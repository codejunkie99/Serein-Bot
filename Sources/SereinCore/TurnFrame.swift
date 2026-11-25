import Foundation

/// What one running turn of Serein's own knows, keyed by its thread, so a tool call reads its own
/// turn and never another one's (TEAMS-V2-BASE 8.4). Taken from the turn globals when the turn
/// starts; those globals stay beside it until commit 2b removes them.
public struct TurnFrame: Equatable, Sendable {
  public let thread: String
  /// `turnSerial` at the start: a late end of an older turn on the same thread clears nothing.
  public let serial: Int
  /// Who asked, for the admission rule (`RelayOrchestrator.admissionTurn`).
  public let admission: Admission.Turn
  /// A schedule, a watch or a link runs it (`runsUnattended`).
  public let unattended: Bool
  /// The person's words as they sent them; read only through `typedWords`.
  public let personWords: String?
  /// The turn brought outside text in (`turnReadOutside`).
  public var readOutside: Bool

  /// The person's own message started it (`startedByPerson`).
  public var byPerson: Bool { admission == .person }
  public var typedWords: String { byPerson ? personWords ?? "" : "" }

  public init(thread: String, serial: Int, admission: Admission.Turn, unattended: Bool, personWords: String?, readOutside: Bool) {
    self.thread = thread
    self.serial = serial
    self.admission = admission
    self.unattended = unattended
    self.personWords = personWords
    self.readOutside = readOutside
  }

  /// The thread of the turn whose tool call runs in this task (`RelayToolHost.call`).
  @TaskLocal public static var callingThread: String?
}

/// Every running turn's frame, by thread. One turn runs per thread (`AgentHub.run(for:)`).
public struct TurnFrames: Equatable, Sendable {
  private var byThread: [String: TurnFrame] = [:]

  public init() {}

  public subscript(thread: String) -> TurnFrame? { byThread[thread] }

  public mutating func begin(_ frame: TurnFrame) { byThread[frame.thread] = frame }
  /// The turn on `thread` ended: done, failed or stopped. With `serial`, only that turn's frame
  /// goes, so a start that failed late never clears a newer turn's.
  public mutating func end(_ thread: String, serial: Int? = nil) {
    guard serial == nil || byThread[thread]?.serial == serial else { return }
    byThread[thread] = nil
  }
  public mutating func noteReadOutside(_ thread: String) { byThread[thread]?.readOutside = true }

  /// The frame a call from `thread` reads: its own, else `none`. Never another thread's.
  public func frame(for thread: String?, none: @autoclosure () -> TurnFrame) -> TurnFrame {
    thread.flatMap { byThread[$0] } ?? none()
  }
}
