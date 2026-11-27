#if DEBUG
import Foundation
import SereinCore

/// The finish notice (SereinCore/FinishNotice.swift, FinishNoticePanel.swift): which finishes show
/// one, that a swarm worker's notice answers to that worker and not its lead, that several finishes
/// stack without a flood, and, on a real Relay over a throwaway library, that a reply typed in a
/// notice lands in the chat and reaches that bot's seat with no card.
extension AssistantCoreChecks {
  static func finishNotice(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 10_000)
    func task(_ outcome: RunRecord.Outcome) -> FinishNotice? {
      .task(thread: "t1", title: "Fix the test", outcome: outcome, summary: "Fixed it.\nMore words.", who: "Claude Code",
            place: "serein-bot", took: 90, at: now)
    }
    try check(task(.done)?.target == .task(thread: "t1") && task(.done)?.summary == "Fixed it." && task(.stuck)?.failed == true,
              "finish notice: a task that is done or stuck shows, its reply goes to that task")
    try check(task(.waiting) == nil && task(.stopped) == nil && task(.running) == nil,
              "finish notice: a waiting, stopped or running task shows none")

    // A swarm: the lead's row holds three seats; all four share the lead's assistant.
    var lead = AssistantHandoff(from: "lead", to: "lead", task: "Find fares", threadID: "seat-lead", askedIn: "chat",
                                team: "", teamName: "All assistants", state: .done)
    lead.side = .swarmLead
    lead.result = "Merged fares."
    var seat = AssistantHandoff(from: "lead", to: "lead", task: "Find fares", threadID: "seat-a", askedIn: "seat-lead",
                                team: "", teamName: "All assistants", state: .done, parent: lead)
    seat.side = .swarm
    seat.route = AssistantRoute(provider: "codex", model: "gpt-5")
    seat.result = "Three fares under $600."
    seat.startedAt = now
    seat.finishedAt = now.addingTimeInterval(120)
    let worker = FinishNotice.handoff(seat, who: "Lead", place: "Seat on gpt-5", opens: "chat", at: now)
    try check(worker?.target == .seat(handoff: seat.id) && worker?.took == 120 && worker?.opens == "chat",
              "finish notice: a swarm worker's notice replies to that worker's seat, not to the lead")
    try check(FinishNotice.handoff(lead, who: "Lead", place: nil, opens: "chat", at: now)?.target == .chat(assistant: "lead"),
              "finish notice: the swarm lead's notice replies in the lead's chat")
    var part = AssistantHandoff(from: "a", to: "b", task: "Part", threadID: "b-chat", askedIn: "a-chat", team: "t",
                                teamName: "Trip", state: .done, parent: lead)
    part.result = "Done."
    var stopped = seat
    stopped.result = HandoffLedger.stoppedWords
    var open = seat
    open.state = .running
    try check(FinishNotice.handoff(part, who: "B", place: nil, opens: "chat", at: now) == nil
        && FinishNotice.handoff(stopped, who: "Lead", place: nil, opens: "chat", at: now) == nil
        && FinishNotice.handoff(open, who: "Lead", place: nil, opens: "chat", at: now) == nil,
              "finish notice: a chain part, a stopped seat and an open one show none")
    let asked = FinishNotice.seatTask(words: "Make it cheaper", earlier: "Three fares under $600.")
    try check(asked.hasPrefix("Make it cheaper") && asked.contains("Three fares under $600.")
        && FinishNotice.seatTask(words: "Hi", earlier: "  \n") == "Hi",
              "finish notice: a reply to a seat carries what the seat answered before")

