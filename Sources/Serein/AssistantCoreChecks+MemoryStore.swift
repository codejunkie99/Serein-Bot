#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  // MARK: unit 6

  static func memoryStore(_ check: Check) throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("serein-memory-\(UUID().uuidString)", isDirectory: true)
    defer { try? files.removeItem(at: root) }
    let url = root.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("memory.sqlite")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try MemoryStore(url: url)

    func mode(_ path: String) -> Int {
      ((try? files.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    try check(mode(url.deletingLastPathComponent().path) == 0o700, "The memory folder is 0700")
    try check(mode(url.path) == 0o600, "The memory file is 0600")

    let planner = MemoryReader(assistant: "planner", teams: ["trip"])
    let scout = MemoryReader(assistant: "scout", teams: ["trip"], apps: ["gmail"])
    let scoutRevoked = MemoryReader(assistant: "scout", teams: ["trip"])
    let writer = MemoryReader(assistant: "writer")
    let main = MemoryReader(assistant: RelayTeam.mainID)
    func note(
      _ text: String, id: String = UUID().uuidString, owner: String = "planner", scope: MemoryScope = .person,
      source: MemorySource = .person, app: String? = nil, at time: Date? = nil, expires: Date? = nil,
      review: MemoryRecord.Review = .confirmed, personal: Bool = false
    ) -> MemoryRecord {
      MemoryRecord(
        id: id, text: text, owner: owner, scope: scope,
        provenance: MemoryProvenance(source: source, reference: "chat-1", app: app), createdAt: time ?? now,
        expires: expires, review: review, personal: personal)
    }
    func ids(_ query: String, _ reader: MemoryReader, at time: Date? = nil) throws -> [String] {
      let hits = try store.search(query, reader: reader, now: time ?? now)
      return hits.reveal(markingChat: { true }).map(\.id)
    }
    func entry(_ write: MemoryWrite) -> String? {
      if case .done(let entry) = write { return entry }
      return nil
    }

    // Insert and search.
    try check(entry(try store.insert(note("Ana is a client", id: "ana"), now: now)) != nil, "A new record is saved")
    try check(try ids("What do you remember about Ana?", writer) == ["ana"], "Search finds a record by a word")
    try check(try store.insert(note("Someone else", id: "ana"), now: now) == .conflict, "A taken id is a conflict")
    _ = try store.insert(note("We fly to Lisbon on Friday", id: "lisbon"), now: now)
    try check(try ids("Lisbn", writer) == ["lisbon"], "Search finds a typo by trigram")
    try check(try ids("lisbon", writer) == ["lisbon"], "Search finds a whole word")
    _ = try store.insert(note("私は東京都に住んでいます", id: "tokyo"), now: now)
    try check(try ids("東京都", writer) == ["tokyo"], "Search finds CJK text by trigram")
    try check(try ids("the hotel whether", writer).isEmpty, "One common piece of a word finds nothing")
    _ = try store.insert(note("Café near the river", id: "cafe"), now: now)
    try check(try ids("cafe", writer) == ["cafe"], "Accents do not matter in a search")
    let odd = try? store.search("\"Ana\" OR NEAR( * col:x ^ -", reader: writer, now: now)
    try check(odd != nil, "Search syntax in a query is only text")

    // Compare-and-set.
    guard let ana = try store.record(id: "ana") else { throw SereinError.invalid("FAIL: The saved record reads back") }
    try check(ana.provenance.reference == "chat-1" && ana.review == .confirmed, "A record reads back with its fields")
    let firstEdit = try store.update(id: "ana", expected: ana.updatedAt, edit: MemoryEdit(text: "Ana is a former client"), now: now.addingTimeInterval(1))
    try check(entry(firstEdit) != nil, "An edit with the current time lands")
    let lostEdit = try store.update(id: "ana", expected: ana.updatedAt, edit: MemoryEdit(text: "Ana is a lost client"), now: now.addingTimeInterval(2))
    try check(lostEdit == .conflict && lostEdit.words == "That note changed. Try again.", "An edit with an old time is a plain conflict")
    let afterEdit = try store.record(id: "ana")
    try check(afterEdit?.text == "Ana is a former client", "The lost edit changed nothing")
    try check(afterEdit?.provenance == ana.provenance && afterEdit?.createdAt == ana.createdAt, "An edit keeps the provenance")
    try check(try ids("former", writer) == ["ana"], "The index follows an edit")
    try check(try store.update(id: "nobody", expected: now, edit: MemoryEdit(enabled: false), now: now) == .missing, "An edit of an unknown id is missing")

    // Undo from the log.
    if let undoEdit = entry(firstEdit) {
      try check(entry(try store.undo(entry: undoEdit, now: now.addingTimeInterval(3))) != nil, "Undo reverses an edit")
    }
    try check(try store.record(id: "ana")?.text == "Ana is a client", "Undo puts back the text before the edit")
    try check(try ids("former", writer).isEmpty, "The index follows the undo")
    let saved = try store.insert(note("Undo me soon", id: "undo-me"), now: now)
    if let undoSave = entry(saved) {
      try check(entry(try store.undo(entry: undoSave, now: now.addingTimeInterval(1))) != nil, "Undo removes a saved record")
    }
    let undoneRecord = try store.record(id: "undo-me")
    let undoneHits = try ids("undo", writer)
    try check(undoneRecord == nil && undoneHits.isEmpty, "An undone record is gone from search")

    // Forget.
    let word = "Zanzibarquokka"
    _ = try store.insert(note(word + " is the code word", id: "code"), now: now)
    if let code = try store.record(id: "code") {
      _ = try store.update(id: "code", expected: code.updatedAt, edit: MemoryEdit(text: word + " is the new code word"), now: now.addingTimeInterval(1))
    }
    try check(try ids(word, writer) == ["code"], "The code word is found before forget")
    let firstForget = try store.forget(id: "code", now: now.addingTimeInterval(2))
    let forgottenHits = try ids(word, writer)
    try check(entry(firstForget) != nil && forgottenHits.isEmpty, "Forget removes the record from search")
    try check(try store.isTombstoned(word + " IS the new code word!"), "Forget keeps a tombstone")
    if let undoForget = entry(firstForget) {
      try check(entry(try store.undo(entry: undoForget, now: now.addingTimeInterval(5))) != nil, "Undo within 10 seconds brings it back")
    }
    try check(try ids(word, writer) == ["code"], "The record is found again after undo")
    let stillTombstoned = try store.isTombstoned(word + " is the new code word")
    try check(!stillTombstoned, "Undo of a forget drops its tombstone")
    let secondForget = try store.forget(id: "code", now: now.addingTimeInterval(6))
    if let late = entry(secondForget) {
      try check(try store.undo(entry: late, now: now.addingTimeInterval(17)) == .missing, "Undo after 10 seconds is gone")
    }
    try store.prune(now: now.addingTimeInterval(17))
    var bytes = (try? Data(contentsOf: url)) ?? Data()
    if let wal = try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")) { bytes.append(wal) }
    try check(!bytes.isEmpty && bytes.range(of: Data(word.utf8)) == nil, "The forgotten text is not left in the file")
    try check(bytes.range(of: Data(word.lowercased().utf8)) == nil, "The forgotten word is not left in the index")
    let relearned = note("zanzibarquokka is the NEW code word.", owner: "scout", scope: .assistant("scout"), source: .page, review: .unreviewed)
    try check(try store.insert(relearned, now: now.addingTimeInterval(18)) == .blocked, "A tombstone blocks learning the fact again")
    try check(entry(try store.insert(note(word + " is the new code word"), now: now.addingTimeInterval(18))) != nil, "The person may say it again")
    try store.tombstone("The person hates jazz", reason: .declined, now: now)
    let declined = note("The person hates jazz", owner: "scout", scope: .assistant("scout"), source: .assistant, review: .unreviewed)
    try check(try store.insert(declined, now: now) == .blocked, "A declined proposal is not proposed again")

    // Move the old notes in.
    let notes: [String: [RelayNote]] = [
      "planner": [RelayNote(id: "a", text: "Old note A", createdAt: now), RelayNote(id: "b", text: "Old note B", createdAt: now)],
      "scout": [RelayNote(id: "a", text: "Old note C", createdAt: now)],
    ]
    let plan = MemoryMigration.plan(notes)
    let before = try store.count()
    let added = try store.migrate(plan)
    let again = try store.migrate(plan)
    try check(added == 3 && again == 0, "Moving the notes twice adds them once")
    try check(try store.count() == before + 3, "Moving twice gives the same count")
    let present = try store.present(ids: plan.map(\.id))
    try check(MemoryMigration.isComplete(plan, present: present), "Every moved row is there")
    try check(try ids("old note", scout) == ["note:scout:a"], "A moved note stays private to its assistant")

    // Recall rules in search.
    _ = try store.insert(note("Casa Azulejo sleeps eight", id: "casa", owner: "scout", scope: .assistant("scout")), now: now)
    _ = try store.insert(note("Trip budget is 4000 euros", id: "budget", scope: .team("trip")), now: now)
    _ = try store.insert(
      note("Invoice from Ana arrived", id: "invoice", owner: "scout", scope: .assistant("scout"), source: .mail, app: "gmail", personal: true),
      now: now)
    _ = try store.insert(note("Window seats preferred", id: "proposal", owner: "scout", scope: .assistant("scout"), source: .page, review: .unreviewed), now: now)
    _ = try store.insert(note("Ferry leaves at nine", id: "expired", expires: now.addingTimeInterval(-1)), now: now)
    let ownHits = try ids("azulejo", scout)
    let otherHits = try ids("azulejo", planner)
    try check(ownHits == ["casa"] && otherHits.isEmpty, "A private record reaches only its assistant")
    try check(try ids("azulejo", main).isEmpty, "Serein does not read another assistant's private records")
    let memberHits = try ids("budget", planner)
    let outsiderHits = try ids("budget", writer)
    try check(memberHits == ["budget"] && outsiderHits.isEmpty, "A team record reaches members only")
    try check(try ids("budget", main) == ["budget"], "Serein reads every team record")
    try check(try ids("invoice", scout) == ["invoice"], "An assistant reads what it learned from an app it holds")
    try check(try ids("invoice", scoutRevoked).isEmpty, "Removing the app silences what was learned from it")
    try check(try ids("invoice", planner).isEmpty, "Another assistant cannot read what one learned")
    try check(try ids("window seats", scout).isEmpty, "A proposal is not recalled")
    try check(try store.proposals(owner: "scout").map(\.id) == ["proposal"], "The proposal waits for review")
    try check(try ids("ferry", writer).isEmpty, "An expired record is not recalled")
    let sealed = try store.search("invoice", reader: scout, now: now)
    try check(sealed.needsMark && sealed.unmarked.isEmpty, "A personal record stays sealed in the result")
    try check(sealed.reveal(markingChat: { false }).isEmpty, "A failed mark returns nothing")
    try check(try store.whoKnows("azulejo invoice", reader: planner, now: now) == ["scout": 2], "Who knows gives the owner and a count, never text")
    if let cafe = try store.record(id: "cafe") {
      _ = try store.update(id: "cafe", expected: cafe.updatedAt, edit: MemoryEdit(enabled: false), now: now.addingTimeInterval(1))
    }
    try check(try ids("cafe", writer).isEmpty, "An off record is not recalled")
    let newest = try store.search("", reader: writer, now: now)
    try check(!newest.isEmpty, "An empty query gives the newest records")

    // The cap.
    for number in 0..<60 {
      _ = try store.insert(note("Hotel option \(number) near Alfama", at: now.addingTimeInterval(Double(number))), now: now)
    }
    try check(try store.search("alfama", reader: writer, now: now.addingTimeInterval(100)).count == MemoryStore.recallLimit, "A search returns at most 40 records")
    try check(try store.search("alfama", reader: writer, now: now.addingTimeInterval(100), limit: 500).count == MemoryStore.recallLimit, "A larger limit is still 40")

    // The file opens again with the same rows.
    let total = try store.count()
    let reopened = try MemoryStore(url: url)
    try check(try reopened.count() == total, "The store opens again with every record")

    // The caps, the archive, an old file and the journal's words (AssistantCoreChecks+MemoryFill.swift).
    try memoryFill(check)
  }
}
#endif
