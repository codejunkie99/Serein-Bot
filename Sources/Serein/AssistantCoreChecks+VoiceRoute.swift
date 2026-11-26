#if DEBUG
import Foundation
import SereinCore

/// Where spoken words go (`VoiceRoute`) and which keys may call Serein alone (`RelayHotKey`).
/// Pure rules: no microphone, no keyboard.
extension AssistantCoreChecks {
  static func voiceRoute(_ check: Check) throws {
    func team(active: String) -> RelayTeam {
      RelayTeam(
        profiles: [
          RelayProfile(id: "main", name: "Serein"),
          RelayProfile(
            id: "scout", name: "Scout",
            scope: AssistantScope(destinations: [.web], instructions: "Who you are: It finds flights and hotels for trips.")),
          RelayProfile(
            id: "inbox", name: "Inbox Zero",
            scope: AssistantScope(destinations: [.web, .mail], instructions: "Who you are: It sorts your mail and drafts replies.")),
        ],
        activeID: active, groups: [AssistantGroup(id: "trip", name: "Trip", memberIDs: ["scout", "inbox"], leadID: "scout")])
    }
    func plan(
      _ words: String, active: String = "main", front: Bool = false, showing: Bool = false, running: Bool = false,
      busy: Set<String> = []
    ) -> VoiceRoute {
      VoiceRoute.plan(
        words, team: team(active: active), chatInFront: front, showing: showing, running: running, busy: busy)
    }

    // A name at the start, with no "@" and no comma, as dictation hears it.
    var route = plan("Scout find fares to Lisbon")
    try check(route.message == "@Scout, find fares to Lisbon" && route.words == "find fares to Lisbon" && route.to == "Scout" && route.reason == .named,
      "Words that open with an assistant's name go to it, without the name")
    try check(plan("hey Scout, find fares").message == "@Scout, find fares", "A greeting before the name is left out")
    try check(plan("Ask Scout to find fares", active: "inbox").message == "@Scout, find fares", "“Ask Scout to …” sends the request alone")
    try check(plan("tell the Trip team that dinner moved").message == "@Trip team, dinner moved", "A team is named as “the Trip team”")
    try check(plan("inbox zero clear my mail").message == "@Inbox Zero, clear my mail", "A name of two words is found in any case")
    try check(plan("Scout").message == "@Scout" && plan("Scout").words.isEmpty, "A name alone opens that chat and sends nothing")
    try check(TeamMention.parse(route.message, in: team(active: "main"))?.rest == route.words,
      "The routed message is a mention the chat already understands")
    // One name that opens another: the comma keeps the mention on the assistant that was named.
    let pair = RelayTeam(
      profiles: [
        RelayProfile(id: "main", name: "Serein"), RelayProfile(id: "scout", name: "Scout"),
        RelayProfile(id: "research", name: "Scout Research"),
      ], activeID: "main")
    for words in ["Scout, research fares", "ask Scout to research fares"] {
      let clash = VoiceRoute.plan(words, team: pair, chatInFront: false, showing: false, running: false, busy: [])
      let parsed = TeamMention.parse(clash.message, in: pair)
      try check(clash.to == "Scout" && parsed?.mention == .assistant("scout") && parsed?.rest == "research fares",
        "“\(words)” reaches Scout, not Scout Research")
    }

    // Words that only look like a name.
    try check(plan("Scout's report was wrong").to == nil && plan("Scoutmaster notes please").to == nil,
      "A possessive or a longer word names nobody")
    try check(plan("ask the team to plan dinner", front: true).reason == .stays && plan("tell me a joke", active: "scout", front: true).message == "tell me a joke",
      "“Ask” and “tell” without a roster name change nothing")

    // A new assistant goes to the main assistant, which has the tool that makes one.
    route = plan("make me an assistant for my inbox", active: "scout")
    try check(route.reason == .newAssistant && route.message == "@Serein, make me an assistant for my inbox" && route.to == "Serein",
      "A request for a new assistant goes to the main assistant with every word")
    try check(plan("can you create an agent called Budget", active: "scout", front: true).reason == .newAssistant
      && plan("new assistant for taxes").reason == .newAssistant && plan("I need a new assistant that tracks fares").message == "I need a new assistant that tracks fares",
      "It is recognised with a chat in front too, and stays as said when the main assistant is in front")
    try check(plan("a bot keeps emailing me, block it", active: "scout").reason != .newAssistant, "A bot that is only mentioned is not a request for one")

    // Only the task is said: it goes to the assistant whose job it clearly is.
    route = plan("check my email for invoices")
    try check(route.reason == .fits && route.to == "Inbox Zero" && route.message == "@Inbox Zero, check my email for invoices",
      "A task about mail reaches the assistant whose job is mail, with every word and no name said")
    try check(plan("find me a cheap flight to Lisbon next week", active: "inbox", front: true).to == "Scout",
      "A task that fits another assistant reaches it with a chat in front too")
    route = plan("draft a reply to Ana's email about the flight")
    try check(route.to == "Inbox Zero" && route.reason == .fits, "When two assistants fit, the clearly better one takes the task")
    route = plan("unsubscribe me from these newsletters", active: "inbox")
    try check(route.reason == .fits && route.message == "unsubscribe me from these newsletters" && route.to == "Inbox Zero",
      "A task for the assistant already in front goes as it is")
    try check(VoiceRoute.fit("what's the weather tomorrow", team: team(active: "main")) == nil
      && VoiceRoute.fit("summarize this", team: team(active: "main")) == nil && VoiceRoute.fit("tell me a joke", team: team(active: "main")) == nil,
      "A task that is nobody's job is left for the main assistant")
    try check(["find the bug in this function", "find my phone", "sort these files by date"].allSatisfy { VoiceRoute.fit($0, team: team(active: "main")) == nil },
      "One plain word shared with an assistant's job is not a fit")
    var paused = team(active: "main")
    paused.profiles[2].paused = true
    try check(VoiceRoute.fit("check my email for invoices", team: paused) == nil, "A paused assistant takes no task")
    try check(VoiceRoute.terms("Checking my emails and meetings") == ["check", "mail", "calendar"], "Words are read by the kind of work they mean")
    try check(VoiceRoute.terms("shopping, a meeting, the news and my writing") == ["shopping", "calendar", "news", "writing"],
      "A word that names its kind of work is read before its ending is cut")
    let shopper = RelayTeam(
      profiles: [
        RelayProfile(id: "main", name: "Serein"),
        RelayProfile(id: "pantry", name: "Pantry", scope: AssistantScope(destinations: [.web], instructions: "Who you are: It does the shopping.")),
      ], activeID: "main")
    try check(VoiceRoute.fit("buy groceries", team: shopper)?.id == "pantry", "“Buy groceries” reaches the assistant whose job is shopping")

    // Nobody named.
    route = plan("what is on my calendar", active: "scout")
    try check(route.reason == .main && route.message == "@Serein, what is on my calendar" && route.to == "Serein",
      "From another app, unaddressed words go to the main assistant, which decides who does it")
    route = plan("what is on my calendar", active: "scout", front: true)
    try check(route.reason == .stays && route.message == "what is on my calendar" && route.to == nil,
      "With a chat in front, unaddressed words stay with the assistant on screen")
    try check(plan("what is on my calendar").message == "what is on my calendar" && plan("what is on my calendar").to == nil,
      "With the main assistant in front, nothing is added")
    try check(plan("@Scout hi").message == "@Scout hi" && plan("  ").message.isEmpty, "A typed mention and silence pass through")
    route = plan("Stop everything.", active: "scout")
    try check(plan("stop", active: "scout").message == "stop" && route.to == nil && route.stop
        && plan("Cancel that.", showing: true, running: true).stop && !plan("Cancel that.", showing: true).stop,
      "A spoken stop that names nobody is never routed, and its route says it is a stop")
    func stops(_ words: String, shown: Bool = true, running: Bool = false) -> Bool {
      RelayStop.stops(words, overShown: shown, running: running)
    }
    try check(stops("stop") && stops("Stop it.") && stops("cancel all") && stops("cancel this", shown: false)
        && stops("Cancel that.", running: true) && !stops("cancel this") && !stops("Cancel that.") && !stops("stop the server"),
      "Over something shown, only “cancel this” and “cancel that” are about it, and only while nothing of Serein's runs")
    // By name, a stop reaches Scout only while a run is in Scout's own chat (`busy`).
    route = plan("Scout, stop.", active: "inbox", showing: true, busy: ["scout"])
    let told = plan("tell Scout to cancel that", showing: true, busy: ["scout"])
    let reaches = route.message == "@Scout, stop" && route.words == "stop" && route.to == "Scout" && route.reason == .named
      && route.stop && route.targetProfileID == "scout" && told.message == "@Scout, cancel that" && told.stop
    func bare(_ route: VoiceRoute, _ words: String = "stop") -> Bool { route.message == words && route.to == nil && route.stop }
    let idle = plan("Scout, stop.", active: "inbox", showing: true, running: true)
    let idleTargeted = idle.message == "@Scout, stop" && idle.stop && idle.targetProfileID == "scout"
    let inFront = bare(plan("Scout, stop.", active: "scout", showing: true, running: true, busy: ["scout"]))
    let toTeam = bare(plan("tell the Trip team to stop", busy: ["scout", "inbox"]))
    let everything = bare(plan("tell Scout to stop everything", busy: ["scout"]), "stop everything")
    try check(reaches && idleTargeted && inFront && toTeam && everything,
      "A named stop keeps its assistant target even while that assistant is idle; stops to the chat in front, a team and “stop everything” stay bare [busy target: \(reaches), idle target: \(idleTargeted), in front: \(inFront), team: \(toTeam), everything: \(everything)]")
    route = plan("Scout, cancel this", showing: true, running: true)
    let busyScout = plan("Scout, stop the server", busy: ["scout"])
    try check(route.message == "@Scout, cancel this" && !route.stop && busyScout.to == "Scout" && !busyScout.stop,
      "A request to an assistant that only sounds like a stop still goes to it, whatever the assistant in front is doing")
    try check(plan("Scout\nfind   fares").message == "@Scout, find fares", "Line breaks and runs of spaces become one space")

    try voiceRouteShown(check)

    // A function key calls Serein alone; any other key needs a modifier.
    try check(RelayHotKey.parse("f5") != nil && RelayHotKey.parse("F13")?.keyCode == 105 && RelayHotKey.symbols("f5") == "F5",
      "A function key is a shortcut alone")
    try check(RelayHotKey.parse("space") == nil && RelayHotKey.parse("a") == nil && RelayHotKey.parse("shift+a") == nil && RelayHotKey.parse("f21") == nil,
      "A key that types, alone or with Shift, is not a shortcut")
    try check(RelayHotKey.parse("opt+space")?.keyCode == 49 && RelayHotKey.parse("ctrl+f5") != nil, "A modifier and a key still parse")
  }

