#if DEBUG
import Foundation
import SereinCore

/// The personal-assistant screens' pure rules (SereinCore/AssistantShell.swift): the paced reveal
/// of a streaming reply, the names in a system line, the message bar's key guard, the switch
/// order, the words under a name, a dashboard's summary and the details card's counts. The plan
/// card's own suite is `plan`. Pure: no window, no files.
extension AssistantCoreChecks {
  static func shell(_ check: Check) throws {
    try pacedReveal(check)
    try systemLines(check)
    try switching(check)
    try rowWords(check)
    try check(ComposerGuard.looksLikeKey("my key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV"), "A pasted key is refused before it leaves")
    try check(ComposerGuard.looksLikeKey("ghp_ABCDEFGHIJKLMNOPQRSTUV12"), "A GitHub token is refused")
    try check(!ComposerGuard.looksLikeKey("Remind me to ask Ana about the task-list at 5"), "Plain words go")
    try check(!ComposerGuard.looksLikeKey("Open https://example.com/search?q=lisbon+hotels"), "A link with a query goes")
    let saved = [PromptShortcut(name: "standup", text: "Write my standup from yesterday's notes")]
    func plan(_ typed: String, attached: Bool = false, refusal: String? = nil, question: Bool = false) -> MessagePlan {
      MessagePlan.of(typed, hasAttachments: attached, shortcuts: saved, mentionRefusal: refusal, questionWaits: question)
    }
    try check(plan("/standup") == .fill("Write my standup from yesterday's notes"), "A shortcut's name fills the box and nothing is sent")
    try check(plan("//standup") == .send("/standup"), "Two slashes send the name as it is written")
    try check(plan("my key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV", refusal: "Writer is still working.", question: true)
      == .refuse(ComposerGuard.keyRefusal), "A key is refused before a mention or a waiting question is weighed")
    try check(plan("@Writer", refusal: "This chat is busy.", question: true) == .refuse("This chat is busy."),
      "A mention that cannot go now keeps its words in the box")
    try check(plan("@Writer", refusal: "This chat is busy.").refusal == "This chat is busy." && plan("@Writer").refusal == nil,
      "A plan gives the reason for a refusal, and none once the same words would go")
    try check(plan("Tuesday", question: true) == .answer("Tuesday"), "Plain words answer the one question that waits")
    try check(plan("Tuesday", attached: true, question: true) == .send("Tuesday"), "Words with something attached are a new message, not an answer")
    try check(plan("", attached: true) == .send("") && plan("Tuesday") == .send("Tuesday"), "Attachments alone go, and so do plain words")
    let trip = DashboardSpec(
      title: "Lisbon trip", stat: DashboardSpec.Stat(label: "Lowest fare", value: "£174"),
      rows: [DashboardSpec.Row(label: "Hotels", value: "4"), DashboardSpec.Row(label: "Budget left", value: "£144"),
             DashboardSpec.Row(label: "Nights", value: "3")],
      sources: ["note:a"])
    try check(DashboardSummary.line(trip) == "Lowest fare £174, Hotels 4, Budget left £144", "A closed dashboard sums up in one line")
    let then = Date(timeIntervalSince1970: 1_793_268_000)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
    utc.locale = Locale(identifier: "en_US")
    try check(DashboardSummary.updated(then, now: then.addingTimeInterval(120), calendar: utc) == "Updated 2 minutes ago",
              "A dashboard says when it was updated")
    try check(DashboardSummary.updated(then, now: then.addingTimeInterval(86_400 * 3), calendar: utc) == "Updated on 29 Oct",
              "An older dashboard names the day")
    let apps = AssistantCardCounts.apps([.web, .mail, .calendar, .project, .connectedApps])
    try check(apps == 3, "The details card counts Mail, Calendar and connected apps as apps, not the web or projects")
  }

