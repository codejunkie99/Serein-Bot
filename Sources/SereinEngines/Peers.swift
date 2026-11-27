import Foundation
import SereinCore

/// The agent behind a task's team tools.
public struct PeerCaller: Sendable {
  public var thread: ThreadKey
  public var cli: HarnessDriver
  /// The most a callee may get: the host decides each callee's own access within it.
  public var access: Access
  public init(thread: ThreadKey, cli: HarnessDriver, access: Access) {
    self.thread = thread
    self.cli = cli
    self.access = access
  }
}

/// One callee turn, in Serein's terms; the app makes it a `TurnRequest`.
public struct PeerCallee: Sendable {
  public var thread: ThreadKey
  public var cli: HarnessDriver
  public var access: Access
  public var prompt: TurnPrompt
  /// The caller's browser task. The callee gets its own task under it, so a secure card it opens
  /// shows in the caller's chat and never waits behind the caller's own team-tool call.
  public var callerTask: String
  /// Whether the callee's browser task lists the team tools (`PeerTools.flag`).
  public var mayCall: Bool
}

/// The app's side: the binary, model and browser task of each callee.
public protocol PeerHost: Sendable {
  /// Throws when the CLI is not installed or signed in; the job then fails with that reason.
  func request(for callee: PeerCallee) async throws -> TurnRequest
  /// The callee's turn ended: close the browser task `request(for:)` made.
  func release(task: String) async
  /// Task `task` stands at Allow all: a callee's question to its caller gets `SwarmPrompts.keepGoing`
  /// instead of ending the callee's turn.
  func keepsGoing(task: String) async -> Bool
  /// Task `task` holds an open secure card or person step: the callee's turn ended waiting on the person.
  func holdsCard(task: String) async -> Bool
  /// Another connected, non-pay-per-use CLI that may take over from `cli` at a long or unnamed
  /// limit (same rule as `LimitFailover.allowed`: free or existing plan, never an API key without
  /// asking, never in `excluding`).
  func fallback(from cli: HarnessDriver, excluding: Set<HarnessDriver>) async -> HarnessDriver?
  /// Informs the app that `cli` reached a limit until `until` (nil when unnamed), so chat failover
  /// shares the same limit state.
  func noteLimit(cli: HarnessDriver, until: Date?) async
  /// A swarm's board changed: the whole board, its `version` higher than any sent before. `task`
  /// is the browser task of the chat's own run, the lead.
  func swarmChanged(_ board: SwarmBoard, task: String) async
}

extension PeerHost {
  public func keepsGoing(task: String) async -> Bool { false }
  public func holdsCard(task: String) async -> Bool { false }
  public func fallback(from cli: HarnessDriver, excluding: Set<HarnessDriver>) async -> HarnessDriver? { nil }
  public func noteLimit(cli: HarnessDriver, until: Date?) async {}
  public func swarmChanged(_ board: SwarmBoard, task: String) async {}
}

public struct PeerReply: Sendable, Equatable {
  public var text: String
  public var isError: Bool
  public init(_ text: String, isError: Bool = false) {
    self.text = text
    self.isError = isError
  }
}

