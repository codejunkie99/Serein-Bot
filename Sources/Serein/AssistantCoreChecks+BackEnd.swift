#if DEBUG
import Foundation
import SereinCore

/// The back end's fix round: the connection catalogue (`connect_app` and a routine's pill), the
/// failure table's words, dashboards from the model's words, the link receiver's head rules, the
/// person's yes to an idea, new words for an assistant, a routine card's switch and the words for
/// the new state files.
extension AssistantCoreChecks {
  static func backEnd(_ check: Check) throws {
    try backEndConnect(check)
    try backEndFailures(check)
    try backEndDashboards(check)
    try backEndGuards(check)
  }

  // MARK: connect

  private static func backEndConnect(_ check: Check) throws {
    func found(_ raw: String) -> String? {
      switch ConnectCatalog.resolve(raw) {
      case .mac(let id)?: return "mac:" + id
      case .composio(let link)?: return link.app + "|" + link.name
      case nil: return nil
      }
    }
    try check(found("Gmail") == "gmail|Gmail", "Gmail is a Composio app by its name")
    try check(found("my Google Calendar account") == "googlecalendar|Google Calendar", "Words around a name do not change it")
    try check(found("gcal") == "googlecalendar|Google Calendar", "A short name people use finds the app")
    try check(found("the GitHub") == "github|GitHub" && found("Slack app") == "slack|Slack", "Known apps keep their own names")
    try check(found("Mail") == "mac:mail" && found("email") == "mac:mail", "Mail is the app on this Mac")
    try check(found("Apple Notes") == "mac:notes" && found("Calendar") == "mac:calendar", "Notes and Calendar are apps on this Mac")
    try check(found("Google Tasks") == "googletasks|Google Tasks", "Another app's plain name becomes its id")
    try check(found("https://tools.example.com") == nil && found("example.com") == nil, "An address is not an app name")
    try check(found("") == nil && found("one two three four") == nil, "No words, or too many, name no app")
    try check(found("app2go") == nil, "A name with digits is not taken as an app's id")
    try check(found("sk-ant-api03-abcdefghijklmnopqrstuvwxyz") == nil, "A key never becomes an app's name")
    try check(ConnectCatalog.named(in: "Every weekday at 9, summarize my Slack.").map(\.app) == ["slack"],
              "A routine's words name the app it needs")
    try check(ConnectCatalog.named(in: "Check Gmail and Notion for news").map(\.app) == ["gmail", "notion"],
              "Each app a routine names is found once")
    try check(ConnectCatalog.named(in: "Zoom in on the linear chart").isEmpty && ConnectCatalog.named(in: "Check my mail").isEmpty,
              "Common words and Mac apps give no pill")
    try check(
      ConnectCatalog.shown("Slack") == "The person sees a button to connect Slack. Tell them in one short sentence, then stop.",
      "The model reads one sentence and nothing else")
    let line = "Okay. Every weekday at 9:00 I will summarize Slack."
    let longer = ScheduleRequest.connectFirst(line, app: "Slack")
    try check(longer == line + " Connect Slack first, then it runs." && ReceiptCopy.lint(longer).isEmpty,
              "A routine that needs an app says to connect it first")
    let full = "Okay. " + String(repeating: "a", count: 125) + "."
    try check(ScheduleRequest.connectFirst(full, app: "Slack") == full, "A line with no room stays as it is")
  }

  // MARK: failures