  static func pacedReveal(_ check: Check) throws {
    let text: [Character] = Array("Four hotels near Alfama under £140. Casa Azulejo sleeps eight.")
    let first = PacedReveal.next(text: text, shown: 0, elapsed: 1.0 / 60, streaming: true, holdTail: true, finishIn: 0.3)
    try check(first > 0 && first < text.count, "A live reply starts to show within one frame and does not show all at once")
    try check(first == text.count || text[first].isWhitespace, "The reveal stops at the end of a word")
    let floorOnly: [Character] = Array(String(repeating: "a ", count: 2))
    let slow = PacedReveal.next(text: floorOnly, shown: 0, elapsed: 0.05, streaming: false, holdTail: false, finishIn: 10)
    try check(slow >= 1, "A small backlog still moves at the 90-characters-a-second floor")
    var shown = 0
    var frames = 0
    while shown < text.count && frames < 1_000 {
      let left: Double = PacedReveal.finishSeconds - Double(frames) / 60
      shown = PacedReveal.next(text: text, shown: shown, elapsed: 1.0 / 60, streaming: false, holdTail: false, finishIn: left)
      frames += 1
    }
    try check(shown == text.count && frames <= 19, "After the stream ends, the rest shows within 0.3 seconds (\(frames) frames)")
    let half: [Character] = Array("Done. I moved it and told An")
    let held = PacedReveal.next(text: half, shown: 0, elapsed: 1, streaming: true, holdTail: true, finishIn: 0.3)
    try check(held <= half.count - 2, "While it streams, a half-sent last word waits")
    let settled = PacedReveal.next(text: half, shown: 0, elapsed: 1, streaming: true, holdTail: false, finishIn: 0.3)
    try check(settled == half.count, "A tail that stopped growing shows")
    let cjk: [Character] = Array(String(repeating: "東", count: 60))
    let wide = PacedReveal.next(text: cjk, shown: 0, elapsed: 1.0 / 60, streaming: false, holdTail: false, finishIn: 0.3)
    try check(wide > 0 && wide < cjk.count, "Text with no spaces shows a part at a time, not whole")
    let emoji: [Character] = Array("👩‍💻 ok")
    try check(PacedReveal.next(text: emoji, shown: 0, elapsed: 1, streaming: false, holdTail: false, finishIn: 0.3) == emoji.count,
              "The reveal counts whole characters, so an emoji is never cut in two")
    try check(PacedReveal.next(text: text, shown: text.count + 5, elapsed: 1, streaming: true, holdTail: true, finishIn: 0.3) == text.count,
              "A count past the end comes back to the end")
  }

  static func systemLines(_ check: Check) throws {
    typealias P = SystemLineParts.Part
    let names: [(id: String, name: String)] = [("p", "Planner"), ("s", "Scout"), ("i", "Inbox Zero"), ("i2", "Inbox Zero 2")]
    try check(SystemLineParts.split("Messaged Planner and Scout", names: names)
                == [P.words("Messaged "), P.name(id: "p", text: "Planner"), P.words(" and "), P.name(id: "s", text: "Scout")],
              "A system line names each assistant in it")
    try check(SystemLineParts.split("You made Inbox Zero 2", names: names) == [P.words("You made "), P.name(id: "i2", text: "Inbox Zero 2")],
              "The longer name wins")
    try check(SystemLineParts.split("Scouting for hotels", names: names) == [P.words("Scouting for hotels")],
              "A name inside a longer word is not a name")
    try check(SystemLineParts.split("", names: names).isEmpty, "An empty line has no parts")
    try check(SystemLineParts.split("Asked Planner.", names: names) == [P.words("Asked "), P.name(id: "p", text: "Planner"), P.words(".")],
              "A name before a full stop is a name")
  }

  static func switching(_ check: Check) throws {
    let order = AssistantSwitchOrder.order(main: "main", shown: ["a", "b", "a", "main", "c"])
    try check(order == ["main", "a", "b", "c"], "The switch order starts with Serein and lists each assistant once")
    try check(AssistantSwitchOrder.neighbour(of: "a", step: 1, in: order) == "b", "Down goes to the next assistant")
    try check(AssistantSwitchOrder.neighbour(of: "a", step: -1, in: order) == "main", "Up goes to the one before")
    try check(AssistantSwitchOrder.neighbour(of: "main", step: -1, in: order) == nil, "Up from the first goes nowhere")
    try check(AssistantSwitchOrder.neighbour(of: "c", step: 1, in: order) == nil, "Down from the last goes nowhere")
    try check(AssistantSwitchOrder.neighbour(of: "x", step: 1, in: order) == nil, "An assistant not in the list goes nowhere")
    try check(AssistantSwitchOrder.around("b", in: order) == ["a", "c"], "The chats loaded ahead are the ones before and after")
  }

