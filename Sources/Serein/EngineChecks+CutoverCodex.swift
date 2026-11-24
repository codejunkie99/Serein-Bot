#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// What the Codex cut-over needs before Codex's old launch paths go, through the app's bridge
/// (EngineTurn), Engines and the real process host, against a fake Codex: a resume `codex exec`
/// no longer has goes on in a fresh session with the conversation, and Edit Review keeps what a
/// stopped app-server turn writes on its way out.
extension AssistantCoreChecks {
  static func cutoverCodex(_ check: Check) throws {
    try MainActor.assumeIsolated {
      try withoutActuallyEscaping(check) { check in
        let rig = try CodexCutoverRig()
        defer { rig.finish() }
        try rig.pump { try await codexExecResumeRecovery(check, rig) }
        try rig.pump { try await codexEditReviewAfterStop(check, rig) }
      }
    }
  }

  @MainActor private static func codexExecResumeRecovery(_ check: Check, _ rig: CodexCutoverRig) async throws {
    try await rig.use(rig.execCodex)
    let target = AgentModel.DispatchTarget(mode: .research, provider: .codex)
    /// What came back after the person's last message.
    func reply(_ run: AgentRun) -> String { run.transcript.reversed().prefix { $0.role != "you" }.map(\.text).joined(separator: "\n") }
    let thread = try await rig.agent.dispatch("Remember FIRST-TURN-WORDS", into: nil, create: true, as: target)
    let first = try rig.agent.hub.run(for: thread).required("Codex exec resume: the first turn did not start")
    try check(
      await rig.until(20) { !first.isActive } && first.error == nil && reply(first).contains("FIRST-TURN-WORDS"),
      "Codex exec resume: the first turn answers" + (first.error.map { " [\($0)]" } ?? ""))
    // Ported from HarnessAdapterChecks' reasoning check, which ran Codex on the old exec path.
    try check(
      first.thinking == "Checking the fixture." && !reply(first).contains("Checking the fixture."),
      "Codex keeps reasoning out of the answer on the engine path")
    try check(
      await rig.until(10) { rig.agent.conversations.first { $0.id == thread }?.remoteID != nil },
      "Codex exec resume: the first turn's session is saved with the thread")
    let before = rig.execLaunches().count
    _ = try await rig.agent.dispatch("And now SECOND-TURN-WORDS", into: thread, as: target)
    let second = try rig.agent.hub.run(for: thread).required("Codex exec resume: the second turn did not start")
    try check(await rig.until(20) { !second.isActive }, "Codex exec resume: the resumed turn ends")
    // Helper requests (such as the thread's title) run codex exec --ephemeral: count only the turn's.
    let launches = rig.execLaunches().dropFirst(before).map { $0["argv"] as? [String] ?? [] }.filter { !$0.contains("--ephemeral") }
    let answer = reply(second)
    try check(
      second.error == nil && answer.contains("Previous conversation is context") && answer.contains("FIRST-TURN-WORDS")
        && answer.contains("SECOND-TURN-WORDS"),
      "Codex exec resume: a resume codex exec cannot find goes on in a fresh session that carries the conversation"
        + (second.error.map { " [\($0)]" } ?? ""))
    try check(
      launches.count == 2 && launches.first?.contains("resume") == true && launches.last?.contains("resume") == false,
      "Codex exec resume: one fresh launch after the refused resume, never another resume"
        + " [\(launches.map { $0.contains("resume") ? "resume" : "fresh" })]")
  }

