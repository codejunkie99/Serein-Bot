#if DEBUG
import Foundation
import SereinCore

/// The face above the message bar and the "+" list (board 17, NbQuick): which running chat the
/// face shows when several run, its words, the filter and its order, the sections that show, the
/// recent chats, and what a pick puts into the draft. Pure: no window, no files.
extension AssistantCoreChecks {
  static func addList(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // The face: one that needs you first, then the newest; at rest none.
    let scout = RunningChat(assistantID: "scout", name: "Scout", chatID: "c1", title: "Lisbon fares", state: .working,
                            since: now.addingTimeInterval(-60))
    let writer = RunningChat(assistantID: "writer", name: "Writer", chatID: "c2", title: "Launch post", state: .working,
                             since: now.addingTimeInterval(-10))
    let planner = RunningChat(assistantID: "planner", name: "Planner", chatID: "c3", title: nil, state: .needsYou,
                              since: now.addingTimeInterval(-600))
    try check(QuickFace.now([]) == nil, "Nothing runs: the face rests")
    try check(QuickFace.now([scout, writer]) == writer, "Of two that work, the newest shows")
    try check(QuickFace.now([writer, scout]) == writer, "The order they come in does not count")
    try check(QuickFace.now([scout, planner, writer]) == planner, "One that needs you shows before one that works")
    var twin = writer
    twin.assistantID = "able"
    try check(QuickFace.now([writer, twin]) == twin && QuickFace.now([twin, writer]) == twin,
              "Equal starts go by assistant id, so the face holds still")

    // Its words.
    try check(QuickFace.line(scout) == "Scout is working · Lisbon fares", "Working names the chat")
    try check(QuickFace.line(planner) == "Planner needs you", "Needs you names no chat")
    try check(QuickFace.line(nil) == nil, "At rest there is no line")
    try check(QuickFace.line(QuickFace.withoutTitle(scout)) == "Scout is working", "Without its title the line keeps the name")
    try check(QuickFace.spoken(scout, restName: "Serein") == "Scout is working on Lisbon fares. Open the chat.",
              "VoiceOver says what runs and what a press does")
    try check(QuickFace.spoken(nil, restName: "Serein") == "Serein. Open the chat.", "At rest VoiceOver names the chat it opens")
    try check(QuickFace.shimmers(scout) && !QuickFace.shimmers(planner) && !QuickFace.shimmers(nil),
              "Only a working line shimmers")
    try check(QuickFace.title("Plan for Ana", chatID: "ask1", hidden: ["ask1"]) == nil, "A hidden ask chat never gives its title")
    try check(QuickFace.title("  Lisbon\nfares ", chatID: "c1", hidden: ["ask1"]) == "Lisbon fares", "A title is one line")
    try check(QuickFace.title("   ", chatID: "c1", hidden: []) == nil, "An empty title shows none")
    let long: String = String(repeating: "a", count: 90)
    try check(QuickFace.title(long, chatID: nil, hidden: [])?.count == QuickFace.titleLimit, "A long title is cut to its limit")
    try check(QuickFace.title("A\u{202E}B", chatID: nil, hidden: []) == "AB", "Hidden characters leave a title")
    let lines: [String] = [QuickFace.line(scout), QuickFace.line(planner), QuickFace.spoken(scout, restName: "Serein"),
                           AddListRules.nothing("x")].compactMap { $0 }
    for line in lines {
      let words: Set<String> = Set(line.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
      try check(ReceiptCopy.bannedWords.intersection(words).isEmpty, "No feature words: \(line)")
    }

    // "@" at the start of a draft opens the list; other drafts do not.
    try check(AddListRules.atQuery("@") == "", "\"@\" alone opens the list with no filter")
    try check(AddListRules.atQuery("@sc") == "sc", "The word after \"@\" is the filter")
    try check(AddListRules.atQuery("@sc hi") == nil, "A space after the word closes it")
    try check(AddListRules.atQuery("hi @sc") == nil, "\"@\" later in the draft is the Send to list's")
    try check(AddListRules.atQuery("") == nil && AddListRules.atQuery("@a@b") == nil, "An empty draft or a second \"@\" opens nothing")

    // The filter and its order.
    try check(AddListRules.rank("Scout", query: "") == 0, "An empty filter matches everything")
    try check(AddListRules.rank("Scout", query: "sc") == 0, "A title that starts with the words comes first")
    try check(AddListRules.rank("Google Calendar", query: "cal") == 1, "A word that starts with them comes next")
    try check(AddListRules.rank("Inbox clean-up", query: "lean") == 2, "Words inside a title come last")
    try check(AddListRules.rank("Writer", query: "sc") == nil, "A title without the words is left out")
    try check(AddListRules.rank("Résumé draft", query: "resume") == 0, "Case and accents do not count")

    let rows: [AddListRow] = [
      AddListRow(kind: .attach, title: "Attach a file", detail: "Photos, PDFs and documents"),
      AddListRow(kind: .teach, title: "Teach a skill", detail: "Show Serein how once"),
      AddListRow(kind: .assistant("scout"), title: "Scout", detail: "Finds fares and hotels", now: true),
      AddListRow(kind: .assistant("inbox"), title: "Inbox Zero", detail: "Cleans your inbox"),
      AddListRow(kind: .chat("c1"), title: "Lisbon fares", detail: "Scout · working", now: true),
      AddListRow(kind: .chat("c4"), title: "Inbox clean-up", detail: "Inbox Zero · 8:02 AM"),
      AddListRow(kind: .app("gmail", connected: true), title: "Gmail", detail: "Connected"),
      AddListRow(kind: .app("slack", connected: false), title: "Slack", detail: "Not connected"),
      AddListRow(kind: .plugin("visualize"), title: "Visualize", detail: "Makes charts from your data"),
      AddListRow(kind: .addApp, title: "Add an app…", detail: "Connect another app"),
    ]
    let all: [AddListGroup] = AddListRules.groups(rows, query: "")
    try check(all.map(\.section) == [.actions, .assistants, .chats, .apps, .plugins, .more], "Sections show in their order")
    try check(AddListRules.flat(all) == rows, "With no filter every row shows in its order")
    try check(all.map(\.section.heading) == [nil, "Assistants", "Chats", "Apps", "Plugins", nil],
              "Only the four kinds have headings")
    let inbox: [AddListGroup] = AddListRules.groups(rows, query: "inbox")
    try check(inbox.map(\.section) == [.assistants, .chats], "Filtering hides the empty sections")
    try check(AddListRules.groups(rows, query: "sl").first?.rows.map(\.id) == ["app:slack"], "An app is found by its name")
    let ranked: [AddListGroup] = AddListRules.groups([
      AddListRow(kind: .chat("x"), title: "Plan the move", detail: ""),
      AddListRow(kind: .chat("y"), title: "Lisbon plan", detail: ""),
      AddListRow(kind: .chat("z"), title: "Planner notes", detail: ""),
    ], query: "plan")
    try check(ranked.first?.rows.map(\.id) == ["chat:x", "chat:z", "chat:y"], "Better matches come first, equal ones keep their order")
    try check(AddListRules.groups(rows, query: "zzz").isEmpty, "No match leaves no section")
    try check(AddListRules.nothing("zzz") == "Nothing called “zzz”", "No match says so in plain words")

    // The keys wrap.
    try check(AddListRules.moving(0, by: -1, count: 3) == 2 && AddListRules.moving(2, by: 1, count: 3) == 0, "↑ and ↓ wrap")
    try check(AddListRules.moving(1, by: 1, count: 3) == 2 && AddListRules.moving(0, by: 1, count: 0) == 0, "↓ moves one row")

    // What the list offers.
    try check(!AddListRules.listsAssistant(hidden: true, busy: false), "A hidden assistant is left out")
    try check(AddListRules.listsAssistant(hidden: true, busy: true), "A hidden assistant shows while it works")
    try check(AddListRules.listsAssistant(hidden: false, busy: false), "Every other assistant shows")
    func entry(_ id: String, _ age: Double, running: Bool = false) -> AddListChat {
      AddListChat(id: id, title: id, ownerName: "Scout", date: now.addingTimeInterval(-age), running: running)
    }
    let chats: [AddListChat] = [entry("a", 50), entry("b", 10), entry("ask", 1), entry("c", 30, running: true), entry("here", 2),
                                entry("b", 10), entry("d", 60), entry("e", 70), entry("f", 80), entry("g", 90)]
    let recent: [String] = AddListRules.recentChats(chats, hidden: ["ask"], current: "here").map(\.id)
    try check(recent == ["c", "b", "a", "d", "e", "f"], "The running chat first, then the newest, at most six")
    try check(!recent.contains("ask"), "A hidden ask chat is never offered")
    try check(!recent.contains("here"), "The chat on screen is not offered")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    try check(AddListRules.when(now.addingTimeInterval(-60), now: now, calendar: calendar) == .today, "A minute ago is today")
    try check(AddListRules.when(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == .yesterday, "A day ago is yesterday")
    try check(AddListRules.when(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) == .earlier, "Three days ago is earlier")
    try check(AddListRules.chatDetail(owner: "Scout", running: true, when: .today, time: "8:02 AM", day: "Oct 28") == "Scout · working",
              "A running chat reads working")
    try check(AddListRules.chatDetail(owner: "Writer", running: false, when: .yesterday, time: "", day: "") == "Writer · Yesterday",
              "Yesterday's chat reads Yesterday")
    try check(AddListRules.chatDetail(owner: "Inbox Zero", running: false, when: .today, time: "8:02 AM", day: "")
              == "Inbox Zero · 8:02 AM", "Today's chat reads its time")

    // What a pick puts into the draft.
    let gmail: String = AddListRules.withWords("Gmail")
    try check(gmail == "with Gmail", "An app adds \"with Gmail\"")
    try check(AddListRules.adding(gmail, to: "") == "with Gmail ", "An empty draft takes the words and a space")
    try check(AddListRules.adding(gmail, to: "Sort my mail  ") == "Sort my mail with Gmail ", "The words go at the end")
    try check(AddListRules.adding(gmail, to: "@gm") == "with Gmail ", "The \"@\" word that opened the list goes")
    try check(AddListRules.adding(gmail, to: "Sort my mail with gmail") == "Sort my mail with gmail ", "Words already there are not added again")
    try check(AddListRules.clearing("@sc") == "" && AddListRules.clearing("Book a table") == "Book a table",
              "Opening a chat keeps the draft, without the \"@\" word")
    try check(AddListRules.withWords("Charts\nand graphs") == "with Charts and graphs", "A plugin's name is one line")
  }
}
#endif
