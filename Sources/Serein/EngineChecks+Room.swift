#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// The memory gate before a CLI starts: pure decisions over set readings, then Engines with fake
/// CLIs and a reading the check moves, then the real sampler.
extension AssistantCoreChecks {
  static func engineRoom(_ check: Check) throws {
    try roomDecisions(check)
    try roomTurns(check)
    try roomSampler(check)
  }

  private static let gb: Int64 = 1 << 30

  private static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }

  private static func roomDecisions(_ check: Check) throws {
    let room = EngineRoom()
    let mac = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 4 * gb)
    let short = RoomSnapshot(totalBytes: 8 * gb, availableBytes: gb)
    let nearlyOut = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 200 * EngineRoom.mb)
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    func other(_ id: String, _ state: RoomOccupant.State, footprint: Int64? = nil, recent: Bool = false, used: TimeInterval = 0) -> RoomOccupant {
      RoomOccupant(thread: ThreadKey(id), state: state, footprint: footprint, recent: recent, lastUsed: at.addingTimeInterval(used))
    }
    try check(room.decide(mac, others: [], waited: 0) == .start, "Room: plenty of memory starts at once")
    try check(room.decide(nil, others: [other("b", .working)], waited: 0) == .start, "Room: an unreadable Mac never holds a start")
    try check(room.decide(short, others: [other("b", .working)], waited: 0) == .wait, "Room: short with another task running waits for it")
    try check(
      room.decide(short, others: [other("b", .working), other("new", .idle, used: 50), other("old", .idle, used: 10)], waited: 0)
        == .close(ThreadKey("old")),
      "Room: short with warm idle CLIs closes the least recently used first")
    try check(room.decide(short, others: [], waited: 600) == .start, "Room: alone and short but not nearly out, it starts")
    try check(room.decide(short, others: [other("c", .waitsOnThis)], waited: 0) == .start, "Room: a caller waiting on this start is never waited for")
    try check(room.decide(nearlyOut, others: [], waited: 59) == .wait, "Room: alone and nearly out, it waits for another app to give room")
    try check(room.decide(nearlyOut, others: [], waited: 60) == .cannot, "Room: still nearly out after a minute alone, it cannot start")
    try check(room.decide(nearlyOut, others: [other("b", .working)], waited: 3_600) == .wait, "Room: a running task always leaves hope: it waits")

    // 8 GB: floor 819.2 MB, default share 700 MB.
    let twoShares = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 820 * EngineRoom.mb + 1_400 * EngineRoom.mb)
    try check(room.decide(twoShares, others: [other("b", .working, footprint: 0, recent: true)], waited: 0) == .start, "Room: room for two shares starts beside one just let in")
    let oneShare = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 820 * EngineRoom.mb + 1_000 * EngineRoom.mb)
    try check(room.decide(oneShare, others: [other("b", .working, footprint: 0, recent: true)], waited: 0) == .wait, "Room: a just-let-in CLI's share is held while it grows")
    try check(
      room.decide(oneShare, others: [other("b", .working, footprint: 700 * EngineRoom.mb, recent: true)], waited: 0) == .start,
      "Room: once it has grown into its share nothing more is held")
    try check(
      room.decide(oneShare, others: [other("b", .working, footprint: 4 * gb)], waited: 0) == .wait
        && room.decide(oneShare, others: [other("b", .working, footprint: 100 * EngineRoom.mb)], waited: 0) == .start,
      "Room: settled CLIs set the share, kept between 300 MB and 1.5 GB")
    try check(EngineRoom.waitText(running: 2).contains("2 other tasks are") && !EngineRoom.cannotText.contains("?"), "Room: the lines say what happens and ask nothing")
  }

  private static func roomTurns(_ check: Check) throws {
    let records = RunRecords(root: FileManager.default.temporaryDirectory.appendingPathComponent("engine-room-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: records.root) }
    let reading = RoomReading(RoomSnapshot(totalBytes: 8 * gb, availableBytes: gb))
    func makeEngines(_ host: RoomHost, giveUp: TimeInterval = 60, real: Bool = false) -> Engines {
      let room = real
        ? EngineRoom(tick: .milliseconds(5))
        : EngineRoom(sample: { reading.value }, footprint: { _ in nil }, tick: .milliseconds(5), giveUp: giveUp)
      return Engines(
        drivers: [RoomDriver()], host: host, records: records, sleep: { try? await Task.sleep(for: min($0, .milliseconds(20))) },
        tickEvery: .seconds(3_600), room: room)
    }
    func request(_ thread: String, _ message: String) -> TurnRequest {
      TurnRequest(
        thread: ThreadKey(thread), cli: .codex, executable: URL(fileURLWithPath: "/usr/bin/true"), access: .answer,
        prompt: TurnPrompt(stable: "s", volatile: "v", message: message, recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "task")
    }
    func until(_ done: @Sendable () async -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline { if await done() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
      return false
    }
    func events(_ handle: TurnHandle) async -> [EngineEvent] {
      var seen: [EngineEvent] = []
      for await event in handle.events { seen.append(event) }
      return seen
    }

    let held = try blocking { () async throws -> (spawnedWhileShort: Int, waited: Bool, events: [EngineEvent], spawned: Int) in
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: gb)
      let host = RoomHost()
      let engines = makeEngines(host)
      _ = try await engines.send(request("busy", "HOLD"))
      _ = await until { host.count == 1 }
      let handle = try await engines.send(request("t", "hi"))
      let seen = TurnLog()
      let reader = Task { for await event in handle.events { seen.append(event) } }
      let waited = await until { seen.events.contains { if case .waiting = $0 { return true } else { return false } } }
      try? await Task.sleep(for: .milliseconds(100))
      let whileShort = host.count
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 4 * gb)
      await reader.value
      await engines.shutdown()
      return (whileShort, waited, seen.events, host.count)
    }
    try check(held.spawnedWhileShort == 1 && held.waited, "Room: a start on a short Mac beside a running task holds and says it waits")
    try check(
      held.spawned == 2 && held.events.last == .ended(TurnEnd(.endTurn)) && held.events.filter({ if case .waiting = $0 { return true } else { return false } }).count == 1,
      "Room: once memory is back it starts by itself and finishes, told once")

    let cannot = try blocking { () async throws -> (events: [EngineEvent], spawned: Int) in
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 200 * EngineRoom.mb)
      let host = RoomHost()
      let engines = makeEngines(host, giveUp: 0.2)
      let seen = await events(try await engines.send(request("t", "hi")))
      await engines.shutdown()
      return (seen, host.count)
    }
    try check(
      cannot.spawned == 0 && cannot.events.last == .ended(TurnEnd(.failed(EngineRoom.cannotText))),
      "Room: a Mac that stays nearly out ends the turn with the one line and starts nothing")
    try check(TurnEnd(.failed(EngineRoom.cannotText)).outcome == .failed, "Room: that end reads as a failure, never a question")

    let closed = try blocking { () async throws -> (events: [EngineEvent], warmSignals: [Int32], spawned: Int) in
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: gb)
      let host = RoomHost()
      let engines = makeEngines(host)
      _ = await events(try await engines.send(request("warm", "hi")))
      let seen = await events(try await engines.send(request("t", "hi")))
      let warm = host.first?.signals ?? []
      await engines.shutdown()
      return (seen, warm, host.count)
    }
    try check(
      closed.warmSignals.first == SIGTERM && closed.spawned == 2 && closed.events.last == .ended(TurnEnd(.endTurn)),
      "Room: on a short Mac a warm idle CLI is closed to make room, then the start runs")

    let callee = try blocking { () async throws -> [EngineEvent] in
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: gb)
      let host = RoomHost()
      let engines = makeEngines(host)
      _ = try await engines.send(request("c", "HOLD"))
      _ = await until { host.count == 1 }
      let seen = await events(try await engines.send(request("c>run.0", "hi")))
      await engines.shutdown()
      return seen
    }
    try check(callee.last == .ended(TurnEnd(.endTurn)), "Room: a team tool's callee never waits on the caller that waits on it")

    let prewarm = try blocking { () async throws -> (whileShort: Int, after: [EngineEvent]) in
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: gb)
      let host = RoomHost()
      let engines = makeEngines(host)
      _ = try await engines.send(request("busy", "HOLD"))
      _ = await until { host.count == 1 }
      try await engines.prewarm(request("p", "hi"))
      try? await Task.sleep(for: .milliseconds(100))
      let whileShort = host.count
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 4 * gb)
      let after = await events(try await engines.send(request("p", "hi")))
      await engines.shutdown()
      return (whileShort, after)
    }
    try check(
      prewarm.whileShort == 1 && prewarm.after.last == .ended(TurnEnd(.endTurn)),
      "Room: a prewarm on a short Mac gives up quietly, and the thread's next send still starts")

    // Delay: the real gate against no reading at all, alternating, on the same fake CLI.
    let timing = try blocking { () async throws -> (on: [Double], off: [Double], gate: [Double]) in
      var on: [Double] = [], off: [Double] = []
      for index in 0..<18 {
        let real = index % 2 == 0
        let host = RoomHost()
        let engines = real ? makeEngines(host, real: true) : makeEngines(host)
        if !real { reading.value = nil }
        let clock = ContinuousClock.now
        let seen = await events(try await engines.send(request("t", "hi")))
        let ms = milliseconds(ContinuousClock.now - clock)
        guard seen.last == .ended(TurnEnd(.endTurn)) else { throw SereinError.invalid("FAIL: timed turn did not finish") }
        if real { on.append(ms) } else { off.append(ms) }
        await engines.shutdown()
      }
      var gate: [Double] = []
      let room = EngineRoom()
      for _ in 0..<200 {
        let clock = ContinuousClock.now
        guard room.decide(room.sample(), others: [], waited: 0) != .cannot else { throw SereinError.invalid("FAIL: timed gate refused") }
        gate.append(milliseconds(ContinuousClock.now - clock))
      }
      return (on, off, gate)
    }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    func show(_ value: Double) -> String { String(format: "%.3f", value) }
    let (on, off, gate) = (median(timing.on), median(timing.off), median(timing.gate))
    try check(
      gate < 1 && on - off < 2,
      "Room: a normal start adds no measurable delay (gate \(show(gate)) ms median of 200; send to end \(show(on)) ms with it, \(show(off)) ms without, median of 9 each, ranges \(show(timing.on.min()!))-\(show(timing.on.max()!)) and \(show(timing.off.min()!))-\(show(timing.off.max()!)) ms)")
  }

  /// A caller blocked on its own callee never holds that callee out of the room, and callees of
  /// running callers start ahead of new top-level starts.
  static func roomCallee(_ check: Check) throws {
    let records = RunRecords(root: FileManager.default.temporaryDirectory.appendingPathComponent("room-callee-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: records.root) }
    let reading = RoomReading(nil)
    let plenty = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 4 * gb)
    let short = RoomSnapshot(totalBytes: 8 * gb, availableBytes: gb)
    func world() -> (Engines, RoomHost) {
      let host = RoomHost()
      let room = EngineRoom(sample: { reading.value }, footprint: { _ in nil }, tick: .milliseconds(5), giveUp: 60)
      let engines = Engines(
        drivers: [RoomDriver()], host: host, records: records, sleep: { try? await Task.sleep(for: min($0, .milliseconds(20))) },
        tickEvery: .seconds(3_600), room: room)
      return (engines, host)
    }
    @Sendable func request(_ thread: String, _ message: String) -> TurnRequest {
      TurnRequest(
        thread: ThreadKey(thread), cli: .codex, executable: URL(fileURLWithPath: "/usr/bin/true"), access: .answer,
        prompt: TurnPrompt(stable: thread, volatile: "v", message: message, recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: "task")
    }
    @Sendable func until(_ done: @Sendable () async -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(3)
      while Date() < deadline { if await done() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
      return false
    }
    @Sendable func watch(_ handle: TurnHandle) -> TurnLog {
      let log = TurnLog()
      Task { for await event in handle.events { log.append(event) } }
      return log
    }
    func waits(_ log: TurnLog) -> Bool { log.events.contains { if case .waiting = $0 { return true } else { return false } } }

    let crossed = try blocking { () async throws -> Bool in
      reading.value = plenty
      let (engines, host) = world()
      _ = try await engines.send(request("a", "HOLD"))
      _ = try await engines.send(request("b", "HOLD"))
      _ = await until { host.count == 2 }
      reading.value = short
      let first = watch(try await engines.send(request("b>run.0", "hi")))
      _ = await until { waits(first) || first.events.last == .ended(TurnEnd(.endTurn)) }
      _ = watch(try await engines.send(request("a>run.0", "hi")))
      let ended = await until { first.events.last == .ended(TurnEnd(.endTurn)) }
      await engines.shutdown()
      return ended
    }
    try check(crossed, "Room: two callers each blocked on their own waiting callee never hold those callees out")

    let ordered = try blocking { () async throws -> [String] in
      reading.value = plenty
      let (engines, host) = world()
      _ = try await engines.send(request("busy", "HOLD"))
      _ = try await engines.send(request("a", "HOLD"))
      _ = await until { host.count == 2 }
      reading.value = short
      let top = watch(try await engines.send(request("c", "hi")))
      _ = await until { waits(top) }
      let callee = watch(try await engines.send(request("a>run.0", "hi")))
      _ = await until { waits(callee) }
      // Room for one more start beside the two just let in: floor 819 MB, two held shares, one share.
      reading.value = RoomSnapshot(totalBytes: 8 * gb, availableBytes: 3_000 * EngineRoom.mb)
      _ = await until { host.count == 4 }
      await engines.shutdown()
      return host.order
    }
    try check(ordered == ["busy", "a", "a>run.0", "c"], "Room: a running caller's callee starts ahead of a top-level start that came first (\(ordered))")
  }

  private static func roomSampler(_ check: Check) throws {
    let memory = EngineRoom.macMemory()
    try check(
      memory?.totalBytes == Int64(ProcessInfo.processInfo.physicalMemory) && (memory?.availableBytes ?? -1) > 0
        && (memory?.availableBytes ?? .max) <= (memory?.totalBytes ?? 0),
      "Room: the Mac's reading is its whole memory and a share of it free (\((memory?.availableBytes ?? 0) / EngineRoom.mb) MB of \((memory?.totalBytes ?? 0) / EngineRoom.mb) MB)")
    let own = EngineRoom.groupFootprint(getpgrp()) ?? 0
    try check(own > EngineRoom.mb && own < 64 * gb, "Room: a live group's footprint reads (\(own / EngineRoom.mb) MB for this run's group)")
    try check(EngineRoom.groupFootprint(999_999) == nil, "Room: a group that is gone reads as nothing")
  }
}

private final class RoomReading: @unchecked Sendable {
  private let lock = NSLock()
  private var current: RoomSnapshot?
  init(_ value: RoomSnapshot?) { current = value }
  var value: RoomSnapshot? {
    get { lock.withLock { current } }
    set { lock.withLock { current = newValue } }
  }
}

private final class TurnLog: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [EngineEvent] = []
  var events: [EngineEvent] { lock.withLock { seen } }
  func append(_ event: EngineEvent) { lock.withLock { seen.append(event) } }
}

/// Answers each message at once, except HOLD, which keeps its turn running.
private final class RoomDriver: Driver, @unchecked Sendable {
  let cli = HarnessDriver.codex
  let cardWait = Duration.seconds(118)

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(request, arguments: ["app-server"], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    switch ModeCheck.verify(contract.expectedMode, reported: ["approvalPolicy": "never"], argv: contract.argv) {
    case .failure(let reason): throw reason
    case .success(let mode):
      let (wire, continuation) = AsyncStream<WireEvent>.makeStream()
      return RoomSession(mode: mode, wire: wire, continuation: continuation)
    }
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class RoomSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  let continuation: AsyncStream<WireEvent>.Continuation

  init(mode: VerifiedMode, wire: AsyncStream<WireEvent>, continuation: AsyncStream<WireEvent>.Continuation) {
    self.mode = mode
    self.wire = wire
    self.continuation = continuation
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    continuation.yield(.accepted)
    if prompt.message != "HOLD" { continuation.yield(.turnDone(.endTurn)) }
  }

  func steer(_ text: String) async -> SteerOutcome { .steered }
}

private final class RoomHost: ProcessHosting, @unchecked Sendable {
  private let lock = NSLock()
  private var started: [RoomProcess] = []
  private var names: [String] = []
  var count: Int { lock.withLock { started.count } }
  /// Each start's stable prompt, in start order.
  var order: [String] { lock.withLock { names } }
  var first: RoomProcess? { lock.withLock { started.first } }

  func spawn(_ contract: LaunchContract) throws -> any HostedProcess {
    let process = RoomProcess()
    lock.withLock {
      started.append(process)
      names.append(contract.stablePrompt)
    }
    return process
  }
}

/// A CLI that exits on the first signal.
private final class RoomProcess: HostedProcess, @unchecked Sendable {
  let pgid: pid_t = 4243
  let output: AsyncStream<Data>
  private let outputContinuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var sent: [Int32] = []
  private var alive = true
  private var waiting: [CheckedContinuation<ProcessExit, Never>] = []

  init() { (output, outputContinuation) = AsyncStream<Data>.makeStream() }

  var signals: [Int32] { lock.withLock { sent } }
  var groupAlive: Bool { lock.withLock { alive } }

  func write(_ data: Data) throws {}
  func closeInput() {}

  func signalGroup(_ signal: Int32) {
    let resumed: [CheckedContinuation<ProcessExit, Never>] = lock.withLock {
      sent.append(signal)
      alive = false
      defer { waiting = [] }
      return waiting
    }
    outputContinuation.finish()
    for continuation in resumed { continuation.resume(returning: ProcessExit(status: 0, signaled: true, stderr: "")) }
  }

  func exited() async -> ProcessExit {
    await withCheckedContinuation { continuation in
      let dead = lock.withLock {
        if alive { waiting.append(continuation) }
        return !alive
      }
      if dead { continuation.resume(returning: ProcessExit(status: 0, signaled: true, stderr: "")) }
    }
  }
}
#endif
