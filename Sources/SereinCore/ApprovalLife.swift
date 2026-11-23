import Foundation

/// What ends an approval card other than its own buttons: the person's next message, or time
/// (`RelayApproval`: a day). Each end is a no, never a yes, so nothing runs on a card the person
/// did not answer. Pure, so it is checked (`AssistantCoreChecks.approvalLife`).
public enum ApprovalLife {
  public enum End: String, Equatable, Sendable {
    /// The person sent a new message while the card waited.
    case skipped
    /// Nobody answered it in a day (`RelayApproval.declineAfter`).
    case expired
    /// The tool call that raised the card stopped waiting for it (`CallWindow`).
    case unanswered
  }

  /// Whether the person's new message in `messageThread` closes a card: only one their own chat
  /// was waiting on. A background card (a run nobody watches deferred it, `RelayDeferred`) is
  /// not that turn's question, so it waits the day its one-time yes could live.
  public static func skips(cardThread: String, background: Bool, messageThread: String) -> Bool {
    !background && cardThread == messageThread
  }

  /// The collapsed line of a card that ended by itself: the word in the bubble, and why under it.
  public static func line(_ end: End) -> (word: String, why: String) {
    switch end {
    case .skipped: return ("Skipped", "You sent a new message. Nothing ran.")
    case .expired: return ("Expired", "Nobody answered in a day. Nothing ran.")
    case .unanswered: return ("Declined", CallWindow.unansweredLine)
    }
  }

  /// Added to what a run hears after a denial.
  public static let noRetry = "Do not try it again until their next message."

  /// The actions the person declined since their last message. The same action is not asked
  /// again until they write: a second card for a step they just refused is the assistant
  /// arguing. Their next message clears it, since it may be them changing their mind.
  public struct Denials: Equatable, Sendable {
    public private(set) var keys: Set<String> = []
    public init() {}

    /// One action, as its card showed it, in one chat.
    public static func key(title: String, detail: String, thread: String?) -> String {
      [thread ?? "", title, detail].joined(separator: "\u{1F}")
    }
    public mutating func deny(_ key: String) { keys.insert(key) }
    /// The person asked for this themself (a pick in a list): it may be asked again.
    public mutating func forget(_ key: String) { keys.remove(key) }
    public func blocks(_ key: String) -> Bool { keys.contains(key) }
    /// The person wrote in `thread`: what they declined there, or on a card with no chat, may be
    /// asked again. Other chats keep theirs.
    public mutating func personSpoke(in thread: String) {
      keys = keys.filter { !$0.hasPrefix(thread + "\u{1F}") && !$0.hasPrefix("\u{1F}") }
    }
  }

}
