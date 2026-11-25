#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The team tools through `Peers.handle`, over the real `Engines` with fake CLIs: no process,
/// no app. A fake CLI answers by what it is asked (`PeerScript`).
extension AssistantCoreChecks {
  static func peers(_ check: Check) throws {
    try peerToolList(check)
    try peerCalls(check)
    try peerTree(check)
  }

  private static func peerToolList(_ check: Check) throws {
    let listed = ToolSchema.everyTool([PeerTools.flag]).compactMap { $0["name"] as? String }
    try check(PeerTools.names.allSatisfy(listed.contains), "A task given the team flag lists every team tool")
    try check(!ToolSchema.everyTool([]).contains { PeerTools.names.contains($0["name"] as? String ?? "") }, "No other run lists them")
    try check(
      PeerTools.parse("peer_ask", ["agents": ["Grok", "grok", "Claude Code"], "question": " Is it safe? "])
        == .success(.ask(agents: [.grok, .claude], question: "Is it safe?")),
      "An agent is named by id or display name, once each")
    try check(
      (try? PeerTools.parse("peer_ask", ["agents": ["hal"], "question": "q"]).get()) == nil
        && (try? PeerTools.parse("peer_burst", ["jobs": [["agent": "grok", "prompt": " "]]]).get()) == nil
        && (try? PeerTools.parse("peer_bridge", ["writer": "codex", "reviewer": "grok", "task": "t", "rounds": 4]).get()) == nil,
      "An unknown agent, an empty job and too many rounds are refused before anything runs")
    try check(ToolTurns.turn(name: "peer_wait", arguments: nil).write == false && ToolTurns.turn(name: "peer_ask", arguments: nil).write,
      "Waiting runs beside the caller's other calls; starting agents takes its turn")
  }

  private static func peerCalls(_ check: Check) throws {
    let folder = URL(fileURLWithPath: "/tmp/peer-checks")
    let top = PeerCaller(thread: ThreadKey("top"), cli: .codex, access: .project(folder: folder, level: .full))
    try peerWorld(check) { world, notes in
      let peers = world.peers
      await peers.register(task: "top", caller: top)

      let one = await peers.handle(.ask(agents: [.grok], question: "Is it safe?"), task: "top")
      notes.check(!one.isError && one.text.contains("grok: answered") && one.text.contains("grok says: Is it safe?") && one.text.contains(": done."),
        "A call to another agent returns its answer inside the call")
      let callee = world.host.callees.first
      notes.check(callee?.access == top.access && callee?.callerTask == "top" && callee?.mayCall == true,
        "The callee works in the caller's folder at the caller's level, under the caller's task")
      notes.check(await eventually { world.host.released.count == 1 }, "The callee's browser task closes when its turn ends")

      let meeting = await peers.handle(.ask(agents: [.claude, .grok, .opencode], question: "FAIL or not?"), task: "top")
      notes.check(
        !meeting.isError && meeting.text.contains("meeting of 3") && meeting.text.contains("claude: answered")
          && meeting.text.contains("grok: answered") && meeting.text.contains("opencode: failed: boom") && meeting.text.contains(": done."),
        "A meeting returns one result; one agent failing does not lose the others' answers")

      let bridge = await peers.handle(.bridge(writer: .claude, reviewer: .grok, task: "Write the BRIDGE plan", rounds: 3), task: "top")
      notes.check(
        bridge.text.contains("writer and reviewer") && bridge.text.contains("reviewer, round 2") && !bridge.text.contains("round 3")
          && bridge.text.contains("draft v2") && !bridge.text.contains("draft v1") && bridge.text.contains("The reviewer approved"),
        "A bridge revises on the review and stops once the reviewer approves, showing the last draft")

      let self_ = await peers.handle(.ask(agents: [.codex], question: "q"), task: "top")
      notes.check(!self_.isError && self_.text.hasPrefix("Blocked: ") && self_.text.contains("already in this chain"), "An agent cannot call its own CLI")

      let held = await peers.handle(.burst((1...6).map { PeerJob(agent: .grok, prompt: "HOLD \($0)") }), task: "top")
      notes.check(
        held.text.components(separatedBy: "grok: working").count - 1 == 4
          && held.text.components(separatedBy: "queued, not started yet").count - 1 == 2 && held.text.contains("still working")
          && held.text.contains("Call peer_wait"),
        "A burst runs four at once for one task and queues the rest, and a call that outlasts its wait says how to keep waiting")
      let stopped = await peers.handle(.stop(run: nil), task: "top")
      notes.check(stopped.text.components(separatedBy: "grok: stopped").count - 1 == 6, "Stopping ends the running jobs and the queued ones")
      notes.check(await eventually { world.processes.spawned.allSatisfy { !$0.groupAlive } }, "Every stopped callee's process group is gone")

      let quick = await peers.handle(.burst((1...6).map { PeerJob(agent: $0 % 2 == 0 ? .grok : .claude, prompt: "part \($0)") }), task: "top")
      let waited = await peers.handle(.wait(runs: [], seconds: 1), task: "top")
      notes.check(quick.text.components(separatedBy: ": answered").count - 1 == 6 && waited.text.contains("part 6"),
        "Burst and wait: every job of the burst answers, and a wait reports every run of the caller's")

      let stranger = await peers.handle(.wait(runs: ["peer-1"], seconds: 1), task: "nobody")
      notes.check(stranger.isError && stranger.text.contains("not available"), "A task that was not given the team tools cannot use them")
    }
  }

