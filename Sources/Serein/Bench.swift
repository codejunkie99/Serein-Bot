#if DEBUG
import Foundation
import SereinCore
import WebKit

/// `--bench <file>`: each line of the file is a request as a user types it. Each one runs as a web
/// task with Click & type on, one after the other, and prints one JSON line: wall time, tool calls,
/// `do` calls, the run's last context size, any error and the start of the reply. The same file on
/// two builds compares them. SEREIN_BENCH_PROVIDER=claude or opencode picks the agent (Codex otherwise),
/// SEREIN_BENCH_MODEL its model;
/// SEREIN_BENCH_FAST=1 turns fast steps on; SEREIN_BENCH_TIMEOUT sets seconds per request (300);
/// SEREIN_BENCH_EFFORT sets the effort (medium by default).
/// `--bench-first <file>` runs the same requests the Jev-first way (JevFirst.swift), falling back to
/// the agent when the plan says so or Jev hands back.
@MainActor enum Bench {
  static var env: [String: String] { ProcessInfo.processInfo.environment }
  static func requests(_ file: String) -> [String] {
    ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
      .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }
  static func prepare(_ agent: AgentModel) {
    // A plain key, so this file builds without fast steps too.
    UserDefaults.standard.set(env["SEREIN_BENCH_FAST"] == "1", forKey: "serein.fastSteps")
    agent.provider = provider
    if let model = env["SEREIN_BENCH_MODEL"] { agent.model = model }
  }
  /// SEREIN_BENCH_PROVIDER: claude, opencode, or Codex otherwise; SEREIN_BENCH_MODEL names the model.
  static var provider: Provider {
    switch env["SEREIN_BENCH_PROVIDER"] {
    case "claude": return .claude
    case "opencode": return Provider(.opencode)
    default: return .codex
    }
  }
  static func run(browser: BrowserModel, agent: AgentModel, file: String) async {
    prepare(agent)
    for (index, request) in requests(file).enumerated() {
      var row = await agentRun(request, browser: browser, agent: agent)
      while BenchTrace.dir != nil && !BenchTrace.done { try? await Task.sleep(nanoseconds: 50_000_000) }
      row["n"] = index + 1
      print(jsonString(row))
      fflush(stdout)
    }
    exit(0)
  }
  /// One request as a normal agent web task.
  static func agentRun(_ request: String, browser: BrowserModel, agent: AgentModel) async -> [String: Any] {
    let limit = Double(env["SEREIN_BENCH_TIMEOUT"] ?? "") ?? 300
    // SEREIN_BENCH_KEEP=1: the next request continues the same thread (a resumed session).
    if env["SEREIN_BENCH_KEEP"] != "1" || agent.messages.isEmpty { agent.clear() }
    agent.autoRouting = false
    agent.mode = .research
    agent.provider = provider
    if let model = env["SEREIN_BENCH_MODEL"] { agent.model = model }
    if let effort = env["SEREIN_BENCH_EFFORT"] { agent.effort = effort }
    agent.allowActions = true
    let before = browser.toolAudit.count
    let started = Date()
    agent.send(request)
    // The first send can wait for the harness setup before its run starts.
    while !agent.running && agent.error == nil && Date().timeIntervalSince(started) < 60 {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    while agent.running && Date().timeIntervalSince(started) < limit {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let seconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
    let timedOut = agent.running
    if timedOut { agent.cancel() }
    let tools = Array(browser.toolAudit.dropFirst(before))
    BenchTrace.finish(answer: agent.messages.last?.text ?? "")
    return [
      "request": request, "seconds": seconds, "timed_out": timedOut,
      "tool_calls": tools.count, "do_calls": tools.filter { $0 == "do" }.count, "tools": tools,
      // Model calls exclude a repl program's own steps ("repl:click").
      "model_calls": tools.filter { !$0.hasPrefix("repl:") }.count, "repl_calls": tools.filter { $0 == "repl" }.count,
      "context_tokens": agent.hub.runs.last?.contextTokens ?? 0, "error": agent.error ?? "",
      "reply": String((agent.messages.last?.text ?? "").prefix(4000)),
    ]
  }

  static func first(browser: BrowserModel, agent: AgentModel, file: String) async {
    prepare(agent)
    let folder = browser.library.root.appendingPathComponent("Anywhere")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func secs(_ since: Date) -> Double { (Date().timeIntervalSince(since) * 10).rounded() / 10 }
    // Serein finds the installed CLIs a moment after launch; the plan needs one.
    let launch = Date()
    while (agent.helperExecutable == nil || agent.helperProvider != agent.provider)
      && Date().timeIntervalSince(launch) < 60
    {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    for (index, request) in requests(file).enumerated() {
      let started = Date()
      var row: [String: Any] = ["n": index + 1, "request": request]
      do {
        let planned = Date()
        let job = try await JevFirst.plan(request, agent: agent)
        row["plan_s"] = secs(planned)
        row["fit"] = job.fit
        row["goal"] = String(job.goal.prefix(200))
        if job.fit == "steps" {
          let task = try browser.beginTask(isolated: true, allowActions: true, includeCurrent: false)
          defer { browser.endTask(task.capability.task) }
          func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            try await browser.handle([
              "task": task.capability.task, "token": task.capability.token, "name": name, "arguments": args,
            ])
          }
          let opened = try await call("open_tab", ["url": job.url])
          let ran = Date()
          let result = try await call("do", [
            "tab": opened["tab"] as? String ?? "", "goal": job.goal, "inputs": job.inputs ?? [:],
            "checks": job.checks ?? [], "max_actions": 20,
          ])
          row["jev_s"] = secs(ran)
          row["status"] = result["status"] ?? ""
          row["steps"] = (result["steps"] as? [Any])?.count ?? 0
          row["reason"] = String((result["reason"] as? String ?? "").prefix(160))
          if result["status"] as? String == "SUBTASK_COMPLETE" {
            if let report = job.report, !report.isEmpty, let page = result["page"] as? [String: Any] {
              let answered = Date()
              row["reply"] = try await JevFirst.answer(request, report: report, page: page, agent: agent)
              row["answer_s"] = secs(answered)
            } else {
              row["reply"] = "Done: " + job.goal
            }
          }
        }
      } catch {
        row["first_error"] = String(error.localizedDescription.prefix(200))
      }
      if row["reply"] == nil {
        // The agent route, or Jev handed back: the normal agent does the request.
        let fallback = await agentRun(request, browser: browser, agent: agent)
        row["fallback"] = true
        row["agent_s"] = fallback["seconds"]
        row["tool_calls"] = fallback["tool_calls"]
        row["tools"] = fallback["tools"]
        row["error"] = fallback["error"]
        row["reply"] = fallback["reply"]
      }
      row["seconds"] = secs(started)
      print(jsonString(row))
      fflush(stdout)
    }
    exit(0)
  }
}

/// SEREIN_BENCH_TRACE=<dir>: an Online-Mind2Web v2 trajectory for WebJudge (schema_v2 in
/// OSU-NLP-Group/Online-Mind2Web): a viewport picture after every browser step in
/// <dir>/trajectory/NNNN.png, and <dir>/result.json with SEREIN_BENCH_TASK, SEREIN_BENCH_TASK_ID and
/// SEREIN_BENCH_REFLEN at the end. Steps are written in the schema's Grammar A.
@MainActor enum BenchTrace {
  static let dir = ProcessInfo.processInfo.environment["SEREIN_BENCH_TRACE"].map { URL(fileURLWithPath: $0) }
  static var steps: [[String: Any]] = []
  static var labels: [String: String] = [:]
  static var lastTab: BrowserTab?
  /// The last picture taken, reused when a capture fails, and the page at finish (the run's end
  /// discards pages, so the final picture is taken when the agent calls finish).
  static var lastPNG: Data?
  static var final: (png: Data?, url: String)?

  static func record(_ raw: String, _ a: [String: Any], _ result: [String: Any], _ error: Error?, tabs: [BrowserTab]) async {
    guard dir != nil else { return }
    let page = result["page"] as? [String: Any] ?? result
    let tabID = a["tab"] as? String ?? page["tab"] as? String
    let tab = tabs.first { $0.id == tabID } ?? lastTab
    let label = (a["ref"] as? String).flatMap { labels[$0] }.map { " \"\($0)\"" } ?? ""
    let target = (a["ref"] as? String).map { "[ref='\($0)']" } ?? "page"
    let action: String
    switch raw {
    case "open_tab", "open", "navigate", "go": action = "page -> NAVIGATE -> open \(a["url"] as? String ?? "")"
    case "click": action = "CLICK \(target) -> click\(label)"
    case "fill", "type": action = "TYPE \(target) -> type \"\(a["text"] as? String ?? "")\" into\(label)"
    case "select": action = "SELECT \(target) -> select \"\(a["value"] as? String ?? "")\" in\(label)"
    case "key": action = "PRESS_KEY \(target) -> press \(a["key"] as? String ?? "")"
    case "scroll": action = "SCROLL page -> scroll \(a["direction"] as? String ?? "down")"
    case "back": action = "page -> GO_BACK -> go back"
    case "wait": action = "WAIT page -> wait for the page to settle"
    case "read": action = "WAIT page -> read the page text"
    case "find": action = "WAIT page -> find elements"
    case "finish":
      let shown = tabs.first { $0.id == a["result_tab"] as? String } ?? lastTab
      if let shown { final = (await shoot(shown), shown.web.url?.absoluteString ?? "") }
      return
    default: return  // tabs, repl (its steps come one by one), fetch: no page to picture
    }
    for row in page["elements"] as? [[String: Any]] ?? [] {
      if let ref = row["ref"] as? String, let text = row["label"] as? String { labels[ref] = String(text.prefix(80)) }
    }
    if let tab { lastTab = tab }
    let status = error == nil ? "SUCCESS" : "FAILED"
    guard let tab = lastTab else { return }
    append(action + " | " + status, status: status, png: await shoot(tab), url: tab.web.url?.absoluteString ?? "")
  }

  static func finish(answer: String) {
    guard let dir else { return }
    let env = ProcessInfo.processInfo.environment
    let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    Task { @MainActor in
      append("TASK_COMPLETE -> ANSWER: " + text, status: nil, png: final?.png, url: final?.url ?? steps.last?["url"] as? String ?? "")
      let result: [String: Any] = [
        "schema_version": "online-mind2web-v2", "task": env["SEREIN_BENCH_TASK"] ?? "",
        "task_id": env["SEREIN_BENCH_TASK_ID"] ?? "", "reference_length": Int(env["SEREIN_BENCH_REFLEN"] ?? "") ?? 0,
        "agent_final_answer": text, "action_history": steps,
      ]
      try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .withoutEscapingSlashes])
        .write(to: dir.appendingPathComponent("result.json"))
      done = true
    }
  }
  static var done = false

  private static func shoot(_ tab: BrowserTab) async -> Data? {
    let config = WKSnapshotConfiguration()
    config.snapshotWidth = 1000
    guard let image = try? await tab.web.takeSnapshot(configuration: config), let tiff = image.tiffRepresentation
    else { return nil }
    return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
  }

  /// Every step names a picture that exists (WebJudge opens each one): a failed capture reuses the
  /// last picture, and a first step without one gets a blank page.
  private static func append(_ action: String, status: String?, png: Data?, url: String) {
    guard let dir else { return }
    let name = String(format: "%04d.png", steps.count)
    let folder = dir.appendingPathComponent("trajectory")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let blank = NSImage(size: NSSize(width: 1000, height: 750), flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      return true
    }
    let picture = png ?? lastPNG
      ?? blank.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    try? picture?.write(to: folder.appendingPathComponent(name))
    if let png { lastPNG = png }
    steps.append([
      "step": steps.count, "screenshot": name, "url": url, "action": action,
      "action_status": status ?? NSNull(), "thought": NSNull(),
    ])
  }
}
#endif