  static func rowWords(_ check: Check) throws {
    let working = AssistantRowWords.of(status: .working(1), phase: "Looking at hotels\nmore", nextRun: nil, job: nil)
    try check(working == AssistantRowWords(text: "Looking at hotels", tone: .working), "A working row says what it does now, on one line")
    try check(AssistantRowWords.of(status: .replying, phase: nil, nextRun: nil, job: nil).text == "Working", "A reply with no step reads Working")
    try check(AssistantRowWords.of(status: .needsYou, phase: "x", nextRun: nil, job: nil).tone == .needsYou, "A card that waits reads Needs you")
    try check(AssistantRowWords.of(status: .paused, phase: nil, nextRun: "Checks at 8:00", job: nil) == AssistantRowWords(text: "Paused", tone: .faint),
              "A paused row reads Paused in faint")
    let quiet = AssistantRowWords.of(status: .ready, phase: nil, nextRun: "Checks at 8:00", job: "Keeps your inbox at zero")
    try check(quiet.text == "Checks at 8:00" && quiet.tone == .quiet, "A quiet row names its next routine first")
    let unread = AssistantRowWords.of(status: .unread, phase: nil, nextRun: nil, job: "Keeps your inbox at zero")
    try check(unread.text == "Keeps your inbox at zero" && unread.tone == .quiet, "An unread reply keeps the words; the dot says it")
    try check(AssistantRowWords.of(status: .ready, phase: nil, nextRun: " ", job: nil).text == "Ready", "With nothing to say, it reads Ready")
    let answering = AssistantRowWords.of(status: .ready, phase: nil, nextRun: "Checks at 8:00", job: nil, answering: "Serein")
    try check(answering == AssistantRowWords(text: "Answering Serein", tone: .working), "An asked assistant reads Answering Serein")
    try check(AssistantRowWords.of(status: .needsYou, phase: nil, nextRun: nil, job: nil, answering: "Serein").text == "Needs you",
              "A card that waits wins over an ask")
    let long = AssistantRowWords.of(status: .working(2), phase: String(repeating: "a", count: 90), nextRun: nil, job: nil)
    try check(long.text.count == AssistantRowWords.maxLine && long.text.hasSuffix("…"), "A long step is cut to 28 characters")
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    let now = Date(timeIntervalSince1970: 1_793_268_000)  // Thursday 29 October 2026, 10:00
    let hour: TimeInterval = 3600
    // The clock follows the calendar's locale, as receipts do; macOS puts a narrow space before AM and PM.
    func row(_ offset: TimeInterval) -> String {
      AssistantRowWords.checks(next: now.addingTimeInterval(offset), now: now, calendar: calendar)
        .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    try check(row(8.5 * hour) == "Checks at 6:30 PM", "A routine later today reads Checks at 6:30 PM")
    try check(row(22 * hour) == "Checks tomorrow at 8:00 AM", "A routine tomorrow reads Checks tomorrow at 8:00 AM")
    try check(row(70 * hour) == "Checks Sun at 8:00 AM", "A routine this week names the day")
    try check(AssistantRowWords.checks(next: now.addingTimeInterval(238 * hour), now: now, calendar: calendar) == "Checks 8 Nov",
              "A routine further off names the date")
    try check(AssistantCardCounts.label(1, one: "Routine", many: "Routines") == "Routine"
                && AssistantCardCounts.label(2, one: "Routine", many: "Routines") == "Routines", "A count of 1 is singular")
    try check(AssistantCardCounts.macApps([.web, .calendar, .mail]) == [.mail, .calendar], "The Mac's apps keep a fixed order")
  }

}
#endif
