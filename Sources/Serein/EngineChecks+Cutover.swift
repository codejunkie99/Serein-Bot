#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// What the per-CLI cut-over needs before the old launch paths go, through the app's bridge
/// (EngineTurn), Engines and the real process host, against fake CLIs: Edit Review keeps what a
/// stopped turn writes on its way out, a resume Claude no longer has goes on in a fresh session,
/// an OpenCode turn writes the behaviour history the old OpenCode path wrote, and the OpenCode key
/// card hands its key to a one-shot server.
extension AssistantCoreChecks {
  static func cutover(_ check: Check) throws {
    try MainActor.assumeIsolated {
      try withoutActuallyEscaping(check) { check in
        let rig = try CutoverRig()
        defer { rig.finish() }
        try rig.pump { try await editReviewAfterStop(check, rig) }
        try rig.pump { try await claudeResumeRecovery(check, rig) }
        try rig.pump { try await openCodeHistory(check, rig) }
        try rig.pump { try await openCodeKeyHandOff(check, rig) }
        try rig.pump { try await openCodeIntelligence(check, rig) }
        try rig.pump { try await standIns(check, rig) }
      }
    }
  }

  @MainActor private static func editReviewAfterStop(_ check: Check, _ rig: CutoverRig) async throws {
    let git = try GitTurns.locateGit().required("Edit Review: git is not on this Mac")
    let project = try rig.folder("edit-review")
    try GitTurns.initialize(folder: project, git: git)
    try "base\n".write(to: project.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    let target = AgentModel.DispatchTarget(mode: .project, provider: .claude, projectID: rig.add(project), edits: true)
    let thread = try await rig.agent.dispatch("STOPWRITE on the way out", into: nil, create: true, as: target)
    let run = try rig.agent.hub.run(for: thread).required("Edit Review: the editing turn did not start")
    try check(
      await rig.until(20) { run.transcript.last?.text.contains("working") == true },
      "Edit Review: an editing engine turn started")
    rig.agent.hub.stop(run)
    try check(
      await rig.until(20) { EditReview.shared.reviews.first { $0.id == run.id }.map { !$0.inProgress } ?? false },
      "Edit Review: a stopped engine turn's review finishes")
    let review = EditReview.shared.reviews.first { $0.id == run.id }
    try check(
      review?.state == .ready && review?.files.contains { $0.path == "late.txt" } == true,
      "Edit Review: a file a stopped engine turn writes 300 ms after its last event is in its review")
  }

  @MainActor private static func claudeResumeRecovery(_ check: Check, _ rig: CutoverRig) async throws {
    let target = AgentModel.DispatchTarget(mode: .research, provider: .claude)
    /// What came back after the person's last message.
    func reply(_ run: AgentRun) -> String { run.transcript.reversed().prefix { $0.role != "you" }.map(\.text).joined(separator: "\n") }
    let thread = try await rig.agent.dispatch("Remember FIRST-TURN-WORDS", into: nil, create: true, as: target)
    let first = try rig.agent.hub.run(for: thread).required("Claude resume: the first turn did not start")
    try check(
      await rig.until(20) { !first.isActive } && first.error == nil && reply(first).contains("echo: ")
        && reply(first).contains("FIRST-TURN-WORDS"),
      "Claude resume: the first turn answers")
    try check(
      await rig.until(10) { rig.agent.conversations.first { $0.id == thread }?.remoteID != nil },
      "Claude resume: the first turn's session is saved with the thread")
    // Cold, so the next turn starts Claude again with --resume.
    let warm = rig.claudeLaunches().last.flatMap { $0["pid"] as? Int }.map { pid_t($0) }
    await rig.engines.close(ThreadKey(thread))
    try check(await rig.until(10) { warm.map { kill($0, 0) != 0 } == true }, "Claude resume: the warm process ended")
    // Engines frees the thread only when the stop ladder ends: 500 ms, then up to 1.5 s more.
    try await Task.sleep(nanoseconds: 2_500_000_000)
    let before = rig.claudeLaunches().count
    _ = try await rig.agent.dispatch("And now SECOND-TURN-WORDS", into: thread, as: target)
    let second = try rig.agent.hub.run(for: thread).required("Claude resume: the second turn did not start")
    try check(await rig.until(20) { !second.isActive }, "Claude resume: the resumed turn ends")
    let launches = rig.claudeLaunches().dropFirst(before).map { $0["argv"] as? [String] ?? [] }
    let answer = reply(second)
    try check(
      second.error == nil && answer.contains("Previous conversation is context") && answer.contains("FIRST-TURN-WORDS")
        && answer.contains("SECOND-TURN-WORDS"),
      "Claude resume: a resume Claude refuses goes on in a fresh session that carries the conversation"
        + (second.error.map { " [\($0)]" } ?? ""))
    try check(
      launches.count == 2 && launches.first?.contains("--resume") == true && launches.last?.contains("--resume") == false,
      "Claude resume: one fresh launch after the refused resume, never another resume")
  }

  /// Ported from HarnessAdapterChecks' OpenCode ledger checks, which ran on the old OpenCode path.
  @MainActor private static func openCodeHistory(_ check: Check, _ rig: CutoverRig) async throws {
    let browser = rig.browser
    // Research, as the old check ran.
    var target = AgentModel.DispatchTarget(mode: .research, provider: Provider(.opencode))
    func turn(_ prompt: String) async throws -> AgentRun {
      let thread = try await rig.agent.dispatch(prompt, into: nil, create: true, as: target)
      return try rig.agent.hub.run(for: thread).required("OpenCode history: \"\(prompt)\" did not start")
    }
    let o1 = try await turn("Say hello PRIVATE_OPENCODE_PROMPT_CANARY")
    try check(await rig.until(20) { !o1.isActive } && o1.error == nil, "OpenCode history: a turn whose tool fails twice ends")
    let o3 = try await turn("SLOW work")
    try check(await rig.until(20) { o3.transcript.last?.text.contains("Working") == true }, "OpenCode history: a slow turn started")
    rig.agent.hub.stop(o3)
    try check(await rig.until(20) { !o3.isActive }, "OpenCode history: Stop ends the slow turn")
    let o4 = try await turn("SHELL list the folder")
    try check(await rig.until(20) { !o4.isActive }, "OpenCode history: a turn whose command Serein refused ends")
    // The edit the bridge declines comes from Claude Code's fake: OpenCode's fake never edits.
    target = AgentModel.DispatchTarget(mode: .project, provider: .claude, projectID: rig.add(try rig.folder("declined-edit")))
    let o2 = try await turn("DENYEDIT the notes")
    try check(
      await rig.until(20) { !o2.isActive } && o2.approvals.map(\.target) == ["notes.txt"],
      "OpenCode history: a declined edit on an engine turn becomes an approval")

    let history = try browser.behaviorHistory.required("OpenCode history: no history store")
    let reopened = try AgentHistoryStore(library: browser.library)
    let ids = Set([o1.id, o2.id, o3.id, o4.id])
    let events = try reopened.archive().events.filter { ids.contains($0.run.id.uuidString) }
    let streamed = events.filter { $0.run.id.uuidString == o1.id }
    let openCode = events.filter { $0.run.id.uuidString != o2.id }
    try check(
      reopened.issuerID == history.issuerID
        && !openCode.isEmpty && openCode.allSatisfy { $0.actorID == history.issuerID.uuidString + ":opencode" }
        && streamed.contains { $0.kind == .sessionLinked && $0.sessionFingerprint != nil }
        && streamed.filter { $0.kind == .toolReported && $0.source == .harness && $0.tool == .fileRead }.count == 1
        && streamed.filter { $0.kind == .toolFailureReported && $0.source == .harness }.count == 1,
      "OpenCode history: identity, session link and deduplicated tool failures survive reopening the ledger")
    try check(
      events.contains { $0.run.id.uuidString == o2.id && $0.kind == .permissionAnswered && $0.decision == .denied }
        && events.contains { $0.run.id.uuidString == o2.id && $0.kind == .approvalRequested && $0.source == .harness }
        && events.contains { $0.run.id.uuidString == o3.id && $0.kind == .capabilityRevoked }
        && events.contains { $0.run.id.uuidString == o3.id && $0.kind == .runEnded && $0.outcome == .stopped },
      "OpenCode history: the permission rejection, approval request and Stop are durable host history")
    let refused = events.filter { $0.run.id.uuidString == o4.id }
    try check(
      refused.contains { $0.kind == .permissionAnswered && $0.decision == .denied }
        && refused.contains { $0.kind == .toolReported && $0.tool == .command }
        && !refused.contains { $0.tool == .fileRead },
      "OpenCode history: a research turn's refused shell call is a denied answer and a command, not a read")
    let data = try AgentHistoryArchive(issuerID: history.issuerID, events: events).encoded()
    let exported = String(decoding: data, as: UTF8.self)
    let destination = try Library(root: rig.root.appendingPathComponent("history-destination"))
    let receiver = try AgentHistoryStore(library: destination)
    let imported = try receiver.importArchive(data)
    try check(
      !exported.contains("PRIVATE_OPENCODE_") && !exported.contains("ses_1")
        && !exported.contains("notes.txt") && !exported.contains(rig.root.path)
        && imported.events == (try AgentHistoryArchive.decode(data)).events
        && receiver.issuerID != imported.issuerID && (try receiver.archive()).events.isEmpty
        && AccessMemory.load(from: destination).byProject.isEmpty
        && !FileManager.default.fileExists(atPath: destination.root.appendingPathComponent("sessions/threads.json").path),
      "OpenCode history: exports redact payloads; imports keep local identity and never restore sessions or access grants")
  }
}

extension AssistantCoreChecks {
  /// A task the thread's app cannot run, or whose app is not set up, runs on one that can; a
  /// project permission outside a project runs Supervised; OpenCode works in a project.
  @MainActor private static func standIns(_ check: Check, _ rig: CutoverRig) async throws {
    let git = try GitTurns.locateGit().required("Stand-ins: git is not on this Mac")
    let grok = HarnessRegistry.shared.snapshot(Provider(.grok))
    defer { HarnessRegistry.shared.assume(.grok, grok) }
    var floor = HarnessSnapshot(instance: HarnessInstance(driver: .grok), status: .ready)
    floor.version = HarnessDriver.grok.minimumCLIVersion
    HarnessRegistry.shared.assume(.grok, floor)
    rig.agent.pin(Provider(.grok), executable: "/usr/bin/false")
    rig.agent.available[Provider(.gemini)] = nil
    func project(_ name: String) throws -> String {
      let folder = try rig.folder(name)
      try GitTurns.initialize(folder: folder, git: git)
      return rig.add(folder)
    }
    let cases: [(String, AgentModel.DispatchTarget, Provider)] = [
      ("OpenCode works in a project with edits",
        .init(mode: .project, provider: Provider(.opencode), projectID: try project("open-project"), edits: true), Provider(.opencode)),
      ("A Grok project task runs on Claude Code",
        .init(mode: .project, provider: Provider(.grok), projectID: try project("grok-project"), edits: true), .claude),
      ("A web task for Gemini, which is not set up, runs on Claude Code",
        .init(mode: .research, provider: Provider(.gemini)), .claude),
      ("Full access on a web task runs Supervised",
        .init(mode: .research, provider: .claude, permission: .fullAccess), .claude),
    ]
    for (name, target, expected) in cases {
      var outcome = ""
      do {
        let thread = try await rig.agent.dispatch("Say hello", into: nil, create: true, as: target)
        let run = try rig.agent.hub.run(for: thread).required("\(name): no run")
        _ = await rig.until(20) { !run.isActive }
        outcome = run.spec.provider == expected && run.error == nil ? "" : "ran on \(run.spec.provider.name): \(run.error ?? "")"
      } catch {
        outcome = error.localizedDescription
      }
      try check(outcome.isEmpty, "Stand-in: \(name)" + (outcome.isEmpty ? "" : " [\(outcome)]"))
    }
  }

