import Darwin
import Foundation

/// One reading of the Mac's memory.
struct RoomSnapshot: Sendable, Equatable {
  var totalBytes: Int64
  /// What the kernel counts as free to hand out before memory pressure (`kern.memorystatus_level`).
  var availableBytes: Int64
}

/// Another thread's CLI, as a start that wants room sees it.
struct RoomOccupant: Sendable, Equatable {
  enum State: Sendable, Equatable {
    /// Warm between turns: closing it gives its memory back.
    case idle
    /// Running a turn, or opening: its end gives room.
    case working
    /// A caller whose team tool waits on this start (Peers names callees `caller>run.index`).
    case waitsOnThis
  }

  var thread: ThreadKey
  var state: State
  /// The group's physical footprint; nil where it could not be read.
  var footprint: Int64?
  /// Let in within `EngineRoom.reserve`: still growing, so its share is held.
  var recent: Bool
  var lastUsed: Date
}

/// What a CLI start does with the room it found.
enum RoomDecision: Sendable, Equatable {
  case start
  /// Close this warm, idle CLI first, then look again.
  case close(ThreadKey)
  /// Another turn's end will give room.
  case wait
  /// The Mac stayed nearly out with nothing of Serein's to give back.
  case cannot
}

/// The gate before Engines spawns a CLI: a start waits quietly while the Mac is short, and ends
/// its turn with one line only when waiting cannot help. Lives on the Engines actor.
struct EngineRoom: Sendable {
  var sample: @Sendable () -> RoomSnapshot? = { EngineRoom.macMemory() }
  var footprint: @Sendable (pid_t) -> Int64? = { EngineRoom.groupFootprint($0) }
  var tick: Duration = .seconds(2)
  var giveUp: TimeInterval = 60
  /// When each thread's CLI was let in.
  var admitted: [ThreadKey: Date] = [:]
  /// Waiting starts by generation, first come first started.
  var queue: [Int] = []

  static let mb: Int64 = 1 << 20
  /// One CLI and its MCP servers until one has been measured here: `opencode acp` took 361 MB
  /// before its first prompt and 623 MB with six stdio MCP servers.
  static let engineDefault = 700 * mb
  static let engineMin = 300 * mb
  static let engineMax = 1500 * mb
  static let reserve: TimeInterval = 90
  static let retell: TimeInterval = 60

  /// What the person's own apps and the file cache keep.
  static func floor(_ memory: RoomSnapshot) -> Int64 { max(320 * mb, memory.totalBytes / 10) }
  static func critical(_ memory: RoomSnapshot) -> Int64 { max(160 * mb, memory.totalBytes * 4 / 100) }

  func decide(_ memory: RoomSnapshot?, others: [RoomOccupant], waited: TimeInterval) -> RoomDecision {
    guard let memory else { return .start }
    let settled = others.filter { !$0.recent }.compactMap(\.footprint)
    let need = settled.isEmpty
      ? Self.engineDefault : min(Self.engineMax, max(Self.engineMin, settled.reduce(0, +) / Int64(settled.count)))
    // A CLI let in recently still grows into its share; only what it has not taken yet is held.
    let held = others.filter(\.recent).reduce(Int64(0)) { $0 + max(0, need - ($1.footprint ?? 0)) }
    if memory.availableBytes - Self.floor(memory) - held >= need { return .start }
    if let idle = others.filter({ $0.state == .idle }).min(by: { $0.lastUsed < $1.lastUsed }) { return .close(idle.thread) }
    if others.contains(where: { $0.state == .working }) { return .wait }
    // Alone, a start runs unless the Mac is nearly out; then only another app can give room back.
    if memory.availableBytes >= Self.critical(memory) { return .start }
    return waited < giveUp ? .wait : .cannot
  }

  static func waitText(running: Int) -> String {
    guard running > 0 else { return "Waiting for memory: this Mac is nearly out. This starts by itself when there is room." }
    let tasks = running == 1 ? "1 other task is" : "\(running) other tasks are"
    return "Waiting for memory: \(tasks) running on this Mac, and one more could run it out. This starts by itself when there is room."
  }

  static let cannotText =
    "Not started: this Mac stayed nearly out of memory for a minute with no other Serein task to wait for. Close an app or two, then send it again."

  static func macMemory() -> RoomSnapshot? {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, (0...100).contains(level) else { return nil }
    let total = Int64(ProcessInfo.processInfo.physicalMemory)
    return RoomSnapshot(totalBytes: total, availableBytes: total * Int64(level) / 100)
  }

  static func groupFootprint(_ pgid: pid_t) -> Int64? {
    let members = KernelProcessTable().members(ofGroup: pgid)
    guard !members.isEmpty else { return nil }
    return members.reduce(Int64(0)) { sum, pid in
      var info = rusage_info_v2()
      let read = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
      }
      return sum + (read == 0 ? Int64(info.ri_phys_footprint) : 0)
    }
  }
}

extension Engines {
  /// Holds this thread's CLI start until the Mac has room. Nil lets `open` go on (its own check
  /// still catches a stop); a reason ends the turn.
  func waitForRoom(_ thread: ThreadKey, _ generation: Int) async -> StopReason? {
    let began = Date()
    var told: Date?
    room.queue.append(generation)
    defer { room.queue.removeAll { $0 == generation } }
    while let slot = slots[thread], slot.generation == generation, !slot.stopAsked {
      let others = roomOccupants(except: thread)
      let decision = room.queue.first == generation
        ? room.decide(room.sample(), others: others, waited: Date().timeIntervalSince(began)) : .wait
      // A prewarm never waits or closes another thread's CLI: the send after it asks again.
      if decision != .start, slot.events == nil { return .stopped }
      switch decision {
      case .start:
        room.admitted = room.admitted.filter { Date().timeIntervalSince($0.value) < EngineRoom.reserve }
        room.admitted[thread] = Date()
        return nil
      case .cannot:
        return .failed(EngineRoom.cannotText)
      case .close(let idle):
        guard let warm = slots[idle] else { continue }
        feed(idle, warm.generation, .shutdown)
        // Its memory comes back only once it has exited: never close a second one meanwhile.
        while slots[idle] === warm, slots[thread]?.stopAsked == false { try? await Task.sleep(for: room.tick) }
        continue
      case .wait:
        if told.map({ Date().timeIntervalSince($0) >= EngineRoom.retell }) ?? true {
          slot.events?.yield(.waiting(EngineRoom.waitText(running: others.filter { $0.state == .working }.count)))
          told = Date()
        }
      }
      try? await Task.sleep(for: room.tick)
    }
    return nil
  }

  private func roomOccupants(except thread: ThreadKey) -> [RoomOccupant] {
    slots.compactMap { key, slot in
      guard key != thread, let process = slot.process else { return nil }
      let state: RoomOccupant.State = thread.id.hasPrefix(key.id + ">") ? .waitsOnThis : slot.idle ? .idle : .working
      let recent = room.admitted[key].map { Date().timeIntervalSince($0) < EngineRoom.reserve } ?? false
      return RoomOccupant(thread: key, state: state, footprint: room.footprint(process.pgid), recent: recent, lastUsed: slot.lastUsed)
    }
  }
}
