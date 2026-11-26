import Foundation

/// The tab a message to Serein carries: the page chip's tab. Only its title and site go into the
/// turn (`CurrentPageContext.line`); the path and the text come back only through `current_page`.
public struct SereinPage: Equatable, Sendable {
  public var tabID: String
  public var title: String
  public var url: String
  public var isPrivate: Bool

  public init(tabID: String, title: String, url: String, isPrivate: Bool = false) {
    self.tabID = tabID
    self.title = title
    self.url = url
    self.isPrivate = isPrivate
  }

  /// The line the turn's context gets, or nil (a private tab, anything but a web page).
  public var line: String? { CurrentPageContext.line(title: AgentPrivacy.redact(title), url: url, isPrivate: isPrivate) }
  public var host: String { CurrentPageContext.host(url) ?? "" }
}

/// What one running turn of Serein's own knows, keyed by its thread, so a tool call reads its own
/// turn and never another one's (TEAMS-V2-BASE 8.4). Taken when the turn starts.
public struct TurnFrame: Equatable, Sendable {
  public let thread: String
  /// `turnSerial` at the start: a late end of an older turn on the same thread clears nothing.
  public let serial: Int
  /// Who asked, for the admission rule.
  public let admission: Admission.Turn
  /// A schedule, a watch or a link runs it.
  public let unattended: Bool
  /// The person's words as they sent them; read only through `typedWords`.
  public let personWords: String?
  /// The turn brought outside text in.
  public var readOutside: Bool
  /// The assistant whose turn it is: a routine's owner, else the one it acts for, else the main one.
  public let profile: String
  /// The assistant it acts for: nil for a schedule of the person's own.
  public let acting: String?
  /// A check-in: it acts on `authority` alone, and the level does not stand in it.
  public let checkingIn: Bool
  /// A goal check: its findings notify only when new.
  public let checkingGoal: Bool
  /// The person's words behind an unattended turn or a check-in, as they approved them.
  public let authority: String?
  /// The page chip's tab the person's message carried; nil once a stop or a switch unbinds it.
  public var page: SereinPage?

  /// The person's own message started it.
  public var byPerson: Bool { admission == .person }
  public var typedWords: String { byPerson ? personWords ?? "" : "" }

  public init(
    thread: String, serial: Int, admission: Admission.Turn, unattended: Bool, personWords: String?, readOutside: Bool,
    profile: String, acting: String?, checkingIn: Bool = false, checkingGoal: Bool = false, authority: String? = nil,
    page: SereinPage? = nil
  ) {
    self.thread = thread
    self.serial = serial
    self.admission = admission
    self.unattended = unattended
    self.personWords = personWords
    self.readOutside = readOutside
    self.profile = profile
    self.acting = acting
    self.checkingIn = checkingIn
    self.checkingGoal = checkingGoal
    self.authority = authority
    self.page = page
  }

  /// `Admission`'s verdict on `change` in this turn, with `TypedConsent` reading the person's words.
  public func admission(_ change: Admission.Change) -> Admission.Verdict {
    Admission.decide(change, turn: admission, wordsNameIt: TypedConsent.names(change, in: typedWords))
  }

  /// The frame the tool call running in this task entered with (`RelayToolHost.call`).
  @TaskLocal public static var calling: TurnFrame?
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
  /// A stop, a rewind or a switch on `thread` unbinds its page chip; `nil`: every thread's.
  public mutating func unbindPage(_ thread: String?) {
    for key in thread.map({ [$0] }) ?? Array(byThread.keys) { byThread[key]?.page = nil }
  }

  /// The frame a call reads: the live frame of the turn it entered with, else (that turn ended
  /// during the call) the frame it entered with. Never another thread's, never a newer turn's;
  /// nil when the call came from no turn.
  public func frame(for calling: TurnFrame?) -> TurnFrame? {
    guard let calling else { return nil }
    guard let live = byThread[calling.thread], live.serial == calling.serial else { return calling }
    return live
  }
}
