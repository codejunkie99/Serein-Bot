#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The engine core with fakes: no CLI, no sleep.
extension AssistantCoreChecks {
  static func engines(_ check: Check) throws {
    try engineTypes(check)
    try engineContract(check)
    try engineFraming(check)
    try engineMachine(check)
    try engineTurns(check)
    try engineRunRecords(check)
    try engineSigterm(check)
    try claudeDriver(check)
    try enginesPi(check)
    try engineFileGuard(check)
    try grokACPFixes(check)
    try engineRoom(check)
    try engineACPGuard(check)
    try bridge(check)
    try engineCore(check)
    try cutover(check)
    try cutoverCodex(check)
    try enginePayGuard(check)
    try enginePayProxy(check)
    try engineShellGuard(check)
    try engineSecrets(check)
  }

  private static func engineTypes(_ check: Check) throws {
    let outcomes: [(StopReason, Outcome)] = [
      (.endTurn, .completed), (.maxTokens, .cutShort), (.loop(tool: "Read"), .cutShort), (.stuck(seconds: 300), .cutShort),
      (.refusal, .failed), (.modeMismatch(name: "sandbox", expected: "workspace-write", reported: nil), .failed),
      (.signIn("x"), .failed), (.stopped, .stopped), (.declined("x"), .cutShort), (.usageLimit("x"), .failed), (.failed("x"), .failed),
    ]
    for (reason, outcome) in outcomes {
      try check(TurnEnd(reason).outcome == outcome, "A turn that stops on \(reason) reads as \(outcome)")
    }
    try check(TurnEnd(.maxTokens).outcome != .completed, "A max-tokens end is never a success")

    let codex = ExpectedMode.reports(["approvalPolicy": "never", "activePermissionProfile.id": "serein-task"])
    func refused(_ result: Result<VerifiedMode, StopReason>) -> StopReason? {
      if case .failure(let reason) = result { return reason }
      return nil
    }
    try check(
      refused(ModeCheck.verify(codex, reported: ["approvalPolicy": "never", "activePermissionProfile.id": "serein-task"], argv: [])) == nil,
      "Both Codex values back as asked verify")
    try check(
      refused(ModeCheck.verify(codex, reported: ["approvalPolicy": "never", "activePermissionProfile.id": "dangerFullAccess"], argv: []))
        == .modeMismatch(name: "activePermissionProfile.id", expected: "serein-task", reported: "dangerFullAccess"),
      "The user's own profile in place of Serein's refuses and names the value")
    try check(
      refused(ModeCheck.verify(codex, reported: ["activePermissionProfile.id": "serein-task"], argv: []))
        == .modeMismatch(name: "approvalPolicy", expected: "never", reported: nil),
      "A value the CLI left out refuses")
    let flag = ExpectedMode.nothing(flagOnArgv: ["--approval-mode", "yolo"])
    try check(refused(ModeCheck.verify(flag, reported: [:], argv: ["gemini", "--approval-mode", "yolo", "--acp"])) == nil, "A no-report CLI verifies when its flag is on argv")
    try check(refused(ModeCheck.verify(flag, reported: [:], argv: ["gemini", "--approval-mode", "--acp", "yolo"])) != nil, "The flag split apart on argv refuses")
    try check(refused(ModeCheck.verify(.nothing(flagOnArgv: []), reported: [:], argv: ["x"])) != nil, "An empty flag never verifies")

    // VerifiedMode's init is fileprivate; this proves no other file makes one.
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("SereinEngines")
    let makers = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
      .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("VerifiedMode()") == true }
      .map(\.lastPathComponent)
    try check(makers == ["ModeCheck.swift"], "Only ModeCheck makes a VerifiedMode")
  }

  private static func engineContract(_ check: Check) throws {
    let folder = URL(fileURLWithPath: "/tmp/project")
    func request(_ access: Access, stable: String = "rules", volatile: String = "now: 9:00") -> TurnRequest {
      TurnRequest(
        thread: ThreadKey("t1"), cli: .codex, executable: URL(fileURLWithPath: "/usr/local/bin/codex"), access: access,
        prompt: TurnPrompt(stable: stable, volatile: volatile, message: "hi", recovery: nil), model: nil, effort: nil,
        resume: nil, browser: nil, taskID: "task")
    }
    func key(_ request: TurnRequest, resume: [String] = []) -> WarmKey {
      LaunchContract(
        request, arguments: ["app-server"], resumeArguments: resume, environment: ["HOME": "/Users/x"],
        expectedMode: .reports(["sandbox": "workspace-write"]), network: .open
      ).warmKey
    }
    let base = key(request(.project(folder: folder, level: .edits)))
    try check(key(request(.project(folder: folder, level: .full))).changed(from: base) == ["level"], "A level change changes only the level field")
    try check(key(request(.project(folder: folder, level: .edits), stable: "other")).changed(from: base) == ["stablePrompt"], "A new stable prompt changes the key")
    try check(key(request(.project(folder: folder, level: .edits), volatile: "now: 9:05")) == base, "The volatile prompt never changes the key")
    try check(key(request(.project(folder: folder, level: .edits)), resume: ["resume", "abc"]) == base, "Resume arguments never change the key")
    try check(!base.fields.values.contains { $0.contains("rules") || $0.contains("/tmp") }, "The key holds hashes, not values")
    try check(Access.task(folder: folder).level == ProjectLevel.full.rawValue, "A task always runs at Full")

    let env = CredentialEnv.build(
      inherited: ["PATH": "/usr/bin", "OPENAI_API_KEY": "theirs", "ANTHROPIC_API_KEY": "theirs", "CURSOR_AUTH_TOKEN": "t"],
      own: ["ANTHROPIC_API_KEY": "serein"], driver: .opencode)
    try check(env == ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "serein"], "Inherited provider keys are stripped; Serein's own stays")
  }

  private static func engineFraming(_ check: Check) throws {
    var framer = LineFramer()
    let big = Data(repeating: UInt8(ascii: "a"), count: 5 * 1024 * 1024)
    var lines: [Data] = []
    var offset = 0
    while offset < big.count {
      let end = min(offset + 65_536, big.count)
      lines += framer.feed(big[offset..<end])
      offset = end
    }
    try check(lines.isEmpty, "No line comes out before its newline")
    lines += framer.feed(Data("\r\n{\"b\":1}\n{\"c\"".utf8))
    try check(lines.count == 2 && lines[0] == big && lines[1] == Data("{\"b\":1}".utf8), "A 5 MB line split over 80 reads comes out whole")
    try check(framer.finish() == Data("{\"c\"".utf8) && framer.finish() == nil, "The unterminated tail comes out once at the end")
  }

  private static func engineMachine(_ check: Check) throws {
    let facts = Facts(expectedMode: .reports(["approvalPolicy": "never"]), argv: ["app-server"])
    let policy = Policy(random: { 0.5 })
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let prompt = TurnPrompt(stable: "s", volatile: "v", message: "m", recovery: nil)
    let transient = MachineInput.wire(.failed("xAI HTTP 429: Too Many Requests"), at: at)
    let sent = TurnState(prompt: prompt, at: at)

    let (replayed, replayEffects) = Machine.step(.awaitingAccept(sent), transient, facts: facts, policy: policy)
    try check(replayed.name == "retrying" && replayEffects.contains(.scheduleRetry(after: .seconds(1))), "A 429 before accept is replayed after 1 s")
    let (held, heldEffects) = Machine.step(.running(sent), transient, facts: facts, policy: policy)
    try check(held.name == "ready" && heldEffects.contains { if case .emit(.ended) = $0 { return true }; return false }, "A 429 after accept ends the turn, never replayed")
    var risky = sent
    risky.shellRisk = .push
    let (riskyNext, riskyEffects) = Machine.step(.awaitingAccept(risky), transient, facts: facts, policy: policy)
    try check(riskyNext.name == "ready" && !riskyEffects.contains { if case .scheduleRetry = $0 { return true }; return false }, "A turn that ran a push is never replayed")
    let (exitedNext, _) = Machine.step(.awaitingAccept(sent), .exited(.exited(status: 1, stderr: "Internal Server Error")), facts: facts, policy: policy)
    try check(exitedNext.name == "retrying", "A CLI that died with a 500 before accept is replayed")

    let inputs: [MachineInput] = [
      .submit(prompt, at: at), .wire(.text("x"), at: at), .wire(.turnDone(.endTurn), at: at), .exited(.signaled), .retryDue,
      .opened(at: at), .openFailed(.stopped), .tick(at, HarnessStuck.Evidence(cpuPerMinute: 0, openTCP: 0, logGrew: false)),
      .interrupt, .shutdown, .stopped,
    ]
    for input in inputs {
      let (next, effects) = Machine.step(.dead, input, facts: facts, policy: policy)
      try check(next.name == "dead" && effects.isEmpty, "dead absorbs \(String(describing: input).prefix { $0 != "(" })")
    }
    let (stopping, first) = Machine.step(.ready, .shutdown, facts: facts, policy: policy)
    let (again, second) = Machine.step(stopping, .shutdown, facts: facts, policy: policy)
    try check(first == [.runStopLadder(StopLadder.standard)] && again.name == "stopping" && second.isEmpty, "A second shutdown is a no-op")

    let (mismatch, mismatchEffects) = Machine.step(
      .running(sent), .wire(.modeReported(["approvalPolicy": "on-request"]), at: at), facts: facts, policy: policy)
    try check(mismatch.name == "stopping" && mismatchEffects.contains(.runStopLadder(StopLadder.standard)), "A looser mode reported mid-turn ends the process")
  }

  private static func engineTurns(_ check: Check) throws {
    let folder = URL(fileURLWithPath: "/tmp/engine-checks")
    let request = TurnRequest(
      thread: ThreadKey("t"), cli: .codex, executable: URL(fileURLWithPath: "/usr/bin/true"), access: .task(folder: folder),
      prompt: TurnPrompt(stable: "s", volatile: "v", message: "m", recovery: nil), model: nil, effort: nil, resume: nil,
      browser: nil, taskID: "task")
    let records = RunRecords(root: FileManager.default.temporaryDirectory.appendingPathComponent("engine-checks-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: records.root) }
    func run(_ driver: FakeDriver, stopAfterStart: Bool = false) throws -> (events: [EngineEvent], process: FakeHosted?) {
      let host = FakeHost()
      let engines = Engines(drivers: [driver], host: host, records: records, sleep: { _ in await Task.yield() }, tickEvery: .seconds(3_600))
      let events = try blocking { () async throws -> [EngineEvent] in
        let handle = try await engines.send(request)
        if stopAfterStart {
          while await engines.steer(request.thread, "x") == .refused { await Task.yield() }
          await engines.stop(request.thread)
        }
        var seen: [EngineEvent] = []
        for await event in handle.events { seen.append(event) }
        await engines.shutdown()
        await engines.shutdown()
        return seen
      }
      return (events, host.spawned.first)
    }

    let mismatch = try run(FakeDriver(reported: ["approvalPolicy": "on-request"], early: [.text("early")], script: []))
    try check(
      mismatch.events == [.ended(TurnEnd(.modeMismatch(name: "approvalPolicy", expected: "never", reported: "on-request")))],
      "A mode mismatch refuses the turn and nothing the CLI sent before it gets out")
    try check(mismatch.process?.signals == [SIGTERM, SIGKILL], "The refused process's whole group is ended")

    let held = try run(FakeDriver(reported: ["approvalPolicy": "never"], early: [.text("early")], script: [.turnDone(.endTurn)]))
    try check(held.events == [.text("early"), .ended(TurnEnd(.endTurn))], "Events reach the turn only after the mode verified")

    let stopped = try run(FakeDriver(reported: ["approvalPolicy": "never"], early: [], script: [.accepted, .text("working")]), stopAfterStart: true)
    try check(stopped.events.last == .ended(TurnEnd(.stopped)), "Stop ends the turn as stopped")
    try check(stopped.process?.inputClosed == true && stopped.process?.signals == [SIGTERM, SIGKILL], "Stop closes input, then TERM and KILL go to the group")
  }

  /// The real host and kernel: the record exists before the CLI runs, and the sweep ends a group
  /// by its tag, never a process that merely looks the same.
  private static func engineRunRecords(_ check: Check) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-runs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let crashed = RunRecords(root: root)
    // An owner that no longer runs: this Serein "crashed".
    try crashed.prepare(owner: ProcessGroupRecord.Member(pid: 999_999, started: 1))
    let sleep = try signedSleep()
    defer { try? FileManager.default.removeItem(at: sleep.deletingLastPathComponent()) }
    let tagged = try spawnSleep(sleep, records: crashed)
    let record = crashed.directory.appendingPathComponent(String(tagged.pgid))
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: record.path), Date() < deadline { usleep(10_000) }
    try check(FileManager.default.fileExists(atPath: record.path), "The process host writes the run record")
    let table = KernelProcessTable()
    while table.environment(of: tagged.pgid)?.contains("\(RunRecords.tagVariable)=\(crashed.tag)") != true, Date() < deadline { usleep(10_000) }

    // Same program, no tag, with a forged record: must survive.
    let lookalike = Process()
    lookalike.executableURL = sleep
    lookalike.arguments = ["30"]
    try lookalike.run()
    defer { lookalike.terminate() }
    try "\(lookalike.processIdentifier)\n".write(
      to: crashed.directory.appendingPathComponent(String(lookalike.processIdentifier)), atomically: true, encoding: .utf8)

    let found = RunSweep.leftovers(in: root, except: "this-run", table: table)
    try check(found == [RunSweep.Leftover(pgid: tagged.pgid, tag: crashed.tag)], "The sweep picks the tagged group and not the lookalike")
    try crashed.prepare(owner: ProcessGroupRecord.Member(pid: 999_999, started: 1))
    try "\(tagged.pgid)\n".write(to: record, atomically: true, encoding: .utf8)
    try blocking { await RunSweep.sweep(RunRecords(root: root, tag: "this-run"), table: table, sleep: { _ in }) }
    let gone = Date().addingTimeInterval(5)
    while tagged.groupAlive, Date() < gone { usleep(10_000) }
    try check(!tagged.groupAlive, "The sweep ended the tagged group")
    try check(lookalike.isRunning, "The lookalike still runs")
    try check(!FileManager.default.fileExists(atPath: crashed.directory.path), "The crashed run's records are removed")
  }

  /// A CLI and a copy of /bin/sleep signed ad hoc: macOS hides the environment of Apple's own
  /// binaries, as it would not a CLI's, and the tag is read from it.
  static func signedSleep() throws -> URL {
    let bin = FileManager.default.temporaryDirectory.appendingPathComponent("engine-bin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let sleep = bin.appendingPathComponent("sleep")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", sleep.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    return sleep
  }

  /// A thirty-second CLI on the real host, recorded under `records`.
  static func spawnSleep(_ sleep: URL, records: RunRecords) throws -> any HostedProcess {
    let request = TurnRequest(
      thread: ThreadKey("r"), cli: .codex, executable: sleep, access: .answer,
      prompt: TurnPrompt(stable: "", volatile: "", message: "", recovery: nil), model: nil, effort: nil, resume: nil,
      browser: nil, taskID: "task")
    let contract = LaunchContract(
      request, arguments: ["30"], environment: ["PATH": "/usr/bin:/bin"], expectedMode: .nothing(flagOnArgv: ["30"]), network: .open)
    return try SereinProcessHost(records: records).spawn(contract)
  }

  /// A SIGTERM to Serein ends its CLI groups before Serein goes (Engines.endGroupsOnSIGTERM). A
  /// second Serein runs the probe (sigtermProbe) so this one survives the signal.
  private static func engineSigterm(_ check: Check) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-sigterm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let sleep = try signedSleep()
    defer { try? FileManager.default.removeItem(at: sleep.deletingLastPathComponent()) }
    let probe = Process()
    probe.executableURL = Bundle.main.executableURL
    probe.arguments = ["--verify-sigterm-probe", root.path, sleep.path]
    let out = Pipe()
    probe.standardOutput = out
    try probe.run()
    defer { if probe.isRunning { kill(probe.processIdentifier, SIGKILL) } }
    let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
    guard let pgid = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)), pgid > 1 else {
      return try check(false, "The SIGTERM probe started its CLI (got \(line.debugDescription))")
    }
    defer { kill(-pgid, SIGKILL) }
    let table = KernelProcessTable()
    let deadline = Date().addingTimeInterval(5)
    // The host carries the tag from its start, so the SIGTERM often lands before its record exists.
    while table.environment(of: pgid)?.contains(where: { $0.hasPrefix(RunRecords.tagVariable + "=") }) != true, Date() < deadline { usleep(10_000) }
    let sent = Date()
    kill(probe.processIdentifier, SIGTERM)
    while probe.isRunning, Date() < deadline.addingTimeInterval(5) { usleep(10_000) }
    try check(probe.terminationReason == .uncaughtSignal && probe.terminationStatus == SIGTERM,
      "Serein still ends by SIGTERM once its CLIs are gone")
    try check(kill(-pgid, 0) != 0 && kill(pgid, 0) != 0, "A SIGTERM to Serein ends its CLI groups first")
    // Within the 2 s before KILL: the CLI took the TERM, so it does not inherit an ignored SIGTERM.
    try check(Date().timeIntervalSince(sent) < 1.5, "The CLIs Serein starts still end on SIGTERM")
  }

  /// Runs async work from a synchronous check, with a deadline so a hang fails instead of stalling.
  static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
      do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
      done.signal()
    }
    guard done.wait(timeout: .now() + 20) == .success, let result = box.result else {
      throw SereinError.invalid("FAIL: engine check timed out")
    }
    return try result.get()
  }
}