    // Stacking: one card per target, at most three, the rest folded; held cards never fold or fade.
    func card(_ id: String, _ summary: String = "Done.") -> FinishNotice {
      FinishNotice(target: .seat(handoff: id), face: "lead", title: "Find fares", summary: summary, who: "Lead", place: nil,
                   took: nil, failed: false, at: now, opens: "chat")
    }
    var stack = FinishNoticeStack()
    for id in ["a", "b", "c", "d", "e"] { stack.add(card(id), now: now) }
    try check(stack.notices.map(\.id) == [.seat(handoff: "e"), .seat(handoff: "d"), .seat(handoff: "c")] && stack.more == 2,
              "finish notice: five finishes show the newest three and fold two into one line")
    stack.add(card("d", "Again."), now: now)
    try check(stack.notices.count == 3 && stack.notices[1].notice.summary == "Again." && stack.more == 2,
              "finish notice: a second finish for the same target replaces its card in place")
    var held = FinishNoticeStack()
    for id in ["a", "b", "c"] { held.add(card(id), now: now) }
    held.hold(.seat(handoff: "a"), true, now: now)
    held.add(card("d"), now: now)
    try check(held.notices.contains { $0.id == .seat(handoff: "a") } && !held.notices.contains { $0.id == .seat(handoff: "b") },
              "finish notice: a held card never folds; the oldest idle one does")
    let life = FinishNoticeStack.life(voiceOver: false)
    try check(!held.expire(now: now.addingTimeInterval(life - 1), life: life)
        && held.expire(now: now.addingTimeInterval(life), life: life)
        && held.notices.map(\.id) == [.seat(handoff: "a")],
              "finish notice: idle cards fade after their life, a held one stays")
    held.close(.seat(handoff: "a"))
    try check(held.notices.isEmpty && held.more == 0, "finish notice: closing the last card takes the fold line with it")

    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "finish notice: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-finishnotice-\(UUID().uuidString)", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      let browser = try BrowserModel(root: root)
      try files.createDirectory(
        at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
      let agent = AgentModel(browser: browser, discoverProviders: false)
      agent.available[.claude] = "/nonexistent/serein-check-claude"
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }
      defer { relay.stopEverything(pause: true) }
      relay.networkOnline = { true }
      guard relay.addProfile("Writer"), let writer = relay.team.profiles.first(where: { $0.name == "Writer" })?.id else {
        try check(false, "finish notice: the roster takes Writer")
        return
      }
      let me = relay.team.activeID
      let chat = relay.threadID
      relay.post(AgentMessage(role: "you", text: "Find fares to Lisbon"), into: chat)
      @MainActor func saved(_ thread: String) -> [AgentMessage] {
        thread == relay.agent.conversationID ? relay.agent.messages : relay.agent.conversations.first { $0.id == thread }?.messages ?? []
      }
      @MainActor func landed(_ text: String, in thread: String) -> Bool {
        saved(thread).contains { $0.role == "you" && $0.text == text }
          || (relay.desk.facts[thread]?.above.contains { $0.role == "you" && $0.text == text } ?? false)
      }
      @MainActor func noCard() -> Bool { relay.approvals.isEmpty && relay.questionForms.isEmpty && !relay.consentWaiting }

      // A finished swarm in this chat: the lead's row and one seat on its own model.
      var leadRow = AssistantHandoff(from: me, to: me, task: "Find fares", threadID: "", askedIn: chat, team: "",
                                     teamName: "All assistants", state: .done)
      leadRow.threadID = RelayOrchestrator.seatThread(leadRow.id)
      leadRow.side = .swarmLead
      var seatRow = AssistantHandoff(from: me, to: me, task: "Find fares", threadID: "", askedIn: leadRow.threadID, team: "",
                                     teamName: "All assistants", state: .done, parent: leadRow)
      seatRow.threadID = RelayOrchestrator.seatThread(seatRow.id)
      seatRow.side = .swarm
      seatRow.route = AssistantRoute(provider: "claude", model: "claude-sonnet-4-5")
      seatRow.result = "Three fares under $600."
      relay.handoffLedger.records += [leadRow, seatRow]
      let before = Set(relay.handoffLedger.records.map(\.id))

      try check(relay.replyFromNotice(.seat(handoff: seatRow.id), "Make it cheaper") == nil,
                "finish notice: a reply to a seat is taken")
      let reply = relay.handoffLedger.records.first { !before.contains($0.id) }
      try check(landed("Make it cheaper", in: chat), "finish notice: the reply lands in the chat the seat answered, as the person's words")
      try check(reply?.to == me && reply?.route == seatRow.route && reply?.side == .busy && reply?.parentID == nil
          && reply?.task.contains("Three fares under $600.") == true,
                "finish notice: the reply reaches that worker's seat, on the worker's model, with what it said before")
      if case .byPerson = reply?.mention {} else { try check(false, "finish notice: the seat answers the person's message") }
      try check(noCard(), "finish notice: a reply to a seat raises no card")

      let writerChat = relay.mainThread(of: writer)
      let seen = Set(relay.handoffLedger.records.map(\.id))
      try check(relay.replyFromNotice(.chat(assistant: writer), "Send it to Ana too") == nil
          && relay.team.activeID == me && relay.threadID == chat,
                "finish notice: a reply to another bot's chat is taken without switching the chat on screen")
      let writerSeat = relay.handoffLedger.records.first { !seen.contains($0.id) }
      try check(landed("Send it to Ana too", in: writerChat) && writerSeat?.to == writer && noCard(),
                "finish notice: the reply lands in that bot's chat and that bot answers it, with no card")
      try check(relay.replyFromNotice(.chat(assistant: "gone"), "Hello") == "That assistant was deleted.",
                "finish notice: a reply to a deleted bot says so")
    }
  }
}
#endif
