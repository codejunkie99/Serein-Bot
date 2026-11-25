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

      // Room for two CLIs on an 8 GB Mac: floor 819 MB, two 700 MB shares, 100 MB over.
      world.memory.value = RoomSnapshot(totalBytes: 8 << 30, availableBytes: 2_320 * EngineRoom.mb)
      let held = await peers.handle(.burst((1...6).map { PeerJob(agent: .grok, prompt: "HOLD \($0)") }), task: "top")
      notes.check(
        held.text.components(separatedBy: "grok: working").count - 1 == 2
          && held.text.components(separatedBy: "grok: waiting for memory").count - 1 == 4 && held.text.contains("still working")
          && held.text.contains("Call peer_wait"),
        "A burst runs as many at once as memory has room for and the rest say they wait for memory, and a call that outlasts its wait says how to keep waiting")
      world.memory.value = PeerWorld.plenty
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
        "A callee's own calls run one at a time")
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
    var limits = Peers.Limits()
    limits.probeFirst = 0.5
    limits.probeMost = 1
    try peerWorld(check, limits: limits) { world, notes in
      let peers = world.peers
      await peers.register(task: "top", caller: top)
      @Sendable func started(_ cli: HarnessDriver) -> Int { world.host.callees.filter { $0.cli == cli }.count }
      func settles(_ task: String, _ texts: [String]) async -> Bool {
        for _ in 0..<12 {
          let said = await peers.handle(.wait(runs: [], seconds: 1), task: task).text
          if texts.allSatisfy(said.contains) { return true }
        }
        return false
      }

      // Claude Code names its reset in its own event.
      _ = await peers.handle(.ask(agents: [.codex], question: "HOLD and ask others"), task: "top")
      guard let codex = world.host.task(of: .codex) else { return notes.check(false, "Quota: the callee got a browser task") }
      world.gate[.claude] = .init(text: "You've hit your session limit", reset: Date().addingTimeInterval(1.5))
      let burst = await peers.handle(.burst([PeerJob(agent: .claude, prompt: "TOOL one"), PeerJob(agent: .claude, prompt: "two")]), task: codex)
      notes.check(started(.claude) == 1 && burst.text.contains("claude: waiting for its limit to reset, starts by itself at"),
        "Quota: the queued job for that CLI stays unstarted and tells its caller it waits for the reset")
      notes.check(burst.text.contains("claude: failed: Claude Code reached its usage limit after this job had run tools, so it is not sent again. Its next jobs start by themselves at"),
        "Quota: a callee that ran tools before its usage limit fails, with when its CLI's jobs start again")
      let other = await peers.handle(.ask(agents: [.opencode], question: "hi"), task: "top")
      notes.check(other.text.contains("opencode: answered"), "Quota: other CLIs keep running while one is held")
      let early = await peers.handle(.ask(agents: [.claude], question: "three"), task: "top")
      notes.check(started(.claude) == 1 && early.text.contains("claude: waiting for its limit to reset"),
        "Quota: a new call to the held CLI waits for the reset too")
      world.gate[.claude] = nil
      let resumed = await settles(codex, ["claude says: two"])
      let third = await settles("top", ["claude says: three"])
      notes.check(resumed && third && started(.claude) == 3,
        "Quota: at the reset time the CLI named, the held jobs start by themselves and answer")

      // The provider names its delay in words (OpenAI's, passed on by OpenCode).
      world.gate[.opencode] = .init(text: "Internal error: Rate limit reached for gpt-4o on tokens per min (TPM): Limit 30000, Used 29000, Requested 2000. Please try again in 1s.")
      let named = await peers.handle(.ask(agents: [.opencode], question: "named"), task: "top")
      notes.check(named.text.contains("opencode: waiting for its limit to reset, starts by itself at"),
        "Quota: a rate limit's delay in the provider's words holds the CLI until then")
      world.gate[.opencode] = nil
      let namedDone = await settles("top", ["opencode says: named"])
      notes.check(namedDone && started(.opencode) == 3, "Quota: the job that met the limit before any tool starts again by itself and answers")

      // No reset named: one job tries on a doubling wait, and an answer releases the rest.
      world.gate[.opencode] = .init(text: "Internal error: Workspace usage limit reached. Model use is paused until the limit resets.")
      let before = started(.opencode)
      let sent = Date()
      func at(_ seconds: Double) async { try? await Task.sleep(for: .seconds(max(0, seconds - Date().timeIntervalSince(sent)))) }
      let held = await peers.handle(.burst(["a", "b", "c"].map { PeerJob(agent: .opencode, prompt: $0) }), task: "top")
      notes.check(held.text.contains("opencode: waiting for its limit to clear, which it named no time for") && !held.text.contains("opencode: failed"),
        "Quota: with no reset named, the CLI's jobs wait to learn when its limit clears, and none fails")
      await at(1.1)
      notes.check(started(.opencode) == before + 4,
        "Quota: one job tries again after the first wait, not every held job, and jobs refused together count as one refusal")
      await at(2.1)
      notes.check(started(.opencode) == before + 5, "Quota: a try still refused doubles the wait before the next one")
      world.gate[.opencode] = nil
      let cleared = await settles("top", ["opencode says: a", "opencode says: b", "opencode says: c"])
      notes.check(cleared && started(.opencode) == before + 8, "Quota: the first try that gets through releases every held job at once")
      _ = await peers.handle(.stop(run: nil), task: "top")
    }
  }

  /// Each CLI's real words at its limit (see the drivers), read for a reset at the shared boundary.
  static func limitWords(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func reset(_ text: String, _ cli: HarnessDriver) -> TimeInterval?? {
      UsageLimit.text(text, harness: cli, now: now).map { $0.resetsAt.map { $0.timeIntervalSince(now) } }
    }
    func delay(_ text: String) -> TimeInterval? { UsageLimit.retryAfter(text, now: now)?.timeIntervalSince(now) }
    try check(reset("You exceeded your current quota, please check your plan and billing details.\n* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 10\nPlease retry in 23.5s.\nSuggested retry after 23s.", .gemini) == .some(23.5),
      "Gemini: a quota error resets after the delay Google named")
    try check(reset("You have exhausted your capacity on this model. Your quota will reset after 10m.", .gemini) == .some(600),
      "Gemini: its capacity limit resets after the time it names")
    try check(reset("You have exhausted your daily quota on this model.", .gemini) == .some(nil),
      "Gemini: a daily quota is a usage limit that names no reset")
    try check(reset("Rate limit exceeded. Try again later.", .gemini) == nil && delay("Rate limit exceeded. Try again later.") == nil,
      "Gemini: its plain rate limit is no usage limit and names no delay")
    try check(delay("Internal error: Rate limit reached for gpt-4o in organization org-1 on tokens per min (TPM): Limit 30000, Used 29000, Requested 2000. Please try again in 6m0s. Visit https://platform.openai.com/account/rate-limits to learn more.") == 360,
      "OpenCode: OpenAI's rate limit names its delay")
    try check(reset("Internal error: Workspace usage limit reached. Model use is paused until the limit resets.", .opencode) == .some(nil),
      "OpenCode: its own usage limit names no reset")
    try check(reset("You have hit your ChatGPT usage limit (plus plan). Try again in ~143 min.", .pi) == .some(143 * 60),
      "Pi: a ChatGPT usage limit resets after the minutes it names")
    try check(reset("Provider requested 8580000ms wait, exceeds retry.maxDelayMs (300000ms). Original error: You have hit your ChatGPT usage limit (plus plan). Try again in ~143 min.", .ohMyPi) == .some(8_580),
      "Oh My Pi: its wait in milliseconds names the reset")
    try check(reset("You\u{2019}ve reached your free Grok Build usage limit for now. Get SuperGrok for much higher limits, or try again later: https://grok.com/supergrok?referrer=grok-build", .grok) == .some(nil),
      "Grok: its usage limit names no reset")
    let grokRate = "You\u{2019}ve hit the rate limit for your plan. Upgrade your account or try again later."
    try check(reset(grokRate, .grok) == nil && delay(grokRate) == nil
      && HarnessRetry.classify(.message(grokRate)) == .transient(.rateLimited),
      "Grok: its rate limit names no delay")
    try check(delay("retry in 0s") == nil && delay("try again in 9999h") == nil, "A delay of nothing or past a week is not believed")
  }

  private struct PeerWorld: Sendable {
    static let plenty = RoomSnapshot(totalBytes: 64 << 30, availableBytes: 48 << 30)
    let peers: Peers
    let host: FakePeerHost
    let processes: PeerProcesses
    /// The memory reading every callee start sees.
    let memory: RoomReading
    let gate: PeerGate
  }

  private static func peerWorld(_ check: Check, limits: Peers.Limits = Peers.Limits(),
                                _ body: @escaping @Sendable (PeerWorld, PeerNotes) async throws -> Void) throws {
    let records = RunRecords(root: FileManager.default.temporaryDirectory.appendingPathComponent("peer-checks-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: records.root) }
    let processes = PeerProcesses()
    let gate = PeerGate()
    let drivers: [any Driver] = [HarnessDriver.claude, .codex, .grok, .opencode].map { PeerScript($0, gate: gate) }
    let memory = RoomReading(PeerWorld.plenty)
    let engines = Engines(
      drivers: drivers, host: processes, records: records, sleep: { _ in await Task.yield() }, tickEvery: .seconds(3_600),
      room: EngineRoom(sample: { memory.value }, footprint: { _ in nil }, tick: .milliseconds(5)))
    var limits = limits
    limits.inlineCap = .milliseconds(400)
    let host = FakePeerHost()
    let world = PeerWorld(peers: Peers(engines: engines, host: host, limits: limits), host: host, processes: processes, memory: memory, gate: gate)
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

/// A CLI's limit, switched on by a check: each turn fails with `text`, after a tool step when
/// the prompt says TOOL, and with Claude Code's own event when `reset` is set.
private final class PeerGate: @unchecked Sendable {
  struct Refusal { var text: String; var reset: Date? = nil }
  private let lock = NSLock()
  private var refusals: [HarnessDriver: Refusal] = [:]
  subscript(cli: HarnessDriver) -> Refusal? {
    get { lock.withLock { refusals[cli] } }
    set { lock.withLock { refusals[cli] = newValue } }
  }
}

/// A fake CLI that answers by what it is asked: HOLD works until stopped, FAIL fails OpenCode,
/// and a bridge's writer and reviewer agree on the second draft.
private struct PeerScript: Driver {
  let cli: HarnessDriver
  let gate: PeerGate
  let cardWait = Duration.seconds(118)

  init(_ cli: HarnessDriver, gate: PeerGate) {
    self.cli = cli
    self.gate = gate
  }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(request, arguments: [], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    let mode = try ModeCheck.verify(contract.expectedMode, reported: ["approvalPolicy": "never"], argv: contract.argv).get()
    return PeerSession(cli: cli, mode: mode, gate: gate)
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class PeerSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation
  private let cli: HarnessDriver
  private let gate: PeerGate

  init(cli: HarnessDriver, mode: VerifiedMode, gate: PeerGate) {
    self.cli = cli
    self.mode = mode
    self.gate = gate
    (wire, continuation) = AsyncStream<WireEvent>.makeStream()
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    let asked = prompt.message
    continuation.yield(.accepted)
    if asked.contains("HOLD") { continuation.yield(.text("working on it")); return }
    if asked.contains("FAIL"), cli == .opencode { continuation.yield(.turnDone(.failed("boom"))); return }
    if let refusal = gate[cli] {
      if asked.contains("TOOL") { continuation.yield(.toolStarted(id: "t1", name: "bash", arguments: "{}", shellCommand: "ls")) }
      if let reset = refusal.reset { continuation.yield(.limitReached(UsageLimit(resetsAt: reset))) }
      continuation.yield(.failed(refusal.text))
      return
    }
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
