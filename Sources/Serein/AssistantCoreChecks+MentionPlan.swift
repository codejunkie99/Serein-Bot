#if DEBUG
import Foundation
import SereinCore

/// The message boxes and `ask` agree on mentions, on a real Relay over a throwaway library: what
/// `messagePlan` refuses, `ask` sends nothing for, and what it lets through, `ask` takes, while
/// Serein works and while it is idle. Free's `ask` opens another assistant's chat to send it files
/// or a bare tag (`routeMention`), so while busy those are refused and the switch is shown to fail;
/// `ask` itself is not called for them, since its refusal puts the words back in the window's box.
extension AssistantCoreChecks {
  static func mentionPlan(_ check: Check) throws {
    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "mention plan: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-mentionplan-\(UUID().uuidString)", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      let browser = try BrowserModel(root: root)
      try files.createDirectory(
        at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
      let agent = AgentModel(browser: browser, discoverProviders: false)
      // An AI app to think with, so a message is not held for one; nothing here starts it.
      agent.available[.claude] = "/nonexistent/serein-check-claude"
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }
      defer { relay.stopEverything(pause: true) }
      relay.networkOnline = { true }
      guard relay.addProfile("Writer"), let writer = relay.team.profiles.first(where: { $0.name == "Writer" })?.id else {
        try check(false, "mention plan: the roster takes Writer")
        return
      }
      let lead = relay.team.activeID
      let chat = relay.threadID
      let file = SereinAttachment(title: "Notes", body: "MENTION PLAN NOTES 3141")

      struct Seen: Equatable { var said: Int; var rows: Int; var pending: Int; var active: String }
      @MainActor func seen() -> Seen {
        let said = chat == agent.conversationID ? agent.messages.count : agent.conversations.first { $0.id == chat }?.messages.count ?? 0
        return Seen(said: said, rows: relay.handoffLedger.records.count, pending: relay.pending.count, active: relay.team.activeID)
      }
      /// The box's plan, then `ask` with the same words: a refusal must match an `ask` that took
      /// nothing at all; words let through must not come back refused.
      @MainActor func send(_ typed: String, _ attached: [SereinAttachment] = []) -> (refusal: String?, took: Bool, unchanged: Bool) {
        relay.lastError = nil
        let refusal = relay.messagePlan(typed, hasAttachments: !attached.isEmpty).refusal
        let before = seen()
        let took = relay.ask(typed, attachments: attached)
        return (refusal, took, seen() == before && relay.lastError == nil)
      }

      // Serein works: this chat cannot switch.
      relay.post(AgentMessage(role: "you", text: "Sort my inbox"), into: chat)
      relay.sending = true
      try check(relay.working && !relay.canSwitchAssistant, "mention plan: the chat is busy")

      let words = send("@Writer draft the toast")
      let tagged = relay.handoffLedger.records.last { $0.to == writer && $0.mention != nil }
      try check(words.refusal == nil && words.took && tagged?.isOpen == true && relay.team.activeID == lead,
        "mention plan: \"@Writer words\" while busy goes as a group turn in this chat, not refused [\(words)]")

      let bare = relay.messagePlan("@Writer", hasAttachments: false).refusal
      try check(bare == "This chat is busy, so @Writer's chat can't open yet. Add a message to send it now."
          && !relay.switchTo(writer) && relay.team.activeID == lead,
        "mention plan: a bare \"@Writer\" while busy is refused, and Writer's chat cannot open for ask [\(bare ?? "none")]")

      let stop = send("@Writer stop")
      try check(stop.refusal == nil && !stop.took && relay.lastError == nil
          && relay.handoffLedger.records.first { $0.id == tagged?.id }?.isOpen == false && relay.team.activeID == lead,
        "mention plan: \"@Writer stop\" while busy goes, and stops Writer's turn here [\(stop)]")

      let unknown = send("@Nobody what's the weather")
      let seat = relay.handoffLedger.records.last { $0.side == .busy }
      try check(unknown.refusal == nil && unknown.took && seat?.task.contains("@Nobody what's the weather") == true,
        "mention plan: an unknown \"@word\" while busy is plain words, and takes a side seat [\(unknown)]")

      let filed = relay.messagePlan("@Writer read this", hasAttachments: true).refusal
      try check(filed == "This chat is busy, so @Writer's chat can't open yet. Send the files when this reply is done, or words alone now."
          && relay.messagePlan("@Writer", hasAttachments: true).refusal == filed && !relay.switchTo(writer),
        "mention plan: a tag with a file while busy is refused, since only Writer's own chat takes files [\(filed ?? "none")]")
      let note = send("keep these", [file])
      try check(note.refusal == nil && note.took && relay.pending.last == "keep these",
        "mention plan: a file to the busy chat itself waits for this chat's own turn [\(note)]")

      // Idle again: a bare tag opens that chat, and one of this chat's own assistant sends nothing.
      relay.stopEverything(pause: false)
      relay.sending = false
      try check(!relay.working && relay.canSwitchAssistant, "mention plan: the chat is idle")
      let own = send("@" + relay.team.activeName)
      try check(own.refusal == "@\(relay.team.activeName) answers in this chat already. Add a message to send it."
          && !own.took && own.unchanged,
        "mention plan: a bare tag of this chat's own assistant is refused, and ask sends nothing for it [\(own)]")
      let open = send("@Writer")
      try check(open.refusal == nil && !open.took && relay.team.activeID == writer && relay.lastError == nil,
        "mention plan: a bare \"@Writer\" while idle is let through, and opens Writer's chat [\(open)]")
    }
  }
}
#endif
