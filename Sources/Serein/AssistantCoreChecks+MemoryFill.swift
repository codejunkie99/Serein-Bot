#if DEBUG
import Foundation
import SQLite3
import SereinCore

extension AssistantCoreChecks {
  /// Runs `sql` straight on the file, as another build would.
  private static func fillExec(_ url: URL, _ sql: String) -> Int32 {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
      if let handle { sqlite3_close(handle) }
      return SQLITE_CANTOPEN
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 2000)
    return sqlite3_exec(db, sql, nil, nil, nil)
  }
  /// The file's `user_version`, or -1.
  private static func fillVersion(_ url: URL) -> Int64 {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
      if let handle { sqlite3_close(handle) }
      return -1
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : -1
  }

  // MARK: memory never fills, and the journal's words

  static func memoryFill(_ check: Check) throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("serein-fill-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func note(
      _ text: String, id: String = UUID().uuidString, owner: String = "writer", quote: String? = nil,
      at time: Date? = nil, expires: Date? = nil, review: MemoryRecord.Review = .confirmed, chat: String? = nil,
      archived: Date? = nil
    ) -> MemoryRecord {
      MemoryRecord(
        id: id, text: text, quote: quote, owner: owner, scope: .person, provenance: MemoryProvenance(source: .person),
        createdAt: time ?? now, expires: expires, review: review, personal: false, chat: chat, archived: archived)
    }

    // The caps, pure.
    try check(MemoryFill.maxLines == 200 && MemoryFill.maxBytes == 24_000, "The notes hold 200 lines or 24,000 bytes")
    let lines160: [MemoryRecord] = (0..<160).map { note("Fact \($0)") }
    try check(MemoryFill.usage(lines160).warns && MemoryFill.usage(lines160).percent == 80, "The gauge warns at 80 percent")
    try check(!MemoryFill.usage(Array(lines160.dropLast())).warns, "Below 80 percent it does not warn")
    try check(MemoryFill.usage([note("one\ntwo\nthree", quote: "abc")]) == MemoryFill.Usage(lines: 3, bytes: 16),
              "A note takes its lines, and the bytes of its text and quote")
    try check(MemoryFill.moving(lines160, now: now).isEmpty, "Notes under both caps stay")
    let wide: [MemoryRecord] = (0..<41).map { note(String(repeating: "x", count: 600), id: "w\($0)", at: now.addingTimeInterval(Double($0))) }
    try check(MemoryFill.moving(wide, now: now).map(\.record.id) == ["w0"], "Over 24,000 bytes the oldest note leaves")
    let ended = note("At the Lisbon hotel", id: "hotel", expires: now.addingTimeInterval(-1))
    let moves = MemoryFill.moving([ended] + lines160, now: now)
    try check(moves.count == 1 && moves.first?.reason == .ended, "A note past its end date leaves, whatever the room")
    try check(MemoryFill.isHealth("Allergic to penicillin") && !MemoryFill.isHealth("Likes long walks"),
              "A health fact is told by its words")

    // The archive in the store.
    let url = root.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("memory.sqlite")
    let store = try MemoryStore(url: url)
    let writer = MemoryReader(assistant: "writer")
    _ = try store.insert(note("Allergic to penicillin", id: "allergy", at: now.addingTimeInterval(-500)), now: now)
    for number in 0..<204 {
      let mark: String = number == 0 ? " zanzibar" : number == 100 ? " quokka" : ""
      _ = try store.insert(note("Trip fact \(number)" + mark, id: "f\(number)", at: now.addingTimeInterval(Double(number))), now: now)
    }
    _ = try store.insert(note("Staying in Alfama", id: "alfama", expires: now.addingTimeInterval(-60), chat: "chat-7"), now: now)
    _ = try store.insert(note("An idea", id: "idea", review: .unreviewed), now: now)
    _ = try store.insert(note("Planner's own", id: "other", owner: "planner"), now: now)
    let total = try store.count()
    let moved = try store.archive(owner: "writer", now: now)
    try check(moved.filter { $0.reason == .ended }.map(\.record.id) == ["alfama"], "The store archives a note past its end date")
    try check(moved.filter { $0.reason == .full }.map(\.record.id) == ["f0", "f1", "f2", "f3", "f4"],
              "Past 200 lines the oldest notes leave, and a health fact stays")
    try check(try store.count() == total, "Archiving deletes nothing")
    try check(try store.record(id: "f0")?.archived != nil && (try store.record(id: "f0"))?.text == "Trip fact 0 zanzibar",
              "An archived note keeps its words")
    try check(MemoryFill.usage(try store.notes(owner: "writer")).lines == MemoryFill.maxLines, "The notes are back at the cap")
    try check(try store.archive(owner: "writer", now: now).isEmpty, "A second pass moves nothing")
    try check(try store.record(id: "idea")?.archived == nil && (try store.record(id: "other"))?.archived == nil,
              "An idea and another assistant's note stay where they are")
    let gone = try store.search("zanzibar", reader: writer, now: now).reveal(markingChat: { true }).map(\.id)
    let kept = try store.search("quokka", reader: writer, now: now).reveal(markingChat: { true }).map(\.id)
    try check(gone.isEmpty && kept == ["f100"], "An archived note is not recalled")
    try check(!MemoryRecall.eligible(note("Old", archived: now), for: writer, now: now), "The recall rule refuses an archived note")
    // Undo puts the note back: its id is taken, so the same record comes out of the archive.
    try check(try store.insert(note("Trip fact 0", id: "f0"), now: now) == .conflict, "An archived note keeps its id")
    try check(try store.unarchive(id: "alfama", now: now.addingTimeInterval(1_000)), "A note comes back from the archive")
    let back = try store.record(id: "alfama")
    try check(back?.archived == nil && back?.expires == nil && back?.chat == "chat-7" && (back?.updatedAt ?? now) > now,
              "It comes back as the newest note, without the end date that passed")
    try check(try !store.unarchive(id: "alfama", now: now), "Bringing it back twice changes nothing")
    try check(try store.archive(owner: "writer", now: now.addingTimeInterval(1_001)).map(\.record.id) == ["f5"],
              "The note that came back stays, and the next oldest makes room")

    // An old file: version 1, written before the archive column.
    let oldURL = root.appendingPathComponent("old", isDirectory: true).appendingPathComponent("memory.sqlite")
    let samples: [MemoryRecord] = [
      note("Ana is a client", id: "ana", quote: "Ana is my client", chat: "chat-1"),
      note("Flies to Lisbon on Friday", id: "trip", expires: now.addingTimeInterval(86_400)),
      note("A waiting idea", id: "wait", owner: "planner", review: .unreviewed),
    ]
    var before: [MemoryRecord] = []
    do {
      let old = try MemoryStore(url: oldURL)
      for record in samples { _ = try old.insert(record, now: now) }
      before = try samples.compactMap { try old.record(id: $0.id) }
    }
    let downgraded = fillExec(oldURL, "ALTER TABLE records DROP COLUMN archived; PRAGMA user_version = 1;")
    try check(downgraded == SQLITE_OK && fillVersion(oldURL) == 1 && before.count == 3, "The check has a version 1 file")
    let opened = try MemoryStore(url: oldURL)
    let after = try samples.compactMap { try opened.record(id: $0.id) }
    try check(after == before && after.allSatisfy { $0.archived == nil }, "A version 1 file opens with every note unchanged")
    try check(fillVersion(oldURL) == 2, "It moves to version 2")
    let old = try opened.search("Ana", reader: writer, now: now).reveal(markingChat: { true }).map(\.id)
    try check(old == ["ana"] && (try opened.proposals(owner: "planner").map(\.id)) == ["wait"], "Its notes are found as before")
    let again = try MemoryStore(url: oldURL)
    try check(try samples.compactMap { try again.record(id: $0.id) } == before, "Opening it again changes nothing")
    let json = String(decoding: try JSONEncoder().encode(before[0]), as: UTF8.self)
    let decoded = try JSONDecoder().decode(MemoryRecord.self, from: Data(json.utf8))
    try check(!json.contains("archived") && decoded == before[0], "A record saved before the archive still decodes")

    // Recall caps.
    try check(MemoryPrompt.maxRecords == 4 && MemoryPrompt.characterBudget == 6_000, "A turn recalls at most 4 notes in 6,000 characters")
    let six: [MemoryRecord] = (0..<6).map { note(String(repeating: "y", count: 600), id: "s\($0)") }
    try check(MemoryTools.forTurn(topical: six, newest: lines160).count == 4, "A turn takes at most 4 notes")
    let block = MemoryPrompt.renderKept(six, now: now)
    try check(block?.ids == ["s0", "s1", "s2", "s3"] && (block?.text.count ?? 0) <= MemoryPrompt.characterBudget,
              "The memory block holds 4 notes within the budget")

    // A personal fact keeps the person's own words.
    let said = ["user: I'm vegetarian, by the way.", "Serein: Noted. You always skip meat."]
    let candidates = [
      RelayLearning.Candidate(text: "The person is vegetarian", quote: "I'm vegetarian"),
      RelayLearning.Candidate(text: "The person skips meat", quote: "You always skip meat"),
      RelayLearning.Candidate(text: "The person lives in Porto", quote: nil),
    ]
    let learned = RelayLearning.records(candidates, by: "planner", chat: "c", personal: false, known: [], waiting: 0, said: said, now: now)
    try check(learned.map(\.text) == ["The person is vegetarian"] && learned.first?.quote == "I'm vegetarian",
              "A learned fact is kept only with words the person said")
    try check(RelayLearning.records(candidates, by: "planner", chat: "c", personal: false, known: [], waiting: 0, now: now).count == 2,
              "With no excerpt a fact still needs a quote")
    try check(MemoryTools.verbatim("i like green tea", said: "Remember that I like green tea!") == "i like green tea",
              "A quote the person typed is kept")
    try check(MemoryTools.verbatim("adores matcha", said: "Remember that I like green tea!") == "Remember that I like green tea!",
              "A quote the person did not type gives way to their message")
    try check(MemoryTools.verbatim(nil, said: "  Remember I like tea ") == "Remember I like tea", "No quote: the message is the quote")
    try check(MemoryTools.verbatim(nil, said: "remember my key sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") == nil,
              "A secret-shaped message is never a quote")

    // The chat's way into the journal.
    try check(MemoryTools.asksToSeeMemory("Show me what you remember.") && MemoryTools.asksToSeeMemory("open your memory journal please"),
              "The person can ask to see the journal")
    try check(!MemoryTools.asksToSeeMemory("What do you remember about Lisbon?") && !MemoryTools.asksToSeeMemory("Remember that I like tea"),
              "A question for recall or a note to keep does not open it")

    // The journal's words.
    func entry(_ actor: String, _ action: RelayJournalEntry.Action, text: String = "", prior: String? = nil) -> RelayJournalEntry {
      RelayJournalEntry(at: now, actor: actor, action: action, noteID: "n1", text: text, priorText: prior)
    }
    try check(MemoryJournal.sentence(entry("relay", .added, text: "Prefers tea"), name: "Scout") == "Scout remembered “Prefers tea”.",
              "A saved note reads as a plain sentence")
    try check(MemoryJournal.sentence(entry("user", .removed, prior: "Prefers tea"), name: "Scout") == "You forgot “Prefers tea”.",
              "The sentence says who changed which note")
    try check(MemoryJournal.sentence(entry(MemoryJournal.endedActor, .removed, prior: "In Lisbon"), name: "Scout")
                == "“In Lisbon” reached its end date and moved to the archive."
                && MemoryJournal.sentence(entry(MemoryJournal.fullActor, .removed, prior: "In Lisbon"), name: "Scout").hasSuffix("to make room."),
              "An archived note says why it moved")
    let secret = "The key is sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    try check(!MemoryJournal.sentence(entry("user", .removed, prior: secret), name: "Scout").contains("sk-ant-ABCDEF"),
              "A sentence never shows a secret")
    let added = entry("relay", .added, text: "Prefers tea")
    try check(MemoryJournal.undoBlock(added, live: "Prefers tea") == nil, "Undo is offered while the note is as the change left it")
    try check(MemoryJournal.undoBlock(added, live: "Prefers coffee") == "Changed since" && MemoryJournal.undoBlock(added, live: nil) == "Already gone",
              "Undo of a saved note says why it is off")
    let changed = entry("relay", .refreshed, text: "Prefers coffee", prior: "Prefers tea")
    try check(MemoryJournal.undoBlock(changed, live: "Prefers coffee") == nil && MemoryJournal.undoBlock(changed, live: "Prefers water") == "Changed since",
              "Undo of an edit is off after a newer edit")
    let removed = entry("user", .removed, prior: "Prefers tea")
    try check(MemoryJournal.undoBlock(removed, live: nil) == nil && MemoryJournal.undoBlock(removed, live: "Prefers tea") == "Already back",
              "Undo of a removal is off once the note is back")
    try check(MemoryJournal.undoBlock(entry("user", .removed, prior: secret), live: nil) == "Can’t undo", "A removed secret cannot be put back")
    try check(MemoryJournal.matches(removed, query: " TEA ") && !MemoryJournal.matches(removed, query: "coffee") && MemoryJournal.matches(removed, query: ""),
              "Search matches a change by its words")
    try check(MemoryJournal.searchAbove == 6, "Search shows past 6 changes")
    try check(MemoryJournal.gauge(MemoryFill.Usage(lines: 100, bytes: 0)) == "Notes 50% full"
                && MemoryJournal.gauge(MemoryFill.Usage(lines: 170, bytes: 0)).hasPrefix("Notes 85% full."),
              "The gauge is one short line")
    try check(MemoryJournal.source(note("x", chat: "chat-1")) == "From a chat" && MemoryJournal.source(note("x")) == "You said this",
              "A note's chip names where it came from")
  }
}
#endif
