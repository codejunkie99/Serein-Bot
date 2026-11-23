import Foundation
import SereinCore

/// Which replies the person has read in Serein's chats: one saved mark per chat, the newest reply
/// they had on screen (`ChatReading`). Saved with the chats' data, as it is no setting.
extension RelayOrchestrator {
  static let chatReadFile = "relay/chat-read.json"
  /// Old chats drop out past this: they then count as read, which is what they are.
  private static let maxReadMarks = 300

  /// The chat on screen has been read. `silent`: the person watched it arrive or is writing, so no
  /// Unread line; otherwise the line goes above the first reply that landed while they were away.
  func chatRead(silent: Bool = false) {
    guard !RunMode.previewing else { return }
    let chat: String = threadID
    let found = ChatReading.unread(transcript.map(RelayMessagesReading.entry), mark: chatReadMarks[chat])
    if let mark = found.mark, chatReadMarks[chat] != mark {
      chatReadMarks[chat] = mark
      while chatReadMarks.count > Self.maxReadMarks, let other = chatReadMarks.keys.first(where: { $0 != chat }) {
        chatReadMarks[other] = nil
      }
      persist(chatReadMarks, Self.chatReadFile)
    }
    // It stays until the person writes or watches a reply arrive: returning to the app reads the
    // chat more than once, and the later reads find nothing new.
    if silent {
      if unreadFrom[chat] != nil { unreadFrom[chat] = nil }
    } else if let first = found.first {
      unreadFrom[chat] = first
    }
  }
}

/// A message as `ChatReading` sees it.
enum RelayMessagesReading {
  static func entry(_ message: AgentMessage) -> ChatReading.Entry {
    ChatReading.Entry(
      id: message.id, isReply: message.role == "assistant" && message.line == nil && message.notice != true,
      hasOutput: !message.text.isEmpty || !(message.activities ?? []).isEmpty)
  }
}