  @MainActor private static func codexEditReviewAfterStop(_ check: Check, _ rig: CodexCutoverRig) async throws {
    try await rig.use(rig.serverCodex)
    let git = try GitTurns.locateGit().required("Codex Edit Review: git is not on this Mac")
    let project = try rig.folder("codex-edit-review")
    try GitTurns.initialize(folder: project, git: git)
    try "base\n".write(to: project.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    let target = AgentModel.DispatchTarget(mode: .project, provider: .codex, projectID: rig.add(project), edits: true)
    let thread = try await rig.agent.dispatch("Edit something", into: nil, create: true, as: target)
    let run = try rig.agent.hub.run(for: thread).required("Codex Edit Review: the editing turn did not start")
    try check(
      await rig.until(20) { run.transcript.last?.text.contains("working") == true },
      "Codex Edit Review: an editing app-server turn started" + (run.error.map { " [\($0)]" } ?? ""))
    rig.agent.hub.stop(run)
    try check(
      await rig.until(20) { EditReview.shared.reviews.first { $0.id == run.id }.map { !$0.inProgress } ?? false },
      "Codex Edit Review: a stopped app-server turn's review finishes")
    let review = EditReview.shared.reviews.first { $0.id == run.id }
    try check(
      review?.state == .ready && review?.files.contains { $0.path == "late.txt" } == true,
      "Codex Edit Review: a file a stopped Codex turn writes 300 ms after Stop is in its review")
  }
}

/// A throwaway library and an agent whose hub runs a fake Codex through Engines and the real
/// process host. The driver's Codex home and home folder are temporary, so nothing reads or
/// writes the person's ~/.codex.
@MainActor private final class CodexCutoverRig {
  let root: URL
  let browser: BrowserModel
  let agent: AgentModel
  let engines: Engines
  /// Probed with a config that overrides Serein's routing, so every turn runs `codex exec`.
  let execCodex: URL
  /// Probed with a clean config, so turns run on the app server.
  let serverCodex: URL
  private let savedEngines: Engines
  private let probed: HarnessSnapshot?