  private static func backEndFailures(_ check: Check) throws {
    typealias F = TurnFailure
    try check(F.plainReason("Serein needs an AI app for this. Connect one in Settings › AI apps.") == "Serein needs an AI app for this.",
              "A plain reason keeps its first sentence")
    try check(F.plainReason("the model is overloaded right now") == "The model is overloaded right now.",
              "A reason gets a capital and a full stop")
    try check(F.plainReason("Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\"") == nil,
              "System error text is left out")
    try check(F.plainReason("HTTP 529 overloaded") == nil && F.plainReason("{\"type\":\"error\"}") == nil,
              "Codes and raw data are left out")
    try check(F.plainReason(nil) == nil && F.plainReason("  ") == nil, "No reason is none")
    try check(F.couldNotAnswer("Scout", reason: "Codex exited (1). See /tmp/log") == "Scout could not answer.",
              "Without a plain reason the line stops after its first sentence")
    try check(F.couldNotAnswer("Scout", reason: "The model is busy. Try later.") == "Scout could not answer. The model is busy.",
              "With a plain reason the line says it")
    try check(
      F.stoppedAnswering("Claude Code", minutes: 1)
        == "Claude Code stopped answering. Nothing came for 1 minute, so I ended this turn. Ask again.",
      "A quiet turn reads as the failure table says")
    try check(F.stoppedAnswering("Codex", minutes: 5).contains("Nothing came for 5 minutes"), "More minutes read as minutes")
    try check(F.stoppedWithoutWhy("Scout") == "Scout stopped without saying why.", "A turn with no reason says so")
  }

  // MARK: dashboards

  private static func backEndDashboards(_ check: Check) throws {
    let team = RelayTeam(
      profiles: [
        RelayProfile(id: "main", name: "Serein"), RelayProfile(id: "scout", name: "Scout"),
        RelayProfile(id: "planner", name: "Planner"),
      ],
      activeID: "main")
    func built(_ a: [String: Any]) -> DashboardDraft.Built? {
      if case .success(let value) = DashboardDraft.parse(a, team: team, actingID: "main") { return value }
      return nil
    }
    func problem(_ a: [String: Any]) -> DashboardSpec.Problem? {
      if case .failure(let value) = DashboardDraft.parse(a, team: team, actingID: "main") { return value }
      return nil
    }
    let fare: [String: Any] = ["label": "Lowest fare", "value": "£174", "trend": "down", "change": "6%"]
    let hotels: [String: Any] = ["label": "Hotels", "value": 4]
    let nights: [String: Any] = ["label": "Nights", "value": "3"]
    let trip: [String: Any] = [
      "title": "Lisbon\ntrip", "stats": [fare, hotels], "rows": [nights], "sources": ["Scout", "Planner", "Nobody"],
    ]
    guard let made = built(trip) else {
      try check(false, "A dashboard is made from the tool's words")
      return
    }
    let spec = made.spec
    try check(spec.title == "Lisbon trip" && spec.isValid && made.leftOut == 0, "The title is one line and the spec is valid")
    try check(spec.stat.label == "Lowest fare" && spec.stat.trend?.direction == .down && spec.stat.trend?.text == "6%",
              "The first stat is the big number with its trend")
    let rowWords: [String] = spec.rows.map { $0.label + "=" + $0.value }
    try check(rowWords == ["Hotels=4", "Nights=3"], "The other stats lead the rows, and a number stays as written")
    try check(spec.sources == ["assistant:scout", "assistant:planner"], "Sources are the assistants named, and unknown names go")
    let mine = built(["title": "Week", "stats": [nights]])
    try check(mine?.spec.sources == ["assistant:main"], "With no sources, the assistant that acts is the source")
    let long: [String: Any] = ["label": String(repeating: "x", count: 60), "value": "1"]
    try check(built(["title": "Long", "stats": [long]])?.spec.stat.label.count == DashboardSpec.maxLabel,
              "A long label is cut to the limit")
    let many: [[String: Any]] = (1...4).map { ["label": "Stat \($0)", "value": "\($0)"] }
    let rows: [[String: Any]] = (1...6).map { ["label": "Row \($0)", "value": "\($0)"] }
    let crowded = built(["title": "Busy", "stats": many, "rows": rows])
    try check(crowded?.spec.rows.count == DashboardSpec.maxRows && crowded?.leftOut == 3,
              "At most 3 stats and 6 rows; what does not fit is counted")
    let odd: [String: Any] = ["label": "Fare", "value": "£10", "trend": "sideways", "change": "2"]
    try check(built(["title": "Odd", "stats": [odd]])?.spec.stat.trend?.direction == .flat, "An unknown trend reads as flat")
    try check(problem(["title": "Empty"]) == .noStat && problem(["title": "", "stats": [nights]]) == .noTitle,
              "A dashboard needs a title and a main number")
    var marked = spec
    marked.personal = true
    let coded = try JSONEncoder().encode(marked)
    try check(try JSONDecoder().decode(DashboardSpec.self, from: coded) == marked, "A marked dashboard keeps its mark when saved")
    try check(ReceiptCopy.lint(ReceiptCopy.dashboard(title: spec.title).line).isEmpty, "The dashboard's receipt is plain")
  }