  /// Intelligence on OpenCode stays on the selected model: no other provider's quota, and no
  /// request on OpenCode's own default.
  @MainActor private static func openCodeIntelligence(_ check: Check, _ rig: CutoverRig) async throws {
    let agent = rig.agent
    let selected = agent.provider, selectedModel = agent.model, available = agent.available
    defer { agent.provider = selected; agent.model = selectedModel; agent.available = available }
    let path = try available[Provider(.opencode)].required("OpenCode intelligence: the fake is not pinned")
    agent.provider = Provider(.opencode)
    agent.model = "opencode/deepseek-test-free"
    agent.available[.claude] = "/synthetic/claude"
    let selection = agent.helperProvider == Provider(.opencode) && agent.helperModel == agent.model
      && agent.helperExecutable == path
    agent.available[Provider(.opencode)] = nil
    let noFallback = agent.helperProvider == Provider(.opencode) && agent.helperExecutable == nil
    try check(selection && noFallback, "OpenCode intelligence keeps the selected model and never falls back to Claude quota")
    let listed = HarnessRegistry.shared.snapshot(Provider(.opencode))
    defer { HarnessRegistry.shared.assume(.opencode, listed) }
    var free = listed ?? HarnessSnapshot(instance: HarnessInstance(driver: .opencode), status: .ready)
    free.models = [HarnessModel(id: "opencode/deepseek-test-free", name: "DeepSeek", blurb: "", isDefault: true)]
    HarnessRegistry.shared.assume(.opencode, free)
    var refusal = ""
    do {
      refusal = "answered: " + (try await StructuredAgent(engines: rig.engines).run(
        executable: path, provider: Provider(.opencode), model: "", prompt: "Pick a title"))
    } catch {
      refusal = error.localizedDescription
    }
    try check(refusal == "answered: Hello from OpenCode on opencode/deepseek-test-free",
      "OpenCode intelligence with no model chosen runs on the model OpenCode lists, never its own default [\(refusal)]")
  }