private final class ResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}

private final class FakeDriver: Driver, @unchecked Sendable {
  let cli = HarnessDriver.codex
  let cardWait = Duration.seconds(118)
  let reported: [String: String]
  let early: [WireEvent]
  let script: [WireEvent]

  init(reported: [String: String], early: [WireEvent], script: [WireEvent]) {
    self.reported = reported
    self.early = early
    self.script = script
  }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(request, arguments: ["app-server"], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    let (wire, continuation) = AsyncStream<WireEvent>.makeStream()
    for event in early { continuation.yield(event) }
    switch ModeCheck.verify(contract.expectedMode, reported: reported, argv: contract.argv) {
    case .failure(let reason): throw reason
    case .success(let mode): return FakeSession(mode: mode, wire: wire, continuation: continuation, script: script)
    }
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class FakeSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  let continuation: AsyncStream<WireEvent>.Continuation
  let script: [WireEvent]

  init(mode: VerifiedMode, wire: AsyncStream<WireEvent>, continuation: AsyncStream<WireEvent>.Continuation, script: [WireEvent]) {
    self.mode = mode
    self.wire = wire
    self.continuation = continuation
    self.script = script
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    for event in script { continuation.yield(event) }
  }

  func steer(_ text: String) async -> SteerOutcome { .steered }
}

private final class FakeHost: ProcessHosting, @unchecked Sendable {
  private let lock = NSLock()
  private var started: [FakeHosted] = []
  var spawned: [FakeHosted] { lock.withLock { started } }