  /// Depth, cycles through a callee, a callee's own calls, and stopping the caller stopping the tree.
  private static func peerTree(_ check: Check) throws {
    let top = PeerCaller(thread: ThreadKey("top"), cli: .codex, access: .task(folder: URL(fileURLWithPath: "/tmp/peer-checks")))
    try peerWorld(check) { world, notes in
      let peers = world.peers
      await peers.register(task: "top", caller: top)
      _ = await peers.handle(.ask(agents: [.grok], question: "HOLD and ask others"), task: "top")
      guard let grok = world.host.task(of: .grok) else { return notes.check(false, "The callee got a browser task") }

      let back = await peers.handle(.ask(agents: [.codex], question: "q"), task: grok)
      notes.check(!back.isError && back.text.hasPrefix("Blocked: ") && back.text.contains("codex > grok"), "A callee cannot call back an agent that called it")
      let nested = await peers.handle(.burst([PeerJob(agent: .claude, prompt: "HOLD a"), PeerJob(agent: .opencode, prompt: "HOLD b")]), task: grok)
      notes.check(
        nested.text.contains("claude: working") && nested.text.contains("opencode: queued"),
        "A callee's own calls run one at a time, outside its caller's slots")
      notes.check(world.host.callees.first { $0.cli == .claude }?.mayCall == false, "The second level down is not given the team tools")
      guard let claude = world.host.task(of: .claude) else { return notes.check(false, "The nested callee got a browser task") }
      let deep = await peers.handle(.ask(agents: [.opencode], question: "q"), task: claude)
      notes.check(!deep.isError && deep.text.hasPrefix("Blocked: ") && deep.text.contains("2 calls deep"), "A call from two levels down is refused")

      await peers.callerEnded(top.thread)
      notes.check(
        await eventually { world.host.released.count == 2 && world.processes.spawned.allSatisfy { !$0.groupAlive } },
        "Stopping the caller stops its callees and theirs, and every process group is gone")
      let after = await peers.handle(.wait(runs: [], seconds: 1), task: grok)
      notes.check(after.isError, "A stopped callee holds no team tools")
    }
  }

