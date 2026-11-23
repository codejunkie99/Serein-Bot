#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// The Codex driver through `Engines`, against a fake `codex` that speaks the app-server and
/// `codex exec --json` wire. No model, no network.
extension SmokeTest {
  static func codexDriver(dir: URL) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let fm = FileManager.default
    let root = dir.appendingPathComponent("codex-driver", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let badMode = root.appendingPathComponent("badmode", isDirectory: true)
    let configured = root.appendingPathComponent("configured", isDirectory: true)
    // A repository root, so project rules and config are looked for no higher than here.
    for folder in [home, codexHome, project, badMode, configured.appendingPathComponent(".codex"), root.appendingPathComponent(".git")] {
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try Data("model = \"x\"\n".utf8).write(to: configured.appendingPathComponent(".codex/config.toml"))
    let codex = root.appendingPathComponent("codex")
    let overriding = root.appendingPathComponent("codex-override")
    let spawning = root.appendingPathComponent("codex-child")
    for url in [codex, overriding, spawning] {
      try fakeCodex.write(to: url, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let log = root.appendingPathComponent("codex.jsonl")
    func logged() -> [[String: Any]] {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    }
    func rpc(_ method: String) -> [[String: Any]] { logged().filter { $0["method"] as? String == method } }
    func waitFor(_ seconds: Double = 15, _ condition: () -> Bool) async throws {
      for _ in 0..<Int(seconds * 10) where !condition() { try await Task.sleep(nanoseconds: 100_000_000) }
    }

    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = codexHome.path
    let driver = CodexDriver(inherited: environment, home: home.path)
    let runs = root.appendingPathComponent("runs", isDirectory: true)
    let records = RunRecords(root: runs, tag: "codex-check-" + UUID().uuidString.prefix(8))
    let engines = Engines(drivers: [driver], host: SereinProcessHost(records: records), records: records)
    defer { Task { await engines.shutdown() } }
    let browser = BrowserServer(command: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["--serve"], tools: ["page_read", "update", "agent_sign_in"])

    func request(
      _ thread: String, _ access: Access, message: String = "hi", resume: String? = nil, recovery: String? = nil,
      executable: URL? = nil, browser: BrowserServer? = nil, schema: String? = nil
    ) -> TurnRequest {
      TurnRequest(
        thread: ThreadKey(thread), cli: .codex, executable: executable ?? codex, access: access,
        prompt: TurnPrompt(stable: "STABLE-RULES", volatile: "now: 9:00", message: message, recovery: recovery),
        model: nil, effort: nil, resume: resume, browser: browser, taskID: "task", schema: schema)
    }
    func collect(_ handle: TurnHandle, seconds: Double = 20) async -> [EngineEvent] {
      await withTaskGroup(of: [EngineEvent]?.self) { group in
        group.addTask {
          var events: [EngineEvent] = []
          for await event in handle.events { events.append(event) }
          return events
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(seconds))
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
      }
    }
    func end(_ events: [EngineEvent]) -> StopReason? {
      for case .ended(let end) in events { return end.stopReason }
      return nil
    }
    func text(_ events: [EngineEvent]) -> String {
      events.reduce("") { if case .text(let part) = $1 { return $0 + part }; return $0 }
    }
    func sessions(_ events: [EngineEvent]) -> [(String, Bool)] {
      events.compactMap { if case .session(let id, let rebuilt) = $0 { return (id, rebuilt) }; return nil }
    }
    func usage(_ events: [EngineEvent]) -> [EngineEvent] {
      events.filter { if case .usage = $0 { return true }; return false }
    }

    // Pure pieces: typed failures and the read-back.
    let failures: [(String, JSON?, StopReason)] = [
      ("Your input exceeds the context window", .string("contextWindowExceeded"), .maxTokens),
      ("You've hit your usage limit. Try again at 5:23 PM.", .string("usageLimitExceeded"), .usageLimit("You've hit your usage limit. Try again at 5:23 PM.")),
      ("unexpected status 401", .object(["responseStreamDisconnected": .object(["httpStatusCode": .number(401)])]), .signIn("unexpected status 401")),
      ("Incorrect API key provided", .string("unauthorized"), .keyFailure("Incorrect API key provided")),
      ("The model `gpt-9` does not exist: model not found", nil, .modelRejected("The model `gpt-9` does not exist: model not found")),
      ("error sending request: connection refused", .object(["httpConnectionFailed": .object(["httpStatusCode": .null])]), .offline("error sending request: connection refused")),
      ("something else", .string("other"), .failed("something else")),
    ]
    for (message, info, expected) in failures {
      try check(CodexFailure.reason(message, info: info) == expected, "Codex's \(info?.string ?? info?.object?.keys.first ?? "plain") failure ends the turn as \(expected)")
    }
    let profiled: [String: Any] = [
      "thread": ["id": "t"], "approvalPolicy": "never", "approvalsReviewer": "user", "cwd": "/tmp/p",
      "activePermissionProfile": ["id": CodexDriver.profile],
      "sandbox": ["type": "workspaceWrite", "writableRoots": ["/private/tmp/p"], "networkAccess": true],
    ]
    try check(
      CodexChecks.threadProblem(profiled, writable: true, approvalPolicy: "never", profile: CodexDriver.profile) == nil,
      "Network on is accepted under Serein's profile, and /private/tmp roots match a /tmp cwd")
    try check(
      CodexChecks.threadProblem(profiled, writable: true, approvalPolicy: "never") != nil,
      "Network on without Serein's profile is refused")
    var other = profiled
    other["activePermissionProfile"] = ["id": "dangerFullAccess"]
    try check(
      CodexChecks.threadProblem(other, writable: true, approvalPolicy: "never", profile: CodexDriver.profile) != nil,
      "Another permissions profile is refused")

    // Probe reads version, sign-in and the person's config layers once.
    try check(await engines.probe(.codex, executable: codex) == .ready(version: "0.169.0"), "The probe reads 0.169.0 and a signed-in Codex")
    try check(rpc("config/read").count == 1, "The probe reads Codex's config layers once from a short-lived app server")

    // Start, handshake, read-back, a streamed turn.
    let t1 = request("t1", .project(folder: project, level: .full), browser: browser)
    let contract = try driver.contract(for: t1, network: .open)
    try check(contract.arguments.first == "app-server", "A Full project turn runs on the app server")
    try check(
      !contract.argv.joined(separator: " ").contains("STABLE-RULES") && !contract.argv.joined(separator: " ").contains("hi"),
      "No prompt text is on argv")
    let first = await collect(try await engines.send(t1))
    try check(end(first) == .endTurn && text(first) == "hello world", "A streamed turn ends endTurn with its text")
    try check(first.first.map { if case .session = $0 { return true }; return false } == true, "The session event comes before any text")
    let start = rpc("thread/start").first?["params"] as? [String: Any] ?? [:]
    let config = start["config"] as? [String: Any] ?? [:]
    try check(start["sandbox"] == nil && start["approvalPolicy"] as? String == "never", "thread/start sends approval never and no sandbox")
    try check(start["developerInstructions"] as? String == "STABLE-RULES", "The stable prompt goes as developer instructions")
    try check(
      config["default_permissions"] as? String == CodexDriver.profile
        && ((config["permissions.\(CodexDriver.profile)"] as? [String: Any])?["network"] as? [String: Any])?["enabled"] as? Bool == true,
      "The thread carries Serein's profile, with the shell's network open")
    let fileRules = ((config["permissions.\(CodexDriver.profile)"] as? [String: Any])?["filesystem"] as? [String: Any]) ?? [:]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
    let schemas = CodexDriver.schemaFile("").deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    try check(
      fileRules[tmp] as? String == "write" && fileRules[schemas] as? String == "read"
        && fileRules[FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gitconfig").path] as? String == "read",
      "Codex's shell writes TMPDIR and reads git's config, but Serein's own temp files stay read-only")
    let prefix = "mcp_servers.\(CodexParams.browserServer)."
    try check(
      config[prefix + "tool_timeout_sec"] as? Int == 900 && config[prefix + "tools.page_read.approval_mode"] as? String == "approve"
        && config[prefix + "tools.update.approval_mode"] as? String == "approve"
        && config[prefix + "tools.agent_sign_in.approval_mode"] as? String == "approve"
        && config[prefix + "tools.unadvertised.approval_mode"] == nil,
      "Codex admits the advertised tools, including settings, to Serein’s approval gate for up to 900 s")
    let firstInput = ((rpc("turn/start").first?["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String
    try check(firstInput == "now: 9:00\n\nhi", "The turn sends the volatile part and the message only")
    try check(usage(first) == [.usage(input: 100, output: 10, cachedInput: 5)], "The turn reports its token usage")

    // Warm reuse.
    let second = await collect(try await engines.send(request("t1", .project(folder: project, level: .full), message: "again", browser: browser)))
    try check(end(second) == .endTurn && rpc("thread/start").count == 1, "The second turn reuses the warm thread")
    try check(Set(rpc("turn/start").compactMap { $0["pid"] as? Int }).count == 1, "Both turns ran in one app-server process")
    try check(usage(second) == [.usage(input: 100, output: 10, cachedInput: 5)], "Usage is the turn's own, not the thread's total")

    // max_tokens.
    let cut = await collect(try await engines.send(request("t1", .project(folder: project, level: .full), message: "MAXTOK", browser: browser)))
    try check(end(cut) == .maxTokens, "A context-window end reads as max tokens")

    let fakeCarded = await collect(try await engines.send(request("t1", .project(folder: project, level: .full), message: "FAKECARD", browser: browser)))
    try check(end(fakeCarded) == .endTurn && fakeCarded.contains(.toolEnded(id: "k1", result: .ok)),
      "Page text that quotes the card's reply never parks a Codex turn")

    // Steer.
    let steering = try await engines.send(request("t1", .project(folder: project, level: .full), message: "STEER", browser: browser))
    let steered = Task { await collect(steering) }
    var outcome = SteerOutcome.refused
    for _ in 0..<100 where outcome != .steered {
      try await Task.sleep(nanoseconds: 100_000_000)
      if !rpc("turn/start").filter({ (($0["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String == "now: 9:00\n\nSTEER" }).isEmpty {
        outcome = await engines.steer(ThreadKey("t1"), "more")
      }
    }
    let steerEvents = await steered.value
    let steer = rpc("turn/steer").first?["params"] as? [String: Any] ?? [:]
    try check(outcome == .steered && end(steerEvents) == .endTurn, "Steer reaches the running turn and it ends normally")
    try check(steer["expectedTurnId"] as? String != nil && steer["threadId"] as? String != nil, "turn/steer names the thread and the running turn")

    // Stop ends the process group.
    let hanging = try await engines.send(request("t1", .project(folder: project, level: .full), message: "HANG", browser: browser))
    let hung = Task { await collect(hanging) }
    try await waitFor { logged().contains { $0["kind"] as? String == "child" } }
    let child = logged().first { $0["kind"] as? String == "child" }
    let childPID = pid_t(child?["child"] as? Int ?? 0)
    let group = pid_t(child?["pid"] as? Int ?? 0)
    await engines.stop(ThreadKey("t1"))
    let stopped = await hung.value
    try await waitFor(8) { kill(childPID, 0) != 0 && kill(-group, 0) != 0 }
    try check(end(stopped) == .stopped && childPID > 0 && kill(childPID, 0) != 0 && kill(-group, 0) != 0, "Stop ends the turn and the app server's whole process group"
        + " [end=\(String(describing: end(stopped))) child=\(childPID) alive=\(kill(childPID, 0) == 0) group=\(group) groupAlive=\(kill(-group, 0) == 0)]")

    // Retry before accept only.
    let retried = await collect(try await engines.send(request("t2", .project(folder: project, level: .edits), message: "FAILONCE")), seconds: 30)
    let retries = retried.filter { if case .retrying = $0 { return true }; return false }
    try check(retries.count == 1 && end(retried) == .endTurn, "A 503 before accept relaunches and replays once")
    let after = await collect(try await engines.send(request("t2", .project(folder: project, level: .edits), message: "FAILAFTER")))
    try check(
      after.allSatisfy { if case .retrying = $0 { return false }; return true } && end(after).map { if case .failed = $0 { return true }; return false } == true,
      "A failure after accept never replays")

    // Read-back refused.
    let refused = await collect(try await engines.send(request("t3", .project(folder: badMode, level: .edits))))
    try check(
      end(refused) == .modeMismatch(name: "activePermissionProfile.id", expected: CodexDriver.profile, reported: nil)
        && !rpc("turn/start").contains { (($0["params"] as? [String: Any])?["threadId"] as? String ?? "").contains("badmode") },
      "A thread that reports no Serein profile is refused before any prompt")

    // Resume, and a gone thread rebuilt from the recovery text.
    let resumed = await collect(try await engines.send(request("t4", .project(folder: project, level: .edits), resume: "kept")))
    try check(end(resumed) == .endTurn && sessions(resumed).first.map { $0 == ("kept", false) } == true, "Resume continues the saved thread")
    let rebuilt = await collect(try await engines.send(request("t5", .project(folder: project, level: .edits), resume: "gone", recovery: "RECOVERY")))
    let rebuiltInput = ((rpc("turn/start").last?["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String
    try check(
      end(rebuilt) == .endTurn && sessions(rebuilt).first?.1 == true && rebuiltInput == "now: 9:00\n\nRECOVERY",
      "A thread Codex lost starts again from the recovery text")

    // Pure answer: ephemeral, with a schema.
    let answer = try await engines.ask(request("t6", .answer, schema: #"{"type":"object"}"#))
    let answerStart = rpc("thread/start").last?["params"] as? [String: Any] ?? [:]
    let answerTurn = rpc("turn/start").last?["params"] as? [String: Any] ?? [:]
    try check(
      answer == "hello world" && answerStart["ephemeral"] as? Bool == true && answerTurn["outputSchema"] != nil
        && ((answerStart["config"] as? [String: Any])?["features.shell_tool"] as? Bool) == false,
      "A pure answer runs on an ephemeral thread with no shell and its reply schema")

    // exec: own setup, a project config, and a user config that overrides Serein's.
    let own = request("t7", .ownSetup(folder: project))
    let ownArgv = try driver.contract(for: own, network: .open).argv
    try check(ownArgv.first == "exec" && !ownArgv.contains("--ignore-user-config") && ownArgv.contains("--ignore-rules"), "Own setup runs codex exec with the person's config, without rules")
    let ownEvents = await collect(try await engines.send(own))
    let execPrompt = logged().last { $0["kind"] as? String == "exec" }?["prompt"] as? String ?? ""
    try check(
      end(ownEvents) == .endTurn && text(ownEvents) == "exec says hi" && sessions(ownEvents).first?.0 == "exec-thread"
        && usage(ownEvents) == [.usage(input: 7, output: 3, cachedInput: 1)],
      "An exec turn streams its answer, session and usage")
    try check(execPrompt.hasPrefix("STABLE-RULES\n\nnow: 9:00\n\nhi"), "exec gets the prompt on stdin, never on argv")
    try check(await engines.steer(ThreadKey("t7"), "late") == .handedBack("late"), "Words for an exec turn are handed back")
    let projectArgv = try driver.contract(for: request("t8", .project(folder: configured, level: .full)), network: .open).argv
    try check(projectArgv.first == "exec" && projectArgv.contains("--ignore-user-config"), "A folder with its own Codex config runs codex exec without the person's config")
    _ = await engines.probe(.codex, executable: overriding)
    let routed = try driver.contract(for: request("t9", .project(folder: project, level: .edits), executable: overriding), network: .open)
    try check(routed.arguments.first == "exec", "A user config that overrides Serein's routes Codex to exec, as on main")
    try check(
      routed.argv.joined(separator: " ").contains("-c model_provider=\"custom\"") && routed.argv.joined(separator: " ").contains("-c model=\"gpt-own\""),
      "exec keeps the user config's model provider and model, which --ignore-user-config drops")
    let ownRouted = try driver.contract(for: request("t9", .ownSetup(folder: project), executable: overriding), network: .open)
    try check(!ownRouted.argv.contains("model_provider=\"custom\""), "Own setup reads the person's config itself, so no routing goes on argv")
    try FileManager.default.createDirectory(at: codexHome.appendingPathComponent("rules"), withIntermediateDirectories: true)
    try Data("prefix_rule(pattern=[\"ls\"], decision=\"allow\")\n".utf8).write(to: codexHome.appendingPathComponent("rules/default.rules"))
    let ruled = try driver.contract(for: request("t10", .project(folder: project, level: .full)), network: .open)
    let ruledEdits = try driver.contract(for: request("t10", .project(folder: project, level: .edits)), network: .open)
    try check(ruled.arguments.first == "exec" && ruledEdits.arguments.first == "app-server", "Exec-policy rules send shell turns to exec; a turn with no shell stays on the app server")

    // The config verdict follows the person's config.
    let changingHome = root.appendingPathComponent("codex-home-changing", isDirectory: true)
    let managedHome = root.appendingPathComponent("codex-home-managed", isDirectory: true)
    for folder in [changingHome, managedHome] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    var changingEnvironment = environment
    changingEnvironment["CODEX_HOME"] = changingHome.path
    let changing = CodexDriver(inherited: changingEnvironment, home: home.path)
    _ = await changing.probe(executable: codex)
    let changingBefore = try changing.contract(for: request("t15", .project(folder: project, level: .edits)), network: .open)
    try Data("model_provider = \"custom\"\n".utf8).write(to: changingHome.appendingPathComponent("config.toml"))
    let changingAfter = try changing.contract(for: request("t15", .project(folder: project, level: .edits)), network: .open)
    try check(
      changingBefore.arguments.first == "app-server" && changingAfter.arguments.first == "exec",
      "A config.toml changed after the probe routes the next turn to exec")
    var managedEnvironment = environment
    managedEnvironment["CODEX_HOME"] = managedHome.path
    let managed = CodexDriver(inherited: managedEnvironment, home: home.path)
    let managedRuns = RunRecords(root: runs, tag: "codex-check-" + UUID().uuidString.prefix(8))
    let managedEngines = Engines(drivers: [managed], host: SereinProcessHost(records: managedRuns), records: managedRuns)
    _ = await managedEngines.probe(.codex, executable: codex)
    try Data("model_provider = \"custom\"\n".utf8).write(to: managedHome.appendingPathComponent("managed_config.toml"))
    let refusedOpen = await collect(try await managedEngines.send(request("t16", .project(folder: project, level: .edits))))
    let managedAfter = try managed.contract(for: request("t16", .project(folder: project, level: .edits)), network: .open)
    await managedEngines.shutdown()
    try check(
      end(refusedOpen).map { if case .failed = $0 { return true }; return false } == true && managedAfter.arguments.first == "exec",
      "A config problem the app server finds at open routes the next turn to exec")

    // A warm thread whose profile or browser would differ starts again.
    let warmStarts = rpc("thread/start").count
    _ = await collect(try await engines.send(request("t11", .project(folder: project, level: .edits), browser: browser)))
    let otherBrowser = BrowserServer(command: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["--serve"], tools: ["page_read", "page_click"])
    _ = await collect(try await engines.send(request("t11", .project(folder: project, level: .edits), browser: otherBrowser)))
    var attached = request("t11", .project(folder: project, level: .edits), browser: otherBrowser)
    attached.attachments = [configured]
    _ = await collect(try await engines.send(attached))
    try check(rpc("thread/start").count == warmStarts + 3, "A changed browser or attachment starts a new thread, never the warm one")

    // turn/start fails closed while Codex's turn/started still waits to be read: the turn stays announced, so never replayed.
    let closedRPC = JSONRPC(EngineProcess(ClosedCodex()))
    let closedThread = CodexThread(rpc: closedRPC, folder: project.path)
    await closedThread.opened(id: "closed-thread", rebuilt: false)
    let closedSession = CodexAppSession(
      mode: try ModeCheck.verify(.nothing(flagOnArgv: ["exec"]), reported: [:], argv: ["exec"]).get(), rpc: closedRPC,
      thread: closedThread, approvalPolicy: "never")
    try await closedSession.send(TurnPrompt(stable: "", volatile: "", message: "hi", recovery: nil), request: request("t13", .project(folder: project, level: .edits)))
    await closedThread.receive(.notification(method: "turn/started", params: .object(["threadId": .string("closed-thread"), "turn": .object(["id": .string("turn-x")])])))
    await closedThread.closed()
    var announced = false
    for await event in closedSession.wire { if case .accepted = event { announced = true } }
    try check(announced, "A turn/started read after turn/start failed closed still announces the turn, so it is never replayed")

    // The preflight app server's whole group ends with it, a child that ignores TERM included.
    _ = await CodexDriver(inherited: environment, home: home.path).probe(executable: spawning)
    let preflightChild = logged().first { $0["kind"] as? String == "preflight-child" }
    let preflightPID = pid_t(preflightChild?["child"] as? Int ?? 0)
    try await waitFor(6) { kill(preflightPID, 0) != 0 }
    try check(
      preflightPID > 0 && kill(preflightPID, 0) != 0 && preflightChild?["pgid"] as? Int == preflightChild?["pid"] as? Int,
      "The preflight app server leads its own group and leaves no child behind, one that ignores TERM included")

    // exec writes its schema file every time and has its empty folder.
    let schema = #"{"type":"object","title":"exec"}"#
    let schemaFile = CodexDriver.schemaFile(schema)
    try fm.createDirectory(at: schemaFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: schemaFile)
    try? fm.removeItem(at: CodexDriver.emptyFolder)
    let ephemeral = await collect(try await engines.send(request("t14", .answer, executable: overriding, schema: schema)))
    try check(
      (try? String(contentsOf: schemaFile, encoding: .utf8)) == schema && fm.fileExists(atPath: CodexDriver.emptyFolder.path),
      "An exec turn rewrites its schema file and creates its empty folder")
    try check(
      end(ephemeral) == .endTurn && sessions(ephemeral).isEmpty,
      "An ephemeral exec answer reports no session, so the next turn never resumes a thread Codex did not save")

    // Codex's shells find programs: Codex's core variables (PATH, HOME, TMPDIR) pass, secret names stay out.
    let execConfigs = Set(zip(routed.argv, routed.argv.dropFirst()).filter { $0.0 == "-c" }.map(\.1))
    let serverConfigs = Set(zip(driver.serverArguments(nil), driver.serverArguments(nil).dropFirst()).filter { $0.0 == "-c" }.map(\.1))
    try check(
      [execConfigs, serverConfigs].allSatisfy {
        $0.contains("shell_environment_policy.inherit=\"core\"") && $0.contains("shell_environment_policy.ignore_default_excludes=false")
      },
      "Codex's shells inherit its core variables, PATH included, and drop secret names")

    await engines.shutdown()
    try? fm.removeItem(at: root)
    if let live = ProcessInfo.processInfo.environment["SEREIN_CODEX_LIVE"] { try await codexLive(check, codex: URL(fileURLWithPath: live)) }
    return results
  }

  /// One real `codex exec` turn at low effort, under a Codex home holding a copy of this Mac's
  /// config and sign-in, so nothing is written to ~/.codex: the config's routing reaches exec's argv.
  private static func codexLive(_ check: (Bool, String) throws -> Void, codex: URL) async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("codex-live-" + UUID().uuidString.prefix(8), isDirectory: true)
    let codexHome = dir.appendingPathComponent("codex-home", isDirectory: true)
    let folder = dir.appendingPathComponent("folder", isDirectory: true)
    for url in [codexHome, folder] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    defer { try? fm.removeItem(at: dir) }
    let own = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    for name in ["config.toml", "auth.json"] {
      try fm.copyItem(at: own.appendingPathComponent(name), to: codexHome.appendingPathComponent(name))
    }
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = codexHome.path
    let driver = CodexDriver(inherited: environment)
    _ = await driver.probe(executable: codex)
    let routing = CodexRouting.arguments(CodexPreflight.shared.verdict(for: driver, executable: codex)?.routing ?? [:])
    let request = TurnRequest(
      thread: ThreadKey("codex-live"), cli: .codex, executable: codex, access: .project(folder: folder, level: .review),
      prompt: TurnPrompt(stable: "Answer in three words.", volatile: "", message: "say hi", recovery: nil), model: nil,
      effort: "low", resume: nil, browser: nil, taskID: "codex-live")
    let argv = try driver.contract(for: request, network: .open).arguments
    let configs = Set(zip(argv, argv.dropFirst()).filter { $0.0 == "-c" }.map(\.1))
    print("Codex live: routing keys \(routing.map { $0.split(separator: "=")[0] })")
    try check(
      argv.first == "exec" && argv.contains("--ignore-user-config") && !routing.isEmpty && routing.allSatisfy(configs.contains),
      "Live: this Mac's Codex routing goes on exec's argv")
    let records = RunRecords(root: dir.appendingPathComponent("runs", isDirectory: true), tag: "codex-live")
    let engines = Engines(drivers: [driver], host: SereinProcessHost(records: records), records: records)
    func run(_ request: TurnRequest) async throws -> (reply: String, ended: Bool, session: String?) {
      var events: [EngineEvent] = []
      for await event in try await engines.send(request).events { events.append(event) }
      let reply = events.reduce("") { if case .text(let part) = $1 { return $0 + part }; return $0 }
      print("Codex live \(request.access): reply \(reply.prefix(700).debugDescription), end \(events.last.map { "\($0)" }?.prefix(200) ?? "none")")
      let ended = { if case .ended(let end) = events.last { return end.stopReason == .endTurn } else { return false } }()
      let session = events.lazy.compactMap { if case .session(let id, _) = $0 { return id }; return nil }.first
      return (reply, ended && !reply.isEmpty, session)
    }
    try check(try await run(request).ended, "Live: Codex exec answers with that routing")

    // Two Answer turns on one thread, the second given what the first reported, as the app does.
    var answer = request
    answer.thread = ThreadKey("codex-live-answer")
    answer.access = .answer
    let first = try await run(answer)
    answer.resume = first.session
    answer.prompt.message = "say bye"
    let second = try await run(answer)
    try check(first.ended && second.ended, "Live: a second Answer turn on the same thread answers")

    var commands = request
    commands.thread = ThreadKey("codex-live-commands")
    commands.access = .project(folder: folder, level: .commands)
    commands.prompt = TurnPrompt(
      stable: "Run shell commands when asked and reply with their output only.", volatile: "",
      message: "Run `which git && uname -s`.", recovery: nil)
    let shell = try await run(commands)
    try check(shell.ended && shell.reply.contains("/git") && shell.reply.contains("Darwin"), "Live: a Commands turn's shell finds programs on its PATH")
    await engines.shutdown()
  }

  /// A Codex whose stdout is already closed.
  private final class ClosedCodex: HostedProcess, @unchecked Sendable {
    let pgid: pid_t = 0
    let output = AsyncStream<Data> { $0.finish() }
    func write(_ data: Data) throws {}
    func closeInput() {}
    func signalGroup(_ signal: Int32) {}
    var groupAlive: Bool { false }
    func exited() async -> ProcessExit { ProcessExit(status: 0, signaled: false, stderr: "") }
  }

  /// A fake `codex`: --version, login status, the app server and `exec --json`, logging what it got.
  static let fakeCodex = #"""
#!/usr/bin/python3 -I
import json, os, subprocess, sys, threading
here = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(here, "codex.jsonl")
lock = threading.Lock()
def log(**k):
    k["pid"] = os.getpid()
    with lock, open(LOG, "a") as f: f.write(json.dumps(k) + "\n")
def send(o):
    with lock:
        sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
argv = sys.argv[1:]
if argv[:1] == ["--version"]: print("codex-cli 0.169.0"); sys.exit(0)
if argv[:2] == ["login", "status"]: print("Logged in using ChatGPT"); sys.exit(0)
log(kind="start", argv=argv, cwd=os.getcwd())
if argv[:1] == ["exec"]:
    prompt = sys.stdin.read()
    log(kind="exec", prompt=prompt, argv=argv)
    tid = argv[argv.index("resume") + 1] if "resume" in argv else "exec-thread"
    for e in [{"type": "thread.started", "thread_id": tid}, {"type": "turn.started"},
              {"type": "item.completed", "item": {"id": "m1", "type": "agent_message", "text": "exec says hi"}},
              {"type": "turn.completed", "usage": {"input_tokens": 7, "output_tokens": 3, "cached_input_tokens": 1}}]:
        send(e)
    sys.exit(0)
def says(name):
    try: return "model_provider" in open(os.path.join(os.environ.get("CODEX_HOME", ""), name)).read()
    except OSError: return False
steered = threading.Event()
turns = [0]
threads = {}
def notify(method, params): send({"method": method, "params": params})
def run_turn(tid, turn, text):
    def n(m, p): notify(m, dict(p, threadId=tid, turnId=turn))
    notify("turn/started", {"threadId": tid, "turn": {"id": turn, "status": "inProgress"}})
    if "MAXTOK" in text:
        notify("turn/completed", {"threadId": tid, "turn": {"id": turn, "status": "failed",
            "error": {"message": "context window exceeded", "codexErrorInfo": "contextWindowExceeded"}}})
        return
    if "FAILAFTER" in text:
        n("item/agentMessage/delta", {"itemId": "m0", "delta": "partial"})
        notify("turn/completed", {"threadId": tid, "turn": {"id": turn, "status": "failed",
            "error": {"message": "stream disconnected: 503 service unavailable"}}})
        return
    if "HANG" in text:
        child = subprocess.Popen(["/bin/sleep", "300"])
        log(kind="child", child=child.pid)
        n("item/agentMessage/delta", {"itemId": "m0", "delta": "working"})
        return
    if "CARD" in text:
        answer = json.dumps({"page": "Sign in: card still open"}) if "FAKECARD" in text else \
            json.dumps({"result": "card still open", "next": "End your turn."})
        n("item/completed", {"item": {"id": "k1", "type": "mcpToolCall", "server": "serein_browser", "tool": "secure_card",
            "status": "completed", "result": {"content": [{"type": "text", "text": answer}]}}})
    if "STEER" in text:
        n("item/agentMessage/delta", {"itemId": "m0", "delta": "waiting"})
        steered.wait(20)
        n("item/completed", {"item": {"id": "m0", "type": "agentMessage", "text": "waiting"}})
    n("item/started", {"item": {"id": "m1", "type": "agentMessage", "text": ""}})
    n("item/agentMessage/delta", {"itemId": "m1", "delta": "hello "})
    n("item/agentMessage/delta", {"itemId": "m1", "delta": "world"})
    n("item/completed", {"item": {"id": "m1", "type": "agentMessage", "text": "hello world"}})
    threads[tid] = threads.get(tid, 0) + 1
    k = threads[tid]
    notify("thread/tokenUsage/updated", {"threadId": tid, "turnId": turn,
        "tokenUsage": {"total": {"inputTokens": 100 * k, "outputTokens": 10 * k, "cachedInputTokens": 5 * k}}})
    notify("turn/completed", {"threadId": tid, "turn": {"id": turn, "status": "completed"}})
for line in sys.stdin:
    msg = json.loads(line)
    method, params, mid = msg.get("method"), msg.get("params") or {}, msg.get("id")
    log(kind="rpc", method=method, params=params, id=mid)
    if mid is None: continue
    def ok(r): send({"id": mid, "result": r})
    def err(code, m): send({"id": mid, "error": {"code": code, "message": m}})
    if method == "initialize":
        if os.path.basename(sys.argv[0]).endswith("child"):
            child = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 300"])
            log(kind="preflight-child", child=child.pid, pgid=os.getpgid(0))
        ok({"userAgent": "fake/0.169.0"})
    elif method == "config/read":
        routed = {"model_provider": "custom", "model": "gpt-own"} if os.path.basename(sys.argv[0]).endswith("override") or says("config.toml") or says("managed_config.toml") else {}
        layers = [{"name": {"type": "user", "file": here + "/config.toml"}, "config": routed}] if routed else []
        ok({"config": routed, "layers": layers})
    elif method in ("thread/start", "thread/resume"):
        if method == "thread/resume" and params.get("threadId") == "gone":
            err(-32600, "no rollout found for thread id gone"); continue
        cfg = params.get("config") or {}
        cwd = params.get("cwd", "")
        tid = params.get("threadId") or ("thr-" + os.path.basename(cwd) + "-" + str(os.getpid()))
        if cfg.get("mcp_servers.serein_browser.command"):
            notify("mcpServer/startupStatus/updated", {"name": "serein_browser", "status": "ready"})
        profile = None if "badmode" in cwd else {"id": cfg.get("default_permissions")}
        ok({"thread": {"id": tid}, "approvalPolicy": params.get("approvalPolicy"), "approvalsReviewer": params.get("approvalsReviewer"),
            "cwd": cwd, "activePermissionProfile": profile,
            "sandbox": {"type": "readOnly", "writableRoots": [], "networkAccess": False}})
    elif method == "mcpServerStatus/list": ok({"data": [], "nextCursor": None})
    elif method == "experimentalFeature/list":
        ok({"data": [{"name": "shell_tool", "enabled": False}], "nextCursor": None})
    elif method == "turn/start":
        text = params["input"][0]["text"]
        marker = os.path.join(here, "failed-once")
        if "FAILONCE" in text and not os.path.exists(marker):
            open(marker, "w").close()
            err(-32000, "stream disconnected: 503 service unavailable"); continue
        turns[0] += 1
        turn = "turn-%d" % turns[0]
        ok({"turn": {"id": turn, "status": "inProgress"}})
        threading.Thread(target=run_turn, args=(params["threadId"], turn, text), daemon=True).start()
    elif method == "turn/steer":
        ok({"turnId": params.get("expectedTurnId")}); steered.set()
    else: err(-32601, "unknown method " + str(method))
"""#
}
#endif
