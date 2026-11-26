#if DEBUG
import Foundation
import SereinCore

/// When a session on this Mac earns a text from Serein (SessionStatusTexts.swift), and what the
/// text may say. Synthetic sessions only; nothing here looks at a real process.
extension AssistantCoreChecks {
  static func sessionStatus(_ check: Check) throws {
    let transcript = """
      {"type":"user","timestamp":"2026-11-14T05:00:00.000Z","message":{"role":"user","content":"hi"}}
      {"type":"assistant","isSidechain":true,"timestamp":"2026-11-14T05:09:00.000Z","message":{"role":"assistant","content":[]}}
      {"type":"assistant","timestamp":"2026-11-14T05:07:17.250Z","message":{"role":"assistant","content":[]}}
      {"type":"last-prompt","lastPrompt":"hi"}
      {"type":"cost-state","timestamp":"2026-11-14T05:17:17.000Z"}
      {"type":"ai-title","title":"Greeting"}
      """
    let clock = TranscriptClock.lastMessage(in: Data(transcript.utf8))
    try check(clock == ISO8601DateFormatter().date(from: "2026-11-14T05:07:17Z")?.addingTimeInterval(0.25),
      "A Claude chat last changed at its last message, not at the bookkeeping lines after it or a helper's line")
    try check(TranscriptClock.lastMessage(in: Data("{\"type\":\"cost-state\"}\n".utf8)) == nil, "No message lines: no time")
    var lateEvent = SessionStatusTracker.Event(kind: .finished, sessionID: "claude:late", app: "Claude Code", folder: "site",
      startedAt: Date(timeIntervalSince1970: 0))
    lateEvent.endedAt = Date(timeIntervalSince1970: 5 * 60)
    try check(SessionStatusTexts.fallback(lateEvent, finishedAt: Date(timeIntervalSince1970: 3 * 3600)).hasSuffix("after 5 min."),
      "A finish noticed hours later still gives the turn's own length")
    let finishWords = SessionStatusWords.self
    try check(finishWords.finished(app: "Claude Code", title: "Fix  the\nlogin page", folder: "site", minutes: 12.2)
      == "Claude Code finished \u{201C}Fix the login page\u{201D} in site after 12 min.", "A finish names the title, folder and minutes")
    try check(finishWords.finished(app: "Codex", title: nil, folder: nil, minutes: 0.4) == "Codex finished.", "Under a minute and no title: just that it finished")
    try check(finishWords.finished(app: "Codex", title: "", folder: "api", minutes: 125) == "Codex finished in api after 2 h 5 min.", "Hours and minutes")
    try check(finishWords.finished(app: "Codex", title: String(repeating: "a", count: 200), folder: nil, minutes: nil).count < 110, "A long title is cut")
    typealias T = SessionStatusTracker
    let start = Date(timeIntervalSince1970: 1_000_000)
    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    func session(_ state: ExternalSession.State, id: String = "claude:one", pid: Int32? = 41) -> ExternalSession {
      ExternalSession(
        id: id, driver: .claude, title: "A private title", cwd: "/work/shop-web", state: state, updatedAt: start, pid: pid)
    }
    func events(_ tracker: inout T, _ seconds: TimeInterval, alive: Bool = true, watching: Bool = false) -> [T.Kind] {
      tracker.due(now: at(seconds), isAlive: { _ in alive }, isWatching: { _ in watching }).map(\.kind)
    }
    /// A tracker that has seen its first scan, with nothing running.
    func started() -> T {
      var tracker = T()
      tracker.observe([], now: start)
      return tracker
    }

    // The first scan is what was already going on, so a relaunch never repeats old news.
    var first = T()
    first.observe([session(.needsUser)], now: start)
    try check(events(&first, 600).isEmpty, "A session already waiting when Serein starts sends no text")

    // Needs you: once per wait, after a short settle.
    var needs = started()
    needs.observe([session(.running)], now: at(1))
    needs.observe([session(.needsUser)], now: at(2))
    try check(events(&needs, 3).isEmpty, "A question gets a few seconds before it becomes a text")
    try check(events(&needs, 8) == [.needsYou], "A session waiting on the person sends one text")
    needs.observe([session(.needsUser)], now: at(9))
    try check(events(&needs, 100).isEmpty, "One wait is one text")
    needs.observe([session(.running)], now: at(110))
    needs.observe([session(.needsUser)], now: at(120))
    try check(events(&needs, 130) == [.needsYou], "A new question is a new text")

    var answered = started()
    answered.observe([session(.needsUser)], now: at(1))
    answered.observe([session(.running)], now: at(3))
    try check(events(&answered, 60).isEmpty, "A question answered at once sends no text")

    // Finished: long enough to matter, and settled.
    var long = started()
    long.observe([session(.running)], now: at(0))
    long.observe([session(.open)], now: at(150))
    try check(events(&long, 160).isEmpty, "A turn that just ended gets time to settle")
    try check(events(&long, 171) == [.finished], "A long turn that ended sends one text")
    try check(events(&long, 500).isEmpty, "One finish is one text")

    var short = started()
    short.observe([session(.running)], now: at(0))
    short.observe([session(.open)], now: at(20))
    try check(events(&short, 100).isEmpty, "A short turn is chatter, not news: no text")

    var pause = started()
    pause.observe([session(.running)], now: at(0))
    pause.observe([session(.open)], now: at(30))
    pause.observe([session(.running)], now: at(35))
    pause.observe([session(.open)], now: at(130))
    try check(events(&pause, 140).isEmpty && events(&pause, 155) == [.finished],
      "A short pause in the middle of work counts as the same turn")

    var cooling = started()
    cooling.observe([session(.running)], now: at(0))
    cooling.observe([session(.open)], now: at(150))
    try check(events(&cooling, 175) == [.finished], "The first finish sends a text")
    cooling.observe([session(.running)], now: at(180))
    cooling.observe([session(.open)], now: at(310))
    try check(events(&cooling, 335) == [.finished], "A new completed turn is not lost to a cooldown")
    let later: TimeInterval = 2_000
    cooling.observe([session(.running)], now: at(later))
    cooling.observe([session(.open)], now: at(later + 150))
    try check(events(&cooling, later + 175) == [.finished], "An update after the quiet time sends a text")

    // Waiting on the person is not work.
    var waited = started()
    waited.observe([session(.running)], now: at(0))
    waited.observe([session(.needsUser)], now: at(10))
    _ = events(&waited, 20)
    waited.observe([session(.running)], now: at(190))
    waited.observe([session(.open)], now: at(198))
    try check(events(&waited, 225).isEmpty, "A short turn after an answered question sends no text")
    var worked = started()
    worked.observe([session(.running)], now: at(0))
    worked.observe([session(.needsUser)], now: at(130))
    _ = events(&worked, 140)
    worked.observe([session(.running)], now: at(200))
    worked.observe([session(.open)], now: at(205))
    try check(events(&worked, 230) == [.finished], "Long work before a question still counts once it ends")

    // Codex drops a finished turn from the list while its process lives on; a process that exits
    // mid-turn was closed or crashed, and that is not "finished".
    var dropped = started()
    dropped.observe([session(.running)], now: at(0))
    dropped.observe([], now: at(150))
    try check(events(&dropped, 175, alive: true) == [.finished], "A turn that left the list with its process alive finished")
    var exited = started()
    exited.observe([session(.running)], now: at(0))
    exited.observe([], now: at(150))
    try check(events(&exited, 175, alive: false).isEmpty, "A session whose process exited mid-turn does not say finished")

    // In front of the person already.
    var watchedQuestion = started()
    watchedQuestion.observe([session(.needsUser)], now: at(1))
    try check(events(&watchedQuestion, 10, watching: true).isEmpty, "No text about a question in the app in front")
    try check(events(&watchedQuestion, 20).isEmpty, "That question is not raised again later")
    var watchedFinish = started()
    watchedFinish.observe([session(.running)], now: at(0))
    watchedFinish.observe([session(.open)], now: at(150))
    try check(events(&watchedFinish, 175, watching: true).isEmpty, "A turn that ended in the app in front was seen: no text")
    try check(events(&watchedFinish, 190).isEmpty, "Nor later")
    var waitAgain = started()
    waitAgain.observe([session(.needsUser)], now: at(1))
    try check(events(&waitAgain, 10) == [.needsYou], "A wait is told once")
    waitAgain.observe([], now: at(20))
    waitAgain.observe([session(.needsUser)], now: at(30))
    try check(events(&waitAgain, 40).isEmpty, "The same wait seen again after a gap in the scan (a restart) is not told twice")

    var pending = started()
    pending.observe([session(.running)], now: at(0))
    pending.observe([session(.open)], now: at(150))
    let checkpoint = try JSONEncoder().encode(pending)
    try check(!String(decoding: checkpoint, as: UTF8.self).contains("A private title"),
      "The checkpoint excludes session titles and transcripts")
    var restored = try JSONDecoder().decode(T.self, from: checkpoint)
    restored.observe([session(.open)], now: at(160))
    try check(events(&restored, 175) == [.finished], "A pending finish survives a tracker restart")
    restored = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(restored))
    try check(events(&restored, 200).isEmpty, "A consumed completion does not return after restart")