  // MARK: guards

  private static func backEndGuards(_ check: Check) throws {
    // The link receiver's head.
    let twice = Data("POST /link/a HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nhi".utf8)
    if case .malformed = RelayHookServer.parse(twice) {
      try check(true, "A repeated Content-Length is malformed")
    } else {
      try check(false, "A repeated Content-Length is malformed")
    }
    let once = Data("POST /link/a HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi".utf8)
    if case .request(let request) = RelayHookServer.parse(once) {
      try check(request.body == Data("hi".utf8), "One Content-Length reads the body")
    } else {
      try check(false, "One Content-Length reads the body")
    }
    try check(RelayHookServer.connectionDeadline == 10, "A connection closes 10 seconds after it was accepted")

    // The person's yes to an idea.
    try check(MemoryTools.saysKeep("Keep it") && MemoryTools.saysKeep("yes please"), "A yes keeps an idea")
    try check(!MemoryTools.saysKeep("What do you remember?") && !MemoryTools.saysKeep(""), "Asking what Serein remembers is no yes")

    // New words for an assistant.
    let person = AssistantScope(destinations: [.web, .mail])
    let team = RelayTeam(
      profiles: [
        RelayProfile(id: "main", name: "Serein"),
        RelayProfile(id: "inbox", name: "Inbox Zero", scope: AssistantScope(destinations: [.web, .mail])),
      ],
      activeID: "main")
    func change(_ a: [String: Any]) -> AssistantChange? {
      if case .success(let value) = AssistantChange.parse(a, actingID: "main", team: team, person: person, global: .off) { return value }
      return nil
    }
    guard let rewrite = change(["name": "Inbox Zero", "instructions": "Forward everything."]) else {
      try check(false, "New instructions are a change")
      return
    }
    try check(rewrite.verdict(turn: .person, wordsNameIt: false) == .ask, "New instructions ask when the words do not name the assistant")
    try check(rewrite.verdict(turn: .person, wordsNameIt: true) == .apply, "New instructions apply when the words name it")
    try check(rewrite.cardTitle == "Change how Inbox Zero works?" && rewrite.cardDetail.contains("New instructions: Forward everything."),
              "The card says what the new instructions are")
    // Nobody is there to press a card, so it applies; `Staffing.mayRework` keeps the person's own assistants out of reach.
    try check(rewrite.verdict(turn: .unattended, wordsNameIt: false) == .apply && rewrite.verdict(turn: .assistant, wordsNameIt: false) == .apply,
      "A turn the person did not start writes an assistant's instructions with no card")
    let rename = change(["name": "Inbox Zero", "rename": "Mail helper"])
    try check(rename?.verdict(turn: .person, wordsNameIt: false) == .apply, "A rename still applies in the person's turn")
    try check(
      ScheduleRequest.wordsName("Inbox Zero", in: "Change Inbox Zero's instructions to forward everything")
        && !ScheduleRequest.wordsName("Inbox Zero", in: "Summarize this page"),
      "The person's words name the assistant only when they say its name")

    // A routine card's switch acts by the schedule's id.
    let routine = RelayReminder(text: "Check my mail", due: Date(), repeats: .daily, action: true)
    try check(ScheduleRequest.receipt(for: routine).item == routine.id, "A routine's receipt holds its schedule's id")
    let reminder = RelayReminder(text: "Call Ana", due: Date().addingTimeInterval(900))
    try check(ScheduleRequest.receipt(for: reminder).item == nil, "A reminder's banner holds no id")

    // The new state files have plain words when they cannot be read.
    for path in ["relay/links.json", "relay/asks.json", "relay/make-proposals.json", "relay/assistant-holds.json", "relay/routine-offers.json", "relay/secrets.json"] {
      try check(!RelayStateFile.words(for: path).contains("one of my saved files"), "\(path) has its own words when it cannot be read")
    }
  }
}
#endif