  /// The key card's one-shot `opencode serve`, against a fake that records what it was sent.
  @MainActor private static func openCodeKeyHandOff(_ check: Check, _ rig: CutoverRig) async throws {
    let folder = try rig.folder("key-serve")
    let fake = folder.appendingPathComponent("opencode")
    try Data(CutoverRig.fakeServe.utf8).write(to: fake)
    chmod(fake.path, 0o755)
    let env = ProcessInfo.processInfo.environment
    func log() -> [[String: Any]] {
      ((try? String(contentsOf: folder.appendingPathComponent("served.jsonl"), encoding: .utf8)) ?? "")
        .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    let stored = await OpenCodeKey.hand("sk-good-KEY-CANARY", model: "deepseek/deepseek-v4", executable: fake.path, environment: env)
    let first = log().first ?? [:]
    let pid = first["pid"] as? Int32 ?? 0
    let configDir = first["configDir"] as? String ?? ""
    try check(
      stored && first["path"] as? String == "/api/integration/deepseek/connect/key"
        && first["directory"] as? String == HelperFolder.url.path && first["auth"] as? Bool == true
        && first["body"] as? String == #"{"key":"sk-good-KEY-CANARY"}"#
        && first["argv"] as? [String] == ["serve", "--hostname=127.0.0.1", "--port=0"],
      "OpenCode key: the one-shot server takes the key in the body of its connect-key request, behind its password")
    try check(
      configDir == HelperFolder.openCodeConfig && !configDir.hasPrefix(NSHomeDirectory() + "/.config")
        && first["pure"] as? String == "1" && first["projectConfig"] as? String == "1",
      "OpenCode key: the server runs on Serein's empty config folder, never the person's ~/.config/opencode")
    try check(await rig.until(5) { pid > 1 && kill(pid, 0) != 0 }, "OpenCode key: the server is stopped once the key is in")
    let refused = await OpenCodeKey.hand("sk-bad", model: "deepseek/deepseek-v4", executable: fake.path, environment: env)
    let unnamed = await OpenCodeKey.hand("sk-good", model: "default", executable: fake.path, environment: env)
    try check(!refused && !unnamed && log().count == 2,
      "OpenCode key: a key OpenCode refuses fails, and a model with no provider starts nothing")
  }
}

/// A throwaway library, an agent whose hub runs a fake Claude Code and a fake OpenCode through
/// Engines and the real process host, and the main run loop turned while async checks run.
@MainActor private final class CutoverRig {
  let root: URL
  let browser: BrowserModel
  let agent: AgentModel
  let engines: Engines
  private let claude: URL
  private let savedEngines: Engines
  private let probed: [HarnessDriver: HarnessSnapshot?]

