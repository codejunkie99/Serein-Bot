import Foundation
import SereinCore

/// `chats_search` (ChatSearch): Serein's main assistant finds what was said in its other chats and
/// in every other assistant's. Like `sessions_list`, only the main assistant may: another one has
/// narrower places, and another chat may hold what those places keep from it.
extension RelayOrchestrator {
  static let chatsMainOnly = "Only the main assistant searches other chats. Ask the person to ask it there."

  /// An assistant's chats: its current one and the ones it moved on from.
  func chatThreads(of profileID: String) -> [String] {
    let saved = profileID == team.activeID ? state : browser.library.load(State.self, from: team.folder(profileID) + "/state.json")
    guard let saved else { return [] }
    return [saved.threadID] + (saved.pastThreadIDs ?? [])
  }

  func searchChats(_ query: String?, limit: Int?) throws -> [String: Any] {
    guard turnProfileID == team.mainProfileID else { throw SereinError.invalid(Self.chatsMainOnly) }
    let words = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !ChatSearch.terms(words).isEmpty else { throw SereinError.invalid("query is required: the words to look for.") }
    let here = turnThread
    var owner: [String: String] = [:]
    for profile in team.profiles {
      for thread in chatThreads(of: profile.id) where thread != here { owner[thread] = owner[thread] ?? profile.name }
    }
    let byID = Dictionary(agent.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let chats: [ChatSearch.Chat] = owner.compactMap { thread, name in
      guard let chat = byID[thread] else { return nil }
      let messages = chat.messages.filter { ($0.role == "you" || $0.role == "assistant") && $0.notice != true }
        .map { ChatSearch.Message(id: $0.id, fromPerson: $0.role == "you", text: $0.text, sentAt: $0.sentAt) }
      return ChatSearch.Chat(id: thread, title: chat.title, assistant: name, messages: messages)
    }
    var hits = ChatSearch.search(words, in: chats, limit: limit ?? ChatSearch.defaultLimit)
    var out: [String: Any] = [:]
    // A chat that took in mail, messages or Mac apps passes that mark on to this one, as recall does.
    if hits.contains(where: { agent.readsPersonal(thread: $0.chat) }), !agent.markPersonalRead(thread: here) {
      hits.removeAll { agent.readsPersonal(thread: $0.chat) }
      out["withheld"] = BrowserModel.personalMarkWithheld
    }
    let chatByID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    out["messages"] = hits.compactMap { hit -> [String: Any]? in
      guard let chat = chatByID[hit.chat], let message = chat.messages.first(where: { $0.id == hit.message }) else { return nil }
      var row: [String: Any] = [
        "chat_untrusted": AgentPrivacy.redact(chat.title, limit: 120), "assistant": chat.assistant,
        "from": message.fromPerson ? "person" : chat.assistant,
        "text_untrusted": ChatSearch.snippet(message.text, query: words),
      ]
      if let sent = message.sentAt { row["when"] = RelayToolHost.stamp(sent) }
      return row
    }
    out["total"] = hits.count
    return out
  }
}