    var continuing = started()
    var loop = session(.running); loop.goal = "active"
    continuing.observe([loop], now: at(0))
    loop.state = .open
    continuing.observe([loop], now: at(150))
    try check(events(&continuing, 180).isEmpty && continuing.nextDue == at(240),
      "An active goal waits without a hot timer or a false completion")
    continuing = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(continuing))
    loop.goal = "complete"
    continuing.observe([loop], now: at(190))
    try check(events(&continuing, 191) == [.finished], "A goal ending after restart releases its completion promptly")

    // When to look again.
    var timing = started()
    try check(timing.nextDue == nil, "Nothing pending means no wake-up")
    timing.observe([session(.needsUser)], now: at(1))
    try check(timing.nextDue == at(1 + T.needsSettle), "The next wake-up is when the pending text settles")
    _ = events(&timing, 10)
    try check(timing.nextDue == nil, "No wake-up is left once it was decided")

    // The words: the app and the folder, never the session's title or anything it wrote.
    func event(_ kind: T.Kind, app: String = "Claude Code", cwd: String? = "/work/shop-web") -> T.Event {
      T.Event(kind: kind, sessionID: "claude:one", app: app, folder: SessionStatusWords.place(cwd, home: "/Users/someone"))
    }
    typealias W = SessionStatusWords
    try check(W.text([event(.needsYou)]) == "Claude Code needs you in shop-web.", "A waiting session's text names its app and folder")
    try check(W.text([event(.finished)]) == "Claude Code has an update in shop-web.", "A finished session's text names its app and folder")
    try check(W.text([event(.finished, cwd: nil)]) == "Claude Code has an update.", "No folder leaves the folder out")
    try check(W.text([event(.finished), event(.finished, app: "Codex", cwd: "/work/api")])
      == "2 sessions have updates: Claude Code in shop-web, Codex in api.", "Finishes together are one text")
    let many = (1...6).map { event(.finished, app: "App \($0)", cwd: nil) }
    try check(W.text(many) == "6 sessions have updates: App 1, App 2, App 3, App 4 and 2 more.", "A long list stays short")
    let notified = [W.notification([event(.needsYou)]), W.notification([event(.finished)]), W.notification(many)]
    try check(notified == ["Claude Code needs you.", "Claude Code has an update.", "6 sessions have updates."],
      "A notification holds names and counts, not folders")
    try check(W.place("/Users/someone", home: "/Users/someone") == "your home folder" && W.place("/", home: "/Users/someone") == nil,
      "The home folder is named as such, and the root is no place")
    try check(W.place("/work/[click](x)\n*now*", home: "/h") == "click x now"
      && W.place("/work/" + String(repeating: "a", count: 90), home: "/h")?.count == 40,
      "A folder name cannot carry links, formatting, line breaks or length into the chat")
    var tracked = started()
    tracked.observe([session(.needsUser)], now: at(1))
    let raised = tracked.due(now: at(10), isAlive: { _ in true }, isWatching: { _ in false })
    try check(raised.first?.sessionID == "claude:one" && !W.text(raised).contains("private"),
      "The text never carries the session's title")
    try sessionFinishes(check)
    try transcriptToTexts(check)
    try codexLongOutput(check)
  }

  /// The "Sessions finished" card: one row per session, never the same event twice, short words.
  private static func sessionFinishes(_ check: Check) throws {
    typealias F = SessionFinishes
    let end = Date(timeIntervalSince1970: 2_000_000)
    func row(_ id: String, _ session: String, app: String = "Claude Code", folder: String? = "site", title: String? = nil) -> SessionFinish {
      SessionFinish(id: id, sessionID: session, app: app, title: title, folder: folder, minutes: 13, endedAt: end)
    }
    var rows = F.adding(row("1", "claude:a", title: "Settings redesign"), to: [])
    rows = F.adding(row("2", "opencode:b", app: "OpenCode", folder: "router"), to: rows)
    try check(rows.map(\.id) == ["1", "2"], "Finishes from different sessions share the card, oldest first")
    try check(F.adding(row("2", "opencode:b", app: "OpenCode", folder: "router"), to: rows) == rows,
      "A delivery retried after a crash never adds the same row twice")
    try check(F.adding(row("3", "claude:a"), to: rows).map(\.id) == ["2", "3"],
      "A session that finishes again moves its row to the end instead of adding one")
    let full = (0..<20).reduce([SessionFinish]()) { F.adding(row("r\($1)", "codex:\($1)"), to: $0) }
    try check(full.count == F.limit && full.first?.id == "r8", "A card keeps the newest rows")
    try check(F.text([row("1", "claude:a", title: "Settings redesign")])
      == "Claude Code finished \u{201C}Settings redesign\u{201D} in site after 13 min.", "One row reads as its sentence")
    try check(F.text(rows) == "2 sessions finished: OpenCode in router, Claude Code in site.",
      "Several read newest first as apps and folders, without titles")
    try check(SessionFinishesCard.provider(row("1", "claude:a")) == Provider(.claude)
      && SessionFinishesCard.provider(row("1", "process:opencode:42:1.0")) == Provider(.opencode)
      && SessionFinishesCard.provider(row("1", "nonsense")) == nil, "A row's mark comes from its session's app")
    try check(WaitingSessionsRow.waited(end, now: end.addingTimeInterval(20)) == "now"
      && WaitingSessionsRow.waited(end, now: end.addingTimeInterval(65 * 60)) == "1 h 5 min", "How long a session has waited")
  }

  /// A Claude Code transcript as it grows, through the real log reader and into the rules.
  private static func transcriptToTexts(_ check: Check) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("serein-status-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = home.appendingPathComponent(".claude/projects/-work-shop-web")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = folder.appendingPathComponent("status-check.jsonl")
    let process = HarnessProcess(
      pid: 999_999, parent: 2, executable: "/synthetic/bin/claude", arguments: ["claude"], cwd: "/work/shop-web", logs: [log.path])
    var reader = ExternalSessionReader()
    var tracker = SessionStatusTracker()
    let start = Date(timeIntervalSince1970: 2_000_000)
    tracker.observe([], now: start)
    /// Appends one line, scans, and returns what has settled by a little later.
    func write(_ line: String, at seconds: TimeInterval, settle: TimeInterval) throws -> [SessionStatusTracker.Event] {
      let handle = FileManager.default.fileExists(atPath: log.path) ? try FileHandle(forWritingTo: log) : nil
      if let handle {
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
      } else {
        try (line + "\n").write(to: log, atomically: false, encoding: .utf8)
      }
      let sessions = reader.snapshot(processes: [process], home: home.path)
      tracker.observe(sessions, now: start.addingTimeInterval(seconds))
      return tracker.due(now: start.addingTimeInterval(seconds + settle), isAlive: { _ in true }, isWatching: { _ in false })
    }
    let asked = try write(
      #"{"type":"user","sessionId":"status","cwd":"/work/shop-web","message":{"role":"user","content":"A private request"}}"#,
      at: 1, settle: 0)
    try check(asked.isEmpty, "A Claude Code transcript with a prompt is working, not news")
    let question = try write(
      #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"AskUserQuestion"}]}}"#,
      at: 2, settle: SessionStatusTracker.needsSettle)
    try check(question.map(\.kind) == [.needsYou] && SessionStatusWords.text(question) == "Claude Code needs you in shop-web.",
      "A real transcript's question becomes the text, without the request's words")
    let answer = try write(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result"}]}}"#, at: 30, settle: 0)
    try check(answer.isEmpty, "The transcript's answer ends the wait quietly")
    let done = try write(
      #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#,
      at: 150, settle: SessionStatusTracker.finishSettle)
    try check(done.map(\.kind) == [.finished] && SessionStatusWords.text(done) == "Claude Code has an update in shop-web.",
      "A real transcript's end becomes the finished text")
  }

  /// A Codex turn whose newest line is one tool output longer than the reader's tail (a
  /// screenshot's runs to megabytes) is still running: it never becomes a finished text.
  private static func codexLongOutput(_ check: Check) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("serein-status-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = home.appendingPathComponent(".codex/sessions/2026/11/25")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = folder.appendingPathComponent("rollout-2026-11-25T17-18-08-status-check.jsonl")
    try Data().write(to: log)
    let process = HarnessProcess(
      pid: 999_998, parent: 2, executable: "/synthetic/bin/codex", arguments: ["codex"], cwd: "/work/earth", logs: [log.path])
    var reader = ExternalSessionReader()
    var tracker = SessionStatusTracker()
    let start = Date(timeIntervalSince1970: 2_000_000)
    tracker.observe([], now: start)
    func write(_ lines: [String], at seconds: TimeInterval, settle: TimeInterval) throws -> (ExternalSession.State?, [SessionStatusTracker.Event]) {
      let handle = try FileHandle(forWritingTo: log)
      _ = try handle.seekToEnd()
      try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
      try handle.close()
      let sessions = reader.snapshot(processes: [process], home: home.path)
      tracker.observe(sessions, now: start.addingTimeInterval(seconds))
      let events = tracker.due(now: start.addingTimeInterval(seconds + settle), isAlive: { _ in true }, isWatching: { _ in false })
      return (sessions.first?.state, events)
    }
    let begun = try write([
      #"{"type":"session_meta","payload":{"id":"01a21500-status","cwd":"/work/earth"}}"#,
      #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
      #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec"}}"#,
    ], at: 1, settle: 0)
    try check(begun.0 == .running && begun.1.isEmpty, "A Codex turn calling a tool is running")
    let screenshot = String(repeating: "A", count: 700 * 1024)
    let long = try write([
      #"{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"\#(screenshot)"}}"#,
      #"{"type":"event_msg","payload":{"type":"token_count"}}"#,
    ], at: 300, settle: SessionStatusTracker.finishSettle)
    try check(long.0 == .running && long.1.isEmpty,
      "A Codex turn whose newest lines are a tool output longer than the read tail and bookkeeping is still running, not finished")
    let ended = try write([
      #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer"}}"#,
      #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
    ], at: 400, settle: SessionStatusTracker.finishSettle)
    try check(ended.0 == nil && ended.1.map(\.kind) == [.finished], "The same turn's real end still becomes the finished text")
    func turn(_ line: String) -> ExternalSessionReader.Turn? { ExternalSessionReader.codexTurn(Data((line + "\n").utf8)) }
    try check(turn(#"{"type":"event_msg","payload":{"type":"token_count"}}"#) == nil
      && turn(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#) == ExternalSessionReader.Turn(nil),
      "Bookkeeping alone says nothing about a Codex turn; its end says it ended")
  }
}
#endif

#if DEBUG
extension SmokeTest {
  /// A status text through the real chat: it lands in the main chat as a notice, starts no turn,
  /// saves no session title, keeps coming with check-ins off, and its own switch silences it.
  /// Synthetic sessions only.
  @MainActor static func sessionStatusDelivery(browser: BrowserModel, relay: RelayOrchestrator) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw SereinError.invalid("FAIL: " + message) }
      results.append("PASS: " + message)
    }
    RelayOrchestrator.quietForChecks = false
    // Posting itself is checked here; which turns are news is checked in AssistantCoreChecks.
    let reportAfter = SessionStatusTracker.reportAfter, reportsWatched = SessionStatusTracker.reportsWatched
    SessionStatusTracker.reportAfter = 0
    SessionStatusTracker.reportsWatched = true
    defer { SessionStatusTracker.reportAfter = reportAfter; SessionStatusTracker.reportsWatched = reportsWatched }
    let level = relay.proactiveOverride
    relay.proactiveOverride = .jarvis
    defer {
      RelayOrchestrator.quietForChecks = true
      relay.proactiveOverride = level
      ExternalSessionStore.shared.onScan = nil
      ExternalSessionStore.shared.onStopped = nil
      ExternalSessionStore.shared.update([])
    }
    // A fresh library has no main chat yet, and with none a text has nowhere to land.
    relay.recordWelcome("Hello.", generated: false, provider: relay.assistantEngine(relay.team.active).provider, thread: relay.threadID)
    let texts = SessionStatusTexts()
    texts.attach(relay)
    defer { texts.detachForChecks() }
    let start = Date()
    func session(_ state: ExternalSession.State) -> ExternalSession {
      ExternalSession(id: "claude:status-check", driver: .claude, title: "A private session title", cwd: "/synthetic/shop-web",
        state: state, updatedAt: start)
    }
    func bubbles() -> [AgentMessage] { relay.transcript.filter { $0.text.contains("shop-web") && $0.notice == true } }
    let before = bubbles().count
    texts.observe([], now: start)
    ExternalSessionStore.shared.update([session(.needsUser)])
    texts.observe([session(.needsUser)], now: start.addingTimeInterval(1))
    texts.observe([session(.needsUser)], now: start.addingTimeInterval(10))
    try check(bubbles().count == before && texts.waiting["claude:status-check"] != nil,
      "A waiting session waits in the row at the chat's foot, not as a chat text")
    try check(!relay.working, "A status text starts no turn")
    let saved = (try? String(contentsOf: browser.library.root.appendingPathComponent("sessions/threads.json"), encoding: .utf8)) ?? ""
    try check(!saved.contains("needs you in shop-web") && !saved.contains("A private session title"),
      "The saved chat holds no wait and never the session's title")
    let beforeFinish = bubbles().count
    texts.observe([session(.running)], now: start.addingTimeInterval(20))
    try check(texts.waiting.isEmpty, "An answered session leaves the row at once")
    texts.observe([session(.open)], now: start.addingTimeInterval(100))
    texts.observe([session(.open)], now: start.addingTimeInterval(125))
    for _ in 0..<100 where bubbles().count == beforeFinish { try await Task.sleep(for: .milliseconds(10)) }
    let finishedWords = bubbles().last?.text ?? ""
    try check(bubbles().count == beforeFinish + 1 && finishedWords.hasPrefix("Claude Code finished")
      && finishedWords.contains(" in shop-web after ") && finishedWords.hasSuffix(" min."),
      "A finished turn says what finished, where and for how long when its report is unavailable, without a fifteen-minute delay")
    try check(bubbles().last?.finished?.map(\.sessionID) == ["claude:status-check"],
      "A finish with no report is a row on a Sessions finished card, not a line of its own")
    try check(finishedWords.contains("\u{201C}A private session title\u{201D}") == SessionReading.allowed,
      "A finished turn names the session's title only while Serein may read the person's chats")
    relay.proactiveOverride = .off
    let offBefore = bubbles().count
    // Another session: the first has just had its text, and texts for one session are spaced out.
    let second = ExternalSession(id: "codex:status-check", driver: .codex, title: "Another private title", cwd: "/synthetic/shop-web",
      state: .needsUser, updatedAt: start)
    ExternalSessionStore.shared.update([session(.open), second])
    texts.observe([session(.open), second], now: start.addingTimeInterval(126))
    texts.observe([session(.open), second], now: start.addingTimeInterval(136))
    try check(bubbles().count == offBefore && texts.waiting["codex:status-check"] != nil,
      "Waiting sessions keep reaching the row with check-ins off, without a model call")
    texts.enabledOverride = false
    let silenced = bubbles().count
    texts.observe([session(.running)], now: start.addingTimeInterval(129))
    texts.observe([session(.needsUser)], now: start.addingTimeInterval(130))
    texts.observe([session(.needsUser)], now: start.addingTimeInterval(140))
    try check(bubbles().count == silenced && texts.waiting.isEmpty, "Turning off Updates from your AI apps silences status texts and empties the row")
    texts.holdForChecks("Held text in shop-web.", waitingSession: nil)
    texts.observe([session(.needsUser)], now: start.addingTimeInterval(150))
    texts.enabledOverride = nil
    relay.proactiveOverride = .jarvis
    texts.observe([session(.needsUser)], now: start.addingTimeInterval(160))
    try check(bubbles().count == silenced, "A text held for a busy chat is dropped once Serein is silenced")

    ExternalSessionStore.shared.update([session(.running)])
    texts.holdForChecks("Answered session in shop-web.", waitingSession: "claude:status-check")
    texts.holdForChecks("Still true in shop-web.", waitingSession: nil)
    texts.observe([session(.running)], now: start.addingTimeInterval(170))
    try check(bubbles().last?.text == "Still true in shop-web." && bubbles().count == silenced + 1,
      "A held question that was answered meanwhile never posts, and what waited behind it does")

    // Inject a model response: these checks exercise reading/delivery, never paid inference.
    CompletionNarrator.responderForChecks = { prompt in
      if prompt.contains("Opened the Serein project folder in Finder.") {
        return #"{"notify":false,"outcome":null,"caveats":[],"failedActivityIDs":[]}"#
      }
      return #"{"notify":true,"outcome":{"text":"Both synthetic checks passed, according to Claude's report.","quote":"Both synthetic checks passed"},"caveats":[{"text":"The report says hosted CI was unavailable.","quote":"hosted CI was unavailable"}],"failedActivityIDs":[]}"#
    }
    defer { CompletionNarrator.responderForChecks = nil }
    // An actual synthetic transcript supplies the useful result, not just the state label.
    let reportLog = browser.library.root.appendingPathComponent("session-status-fixture.jsonl")
    try #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done. Both synthetic checks passed; hosted CI was unavailable."}]}}"#
      .write(to: reportLog, atomically: true, encoding: .utf8)
    var reported = ExternalSession(id: "claude:report-proof", driver: .claude, title: "Private report title", cwd: "/synthetic/report-proof",
      state: .running, updatedAt: start)
    reported.log = reportLog.path
    ExternalSessionStore.shared.update([reported])
    texts.observe([reported], now: start.addingTimeInterval(171))
    reported.state = .open
    ExternalSessionStore.shared.update([reported])
    texts.observe([reported], now: start.addingTimeInterval(172))
    texts.observe([reported], now: start.addingTimeInterval(193))
    for _ in 0..<100 where !relay.transcript.contains(where: { $0.notice == true && $0.text.contains("Both synthetic checks passed") }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    try check(relay.transcript.contains { $0.notice == true && !$0.text.contains("Finished this turn.")
      && $0.text.contains("Both synthetic checks passed") && $0.text.contains("hosted CI was unavailable") },
      "A completion carries the actual final report and its limitation as a host notice")
    let finalNotice = relay.transcript.last { $0.notice == true && $0.text.contains("Both synthetic checks passed") }!
    try check(ChatBubbles.split(finalNotice.text).count == 1,
      "A result and its source form one bubble without a separate status announcement")
    let reportEvent = SessionStatusTracker.Event(kind: .finished, sessionID: reported.id, app: "Claude Code", folder: "report-proof")
    let newerReport = await SessionStatusTexts.report(reportEvent, browser: browser, finishedAt: start.addingTimeInterval(-100))
    try check(newerReport == nil, "A pending completion cannot borrow a report written after its cutoff")
    reported.state = .running
    ExternalSessionStore.shared.update([reported])
    let runningReport = await SessionStatusTexts.report(reportEvent, browser: browser, finishedAt: Date())
    try check(runningReport == nil, "A new running turn cannot become the previous turn's completion report")

    // A routine confirmation is consumed, not replaced with an alarming unreadable-report fallback.
    let noticesBeforeCourtesy = relay.transcript.filter { $0.notice == true }.count
    texts.observe([reported], now: start.addingTimeInterval(194))
    try #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Opened the Serein project folder in Finder."}]}}"#
      .write(to: reportLog, atomically: true, encoding: .utf8)
    reported.state = .open
    ExternalSessionStore.shared.update([reported])
    texts.observe([reported], now: start.addingTimeInterval(195))
    texts.observe([reported], now: start.addingTimeInterval(216))
    let courtesyQueue = browser.library.root.appendingPathComponent(SessionStatusTexts.checkpointPath)
    for _ in 0..<100 {
      let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: courtesyQueue)) as! [String: Any]
      if (saved["held"] as? [Any])?.isEmpty == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let courtesyCheckpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: courtesyQueue)) as! [String: Any]
    try check(relay.transcript.filter { $0.notice == true }.count == noticesBeforeCourtesy
      && (courtesyCheckpoint["held"] as? [Any])?.isEmpty == true,
      "A simple Finder confirmation is consumed durably without posting a fallback or an alert")

    let quieted = bubbles().count
    texts.observe([session(.running)], now: start.addingTimeInterval(180))
    texts.stopped()
    texts.observe([session(.open)], now: start.addingTimeInterval(600))
    texts.observe([session(.open)], now: start.addingTimeInterval(700))
    try check(bubbles().count == quieted, "Turning watching off and on sends no old news")
    var helper = ExternalSession(id: "codex:helper-check", driver: .codex, title: "A helper", cwd: "/synthetic/shop-web",
      state: .needsUser, updatedAt: start)
    helper.parent = "status-check-parent"
    ExternalSessionStore.shared.update([session(.open), helper])
    texts.observe([session(.open), helper], now: start.addingTimeInterval(800))
    texts.observe([session(.open), helper], now: start.addingTimeInterval(810))
    try check(bubbles().count == quieted, "A helper a session spawned sends no texts of its own")

    // Save a completion before it is due, then restore a fresh coordinator while Codex is in front.
    texts.stopped(); texts.detachForChecks()
    let readingAllowed = SessionReading.allowed
    SessionReading.allowed = false
    defer { SessionReading.allowed = readingAllowed }
    let durable = SessionStatusTexts(); durable.holdDeliveryForChecks = true; durable.watchingForChecks = true
    durable.attach(relay)
    let doneID = "codex:durable-status-check"
    func durableSession(_ state: ExternalSession.State) -> ExternalSession {
      ExternalSession(id: doneID, driver: .codex, title: "Never persisted", cwd: "/synthetic/restart-proof",
        state: state, updatedAt: start, pid: 99)
    }
    durable.observe([], now: start)
    durable.observe([durableSession(.running)], now: start)
    durable.observe([durableSession(.open)], now: start.addingTimeInterval(70))
    durable.detachForChecks()
    let resumed = SessionStatusTexts(); resumed.holdDeliveryForChecks = true; resumed.watchingForChecks = true
    resumed.attach(relay)
    ExternalSessionStore.shared.update([durableSession(.open)])
    resumed.observe([durableSession(.open)], now: start.addingTimeInterval(95))
    let queueURL = browser.library.root.appendingPathComponent(SessionStatusTexts.checkpointPath)
    let pendingBytes = try Data(contentsOf: queueURL)
    let pendingJSON = try JSONSerialization.jsonObject(with: pendingBytes) as! [String: Any]
    let outbox = pendingJSON["held"] as! [[String: Any]]
    let noticeID = outbox.first?["id"] as? String ?? "missing"
    // With no report to read, the completion is a row on a Sessions finished card.
    func delivered() -> Bool { relay.agent.hasNotice(noticeID, into: relay.threadID) || relay.agent.hasFinish(noticeID, into: relay.threadID) }
    func copies() -> Int {
      relay.transcript.reduce(0) { $0 + ($1.finished.map { rows in rows.filter { $0.id == noticeID }.count } ?? ($1.id == noticeID ? 1 : 0)) }
    }
    try check(outbox.count == 1 && !delivered(), "A foreground completion is durably queued while delivery is held")
    resumed.detachForChecks()
    let delivering = SessionStatusTexts(); delivering.watchingForChecks = true; delivering.attach(relay)
    for _ in 0..<100 where !delivered() { try await Task.sleep(for: .milliseconds(10)) }
    try check(delivered(), "A fresh coordinator delivers its pending completion")
    delivering.detachForChecks()
    // Simulate the crash window: the chat was saved, but the old outbox remained on disk.
    try pendingBytes.write(to: queueURL, options: .atomic)
    let recovering = SessionStatusTexts(); recovering.watchingForChecks = true; recovering.attach(relay)
    for _ in 0..<100 {
      let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as! [String: Any]
      if (saved["held"] as? [Any])?.isEmpty == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try check(copies() == 1, "A crash between chat save and dequeue does not duplicate the completion")
    recovering.detachForChecks()
    let again = SessionStatusTexts(); again.attach(relay)
    again.observe([durableSession(.open)], now: start.addingTimeInterval(150))
    try check(copies() == 1, "Another restart and scan keep the delivered completion exactly once")
    again.stopped(); again.detachForChecks()

    // A "needs you" queued as a chat text by an older Serein waits in the row after the update.
    ExternalSessionStore.shared.update([session(.needsUser)])
    let older = SessionStatusTexts(); older.holdDeliveryForChecks = true; older.attach(relay)
    older.holdForChecks("Claude Code needs you in shop-web.", waitingSession: "claude:status-check")
    older.detachForChecks()
    let updated = SessionStatusTexts(); updated.holdDeliveryForChecks = true; updated.attach(relay)
    try check(updated.waiting["claude:status-check"] != nil && !relay.transcript.contains { $0.text == "Claude Code needs you in shop-web." },
      "A question queued before the row moves into the row, not the chat")
    updated.stopped(); updated.detachForChecks()

    // Finishes share the card while it is the chat's last message; anything after starts a new one.
    func finish(_ id: String, _ session: String) -> SessionFinish {
      SessionFinish(id: id, sessionID: session, app: "Codex", title: nil, folder: "api", minutes: 3, endedAt: Date())
    }
    let cardID = "finish-card-" + UUID().uuidString
    // The completion above left its card last; a message after it means the next finish starts one.
    _ = relay.agent.postNotice("Something before.", into: relay.threadID, id: UUID().uuidString)
    _ = relay.agent.postFinish(finish(cardID, "codex:card-a"), into: relay.threadID)
    _ = relay.agent.postFinish(finish(cardID + "-b", "codex:card-b"), into: relay.threadID)
    try check(relay.transcript.last?.id == cardID && relay.transcript.last?.finished?.count == 2
      && relay.transcript.last?.text == "2 sessions finished: Codex in api, Codex in api.",
      "A second finish joins the card at the end of the chat")
    _ = relay.agent.postNotice("Something else in between.", into: relay.threadID, id: UUID().uuidString)
    _ = relay.agent.postFinish(finish(cardID + "-c", "codex:card-c"), into: relay.threadID)
    try check(relay.transcript.last?.id == cardID + "-c" && relay.transcript.last?.finished?.count == 1,
      "A finish after other messages starts a new card")

    // A failed chat write must not acknowledge delivery merely because the bubble is in memory.
    let threadsURL = browser.library.root.appendingPathComponent("sessions/threads.json")
    let backupURL = browser.library.root.appendingPathComponent("sessions/threads-before-failure.json")
    let blockerURL = browser.library.root.appendingPathComponent("sessions/threads-write-blocker")
    try FileManager.default.moveItem(at: threadsURL, to: backupURL)
    try FileManager.default.createDirectory(at: threadsURL, withIntermediateDirectories: false)
    let failedID = UUID().uuidString
    let failedSave = relay.agent.postNotice("Saved once after retry.", into: relay.threadID, id: failedID)
    try FileManager.default.moveItem(at: threadsURL, to: blockerURL)
    try FileManager.default.moveItem(at: backupURL, to: threadsURL)
    try check(failedSave == false, "A failed chat write leaves the notice unacknowledged")
    try check(relay.agent.postNotice("Saved once after retry.", into: relay.threadID, id: failedID) == true
      && relay.transcript.filter { $0.id == failedID }.count == 1,
      "Retrying a failed chat write saves the same notice without duplication")
    let diskThreads = try String(contentsOf: threadsURL, encoding: .utf8)
    try check(diskThreads.components(separatedBy: failedID).count == 2,
      "The retried notice is present exactly once in the durable chat")

    // The Agents list also shows the AI apps' recent chats that have no process now.
    let project = Project(name: "Synthetic shop", path: "/synthetic/shop-web")
    let fresh = DiscoveredSession(provider: "claude", id: "list-check-recent", cwd: project.path, title: "Fix the header", date: start)
    let old = DiscoveredSession(provider: "claude", id: "list-check-old", cwd: project.path, title: "Old chat",
                                date: start.addingTimeInterval(-AgentsByProject.recentWindow - 60))
    let groups = AgentsByProject.groups(agent: relay.agent, hub: relay.agent.hub, relay: relay, ledger: [], items: [],
                                        projects: [project], history: [fresh, old], now: start)
    let rows: [AgentsByProject.Task] = groups.flatMap(\.entries).compactMap { if case .task(let t) = $0 { return t } else { return nil } }
    try check(rows.contains { $0.past?.id == "list-check-recent" && $0.title == "Fix the header" }
      && !rows.contains { $0.past?.id == "list-check-old" },
      "The Agents list shows an AI app's chat from the last two days with no process, and not an older one")
    return results
  }
}
#endif
