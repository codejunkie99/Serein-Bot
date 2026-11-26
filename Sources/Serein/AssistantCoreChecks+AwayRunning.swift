#if DEBUG
import Foundation
import SereinCore

/// The away card at the Unread line (AwaySummary.swift), the chat pill's Running Now status
/// (RunningNow.swift) and where the room between turns goes in a chat (`ChatTurns`). Synthetic
/// data only.
extension AssistantCoreChecks {
  static func awayRunningTurns(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 3_000_000)
    func task(_ id: String, _ outcome: RunRecord.Outcome, endedAgo minutes: Double? = nil) -> SereinTrayList.Item {
      SereinTrayList.Item(
        id: id, title: "Task " + id, outcome: outcome, startedAt: now.addingTimeInterval(-7200),
        endedAt: minutes.map { now.addingTimeInterval(-$0 * 60) }, serein: true)
    }
    func outside(_ id: String, _ state: ExternalSession.State) -> ExternalSession {
      ExternalSession(id: id, driver: .codex, title: "Session " + id, cwd: "/work/" + id, state: state, updatedAt: now)
    }
    let entries = SereinSessionList.entries(
      tasks: [task("ask", .waiting), task("bad", .stuck, endedAgo: 20), task("oldBad", .stuck, endedAgo: 55),
              task("done", .done, endedAgo: 10), task("oldDone", .done, endedAgo: 50), task("run", .running)],
      outside: [outside("waits", .needsUser), outside("busy", .running)], now: now)

    // Away summary.
    let since = now.addingTimeInterval(-30 * 60)
    let groups = AwaySummary.groups(entries, since: since)
    try check(groups.map(\.kind) == [.needsYou, .failed, .done],
      "The away card says what needs the person first, then what did not finish, then what is done")
    try check(groups.first?.entries.map(\.sourceID).sorted() == ["ask", "waits"],
      "Everything waiting on the person counts, a session outside Serein too, however long it has waited")
    try check(groups.first { $0.kind == .failed }?.entries.map(\.sourceID) == ["bad"]
      && groups.first { $0.kind == .done }?.entries.map(\.sourceID) == ["done"],
      "A failure or a finish counts only if it ended while the person was away")
    try check(entries.filter(\.failed).map(\.sourceID).sorted() == ["bad", "oldBad"],
      "Only a task whose run failed is marked failed; a session outside Serein never is")
    try check(!groups.flatMap(\.entries).contains { $0.state == .working },
      "What is still at work is the header's line, not the away card's")
    try check(AwaySummary.groups(entries, since: nil).first { $0.kind == .done }?.entries.count == 2,
      "With no time away known, every finish still listed counts")
    try check(AwaySummary.groups(SereinSessionList.entries(tasks: [task("run", .running)], outside: [], now: now), since: since).isEmpty,
      "Nothing waiting, failed or done is no card")
    try check(AwaySummary.Kind.allCases.map(\.title) == ["Needs you", "Didn't finish", "Done"],
      "Each part of the away card names its state in words")
    func away(_ minutes: Double) -> String? { AwaySummary.awayWords(from: now.addingTimeInterval(-minutes * 60), to: now) }
    try check(away(0.5) == nil && away(25) == "25 min" && away(120) == "2 h" && away(134) == "2 h 14 min"
      && away(26 * 60) == "1 day" && away(3 * 24 * 60) == "3 days",
      "Time away reads in minutes, hours and minutes, then days, and under a minute says nothing")

    // Running now.
    try check(RunningNow.lead(entries) == "Session waits, Task bad and 2 more need you",
      "The pill names what needs the person (newest first) and leaves what runs to the peek, with no number on a badge")
    try check(RunningNow.lead(SereinSessionList.entries(tasks: [task("run", .running)], outside: [], now: now)) == "Task run running",
      "With nothing waiting, one task at work reads as its name")
    try check(RunningNow.lead(SereinSessionList.entries(tasks: [task("done", .done, endedAgo: 5)], outside: [], now: now)) == nil
      && RunningNow.lead([]) == nil, "Nothing waiting or at work leaves the pill with the name alone")
    try check(RunningNow.peek(entries) == "Needs you: Session waits, Task bad, Task oldBad, Task ask\nRunning: Session busy, Task run",
      "The hover peek names every one, under its state")

    // Turns.
    func you(_ text: String, id: String) -> AgentMessage { AgentMessage(id: id, role: "you", text: text) }
    func reply(_ text: String, id: String) -> AgentMessage { AgentMessage(id: id, role: "assistant", text: text) }
    let chat: [AgentMessage] = [
      you("Book the table", id: "y1"), reply("Booked, 7 pm.", id: "r1"),
      you("Also the weather?", id: "y2"), you("And remind Maya", id: "y3"), reply("Clear. Done.", id: "r2"),
      you(RelayGoal.promptLead + " the lease", id: "g1"), reply(RelayUnattended.quietMark, id: "q1"),
      you(RelayGoal.promptLead + " the flat", id: "g2"), reply("The flat is still listed.", id: "r3"),
      you("Thanks", id: "y4"), reply("Any time.", id: "r4"),
    ]
    let breaks = ChatTurns.breaks(chat)
    try check(!breaks.contains("y1"), "The first turn has no room above it")
    try check(breaks.contains("y2") && !breaks.contains("y3") && !breaks.contains("r1") && !breaks.contains("r2"),
      "A turn's reply sits close to its message, and the person's messages in a row are one turn")
    try check(!breaks.contains("g1") && !breaks.contains("q1"), "A turn Serein started that drew nothing leaves no room")
    try check(breaks.contains("g2") && breaks.contains("y4") && breaks.count == 3,
      "A turn Serein started itself and the person's next message each start a turn")
    let checkIn: [AgentMessage] = [
      you("Book the table", id: "y1"), reply("Booked, 7 pm.", id: "r1"),
      you(RelayProactive.marker + "Check-in. Look through what I have connected", id: "c1"), reply("Your 3 pm moved to 4.", id: "c2"),
      you("Thanks", id: "y2"),
    ]
    let quiet = ChatTurns.breaks(checkIn)
    try check(!quiet.contains("c1") && !quiet.contains("c2") && quiet == ["y2"],
      "A check-in, whose line is hidden, comes in as one more of Serein's texts: no empty room above it")
    // A condensed line reads as sent when the replies it folds were, not when it folded them.
    let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var hey = you("hey", id: "h1"); hey.sentAt = noon
    var early = reply("Earlier reply", id: "o1"); early.sentAt = noon.addingTimeInterval(60)
    var late = reply("Later reply", id: "o2"); late.sentAt = noon.addingTimeInterval(120)
    var summary = reply("Summary", id: "s1"); summary.sentAt = noon.addingTimeInterval(8 * 3600)
    summary.condensed = CondensedRange(originals: [hey, early, late], kept: ["h1"], session: nil, scope: "")
    var hi = you("hi", id: "h2"); hi.sentAt = noon.addingTimeInterval(180)
    let folded: [AgentMessage] = [hey, summary, hi]
    try check(ChatTurns.time(of: summary) == early.sentAt && ChatTurns.lastDrawnTime(before: 2, in: folded) == late.sentAt
      && !MessageTimeline.startsGroup(ChatTurns.time(of: summary), after: ChatTurns.lastDrawnTime(before: 1, in: folded))
      && !MessageTimeline.startsGroup(hi.sentAt, after: ChatTurns.lastDrawnTime(before: 2, in: folded)),
      "A condensed line takes the time of the replies it folds, so it never puts a later time between earlier messages")
  }
}
#endif