/// Runs the team tools (`PeerTools`): who may call whom, when each callee starts, how long a call
/// waits, and stopping a whole tree of calls. Memory paces how many run at once: every callee start
/// waits for room like any CLI start (`Engines.waitForRoom`).
public actor Peers {
  public struct Limits: Sendable {
    /// A task is depth 0. Depth 1 may call once more, one call at a time; depth 2 has no team tools.
    public var maxDepth = 2
    /// Longest a call waits inline: the caller CLI's tool-call limit less a margin, at most this.
    public var inlineCap: Duration = .seconds(100)
    public var inlineMargin: Duration = .seconds(5)
    public var inlineUnknown: Duration = .seconds(20)
    /// A CLI's usage limit with no reset named: one of its jobs tries again this long after, the
    /// wait doubling with each try still refused, up to `probeMost`.
    public var probeFirst: TimeInterval = 2 * 60
    /// An unnamed transient 429 rate limit clears sooner than a usage limit, so probe faster first.
    public var rateProbeFirst: TimeInterval = 20
    public var probeMost: TimeInterval = 30 * 60
    /// Consecutive unnamed refusals before a held job fails instead of probing forever.
    public var maxUnclearProbes = 6
    /// A named reset longer than this (or an unnamed limit) tries a safe same-plan/free backup CLI
    /// first instead of waiting. Short waits (like Gemini's 23.5s) stay on the requested CLI.
    public var failoverThreshold: TimeInterval = 60
    public init() {}
  }

  public static let shared = Peers(engines: .shared)

  private let engines: Engines
  private var host: (any PeerHost)?
  private let limits: Limits

  private struct Seat {
    var caller: PeerCaller
    var root: ThreadKey
    /// The browser task of the top task in this tree of calls.
    var rootTask: String
    var chain: [HarnessDriver]
    var depth: Int
    /// The bot this seat is on a swarm board, so its own team calls seat helpers under it.
    var place: Place? = nil
  }

  private struct Place {
    var board: String
    var member: String
  }

  /// A swarm board while its swarm runs; `task` is the lead's browser task.
  private struct Live {
    var board: SwarmBoard
    var task: String
  }

  private struct Job {
    var agent: HarnessDriver
    var role: String?
    var prompt: String
    var thread: ThreadKey
    var accessOverride: Access? = nil
    /// A writer in a folder other writers share, with no git worktree. One such writer works there at a time.
    var shares: URL? = nil
    var state: PeerJobState = .queued
    var work: Task<Void, Never>?
    /// The CLI's own word on when its limit resets, seen during the turn.
    var limit: UsageLimit? = nil
    /// Monotonic start instant of its latest turn, and whether that turn started a tool.
    var started: ContinuousClock.Instant? = nil
    var toolRan = false
    /// Original CLI if this job failed over to `agent` because that CLI hit a limit.
    var reroutedFrom: HarnessDriver? = nil
    /// Its bot's name on the run's board; follow-up and revise turns share it.
    var member: String? = nil
  }

  /// Why a CLI's jobs wait after its usage or rate limit. All scheduling uses `ContinuousClock` so
  /// wall-clock adjustments or early wakeups never stall the queue; `display` is for status text.
  private enum Hold {
    /// It named its reset: none of its jobs starts before `at`.
    case until(at: ContinuousClock.Instant, display: Date)
    /// It named none: started at `began`; after `misses` refusals in a row, one job tries at `next`
    /// and the rest wait for it. Only a job started at or after `began` that gets through ends it.
    case unclear(misses: Int, base: TimeInterval, began: ContinuousClock.Instant, next: ContinuousClock.Instant, display: Date)
  }

  private enum Kind { case ask, bridge, burst, swarm }

  private struct Run {
    var id: String
    var kind: Kind
    var owner: Seat
    var ownerTask: String
    var jobs: [Job] = []
    /// A bridge or swarm decides when it is done; an ask or burst is done when every job is.
    var finished = false
    var approved = false
    /// The board this run's jobs sit on, by id.
    var board: String? = nil
    var plan: SwarmPlan? = nil
    var coordinatorTask: Task<Void, Never>? = nil
    var settled: Bool { (kind == .bridge || kind == .swarm) ? finished : jobs.allSatisfy(\.state.settled) }
  }

  private var seats: [String: Seat] = [:]
  private var runs: [String: Run] = [:]
  private var boards: [String: Live] = [:]
  private var order: [String] = []
  private var made = 0
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// Each CLI that reached its usage or rate limit.
  private var holds: [HarnessDriver: Hold] = [:]
  /// At most one active wakeup timer per held CLI, keyed by its monotonic deadline.
  private var wakeTasks: [HarnessDriver: (at: ContinuousClock.Instant, task: Task<Void, Never>)] = [:]

  public init(engines: Engines, host: (any PeerHost)? = nil, limits: Limits = Limits()) {
    self.engines = engines
    self.host = host
    self.limits = limits
  }

  public func use(host: any PeerHost) { self.host = host }

  /// A task whose agent may use the team tools, at depth 0.
  public func register(task: String, caller: PeerCaller) {
    seats[task] = Seat(caller: caller, root: caller.thread, rootTask: task, chain: [caller.cli], depth: 0)
  }

  /// The caller's run stopped or finished: every run it started stops, and theirs in turn.
  /// Settled runs for this caller are evicted so `Peers` does not grow without bound.
  public func callerEnded(_ thread: ThreadKey) {
    seats = seats.filter { $0.value.caller.thread != thread }
    for id in order where runs[id]?.owner.caller.thread == thread { stop(id) }
    let evicted = Set(order.filter { id in
      guard let r = runs[id] else { return true }
      return r.owner.caller.thread == thread && r.settled
    })
    if !evicted.isEmpty {
      for id in evicted { runs.removeValue(forKey: id) }
      order.removeAll { evicted.contains($0) }
      let used = Set(runs.values.compactMap(\.board))
      boards = boards.filter { used.contains($0.key) }
    }
  }

  public func handle(_ call: PeerCall, task: String) async -> PeerReply {
    guard let seat = seats[task] else { return PeerReply("Team tools are not available in this run.", isError: true) }
    guard host != nil else { return PeerReply("Team tools are not set up in this build.", isError: true) }
    let window = await inlineWindow(seat.caller.cli)
    switch call {
    case .ask(let agents, let question):
      if let blocked = blocked(seat, agents) { return PeerReply(blocked.text) }
      let resolved = await resolveHeld(agents.map { ($0, nil as String?, question) }, seat: seat, uniqueCLIs: true)
      let id = open(.ask, seat, task, resolved)
      return await answer([id], within: window, earlyReturnWhenHeld: true)
    case .burst(let jobs):
      if let blocked = blocked(seat, jobs.map(\.agent)) { return PeerReply(blocked.text) }
      let resolved = await resolveHeld(jobs.map { ($0.agent, nil as String?, $0.prompt) }, seat: seat, uniqueCLIs: false)
      let id = open(.burst, seat, task, resolved)
      return await answer([id], within: window, earlyReturnWhenHeld: true)
    case .bridge(let writer, let reviewer, let brief, let rounds):
      if let blocked = blocked(seat, [writer, reviewer]) { return PeerReply(blocked.text) }
      let id = open(.bridge, seat, task, [])
      runs[id]?.coordinatorTask = Task { await self.bridge(id, writer: writer, reviewer: reviewer, brief: brief, rounds: rounds) }
      return await answer([id], within: window)
    case .swarm(let spec):
      // Swarms allow same-CLI workers and verifiers so single-subscription users are never locked out;
      // only recursion depth is bounded.
      if let blocked = blockedDepth(seat) { return PeerReply(blocked.text) }
      let id = open(.swarm, seat, task, [])
      runs[id]?.coordinatorTask = Task { await self.swarm(id, spec: spec) }
      return await answer([id], within: window)
    case .wait(let asked, let seconds):
      let mine = order.filter { runs[$0]?.owner.caller.thread == seat.caller.thread }
      let unknown = asked.filter { !mine.contains($0) }
      if !unknown.isEmpty { return PeerReply("No run of yours is called \(unknown.joined(separator: ", ")).", isError: true) }
      let ids = asked.isEmpty ? mine : asked
      return await answer(ids, within: seconds.map { min(.seconds($0), window) } ?? window)
    case .stop(let one):
      let mine = order.filter { runs[$0]?.owner.caller.thread == seat.caller.thread }
      if let one, !mine.contains(one) { return PeerReply("No run of yours is called \(one).", isError: true) }
      let ids = one.map { [$0] } ?? mine
      for id in ids { stop(id) }
      return PeerReply(PeerTools.render(reports(ids)))
    }
  }

  // MARK: Rules

  private func blockedDepth(_ seat: Seat) -> Blocked? {
    if seat.depth >= limits.maxDepth {
      return Blocked(
        "team tools stop \(limits.maxDepth) calls deep, and this agent was called that deep",
        routes: .init("do this part yourself", "put what is left in your reply, and the agent that called you hands it on"))
    }
    return nil
  }

  /// A normal result with routes, never `isError` (R17): the call is the one thing that does not run.
  private func blocked(_ seat: Seat, _ agents: [HarnessDriver]) -> Blocked? {
    if let depthBlocked = blockedDepth(seat) { return depthBlocked }
    let looped = agents.filter(seat.chain.contains)
    if !looped.isEmpty {
      let chain = seat.chain.map(\.rawValue).joined(separator: " > ")
      return Blocked(
        "\(looped.map(\.rawValue).joined(separator: ", ")) is already in this chain of calls (\(chain)), and an agent cannot call itself or an agent that called it",
        routes: .init("call an app that is not in the chain", "do this part yourself"))
    }
    return nil
  }

  private func inlineWindow(_ cli: HarnessDriver) async -> Duration {
    guard let wait = await engines.cardWait(for: cli) else { return min(limits.inlineUnknown, limits.inlineCap) }
    return min(wait - limits.inlineMargin, limits.inlineCap)
  }

  // MARK: Runs

  /// If a job targets a CLI already held past `failoverThreshold` (or on an unclear limit), try a
  /// safe same-plan/free backup CLI up front so the user does not wait for a known limit.
  private func resolveHeld(
    _ jobs: [(HarnessDriver, String?, String)], seat: Seat, uniqueCLIs: Bool
  ) async -> [(HarnessDriver, String?, String, HarnessDriver?)] {
    let clockNow = ContinuousClock.now
    var assigned = Set(jobs.map(\.0))
    var out: [(HarnessDriver, String?, String, HarnessDriver?)] = []
    for (cli, role, prompt) in jobs {
      if shouldFailoverHeld(cli, now: clockNow) {
        var excluded = Set(seat.chain).union(activeHeldCLIs(now: clockNow))
        excluded.insert(cli)
        if uniqueCLIs { excluded.formUnion(assigned) }
        if let backup = await host?.fallback(from: cli, excluding: excluded) {
          assigned.insert(backup)
          out.append((backup, role, prompt, cli))
          continue
        }
      }
      out.append((cli, role, prompt, nil))
    }
    return out
  }

  private func open(_ kind: Kind, _ seat: Seat, _ task: String, _ jobs: [(HarnessDriver, String?, String, HarnessDriver?)] = []) -> String {
    made += 1
    let id = "peer-\(made)"
    runs[id] = Run(id: id, kind: kind, owner: seat, ownerTask: task)
    // A bot on a board that calls other agents seats them as its helpers on that board.
    if kind != .swarm, let place = seat.place, boards[place.board] != nil { runs[id]!.board = place.board }
    order.append(id)
    for job in jobs { add(id, agent: job.0, role: job.1, prompt: job.2, reroutedFrom: job.3) }
    pump()
    return id
  }

  @discardableResult
  private func add(
    _ id: String, agent: HarnessDriver, role: String?, prompt: String, accessOverride: Access? = nil,
    shares: URL? = nil, reroutedFrom: HarnessDriver? = nil, member: String? = nil
  ) -> Int {
    let index = runs[id]!.jobs.count
    var member = member
    if member == nil, runs[id]!.kind != .swarm, let place = runs[id]!.owner.place, let bid = runs[id]!.board {
      member = boards[bid]?.board.unusedName("\(place.member)-\(agent.rawValue)")
      if let name = member {
        boards[bid]!.board.register(
          name: name, role: .helper, workspace: .inherit, parent: place.member, agent: agent.displayName,
          task: String(prompt.prefix(200)))
        post(bid, author: place.member, text: SwarmPrompts.ask(prompt, to: name), kind: .brief)
      }
    }
    runs[id]!.jobs.append(Job(
      agent: agent, role: role, prompt: prompt,
      thread: ThreadKey("\(runs[id]!.owner.caller.thread.id)>\(id).\(index)"),
      accessOverride: accessOverride, shares: shares, reroutedFrom: reroutedFrom, member: member))
    return index
  }

  /// Starts queued jobs, oldest first. A CLI past its limit starts none until it resets, or only
  /// the one job that tries whether its limit has cleared.
  private func pump() {
    let clockNow = ContinuousClock.now
    for id in order {
      guard let run = runs[id] else { continue }
      for index in run.jobs.indices where runs[id]!.jobs[index].state.unstarted {
        if let held = held(runs[id]!.jobs[index].agent, now: clockNow) {
          runs[id]!.jobs[index].state = held
          continue
        }
        runs[id]!.jobs[index].state = .queued
        if let folder = runs[id]!.jobs[index].shares, writing(in: folder) { continue }
        if run.owner.depth > 0, working(where: { $0.owner.caller.thread == run.owner.caller.thread }) > 0 { break }
        runs[id]!.jobs[index].state = .working
        runs[id]!.jobs[index].started = clockNow
        runs[id]!.jobs[index].toolRan = false
        runs[id]!.jobs[index].limit = nil
        runs[id]!.jobs[index].work = Task { await self.run(id, index) }
      }
    }
  }

  /// What `cli`'s next job reads while its limit holds it, or nil when it may start. Always ensures
  /// a monotonic wakeup timer is active whenever a hold stays in the future.
  private func held(_ cli: HarnessDriver, now: ContinuousClock.Instant) -> PeerJobState? {
    switch holds[cli] {
    case .until(let at, let display)? where at > now:
      scheduleWake(for: cli, at: at)
      return .limited(until: display)
    case .until?:
      holds[cli] = nil
      wakeTasks.removeValue(forKey: cli)?.task.cancel()
    case .unclear(_, _, _, let next, let display)? where next > now:
      scheduleWake(for: cli, at: next)
      return .limitUnclear(checksAt: display)
    case .unclear(_, _, _, let next, _)? where trying(cli, since: next):
      return .limitUnclear(checksAt: nil)
    // The wait is over and no job tries yet: this one does.
    case .unclear?, nil:
      return nil
    }
    return nil
  }

  private func shouldFailoverHeld(_ cli: HarnessDriver, now: ContinuousClock.Instant) -> Bool {
    switch holds[cli] {
    case .until(let at, _)?:
      return at > now + .seconds(limits.failoverThreshold)
    case .unclear(_, _, _, let next, _)?:
      return next > now || trying(cli, since: next)
    case nil:
      return false
    }
  }

  private func activeHeldCLIs(now: ContinuousClock.Instant) -> Set<HarnessDriver> {
    var out = Set<HarnessDriver>()
    for (cli, hold) in holds {
      switch hold {
      case .until(let at, _) where at > now: out.insert(cli)
      case .unclear: out.insert(cli)
      default: break
      }
    }
    return out
  }

  private func scheduleWake(for cli: HarnessDriver, at deadline: ContinuousClock.Instant) {
    if let existing = wakeTasks[cli], existing.at <= deadline { return }
    wakeTasks[cli]?.task.cancel()
    let task = Task {
      while ContinuousClock.now < deadline {
        try? await Task.sleep(until: deadline, clock: .continuous)
        if Task.isCancelled { return }
      }
      self.wakeHold(for: cli, expected: deadline)
    }
    wakeTasks[cli] = (deadline, task)
  }

  private func wakeHold(for cli: HarnessDriver, expected: ContinuousClock.Instant) {
    if wakeTasks[cli]?.at == expected { wakeTasks.removeValue(forKey: cli) }
    changed()
  }

  /// A job of `cli` that started at or after `since` still runs.
  private func trying(_ cli: HarnessDriver, since: ContinuousClock.Instant) -> Bool {
    runs.values.contains { $0.jobs.contains { $0.agent == cli && $0.state.running && ($0.started.map { $0 >= since } ?? false) } }
  }

  private func working(where match: (Run) -> Bool) -> Int {
    runs.values.filter(match).reduce(0) { $0 + $1.jobs.filter(\.state.running).count }
  }

  private func writing(in folder: URL) -> Bool {
    runs.values.contains { $0.jobs.contains { $0.state.running && $0.shares == folder } }
  }

  private func run(_ id: String, _ index: Int) async {
    guard let run = runs[id], let host else { return }
    let job = run.jobs[index]
    let owner = run.owner
    let mayCall = owner.depth + 1 < limits.maxDepth
    var stable = SwarmPrompts.callee(agent: job.agent.displayName, caller: owner.caller.cli.displayName, mayCall: mayCall)
    let keepGoing = await host.keepsGoing(task: owner.rootTask)
    if keepGoing { stable += " " + SwarmPrompts.askMark }
    let callee = PeerCallee(
      thread: job.thread, cli: job.agent, access: job.accessOverride ?? owner.caller.access,
      prompt: TurnPrompt(stable: stable, volatile: "", message: job.prompt, recovery: nil),
      callerTask: run.ownerTask, mayCall: mayCall)
    var task: String?
    let state: PeerJobState
    do {
      let request = try await host.request(for: callee)
      task = request.taskID
      seats[request.taskID] = Seat(
        caller: PeerCaller(thread: job.thread, cli: job.agent, access: request.access), root: owner.root,
        rootTask: owner.rootTask, chain: owner.chain + [job.agent], depth: owner.depth + 1,
        place: run.board.flatMap { board in job.member.map { Place(board: board, member: $0) } })
      try Task.checkCancellation()
      let seen: @Sendable (EngineEvent) async -> Void = { await self.saw($0, id, index) }
      var answer = try await engines.ask(request, seen: seen)
      if keepGoing, let question = RelayMarks.after(RelayUnattended.inputMark, in: answer) {
        var next = request
        next.prompt.message = SwarmPrompts.keepGoing(question: question, work: job.prompt)
        try Task.checkCancellation()
        answer = try await engines.ask(next, seen: seen)
      }
      state = await host.holdsCard(task: request.taskID) ? .parked : .answered(answer)
    } catch StopReason.stopped {
      state = .stopped
    } catch is CancellationError {
      state = .stopped
    } catch StopReason.usageLimit(let words) {
      state = await limited(id, index, "usage limit", isRateLimit: false, words: words)
    } catch StopReason.failed(let why) where HarnessRetry.classify(.message(why)) == .transient(.rateLimited) {
      state = await limited(id, index, "rate limit", isRateLimit: true, words: why)
    } catch StopReason.failed(let why) {
      state = .failed(why)
    } catch {
      state = .failed(String(describing: error))
    }
    // Only a job started after the unclear hold began proves the limit cleared; an older in-flight
    // job finishing must not drop the hold and release the queue into the limit.
    if case .unclear(_, _, let began, _, _)? = holds[job.agent], state.through,
      let started = job.started, started >= began
    {
      holds[job.agent] = nil
      wakeTasks.removeValue(forKey: job.agent)?.task.cancel()
    }
    callerEnded(job.thread)
    await engines.close(job.thread)
    if let task { await host.release(task: task) }
    if runs[id]?.jobs[index].state.settled == false { runs[id]!.jobs[index].state = state }
    reportOnBoard(id, index)
    changed()
  }

  /// A bot's turn ended: its answer, or why it failed, goes on the board to the bot that started it.
  private func reportOnBoard(_ id: String, _ index: Int) {
    guard let run = runs[id], let bid = run.board, let member = run.jobs[index].member,
      let parent = boards[bid]?.board.members[member]?.parent
    else { return }
    switch run.jobs[index].state {
    case .answered(let answer): post(bid, author: member, text: "@\(parent) [done] \(answer)", kind: .done)
    case .failed(let why): post(bid, author: member, text: "@\(parent) [stall] \(why)", kind: .stall)
    default: break
    }
  }

  private func saw(_ event: EngineEvent, _ id: String, _ index: Int) {
    if case .limitReached(let limit) = event { runs[id]?.jobs[index].limit = limit }
    if case .toolStarted = event { runs[id]?.jobs[index].toolRan = true }
    guard runs[id]?.jobs[index].state.running == true else { return }
    if case .waiting = event { runs[id]!.jobs[index].state = .waitingForMemory } else { runs[id]!.jobs[index].state = .working }
  }

  /// Job `index`'s CLI reached its limit. A reset it named holds its jobs until then. With none,
  /// one job tries again after a wait that doubles with each refusal (`rateProbeFirst` for a rate
  /// limit, `probeFirst` for a usage limit, up to `probeMost` and at most `maxUnclearProbes` tries),
  /// and an answer from a post-hold try releases the rest. When the job ran no tool and the wait is
  /// long or unnamed, try a safe same-plan/free backup CLI immediately before waiting. Hard billing
  /// or credit exhaustion with no reset time fails fast instead of looping.
  private func limited(_ id: String, _ index: Int, _ what: String, isRateLimit: Bool, words: String) async -> PeerJobState {
    guard let run = runs[id], index < run.jobs.count else { return .stopped }
    let job = run.jobs[index]
    let cli = job.agent
    let now = Date()
    let clockNow = ContinuousClock.now
    // A reset the turn outlived counts as none, so the job cannot restart at once and loop.
    let named = (job.limit?.resetsAt ?? UsageLimit.text(words, harness: cli, now: now)?.resetsAt
      ?? UsageLimit.retryAfter(words, now: now)).flatMap { $0 > now ? $0 : nil }
    let billingHardStop = named == nil && !isRateLimit && UsageLimit.needsBilling(words)
    var exceededProbes = false

    if let named {
      let delay = max(0, named.timeIntervalSince(now))
      let deadline = clockNow + .seconds(delay)
      if case .until(let heldAt, _)? = holds[cli], heldAt > deadline {} else {
        holds[cli] = .until(at: deadline, display: named)
      }
      await host?.noteLimit(cli: cli, until: named)
    } else if !billingHardStop {
      let initialBase = isRateLimit ? limits.rateProbeFirst : limits.probeFirst
      switch holds[cli] {
      case .until(let resetAt, _)? where resetAt > clockNow:
        break
      // A job that started before this wait began brings old news; only the try counts.
      case .unclear(let misses, let base, let began, let next, _)?:
        if let started = job.started, started >= next {
          let nextMisses = misses + 1
          let effectiveBase = min(base, initialBase)
          let delay = gap(nextMisses, base: effectiveBase)
          holds[cli] = .unclear(
            misses: nextMisses, base: effectiveBase, began: began,
            next: clockNow + .seconds(delay), display: now.addingTimeInterval(delay))
          if nextMisses > limits.maxUnclearProbes { exceededProbes = true }
        }
      default:
        let delay = gap(1, base: initialBase)
        holds[cli] = .unclear(
          misses: 1, base: initialBase, began: clockNow,
          next: clockNow + .seconds(delay), display: now.addingTimeInterval(delay))
      }
      await host?.noteLimit(cli: cli, until: nil)
    }

    // Try a safe same-plan/free backup CLI right away when no tool ran and waiting would take long.
    let worthFailover = named.map { $0.timeIntervalSince(now) > limits.failoverThreshold } ?? true
    if !job.toolRan, job.reroutedFrom == nil, worthFailover {
      var excluded = Set(run.owner.chain).union(activeHeldCLIs(now: clockNow))
      excluded.insert(cli)
      if run.kind == .ask {
        for other in run.jobs { excluded.insert(other.agent) }
      }
      if let backup = await host?.fallback(from: cli, excluding: excluded),
        runs[id]?.jobs[index].state.settled == false
      {
        runs[id]!.jobs[index].reroutedFrom = cli
        runs[id]!.jobs[index].agent = backup
        // The limited CLI's process is still shutting down on the old thread; the backup never starts over it.
        runs[id]!.jobs[index].thread = ThreadKey("\(job.thread.id).\(backup.rawValue)")
        runs[id]!.jobs[index].limit = nil
        if case .until(let at, _)? = holds[cli], at > clockNow { scheduleWake(for: cli, at: at) }
        else if case .unclear(_, _, _, let next, _)? = holds[cli], next > clockNow { scheduleWake(for: cli, at: next) }
        return .queued
      }
    }

    if billingHardStop {
      return .failed("\(cli.displayName) stopped for a billing or credit limit with no reset time named.")
    }

    let wait: String
    let wakeAt: ContinuousClock.Instant
    switch holds[cli] {
    case .until(let at, let reset)?:
      wakeAt = at
      wait = "Its next jobs start by themselves at \(UsageLimit.when(reset, now: now))."
    case .unclear(_, _, _, let next, let display)?:
      wakeAt = next
      wait = "It named no reset time, so one of its jobs checks again at \(UsageLimit.when(display, now: now)) and the rest start once one gets through."
    case nil:
      return .queued
    }
    scheduleWake(for: cli, at: wakeAt)
    guard !job.toolRan else {
      return .failed("\(cli.displayName) reached its \(what) after this job had run tools, so it is not sent again. \(wait)")
    }
    if exceededProbes {
      return .failed("\(cli.displayName) is still at its \(what) after \(limits.maxUnclearProbes) checks with no reset time named.")
    }
    return .queued
  }

  /// The wait before the try after `misses` refusals in a row: `base`, doubling, at most `probeMost`.
  private func gap(_ misses: Int, base: TimeInterval) -> TimeInterval {
    min(base * pow(2, Double(min(misses, 30) - 1)), limits.probeMost)
  }

  /// Stops a run: its queued jobs never start, its running ones stop with their whole tree.
  private func stop(_ id: String) {
    guard let run = runs[id] else { return }
    run.coordinatorTask?.cancel()
    for index in run.jobs.indices where !run.jobs[index].state.settled {
      run.jobs[index].work?.cancel()
      runs[id]!.jobs[index].state = .stopped
    }
    runs[id]!.finished = true
    // A stopped swarm never reaches its own end, so its board ends here.
    if run.kind == .swarm, run.owner.place == nil, let bid = run.board { boards[bid]?.board.finish() }
    changed()
  }

  private static func readOnlyAccess(_ access: Access) -> Access {
    switch access {
    case .task(let folder): return .project(folder: folder, level: .review)
    case .project(let folder, _): return .project(folder: folder, level: .review)
    case .answer, .web, .library, .ownSetup: return access
    }
  }

  /// The folder a writer with `access` would change, if any.
  private static func writableFolder(_ access: Access) -> URL? {
    switch access {
    case .task(let folder), .project(let folder, _): return folder.standardizedFileURL
    case .answer, .web, .library, .ownSetup: return nil
    }
  }

  /// `access` at the same level, moved to `folder`.
  private static func access(_ access: Access, in folder: URL) -> Access {
    switch access {
    case .task: return .task(folder: folder)
    case .project(_, let level): return .project(folder: folder, level: level)
    case .answer, .web, .library, .ownSetup: return access
    }
  }

  /// Each writer's diff, for the verifier, whose own folder does not hold the changes yet.
  private static func changes(_ trees: [(name: String, handle: SwarmWorktree.Handle)]) async -> String {
    var text = ""
    for (name, handle) in trees {
      let diff = await Task.detached { SwarmWorktree.diff(handle) }.value ?? "(git could not read the changes)"
      let shown = diff.isEmpty ? "(no changes)" : String(diff.prefix(20_000)) + (diff.count > 20_000 ? "\n(cut here; the rest is in the worktree)" : "")
      text += "\n\n\(name) worked in its own worktree, \(handle.folder.path), and its changes are not in your folder yet. Its diff:\n\(shown)"
    }
    return text
  }

  /// Serein's own line in a swarm's result. It rides as a settled job, the one thing
  /// `PeerTools.render` lists per run.
  private func report(_ id: String, _ text: String, failed: Bool) {
    guard let run = runs[id] else { return }
    runs[id]!.jobs.append(Job(
      agent: run.owner.caller.cli, role: "merge into your folder", prompt: "",
      thread: ThreadKey("\(run.owner.caller.thread.id)>\(id).\(run.jobs.count)"), state: failed ? .failed(text) : .answered(text)))
  }

  /// Runs parallel swarm workers over a shared `SwarmBoard` with an optional read-only verifier
  /// checking `#seq` outputs and requesting targeted revisions. A worker's own swarm joins the
  /// board it sits on, led by that worker; any other swarm opens a new board.
  private func swarm(_ id: String, spec: PeerSwarmRequest) async {
    guard let run = runs[id] else { return }
    let ownerAccess = run.owner.caller.access
    let bid: String
    let lead: String
    let opened: Bool
    if let place = run.owner.place, boards[place.board] != nil {
      (bid, lead, opened) = (place.board, place.member, false)
    } else {
      (bid, lead, opened) = (UUID().uuidString, "coordinator", true)
      var board = SwarmBoard(id: bid, goal: spec.goal)
      board.register(name: lead, role: .coordinator, workspace: .inherit, agent: run.owner.caller.cli.displayName, task: spec.goal)
      boards[bid] = Live(board: board, task: run.owner.rootTask)
    }
    runs[id]?.board = bid
    var names: [String] = []
    for w in spec.workers {
      let name = boards[bid]!.board.unusedName(w.name)
      names.append(name)
      boards[bid]!.board.register(
        name: name, role: .worker, workspace: w.write ? .worktree : .readOnly, parent: lead, agent: w.agent.displayName, task: w.task)
      post(bid, author: lead, text: SwarmPrompts.brief(goal: spec.goal, slice: w.task, to: name), kind: .brief)
    }
    var verifierName: String?
    if let verifier = spec.verifier {
      let name = boards[bid]!.board.unusedName("verifier")
      verifierName = name
      boards[bid]!.board.register(
        name: name, role: .verifier, workspace: .readOnly, parent: lead, agent: verifier.displayName, task: "Verify the workers' reports")
      publish(bid, force: true)
    }
    var tasks = Dictionary(uniqueKeysWithValues: zip(names, spec.workers.map(\.task)))
    var threads = [SwarmPlan.Thread(id: "t-workers", title: "Execute slices", goal: spec.goal, tasks: names)]
    if let verifierName {
      tasks[verifierName] = "Verify worker outputs"
      threads.append(SwarmPlan.Thread(id: "t-verify", title: "Verify outputs", goal: "Check accuracy and completion", tasks: [verifierName]))
    }
    runs[id]?.plan = SwarmPlan(goal: .init(title: String(spec.goal.prefix(64)), line: spec.goal), tasks: tasks, threads: threads)

    // In a git repo each writer gets its own worktree; elsewhere writers take turns in the folder.
    let ownerFolder = Self.writableFolder(ownerAccess)
    let readOnly = Self.readOnlyAccess(ownerAccess)
    var trees: [(name: String, handle: SwarmWorktree.Handle)] = []
    if let ownerFolder, let base = await Task.detached(operation: { SwarmWorktree.base(for: ownerFolder, run: id) }).value {
      for (w, name) in zip(spec.workers, names) where w.write {
        do {
          if let handle = try await Task.detached(operation: { try SwarmWorktree.create(repo: ownerFolder, name: name, baseDirectory: base) }).value {
            trees.append((name, handle))
            post(bid, author: lead, text: "@\(name) Your own worktree: \(handle.folder.path)", kind: .update)
          }
        } catch {
          post(bid, author: lead, text: "@\(name) No worktree (\(error.localizedDescription)), so you take turns in \(ownerFolder.path).", kind: .update)
        }
      }
    }
    workspaces[id] = Dictionary(uniqueKeysWithValues: zip(names, spec.workers).map { name, w in
      let workspace: Workspace
      if !w.write {
        workspace = Workspace(mode: .readOnly, access: readOnly, shares: nil)
      } else if let tree = trees.first(where: { $0.name == name }) {
        workspace = Workspace(mode: .worktree, access: Self.access(ownerAccess, in: tree.handle.folder), shares: nil)
      } else {
        workspace = Workspace(mode: .inherit, access: ownerAccess, shares: ownerFolder)
      }
      return (name, workspace)
    })
    func job(_ w: PeerSwarmWorker, _ name: String, _ role: String, _ prompt: String) {
      let workspace = workspaces[id]?[name]
      add(id, agent: w.agent, role: role, prompt: prompt, accessOverride: workspace?.access, shares: workspace?.shares, member: name)
    }

    for (w, name) in zip(spec.workers, names) {
      job(w, name, w.name, SwarmPrompts.worker(goal: spec.goal, name: name, slice: w.task, workspace: workspaces[id]?[name]?.mode ?? .readOnly))
    }
    await settle(id)

    if let verifierCLI = spec.verifier, let verifierName, runs[id]?.finished == false && !Task.isCancelled {
      for round in 1...spec.rounds {
        let reports = answered(id, names, on: bid)
        let changes = await Self.changes(trees)
        let prompt = SwarmPrompts.verifier(round: round, goal: spec.goal, posts: reports, changes: changes)
        guard case .answered(let verdict) = await turn(id, verifierCLI, "verifier, round \(round)", prompt, accessOverride: readOnly, member: verifierName),
          let verdictPost = boards[bid]?.board.lastDone(by: verifierName)
        else { break }
        if verdict.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix(PeerTools.approved) {
          runs[id]?.approved = true
          break
        }
        if round == spec.rounds { break }
        for (w, name) in zip(spec.workers, names) {
          job(w, name, "\(w.name), rev \(round)", SwarmPrompts.revise(goal: spec.goal, name: name, slice: w.task, verdict: verdictPost))
        }
        await settle(id)
      }
    }

    // Merge back only what was signed off; anything else stays in its worktree and is named.
    if let ownerFolder, !trees.isEmpty {
      // A run already evicted by its caller's end counts as stopped.
      let stopped = Task.isCancelled || runs[id]?.finished != false
      let signed = spec.verifier == nil || runs[id]?.approved == true
      var merged: [String] = []
      var kept: [String] = []
      for (name, handle) in trees {
        guard let diff = await Task.detached(operation: { SwarmWorktree.diff(handle) }).value else {
          kept.append("\(name)'s changes stay in \(handle.worktreeURL.path) because git could not read them")
          continue
        }
        if diff.isEmpty {
          await Task.detached { SwarmWorktree.remove(handle) }.value
          continue
        }
        var answered = false
        if let index = latestJob(id, name), case .answered = runs[id]?.jobs[index].state { answered = true }
        let why: String?
        if stopped {
          why = "the swarm was stopped"
        } else if !signed {
          why = "the verifier did not approve them"
        } else if !answered {
          why = "\(name) did not finish its turn"
        } else if let refused = await Task.detached(operation: { SwarmWorktree.apply(diff, to: handle) }).value {
          why = "they do not apply cleanly to \(ownerFolder.path) (\(refused.prefix(200)))"
        } else {
          why = nil
        }
        if let why {
          kept.append("\(name)'s changes stay in \(handle.worktreeURL.path) because \(why)")
        } else {
          merged.append(name)
          await Task.detached { SwarmWorktree.remove(handle) }.value
        }
      }
      var lines = merged.isEmpty ? [] : ["Merged the changes of \(merged.joined(separator: ", ")) into \(ownerFolder.path)."]
      lines += kept.map { $0 + "." }
      let text = lines.isEmpty ? "No writer changed a file." : lines.joined(separator: " ")
      post(bid, author: lead, text: text, kind: .update)
      report(id, text, failed: !kept.isEmpty)
    }

    post(bid, author: lead, text: "[done] Swarm finished.", kind: .done)
    if opened { boards[bid]?.board.finish() }
    workspaces[id] = nil
    runs[id]?.finished = true
    changed()
  }

  /// Where a swarm worker works, so a follow-up turn works there too.
  private struct Workspace {
    var mode: SwarmWorkspaceMode
    var access: Access
    var shares: URL?
  }
  private var workspaces: [String: [String: Workspace]] = [:]

  /// Waits until every job of the swarm, follow-ups the person started included, has settled.
  private func settle(_ id: String) async {
    pump()
    while let run = runs[id], run.jobs.contains(where: { !$0.state.settled }) {
      if Task.isCancelled || run.finished { break }
      await next(until: .now + .seconds(86_400))
    }
  }

  /// The newest job of `member` in run `id`.
  private func latestJob(_ id: String, _ member: String) -> Int? {
    runs[id]?.jobs.lastIndex { $0.member == member }
  }

  /// Each worker's newest report, for those whose newest turn answered.
  private func answered(_ id: String, _ names: [String], on bid: String) -> [SwarmPost] {
    names.compactMap { name in
      guard let index = latestJob(id, name), case .answered = runs[id]?.jobs[index].state else { return nil }
      return boards[bid]?.board.lastDone(by: name)
    }
  }

  // MARK: Board

  /// What happened to the person's words for one bot.
  public enum Delivery: Sendable, Equatable {
    /// They went into its running turn.
    case steered
    /// Its turn had ended, or its app could not take words mid-turn: a new turn started with them.
    case restarted
    /// Its turn had not started: they joined its brief.
    case briefed
    case stopped
    /// The bot is the lead, the chat's own run: the app steers or stops it.
    case lead
    /// The swarm is over, or the bot is not on a live board.
    case ended
  }

  /// The person speaks to one bot from the board. The words show on the board first, then go
  /// straight into that bot's seat, never behind a card.
  public func command(board bid: String, member: String, words: String) async -> Delivery {
    guard let bot = boards[bid]?.board.members[member] else { return .ended }
    post(bid, author: "you", text: "@\(member) \(words)", kind: .update)
    if bot.parent == nil { return .lead }
    guard let (id, index) = seatOf(bid, member) else { return .ended }
    let job = runs[id]!.jobs[index]
    if job.state.running {
      switch await engines.steer(job.thread, AgentPrivacy.redact(words)) {
      case .steered, .indeterminate: return .steered
      case .refused, .handedBack: await halt(id, index)
      }
    } else if job.state.unstarted {
      runs[id]!.jobs[index].prompt += "\n\n" + SwarmPrompts.personSays(words)
      return .briefed
    }
    guard let run = runs[id], !run.finished, seats.values.contains(where: { $0.caller.thread == run.owner.caller.thread }),
      let goal = boards[bid]?.board.goal
    else { return .ended }
    let workspace = workspaces[id]?[member]
    add(
      id, agent: job.agent, role: job.role, prompt: SwarmPrompts.followUp(
        goal: goal, name: member, slice: bot.task ?? "", last: boards[bid]?.board.lastDone(by: member)?.text, words: words),
      accessOverride: workspace?.access ?? job.accessOverride, shares: workspace?.shares ?? job.shares, member: member)
    pump()
    changed()
    return .restarted
  }

  /// The person stops one bot from the board: its turn ends, and so do its helpers'.
  public func stopMember(board bid: String, member: String) async -> Delivery {
    guard let bot = boards[bid]?.board.members[member] else { return .ended }
    if bot.parent == nil { return .lead }
    guard let (id, index) = seatOf(bid, member), runs[id]!.jobs[index].state.settled == false else { return .ended }
    post(bid, author: "you", text: "@\(member) Stop.", kind: .update)
    await halt(id, index)
    changed()
    return .stopped
  }

  /// The run and newest job of `member` on board `bid`.
  private func seatOf(_ bid: String, _ member: String) -> (String, Int)? {
    for id in order where runs[id]?.board == bid {
      if let index = latestJob(id, member) { return (id, index) }
    }
    return nil
  }

  private func halt(_ id: String, _ index: Int) async {
    guard let job = runs[id]?.jobs[index], !job.state.settled else { return }
    job.work?.cancel()
    runs[id]!.jobs[index].state = .stopped
    await engines.stop(job.thread)
  }

  @discardableResult
  private func post(_ bid: String, author: String, text: String, kind: SwarmPost.Kind) -> SwarmPost? {
    guard boards[bid] != nil else { return nil }
    let entry = boards[bid]!.board.post(author: author, text: text, kind: kind)
    publish(bid, force: true)
    return entry
  }

  /// The one way a board leaves Peers. Every bot's state is set from its newest job first, so
  /// the board never shows a bot working with no turn running.
  private func publish(_ bid: String, force: Bool = false) {
    guard var live = boards[bid] else { return }
    var board = live.board
    for run in runs.values where run.board == bid {
      for job in run.jobs {
        guard let member = job.member, let state = Self.boardState(job.state), board.members[member]?.state != state else { continue }
        board.setState(member, to: state)
      }
    }
    if let lead = board.lead, board.members[lead.name]?.state != (board.finished ? .done : .working) {
      board.setState(lead.name, to: board.finished ? .done : .working)
    }
    guard force || board != live.board else { return }
    board.version += 1
    live.board = board
    boards[bid] = live
    let host = host
    Task { await host?.swarmChanged(board, task: live.task) }
  }

  private static func boardState(_ job: PeerJobState) -> SwarmMemberState? {
    switch job {
    case .queued, .parked: return .waiting
    case .working: return .working
    case .waitingForMemory, .limited, .limitUnclear: return .stalled
    case .answered: return .done
    case .failed, .stopped: return .stopped
    }
  }

  private func bridge(_ id: String, writer: HarnessDriver, reviewer: HarnessDriver, brief: String, rounds: Int) async {
    var draft = ""
    var review: String?
    for round in 1...rounds {
      let write =
        review.map {
          "\(brief)\n\nYour last draft:\n\(draft)\n\nThe reviewer's notes:\n\($0)\n\nRevise the draft to answer the notes. Reply with the whole revised draft."
        } ?? brief
      guard case .answered(let text) = await turn(id, writer, "writer, round \(round)", write) else { break }
      draft = text
      let check = "Review this draft against the task. If it is right and complete, reply \(PeerTools.approved) on the first line. Otherwise list what to change.\n\nThe task:\n\(brief)\n\nThe draft:\n\(draft)"
      guard case .answered(let notes) = await turn(id, reviewer, "reviewer, round \(round)", check) else { break }
      if notes.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix(PeerTools.approved) {
        runs[id]?.approved = true
        break
      }
      review = notes
    }
    runs[id]?.finished = true
    changed()
  }

  /// One bridge or verifier turn, queued like any job; `.stopped` once the run was stopped.
  private func turn(
    _ id: String, _ agent: HarnessDriver, _ role: String, _ prompt: String, accessOverride: Access? = nil, member: String? = nil
  ) async -> PeerJobState {
    guard runs[id]?.finished == false else { return .stopped }
    let index = add(id, agent: agent, role: role, prompt: prompt, accessOverride: accessOverride, member: member)
    pump()
    while let state = runs[id]?.jobs[index].state, !state.settled { await next(until: .now + .seconds(86_400)) }
    return runs[id]?.jobs[index].state ?? .stopped
  }

  // MARK: Waiting

  private func answer(_ ids: [String], within window: Duration, earlyReturnWhenHeld: Bool = false) async -> PeerReply {
    let deadline = ContinuousClock.now + window
    while ids.contains(where: { runs[$0]?.settled == false }), ContinuousClock.now < deadline {
      if earlyReturnWhenHeld, allUnsettledHeldPast(ids, deadline: deadline) { break }
      await next(until: deadline)
    }
    return PeerReply(PeerTools.render(reports(ids)))
  }

  /// True when every unsettled job in `ids` is held on a CLI whose next wakeup is past `deadline`,
  /// so waiting out `window` cannot start any of them.
  private func allUnsettledHeldPast(_ ids: [String], deadline: ContinuousClock.Instant) -> Bool {
    var sawHeld = false
    for id in ids {
      guard let run = runs[id], !run.settled else { continue }
      if run.kind == .bridge || run.kind == .swarm { return false }
      for job in run.jobs where !job.state.settled {
        switch job.state {
        case .limited:
          guard case .until(let at, _)? = holds[job.agent], at > deadline else { return false }
          sawHeld = true
        case .limitUnclear(let checksAt):
          guard checksAt != nil, case .unclear(_, _, _, let next, _)? = holds[job.agent], next > deadline else { return false }
          sawHeld = true
        default:
          return false
        }
      }
    }
    return sawHeld
  }

  /// Returns at the next change to any run, or at the deadline.
  private func next(until deadline: ContinuousClock.Instant) async {
    let key = UUID()
    let timer = Task {
      try? await Task.sleep(until: deadline, clock: .continuous)
      self.wake(key)
    }
    await withCheckedContinuation { waiters[key] = $0 }
    timer.cancel()
  }

  private func wake(_ key: UUID) { waiters.removeValue(forKey: key)?.resume() }

  private func changed() {
    pump()
    for bid in boards.keys { publish(bid) }
    let woken = waiters.values
    waiters = [:]
    for waiter in woken { waiter.resume() }
  }

  private func reports(_ ids: [String]) -> [PeerRunReport] {
    ids.compactMap { runs[$0] }.map { run in
      let kind: PeerRunReport.Kind
      switch run.kind {
      case .ask: kind = .ask(count: run.jobs.count)
      case .bridge: kind = .bridge(approved: run.approved)
      case .burst: kind = .burst
      case .swarm: kind = .swarm(verified: run.approved, plan: run.plan)
      }
      return PeerRunReport(
        id: run.id, kind: kind,
        jobs: run.jobs.map { PeerJobReport(agent: $0.agent, role: $0.role, state: $0.state, reroutedFrom: $0.reroutedFrom) },
        settled: run.settled)
    }
  }
}

extension PeerJobState {
  /// Not started yet: queued, or held for its CLI's limit.
  fileprivate var unstarted: Bool {
    switch self {
    case .queued, .limited, .limitUnclear: return true
    default: return false
    }
  }
  /// The CLI took the turn: its limit, if any, has cleared.
  fileprivate var through: Bool {
    switch self {
    case .answered, .parked: return true
    default: return false
    }
  }
  /// Started: its turn runs, or its CLI waits for memory to start.
  fileprivate var running: Bool { self == .working || self == .waitingForMemory }
}