  /// What the pointer did during a hold (`PointerGesture`) and what rides with the words
  /// (`ScreenContext`).
  private static func voiceRouteShown(_ check: Check) throws {
    typealias G = PointerGesture
    func trail(_ points: [(Double, Double)]) -> [G.Sample] {
      points.enumerated().map { G.Sample(x: $0.element.0, y: $0.element.1, t: Double($0.offset) * 0.04) }
    }
    let circle: [(Double, Double)] = (0..<22).map { index in
      let angle = Double(index) / 20.0 * 2.0 * Double.pi
      return (500.0 + 80.0 * cos(angle), 300.0 + 50.0 * sin(angle))
    }
    guard case .circled(let round) = G.classify(trail(circle)) else { return try check(false, "A loop round something is a circle") }
    try check(abs(round.width - 160) < 2 && abs(round.height - 100) < 2, "A circle covers what it went round")
    guard case .underlined(let line) = G.classify(trail((0..<20).map { (300 + Double($0) * 12, 400) })) else {
      return try check(false, "A stroke along a line underlines it")
    }
    try check(line.minY < 400 && line.width > 200, "An underline reaches up to the text above it")
    try check(G.classify(trail(Array(repeating: (700.0, 500.0), count: 30))) == .rested(x: 700, y: 500), "A pointer that stays put rests on one thing")
    let approach: [(Double, Double)] = (0..<15).map { index in
      let offset = Double(index)
      return (100.0 + offset * 30.0, 200.0 + offset * 2.0)
    }
    let moved: [(Double, Double)] = approach + Array(repeating: (520.0, 228.0), count: 15)
    try check(G.classify(trail(moved)) == .rested(x: 520, y: 228), "A pointer that moves to something and stops points at it, and underlines nothing")
    let tiny: [(Double, Double)] = (0..<12).map { index in
      let angle = Double(index) / 10.0 * 2.0 * Double.pi
      return (500.0 + 8.0 * cos(angle), 300.0 + 8.0 * sin(angle))
    }
    if case .circled = G.classify(trail(tiny)) { try check(false, "A wobble is not a circle") }
    try check(G.classify([]) == .none, "No reading is no gesture")
    let probes = round.probes()
    let centered = probes.first.map { abs($0.x - round.midX) < 1.0 } ?? false
    try check(probes.count == 9 && centered, "A region is read from its middle outwards")

    let shown = ScreenContext(
      app: "Pages", window: "Budget 2026", selection: "Q3 spend\u{0}48,000\nsk-" + String(repeating: "a", count: 40),
      gesture: .circled(round),
      items: [.init(kind: "text", text: "Marketing  48,000"), .init(kind: "text", text: "Marketing 48,000"), .init(kind: "button", text: "")])
    try check(shown.title == "Pages · Budget 2026" && shown.items.count == 1 && shown.items[0].text == "Marketing 48,000",
      "What was shown is named by its app and window, each thing once, without empty ones")
    try check(!(shown.selection ?? "").contains(String(repeating: "a", count: 40)), "A key in the selected text does not ride along")
    try check(shown.body.contains("The pointer circled this") && shown.summary == "selected text, what you circled", "The words say what the pointer did")
    try check(ScreenContext(app: "Finder").isEmpty && !ScreenContext(app: "Finder", files: ["Chart.png"]).isEmpty,
      "An app's name alone is not worth sending; a file under the pointer is")
    let missed = ScreenContext(app: "Safari", missedPicture: true)
    try check(missed.missedPicture && !ScreenContext(app: "Safari", hasPicture: true, missedPicture: true).missedPicture,
      "A picture in the window's picture was not missed")
    try check(ScreenContext(app: "Finder", files: ["Notes.pdf"], missedPicture: true).missedPicture,
      "Another file that rides along does not stand for a picture that was missed")
    try check(ScreenContext.kind(role: "AXButton") == "button" && ScreenContext.kind(role: "AXWhatever") == "item", "A control is named in plain words")
    try check(ScreenContext.namesFiles(bundleID: "com.apple.finder") && !ScreenContext.namesFiles(bundleID: "com.apple.Safari") && !ScreenContext.namesFiles(bundleID: nil),
      "Only a Finder or Desktop item under the pointer stands for a file, never a link another app shows")

    let waiting = FileManager.default.temporaryDirectory.appendingPathComponent("serein-check-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: waiting) }
    try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
    let drawn = waiting.appendingPathComponent("window.jpg"), pasted = waiting.appendingPathComponent("picture.png")
    let dragged = waiting.appendingPathComponent("photo.JPEG")
    try Data([0xFF, 0xD8]).write(to: drawn)
    try Data([0x89, 0x50]).write(to: pasted)
    try Data([0xFF, 0xD8]).write(to: dragged)
    var turn = PageContext.Turn(pictures: [
      .init(path: drawn.path, name: "window.jpg"), .init(path: pasted.path, name: "picture.png"),
      .init(path: dragged.path, name: "photo.JPEG"),
    ])
    _ = try TurnAttachments.stage(&turn, root: waiting)
    try check(turn.pictures.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["picture-1.jpg", "picture-2.png", "picture-3.jpg"],
      "A picture staged for a turn keeps the ending its bytes have")

    let start = Date(timeIntervalSince1970: 1_793_268_000)
    var trail = ScreenTrail()
    func front(_ seconds: TimeInterval, _ app: String, _ window: String? = nil, id: String? = nil, serein: Bool = false, web: Bool = false) {
      trail.note(app: app, bundleID: id, window: window, isSerein: serein, opensWebPages: web, at: start.addingTimeInterval(seconds))
    }
    front(0, "Pages", "Budget 2026")
    front(3, "Pages", "Budget 2026")
    front(6, "Pages")
    try check(trail.stops.count == 1 && trail.stops[0].window == "Budget 2026", "A window that stays in front is one stop, with its title unread or not")
    front(9, "Safari", "My bank, private window", web: true)
    front(12, "1Password", "Vault", id: "com.1password.1password")
    front(15, "Serein", "Chat", serein: true)
    try check(trail.stops.map(\.app) == ["Pages", "Safari"] && trail.stops[1].window == nil,
      "A browser keeps its name alone; a password manager and Serein itself are not kept")
    for step in 0..<6 { front(20 + Double(step), "Terminal", "build \(step)") }
    try check(trail.stops.map(\.app) == ["Pages", "Safari", "Terminal", "Terminal", "Terminal"] && trail.stops.last?.window == "build 5",
      "A window whose name keeps changing keeps its last three and crowds no other app out")
    front(30, "Notes", "sk-" + String(repeating: "a", count: 40))
    let listed = (trail.body(now: start.addingTimeInterval(95)) ?? "").split(separator: "\n").map(String.init)
    try check(listed.dropFirst().prefix(2) == ["- Pages: Budget 2026 (1 min ago)", "- Safari (1 min ago)"]
      && !listed.joined().contains(String(repeating: "a", count: 40)) && !listed.joined().contains("private window"),
      "The trail lists where the person was, oldest first, with no page's name and no key in a window's name")
    front(700, "Mail", "Inbox")
    try check(trail.stops.map(\.app) == ["Mail"] && ScreenTrail().body(now: start) == nil,
      "After ten minutes a stop is forgotten, and an empty trail says nothing")
    func plain(_ trail: inout ScreenTrail, _ seconds: TimeInterval, _ app: String, _ window: String? = nil, id: String? = nil) {
      trail.note(app: app, bundleID: id, window: window, isSerein: false, opensWebPages: false, at: start.addingTimeInterval(seconds))
    }
    var unread = ScreenTrail()
    plain(&unread, 0, "Pages", "Budget 2026")
    for seconds in [3.0, 300, 590] { plain(&unread, seconds, "Pages") }
    try check(unread.stops.count == 1 && unread.stops[0].window == "Budget 2026" && unread.stops[0].seen == start,
      "A title that was not read again adds no stop and is seen no later than when it was read")
    plain(&unread, 601, "Pages")
    let afterTen = unread.body(now: start.addingTimeInterval(601)) ?? ""
    try check(unread.stops.count == 1 && unread.stops[0].window == nil && afterTen.hasSuffix("- Pages (just now)") && !afterTen.contains("Budget 2026"),
      "A title last read over ten minutes ago is gone, with its app still in front")
    var aged = ScreenTrail()
    plain(&aged, 0, "Pages", "Budget 2026")
    plain(&aged, 400, "Mail", "Inbox")
    let agedLines = (aged.body(now: start.addingTimeInterval(650)) ?? "").split(separator: "\n").dropFirst().map(String.init)
    try check(aged.stops.count == 2 && agedLines == ["- Mail: Inbox (4 min ago)"] && aged.body(now: start.addingTimeInterval(1001)) == nil,
      "A stop over ten minutes old is left out of what is sent, though nothing was noted since")
    var many = ScreenTrail()
    for step in 0..<15 { plain(&many, Double(step), "App \(step)") }
    try check(many.stops.count == ScreenTrail.limit && many.stops.first?.app == "App 3" && many.stops.last?.app == "App 14",
      "The trail keeps its newest twelve stops")
    var secret = ScreenTrail()
    plain(&secret, 0, "1Password", "Vault")
    plain(&secret, 1, "Helper", "Vault", id: "com.1password.1password")
    plain(&secret, 2, "KeePassXC", "Passwords.kdbx", id: "org.example.build")
    try check(secret.stops.isEmpty, "A password manager is left out by its name alone and by its identifier alone")
    let browsers: Set<String> = ["/Applications/Safari.app", "/Applications/Google Chrome.app"]
    func opensWeb(_ id: String, _ path: String?, handlers: Set<String>? = nil) -> Bool {
      ScreenTrail.opensWebPages(bundleID: id, path: path, handlers: handlers ?? browsers) {
        ["com.google.Chrome": ["/Applications/Google Chrome.app"], "com.apple.iWork.Pages": ["/Applications/Pages.app"]][$0] ?? []
      }
    }
    try check(opensWeb("com.apple.Safari", "/Applications/Safari.app")
      && opensWeb("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", "/Users/me/Applications/Chrome Apps.localized/Mail.app"),
      "An app macOS offers for a web link shows web pages, and so does a web app one of them installed")
    try check(!opensWeb("com.apple.iWork.Pages", "/Applications/Pages.app") && !opensWeb("com.example.Notes", nil),
      "An app macOS does not offer for a web link, and that extends none that is, keeps its window's name")
    try check(opensWeb("com.apple.iWork.Pages", "/Applications/Pages.app", handlers: []),
      "With no browser known, every app keeps its name alone")
    try check(ScreenTrail.opensWebPages(bundleID: nil, path: "/Applications/Pages.app", handlers: browsers) { _ in [] },
      "An app with no identifier keeps its name alone")
    try check(SereinSetup.offersFollow(on: false, declined: false, cardWaiting: false)
      && !SereinSetup.offersFollow(on: true, declined: false, cardWaiting: false)
      && !SereinSetup.offersFollow(on: false, declined: true, cardWaiting: false)
      && !SereinSetup.offersFollow(on: false, declined: false, cardWaiting: true)
      && (try? SereinSetup.topic(["topic": "follow"])) == .follow,
      "Following along is offered while it is off, never once it is on, was declined, or another card waits")

    // A connection's tool through the door: a read runs at every level; a change follows the
    // level, and a webhook or a schedule at Every step leaves its card open instead of refusing.
    typealias Door = ApprovalDoor
    let read = Door.Step.plugin(name: "list_items", declared: .read, effect: .read)
    let change = Door.Step.plugin(name: "anything", declared: nil)
    func mcp(_ step: Door.Step, _ standing: Door.Standing) -> Door.Answer {
      Door.answer(.init(step, standing), facts: DoorTable.facts())
    }
    try check(DoorTable.standings.allSatisfy { mcp(read, $0) == .run }, "A connection's read runs at every level, the person there or not")
    try check(
      mcp(change, .person(.everyStep)) == .card(.hold(cap: Door.holdCap)) && mcp(change, .person(.riskyOnly)) == .run
        && mcp(change, .proactiveTask(present: false)) == .run,
      "A connection's change follows the level")
    try check(
      mcp(change, Door.Standing(level: .everyStep, levelStands: true, present: false)) == .card(.deferred),
      "A webhook or a schedule at Every step leaves its card open; it is never refused")
  }
}
#endif
