#if DEBUG
import Foundation
import SereinCore

/// No queue (RelaySideSeats.swift) on a real Relay over a throwaway library: a message to a busy
/// chat takes a side seat at once with nothing queued, its answer posts once under it, a turn past
/// 150 s moves to the background on an injected clock and its answer posts once, a relaunch between
/// finishing and posting still posts once, a full cap says so and loses nothing, and a stop ends
/// the right seat.
extension AssistantCoreChecks {
  static func noQueue(_ check: Check) throws {
    let start = Date(timeIntervalSince1970: 1_000)
    try check(!SideSeat.moves(startedAt: start, now: start.addingTimeInterval(149), moved: false)
        && SideSeat.moves(startedAt: start, now: start.addingTimeInterval(150), moved: false)
        && !SideSeat.moves(startedAt: start, now: start.addingTimeInterval(900), moved: true),
      "no queue: a turn moves at 150 s, once")
    try check(SideSeat.free(seated: 2, delegated: 0) && !SideSeat.free(seated: 1, delegated: 2) && !SideSeat.free(seated: 3, delegated: 0),
      "no queue: side seats and delegated runs share the cap of three")

    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "no queue: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-noqueue-\(UUID().uuidString)", isDirectory: true)
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
        try check(false, "no queue: the roster takes Writer")
        return
      }
      let lead = relay.team.activeID
      let chat = relay.threadID
      @MainActor func saved(_ relay: RelayOrchestrator, _ thread: String) -> [AgentMessage] {
        thread == relay.agent.conversationID ? relay.agent.messages : relay.agent.conversations.first { $0.id == thread }?.messages ?? []
      }
      @MainActor func seen(_ id: String) -> Int {
        saved(relay, chat).filter { $0.id == id }.count + (relay.desk.facts[chat]?.above.filter { $0.id == id }.count ?? 0)
      }
      @MainActor func row(_ id: String) -> AssistantHandoff? { relay.handoffLedger.records.first { $0.id == id } }
      @MainActor func close(_ id: String, _ result: String) {
        guard let i = relay.handoffLedger.records.firstIndex(where: { $0.id == id }) else { return }
        relay.handoffLedger.records[i].state = .done
        relay.handoffLedger.records[i].result = result
        relay.handoffLedger.records[i].posted = false
        relay.handoffsStarting.remove(relay.handoffLedger.records[i].threadID)
        relay.saveHandoffs()
      }
      @MainActor func fakeRun(_ thread: String, _ transcript: [AgentMessage]) -> AgentRun {
        var spec = RunSpec(threadID: thread, provider: .claude, executable: "/usr/bin/false", model: "", effort: "low", mode: .answer,
          projectID: nil, projectName: nil, title: "Check", scope: "", autoRouting: false, grants: RunGrants(),
          limits: RunLimits(hard: 600, idle: 600))
        spec.relay = true
        spec.initiator = .relay
        return AgentRun(spec: spec, taskID: "noqueue-" + UUID().uuidString, transcript: transcript)
      }
      /// The chat's busy turn ends: what it held lands on it (`landTurnFacts`).
      @MainActor func turnEnds() {
        relay.sending = false
        relay.landTurnFacts(fakeRun(chat, []))
      }

      // The chat the person is in, saved with the message its busy turn answers.
      relay.post(AgentMessage(role: "you", text: "Sort my inbox"), into: chat)
      try check(!saved(relay, chat).isEmpty, "no queue: the chat is saved")

      // 1. A busy chat and a new message: a side seat starts at once, and nothing is queued.
      relay.sending = true
      try check(relay.working && relay.ask("What's the weather in Lisbon?"), "no queue: a message to a busy chat is taken")
      guard let side = relay.handoffLedger.records.last, side.side == .busy, case .byPerson(let asked)? = side.mention else {
        try check(false, "no queue: a busy chat's message takes a side seat")
        return
      }
      let queuedBubble = relay.desk.facts[chat]?.above.first { $0.id == asked }
      try check(relay.pending.isEmpty && side.from == lead && side.to == lead && side.askedIn == chat && side.parentID == nil
          && relay.handoffsStarting.contains(side.threadID) && side.threadID.hasPrefix(RelayOrchestrator.seatPrefix)
          && seen(asked) == 1 && queuedBubble.map { LiveTurnFacts.draws($0, profiles: relay.team.profiles) } == true
          && relay.handoffLedger.daily.isEmpty,
        "no queue: a busy chat plus a new message gives a side seat right away, its message renders in the live chat, with no queue")

      // 2. Its answer posts once, under that message, in the origin chat.
      close(side.id, "Sunny, 24 °C.")
      relay.deliverHandoffReports()
      try check(seen(HandoffReport.postID(side.id)) == 1 && row(side.id)?.reported != true,
        "no queue: while the chat is busy the side answer shows there, and is claimed only once saved")
      turnEnds()
      relay.deliverHandoffReports()
      relay.sweepHandoffs()
      let answer = saved(relay, chat).filter { $0.id == HandoffReport.postID(side.id) }
      try check(answer.count == 1 && answer[0].from == lead && answer[0].re == asked && answer[0].notice != true
          && answer[0].text == "Sunny, 24 °C." && seen(asked) == 1 && row(side.id)?.reported == true && row(side.id)?.posted == true,
        "no queue: the side answer posts once to the origin chat, from its assistant, answering the message")

      // 3. A turn past 150 s moves to the background on the injected clock; the chat frees.
      // A real run on the hub holds the chat: a sleeping process stands in for the AI app.
      let message = AgentMessage(role: "you", text: "Plan the team offsite")
      var spec = RunSpec(threadID: chat, provider: .claude, executable: "/bin/sleep", model: "", effort: "low", mode: .answer,
        projectID: nil, projectName: nil, title: "Check", scope: "", autoRouting: false, grants: RunGrants(),
        limits: RunLimits(hard: 600, idle: 600))
      spec.relay = true
      spec.initiator = .relay
      let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
      let long = try agent.hub.start(spec, task: task, arguments: ["60"], folder: root, prompt: "",
        transcript: saved(relay, chat) + [message, AgentMessage(role: "assistant", text: "Looking at venues near the river")])
      defer {
        agent.hub.stop(long)
        browser.endTask(task.capability.task)
      }
      try check(relay.run === long && relay.working, "no queue: the person's turn holds the chat")
      let began = long.record.startedAt
      try check(relay.moveLongTurn(long, now: began.addingTimeInterval(149)) == nil && long.isActive,
        "no queue: a turn under 150 s stays in its chat")
      let moved = relay.moveLongTurn(long, now: began.addingTimeInterval(151))
      try check(moved?.side == .background && moved?.mention == .byPerson(message: message.id)
          && moved?.task.contains("Plan the team offsite") == true && moved?.task.contains("venues near the river") == true
          && !long.isActive && long.record.outcome == .stopped && !relay.working
          && saved(relay, chat).contains { $0.id == "background-" + (moved?.id ?? "") && $0.line == SideSeat.backgroundLine && $0.re == message.id },
        "no queue: a turn past 150 s goes to the background, says so in plain words, and the chat frees")
      try check(relay.moveLongTurn(long, now: began.addingTimeInterval(400)) == nil
          && relay.handoffLedger.records.filter { $0.side == .background }.count == 1,
        "no queue: a turn moves to the background once")
      if let moved {
        close(moved.id, "Booked the boathouse for Friday.")
        relay.deliverHandoffReports()
        relay.deliverHandoffReports()
        relay.sweepHandoffs()
        try check(saved(relay, chat).filter { $0.id == HandoffReport.postID(moved.id) }.count == 1 && row(moved.id)?.reported == true,
          "no queue: the background result posts once to the origin chat")
      }

      // 5. At the cap the message says so, waits for a seat, and is never lost.
      relay.sending = true
      for text in ["one", "two", "three", "four"] { _ = relay.ask("Side question \(text)") }
      let sides = relay.handoffLedger.records.suffix(4)
      let last = sides.last
      try check(sides.allSatisfy { $0.side == .busy } && sides.prefix(3).allSatisfy { relay.handoffsStarting.contains($0.threadID) }
          && last?.state == .waiting && last.map { !relay.handoffsStarting.contains($0.threadID) } == true
          && relay.desk.facts[chat]?.above.contains { $0.id == "side-wait-" + (last?.id ?? "") && $0.line == SideSeat.fullLine } == true
          && sides.allSatisfy { seen($0.mention?.post ?? "") == 1 } && relay.pending.isEmpty,
        "no queue: at the cap of three side seats the fourth message shows the notice and waits, and nothing is lost")
      if let first = sides.first, let last {
        close(first.id, "One.")
        relay.startWaitingHandoffs()
        try check(relay.handoffsStarting.contains(last.threadID), "no queue: a message that waited at the cap starts when a seat frees")
      }
      for record in sides.dropFirst() { close(record.id, "Done.") }
      turnEnds()
      relay.sweepHandoffs()

      // 6. Stop cancels the right run: "@Writer stop" Writer's turn only, a bare "stop" this chat's side seats.
      relay.sending = true
      _ = relay.ask("Check my calendar")
      let mine = relay.handoffLedger.records.last
      _ = relay.ask("@Writer draft the toast")
      let theirs = relay.handoffLedger.records.last
      try check(mine?.side == .busy && theirs?.to == writer && theirs?.side == nil, "no queue: a side seat and a tagged turn both run")
      _ = relay.ask("@Writer stop")
      _ = relay.switchTo(lead)
      try check(row(theirs?.id ?? "")?.state == .failed && row(mine?.id ?? "")?.isOpen == true,
        "no queue: “@Writer stop” stops Writer's turn and leaves this chat's side seat running")
      _ = relay.ask("stop")
      try check(row(mine?.id ?? "")?.state == .failed && row(mine?.id ?? "")?.result == HandoffLedger.stoppedWords,
        "no queue: a bare stop stops this chat's side seat")
      turnEnds()
      relay.sweepHandoffs()

      // 4. A relaunch after the seat finished and before its answer was saved still posts it once.
      relay.sending = true
      _ = relay.ask("Remind me what we decided")
      guard let late = relay.handoffLedger.records.last, late.side == .busy else {
        try check(false, "no queue: a side seat before the relaunch")
        return
      }
      close(late.id, "Friday at the boathouse.")
      relay.postReport(row(late.id)!)
      try check(seen(HandoffReport.postID(late.id)) == 1 && saved(relay, chat).allSatisfy { $0.id != HandoffReport.postID(late.id) },
        "no queue: before the relaunch the answer waits only in the busy chat's memory")
      RelayOrchestrator.releaseForChecks(relay)
      let browser2 = try BrowserModel(root: root)
      let agent2 = AgentModel(browser: browser2, discoverProviders: false)
      let relay2 = RelayOrchestrator.start(agent: agent2, browser: browser2)
      defer { RelayOrchestrator.releaseForChecks(relay2) }
      defer { relay2.stopEverything(pause: true) }
      relay2.sweepHandoffs()
      relay2.sweepHandoffs()
      let after = saved(relay2, chat)
      try check(after.filter { $0.id == HandoffReport.postID(late.id) }.count == 1
          && after.filter { $0.id == late.mention?.post }.count == 1
          && relay2.handoffLedger.records.first { $0.id == late.id }?.reported == true,
        "no queue: a restart after finishing and before posting still posts once, with its message")
    }
  }
}
#endif
