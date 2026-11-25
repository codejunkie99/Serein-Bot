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
  /// Task `task` stands at Allow all: a callee's question to its caller gets `Peers.keepGoing`
  /// instead of ending the callee's turn.
  func keepsGoing(task: String) async -> Bool
  /// Task `task` holds an open secure card or person step: the callee's turn ended waiting on the person.
  func holdsCard(task: String) async -> Bool
}

extension PeerHost {
  public func keepsGoing(task: String) async -> Bool { false }
  public func holdsCard(task: String) async -> Bool { false }
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
    /// A CLI's limit with no reset named: one of its jobs tries again this long after, the wait
    /// doubling with each try still refused, up to `probeMost`. The CLI already retried for a
    /// minute or two itself, so a sooner try learns nothing; at the most the provider gets one
    /// try each half hour, and the work starts at most that long after the limit clears.
    public var probeFirst: TimeInterval = 2 * 60
    public var probeMost: TimeInterval = 30 * 60
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
    /// When its latest turn started, and whether that turn started a tool.
    var started: Date? = nil
    var toolRan = false
  }

  /// Why a CLI's jobs wait after its usage or rate limit.
  private enum Hold {
    /// It named its reset: none of its jobs starts before then.
    case until(Date)
    /// It named none: after `misses` refusals in a row, one job tries at `next` and the rest wait
    /// for it. The first answer from this CLI ends the hold.
    case unclear(misses: Int, next: Date)
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
    var board: SwarmBoard? = nil
    var plan: SwarmPlan? = nil
    var coordinatorTask: Task<Void, Never>? = nil
    var settled: Bool { (kind == .bridge || kind == .swarm) ? finished : jobs.allSatisfy(\.state.settled) }
  }

  private var seats: [String: Seat] = [:]
  private var runs: [String: Run] = [:]
  private var order: [String] = []
  private var made = 0
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// Each CLI that reached its usage or rate limit.
  private var holds: [HarnessDriver: Hold] = [:]

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
    }
  }

  public func handle(_ call: PeerCall, task: String) async -> PeerReply {
    guard let seat = seats[task] else { return PeerReply("Team tools are not available in this run.", isError: true) }
    guard host != nil else { return PeerReply("Team tools are not set up in this build.", isError: true) }
    let window = await inlineWindow(seat.caller.cli)
    switch call {
    case .ask(let agents, let question):
      if let blocked = blocked(seat, agents) { return PeerReply(blocked.text) }
      let id = open(.ask, seat, task, agents.map { ($0, nil, question) })
      return await answer([id], within: window)
    case .burst(let jobs):
      if let blocked = blocked(seat, jobs.map(\.agent)) { return PeerReply(blocked.text) }
      let id = open(.burst, seat, task, jobs.map { ($0.agent, nil, $0.prompt) })
      return await answer([id], within: window)
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

  private func open(_ kind: Kind, _ seat: Seat, _ task: String, _ jobs: [(HarnessDriver, String?, String)]) -> String {
    made += 1
    let id = "peer-\(made)"
    runs[id] = Run(id: id, kind: kind, owner: seat, ownerTask: task)
    order.append(id)
    for job in jobs { add(id, agent: job.0, role: job.1, prompt: job.2) }
    pump()
    return id
  }

  @discardableResult
  private func add(_ id: String, agent: HarnessDriver, role: String?, prompt: String, accessOverride: Access? = nil, shares: URL? = nil) -> Int {
    let index = runs[id]!.jobs.count
    runs[id]!.jobs.append(Job(
      agent: agent, role: role, prompt: prompt,
      thread: ThreadKey("\(runs[id]!.owner.caller.thread.id)>\(id).\(index)"),
      accessOverride: accessOverride, shares: shares))
    return index
  }

  /// Starts queued jobs, oldest first. A CLI past its limit starts none until it resets, or only
  /// the one job that tries whether its limit has cleared.
  private func pump() {
    let now = Date()
    for id in order {
      guard let run = runs[id] else { continue }
      for index in run.jobs.indices where runs[id]!.jobs[index].state.unstarted {
        if let held = held(runs[id]!.jobs[index].agent, now: now) {
          runs[id]!.jobs[index].state = held
          continue
        }
        runs[id]!.jobs[index].state = .queued
        if let folder = runs[id]!.jobs[index].shares, writing(in: folder) { continue }
        if run.owner.depth > 0, working(where: { $0.owner.caller.thread == run.owner.caller.thread }) > 0 { break }
        runs[id]!.jobs[index].state = .working
        runs[id]!.jobs[index].started = now
        runs[id]!.jobs[index].toolRan = false
        runs[id]!.jobs[index].limit = nil
        runs[id]!.jobs[index].work = Task { await self.run(id, index) }
      }
    }
  }

  /// What `cli`'s next job reads while its limit holds it, or nil when it may start.
  private func held(_ cli: HarnessDriver, now: Date) -> PeerJobState? {
    switch holds[cli] {
    case .until(let reset)? where reset > now: return .limited(until: reset)
    case .until?: holds[cli] = nil
    case .unclear(_, let next)? where next > now: return .limitUnclear(checksAt: next)
    case .unclear(_, let next)? where trying(cli, since: next): return .limitUnclear(checksAt: nil)
    // The wait is over and no job tries yet: this one does.
    case .unclear?, nil: return nil
    }
    return nil
  }

  /// A job of `cli` that started at or after `since` still runs.
  private func trying(_ cli: HarnessDriver, since: Date) -> Bool {
    runs.values.contains { $0.jobs.contains { $0.agent == cli && $0.state.running && ($0.started ?? .distantPast) >= since } }
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
    var stable = "You are \(job.agent.displayName), called by another agent (\(owner.caller.cli.displayName)) from inside a Serein task. You see only this message. Do the work in the folder you were given, then end with the result itself: your last message goes back to the caller as your answer."
    if !mayCall { stable += " You cannot call other agents." }
    let keepGoing = await host.keepsGoing(task: owner.rootTask)
    if keepGoing { stable += " " + Self.askMark }
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
        rootTask: owner.rootTask, chain: owner.chain + [job.agent], depth: owner.depth + 1)
      try Task.checkCancellation()
      let seen: @Sendable (EngineEvent) async -> Void = { await self.saw($0, id, index) }
      var answer = try await engines.ask(request, seen: seen)
      if keepGoing, let question = RelayMarks.after(RelayUnattended.inputMark, in: answer) {
        var next = request
        next.prompt.message = Self.keepGoing(question: question, work: job.prompt)
        try Task.checkCancellation()
        answer = try await engines.ask(next, seen: seen)
      }
      state = await host.holdsCard(task: request.taskID) ? .parked : .answered(answer)
    } catch StopReason.stopped {
      state = .stopped
    } catch is CancellationError {
      state = .stopped
    } catch StopReason.usageLimit(let words) {
      state = limited(id, index, "usage limit", words: words)
    } catch StopReason.failed(let why) where HarnessRetry.classify(.message(why)) == .transient(.rateLimited) {
      state = limited(id, index, "rate limit", words: why)
    } catch StopReason.failed(let why) {
      state = .failed(why)
    } catch {
      state = .failed(String(describing: error))
    }
    if case .unclear? = holds[job.agent], state.through { holds[job.agent] = nil }
    callerEnded(job.thread)
    await engines.close(job.thread)
    if let task { await host.release(task: task) }
    if runs[id]?.jobs[index].state.settled == false { runs[id]!.jobs[index].state = state }
    changed()
  }

  private func saw(_ event: EngineEvent, _ id: String, _ index: Int) {
    if case .limitReached(let limit) = event { runs[id]?.jobs[index].limit = limit }
    if case .toolStarted = event { runs[id]?.jobs[index].toolRan = true }
    guard runs[id]?.jobs[index].state.running == true else { return }
    if case .waiting = event { runs[id]!.jobs[index].state = .waitingForMemory } else { runs[id]!.jobs[index].state = .working }
  }

  /// Job `index`'s CLI reached its limit. A reset it named holds its jobs until then. With none,
  /// one job tries again after a wait that doubles with each refusal (`Limits.probeFirst`), and an
  /// answer releases the rest. The job goes back in line when it ran no tool, since sending it
  /// again repeats nothing; else it fails.
  private func limited(_ id: String, _ index: Int, _ what: String, words: String) -> PeerJobState {
    guard let job = runs[id]?.jobs[index] else { return .stopped }
    let cli = job.agent
    let now = Date()
    // A reset the turn outlived counts as none, so the job cannot restart at once and loop.
    let named = (job.limit?.resetsAt ?? UsageLimit.text(words, harness: cli, now: now)?.resetsAt
      ?? UsageLimit.retryAfter(words, now: now)).flatMap { $0 > now ? $0 : nil }
    if let named {
      if case .until(let held)? = holds[cli], held > named {} else { holds[cli] = .until(named) }
    } else {
      switch holds[cli] {
      case .until(let reset)? where reset > now: break
      // A job that started before this wait began brings old news; only the try counts.
      case .unclear(let misses, let next)?:
        if (job.started ?? .distantPast) >= next { holds[cli] = .unclear(misses: misses + 1, next: now.addingTimeInterval(gap(misses + 1))) }
      default: holds[cli] = .unclear(misses: 1, next: now.addingTimeInterval(gap(1)))
      }
    }
    let wait: String
    let at: Date
    switch holds[cli] {
    case .until(let reset)?:
      at = reset
      wait = "Its next jobs start by themselves at \(UsageLimit.when(reset, now: now))."
    case .unclear(_, let next)?:
      at = next
      wait = "It named no reset time, so one of its jobs checks again at \(UsageLimit.when(next, now: now)) and the rest start once one gets through."
    case nil:
      return .queued
    }
    Task {
      try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
      self.changed()
    }
    guard job.toolRan else { return .queued }
    return .failed("\(cli.displayName) reached its \(what) after this job had run tools, so it is not sent again. \(wait)")
  }

  /// The wait before the try after `misses` refusals in a row: `probeFirst`, doubling, at most `probeMost`.
  private func gap(_ misses: Int) -> TimeInterval {
    min(limits.probeFirst * pow(2, Double(min(misses, 30) - 1)), limits.probeMost)
  }

  /// At Allow all the caller does not stop to answer: a callee marks a question so Serein can
  /// send it back to work once (`keepGoing`).
  static let askMark = "If you need your caller to decide something before you can go on, end your message with \(RelayUnattended.inputMark) followed by the question."
  static func keepGoing(question: String, work: String) -> String {
    "Your caller does not answer questions here. Pick the safest reasonable default, say in one line which you picked, and continue the work.\n\nYour question: \(question.prefix(1_000))\n\nThe work: \(work)"
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
  /// checking `#seq` outputs and requesting targeted revisions.
  private func swarm(_ id: String, spec: PeerSwarmRequest) async {
    guard let ownerAccess = runs[id]?.owner.caller.access else { return }
    var board = SwarmBoard()
    board.register(name: "coordinator", role: .coordinator, workspace: .inherit)
    var workerTasks: [String: String] = [:]
    for w in spec.workers {
      let ws: SwarmWorkspaceMode = w.write ? .worktree : .readOnly
      board.register(name: w.name.lowercased(), role: .worker, workspace: ws)
      workerTasks[w.name.lowercased()] = w.task
      let brief = "@\(w.name.lowercased()) Goal: \(spec.goal)\nYour slice: \(w.task)"
      board.post(author: "coordinator", text: brief, kind: .brief)
    }
    if spec.verifier != nil {
      board.register(name: "verifier", role: .verifier, workspace: .readOnly)
      workerTasks["verifier"] = "Verify worker outputs"
    }
    var threads = [
      SwarmPlan.Thread(id: "t-workers", title: "Execute slices", goal: spec.goal, tasks: spec.workers.map { $0.name.lowercased() }),
    ]
    if spec.verifier != nil {
      threads.append(SwarmPlan.Thread(id: "t-verify", title: "Verify outputs", goal: "Check accuracy and completion", tasks: ["verifier"]))
    }
    runs[id]?.plan = SwarmPlan(goal: .init(title: String(spec.goal.prefix(64)), line: spec.goal), tasks: workerTasks, threads: threads)
    runs[id]?.board = board

    // In a git repo each writer gets its own worktree; elsewhere writers take turns in the folder.
    let ownerFolder = Self.writableFolder(ownerAccess)
    let readOnly = Self.readOnlyAccess(ownerAccess)
    var trees: [(name: String, handle: SwarmWorktree.Handle)] = []
    if let ownerFolder, let base = await Task.detached(operation: { SwarmWorktree.base(for: ownerFolder, run: id) }).value {
      for w in spec.workers where w.write {
        let name = w.name.lowercased()
        do {
          if let handle = try await Task.detached(operation: { try SwarmWorktree.create(repo: ownerFolder, name: name, baseDirectory: base) }).value {
            trees.append((name, handle))
            board.post(author: "coordinator", text: "@\(name) Your own worktree: \(handle.folder.path)", kind: .update)
          }
        } catch {
          board.post(author: "coordinator", text: "@\(name) No worktree (\(error.localizedDescription)), so you take turns in \(ownerFolder.path).", kind: .update)
        }
      }
      runs[id]?.board = board
    }
    func job(_ w: PeerSwarmWorker, _ role: String, _ prompt: String) -> Int {
      guard w.write else { return add(id, agent: w.agent, role: role, prompt: prompt, accessOverride: readOnly) }
      if let tree = trees.first(where: { $0.name == w.name.lowercased() }) {
        return add(id, agent: w.agent, role: role, prompt: prompt, accessOverride: Self.access(ownerAccess, in: tree.handle.folder))
      }
      return add(id, agent: w.agent, role: role, prompt: prompt, accessOverride: ownerAccess, shares: ownerFolder)
    }
    // Each worker's latest job. Only a writer whose latest turn answered is merged.
    var latest: [String: Int] = [:]

    // Launch all workers in parallel.
    let workerIndices: [(worker: PeerSwarmWorker, index: Int)] = spec.workers.map { w in
      let prompt = "Swarm Goal: \(spec.goal)\nYou are '\(w.name)'. Your slice: \(w.task)\nPost a concise completion summary."
      let idx = job(w, w.name, prompt)
      latest[w.name.lowercased()] = idx
      return (w, idx)
    }
    pump()
    for (_, idx) in workerIndices {
      while let state = runs[id]?.jobs[idx].state, !state.settled {
        if Task.isCancelled || runs[id]?.finished == true { break }
        await next(until: .now + .seconds(86_400))
      }
    }

    var workerSeqs: [Int] = []
    for (w, idx) in workerIndices {
      if let state = runs[id]?.jobs[idx].state, case .answered(let answer) = state {
        let target = spec.verifier == nil ? "@coordinator" : "@verifier"
        let posted = board.post(author: w.name.lowercased(), text: "\(target) [done] \(answer)", kind: .done)
        workerSeqs.append(posted.seq)
      }
    }

    if let verifierCLI = spec.verifier, runs[id]?.finished == false && !Task.isCancelled {
      var latestSeqs = workerSeqs
      for round in 1...spec.rounds {
        let refs = latestSeqs.map { "#\($0)" }.joined(separator: ", ")
        let postsText = board.posts(seqs: latestSeqs).map { "#\($0.seq) (\($0.author)): \($0.text)" }.joined(separator: "\n\n")
        let changes = await Self.changes(trees)
        let verifyPrompt = "You are the read-only verifier (round \(round)). Goal: \(spec.goal)\nVerify \(refs):\n\n\(postsText)\(changes)\n\nIf all claims and outputs are verified, start your reply with \(PeerTools.approved). Otherwise state exact fixes needed."
        guard case .answered(let verdict) = await turn(id, verifierCLI, "verifier, round \(round)", verifyPrompt, accessOverride: readOnly) else {
          break
        }
        let vPost = board.post(author: "verifier", text: "@coordinator \(verdict)")
        if verdict.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix(PeerTools.approved) {
          runs[id]?.approved = true
          break
        }
        if round == spec.rounds { break }
        // Ask workers to revise once on the verifier's notes (#vPost.seq).
        var revisedIndices: [(PeerSwarmWorker, Int)] = []
        for w in spec.workers {
          let revPrompt = "Swarm Goal: \(spec.goal)\nVerifier feedback (#\(vPost.seq)):\n\(verdict)\n\nRevise your slice (\(w.task)) and post the updated result."
          let idx = job(w, "\(w.name), rev \(round)", revPrompt)
          latest[w.name.lowercased()] = idx
          revisedIndices.append((w, idx))
        }
        pump()
        latestSeqs = []
        for (w, idx) in revisedIndices {
          while let state = runs[id]?.jobs[idx].state, !state.settled {
            if Task.isCancelled || runs[id]?.finished == true { break }
            await next(until: .now + .seconds(86_400))
          }
          if let state = runs[id]?.jobs[idx].state, case .answered(let answer) = state {
            latestSeqs.append(board.post(author: w.name.lowercased(), text: "@verifier [done] \(answer)", kind: .done).seq)
          }
        }
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
        if let index = latest[name], case .answered = runs[id]?.jobs[index].state { answered = true }
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
      board.post(author: "coordinator", text: text, kind: .update)
      report(id, text, failed: !kept.isEmpty)
    }

    board.post(author: "coordinator", text: "[done] Swarm finished.", kind: .done)
    runs[id]?.board = board
    runs[id]?.finished = true
    changed()
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
  private func turn(_ id: String, _ agent: HarnessDriver, _ role: String, _ prompt: String, accessOverride: Access? = nil) async -> PeerJobState {
    guard runs[id]?.finished == false else { return .stopped }
    let index = add(id, agent: agent, role: role, prompt: prompt, accessOverride: accessOverride)
    pump()
    while let state = runs[id]?.jobs[index].state, !state.settled { await next(until: .now + .seconds(86_400)) }
    return runs[id]?.jobs[index].state ?? .stopped
  }

  // MARK: Waiting

  private func answer(_ ids: [String], within window: Duration) async -> PeerReply {
    let deadline = ContinuousClock.now + window
    while ids.contains(where: { runs[$0]?.settled == false }), ContinuousClock.now < deadline { await next(until: deadline) }
    return PeerReply(PeerTools.render(reports(ids)))
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
        id: run.id, kind: kind, jobs: run.jobs.map { PeerJobReport(agent: $0.agent, role: $0.role, state: $0.state) },
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