  init() throws {
    let fm = FileManager.default
    // Outside the library: assistants never work inside Serein's own data.
    root = URL(fileURLWithPath: "/private/tmp/serein-cutover-codex-\(UUID().uuidString)", isDirectory: true)
    for name in ["codex-cli", "codex-home", "home"] {
      try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    serverCodex = root.appendingPathComponent("codex-cli/codex")
    execCodex = root.appendingPathComponent("codex-cli/codex-override")
    for url in [serverCodex, execCodex] {
      try Data(Self.fakeCodex.utf8).write(to: url)
      chmod(url.path, 0o755)
    }
    browser = try BrowserModel(root: root.appendingPathComponent("library"), prepareHistoryAsynchronously: false)
    agent = AgentModel(browser: browser, discoverProviders: false)
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = root.appendingPathComponent("codex-home").path
    let records = RunRecords(root: root.appendingPathComponent("runs"))
    engines = Engines(
      drivers: [CodexDriver(inherited: environment, home: root.appendingPathComponent("home").path)],
      host: SereinProcessHost(records: records), records: records, tickEvery: .seconds(3_600))
    savedEngines = agent.hub.engines
    agent.hub.engines = engines
    probed = HarnessRegistry.shared.snapshot(.codex)
    var floor = HarnessSnapshot(instance: HarnessInstance(driver: .codex), status: .ready)
    floor.version = HarnessDriver.codex.minimumCLIVersion
    HarnessRegistry.shared.assume(.codex, floor)
  }

  /// Pins `codex` for the next turns, after Engines probed it (which reads its config's routing).
  func use(_ codex: URL) async throws {
    guard case .ready = await engines.probe(.codex, executable: codex) else {
      throw SereinError.invalid("FAIL: the fake Codex at \(codex.lastPathComponent) did not probe ready")
    }
    agent.pin(.codex, executable: codex.path)
  }

  func finish() {
    agent.clear()
    try? pump { [engines] in await engines.shutdown() }
    agent.hub.engines = savedEngines
    HarnessRegistry.shared.assume(.codex, probed)
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

  func execLaunches() -> [[String: Any]] {
    let log = root.appendingPathComponent("codex-cli/codex.jsonl")
    return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }.filter { $0["kind"] as? String == "exec" }
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
    guard let result = box.result else { throw SereinError.invalid("FAIL: Codex cut-over check timed out") }
    try result.get()
  }

  /// Codex 0.169's exec and app-server wire, as EngineChecks+Codex's fake speaks them. `exec
  /// resume` starts a new session, as Codex does when it cannot find the one asked for, and
  /// answers anyway; exec thinks, then echoes its prompt. An app-server turn works until stopped, then writes
  /// late.txt in its folder 300 ms after its input closes (or SIGTERM) and ends. A name ending in
  /// "override" reads a config that overrides Serein's routing.
  static let fakeCodex = #"""
    #!/usr/bin/python3 -I
    import json, os, signal, sys, threading, time
    here = os.path.dirname(os.path.abspath(__file__))
    argv = sys.argv[1:]
    lock = threading.Lock()
    def log(**k):
        k["pid"] = os.getpid()
        with lock, open(os.path.join(here, "codex.jsonl"), "a") as f: f.write(json.dumps(k) + "\n")
    def send(o):
        with lock:
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    if argv[:1] == ["--version"]: print("codex-cli 0.169.0"); sys.exit(0)
    if argv[:2] == ["login", "status"]: print("Logged in using ChatGPT"); sys.exit(0)
    if argv[:1] == ["exec"]:
        prompt = sys.stdin.read()
        log(kind="exec", argv=argv, prompt=prompt)
        tid = ("exec-new-%d" if "resume" in argv else "exec-%d") % os.getpid()
        for e in [{"type": "thread.started", "thread_id": tid}, {"type": "turn.started"},
                  {"type": "item.completed", "item": {"id": "r1", "type": "reasoning", "text": "Checking the fixture."}},
                  {"type": "item.completed", "item": {"id": "m1", "type": "agent_message", "text": "echo: " + prompt}},
                  {"type": "turn.completed", "usage": {"input_tokens": 7, "output_tokens": 3}}]:
            send(e)
        sys.exit(0)
    if argv[:1] != ["app-server"] or "generate-json-schema" in argv: sys.exit(1)
    cwds, working = {}, {}
    def write_late(cwd):
        time.sleep(0.3)
        with open(os.path.join(cwd, "late.txt"), "w") as f: f.write("written after Stop\n")
    def on_term(*_):
        for cwd in list(working.values()): write_late(cwd)
        working.clear()
        os._exit(0)
    signal.signal(signal.SIGTERM, on_term)
    def notify(method, params): send({"method": method, "params": params})
    for line in sys.stdin:
        msg = json.loads(line)
        method, p, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
        if mid is None: continue
        def ok(r): send({"id": mid, "result": r})
        if method == "initialize": ok({"userAgent": "fake/0.169.0"})
        elif method == "config/read":
            routed = {"model_provider": "custom", "model": "gpt-own"} if os.path.basename(sys.argv[0]).endswith("override") else {}
            layers = [{"name": {"type": "user", "file": here + "/config.toml"}, "config": routed}] if routed else []
            ok({"config": routed, "layers": layers})
        elif method in ("thread/start", "thread/resume"):
            cfg = p.get("config") or {}
            cwd = p.get("cwd", "")
            tid = p.get("threadId") or "thr-%d-%d" % (os.getpid(), len(cwds))
            cwds[tid] = cwd
            if cfg.get("mcp_servers.serein_browser.command"):
                notify("mcpServer/startupStatus/updated", {"name": "serein_browser", "status": "ready"})
            # The summary as Codex 0.171 gives it: every root the profile writes but cwd.
            files = (cfg.get("permissions." + str(cfg.get("default_permissions"))) or {}).get("filesystem") or {}
            writes = sorted(os.path.realpath(k) for k, a in files.items() if k.startswith("/") and (a if isinstance(a, str) else a.get(".")) == "write")
            real = os.path.realpath(cwd)
            sandbox = {"type": "workspaceWrite", "writableRoots": [k for k in writes if k != real], "networkAccess": True,
                       "excludeTmpdirEnvVar": real in writes, "excludeSlashTmp": True} if writes else {"type": "readOnly", "networkAccess": True}
            ok({"thread": {"id": tid}, "approvalPolicy": p.get("approvalPolicy"), "approvalsReviewer": p.get("approvalsReviewer"),
                "cwd": cwd, "activePermissionProfile": {"id": cfg.get("default_permissions")}, "sandbox": sandbox})
        elif method == "mcpServerStatus/list": ok({"data": [], "nextCursor": None})
        elif method == "experimentalFeature/list": ok({"data": [{"name": "shell_tool", "enabled": False}], "nextCursor": None})
        elif method == "turn/start":
            tid = p["threadId"]
            ok({"turn": {"id": "turn-1", "status": "inProgress"}})
            notify("turn/started", {"threadId": tid, "turn": {"id": "turn-1", "status": "inProgress"}})
            notify("item/agentMessage/delta", {"threadId": tid, "turnId": "turn-1", "itemId": "m1", "delta": "working"})
            working[tid] = cwds.get(tid) or os.getcwd()
        elif method == "turn/interrupt": ok({})
        else: send({"id": mid, "error": {"code": -32601, "message": "unknown method " + str(method)}})
    # Stop closes input first: a working turn writes on its way out.
    on_term()
    """#
}

private extension Optional {
  func required(_ why: String) throws -> Wrapped {
    guard let self else { throw SereinError.invalid("FAIL: " + why) }
    return self
  }
}
#endif
