#if DEBUG
import Foundation
import SereinCore

/// `--verify-helpers`: helper requests against fake CLIs, with no window and no provider call.
/// Also runs the harness readiness checks headless.
/// `--verify-helpers-live` times real CLIs, cold and ready, with a synthetic request.
@MainActor func checkHelpers(live: Bool) async throws {
  let fm = FileManager.default
  guard let path = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"],
    path.hasPrefix(fm.temporaryDirectory.path) || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"),
    (try? fm.contentsOfDirectory(atPath: path)) == [".serein-helper-check"]
  else { throw SereinError.invalid("Use a fresh temporary library that holds only .serein-helper-check.") }
  func report(_ line: String) { print(line); fflush(stdout) }
  if live { return try await checkLiveHelpers(report: report) }

  let browser = try BrowserModel(root: URL(fileURLWithPath: path))
  defer { browser.shutdown() }
  let agent = AgentModel(browser: browser, discoverProviders: false)
  for line in try await SmokeTest.codexAppServer(browser: browser, agent: agent) { report(line) }
  for line in try await SmokeTest.harnessReadiness(browser: browser, agent: agent) { report(line) }

  var passed = 0
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("FAIL: " + label) }
    passed += 1
    report("PASS: " + label)
  }
  let dir = URL(fileURLWithPath: path).appendingPathComponent("helper-fakes")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  let log = dir.appendingPathComponent("received.jsonl")
  setenv("SEREIN_FAKE_LOG", log.path, 1)
  func install(_ name: String, _ script: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }
  func received() -> [[String: Any]] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }
  func timed(_ body: () async throws -> String) async throws -> (String, TimeInterval) {
    let start = Date()
    let answer = try await body()
    return (answer, Date().timeIntervalSince(start))
  }
  func ask(_ driver: HarnessDriver, _ executable: String, _ prompt: String = "Return {\"ok\":true}") async throws -> String {
    try await StructuredAgent().run(executable: executable, provider: Provider(driver), model: "", prompt: prompt)
  }

  // Claude Code answers through Engines (EngineChecks); the helper choice below only names it.
  let claude = "/synthetic/claude"

  // Grok and Cursor are refused before anything starts while their own config could act
  // without Serein answering (StructuredAgent.configProblem). GROK_HOME points at a made-up config.
  let grokHome = dir.appendingPathComponent("grok-home")
  try fm.createDirectory(at: grokHome, withIntermediateDirectories: true)
  let grokConfig = grokHome.appendingPathComponent("config.toml")
  try "[mcp_servers.files]\ncommand = \"x\"\n".write(to: grokConfig, atomically: true, encoding: .utf8)
  setenv("GROK_HOME", grokHome.path, 1)
  defer { unsetenv("GROK_HOME") }
  let grok = try install("grok", fakeACP)
  StructuredAgent.forgetConfigChecks()
  var grokRefusal = ""
  do { _ = try await ask(.grok, grok) } catch { grokRefusal = error.localizedDescription }
  try check(grokRefusal.contains("MCP servers") && !received().contains { $0["cli"] as? String == "acp" },
    "Grok is refused before it starts when its config adds MCP servers")

  // Cursor's check reads this Mac's own ~/.cursor, so it is asserted only where that refuses.
  let cursor = try install("cursor-agent", fakeACP)
  let cursorProblem = CursorPreflight.problem(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
  if let cursorProblem {
    var cursorResult = ""
    do { _ = try await ask(.cursor, cursor) } catch { cursorResult = error.localizedDescription }
    try check(cursorResult == cursorProblem && !received().contains { $0["cli"] as? String == "acp" },
      "Cursor is refused while its settings have hooks, MCP servers or open allow rules")
  }

  let pi = "/synthetic/pi"

  // The judge and the helper choice reach every harness that can answer.
  try "[ui]\n".write(to: grokConfig, atomically: true, encoding: .utf8)
  StructuredAgent.forgetConfigChecks()
  let saved = (agent.provider, agent.model, agent.available)
  agent.available = [Provider(.cursor): cursor, .claude: claude]
  agent.provider = Provider(.cursor)
  let cursorChoice = agent.helperProvider == (cursorProblem == nil ? Provider(.cursor) : .claude)
  agent.available = [Provider(.pi): pi]
  agent.provider = Provider(.pi)
  let piChosen = agent.helperProvider == Provider(.pi)
  agent.available = [Provider(.grok): grok, .claude: claude]
  agent.provider = Provider(.grok)
  let grokChosen = agent.helperProvider == Provider(.grok)
  agent.available = [Provider(.pi): pi, Provider(.opencode): "/synthetic/opencode"]
  agent.provider = Provider(.cursor)
  let fallback = agent.helperProvider == Provider(.pi)
  agent.provider = saved.0; agent.model = saved.1; agent.available = saved.2
  let spec = RunSpec(threadID: "t", provider: Provider(.pi), executable: pi, model: "auto", effort: "",
    mode: .answer, projectID: nil, projectName: nil, title: "", scope: "", autoRouting: false,
    grants: RunGrants(), limits: RunLimits(hard: 2, idle: 2))
  let judge = agent.hub.judge(spec)
  try check(
    cursorChoice && piChosen && grokChosen && fallback && judge?.provider == Provider(.pi) && judge?.model == "auto",
    "Helpers and the turn judge use the selected harness when it passes its checks, else Claude Code, Codex, then any other")

  try await checkEngineWiring(browser: browser, agent: agent, root: URL(fileURLWithPath: path), check: check)
  report("PASS: \(passed) helper checks")
}

/// Real CLIs on this Mac, a synthetic request each: cold, then from a ready helper.
@MainActor private func checkLiveHelpers(report: (String) -> Void) async throws {
  let models: [HarnessDriver: String] = [
    .claude: "haiku",
    .opencode: ProcessInfo.processInfo.environment["SEREIN_OPENCODE_TEST_MODEL"] ?? "opencode/deepseek-v4.1-flash-free",
  ]
  let prompt = "Synthetic check. Return JSON only: {\"sum\": 19 + 23 as a number}."
  for driver in HelperWire.drivers {
    guard let executable = driver.binaries.lazy.compactMap({ AgentModel.locate($0) }).first else {
      report("SKIP \(driver.displayName): not installed")
      continue
    }
    let provider = Provider(driver)
    let model = models[driver] ?? ""
    func once() async -> String {
      let start = Date()
      do {
        let answer = try await StructuredAgent().run(executable: executable, provider: provider, model: model, prompt: prompt)
        return String(format: "%.2f s %@", Date().timeIntervalSince(start), answer.contains("42") ? "ok" : "unexpected answer")
      } catch {
        return String(format: "%.2f s error: %@", Date().timeIntervalSince(start), String(error.localizedDescription.prefix(160)))
      }
    }
    let cold = await once()
    StructuredAgent.prewarm(provider, executable: executable, model: model)
    try await Task.sleep(nanoseconds: 4_000_000_000)
    let ready = await once()
    report("\(driver.displayName): cold \(cold); ready \(ready)")
  }
}

/// Records that it started: a refused Grok or Cursor must never get this far.
private let fakeACP = #"""
#!/usr/bin/python3 -I
import json, os, sys
with open(os.environ["SEREIN_FAKE_LOG"], "a") as log:
    log.write(json.dumps({"cli": "acp", "pid": os.getpid(), "argv": sys.argv[1:]}) + "\n")
"""#
#endif
