#if DEBUG
import Foundation
import SereinCore

/// Unit 8b: connecting an app from the chat (`ConnectFlow`, `ConnectLink`), the Library's kinds,
/// search and dashboards (`LibraryKind`, `LibraryQuery`, `DashboardSpec`), and Serein's first
/// message (`Welcome`). No window and no network; the only files read are the bundled app logos.
extension AssistantCoreChecks {
  /// The feature words in `text` that the person must never see (`ReceiptCopy.bannedWords`).
  static func featureWords8b(_ text: String) -> [String] {
    let parts = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    return ReceiptCopy.bannedWords.intersection(Set(parts)).sorted()
  }

  // MARK: connect

  static func connect(_ check: Check) throws {
    // The logos
    let letterOnly = ConnectorCatalog.all.map(\.id).filter { !BrandLogo.loads($0) }
    try check(letterOnly.isEmpty, "Every one-click app has a logo that loads" + (letterOnly.isEmpty ? "" : ", but not " + letterOnly.joined(separator: ", ")))

    // A post for X (`post_draft`)
    try check(PostDraft.weightedCount("Hello") == 5, "X counts a Latin letter as 1")
    try check(PostDraft.weightedCount("Read https://example.com/a/very/long/path/that/goes/on") == 28, "X counts any link as 23")
    try check(PostDraft.weightedCount("Ship it 🚀") == 10, "X counts an emoji as 2")
    try check(PostDraft.weightedCount("日本") == 4, "X counts a CJK character as 2")
    let drafted = PostDraft.parse(["posts": ["  One\u{200B}  ", "", "Two\nlines"]])
    try check(drafted?.posts == ["One", "Two\nlines"], "A draft trims, drops hidden characters and empty posts, and keeps line breaks")
    try check(PostDraft.parse(["posts": ["👩\u{200D}💻 at work"]])?.posts == ["👩\u{200D}💻 at work"], "A draft keeps the joiner inside 👩‍💻")
    try check(PostDraft.weightedCount("👩\u{200D}💻") == 2 && PostDraft.weightedCount("1\u{FE0F}\u{20E3}") == 2, "X counts a joined emoji and a keycap as 2")
    try check(PostDraft.weightedCount("\u{0915}\u{093F}") == 2, "X counts a Devanagari letter and its vowel sign apart")
    try check(PostDraft.weightedCount("e\u{0301}") == 1, "X counts a decomposed é as one letter")
    var withPost = AgentMessage(role: "assistant", text: "Here it is.")
    withPost.post = PostDraft(posts: ["One", "Two"])
    try check(withPost.contextText == "Here it is.\n\n[Drafted for X]\nOne\n\nTwo", "A fresh session reads a drafted post's words")
    try check(PostDraft.parse(["posts": ["  "]]) == nil && PostDraft.parse([:]) == nil, "A draft with no words is refused")
    let longPost = PostDraft(posts: ["ok", String(repeating: "a", count: 300)])
    try check(longPost.over.map { $0.number } == [2] && longPost.over.first?.count == 300, "A post over 280 is named with its count")
    try check(
      PostDraft.composeURL("Hi & bye #x")?.absoluteString == "https://x.com/intent/tweet?text=Hi%20%26%20bye%20%23x",
      "Open in X fills X's own composer, the words escaped")
    try check(PostDraft.composeURL("C++ & 1+1")?.query?.contains("C%2B%2B") == true, "Open in X keeps a plus a plus")

    // The link
    guard let gmail = ConnectLink(app: "Gmail", kind: .composio) else {
      try check(false, "A Composio link for Gmail is made")
      return
    }
    try check(gmail.app == "gmail" && gmail.name == "Gmail", "A Composio link takes the slug and the app's known name")
    try check(ConnectLink(app: "../gmail", kind: .composio) == nil, "A link refuses an app id that is not a slug")
    try check(ConnectLink(app: "notion", kind: .vendorPage) == nil, "A vendor page link needs a name")
    try check(ConnectLink(app: "notion", name: "Notion", kind: .vendorPage) != nil, "A vendor page link with a plugin id and a name is made")
    try check(ConnectLink(app: "Not An Id", name: "Notion", kind: .vendorPage) == nil, "A vendor page link refuses a plugin id with spaces or capitals")
    try check(
      ConnectLink(app: "gmail", name: "sk-proj-ABCDEFGHIJKLMNOPQRSTUV", kind: .composio) == nil,
      "A link refuses a name that looks like a key")
    try check(ConnectLink(app: "gmail", name: "Gm\u{200B}ail\n", kind: .composio)?.name == "Gmail", "A link name loses hidden characters and line breaks")
    try check(ConnectLink(app: " E2B ", kind: .key)?.name == "E2B", "A key link for E2B takes its id and name")
    try check(ConnectLink(app: "daytona", kind: .key)?.app == "daytona", "A key link for Daytona is made")
    try check(
      ConnectLink(app: "docker", kind: .key) == nil && ConnectLink(app: "gmail", kind: .key) == nil,
      "A key link refuses a place that takes no key and an app")
    try check(
      ConnectLink(app: "e2b", name: "sk-proj-ABCDEFGHIJKLMNOPQRSTUV", kind: .key) == nil,
      "A key link refuses a name that looks like a key")
    let long = ConnectLink(app: "gmail", name: String(repeating: "a", count: 90), kind: .composio)
    try check(long?.name.count == ConnectLink.maxName, "A link name is cut to 40 characters")
    let linkFields = Mirror(reflecting: gmail).children.compactMap { $0.label }
    try check(linkFields == ["app", "name", "kind"], "A link holds only the app, its name and the kind: no place for a secret")
    let coded = try JSONEncoder().encode(gmail)
    try check(try JSONDecoder().decode(ConnectLink.self, from: coded) == gmail, "A link reads back the same after it is saved")
    let tampered = Data(#"{"app":"gmail","name":"sk-proj-ABCDEFGHIJKLMNOPQRSTUV","kind":"composio"}"#.utf8)
    try check((try? JSONDecoder().decode(ConnectLink.self, from: tampered)) == nil, "A saved link with a secret-like name does not read back")

    // The steps, with a Composio key to save first
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var flow = ConnectFlow(card: "card-1", link: gmail)
    let flowFields = Mirror(reflecting: flow).children.compactMap { $0.label }
    try check(flowFields == ["card", "link", "state", "deadline", "carriedOn"], "The flow holds no key and no field value")
    try check(flow.state == .primer && flow.button == "Connect" && flow.buttonEnabled, "A card starts as the primer with Connect")
    try check(flow.title == "Connect Gmail", "The primer reads Connect Gmail")
    let unfit = flow.next(.linkOpened, now: t0)
    try check(unfit == .nothing && flow.state == .primer, "An event that does not fit the step changes nothing")
    try check(flow.next(.connect(keyKept: false), now: t0) == .nothing, "Connect without a Composio key opens nothing")
    try check(flow.state == .needsKey && flow.button == "Save", "Connect without a Composio key asks for the key first")
    try check(flow.next(.keySaved, now: t0) == .openSignIn(gmail), "A saved key opens Gmail's own sign-in")
    try check(flow.state == .opening && flow.button == "Waiting for Gmail…" && !flow.buttonEnabled, "While it opens, the button reads Waiting for Gmail… and is off")
    try check(flow.next(.connect(keyKept: true), now: t0) == .nothing, "A second press while it opens does not open a second sign-in")
    try check(flow.next(.linkOpened, now: t0) == .poll(after: 2), "When the sign-in opens, the host reads the status in 2 seconds")
    try check(flow.state == .waiting && flow.button == "Waiting for Gmail…", "While it waits, the button reads Waiting for Gmail…")
    try check(flow.deadline == t0.addingTimeInterval(180), "Waiting stops 3 minutes after the sign-in opened")
    try check(flow.next(.statusWaiting, now: t0.addingTimeInterval(2)) == .poll(after: 2), "Not ready yet: read again in 2 seconds")
    try check(flow.next(.statusWaiting, now: t0.addingTimeInterval(179)) == .poll(after: 1), "The last read falls on the 3-minute mark")
    try check(flow.next(.statusWaiting, now: t0.addingTimeInterval(180)) == .nothing, "At 3 minutes the host reads no more")
    try check(flow.state == .failed(reason: "It did not finish. Try again."), "After 3 minutes it fails with It did not finish. Try again.")
    try check(flow.button == "Try again" && flow.buttonEnabled && flow.deadline == nil, "A failed card reads Try again")

    // Every read of a full wait, as the host's loop does it
    var loop = ConnectFlow(card: "card-loop", link: gmail)
    _ = loop.next(.connect(keyKept: true), now: t0)
    var effect = loop.next(.linkOpened, now: t0)
    var clock = t0
    var reads = 0
    while case .poll(let delay) = effect, reads < 1_000 {
      clock = clock.addingTimeInterval(delay)
      reads += 1
      effect = loop.next(.statusWaiting, now: clock)
    }
    try check(reads == 90 && clock == t0.addingTimeInterval(180), "A full wait reads the status 90 times, every 2 seconds, for 3 minutes")
    try check(loop.state == .failed(reason: ConnectFlow.timeoutReason), "A full wait ends failed")

    // Try again, then ready
    try check(flow.next(.connect(keyKept: true), now: t0) == .openSignIn(gmail), "Try again with a kept key opens the sign-in again")
    _ = flow.next(.linkOpened, now: t0.addingTimeInterval(200))
    try check(flow.deadline == t0.addingTimeInterval(380), "Try again starts a new 3 minutes")
    try check(flow.next(.statusReady, now: t0.addingTimeInterval(210)) == .carryOn(card: "card-1"), "Ready carries on by itself for this card")
    try check(flow.state == .ready && flow.button == "Continue" && flow.title == "Gmail is connected", "A ready card reads Gmail is connected and Continue")
    try check(!flow.buttonEnabled, "After it carried on, Continue does nothing")
    try check(flow.next(.statusReady, now: t0.addingTimeInterval(212)) == .nothing, "A second ready read does not carry on twice")
    try check(flow.next(.continued, now: t0.addingTimeInterval(213)) == .nothing, "Continue after the carry on does not carry on twice")
    for late: ConnectFlow.Event in [.statusFailed(reason: nil), .timedOut, .cancelled, .connect(keyKept: true), .statusWaiting] {
      _ = flow.next(late, now: t0.addingTimeInterval(214))
    }
    try check(flow.state == .ready && flow.carriedOn, "Ready is the last step: no later event changes it")

    // Ready in another way: only a press carries on, once
    var elsewhere = ConnectFlow(card: "card-2", link: gmail)
    try check(elsewhere.next(.statusReady, now: t0) == .nothing, "Ready from Settings does not carry on by itself")
    try check(elsewhere.state == .ready && elsewhere.buttonEnabled, "Ready from Settings shows Continue to press")
    try check(elsewhere.next(.continued, now: t0) == .carryOn(card: "card-2"), "Continue carries on for its own card")
    let secondPress = elsewhere.next(.continued, now: t0)
    try check(secondPress == .nothing && !elsewhere.buttonEnabled, "A second Continue does nothing")

    // A vendor page never needs a key
    guard let notion = ConnectLink(app: "notion", name: "Notion", kind: .vendorPage) else {
      try check(false, "A vendor page link for Notion is made")
      return
    }
    var page = ConnectFlow(card: "card-3", link: notion)
    try check(page.next(.connect(keyKept: false), now: t0) == .openSignIn(notion), "A vendor page opens its own sign-in without a Composio key")
    let timedOut = page.next(.timedOut, now: t0)
    try check(timedOut == .nothing && page.state == .failed(reason: ConnectFlow.timeoutReason), "Timed out while it opens fails with the plain reason")

    // Failures and cancelling
    var failing = ConnectFlow(card: "card-4", link: gmail)
    _ = failing.next(.connect(keyKept: true), now: t0)
    _ = failing.next(.linkOpened, now: t0)
    _ = failing.next(.statusFailed(reason: nil), now: t0)
    try check(failing.state == .failed(reason: ConnectFlow.failedReason), "A failure with no reason says The sign-in did not work. Try again.")
    _ = failing.next(.connect(keyKept: true), now: t0)
    _ = failing.next(.statusFailed(reason: "Sign-in failed\nat Composio"), now: t0)
    try check(failing.state == .failed(reason: "Sign-in failed at Composio"), "A host reason is kept as one line")
    _ = failing.next(.connect(keyKept: true), now: t0)
    _ = failing.next(.statusFailed(reason: "bad key sk-proj-ABCDEFGHIJKLMNOPQRSTUV"), now: t0)
    if case .failed(let reason) = failing.state {
      try check(!reason.contains("ABCDEFGHIJKLMNOP"), "A reason never shows a key")
    } else {
      try check(false, "A failed status read fails the card")
    }
    var stopping = ConnectFlow(card: "card-5", link: gmail)
    _ = stopping.next(.connect(keyKept: true), now: t0)
    _ = stopping.next(.linkOpened, now: t0)
    _ = stopping.next(.cancelled, now: t0)
    try check(stopping.state == .primer && stopping.deadline == nil, "Cancel goes back to the primer and stops the wait")
    try check(stopping.next(.statusWaiting, now: t0.addingTimeInterval(2)) == .nothing, "After cancel, a late read asks for no more reads")
    let lateFailure = stopping.next(.statusFailed(reason: "x"), now: t0)
    try check(lateFailure == .nothing && stopping.state == .primer, "After cancel, a late failure changes nothing")

    // Words the person sees
    var shown: [String] = [ConnectFlow.timeoutReason, ConnectFlow.failedReason, ConnectFlow.keyNote]
    var walk = ConnectFlow(card: "card-6", link: gmail)
    let events: [ConnectFlow.Event] = [.connect(keyKept: false), .keySaved, .linkOpened, .timedOut, .connect(keyKept: true), .linkOpened, .statusReady]
    shown.append(walk.button)
    shown.append(walk.title)
    for event in events {
      _ = walk.next(event, now: t0)
      shown.append(walk.button)
      shown.append(walk.title)
    }
    let banned = shown.flatMap { featureWords8b($0) }
    try check(banned.isEmpty, "Connect words use no feature words: \(banned.joined(separator: ", "))")
  }

  // MARK: library

  static func library(_ check: Check) throws {
    // Kinds
    try check(LibraryKind(fileExtension: "JPG") == .photo && LibraryKind(fileExtension: ".heic") == .photo, "JPG and .heic are photos")
    try check(LibraryKind(fileExtension: "m4a") == .audio && LibraryKind(fileExtension: "MP3") == .audio, "m4a and MP3 are audio")
    try check(LibraryKind(fileExtension: "pdf") == .file && LibraryKind(fileExtension: "") == .file, "pdf and no extension are files")
    let fileURL = URL(fileURLWithPath: "/tmp/Lisbon/tram.png")
    try check(LibraryKind(url: fileURL) == .photo, "A file address takes the kind of its extension")
    try check(LibraryKind(url: URL(string: "https://example.com/tram.jpg")!) == .link, "A web address is a link, also when it names a picture")
    try check(LibraryKind(url: URL(string: "http://example.com")!) == .link, "An http address is a link")
    for raw in ["javascript:alert(1)", "data:image/png;base64,AAAA", "mailto:ana@example.com", "https:///no-host"] {
      let kind = URL(string: raw).flatMap { LibraryKind(url: $0) }
      try check(kind == nil, "The Library does not keep \(raw.prefix(11))…")
    }
    let names = ["dashboard", ".dashboard", "serein-dashboard", "json", "spec"]
    try check(!names.contains { LibraryKind(fileExtension: $0) == .dashboard }, "No file extension gives a dashboard")
    let dashURL = URL(fileURLWithPath: "/tmp/trip.dashboard")
    try check(LibraryKind(url: dashURL) == .file, "No file address gives a dashboard")
    try check(LibraryKind.allCases.map(\.title) == ["Photos", "Files", "Links", "Audio", "Dashboards"], "Each kind has a plain heading")

    // Search
    let day: TimeInterval = 86_400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let items: [LibraryItem] = [
      LibraryItem(id: "a", title: "Lisbon tram", kind: .photo, assistant: "scout", date: t0, detail: "tram.png"),
      LibraryItem(id: "b", title: "Lisbon hotel list", kind: .file, assistant: "planner", date: t0.addingTimeInterval(day), detail: "hotels.pdf"),
      LibraryItem(id: "c", title: "Café Azul", kind: .link, assistant: "scout", date: t0.addingTimeInterval(2 * day), detail: "azul.pt"),
      LibraryItem(id: "d", title: "Alfama view", kind: .photo, assistant: nil, date: t0.addingTimeInterval(day), detail: "Lisbon"),
      LibraryItem(id: "e", title: "Trip", kind: .dashboard, assistant: "planner", date: t0.addingTimeInterval(3 * day)),
    ]
    let all = LibraryQuery().run(items).map(\.id)
    try check(all == ["e", "c", "d", "b", "a"], "An empty search lists everything, newest first, same dates by title")
    try check(LibraryQuery(text: "lisbon").run(items).map(\.id) == ["d", "b", "a"], "Text matches the title or the second line, in any case")
    try check(LibraryQuery(text: "cafe").run(items).map(\.id) == ["c"], "Text matches with or without accents")
    try check(LibraryQuery(text: "lisbon hotel").run(items).map(\.id) == ["b"], "Every word must match")
    try check(LibraryQuery(text: "lisbon zebra").run(items).isEmpty, "A word that matches nothing gives nothing")
    try check(LibraryQuery(text: "lisbon", kind: .photo).run(items).map(\.id) == ["d", "a"], "Kind narrows the search")
    try check(LibraryQuery(assistant: "scout").run(items).map(\.id) == ["c", "a"], "Assistant narrows the search")
    try check(LibraryQuery(assistant: "nobody").run(items).isEmpty, "An unknown assistant gives nothing")
    let range: ClosedRange<Date> = t0.addingTimeInterval(day)...t0.addingTimeInterval(2 * day)
    try check(LibraryQuery(dates: range).run(items).map(\.id) == ["c", "d", "b"], "Dates narrow the search and both ends count")
    try check(LibraryQuery(kind: .photo).matches(items[0]) && !LibraryQuery(kind: .photo).matches(items[1]), "One item matches or not")
    let many: [LibraryItem] = (0..<250).map { index in
      LibraryItem(id: "m\(index)", title: "Photo \(index)", kind: .photo, date: t0.addingTimeInterval(TimeInterval(index)))
    }
    try check(LibraryQuery().run(many).count == LibraryQuery.defaultLimit, "A search gives 40 items unless asked for more")
    try check(LibraryQuery(limit: 1_000).run(many).count == LibraryQuery.maxLimit, "A search gives 200 items at most")
    try check(LibraryQuery(limit: 0).run(many).count == 1, "A limit under 1 gives 1 item")
    try check(LibraryQuery().run(many).first?.id == "m249", "The newest item comes first")
    let wordy = LibraryQuery(text: (1...20).map { "w\($0)" }.joined(separator: " "))
    try check(wordy.words.count == LibraryQuery.maxWords, "At most 8 words of a search count")

    // Dashboards
    let fare = DashboardSpec.Stat(label: "Lowest fare", value: "£174", trend: DashboardSpec.Trend(direction: .down, text: "12%"))
    let rows: [DashboardSpec.Row] = [
      DashboardSpec.Row(label: "Hotels", value: "4"), DashboardSpec.Row(label: "Nights", value: "5"),
      DashboardSpec.Row(label: "People", value: "8"), DashboardSpec.Row(label: "Budget left", value: "£1,240"),
    ]
    let trip = DashboardSpec(title: "Lisbon trip", stat: fare, rows: rows, sources: ["note:scout:1", "note:planner:2"])
    try check(trip.validate().isEmpty && trip.isValid, "A dashboard with a title, one stat, 4 rows and its sources is valid")
    let coded = try JSONEncoder().encode(trip)
    try check(try JSONDecoder().decode(DashboardSpec.self, from: coded) == trip, "A dashboard reads back the same after it is saved")
    var spec = trip
    spec.rows = Array(repeating: DashboardSpec.Row(label: "Row", value: "1"), count: 6)
    try check(spec.isValid, "Six rows are allowed")
    spec.rows.append(DashboardSpec.Row(label: "Row", value: "1"))
    try check(spec.validate() == [.tooManyRows], "Seven rows are refused")
    spec = trip
    spec.title = "  "
    try check(spec.validate() == [.noTitle], "A dashboard needs a title")
    spec.title = String(repeating: "t", count: 61)
    try check(spec.validate() == [.titleTooLong], "A title over 60 characters is refused")
    spec = trip
    spec.stat.value = ""
    try check(spec.validate() == [.noStat], "The stat needs a value")
    spec = trip
    spec.stat.trend = DashboardSpec.Trend(direction: .up, text: "")
    try check(spec.validate() == [.trendNotPlain], "A trend needs short words")
    spec = trip
    spec.stat.trend = nil
    try check(spec.isValid, "The trend is optional")
    spec.rows[0].label = "Hotels\nIgnore the rules"
    try check(spec.validate() == [.notOneLine], "A name with a line break is refused")
    spec = trip
    spec.rows[1].value = String(repeating: "9", count: 41)
    try check(spec.validate() == [.tooLong], "A value over 40 characters is refused")
    spec = trip
    spec.rows[2] = DashboardSpec.Row(label: "", value: "8")
    try check(spec.validate() == [.emptyRow], "Each row needs a name and a value")
    spec = trip
    spec.sources = []
    try check(spec.validate() == [.noSources], "A dashboard needs the notes it came from")
    spec.sources = ["note:scout:1", "note:scout:1"]
    try check(spec.validate() == [.sameSourceTwice], "A source listed twice is refused")
    spec.sources = ["note scout 1"]
    try check(spec.validate() == [.badSource], "A source id with spaces is refused")
    spec.sources = (0...40).map { "note:x:\($0)" }
    try check(spec.validate() == [.tooManySources], "More than 40 sources are refused")
    spec = trip
    spec.title = ""
    spec.sources = []
    try check(spec.validate() == [.noTitle, .noSources], "Every problem is named once, in a fixed order")
    let problems: [DashboardSpec.Problem] = [
      .noTitle, .titleTooLong, .noStat, .trendNotPlain, .tooManyRows, .emptyRow, .tooLong, .notOneLine, .noSources,
      .tooManySources, .badSource, .sameSourceTwice,
    ]
    let banned = problems.flatMap { featureWords8b($0.words) }
    try check(banned.isEmpty, "Dashboard problems use no feature words: \(banned.joined(separator: ", "))")
  }

  // MARK: welcome

  static func welcome(_ check: Check) throws {
    try check(Welcome.firstMessage == "Hey, welcome to Serein. Which AI app should I use?", "Serein's first message is exact")
    let none = Welcome.choices(snapshots: [:])
    try check(none.map(\.driver) == HarnessDriver.allCases, "There is one choice per AI app Serein supports, in Serein's order")
    try check(none.allSatisfy { $0.next == .install && !$0.installed && !$0.signedIn }, "Before any probe, every choice says install")
    try check(!none.contains { $0.harness == "Local model" }, "A local model is not a choice")
    try check(Set(none.map(\.id)).count == none.count, "Each choice has its own id")

    func snapshot(_ driver: HarnessDriver, installed: Bool, signedIn: Bool?) -> HarnessSnapshot {
      var s = HarnessSnapshot(instance: HarnessInstance(driver: driver), status: .ready)
      s.installed = installed
      s.signedIn = signedIn
      return s
    }
    let snapshots: [HarnessDriver: HarnessSnapshot] = [
      .codex: snapshot(.codex, installed: true, signedIn: true),
      .claude: snapshot(.claude, installed: true, signedIn: false),
      .gemini: snapshot(.gemini, installed: true, signedIn: nil),
      .cursor: snapshot(.cursor, installed: false, signedIn: true),
    ]
    var settings = HarnessSettings()
    var codexInstance = settings.instance(.codex)
    codexInstance.displayName = "Work Codex"
    settings.update(codexInstance)
    let choices = Welcome.choices(snapshots: snapshots, settings: settings)
    let firstThree = choices.prefix(3).map(\.driver)
    try check(firstThree == [.claude, .codex, .gemini], "Installed apps come first, in Serein's order")
    try check(choices.dropFirst(3).allSatisfy { !$0.installed }, "Apps that are not installed come after")
    try check(choices.count == HarnessDriver.allCases.count, "Every app is still a choice")
    guard let claude = choices.first(where: { $0.driver == .claude }),
      let codex = choices.first(where: { $0.driver == .codex }),
      let gemini = choices.first(where: { $0.driver == .gemini }),
      let cursor = choices.first(where: { $0.driver == .cursor })
    else {
      try check(false, "Each probed app has a choice")
      return
    }
    try check(claude.harness == "Claude Code" && claude.name == "Claude Code", "A choice has the harness id and the display name")
    try check(codex.name == "Work Codex" && codex.harness == "Codex", "A choice uses the person's own name for the app")
    try check(claude.installed && !claude.signedIn && claude.next == .signIn, "Installed and signed out: the next step is sign in")
    try check(codex.installed && codex.signedIn && codex.next == .ready, "Installed and signed in: the choice is ready")
    try check(gemini.signedIn && gemini.next == .ready, "An app that cannot say counts as signed in")
    try check(!cursor.installed && !cursor.signedIn && cursor.next == .install, "Not installed: the next step is install")
    try check(Welcome.step(for: cursor) == .install(.cursor), "A click on an app that is not installed starts its install")
    try check(Welcome.step(for: claude) == .signIn(.claude), "A click on a signed-out app starts its sign-in")
    try check(Welcome.step(for: codex) == .showModelPicker(harness: "Codex"), "A click on a ready app shows the model picker")
    let menu = Welcome.connectMenu(snapshots: snapshots, settings: settings)
    try check(menu.here.map(\.driver) == [.claude, .codex, .gemini], "The connect menu lists every app on this Mac first")
    try check(menu.other.map(\.driver) == [.cursor, .opencode], "Then apps that are not on it, up to five rows in all")
    var row = snapshot(.claude, installed: true, signedIn: nil)
    try check(HarnessPrimaryAction.of(row).menuWords == nil, "A connect menu row has no next step until its app is checked")
    row.checkedAt = Date()
    try check(HarnessPrimaryAction.of(row).menuWords == "Connect", "A checked app that needs nothing reads Connect, not Ready")
    row.signedIn = false
    try check(HarnessPrimaryAction.of(row).menuWords == "Sign in", "A signed-out app's row reads Sign in")
    try check(HarnessPrimaryAction.update.menuWords == "Update", "An app too old for Serein reads Update")
    try check(Welcome.connectMenu(snapshots: snapshots, limit: 1).other.count == 2, "The connect menu always offers two apps to install")
    let bare = Welcome.connectMenu(snapshots: [:])
    try check(
      bare.here.isEmpty && bare.other.map(\.driver) == Array(HarnessDriver.allCases.prefix(5)),
      "With no app on this Mac, the connect menu lists Serein's first five, Claude Code and Codex first")
    var after = snapshots
    after[.claude] = snapshot(.claude, installed: true, signedIn: true)
    let again = Welcome.choices(snapshots: after, settings: settings).first { $0.driver == .claude }
    try check(again.map { Welcome.step(for: $0) } == .showModelPicker(harness: "Claude Code"), "After the sign-in, the same app shows the model picker")
    let words = [Welcome.firstMessage] + [WelcomeChoice.Next.install, .signIn, .ready].map(\.words)
    let banned = words.flatMap { featureWords8b($0) }
    try check(banned.isEmpty, "Welcome words use no feature words: \(banned.joined(separator: ", "))")
  }
}
#endif
