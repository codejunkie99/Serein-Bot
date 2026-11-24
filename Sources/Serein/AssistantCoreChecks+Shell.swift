#if DEBUG
import Foundation
import SQLite3
import SereinCore

/// Units 11 and 12 (the shell's memory and schedules): the pure rules the shell runs on. Every
/// check runs on new files in a temporary folder.
extension AssistantCoreChecks {
  /// Runs SQL on a file through a second connection, as a stray writer would. The result code
  /// says whether the file took it.
  private static func shellExec(_ url: URL, _ sql: String) -> Int32 {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
      if let handle { sqlite3_close(handle) }
      return SQLITE_CANTOPEN
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 2000)
    return sqlite3_exec(db, sql, nil, nil, nil)
  }

  // MARK: unit 11: memory in the shell

  static func shellMemory(_ check: Check) throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("serein-shell-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // The unreadable guard: a file that does not decode is kept as it is.
    let library = try Library(root: root.appendingPathComponent("library", isDirectory: true))
    let path = "relay/reminders.json"
    try files.createDirectory(
      at: library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
    try check(library.loadGuarded([RelayReminder].self, from: path).value == nil, "A missing file reads as missing")
    try library.saveText("{ not json", to: path)
    if case .unreadable = library.loadGuarded([RelayReminder].self, from: path) {
      try check(true, "A file that does not decode reads as unreadable")
    } else {
      try check(false, "A file that does not decode reads as unreadable")
    }
    let kept = (try? String(contentsOf: library.root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    try check(kept == "{ not json", "The unreadable file stays as it was")
    let words = RelayStateFile.words(for: path)
    try check(words.contains("reminders") && !words.lowercased().contains("json"), "The guard's words name the data, never a format")
    try library.save([RelayReminder(text: "Stretch", due: now)], to: path)
    try check(library.loadGuarded([RelayReminder].self, from: path).value?.first?.text == "Stretch", "A good file loads")

    // remember: only the person's words that ask to keep something make a kept note.
    try check(MemoryTools.asksToRemember("Remember that Ana is a client"), "“Remember that …” asks to keep it")
    try check(MemoryTools.asksToRemember("Don't forget I fly on Friday"), "“Don't forget …” asks to keep it")
    try check(!MemoryTools.asksToRemember("Please delegate a check task."), "A task request does not ask to keep anything")

    // Who a share names.
    var team = RelayTeam.fresh()
    team.profiles.append(RelayProfile(id: "planner", name: "Planner"))
    team.groups = [AssistantGroup(id: "trip", name: "Trip", memberIDs: ["planner"])]
    try check(MemoryTools.scope(with: "everyone", in: team, assistant: "planner") == .person, "Everyone is every assistant")
    try check(MemoryTools.scope(with: "the Trip team", in: team, assistant: "planner") == .team("trip"), "A team by its name")
    try check(MemoryTools.scope(with: "only you", in: team, assistant: "planner") == .assistant("planner"), "Only you narrows")
    try check(MemoryTools.scope(with: "the moon", in: team, assistant: "planner") == nil, "An unknown name is refused")
    try check(MemoryTools.whom(.team("trip"), in: team) == "The Trip team", "A team receipt names the team")
    let who = MemoryTools.whoKnows(["planner": 2, "gone": 5], in: team)
    try check(who.count == 1 && who.first?.name == "Planner" && who.first?.count == 2, "Who knows names assistants on the roster only")

    // The turn's memory block.
    func note(_ id: String, _ text: String, scope: MemoryScope = .person, personal: Bool = false, at: Date? = nil) -> MemoryRecord {
      MemoryRecord(
        id: id, text: text, owner: "planner", scope: scope, provenance: MemoryProvenance(source: .person),
        createdAt: at ?? now, review: .confirmed, personal: personal)
    }
    let topical = [note("a", "Ana is a client")]
    let newest = [note("b", "Prefers aisle seats"), note("c", "Private plan", scope: .assistant("planner")), note("a", "Ana is a client")]
    let chosen = MemoryTools.forTurn(topical: topical, newest: newest)
    try check(chosen.map(\.id) == ["a", "b"], "Few matches fill with the newest notes shared with everyone, each once")
    let many = (1...4).map { note("t\($0)", "Topic \($0)") }
    try check(MemoryTools.forTurn(topical: many, newest: newest).count == 4, "Enough matches need no fill")
    let sealed = MemoryHits([note("p", "Ana's phone", personal: true), note("q", "Ana's city")])
    guard let block = MemoryPrompt.renderKept(sealed.unmarked, sealed: sealed.sealedCount, now: now) else {
      throw SereinError.invalid("FAIL: The memory block renders")
    }
    try check(block.ids == ["q"] && !block.text.contains("phone"), "A personal note stays out of an unmarked chat's block")
    try check(block.text.contains("1 more note holds personal data. Use recall to read them."), "One line counts what stays out")
    try check(block.text.contains(MemoryPrompt.notProof), "The block says memory is not proof")
    let stale = MemoryPrompt.renderKept([note("s", "Old fact", at: now.addingTimeInterval(-100 * 86_400))], now: now)
    try check(stale?.text.contains("It may be out of date.") == true, "A note unused for 90 days may be out of date")
    try check(MemoryPrompt.renderKept([], now: now) == nil, "Nothing to say renders nothing")

    // Learning: idle chats, limits and words.
    let quiet = now.addingTimeInterval(-7 * 3600)
    try check(RelayLearning.isDue(lastID: "m2", lastAt: quiet, learnedThrough: "m1", now: now), "A chat quiet for 7 hours is due")
    try check(!RelayLearning.isDue(lastID: "m2", lastAt: quiet, learnedThrough: "m2", now: now), "A chat read through its last message is not")
    try check(!RelayLearning.isDue(lastID: "m2", lastAt: now.addingTimeInterval(-3600), learnedThrough: nil, now: now), "One quiet for an hour waits")
    try check(!RelayLearning.isDue(lastID: "m2", lastAt: now.addingTimeInterval(-11 * 86_400), learnedThrough: nil, now: now), "One quiet for 11 days is left")
    let twoThisHour = [now.addingTimeInterval(-600), now.addingTimeInterval(-1200)]
    try check(!RelayLearning.mayCapture(after: twoThisHour, now: now), "At most 2 captures an hour")
    let eightToday = (1...8).map { now.addingTimeInterval(-Double($0) * 7200) }
    try check(!RelayLearning.mayCapture(after: eightToday, now: now), "At most 8 captures a day")
    try check(RelayLearning.mayCapture(after: [now.addingTimeInterval(-90_000)], now: now), "Yesterday's captures do not count")
    try check(RelayLearning.overGeneralises("The person always wants a window seat", quote: "a window seat please"),
              "A habit word the person did not say is refused")
    try check(!RelayLearning.overGeneralises("The person always flies economy", quote: "I always fly economy"),
              "A habit word the person said is kept")
    let candidates = [
      RelayLearning.Candidate(text: "The person works on the shop-web project", quote: "my shop-web project"),
      RelayLearning.Candidate(text: "The person always skips breakfast", quote: "no breakfast today"),
      RelayLearning.Candidate(text: "The person's key is sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", quote: nil),
    ]
    let learned = RelayLearning.records(candidates, by: "planner", chat: "chat-9", personal: true, known: [], waiting: 0, now: now)
    try check(learned.count == 1 && learned.first?.review == .unreviewed && learned.first?.scope == .assistant("planner"),
              "A capture keeps plain notes as private proposals")
    try check(learned.first?.chat == "chat-9" && learned.first?.personal == true, "A proposal keeps its chat and the chat's mark")
    try check(RelayLearning.records(candidates, by: "planner", chat: nil, personal: false, known: [], waiting: RelayLearning.maxProposals, now: now).isEmpty,
              "A full review list takes no more")

    // The store: the upgrade, the fixed columns, use counts and the chat cascade.
    let url = root.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("memory.sqlite")
    let store = try MemoryStore(url: url)
    let typed = try MemoryDefaults.remembered(
      "Ana is a client", by: "planner", chat: "chat-1", turn: MemoryTurn(readOutside: false, readPersonal: false), now: now)
    _ = try store.insert(typed, now: now)
    let idea = try MemoryDefaults.learned(
      "The person plans a trip to Lisbon", by: "planner", from: .assistant, personal: false, chat: "chat-1", now: now)
    _ = try store.insert(idea, now: now)
    let other = try MemoryDefaults.learned(
      "The person likes jazz", by: "planner", from: .assistant, personal: false, chat: "chat-2", now: now)
    _ = try store.insert(other, now: now)
    try check(try store.record(id: idea.id)?.chat == "chat-1", "A record keeps the chat it was made in")
    let reopened = try MemoryStore(url: url)
    try check(try reopened.record(id: typed.id)?.text == "Ana is a client", "Opening the file again changes nothing")
    let fixed = shellExec(url, "UPDATE records SET chat = 'elsewhere' WHERE id = '\(typed.id)'")
    let afterFixed = try store.record(id: typed.id)
    try check(fixed != SQLITE_OK && afterFixed?.chat == "chat-1", "A fixed column cannot change")
    let personalFlip = shellExec(url, "UPDATE records SET personal = 1 WHERE id = '\(typed.id)'")
    try check(personalFlip != SQLITE_OK, "The personal-read mark cannot change")
    let edit = try store.update(id: typed.id, expected: typed.updatedAt, edit: MemoryEdit(text: "Ana is a former client"), now: now)
    if case .done = edit { try check(true, "A built edit still lands under the trigger") } else { try check(false, "A built edit still lands under the trigger") }
    try store.markRendered([typed.id, typed.id], now: now)
    try check(try store.record(id: typed.id)?.useCount == 1, "The host's use counts once per render")
    let gone = try store.forgetLearned(chat: "chat-1", now: now)
    let ideaAfter = try store.record(id: idea.id)
    try check(gone == 1 && ideaAfter == nil, "Deleting a chat forgets what was learned in it")
    let typedAfter = try store.record(id: typed.id)
    let otherAfter = try store.record(id: other.id)
    try check(typedAfter != nil && otherAfter != nil, "What the person said, and other chats, stay")
    try check(try store.insert(idea, now: now) == .blocked, "A fact from a deleted chat is not learned again")
    // More learned records than one batch (200): deleting the chat forgets every one.
    for index in 0..<205 {
      let many = try MemoryDefaults.learned(
        "The busy chat taught fact number \(index)", by: "planner", from: .assistant, personal: false, chat: "chat-big", now: now)
      _ = try store.insert(many, now: now)
    }
    let goneMany = try store.forgetLearned(chat: "chat-big", now: now)
    let leftMany = try store.forgetLearned(chat: "chat-big", now: now)
    try check(goneMany == 205 && leftMany == 0, "Deleting a chat forgets more than one batch of learned records")
    // A note from outside content makes the turn that reads it outside (recall and the memory block).
    try check(MemoryTools.carriesOutside([other]) && !MemoryTools.carriesOutside([typed]),
      "A learned note counts as outside content; the person's own note does not")

    // Rules live in the store but never in recall, the memory block's 4 slots or the notes list.
    let rule = MemoryRecord(
      kind: .rule, text: "Ana gets a short reply only", quote: "keep replies to Ana short", owner: "planner", scope: .person,
      provenance: MemoryProvenance(source: .person), createdAt: now, review: .confirmed, personal: false)
    _ = try store.insert(rule, now: now)
    let reader = MemoryReader(assistant: "planner")
    let anaHits = try store.search("Ana", reader: reader, now: now).reveal { true }
    let newestHits = try store.search("", reader: reader, now: now).reveal { true }
    try check(!anaHits.isEmpty && !(anaHits + newestHits).contains { $0.kind == .rule }, "Search never returns a rule")
    try check(!MemoryTools.forTurn(topical: anaHits, newest: newestHits).contains { $0.id == rule.id }, "A rule never takes one of the 4 memory slots")
    try check(try store.rules(reader: reader, now: now).map(\.id) == [rule.id], "The rules read returns the rule")
    try check(!(try store.notes(owner: "planner")).contains { $0.id == rule.id }, "A rule is not in the notes file")

    // Receipts the memory shell writes.
    let narrowed = Receipt(kind: .memoryShared, line: "Done. Only Planner uses it now.")
    try check(ReceiptCopy.lint(narrowed.line).isEmpty, "The narrow receipt is plain")
  }

  // MARK: unit 12: schedules in the shell

  static func shellSchedules(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone

    // The host does the time sum.
    if case .success(let date)? = ScheduleRequest.firstDue(at: nil, inMinutes: 15, now: now) {
      try check(date.timeIntervalSince(now) == 900, "in_minutes 15 is 15 minutes from now")
    } else {
      try check(false, "in_minutes 15 is 15 minutes from now")
    }
    if case .failure(let refusal)? = ScheduleRequest.firstDue(at: "2026-10-22T09:00:00Z", inMinutes: 20_000, now: now) {
      try check(refusal == .outOfRange, "in_minutes past a week is refused, whatever at says")
    } else {
      try check(false, "in_minutes past a week is refused, whatever at says")
    }
    try check(ScheduleRequest.firstDue(at: nil, inMinutes: nil, now: now) == nil, "No time is no time")

    // The guard over every repeat.
    let on = (1...20).map { RelayReminder(id: "r\($0)", text: "Run \($0)", due: now, repeats: .daily, action: true) }
    try check(ScheduleRequest.actionRoutinesOn(on) == 20 && ScheduleRequest.actionRoutinesOn(on, except: "r1") == 19,
              "Routines that act and are on are counted, without the one being changed")
    try check(ScheduleRequest.refusal(repeats: .cron, cron: "*/5 * * * *", acts: true, actionRoutinesOn: 0) == .tooOften(minutes: 5),
              "Every 5 minutes is too often for a routine that acts")
    try check(ScheduleRequest.refusal(repeats: .cron, cron: "*/5 * * * *", acts: true, on: false, actionRoutinesOn: 0) == .tooOften(minutes: 5),
              "The floor holds for a paused routine too")
    try check(ScheduleRequest.refusal(repeats: .daily, cron: nil, acts: true, actionRoutinesOn: 20) == .tooMany,
              "A twenty-first daily routine is refused")
    try check(ScheduleRequest.refusal(repeats: .daily, cron: nil, acts: true, on: false, actionRoutinesOn: 20) == nil,
              "A paused one does not count against the twenty")
    try check(ScheduleRequest.refusal(repeats: .none, cron: nil, acts: true, actionRoutinesOn: 20) == nil, "A one-time request is not a routine")
    try check(ScheduleRequest.refusal(repeats: .cron, cron: nil, acts: false, actionRoutinesOn: 0) == .unreadable, "A custom repeat needs its cron")

    // Typed words name what they approve.
    try check(ScheduleRequest.namesSchedule("Every weekday at 8 clear my inbox"), "“Every weekday at 8” names a schedule")
    try check(ScheduleRequest.namesSchedule("Inbox Zero, check my mail every 15 minutes"), "“every 15 minutes” names a schedule")
    try check(ScheduleRequest.namesSchedule("do it at 8:30"), "A clock time names a schedule")
    try check(!ScheduleRequest.namesSchedule("Summarize this page for me"), "A request without a time names none")
    try check(ScheduleRequest.namesGoal("Find me a used road bike under 600"), "“Find me” names a goal")
    try check(ScheduleRequest.wordsName("Inbox Zero", in: "Inbox Zero, check my mail every 15 minutes"), "The words name the assistant")
    try check(!ScheduleRequest.wordsName("Inbox Zero", in: "check my inbox"), "Part of a name is not the name")

    // Receipts.
    let reminder = RelayReminder(text: "Call Ana", due: now.addingTimeInterval(900))
    let banner = ScheduleRequest.receipt(for: reminder, now: now, calendar: calendar)
    try check(banner.kind == .reminder && ReceiptCopy.lint(banner.line).isEmpty, "A one-time reminder gets the plain banner")
    let routine = RelayReminder(
      text: "Check my mail", due: now, repeats: .cron, action: true, cron: "*/15 * * * *", profileID: "inbox")
    let owned = ScheduleRequest.receipt(for: routine, owner: "Inbox Zero", now: now, calendar: calendar)
    try check(owned.line == "Okay. Every 15 minutes Inbox Zero will check my mail.", "A routine for another assistant names it")
    if case .routine(let title, let detail, let isOn)? = owned.card {
      try check(title == "Every 15 minutes" && detail == "Check my mail" && isOn, "The routine card has plain words and is on")
    } else {
      try check(false, "The routine card has plain words and is on")
    }
    let long = RelayReminder(
      text: String(repeating: "word ", count: 80), due: now, repeats: .daily, action: true)
    let clipped = ScheduleRequest.receipt(for: long, now: now, calendar: calendar)
    try check(clipped.line.count <= Receipt.maxLine && ReceiptCopy.lint(clipped.line).isEmpty, "A long routine's line is cut to fit")
    let daily = ScheduleRequest.receipt(for: RelayReminder(text: "Stretch", due: now, repeats: .daily), now: now, calendar: calendar)
    try check(daily.kind == .routine && daily.line.hasPrefix("Okay. Every day at "), "A repeating reminder gets the routine card")

    // A queued run's ledger row.
    let run = QueuedRun(reminder: routine, initiator: .scheduled, profileID: "inbox", retried: false)
    guard let payload = run.payload() else { throw SereinError.invalid("FAIL: A queued run fits the ledger") }
    try check(QueuedRun.decoded(payload) == run && run.owner == "inbox", "A queued run reads back whole, with its owner")
    try check(QueuedRun(reminder: reminder, initiator: .webhook, profileID: nil, retried: true).owner == QueuedRun.personsOwn,
              "The person's own run has the person as owner")
    try check(QueuedRun.decoded("{") == nil, "A payload this build cannot read is nothing")
    let missed = RelayMissedRun(reminder: routine, why: .interrupted)
    try check(missed.title == "Stopped when Serein closed, and did not run again", "An interrupted run says it did not run again")
  }
}
#endif
