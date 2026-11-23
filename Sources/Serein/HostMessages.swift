import Foundation
import SereinCore

/// Messages Serein itself writes into a chat: receipts and system lines after a turn, another
/// assistant's answer, a new assistant's first question. Never a model's words, never sent as a
/// turn and never starting one. Like `postNotice`, they wait while a run works in the chat, since
/// a turn in flight writes its own reply at the end of the transcript.
extension AgentModel {
  /// Changes the messages of `threadID`: the saved record (or the selected chat) and the latest
  /// run's transcript, which the Serein surface shows while that run is in the hub. True once it
  /// is saved; false while a run works there, when no such chat is known, or when the save failed.
  @discardableResult func amendThread(_ threadID: String, _ change: (inout [AgentMessage]) -> Void) -> Bool {
    guard let browser, hub.run(for: threadID) == nil else { return false }
    if let run = hub.latest(for: threadID) {
      var transcript: [AgentMessage] = run.transcript
      change(&transcript)
      if transcript != run.transcript { run.transcript = transcript }
    }
    if threadID == conversationID {
      var current: [AgentMessage] = messages
      change(&current)
      if current != messages { messages = current }
      saveConversation()
      return true
    }
    guard let i = conversations.firstIndex(where: { $0.id == threadID }) else { return false }
    var saved: [AgentMessage] = conversations[i].messages
    change(&saved)
    guard saved != conversations[i].messages else { return true }
    let before = conversations[i].tail
    conversations[i].messages = saved
    conversations[i].lastMessageAt = ThreadActivity.lastMessageAt(
      stored: conversations[i].lastMessageAt, previous: before, current: conversations[i].tail)
    conversations[i].updatedAt = Date()
    do { try browser.library.save(conversations, to: "sessions/threads.json") } catch {
      self.error = error.localizedDescription
      return false
    }
    return true
  }

  /// Adds one host message at the end of `threadID`. A chat that does not exist yet (a new
  /// assistant's Main chat) is made as one of Serein's own chats with `title`, on `provider`.
  /// False while a run works there, or when the save failed.
  @discardableResult func postHostMessage(_ message: AgentMessage, into threadID: String, title: String, provider: Provider)
    -> Bool
  {
    guard let browser, hub.run(for: threadID) == nil else { return false }
    let known = threadID == conversationID || conversations.contains { $0.id == threadID }
    if known { return amendThread(threadID) { $0.append(message) } }
    var chat = Conversation(
      id: threadID, title: title, messages: [message], provider: provider, mode: .anywhere, projectID: nil, remoteID: nil,
      scope: "", updatedAt: Date())
    chat.lastMessageAt = Date()
    chat.serein = true
    conversations.append(chat)
    do { try browser.library.save(conversations, to: "sessions/threads.json") } catch {
      self.error = error.localizedDescription
      return false
    }
    return true
  }
}
