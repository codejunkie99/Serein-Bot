#if DEBUG
import SereinCore
import SwiftUI

/// `--verify-outside-agents`: the real `serein-agent` command against this Serein, in a test
/// library, on the localhost fixture (scripts/verify.py). Pairing, refused sites and redirects,
/// steps by label, pictures to files, take-over and Revoke.
@MainActor func checkOutsideAgents() async throws {
  func progress(_ label: String) {
    FileHandle.standardError.write(Data(("Outside agents: " + label + "\n").utf8))
  }
  progress("starting isolated checks")
  guard let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"],
    let data = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"]
  else { throw SereinError.invalid("Outside agent checks require an isolated test library and localhost fixture.") }
  let root = URL(fileURLWithPath: data)
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  let approvals = try FixtureApprovals(browser: browser)
  defer { approvals.close() }
  OutsideAgents.start(root: root, browser: browser)
  progress("approval host and agent socket ready")
  guard let access = OutsideAgents.shared else { throw SereinError.invalid("Outside agents did not start.") }
  let command = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("serein-agent")
  let scratch = root.appendingPathComponent("agent-check", isDirectory: true)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  var checks = 0
  func check(_ condition: Bool, _ label: String, _ detail: Any = "") throws {
    guard condition else { throw SereinError.invalid("Outside agents: \(label) \(detail)") }
    checks += 1
    progress("\(checks): \(label)")
  }
  /// Runs the command and parses its one JSON line.
  func agent(_ words: String...) async -> (status: Int32, out: [String: Any]) {
    progress("calling " + (words.first ?? "unknown"))
    return await withCheckedContinuation { done in
      let process = Process()
      process.executableURL = command
      process.arguments = words
      process.environment = ["SEREIN_DATA_DIR": data, "TMPDIR": scratch.path + "/", "PATH": "/usr/bin:/bin"]
      let pipe = Pipe()
      process.standardOutput = pipe
      DispatchQueue.global().async {
        do { try process.run() } catch { return done.resume(returning: (-1, ["error": error.localizedDescription])) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        done.resume(returning: (process.terminationStatus, object ?? ["error": String(decoding: output, as: UTF8.self)]))
      }
    }
  }
  let host = URL(string: base)!.host!
  let port = URL(string: base)!.port!
  func session() -> (id: String, task: BrowserTask)? {
    browser.tasks.first { $0.value.allows != nil }.map { ($0.key, $0.value) }
  }

  var r = await agent("status")
  try check(r.status == 1 && r.out["needs_user"] as? Bool == true, "an unpaired agent is sent to the user", r.out)
  try check(
    access.makeOffer(name: "Check agent", sites: "", actions: true, localHosts: host, days: 1) == nil, "an offer is made")
  r = await agent("pair", "0000-0000")
  try check(r.status == 1 && access.offer != nil, "a wrong code is refused and the offer stays", r.out)
  r = await agent("pair", access.offer!.code)
  try check(r.out["paired"] as? Bool == true && access.grants.count == 1 && access.offer == nil, "the code pairs once", r.out)
  try check(!jsonString(r.out).contains(access.grants[0].token), "the token is not in the agent's output")
  let clients = try FileManager.default.contentsOfDirectory(atPath: AgentAccess.clients(root: root).path)
  let mode = try FileManager.default.attributesOfItem(atPath: AgentAccess.clients(root: root).appendingPathComponent(clients[0]).path)[.posixPermissions] as? Int
  try check(clients.count == 1 && mode == 0o600, "the client file is owner-only", mode ?? -1)

  // Serein's own settings: read, change at once, refuse what is not a choice. Values are put back.
  let savedAppearance = AppearanceController.shared.preference
  let savedCompact = UserDefaults.standard.object(forKey: "serein.compact")
  defer {
    AppearanceController.shared.set(savedAppearance)
    UserDefaults.standard.set(savedCompact, forKey: "serein.compact")
  }
  r = await agent("settings")
  try check((r.out["settings"] as? [String: String])?["appearance"] != nil, "settings lists Serein's settings", r.out)
  let other = savedAppearance == .light ? "dark" : "light"
  r = try await approvals.perform(expecting: [.init(title: "Serein wants to change a setting", detail: "This changes a setting.")]) {
    await agent("set", "appearance", other)
  }
  try check(r.status == 0 && AppearanceController.shared.preference.rawValue == other, "set changes the appearance at once", r.out)
  r = try await approvals.perform(expecting: [.init(title: "Serein wants to change a setting", detail: "This changes a setting.")]) {
    await agent("set", "compact", "on")
  }
  try check(r.out["value"] as? String == "on" && UserDefaults.standard.bool(forKey: "serein.compact"), "set changes the tab layout", r.out)
  r = try await approvals.perform(expecting: [.init(title: "Serein wants to change a setting", detail: "This changes a setting.")]) {
    await agent("set", "text_size", "500%")
  }
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("90% to 160%") == true, "a value that is not a choice is refused", r.out)
  r = try await approvals.perform(expecting: [.init(title: "Serein wants to change a setting", detail: "This changes a setting.")]) {
    await agent("set", "history", "off")
  }
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("Unknown setting") == true, "only listed settings change", r.out)
  r = await agent("update")
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("no update feed") == true, "a local build says it has no update feed", r.out)
  r = try await approvals.perform(expecting: [.init(title: "Serein wants to change a setting", detail: "This may change who has access.")]) {
    await agent("sign-in", "nobody")
  }
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("Unknown agent") == true, "sign-in names the agents it knows", r.out)
  let inApp = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
  // Both paths read settings without changing them.
  progress("calling in-app settings_get")
  let own = try await approvals.perform(expecting: []) {
    try await browser.handle(["task": inApp.capability.task, "token": inApp.capability.token, "name": "settings_get", "arguments": [:]])
  }
  browser.endTask(inApp.capability.task)
  try check((own["settings"] as? [String: String])?["appearance"] == other, "Serein's own agents read the same settings")

  r = await agent("open", "http://localhost:\(port)/form")
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("may not open localhost") == true, "an unlisted local name is refused", r.out)
  r = await agent("open", "http://10.0.0.1/")
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("may not open") == true, "a private address is refused", r.out)
  r = try await approvals.perform(expecting: [.site(url: base + "form")]) {
    await agent("open", base + "form")
  }
  guard let tab = r.out["tab"] as? String else { throw SereinError.invalid("Outside agents: open failed \(r.out)") }
  try check(session()?.task.isolated == true, "a pairing with no sign-in sites works in isolated tabs")
  try check(browser.agentTabs.info(tab)?.agent == "Check agent", "its tabs carry the paired name")

  r = try await approvals.perform(expecting: [
    .init(title: "Serein wants to type on this page", detail: "Check this before you allow it."),
    .init(title: "Serein wants to click on this page", detail: "This may change something. Check it before you allow it.\nTarget: Apply"),
  ]) {
    await agent("steps", #"[{"tool":"type","tab":"\#(tab)","label":"Message","text":"hello"},{"tool":"click","label":"Apply"}]"#)
  }
  let after = ((r.out["result"] as? [String: Any])?["page"] as? [String: Any])?["text"] as? String ?? ""
  try check(r.status == 0 && after.contains("Sent: hello"), "steps find fields and buttons by label", r.out)
  r = await agent("click", tab, "--label", "Nothing like this")
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("No element matches") == true, "a missing label is reported", r.out)

  r = await agent("screenshot", tab)
  let picture = (r.out["file"] as? String).flatMap { FileManager.default.contents(atPath: $0) } ?? Data()
  try check(picture.starts(with: [0x89, 0x50, 0x4E, 0x47]), "a screenshot is saved as a PNG file", r.out)
  let readFile = scratch.appendingPathComponent("read.json").path
  r = await agent("read", tab, "--out", readFile)
  try check(r.out["file"] as? String == readFile && FileManager.default.fileExists(atPath: readFile), "--out writes the read to a file", r.out)

  // A page that sends its tab out of the allowed hosts does not leave them.
  if let live = session()?.task.tabs.first {
    _ = try await live.script("location.href='http://localhost:\(port)/plain';true")
    try await Task.sleep(nanoseconds: 800_000_000)
    try check(live.address.contains(host) && !live.address.contains("localhost"), "a page cannot take the tab to another host", live.address)
  }

  // The user takes over: the next call asks the agent to check with the user; the one after starts again.
  if let current = session() { browser.endTask(current.id) }
  r = await agent("status")
  try check(r.status == 0 && (r.out["tabs"] as? [Any])?.isEmpty == true, "status works after a take-over", r.out)
  r = await agent("tabs")
  try check(r.status == 1 && r.out["needs_user"] as? Bool == true, "the first call after a take-over goes to the user", r.out)
  r = try await approvals.perform(expecting: [.site(url: base + "plain")]) {
    await agent("open", base + "plain")
  }
  try check(r.status == 0 && r.out["tab"] != nil, "the agent can start again after that", r.out)
  // The MCP mode: the same pairing and tools over JSON-RPC.
  progress("calling mcp")
  let lines = await withCheckedContinuation { (done: CheckedContinuation<[[String: Any]], Never>) in
    let process = Process()
    process.executableURL = command
    process.arguments = ["mcp"]
    process.environment = ["SEREIN_DATA_DIR": data, "PATH": "/usr/bin:/bin"]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    DispatchQueue.global().async {
      guard (try? process.run()) != nil else { return done.resume(returning: []) }
      let messages = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"do","arguments":{}}}"#,
      ]
      input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))
      try? input.fileHandleForWriting.close()
      let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      process.waitUntilExit()
      done.resume(returning: text.split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
      })
    }
  }
  let listed = ((lines.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
    .compactMap { $0["name"] as? String }
  let mcpStatus = lines.first { $0["id"] as? Int == 3 }?["result"] as? [String: Any]
  let mcpDo = lines.first { $0["id"] as? Int == 4 }?["result"] as? [String: Any]
  try check(lines.count == 4 && listed.contains("open") && listed.contains("settings_set") && !listed.contains("do") && !listed.contains("mac_act"),
    "mcp lists the browser tools without fast steps or Mac tools", listed)
  try check(mcpStatus?["isError"] == nil && jsonString(mcpStatus ?? [:]).contains("Check agent"), "mcp calls Serein", mcpStatus ?? [:])
  try check(mcpDo?["isError"] as? Bool == true, "mcp refuses a tool it does not list")

  r = await agent("done", "Checked", "the", "form")
  try check(r.status == 0 && session() == nil, "done ends the session", r.out)

  // Reads only, and sign-ins on listed sites only.
  let first = access.grants[0].id
  access.revoke(first)
  r = await agent("status")
  try check(r.status == 1 && access.grants.isEmpty, "Revoke ends the pairing", r.out)
  try check(access.makeOffer(name: "Sites", sites: "example.com", actions: false, localHosts: "", days: 0) == nil, "a sites offer")
  r = await agent("pair", access.offer!.code)
  try check(r.out["paired"] as? Bool == true, "the sites pairing", r.out)
  r = await agent("open", "https://www.iana.org/")
  try check(r.status == 1 && (r.out["error"] as? String)?.contains("may not open") == true, "an unlisted site is refused", r.out)
  r = await agent("open", base + "form")
  try check(r.status == 1, "a local address not listed is refused", r.out)
  try check(access.makeOffer(name: "Sites", sites: "", actions: true, localHosts: "", days: 1) != nil, "names stay unique")
  try check(access.makeOffer(name: "Other", sites: "localhost", actions: true, localHosts: "", days: 1) != nil,
    "a local address is not a sign-in site")
  // A pairing whose "May ask Serein" the one-time assistant migration took back is refused with
  // words that say how to give it back; turning it on again clears the mark.
  try check(access.makeOffer(name: "Asker", sites: "", actions: false, localHosts: "", days: 1, relay: true) == nil, "an asking offer")
  r = await agent("pair", access.offer!.code)
  try check(r.out["paired"] as? Bool == true, "the asking pairing", r.out)
  OutsideAgents.clearRelayGrants(root: root)
  let asker = access.grants.first { $0.name == "Asker" }
  r = await agent("relay", "ask", "hello", "--as", "Asker")
  try check(r.status == 1 && asker?.mayAskRelay == false && asker?.relayCleared == true
    && (r.out["error"] as? String)?.contains("may no longer ask Serein") == true
    && (r.out["error"] as? String)?.contains("“May ask Serein” for Asker again") == true,
    "a pairing whose ask was cleared is refused and told how to allow it again", r.out)
  if let asker { access.setMayAsk(asker.id, true) }
  let stored = try JSONDecoder().decode(AgentGrant.self, from: Data(contentsOf:
    AgentAccess.grants(root: root).appendingPathComponent((asker?.id ?? "") + ".json")))
  try check(stored.mayAskRelay && stored.relayCleared == nil, "allowing it again is saved", stored.relay ?? false)
  if let asker { access.revoke(asker.id) }
  access.cancelOffer()
  let audit = try String(contentsOf: AgentAccess.directory(root: root).appendingPathComponent("audit.jsonl"))
  try check(audit.contains("\"call\":\"steps\"") == false && audit.contains("\"call\":\"type\"") && !audit.contains("hello"),
    "the audit log names calls but not what was typed")
  access.revoke(access.grants[0].id)
  print("PASS: \(checks) outside agent checks")
}
#endif