  /// A CLI that reaches its usage or rate limit holds its queued jobs until the reset, then they start by themselves.
  static func peerQuota(_ check: Check) throws {
    let top = PeerCaller(thread: ThreadKey("top"), cli: .grok, access: .task(folder: URL(fileURLWithPath: "/tmp/peer-checks")))
    try peerWorld(check) { world, notes in
      let peers = world.peers
      await peers.register(task: "top", caller: top)
      @Sendable func started(_ cli: HarnessDriver) -> Int { world.host.callees.filter { $0.cli == cli }.count }
      func settles(_ task: String, _ text: String) async -> Bool {
        for _ in 0..<25 {
          if await peers.handle(.wait(runs: [], seconds: 1), task: task).text.contains(text) { return true }
        }
        return false
      }

      _ = await peers.handle(.ask(agents: [.codex], question: "HOLD and ask others"), task: "top")
      guard let codex = world.host.task(of: .codex) else { return notes.check(false, "Quota: the callee got a browser task") }
      let burst = await peers.handle(.burst([PeerJob(agent: .claude, prompt: "LIMIT AT"), PeerJob(agent: .claude, prompt: "after")]), task: codex)
      notes.check(started(.claude) == 1 && burst.text.contains("claude: waiting for its limit to reset, starts by itself at"),
        "Quota: the queued job for that CLI stays unstarted and tells its caller it waits for the reset")
      notes.check(burst.text.contains("claude: failed: Claude Code reached its usage limit. Its next jobs start by themselves at"),
        "Quota: a callee that reaches its usage limit fails with when its CLI's jobs start again")

      let other = await peers.handle(.ask(agents: [.opencode], question: "hi"), task: "top")
      notes.check(other.text.contains("opencode: answered"), "Quota: other CLIs keep running while one is held")
      let later = await peers.handle(.ask(agents: [.claude], question: "q"), task: "top")
      notes.check(started(.claude) == 1 && later.text.contains("claude: waiting for its limit to reset"),
        "Quota: a new call to the held CLI waits for the reset too")
      let resumed = await settles(codex, "claude says: after")
      let allThree = await eventually { started(.claude) == 3 }
      notes.check(resumed && allThree,
        "Quota: at the reset time the CLI named, the held jobs start by themselves and answer")

      _ = await peers.handle(.ask(agents: [.opencode], question: "BUSY"), task: "top")
      let paced = await peers.handle(.ask(agents: [.opencode], question: "next"), task: "top")
      notes.check(paced.text.contains("opencode: waiting for its limit to reset") && !paced.text.contains("opencode says: next"),
        "Quota: a rate limit (429) holds the CLI's next job")

      _ = await peers.handle(.ask(agents: [.claude], question: "LIMIT"), task: "top")
      let unnamed = await peers.handle(.ask(agents: [.claude], question: "unnamed"), task: "top")
      try? await Task.sleep(for: .milliseconds(2_500))
      notes.check(unnamed.text.contains("claude: waiting for its limit to reset") && started(.claude) == 4,
        "Quota: a limit with no reset time named still holds the CLI's next job, past a named reset's wait")
      _ = await peers.handle(.stop(run: nil), task: "top")
    }
  }

  private struct PeerWorld: Sendable {
    let peers: Peers
    let host: FakePeerHost
    let processes: PeerProcesses
  }

