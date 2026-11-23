import Foundation

/// Optional controls Serein can offer inside a conversation. An offer never changes a setting;
/// the person uses the native control on its card. There is no ordered setup sequence.
public enum SereinSetup {
  public enum Topic: String, CaseIterable, Codable, Sendable {
    case beside, anywhere, approvals
    case checkIns = "check_ins"
    /// Read the person's chats with their AI apps on this Mac, keep what matters as notes and
    /// offer to connect the workspaces they use (`sessions_overview`).
    case firstRead = "first_read"
    /// Open Serein when the person logs in, so schedules keep running after a restart.
    case login
    case follow
    /// Download the speech model, so dictation in English is faster and more accurate (SpeechModel).
    case speech
    /// Let Serein read the person's Mac (MacFiles, read-only): their files, notes and documents
    /// already hold who they are and what they work on, so nobody starts from nothing.
    case files
    /// A face for each assistant at the edge of the screen (AssistantDock).
    case dock
    /// What the person selects or points at goes with what they say from the shortcut (ScreenContext).
    case showAndTell = "show_and_tell"
    /// Say “Serein” to ask (WakeListener).
    case wake
    /// Work in a Mac app's window without taking the person's pointer (MacBackgroundPolicy).
    case background
    /// Let tasks download files (TaskDownloadPolicy).
    case downloads
    /// Keep the Mac awake while tasks run (KeepAwake).
    case awake
  }

  public static func topic(_ arguments: [String: Any]) throws -> Topic {
    guard arguments.keys.allSatisfy({ $0 == "topic" }),
      let name = arguments["topic"] as? String, let topic = Topic(rawValue: name)
    else { throw SereinError.invalid("topic must be " + Topic.allCases.map(\.rawValue).joined(separator: ", ")) }
    return topic
  }

  /// The card a yes leads to, once: a schedule that opens at login also needs the Mac awake when it
  /// is due, and following along sits beside sharing what the person points at. Never a third.
  public static func next(after topic: Topic, on: Bool, dismissed: [Topic]) -> Topic? {
    let follows: [Topic: Topic] = [.login: .awake, .follow: .showAndTell]
    guard let next = follows[topic], !on, !dismissed.contains(next) else { return nil }
    return next
  }

  public static func mayOffer(personStarted: Bool, unattended: Bool) -> Bool {
    personStarted && !unattended
  }

  /// Serein offers Open at login itself once the person depends on schedules (a timed request,
  /// the morning brief or check-ins), in a copy macOS can open at login, unless it already opens
  /// then or the person said Not now to it before.
  public static func offersLogin(scheduled: Bool, opensAtLogin: Bool, packaged: Bool, declined: Bool) -> Bool {
    scheduled && !opensAtLogin && packaged && !declined
  }

  public static func offersFollow(on: Bool, declined: Bool, cardWaiting: Bool) -> Bool {
    !on && !declined && !cardWaiting
  }

  /// Serein offers the speech model itself after a dictation in English that Apple Speech heard,
  /// on a Mac that can run the model and has no copy, unless the person said Not now to it before.
  public static func offersSpeech(supported: Bool, there: Bool, declined: Bool, cardWaiting: Bool) -> Bool {
    supported && !there && !declined && !cardWaiting
  }

  /// At most one relevant offer per chat, bounded across chats and never persisted. Repeating
  /// a tool call leaves the same card in place instead of building a new checklist.
  public struct Offers: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
      var thread: String
      var topic: Topic
    }
    private var entries: [Entry] = []
    private var declined: [Entry] = []
    public init() {}
    public func topic(in thread: String) -> Topic? { entries.first { $0.thread == thread }?.topic }
    public func dismissed(in thread: String) -> [Topic] { declined.filter { $0.thread == thread }.map(\.topic) }
    @discardableResult public mutating func offer(_ topic: Topic, in thread: String) -> Bool {
      guard !thread.isEmpty, self.topic(in: thread) != topic else { return false }
      entries.removeAll { $0.thread == thread }
      entries.append(Entry(thread: thread, topic: topic))
      entries = Array(entries.suffix(16))
      return true
    }
    @discardableResult public mutating func dismiss(_ topic: Topic, in thread: String, declined wasDeclined: Bool = true) -> Bool {
      guard self.topic(in: thread) == topic else { return false }
      entries.removeAll { $0.thread == thread }
      declined.removeAll { $0.thread == thread && $0.topic == topic }
      if wasDeclined { declined.append(Entry(thread: thread, topic: topic)) }
      declined = Array(declined.suffix(64))
      return true
    }
  }
}
