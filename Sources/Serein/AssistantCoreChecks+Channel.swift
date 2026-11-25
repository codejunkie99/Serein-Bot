#if DEBUG
import Foundation
import SereinCore

/// One channel in the origin chat (RelayChannel.swift) on a real Relay over a throwaway library:
/// a hand-off posts "@Target …" from its sender with what it answers, a report posts once under
/// its target's name however often it is replayed, a relaunch between the post and the claim
/// still shows it once, no "Messaged" line is left, and a post never makes a chat.
extension AssistantCoreChecks {
  static func channel(_ check: Check) throws {
    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "channel: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-channel-\(UUID().uuidString)", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      let browser = try BrowserModel(root: root)
      try files.createDirectory(
        at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
      let agent = AgentModel(browser: browser, discoverProviders: false)
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }

      let chat = "origin-" + UUID().uuidString
      agent.conversations.append(Conversation(
        id: chat, title: "Serein", messages: [AgentMessage(role: "you", text: "Find three venues")], provider: .claude,
        mode: .anywhere, projectID: nil, remoteID: nil, scope: "", updatedAt: Date()))
      let asked = agent.conversations.first { $0.id == chat }?.messages.first?.id
      @MainActor func posts() -> [AgentMessage] { agent.conversations.first { $0.id == chat }?.messages.filter { $0.role == "assistant" } ?? [] }

      // The hand-off: from its sender, tagging its target, answering the person's message, capped.
      var record = AssistantHandoff(
        from: "serein", to: "theo", task: "Find three venues " + String(repeating: "near the harbour ", count: 120),
        threadID: "", askedIn: chat, team: "", teamName: "All assistants")
      record.threadID = RelayOrchestrator.seatThread(record.id)
      relay.handoffLedger.admit(record, now: Date())
      relay.postHandoff(record, answering: asked)
      let sent = posts()
      try check(sent.count == 1 && sent[0].id == RelayOrchestrator.handoffPostID(record.id) && sent[0].from == "serein"
          && sent[0].re == asked && sent[0].mentions == ["theo"] && sent[0].text.hasPrefix("@"),
        "channel: a hand-off posts in the origin chat from its sender, tagging its target, answering the person's message")
      try check(sent[0].text.count <= RelayOrchestrator.channelCap && HandoffPacket.Cap.summary == 1_200,
        "channel: a post's words stop at 600; the packet's summary keeps 1,200")
      try check(!posts().contains { $0.line?.hasPrefix("Messaged") == true }, "channel: no Messaged line is left in the chat")

      // A replayed post with the same id changes nothing.
      relay.postHandoff(record, answering: asked)
      try check(posts().count == 1, "channel: a replayed post with the same id is a no-op")

      // The report: posted, then a relaunch before the claim; posting again and claiming shows it once.
      relay.handoffLedger.records[0].state = .done
      relay.handoffLedger.records[0].result = "Casa Alta is cheapest"
      let closed = relay.handoffLedger.records[0]
      try check(relay.postReport(closed), "channel: a closed hand-off's report lands in an idle origin chat")
      try check(relay.postReport(closed) && relay.handoffLedger.claimReport(closed.id) != nil,
        "channel: after a relaunch between the post and the claim, the post is found and the claim goes through")
      let reports = posts().filter { $0.id == HandoffReport.postID(closed.id) }
      try check(reports.count == 1 && reports[0].from == "theo" && reports[0].re == RelayOrchestrator.handoffPostID(closed.id)
          && reports[0].mentions == ["serein"] && reports[0].text == "Casa Alta is cheapest",
        "channel: the report shows once, from its target, answering the hand-off and tagging its sender")

      // A post never makes a chat: one the person deleted stays gone.
      var gone = closed
      gone.askedIn = "deleted-" + UUID().uuidString
      try check(!relay.postReport(gone) && !agent.conversations.contains { $0.id == gone.askedIn },
        "channel: a post into a chat that is gone makes no chat")
    }
  }
}
#endif