  private static func peerWorld(_ check: Check, _ body: @escaping @Sendable (PeerWorld, PeerNotes) async throws -> Void) throws {
    let records = RunRecords(root: FileManager.default.temporaryDirectory.appendingPathComponent("peer-checks-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: records.root) }
    let processes = PeerProcesses()
    let drivers: [any Driver] = [HarnessDriver.claude, .codex, .grok, .opencode].map(PeerScript.init)
    let engines = Engines(drivers: drivers, host: processes, records: records, sleep: { _ in await Task.yield() }, tickEvery: .seconds(3_600))
    var limits = Peers.Limits()
    limits.inlineCap = .milliseconds(400)
    let host = FakePeerHost()
    let world = PeerWorld(peers: Peers(engines: engines, host: host, limits: limits), host: host, processes: processes)
    let done = DispatchSemaphore(value: 0)
    let box = PeerResult()
    let notes = PeerNotes()
    Task {
      do { try await body(world, notes) } catch { box.error = error }
      await engines.shutdown()
      done.signal()
    }
    guard done.wait(timeout: .now() + 30) == .success else { throw SereinError.invalid("FAIL: team tool check timed out") }
    if let error = box.error { throw error }
    for (passed, label) in notes.all { try check(passed, label) }
  }

  private static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private final class PeerResult: @unchecked Sendable {
  var error: Error?
}

/// Results taken inside the async world, reported in order once it is done.
private final class PeerNotes: @unchecked Sendable {
  private let lock = NSLock()
  private var taken: [(Bool, String)] = []
  var all: [(Bool, String)] { lock.withLock { taken } }
  func check(_ passed: Bool, _ label: String) { lock.withLock { taken.append((passed, label)) } }
}

final class FakePeerHost: PeerHost, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [PeerCallee] = []
  private var closed: [String] = []
  var callees: [PeerCallee] { lock.withLock { seen } }
  var released: [String] { lock.withLock { closed } }
  func task(of cli: HarnessDriver) -> String? { callees.first { $0.cli == cli }.map { "task:" + $0.thread.id } }

  func request(for callee: PeerCallee) async throws -> TurnRequest {
    lock.withLock { seen.append(callee) }
    return TurnRequest(
      thread: callee.thread, cli: callee.cli, executable: URL(fileURLWithPath: "/usr/bin/true"), access: callee.access,
      prompt: callee.prompt, model: nil, effort: nil, resume: nil, browser: nil, taskID: "task:" + callee.thread.id)
  }

  func release(task: String) async { lock.withLock { closed.append(task) } }
}

/// A fake CLI that answers by what it is asked: HOLD works until stopped, FAIL fails OpenCode,
/// and a bridge's writer and reviewer agree on the second draft.
private struct PeerScript: Driver {
  let cli: HarnessDriver
  let cardWait = Duration.seconds(118)

  init(_ cli: HarnessDriver) { self.cli = cli }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(request, arguments: [], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    let mode = try ModeCheck.verify(contract.expectedMode, reported: ["approvalPolicy": "never"], argv: contract.argv).get()
    return PeerSession(cli: cli, mode: mode)
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class PeerSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation
  private let cli: HarnessDriver

  init(cli: HarnessDriver, mode: VerifiedMode) {
    self.cli = cli
    self.mode = mode
    (wire, continuation) = AsyncStream<WireEvent>.makeStream()
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    let asked = prompt.message
    continuation.yield(.accepted)
    if asked.contains("HOLD") { continuation.yield(.text("working on it")); return }
    if asked.contains("FAIL"), cli == .opencode { continuation.yield(.turnDone(.failed("boom"))); return }
    if asked.contains("LIMIT AT") { continuation.yield(.limitReached(UsageLimit(resetsAt: Date().addingTimeInterval(2)))) }
    if asked.contains("LIMIT") { continuation.yield(.failed("You've hit your session limit")); return }
    if asked.contains("BUSY") { continuation.yield(.failed("429 Too Many Requests")); return }
    let reply: String
    if asked.hasPrefix("Review this draft") {
      reply = asked.contains("draft v2") ? "APPROVED, ship it." : "Add the rollback step."
    } else if asked.contains("reviewer's notes") {
      reply = "draft v2"
    } else if asked.contains("BRIDGE") {
      reply = "draft v1"
    } else {
      reply = "\(cli.rawValue) says: \(asked)"
    }
    continuation.yield(.text(reply))
    continuation.yield(.turnDone(.endTurn))
  }

  func steer(_ text: String) async -> SteerOutcome { .steered }
}

final class PeerProcesses: ProcessHosting, @unchecked Sendable {
  private let lock = NSLock()
  private var started: [PeerProcess] = []
  var spawned: [PeerProcess] { lock.withLock { started } }

  func spawn(_ contract: LaunchContract) throws -> any HostedProcess {
    let process = PeerProcess()
    lock.withLock { started.append(process) }
    return process
  }
}

/// A CLI that ends on its group's first signal.
final class PeerProcess: HostedProcess, @unchecked Sendable {
  let pgid: pid_t = 4343
  let output: AsyncStream<Data>
  private let outputContinuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var alive = true
  private var waiting: [CheckedContinuation<ProcessExit, Never>] = []

  init() { (output, outputContinuation) = AsyncStream<Data>.makeStream() }

  var groupAlive: Bool { lock.withLock { alive } }
  func write(_ data: Data) throws {}
  func closeInput() {}

  func signalGroup(_ signal: Int32) {
    let resumed: [CheckedContinuation<ProcessExit, Never>] = lock.withLock {
      alive = false
      defer { waiting = [] }
      return waiting
    }
    outputContinuation.finish()
    for continuation in resumed { continuation.resume(returning: ProcessExit(status: 15, signaled: true, stderr: "")) }
  }

  func exited() async -> ProcessExit {
    await withCheckedContinuation { continuation in
      let dead = lock.withLock {
        if alive { waiting.append(continuation) }
        return !alive
      }
      if dead { continuation.resume(returning: ProcessExit(status: 15, signaled: true, stderr: "")) }
    }
  }
}
#endif
