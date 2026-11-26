#if DEBUG
import Foundation
import SereinCore

/// One channel and the group turn (RelayGroupTurn.swift) on a real Relay over a throwaway library:
/// a person's @tag seats the named bot in that chat, two tags seat two, an unknown @ stays text,
/// channel_say posts with from, re and mentions, a bot's text tag routes, a self-tag is ignored,
/// a tag loop stops at the chain caps, and a tagged turn's reply lands once with no wake turn.
extension AssistantCoreChecks {
  static func groupTurn(_ check: Check) throws {
    // The parser alone: anywhere in the text, case-insensitive, longest name first, unknown is text.
    let roster = RelayTeam(
      profiles: [RelayProfile(id: "main", name: "Serein"), RelayProfile(id: "w", name: "Writer"),
                 RelayProfile(id: "wp", name: "Writer Pro"), RelayProfile(id: "s", name: "Scout")], activeID: "main")
    try check(GroupTurn.speakers(of: "ok @writer pro, and @Scout: plan it", in: roster) == ["wp", "s"],
      "group turn: tags are found anywhere, in any case, the longest name first, in order")
    try check(GroupTurn.speakers(of: "mail bob@writer.com and @Nobody", in: roster).isEmpty
        && GroupTurn.words(of: "ping @Nobody", in: roster) == "ping @Nobody",
      "group turn: an @ inside a word or before an unknown name stays plain text")
    try check(GroupTurn.speakers(of: "Thanks @Writer.", in: roster, addressed: true).isEmpty
        && GroupTurn.speakers(of: "@Writer can you polish it", in: roster, addressed: true) == ["w"],
      "group turn: in a bot's reply only a tag with words after it counts")

    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "group turn: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-group-\(UUID().uuidString)", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      let browser = try BrowserModel(root: root)
      try files.createDirectory(
        at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
      let agent = AgentModel(browser: browser, discoverProviders: false)
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }
      defer { relay.stopEverything(pause: true) }
      guard relay.addProfile("Writer"), relay.addProfile("Scout"), relay.addProfile("Editor"),
        let editor = relay.team.profiles.first(where: { $0.name == "Editor" })?.id
      else {
        try check(false, "group turn: the roster takes Writer, Scout and Editor")
        return
      }
      let lead = relay.team.activeID
      let writer = relay.profile(id: relay.team.profiles.first { $0.name == "Writer" }?.id ?? "")
      let scout = relay.profile(id: relay.team.profiles.first { $0.name == "Scout" }?.id ?? "")
      let chat = relay.threadID
      @MainActor func messages() -> [AgentMessage] {
        chat == agent.conversationID ? agent.messages : agent.conversations.first { $0.id == chat }?.messages ?? []
      }
      @MainActor func tags(_ post: String) -> [AssistantHandoff] { relay.handoffLedger.records.filter { $0.mention?.post == post } }

      // 1. A person's tag seats the named bot in this chat, answering the person's own message.
      try check(relay.ask("@Writer draft the toast"), "group turn: a person's tag starts a turn")
      let bubble = messages().last { $0.role == "you" }
      let first = bubble.map { tags($0.id) } ?? []
      try check(bubble?.text == "@Writer draft the toast" && bubble?.mentions == [writer.id]
          && first.count == 1 && first[0].to == writer.id && first[0].from == lead && first[0].mention == .byPerson(message: bubble?.id ?? "")
          && !messages().contains { $0.id == RelayOrchestrator.handoffPostID(first[0].id) },
        "group turn: a person's @mention routes to the named bot, in this chat, with no hand-off post or card")

      // 2. Two tags, two turns, in the order tagged.
      _ = relay.ask("@writer and @Scout, plan the trip")
      let both = messages().last { $0.role == "you" }.map { tags($0.id) } ?? []
      try check(both.map(\.to) == [writer.id, scout.id], "group turn: two mentions give two turns")

      // 3. An unknown @ is plain text: no turn, nothing posted.
      let rows = relay.handoffLedger.records.count
      let said = messages().count
      try check(!relay.startGroupTurn("ping @Nobody about it") && !relay.startGroupTurn("@\(relay.team.activeName) hi")
          && relay.handoffLedger.records.count == rows && messages().count == said,
        "group turn: an unknown @ and the chat's own assistant stay on the usual path")

      // A tagged turn's own run calls channel_say and tags from its reply: it is running.
      @MainActor func running(_ id: String?) -> AssistantHandoff? {
        guard let i = relay.handoffLedger.records.firstIndex(where: { $0.id == id }) else { return nil }
        relay.handoffLedger.records[i].state = .running
        return relay.handoffLedger.records[i]
      }
      guard both.count == 2, let writing = running(both[0].id), let scouting = running(both[1].id) else {
        try check(false, "group turn: both tagged turns are in the ledger")
        return
      }

      // 4. channel_say: offered with the team tools; posts from its sender, answering its tag, tagging.
      try check(ToolSchema.everyTool(["--team"]).contains { $0["name"] as? String == "channel_say" }
          && RelayTools.teamNames.contains("channel_say"),
        "group turn: channel_say is offered with assistant_handoff")
      let say = relay.channelSay("@Scout can you check the dates", from: writer, parent: writing, chat: writing.threadID, readOutside: false)
      let sayPost = messages().first { $0.id == say.post }
      try check(sayPost?.from == writer.id && sayPost?.re == writing.mention?.post && sayPost?.mentions == [scout.id]
          && tags(say.post).map(\.to) == [scout.id] && tags(say.post).first?.parentID == writing.id,
        "group turn: channel_say posts with from, re and mentions, and the tagged bot takes a turn that reports back [post: \(sayPost != nil), refused: \(say.refused.map(\.words))]")

      // A side seat and the front turn in the same chat: the seat's run posts as its own target
      // with no frame read (Browser routes it with `handoffChat`), the front turn's call posts as
      // the front turn's assistant, and a call from the seat's chat finds no frame to borrow.
      let frontFrame = TurnFrame(thread: chat, serial: 9201, admission: .person, unattended: false,
                                 personWords: "plan the trip", readOutside: false, profile: lead, acting: lead)
      relay.frames.begin(frontFrame)
      var posted: [String: String] = [:]
      Task { @MainActor in
        do { posted["seat"] = try await relay.tools.channelSay(["text": "seat note"], handoffChat: writing.threadID)["posted"] as? String } catch {
          posted["seat"] = "error: " + error.localizedDescription
        }
      }
      Task { @MainActor in
        do { posted["front"] = try await relay.tools.call("channel_say", ["text": "front note"], thread: chat)["posted"] as? String } catch {
          posted["front"] = "error: " + error.localizedDescription
        }
      }
      Task { @MainActor in
        do { _ = try await relay.tools.call("channel_say", ["text": "borrowed note"], thread: writing.threadID) } catch {
          posted["borrow"] = error.localizedDescription
        }
      }
      let seatEnd = Date().addingTimeInterval(10)
      while posted.count < 3, Date() < seatEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
      relay.frames.end(chat, serial: frontFrame.serial)
      let seatPost = messages().first { $0.id == posted["seat"] }
      let frontPost = messages().first { $0.id == posted["front"] }
      try check(seatPost?.from == writer.id && frontPost?.from == lead && posted["borrow"] == RelayToolHost.noTurn,
        "group turn: a side seat and the front turn in one chat each post as their own assistant, and the seat never borrows the front frame [\(posted)]")

      // 5. A text mention in a bot's reply routes; a thank-you does not.
      let thanks = relay.channelSay("Thanks @Writer.", from: scout, parent: scouting, chat: scouting.threadID, readOutside: false, addressed: true)
      let ask = relay.channelSay("@Editor can you polish it", from: scout, parent: scouting, chat: scouting.threadID, readOutside: false, addressed: true)
      try check(thanks.post.isEmpty && ask.seated == [editor] && messages().contains { $0.id == ask.post },
        "group turn: a bot's text mention routes, and posts as its message [refused: \(ask.refused.map(\.words))]")

      // 6. Never itself.
      let me = relay.channelSay("@Writer note to self", from: writer, parent: writing, chat: writing.threadID, readOutside: false)
      try check(me.seated.isEmpty && tags(me.post).isEmpty, "group turn: a self-mention is ignored")

      // 7. The reply of a tagged turn lands once, answering the tag, and wakes nobody.
      if let i = relay.handoffLedger.records.firstIndex(where: { $0.id == first.first?.id }) {
        relay.handoffLedger.records[i].state = .done
        relay.handoffLedger.records[i].result = "Here is the toast"
      }
      let closed = relay.handoffLedger.records.first { $0.id == first.first?.id }
      if let closed { relay.postReport(closed); relay.postReport(closed) }
      relay.deliverHandoffReports()
      let reports = messages().filter { $0.id == HandoffReport.postID(closed?.id ?? "") }
      try check(reports.count == 1 && reports[0].from == writer.id && reports[0].re == bubble?.id && reports[0].mentions == nil
          && relay.handoffLedger.records.first { $0.id == closed?.id }?.reported == true && !relay.working,
        "group turn: a tagged turn's reply lands once, answering the person, claimed with no wake turn")

      // 8. A tag loop stops at the caps: back to a holder is refused, and one task's turns stop at the per-root cap.
      let back = relay.tag([writer.id], task: "@Writer over to you", from: scout, parent: tags(say.post).first.flatMap { running($0.id) },
                           chat: chat, readOutside: false, mention: .byBot(post: "back"))
      try check(back.seated.isEmpty && back.refused.count == 1, "group turn: a tag back to a bot that holds the work is refused")
      @MainActor func underRoot() -> Int { relay.handoffLedger.records.filter { ($0.rootID ?? $0.id) == writing.id }.count }
      let before = underRoot()
      var seats = 0
      var refusedAt: Int?
      for n in 0..<(HandoffLedger.maxPerRoot + 2) {
        let turn = relay.tag([editor], task: "@Editor look again", from: writer, parent: writing, chat: writing.threadID,
                             readOutside: false, mention: .byBot(post: "loop-\(n)"))
        guard turn.seated == [editor], let i = relay.handoffLedger.records.lastIndex(where: { $0.parentID == writing.id && $0.to == editor })
        else {
          refusedAt = n
          break
        }
        seats += 1
        relay.handoffLedger.records[i].state = .done
      }
      try check(refusedAt != nil && underRoot() == HandoffLedger.maxPerRoot && seats == HandoffLedger.maxPerRoot - before,
        "group turn: a loop stops at the cap [\(seats) seats, \(underRoot()) rows under the root, refused at \(refusedAt ?? -1)]")
    }
  }
}
#endif
