import Darwin
import Foundation
import OSLog
import SereinCore

/// Runs the agent CLIs. One per app; every turn on every thread goes through it.
public actor Engines {
  public static let shared = Engines()
  private static let log = Logger(subsystem: "app.serein", category: "engines")

  private let drivers: [HarnessDriver: any Driver]
  private let host: any ProcessHosting
  private let records: RunRecords
  private let sleep: Sleep
  private let policy: Policy
  private let now: @Sendable () -> Date
  private let tickEvery: Duration
  var room: EngineRoom

  var slots: [ThreadKey: Slot] = [:]
  /// Generations are unique across slots: a retired process's late exit or wire event never
  /// reaches the slot that replaced it on the same thread.
  private var generations = 0
  private var probes: [ProbeKey: Readiness] = [:]
  private var recordsReady = false
  private var reaping = false
  private var shutDown = false
  private var ladders: [Task<Void, Never>] = []
  /// Generations whose session's wire is still being read, and the exits waiting for it.
  private var wiresOpen: Set<Int> = []
  private var exitsWaiting: [Int: CheckedContinuation<Void, Never>] = [:]
  /// When the turn of a slot dropped with its process ended, for the steer grace.
  private var droppedEnds: [ThreadKey: Date] = [:]
  /// One shell proxy per thread, kept across processes so the port and warm key stay put.
  private var guards: [ThreadKey: ShellGuard] = [:]
  private var cards: (any PayCards)?

  public init() {
    let records = RunRecords()
    self.init(drivers: DriverRegistry.all, host: SereinProcessHost(records: records), records: records)
  }

  init(
    drivers: [any Driver], host: any ProcessHosting, records: RunRecords,
    sleep: @escaping Sleep = { try? await Task.sleep(for: $0) }, policy: Policy = Policy(),
    now: @escaping @Sendable () -> Date = Date.init, tickEvery: Duration = .seconds(30), room: EngineRoom = EngineRoom()
  ) {
    self.drivers = Dictionary(drivers.map { ($0.cli, $0) }) { first, _ in first }
    self.host = host
    self.records = records
    self.sleep = sleep
    self.policy = policy
    self.now = now
    self.tickEvery = tickEvery
    self.room = room
  }

  // MARK: Public

  /// Whether a driver runs this CLI. The app keeps its own launch path for a CLI without one.
  public nonisolated func runs(_ cli: HarnessDriver) -> Bool { drivers[cli] != nil }

  /// The driver's `promptAddition`, for the app to place after the shared core, with the shell
  /// proxy's line for the task's level (`allowsAll`: Allow all).
  public nonisolated func promptAddition(for cli: HarnessDriver, allowsAll: Bool) -> String {
    guard let driver = drivers[cli] else { return "" }
    return [driver.promptAddition, PayGuard.promptLine(allowsAll: allowsAll)].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// The secure cards that answer a shell's payment connections. Until attached, each is refused
  /// with a notice in the turn.
  public func attach(cards: any PayCards) {
    self.cards = cards
    for shellGuard in guards.values { shellGuard.attach(cards) }
  }

  /// Starts a turn. Throws before any process starts; after that every failure arrives as the
  /// handle's single `.ended`.
  public func send(_ request: TurnRequest) async throws -> TurnHandle {
    let (events, continuation) = AsyncStream<EngineEvent>.makeStream()
    try await start(request, events: continuation)
    return TurnHandle(events: events)
  }

  /// Starts the CLI for this thread with no turn, so the first send finds it warm.
  public func prewarm(_ request: TurnRequest) async throws {
    guard request.directHTTP == nil else { return }
    if let slot = slots[request.thread], !slot.idle || slot.contract.warmKey == (try? contract(for: request))?.warmKey { return }
    try await start(request, events: nil)
  }

  /// A pure answer: sends the turn and returns its text. Cancelling the calling task stops it.
  /// Throws the `StopReason` of any turn that did not complete. `seen` gets each event first, in order.
  public func ask(_ request: TurnRequest, seen: @escaping @Sendable (EngineEvent) async -> Void = { _ in }) async throws -> String {
    let handle = try await send(request)
    return try await withTaskCancellationHandler {
      var text = ""
      for await event in handle.events {
        await seen(event)
        switch event {
        case .text(let part): text += part
        case .newMessage: text = ""
        case .ended(let end):
          if end.outcome != .completed { throw end.stopReason }
        default: break
        }
      }
      return text
    } onCancel: {
      Task { await self.stop(request.thread) }
    }
  }

  /// Whether a steer sent now would reach the CLI.
  public func takesWords(_ thread: ThreadKey) -> Bool {
    guard let slot = slots[thread], let session = slot.session, session.steers else { return false }
    switch slot.phase {
    case .awaitingAccept, .running: return true
    default: return false
    }
  }

  func contract(for request: TurnRequest) throws -> LaunchContract {
    guard let driver = drivers[request.cli] else { throw EngineRefusal.notReady(.missing) }
    return try contract(driver, request)
  }

  /// The driver's contract on the thread's shell proxy, with the proxy environment unless the
  /// CLI hands the port to its own shells.
  private func contract(_ driver: any Driver, _ request: TurnRequest) throws -> LaunchContract {
    if request.directHTTP != nil {
      return LaunchContract(request, arguments: [], environment: [:], expectedMode: .reports([:]), network: ShellNetwork.Plan(port: 0))
    }
    var contract = try driver.contract(for: request, network: ShellNetwork.Plan(port: try shellGuard(request.thread).port))
    contract.routesOwnShells = driver.routesOwnShells
    return contract.guarded()
  }

  /// The proxy port for a shell Serein runs itself (`mac_run`): its payment calls ask the same
  /// cards, charged to `task`, with `command` on the card. A task with no chat thread gets a
  /// guard of its own (`taskThread`), closed by `close` at the task's end.
  public func shellPort(thread: ThreadKey?, task: String, command: String) throws -> UInt16 {
    let shellGuard = try shellGuard(thread ?? Self.taskThread(task))
    shellGuard.begin(task: task)
    shellGuard.saw(command: command, task: task)
    return shellGuard.port
  }

  /// The guard key of a task with no chat thread.
  public static func taskThread(_ task: String) -> ThreadKey { ThreadKey("task:" + task) }

  private func shellGuard(_ thread: ThreadKey) throws -> ShellGuard {
    if let existing = guards[thread] { return existing }
    let made = try ShellGuard(thread: thread.id) { [weak self] text in
      Task { await self?.notice(thread, text) }
    }
    made.attach(cards)
    guards[thread] = made
    return made
  }

  private func notice(_ thread: ThreadKey, _ text: String) {
    slots[thread]?.events?.yield(.notice(text))
  }

  private func start(_ original: TurnRequest, events: AsyncStream<EngineEvent>.Continuation?) async throws {
    guard !shutDown else { throw EngineRefusal.notReady(.broken("Serein is quitting.")) }
    guard let driver = drivers[original.cli] else { throw EngineRefusal.notReady(.missing) }
    var request = original
    request.resume = request.scopedResume
    if let refusal = await request.revalidate?() { throw refusal }
    let contract = try contract(driver, request)
    startReaper()
    let thread = request.thread

    if let slot = slots[thread] {
      guard slot.idle else { throw EngineRefusal.threadBusy }
      guards[thread]?.begin(task: request.taskID)
      var changed = contract.warmKey.changed(from: slot.contract.warmKey)
      // The process holds its session's context. A thread that keeps sessions (a scope) and asks
      // for another, or for none after Compact or Edit and rerun, needs a new process.
      if request.sessionScope != nil, request.resume != slot.sessionID { changed.append("session") }
      if changed.isEmpty, request.directHTTP == nil, slot.request.directHTTP == nil {
        guard let events else { return }
        slot.request = request
        slot.events = events
        submit(slot)
        return
      }
      Self.log.info("Replacing a warm \(request.cli.rawValue, privacy: .public) process: \(changed.joined(separator: ", "), privacy: .public) changed")
      retire(thread)
    }

    guards[thread]?.begin(task: request.taskID)
    let slot = Slot(driver: driver, request: request, contract: contract)
    // A replaced process's late exit must never reach the slot that followed it on this thread.
    slot.generation = nextGeneration()
    slot.events = events
    slots[thread] = slot
    droppedEnds[thread] = nil
    Task {
      switch await self.open(thread, slot.generation) {
      case .success: if events != nil { self.submit(slot) }
      case .failure(let reason): self.endUnopened(thread, slot, reason)
      }
    }
  }

  private func submit(_ slot: Slot) {
    let request = slot.request
    let budget: Int?
    if case .task = request.access { budget = nil } else { budget = request.stepBudget }
    feed(request.thread, slot.generation, .submit(request.prompt, at: now(), stepBudget: budget))
  }

  /// Mid-turn input for the thread's running turn. Words the CLI cannot take now, or that come
  /// within 30 s of the last answer, are handed back to send as the next turn.
  public func steer(_ thread: ThreadKey, _ text: String) async -> SteerOutcome {
    guard let slot = slots[thread] else {
      if let ended = droppedEnds[thread], now().timeIntervalSince(ended) < Self.steerGrace { return .handedBack(text) }
      return .refused
    }
    switch slot.phase {
    case .awaitingAccept, .running:
      guard let session = slot.session, session.steers else { return .handedBack(text) }
      return await session.steer(text)
    default:
      if let ended = slot.lastEnded, now().timeIntervalSince(ended) < Self.steerGrace { return .handedBack(text) }
      return .refused
    }
  }

  static let steerGrace: TimeInterval = 30
  /// Pure-answer processes close sooner than chat ones.
  static let answerIdle: TimeInterval = 120
  /// The longest an exit waits for the CLI's last output to reach the machine.
  static let drainWait: Duration = .seconds(2)

  /// Stop: the turn ends `.stopped` once the CLI's whole group is gone. Taken even while the
  /// process is still opening.
  public func stop(_ thread: ThreadKey) {
    guard let slot = slots[thread] else { return }
    if slot.opening {
      slot.stopAsked = true
      // A handshake can take seconds: end the process now rather than after it.
      if let process = slot.process { track(process, ladder: slot.driver.stopLadder) }
    } else {
      feed(thread, slot.generation, .interrupt)
    }
  }

  /// Ends the thread's CLI now, idle or not, instead of leaving it warm for the reaper: for
  /// one-off threads such as a team tool's callee (Peers).
  public func close(_ thread: ThreadKey) {
    guards.removeValue(forKey: thread)?.stop()
    guard let slot = slots[thread] else { return }
    if slot.opening { slot.stopAsked = true } else { feed(thread, slot.generation, .shutdown) }
  }

  /// Cached per binary (path, inode, change time, size), so a reinstall is probed again.
  public func probe(_ cli: HarnessDriver, executable: URL) async -> Readiness {
    guard let driver = drivers[cli] else { return .missing }
    guard let key = ProbeKey(executable) else { return .missing }
    if let known = probes[key] { return known }
    let readiness = await driver.probe(executable: executable)
    probes[key] = readiness
    return readiness
  }

  /// Ends every CLI and removes this run's records. A second call does nothing.
  public func shutdown() async {
    guard !shutDown else { return }
    shutDown = true
    for (thread, slot) in slots {
      if slot.opening { slot.stopAsked = true } else { feed(thread, slot.generation, .shutdown) }
    }
    for ladder in ladders { await ladder.value }
    for shellGuard in guards.values { shellGuard.stop() }
    guards = [:]
    records.removeAll()
  }

  /// At launch: ends the CLI groups a crashed Serein left, matched by its run tag.
  public nonisolated func sweepLeftovers() async {
    await RunSweep.sweep(records, table: KernelProcessTable(), sleep: sleep)
  }

  /// Ends this Serein's CLI groups before it returns: TERM, up to `timeout` for all of them, then
  /// KILL. For a quit, which exits before a Stop's ladder would finish. Blocks the calling thread.
  public nonisolated func endGroupsNow(within timeout: TimeInterval = 2) {
    ProcessGroup.end(RunSweep.own(records, table: KernelProcessTable()), within: timeout)
  }

  /// A SIGTERM (logout, `kill`, launchd) skips the app's quit: this ends the CLI groups first,
  /// then lets the signal end Serein as it would have. Each CLI runs in its own session, so
  /// nothing else would reach it.
  public nonisolated func endGroupsOnSIGTERM() {
    // A handler, not SIG_IGN: an ignored signal stays ignored in every CLI Serein starts.
    signal(SIGTERM) { _ in }
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    source.setEventHandler { [self] in
      endGroupsNow()
      signal(SIGTERM, SIG_DFL)
      kill(getpid(), SIGTERM)
    }
    source.resume()
    Self.terminationSource = source
  }
  nonisolated(unsafe) private static var terminationSource: DispatchSourceSignal?

  /// The longest a secure card may hold a tool call open for this CLI.
  public func cardWait(for cli: HarnessDriver) -> Duration? { drivers[cli]?.cardWait }

  // MARK: Turn loop

  /// Feeds one input to the thread's machine and performs what it returns. Input from a process
  /// the thread has since replaced (`generation`) is dropped.
  func feed(_ thread: ThreadKey, _ generation: Int, _ input: MachineInput) {
    guard let slot = slots[thread], slot.generation == generation else { return }
    if case .wire(.toolStarted(_, _, _, let command?), _) = input { guards[thread]?.saw(command: command, task: slot.request.taskID) }
    let (next, effects) = Machine.step(slot.phase, input, facts: slot.facts, policy: policy)
    slot.phase = next
    if case .ready = next { slot.lastUsed = now() }
    for effect in effects { perform(effect, thread: thread, slot: slot) }
    if case .dead = next, slots[thread] === slot {
      slots[thread] = nil
      droppedEnds[thread] = slot.lastEnded
    }
    let ended = effects.contains { if case .emit(.ended) = $0 { return true }; return false }
    if ended, slot.session?.reusable == false, slots[thread] === slot { retire(thread) }
  }

  private func perform(_ effect: Effect, thread: ThreadKey, slot: Slot) {
    let generation = slot.generation
    switch effect {
    case .send(let prompt):
      guard let session = slot.session else { return }
      let request = slot.request
      Task {
        do { try await session.send(prompt, request: request) } catch {
          self.feed(thread, generation, .wire(.failed(String(describing: error)), at: self.now()))
        }
      }
    case .emit(let event):
      slot.events?.yield(event)
      if case .ended(let end) = event {
        if let id = end.sessionID { slot.sessionID = id }
        slot.events?.finish()
        slot.events = nil
        slot.lastEnded = now()
      }
    case .scheduleRetry(let after):
      Task {
        await self.sleep(after)
        self.feed(thread, generation, .retryDue)
      }
    case .scheduleFinish(let after):
      Task {
        await self.sleep(after)
        self.feed(thread, generation, .finishDue)
      }
    case .relaunch:
      if let process = slot.process { track(process, ladder: slot.driver.stopLadder) }
      slot.generation = nextGeneration()
      slot.process = nil
      slot.session = nil
      let next = slot.generation
      let revalidate = slot.request.revalidate
      Task {
        if let refusal = await revalidate?() {
          self.feed(thread, next, .openFailed(.failed("Not started again: \(refusal)")))
          return
        }
        switch await self.open(thread, next) {
        case .success: self.feed(thread, next, .opened(at: self.now()))
        case .failure(let reason): self.feed(thread, next, .openFailed(reason))
        }
      }
    case .runStopLadder(let steps):
      guard let process = slot.process else {
        let session = slot.session
        Task { await session?.cancel(); self.feed(thread, generation, .stopped) }
        return
      }
      let session = slot.session
      track(process, ladder: steps, first: { await session?.cancel() }) { await self.feed(thread, generation, .stopped) }
    }
  }

  /// Starts the process, then the driver's handshake and mode read-back. Nothing reaches the
  /// machine before the session (and with it the VerifiedMode) exists.
  private func open(_ thread: ThreadKey, _ generation: Int) async -> Result<Void, StopReason> {
    if let slot = slots[thread], let route = slot.request.directHTTP {
      guard slot.generation == generation, !slot.stopAsked, !shutDown else { return .failure(.stopped) }
      let session = DirectHTTPSession(route: route) { [weak self] id, name, arguments in
        await self?.beginDirectTool(thread, generation, id, name, arguments) ?? false
      }
      slot.session = session
      slot.opening = false
      watchWire(thread, generation, session)
      watchClock(thread, generation)
      return .success(())
    }
    if let reason = await waitForRoom(thread, generation) { return .failure(reason) }
    // Stop before the process started: nothing starts.
    guard let slot = slots[thread], slot.generation == generation, !slot.stopAsked, !shutDown else { return .failure(.stopped) }
    let process: EngineProcess
    do {
      try prepareRecords()
      try slot.driver.prepare(slot.contract, request: slot.request)
      process = EngineProcess(try host.spawn(slot.contract))
    } catch {
      return .failure(.failed("Could not start \(slot.request.cli.displayName): \(error)"))
    }
    slot.process = process
    watchExit(thread, generation, process)
    let session: any EngineSession
    do {
      session = try await slot.driver.open(process, contract: slot.contract, request: slot.request)
    } catch {
      track(process, ladder: slot.driver.stopLadder)
      if slot.stopAsked || shutDown { return .failure(.stopped) }
      return .failure(error as? StopReason ?? .failed(String(describing: error)))
    }
    guard slots[thread] === slot, slot.generation == generation, !slot.stopAsked, !shutDown else {
      track(process, ladder: slot.driver.stopLadder)
      return .failure(.stopped)
    }
    slot.session = session
    slot.opening = false
    watchWire(thread, generation, session)
    watchClock(thread, generation)
    return .success(())
  }

  /// Apply the journal and step/loop limits synchronously before dispatch to the host.
  private func beginDirectTool(_ thread: ThreadKey, _ generation: Int, _ id: String, _ name: String, _ arguments: String) -> Bool {
    guard let slot = slots[thread], slot.generation == generation else { return false }
    feed(thread, generation, .wire(.toolStarted(id: id, name: name, arguments: arguments, shellCommand: nil), at: now()))
    if case .running = slot.phase { return true }
    return false
  }

  private func nextGeneration() -> Int {
    generations += 1
    return generations
  }

  /// A CLI that exits while opening can be fed its exit first, which drops the slot; the turn
  /// still gets its end.
  private func endUnopened(_ thread: ThreadKey, _ slot: Slot, _ reason: StopReason) {
    slot.events?.yield(.ended(TurnEnd(reason)))
    slot.events?.finish()
    slot.events = nil
    if slots[thread] === slot { slots[thread] = nil }
  }

  private func retire(_ thread: ThreadKey) {
    guard let slot = slots.removeValue(forKey: thread) else { return }
    droppedEnds[thread] = slot.lastEnded
    guard let process = slot.process else { return }
    track(process, ladder: slot.driver.stopLadder)
  }

  private func track(
    _ process: EngineProcess, ladder: [StopStep], first: (@Sendable () async -> Void)? = nil,
    then: (@Sendable () async -> Void)? = nil
  ) {
    let sleep = sleep
    ladders.append(Task {
      await first?()
      await StopLadder.run(ladder, on: process.hosted, sleep: sleep)
      await then?()
    })
  }

  private func watchExit(_ thread: ThreadKey, _ generation: Int, _ process: EngineProcess) {
    Task {
      let exit = await process.hosted.exited()
      await self.drain(generation)
      self.feed(thread, generation, .exited(exit.signaled ? .signaled : .exited(status: exit.status, stderr: exit.stderr)))
    }
  }

  /// A CLI such as `codex exec` exits right after its last words, which are still on their way
  /// through the pipe and the driver: its exit waits for the wire to finish, at most `drainWait`.
  private func drain(_ generation: Int) async {
    guard wiresOpen.contains(generation) else { return }
    let sleep = sleep
    Task {
      await sleep(Self.drainWait)
      self.exitsWaiting.removeValue(forKey: generation)?.resume()
    }
    await withCheckedContinuation { exitsWaiting[generation] = $0 }
  }

  private func watchWire(_ thread: ThreadKey, _ generation: Int, _ session: any EngineSession) {
    wiresOpen.insert(generation)
    Task {
      for await event in session.wire { self.feed(thread, generation, .wire(event, at: self.now())) }
      self.wiresOpen.remove(generation)
      self.exitsWaiting.removeValue(forKey: generation)?.resume()
    }
  }

  /// Ticks the stuck watch. CPU is not sampled yet, so only the silence ceiling can stop a turn.
  private func watchClock(_ thread: ThreadKey, _ generation: Int) {
    let tickEvery = tickEvery
    Task {
      while self.isCurrent(thread, generation) {
        await self.sleep(tickEvery)
        let tcp = Self.openTCP(group: self.slots[thread]?.process?.pgid)
        self.feed(thread, generation, .tick(self.now(), HarnessStuck.Evidence(cpuPerMinute: nil, openTCP: tcp, logGrew: false)))
      }
    }
  }

  /// Model connections held by the CLI's process group; nil for a turn with no process.
  /// shortcut: helpers that call setsid leave the group and are not counted; walk the
  /// descendants HostedCLI already tracks if one turns out to hold the model connection.
  static func openTCP(group pgid: pid_t?) -> Int? {
    guard let pgid else { return nil }
    let members = KernelProcessTable().members(ofGroup: pgid)
    return HarnessStuck.modelConnections(pids: members.isEmpty ? [pgid] : members)
  }

  private func isCurrent(_ thread: ThreadKey, _ generation: Int) -> Bool {
    slots[thread]?.generation == generation
  }

  private func prepareRecords() throws {
    guard !recordsReady else { return }
    guard let me = KernelProcessTable().live(getpid()) else { throw SereinError.invalid("Cannot read Serein's own start time.") }
    try records.prepare(owner: ProcessGroupRecord.Member(pid: getpid(), started: me.started))
    recordsReady = true
  }

  // MARK: Idle close

  private func startReaper() {
    guard !reaping else { return }
    reaping = true
    Task {
      while !self.shutDown {
        await self.sleep(.seconds(60))
        self.reap(now: self.now())
      }
    }
  }

  /// Closes warm processes idle past `HarnessIdle.closeAfter`.
  func reap(now: Date) {
    for (thread, slot) in slots where slot.idle && slot.process != nil {
      let after = slot.request.access == .answer ? Self.answerIdle : HarnessIdle.closeAfter(lastSeen: slot.lastUsed, now: now)
      if now.timeIntervalSince(slot.lastUsed) >= after {
        feed(thread, slot.generation, .shutdown)
      }
    }
  }
}

/// One thread's process and turn. Only touched on the Engines actor.
final class Slot {
  let driver: any Driver
  var request: TurnRequest
  let contract: LaunchContract
  let facts: Facts
  var phase: Phase = .ready
  var process: EngineProcess?
  var session: (any EngineSession)?
  var generation = 0
  var events: AsyncStream<EngineEvent>.Continuation?
  var lastUsed = Date()
  var opening = true
  var stopAsked = false
  var lastEnded: Date?
  /// The CLI session the process holds: the one it resumed, then the one its last turn reported.
  var sessionID: String?

  init(driver: any Driver, request: TurnRequest, contract: LaunchContract) {
    self.driver = driver
    self.request = request
    sessionID = request.resume
    self.contract = contract
    facts = Facts(expectedMode: contract.expectedMode, argv: contract.argv, ladder: driver.stopLadder, asks: contract.access.asks,
      directHTTP: request.directHTTP != nil)
  }

  var idle: Bool {
    if opening { return false }
    if case .ready = phase { return true }
    return false
  }
}

private struct ProbeKey: Hashable {
  var path: String
  var inode: UInt64
  var changed: Int
  var size: Int64

  init?(_ executable: URL) {
    var info = stat()
    guard stat(executable.path, &info) == 0 else { return nil }
    path = executable.path
    inode = UInt64(info.st_ino)
    changed = info.st_ctimespec.tv_sec
    size = info.st_size
  }
}
