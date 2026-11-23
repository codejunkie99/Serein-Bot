import Foundation

/// What has been read in a chat, both ways: whether the AI app has seen the person's message, and
/// which replies the person has not read yet. Worked out from the messages and one saved mark per
/// chat, so older saved chats need nothing new.
public enum ChatReading {
  /// `notSent`: the turn could not start, and the message stays in the chat for Send again.
  public enum PersonStatus: Sendable, Equatable { case sent, seen, notSent }

  public struct Entry: Sendable, Equatable {
    public let id: String
    public let isReply: Bool
    /// It has words or tool steps: the AI app has started on the message before it.
    public let hasOutput: Bool
    public init(id: String, isReply: Bool, hasOutput: Bool) {
      self.id = id
      self.isReply = isReply
      self.hasOutput = hasOutput
    }
  }

  /// The AI app has seen a message once anything of its answer exists after it.
  public static func personSeen(after later: [Entry]) -> Bool {
    later.contains { $0.isReply && $0.hasOutput }
  }

  /// Reading a chat up to now: its first unread reply, if any, and the new mark. A chat with no
  /// mark, or whose mark has left the chat (rewound or condensed), counts as read: a line over
  /// its whole history would say nothing.
  public static func unread(_ entries: [Entry], mark: String?) -> (first: String?, mark: String?) {
    let replies = entries.filter { $0.isReply && $0.hasOutput }
    guard let newest = replies.last else { return (nil, mark) }
    guard let mark, let at = entries.firstIndex(where: { $0.id == mark }) else { return (nil, newest.id) }
    let first = entries[(at + 1)...].first { $0.isReply && $0.hasOutput }
    return (first?.id, newest.id)
  }
}