  func spawn(_ contract: LaunchContract) throws -> any HostedProcess {
    let process = FakeHosted()
    lock.withLock { started.append(process) }
    return process
  }
}

/// A CLI that ignores end of input and TERM, so the whole ladder runs.
private final class FakeHosted: HostedProcess, @unchecked Sendable {
  let pgid: pid_t = 4242
  let output: AsyncStream<Data>
  private let outputContinuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var sent: [Int32] = []
  private var closed = false
  private var alive = true
  private var waiting: [CheckedContinuation<ProcessExit, Never>] = []

  init() { (output, outputContinuation) = AsyncStream<Data>.makeStream() }

  var signals: [Int32] { lock.withLock { sent } }
  var inputClosed: Bool { lock.withLock { closed } }
  var groupAlive: Bool { lock.withLock { alive } }

  func write(_ data: Data) throws {}
  func closeInput() { lock.withLock { closed = true } }

  func signalGroup(_ signal: Int32) {
    let resumed: [CheckedContinuation<ProcessExit, Never>] = lock.withLock {
      sent.append(signal)
      guard signal == SIGKILL else { return [] }
      alive = false
      defer { waiting = [] }
      return waiting
    }
    if signal == SIGKILL { outputContinuation.finish() }
    for continuation in resumed { continuation.resume(returning: ProcessExit(status: 9, signaled: true, stderr: "")) }
  }

  func exited() async -> ProcessExit {
    await withCheckedContinuation { continuation in
      let dead = lock.withLock {
        if alive { waiting.append(continuation) }
        return !alive
      }
      if dead { continuation.resume(returning: ProcessExit(status: 9, signaled: true, stderr: "")) }
    }
  }
}
/// `--verify-sigterm-probe <root> <sleep>`: the second Serein of engineSigterm. Starts one CLI
/// under its own run records, prints its group, and waits for the SIGTERM.
func sigtermProbe(root: URL, sleep: URL) -> Never {
  let records = RunRecords(root: root)
  let engines = Engines(drivers: [], host: SereinProcessHost(records: records), records: records)
  engines.endGroupsOnSIGTERM()
  let tagged: any HostedProcess
  do {
    try records.prepare(owner: ProcessGroupRecord.Member(pid: getpid(), started: KernelProcessTable().live(getpid())?.started ?? 0))
    tagged = try AssistantCoreChecks.spawnSleep(sleep, records: records)
  } catch {
    exit(2)
  }
  print(tagged.pgid)
  fflush(stdout)
  // Held, as Engines holds a CLI it runs, so its exit is reaped and not left a zombie.
  while true { withExtendedLifetime(tagged) { _ = pause() } }
}
#endif
