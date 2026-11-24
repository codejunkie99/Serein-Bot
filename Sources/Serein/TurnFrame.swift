import SereinCore

/// What one running turn of Serein's own knows, keyed by its thread, so a tool call reads its own
/// turn and never another one's (TEAMS-V2-BASE 8.4). Taken from the turn globals when the turn
/// starts; those globals stay beside it until commit 2b removes them.
struct TurnFrame: Equatable {
  let thread: String
  /// `turnSerial` at the start: a late end of an older turn on the same thread clears nothing.
  let serial: Int
  /// Who asked, for the admission rule (`RelayOrchestrator.admissionTurn`).
  let admission: Admission.Turn
  /// A schedule, a watch or a link runs it (`runsUnattended`).
  let unattended: Bool
  /// The person's words as they sent them; read only through `typedWords`.
  let personWords: String?
  /// The turn brought outside text in (`turnReadOutside`).
  var readOutside: Bool

  /// The person's own message started it (`startedByPerson`).
  var byPerson: Bool { admission == .person }
  var typedWords: String { byPerson ? personWords ?? "" : "" }

  /// The thread of the turn whose tool call runs in this task (`RelayToolHost.call`).
  @TaskLocal static var callingThread: String?
}

/// Every running turn's frame, by thread. One turn runs per thread (`AgentHub.run(for:)`).
struct TurnFrames {
  private var byThread: [String: TurnFrame] = [:]

  subscript(thread: String) -> TurnFrame? { byThread[thread] }

  mutating func begin(_ frame: TurnFrame) { byThread[frame.thread] = frame }
  /// The turn on `thread` ended: done, failed or stopped. With `serial`, only that turn's frame
  /// goes, so a start that failed late never clears a newer turn's.
  mutating func end(_ thread: String, serial: Int? = nil) {
    guard serial == nil || byThread[thread]?.serial == serial else { return }
    byThread[thread] = nil
  }
  mutating func noteReadOutside(_ thread: String) { byThread[thread]?.readOutside = true }

  /// The frame a call from `thread` reads: its own, else `none`. Never another thread's.
  func frame(for thread: String?, none: @autoclosure () -> TurnFrame) -> TurnFrame {
    thread.flatMap { byThread[$0] } ?? none()
  }
}