  init() throws {
    let fm = FileManager.default
    // Outside the library: assistants never work inside Serein's own data.
    root = URL(fileURLWithPath: "/private/tmp/serein-cutover-\(UUID().uuidString)", isDirectory: true)
    for name in ["claude-cli", "opencode-cli"] {
      try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    claude = root.appendingPathComponent("claude-cli/claude")
    let opencode = root.appendingPathComponent("opencode-cli/opencode")
    for (url, script) in [(claude, Self.fakeClaude), (opencode, Self.fakeOpenCode)] {
      try Data(script.utf8).write(to: url)
      chmod(url.path, 0o755)
    }
    browser = try BrowserModel(root: root.appendingPathComponent("library"), prepareHistoryAsynchronously: false)
    agent = AgentModel(browser: browser, discoverProviders: false)
    let records = RunRecords(root: root.appendingPathComponent("runs"))
    engines = Engines(
      drivers: [ClaudeDriver(root: root.appendingPathComponent("claude-launch", isDirectory: true)), OpenCodeDriver()],
      host: SereinProcessHost(records: records), records: records, tickEvery: .seconds(3_600))
    savedEngines = agent.hub.engines
    agent.hub.engines = engines
    var probed: [HarnessDriver: HarnessSnapshot?] = [:]
    for (driver, executable) in [(HarnessDriver.claude, claude), (.opencode, opencode)] {
      probed[driver] = HarnessRegistry.shared.snapshot(Provider(driver))
      // File modes need a probed version (HarnessVersionGate): this one is at the CLI's floor.
      var floor = HarnessSnapshot(instance: HarnessInstance(driver: driver), status: .ready)
      floor.version = driver.minimumCLIVersion
      HarnessRegistry.shared.assume(driver, floor)
      agent.pin(Provider(driver), executable: executable.path)
    }
    self.probed = probed
  }

  func finish() {
    agent.clear()
    try? pump { [engines] in await engines.shutdown() }
    agent.hub.engines = savedEngines
    for (driver, snapshot) in probed { HarnessRegistry.shared.assume(driver, snapshot) }
    try? FileManager.default.removeItem(at: root)
  }

  /// A new folder outside the library.
  func folder(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Adds the folder as a project and returns its id.
  func add(_ folder: URL) -> String {
    let project = Project(name: folder.lastPathComponent, path: folder.path, source: .added)
    browser.projects.append(project)
    return project.id
  }

  func claudeLaunches() -> [[String: Any]] {
    let log = claude.deletingLastPathComponent().appendingPathComponent("launches.jsonl")
    return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    return condition()
  }

  /// Runs `body` on the main actor and turns the main run loop until it is done.
  func pump(_ body: @escaping @MainActor () async throws -> Void) throws {
    final class Box { var result: Result<Void, Error>? }
    let box = Box()
    Task { @MainActor in
      do { try await body(); box.result = .success(()) } catch { box.result = .failure(error) }
    }
    let deadline = Date().addingTimeInterval(90)
    while box.result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    guard let result = box.result else { throw SereinError.invalid("FAIL: cut-over check timed out") }
    try result.get()
  }

  /// Claude Code's stream-json wire as EngineChecks+Claude's fake speaks it. A resume always
  /// fails as Claude fails one it no longer has; STOPWRITE writes late.txt 300 ms after its input
  /// closes (Stop); the turn judge's question (Judge.prompt) is answered "nothing left"; anything
  /// else is echoed back.
  static let fakeClaude = #"""
    #!/usr/bin/env python3
    import json, os, sys, time
    here = os.path.dirname(os.path.abspath(__file__))
    argv = sys.argv[1:]
    if argv == ["--version"]:
        print("2.1.325 (Claude Code)"); sys.exit(0)
    if argv[:2] == ["auth", "status"]:
        print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty"})); sys.exit(0)
    resume = argv[argv.index("--resume") + 1] if "--resume" in argv else None
    with open(os.path.join(here, "launches.jsonl"), "a") as log:
        log.write(json.dumps({"pid": os.getpid(), "argv": argv}) + "\n")
    def out(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    if resume:
        sys.stderr.write("No conversation found with session ID: %s\n" % resume)
        out({"type": "result", "subtype": "error_during_execution", "is_error": True, "errors": ["No conversation found with session ID: " + resume]})
        sys.exit(1)
    session = "sess-%d" % os.getpid()
    late = False
    for raw in sys.stdin:
        msg = json.loads(raw)
        if msg.get("type") == "control_request":
            out({"type": "control_response", "response": {"subtype": "success", "request_id": msg["request_id"], "response": {"current_permission_mode": "dontAsk", "account": {"tokenSource": "claude.ai", "apiProvider": "firstParty"}}}})
            continue
        if msg.get("type") != "user":
            continue
        text = "".join(b.get("text", "") for b in msg["message"]["content"] if b.get("type") == "text")
        out({"type": "system", "subtype": "init", "session_id": session, "tools": [], "mcp_servers": [], "model": "fake", "permissionMode": "dontAsk"})
        out({"type": "user", "message": msg["message"], "session_id": session, "parent_tool_use_id": None, "uuid": msg.get("uuid"), "isReplay": True})
        if "STOPWRITE" in text:
            late = True
            out({"type": "stream_event", "parent_tool_use_id": None, "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "working"}}})
            continue
        reply = '{"left":""}' if 'Return JSON {"left":""}' in text else "echo: " + text
        out({"type": "assistant", "parent_tool_use_id": None, "message": {"role": "assistant", "content": [{"type": "text", "text": reply}]}})
        denials = [{"tool_name": "Edit", "tool_use_id": "toolu_deny", "tool_input": {"file_path": os.path.join(os.getcwd(), "notes.txt")}}] if "DENYEDIT" in text else []
        out({"type": "result", "subtype": "success", "is_error": False, "stop_reason": "end_turn", "session_id": session,
             "usage": {"input_tokens": 10, "output_tokens": 5}, "queued_turn_count": 0, "permission_denials": denials})
    if late:
        time.sleep(0.3)
        with open(os.path.join(os.getcwd(), "late.txt"), "w") as f: f.write("written after Stop\n")
    """#

  /// `opencode serve` far enough for the key card: says where it listens, logs each request with
  /// the argv and config env it ran with, and takes only "sk-good" keys.
  static let fakeServe = #"""
    #!/usr/bin/env python3
    import base64, json, os, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from urllib.parse import urlparse, parse_qs
    here = os.path.dirname(os.path.abspath(__file__))
    want = "Basic " + base64.b64encode(("opencode:" + os.environ.get("OPENCODE_SERVER_PASSWORD", "")).encode()).decode()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            url = urlparse(self.path)
            with open(os.path.join(here, "served.jsonl"), "a") as f:
                f.write(json.dumps({"pid": os.getpid(), "argv": sys.argv[1:], "path": url.path,
                    "directory": parse_qs(url.query).get("directory", [""])[0], "auth": self.headers.get("Authorization") == want,
                    "body": body, "configDir": os.environ.get("OPENCODE_CONFIG_DIR"), "pure": os.environ.get("OPENCODE_PURE"),
                    "projectConfig": os.environ.get("OPENCODE_DISABLE_PROJECT_CONFIG")}) + "\n")
            good = json.loads(body).get("key", "").startswith("sk-good")
            self.send_response(200 if good else 401); self.end_headers(); self.wfile.write(b"{}")
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print("opencode server listening on http://127.0.0.1:%d" % server.server_port, flush=True)
    server.serve_forever()
    """#

  /// `opencode acp` as OpenCode 2.2.4 speaks it: SLOW works until stopped, SHELL asks to run
  /// `ls` and reports the refused call, anything else runs a read whose call fails twice, then answers.
  static let fakeOpenCode = #"""
    #!/usr/bin/env python3
    import json, sys, time
    def send(o):
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def read():
        line = sys.stdin.readline()
        if not line: sys.exit(0)
        return json.loads(line)
    def ok(i, result): send({"jsonrpc": "2.0", "id": i, "result": result})
    def update(sid, u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}})
    def text(sid, t): update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})
    def read_tool(sid, kind, status):
        update(sid, {"sessionUpdate": kind, "toolCallId": "call_1", "title": "read", "kind": "read", "status": status,
            "rawInput": {"filePath": "PRIVATE_OPENCODE_FILE_CANARY"}, "rawOutput": {"error": "PRIVATE_OPENCODE_ERROR_CANARY"}})
    model = ""
    while True:
        m = read()
        method, i, p = m.get("method"), m.get("id"), m.get("params") or {}
        if method == "session/set_config_option" and p.get("configId") == "model":
            model = p.get("value", "")
            ok(i, {})
        elif method == "initialize":
            ok(i, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "promptCapabilities": {"image": True}}, "authMethods": []})
        elif method == "session/new":
            ok(i, {"sessionId": "ses_1", "configOptions": [{"id": "model", "currentValue": "default-model"}, {"id": "mode", "currentValue": "build"}]})
        elif method == "session/prompt":
            sid = p["sessionId"]
            body = "".join(b.get("text", "") for b in p["prompt"] if b.get("type") == "text")
            if "SLOW" in body:
                text(sid, "Working")
                time.sleep(300)
            elif "SHELL" in body:
                send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {"sessionId": sid,
                    "toolCall": {"toolCallId": "call_sh", "title": "ls", "kind": "execute", "rawInput": {"command": "ls"}},
                    "options": [{"optionId": "once", "kind": "allow_once", "name": "Allow"}, {"optionId": "reject", "kind": "reject_once", "name": "Reject"}]}})
                read()
                update(sid, {"sessionUpdate": "tool_call", "toolCallId": "call_sh", "name": "shell", "title": "ls", "kind": "execute",
                    "status": "failed", "rawInput": {"command": "ls"}})
                text(sid, "Commands are off here")
                ok(i, {"stopReason": "end_turn"})
            else:
                read_tool(sid, "tool_call", "pending")
                read_tool(sid, "tool_call", "in_progress")
                read_tool(sid, "tool_call_update", "failed")
                read_tool(sid, "tool_call_update", "failed")
                text(sid, "Hello from OpenCode" + (" on " + model if model else ""))
                ok(i, {"stopReason": "end_turn"})
        elif i is not None and method:
            send({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "Method not found"}})
    """#
}

private extension Optional {
  func required(_ why: String) throws -> Wrapped {
    guard let self else { throw SereinError.invalid("FAIL: " + why) }
    return self
  }
}
#endif
