import Foundation
import SereinCore

/// The task tabs, in the order ⇧⌘] and ⇧⌘[ move through them.
@MainActor enum ThreadTabs {
  static func open(browser: BrowserModel, agent: AgentModel) -> [Conversation] {
    var ids = agent.openThreads
    if browser.section == ShellSection.thread, !ids.contains(agent.conversationID) { ids.append(agent.conversationID) }
    // Task tabs only: never Serein's own chats or the tasks it started (the Serein surface has them).
    ids = ids.filter { !agent.isSereinThread($0) }
    return ids.compactMap { id -> Conversation? in
      var item: Conversation
      if id == agent.conversationID, agent.conversations.first(where: { $0.id == id }) == nil {
        let title = String((agent.messages.first?.text ?? agent.draft).prefix(100))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        // The unsaved task stays navigable without adding empty records to history.
        item = Conversation(id: id, title: title, messages: agent.messages, provider: agent.provider,
          mode: agent.mode, projectID: agent.projectID, remoteID: agent.nativeSessionID, scope: "",
          updatedAt: Date())
      } else if let known = agent.openThreadItem(id) {
        item = known
      } else {
        return nil
      }
      // An empty thread reads as its project, or "New task".
      if item.messages.isEmpty {
        item.title = browser.projects.first { $0.id == item.projectID }?.name ?? "New task"
      }
      return item
    }
  }
}
