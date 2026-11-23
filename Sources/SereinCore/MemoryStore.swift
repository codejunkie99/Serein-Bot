import Foundation
import SQLite3

/// What one write to the memory store did.
public enum MemoryWrite: Equatable, Sendable {
  /// The change landed. `entry` names the log row that `MemoryStore.undo` reverses (for an
  /// undo: the entry it reversed).
  case done(entry: String)
  /// Another write changed the record first (the compare-and-set lost), or the id is taken.
  case conflict
  /// No such record, or no such log entry, or its time for Undo is over.
  case missing
  /// Learning proposed a fact the person forgot or declined before (a tombstone matched).
  case blocked

  /// The sentence the person reads. nil for `done`.
  public var words: String? {
    switch self {
    case .done: return nil
    case .conflict: return "That note changed. Try again."
    case .missing: return "I cannot find that note."
    case .blocked: return "You told me to forget that."
    }
  }
}

/// Reciprocal rank fusion: each list adds 1 / (k + rank) to a record's score. A record found by
/// both indexes goes up. Ties go to the newer record, then to the smaller id.
public enum MemoryRank {
  public static let k = 60

  public static func fuse(_ lists: [[MemoryRecord]], limit: Int) -> [MemoryRecord] {
    var score: [String: Double] = [:]
    var byID: [String: MemoryRecord] = [:]
    for list in lists {
      for (index, record) in list.enumerated() {
        let add = 1.0 / Double(k + index + 1)
        score[record.id, default: 0] += add
        if byID[record.id] == nil { byID[record.id] = record }
      }
    }
    let all = Array(byID.values)
    let sorted = all.sorted { a, b in
      let left = score[a.id] ?? 0
      let right = score[b.id] ?? 0
      if left != right { return left > right }
      if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
      return a.id < b.id
    }
    return Array(sorted.prefix(max(0, limit)))
  }
}

/// How search text becomes index queries. Every word goes in quotes, so text the person or a
/// model typed is never index syntax.
enum MemoryQuery {
  static let maxWords = 16
  static let maxTrigrams = 48

  /// Distinct lowercase words of `query`, at most `maxWords`. A one-letter ASCII word is dropped.
  static func words(_ query: String) -> [String] {
    let folded = query.precomposedStringWithCanonicalMapping.lowercased()
    var out: [String] = []
    var seen = Set<String>()
    for part in folded.components(separatedBy: CharacterSet.alphanumerics.inverted) {
      if part.isEmpty { continue }
      if part.count < 2 && part.allSatisfy(\.isASCII) { continue }
      if !seen.insert(part).inserted { continue }
      out.append(part)
      if out.count == maxWords { break }
    }
    return out
  }

  /// The word index query: each word as a prefix, joined by OR.
  static func wordMatch(_ words: [String]) -> String {
    words.map { "\"" + $0 + "\"*" }.joined(separator: " OR ")
  }

  /// The three-letter pieces of `word`, by Unicode scalar (as the trigram index counts them).
  static func trigrams(_ word: String) -> [String] {
    let scalars = Array(word.unicodeScalars)
    guard scalars.count >= 3 else { return [] }
    var out: [String] = []
    for first in 0...(scalars.count - 3) {
      var view = String.UnicodeScalarView()
      view.append(contentsOf: scalars[first..<(first + 3)])
      out.append(String(view))
    }
    return out
  }

  /// The trigram index query: each distinct piece in quotes, joined by OR. nil when no word has
  /// three letters.
  static func trigramMatch(_ words: [String]) -> String? {
    var grams: [String] = []
    var seen = Set<String>()
    for word in words {
      for gram in trigrams(word) {
        if seen.insert(gram).inserted { grams.append(gram) }
      }
    }
    let kept = grams.prefix(maxTrigrams)
    guard !kept.isEmpty else { return nil }
    return kept.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
  }

  /// Whether a trigram hit is near one query word: at least half of the word's pieces are in the
  /// record. One piece is enough for a word in a script without spaces (CJK and others above
  /// U+2E80). This keeps a common piece ("the") from bringing in unrelated records.
  static func closeEnough(_ record: MemoryRecord, words: [String]) -> Bool {
    let haystack = body(record).lowercased()
    for word in words {
      let grams = trigrams(word)
      if grams.isEmpty { continue }
      var hits = 0
      for gram in grams where haystack.contains(gram) { hits += 1 }
      let spaceless = word.unicodeScalars.contains { $0.value >= 0x2E80 }
      let need = spaceless ? 1 : (grams.count + 1) / 2
      if hits >= need { return true }
    }
    return false
  }

  /// The indexed text of a record: its text and the person's words.
  static func body(_ record: MemoryRecord) -> String {
    (record.text + "\n" + (record.quote ?? "")).precomposedStringWithCanonicalMapping
  }
}

/// Serein's shared memory on disk (`relay/memory/memory.sqlite`): records, two full-text indexes,
/// tombstones and an Undo log. One connection, opened once, in WAL mode with `secure_delete`;
/// the folder is 0700 and the file 0600. Statements are prepared once and reused. Every call
/// takes a lock, so it is safe from any thread; call it off the main thread.
///
/// - `records_fts` (`unicode61`, accents removed) finds words. `records_tri` (`trigram`) finds
///   pieces of words, for CJK text and typos. Both change in the same transaction as `records`.
/// - `search` ranks each index by BM25, keeps what `MemoryRecall.eligible` allows, merges the two
///   lists by reciprocal rank and returns at most `recallLimit` records.
/// - `update` is a compare-and-set on `updated`. `undo` reverses one log entry.
/// - `forget` deletes the record and its log rows, keeps a digest (`MemoryTombstone`), and
///   rewrites the indexes and the WAL file. Its own Undo copy lives `UndoToken.removalWindow`
///   seconds; `prune` then deletes it, so the text leaves the disk.
public final class MemoryStore: @unchecked Sendable {
  /// Where the store lives under the Library root.
  public static let relativePath = "relay/memory/memory.sqlite"
  /// The most records one search returns.
  public static let recallLimit = 40
  /// How many candidates each index gives before the recall rules filter them.
  static let window = 200
  /// How long Undo for a saved or edited record lasts.
  public static let logKeep: TimeInterval = 30 * 86_400
  /// The most log rows kept.
  static let logLimit = 1_000

  public let url: URL
  private var db: OpaquePointer?
  private var cache: [String: OpaquePointer] = [:]
  private let lock = NSLock()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private enum Value {
    case text(String)
    case int(Int64)
    case null
  }
  private enum LogKind: String {
    case insert, update, forget
  }
  private struct Found {
    var seq: Int64
    var record: MemoryRecord
  }
  private struct LogRow {
    var recordID: String
    var kind: LogKind
    var prior: MemoryRecord?
    var after: Int64?
    var expires: Int64
  }
  /// A unique key was already taken.
  private struct Taken: Error {}

  /// Opens or makes the store at `url`. Makes the folder (0700) and the file (0600) when needed.
  public init(url: URL) throws {
    self.url = url
    let files = FileManager.default
    let folder = url.deletingLastPathComponent()
    try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    if !files.fileExists(atPath: url.path) {
      guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw SereinError.invalid("Memory could not make its file.")
      }
    }
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
      if let handle { sqlite3_close(handle) }
      throw SereinError.invalid("Memory could not open its file.")
    }
    db = opened
    sqlite3_busy_timeout(opened, 5000)
    do {
      try exec(Schema.pragmas)
      try exec(Schema.tables)
      try upgrade()
    } catch {
      sqlite3_close(opened)
      db = nil
      throw error
    }
    for suffix in ["-wal", "-shm"] {
      let side = url.path + suffix
      if files.fileExists(atPath: side) {
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: side)
      }
    }
  }

  deinit {
    for statement in cache.values { sqlite3_finalize(statement) }
    sqlite3_close(db)
  }

  // MARK: Writes

  /// Saves a new record. `.blocked` when it is learned and matches a tombstone; `.conflict` when
  /// its id is taken. The log keeps an entry for Undo (`logKeep`).
  public func insert(_ record: MemoryRecord, now: Date = Date()) throws -> MemoryWrite {
    lock.lock()
    defer { lock.unlock() }
    let scrub = try pruneLocked(now: now)
    let outcome = try transaction { () throws -> MemoryWrite in
      if record.provenance.source.isLearned {
        let blocked = try self.tombstonedLocked(record.text)
        if blocked { return .blocked }
      }
      do {
        _ = try self.insertRow(record, sql: Schema.insertRecord)
      } catch is Taken {
        return .conflict
      }
      let entry = UUID().uuidString
      try self.addLog(
        entry: entry, recordID: record.id, kind: .insert, prior: nil, after: record.updatedAt, now: now,
        keep: MemoryStore.logKeep)
      return .done(entry: entry)
    }
    if scrub { try? scrubLocked() }
    return outcome
  }

  /// Applies `edit` to the record `id` only while its `updated` time is still `expected`. A lost
  /// race gives `.conflict`, and nothing changes. Provenance columns are never written.
  public func update(id: String, expected: Date, edit: MemoryEdit, now: Date = Date()) throws -> MemoryWrite {
    lock.lock()
    defer { lock.unlock() }
    let scrub = try pruneLocked(now: now)
    let outcome = try transaction { () throws -> MemoryWrite in
      guard let found = try self.currentLocked(id: id) else { return .missing }
      let before = MemoryClock.toMillis(found.record.updatedAt)
      guard before == MemoryClock.toMillis(expected) else { return .conflict }
      let next = try found.record.edited(edit, now: now)
      let changed = try self.writeFields(next, seq: found.seq, expected: before)
      guard changed == 1 else { return .conflict }
      if next.text != found.record.text { try self.reindex(seq: found.seq, record: next) }
      let entry = UUID().uuidString
      try self.addLog(
        entry: entry, recordID: id, kind: .update, prior: found.record, after: next.updatedAt, now: now,
        keep: MemoryStore.logKeep)
      return .done(entry: entry)
    }
    if scrub { try? scrubLocked() }
    return outcome
  }

  /// Deletes the record `id` from the table and both indexes, deletes its older log rows, keeps
  /// a digest of its text, then rewrites the indexes and the WAL file. Undo works for
  /// `UndoToken.removalWindow` seconds.
  public func forget(id: String, reason: MemoryTombstone.Reason = .forgotten, now: Date = Date()) throws
    -> MemoryWrite
  {
    lock.lock()
    defer { lock.unlock() }
    _ = try pruneLocked(now: now)
    let outcome = try transaction { () throws -> MemoryWrite in
      guard let found = try self.currentLocked(id: id) else { return .missing }
      try self.change(Schema.deleteRecord, [.int(found.seq)])
      try self.unindex(seq: found.seq)
      try self.change(Schema.dropLogFor, [.text(id)])
      try self.addTombstone(found.record.text, reason: reason, now: now)
      let entry = UUID().uuidString
      try self.addLog(
        entry: entry, recordID: id, kind: .forget, prior: found.record, after: nil, now: now,
        keep: UndoToken.removalWindow)
      return .done(entry: entry)
    }
    if case .done = outcome { try? scrubLocked() }
    return outcome
  }

  /// Reverses one log entry: removes a saved record, puts back the fields before an edit, or
  /// brings back a forgotten record (and drops its tombstone). `.conflict` when the record
  /// changed after that entry; `.missing` when the entry is gone or its time is over.
  public func undo(entry: String, now: Date = Date()) throws -> MemoryWrite {
    lock.lock()
    defer { lock.unlock() }
    return try transaction { () throws -> MemoryWrite in
      guard let log = try self.logRow(entry), log.expires > MemoryClock.toMillis(now) else { return .missing }
      let found = try self.currentLocked(id: log.recordID)
      switch log.kind {
      case .insert:
        guard let found else { return .missing }
        guard MemoryClock.toMillis(found.record.updatedAt) == log.after else { return .conflict }
        try self.change(Schema.deleteRecord, [.int(found.seq)])
        try self.unindex(seq: found.seq)
      case .update:
        guard let found, let prior = log.prior else { return .missing }
        let current = MemoryClock.toMillis(found.record.updatedAt)
        guard current == log.after else { return .conflict }
        var restored = prior
        restored.updatedAt = MemoryClock.fromMillis(max(MemoryClock.toMillis(now), current + 1))
        let changed = try self.writeFields(restored, seq: found.seq, expected: current)
        guard changed == 1 else { return .conflict }
        try self.reindex(seq: found.seq, record: restored)
      case .forget:
        guard found == nil else { return .conflict }
        guard let prior = log.prior else { return .missing }
        do {
          _ = try self.insertRow(prior, sql: Schema.insertRecord)
        } catch is Taken {
          return .conflict
        }
        try self.change(Schema.dropTombstone, [.text(MemoryTombstone.digest(prior.text))])
      }
      try self.change(Schema.dropLog, [.text(entry)])
      return .done(entry: entry)
    }
  }

  /// Moves planned rows in (`MemoryMigration.plan`) with `INSERT OR IGNORE`, in one transaction.
  /// Returns how many rows were new, so a second run returns 0 and changes nothing.
  public func migrate(_ records: [MemoryRecord]) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    return try transaction { () throws -> Int in
      var added = 0
      for record in records {
        let seq = try self.insertRow(record, sql: Schema.migrateRecord)
        if seq != nil { added += 1 }
      }
      return added
    }
  }

  /// Moves into the archive the notes of `owner` that must leave now (`MemoryFill.moving`): each
  /// one past its end date, then the oldest while its notes are over a cap. One transaction, so
  /// a quit midway moves all of them or none; nothing is deleted either way, and a second pass
  /// finds nothing left to move. Returns what moved, for the journal.
  public func archive(owner: String, now: Date = Date()) throws -> [MemoryFill.Move] {
    lock.lock()
    defer { lock.unlock() }
    return try transaction { () throws -> [MemoryFill.Move] in
      let live = try self.rows(Schema.ownedLive, [.text(owner)])
      let moves = MemoryFill.moving(live, now: now)
      let stamp = Value.int(MemoryClock.toMillis(now))
      for move in moves { try self.change(Schema.archiveOne, [stamp, .text(move.record.id)]) }
      return moves
    }
  }

  /// Brings the note `id` back from the archive, as the newest note and without an end date that
  /// passed. False when it is not in the archive.
  @discardableResult
  public func unarchive(id: String, now: Date = Date()) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return try change(Schema.unarchiveOne, [.int(MemoryClock.toMillis(now)), .text(id)]) == 1
  }

  /// The notes file of `owner`: its notes the person has seen, the archive aside, oldest change
  /// first. For the fill gauge (`MemoryFill.usage`); no recall rules, and no model reads it.
  public func notes(owner: String) throws -> [MemoryRecord] {
    lock.lock()
    defer { lock.unlock() }
    return try rows(Schema.ownedLive, [.text(owner)])
  }

  /// Keeps a digest of `text`, so learning never proposes it again (for a proposal the person
  /// declined before it was saved).
  public func tombstone(_ text: String, reason: MemoryTombstone.Reason, now: Date = Date()) throws {
    lock.lock()
    defer { lock.unlock() }
    try addTombstone(text, reason: reason, now: now)
  }

  /// Deletes log rows whose time is over. When one held a forgotten record, the indexes and the
  /// WAL file are rewritten too. Writes call this first; the host may also call it after the
  /// Undo window of a forget.
  public func prune(now: Date = Date()) throws {
    lock.lock()
    defer { lock.unlock() }
    let scrub = try pruneLocked(now: now)
    if scrub { try? scrubLocked() }
  }

  // MARK: Reads

  /// The records `reader` may recall for `query`, best first, at most `limit` (never more than
  /// `recallLimit`). An empty query gives the newest records. Personal records stay sealed in
  /// the result until `MemoryHits.reveal`.
  public func search(_ query: String, reader: MemoryReader, now: Date = Date(), limit: Int = MemoryStore.recallLimit)
    throws -> MemoryHits
  {
    lock.lock()
    defer { lock.unlock() }
    let cap = min(max(limit, 0), MemoryStore.recallLimit)
    let nowValue = Value.int(MemoryClock.toMillis(now))
    let readerValue = Value.text(reader.assistant)
    let windowValue = Value.int(Int64(MemoryStore.window))
    let words = MemoryQuery.words(query)
    if words.isEmpty {
      let newest = try rows(Schema.newest, [.null, nowValue, readerValue, windowValue])
      let kept = MemoryRecall.filter(newest, for: reader, now: now)
      return MemoryHits(Array(kept.prefix(cap)))
    }
    let wordMatch = Value.text(MemoryQuery.wordMatch(words))
    let wordRows = try rows(Schema.searchWords, [wordMatch, nowValue, readerValue, windowValue])
    let wordKept = MemoryRecall.filter(wordRows, for: reader, now: now)
    var trigramKept: [MemoryRecord] = []
    if let match = MemoryQuery.trigramMatch(words) {
      let trigramRows = try rows(Schema.searchTrigrams, [.text(match), nowValue, readerValue, windowValue])
      let allowed = MemoryRecall.filter(trigramRows, for: reader, now: now)
      trigramKept = allowed.filter { MemoryQuery.closeEnough($0, words: words) }
    }
    return MemoryHits(MemoryRank.fuse([wordKept, trigramKept], limit: cap))
  }

  /// Other assistants with matching records that `reader` cannot read: owner id and count.
  /// Never the text. For "Planner has more notes about her".
  public func whoKnows(_ query: String, reader: MemoryReader, now: Date = Date()) throws -> [String: Int] {
    lock.lock()
    defer { lock.unlock() }
    let words = MemoryQuery.words(query)
    guard !words.isEmpty else { return [:] }
    let nowValue = Value.int(MemoryClock.toMillis(now))
    let readerValue = Value.text(reader.assistant)
    let windowValue = Value.int(Int64(MemoryStore.window))
    var found = try rows(Schema.othersWords, [.text(MemoryQuery.wordMatch(words)), nowValue, readerValue, windowValue])
    if let match = MemoryQuery.trigramMatch(words) {
      let trigramRows = try rows(Schema.othersTrigrams, [.text(match), nowValue, readerValue, windowValue])
      found += trigramRows.filter { MemoryQuery.closeEnough($0, words: words) }
    }
    var seen = Set<String>()
    var counts: [String: Int] = [:]
    for record in found {
      if MemoryRecall.eligible(record, for: reader, now: now) { continue }
      if !seen.insert(record.id).inserted { continue }
      counts[record.owner, default: 0] += 1
    }
    return counts
  }

  /// One record by id, with no recall rules (for the host's own checks and for edits).
  public func record(id: String) throws -> MemoryRecord? {
    lock.lock()
    defer { lock.unlock() }
    return try currentLocked(id: id)?.record
  }

  /// The proposals that wait for the person's review, newest first.
  public func proposals(owner: String, limit: Int = RelayLearning.maxProposals) throws -> [MemoryRecord] {
    lock.lock()
    defer { lock.unlock() }
    return try rows(Schema.proposals, [.text(owner), .int(Int64(max(0, limit)))])
  }

  /// How many records the store holds.
  public func count() throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    return try query(Schema.countRecords, []) { (statement: OpaquePointer) throws -> Int in
      guard sqlite3_step(statement) == SQLITE_ROW else { throw self.failure("Memory could not read that.") }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  /// The host put these records into a prompt or a recall answer: each one's use count goes up
  /// by one, and its last use is now. Only the host calls this, never for a model's citation, so
  /// a planted page cannot lift a record (SPEC 4.7). `updated` does not move.
  public func markRendered(_ ids: [String], now: Date = Date()) throws {
    guard !ids.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    let stamp = Value.int(MemoryClock.toMillis(now))
    let unique = Array(Set(ids))
    try transaction { () throws -> Void in
      for id in unique { try self.change(Schema.markUsed, [stamp, .text(id)]) }
    }
  }

  /// Forgets every learned record made in `chat` (SPEC 4.9, the chat-delete cascade): each one
  /// leaves the table and both indexes with its log rows and keeps a `sourceDeleted` digest, so
  /// learning never proposes it again. What the person said, and moved notes, stay. Returns how
  /// many went. It reads `window` records at a time until none is left, so a chat with more than
  /// `window` learned records forgets them all.
  public func forgetLearned(chat: String, now: Date = Date()) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    _ = try pruneLocked(now: now)
    let gone = try transaction { () throws -> Int in
      var count = 0
      while true {
        let found = try self.rows(Schema.learnedInChat, [.text(chat), .int(Int64(MemoryStore.window))])
        var removed = 0
        for record in found {
          guard let current = try self.currentLocked(id: record.id) else { continue }
          try self.change(Schema.deleteRecord, [.int(current.seq)])
          try self.unindex(seq: current.seq)
          try self.change(Schema.dropLogFor, [.text(record.id)])
          try self.addTombstone(record.text, reason: .sourceDeleted, now: now)
          removed += 1
        }
        count += removed
        // A short batch was the last one; a batch that removed nothing cannot shrink the rest.
        if found.count < MemoryStore.window || removed == 0 { break }
      }
      return count
    }
    if gone > 0 { try? scrubLocked() }
    return gone
  }

  /// The ids of `ids` that are in the store (for the migration's id check).
  public func present(ids: [String]) throws -> Set<String> {
    lock.lock()
    defer { lock.unlock() }
    var out = Set<String>()
    for id in ids {
      let here = try query(Schema.hasRecord, [.text(id)]) { (statement: OpaquePointer) throws -> Bool in
        sqlite3_step(statement) == SQLITE_ROW
      }
      if here { out.insert(id) }
    }
    return out
  }

  /// Whether the person forgot or declined a fact with these words before.
  public func isTombstoned(_ text: String) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return try tombstonedLocked(text)
  }

  // MARK: Steps (the caller holds the lock)

  /// Moves an older file to `Schema.version`, each step once and in its own transaction (SPEC
  /// 8.2), so a quit between two steps leaves a whole file at the step it reached. Step 1: the
  /// new columns, the outside mark for the rows whose source is outside, the indexes, and the
  /// trigger that refuses a change to a fixed column (the backfill runs before the trigger
  /// exists). Step 2: the archive column; every row there already stays as it is, not archived.
  /// A file from a newer build is left as it is.
  private func upgrade() throws {
    let version = try query(Schema.readVersion, []) { (statement: OpaquePointer) throws -> Int64 in
      guard sqlite3_step(statement) == SQLITE_ROW else { throw self.failure("Memory could not read that.") }
      return sqlite3_column_int64(statement, 0)
    }
    if version < 1 { try transaction { () throws -> Void in try self.exec(Schema.upgradeOne) } }
    if version < 2 { try transaction { () throws -> Void in try self.exec(Schema.upgradeTwo) } }
  }

  private func insertRow(_ record: MemoryRecord, sql: String) throws -> Int64? {
    let changed = try change(sql, values(record))
    guard changed == 1 else { return nil }
    let seq = sqlite3_last_insert_rowid(db)
    try index(seq: seq, record: record)
    return seq
  }

  /// Writes the fields an edit may change, only while `updated` is still `expected`.
  private func writeFields(_ record: MemoryRecord, seq: Int64, expected: Int64) throws -> Int {
    var values: [Value] = []
    values.append(.text(record.text))
    values.append(.text(record.scope.kind))
    values.append(.text(record.scope.id))
    values.append(.int(MemoryClock.toMillis(record.updatedAt)))
    values.append(MemoryStore.optionalDate(record.expires))
    values.append(.int(record.enabled ? 1 : 0))
    values.append(.text(record.review.rawValue))
    values.append(.int(seq))
    values.append(.int(expected))
    return try change(Schema.updateRecord, values)
  }

  private func index(seq: Int64, record: MemoryRecord) throws {
    let body = MemoryQuery.body(record)
    try change(Schema.indexWords, [.int(seq), .text(body)])
    try change(Schema.indexTrigrams, [.int(seq), .text(body)])
  }

  private func unindex(seq: Int64) throws {
    try change(Schema.unindexWords, [.int(seq)])
    try change(Schema.unindexTrigrams, [.int(seq)])
  }

  private func reindex(seq: Int64, record: MemoryRecord) throws {
    try unindex(seq: seq)
    try index(seq: seq, record: record)
  }

  private func addTombstone(_ text: String, reason: MemoryTombstone.Reason, now: Date) throws {
    let digest = MemoryTombstone.digest(text)
    try change(Schema.addTombstone, [.text(digest), .text(reason.rawValue), .int(MemoryClock.toMillis(now))])
  }

  private func tombstonedLocked(_ text: String) throws -> Bool {
    let digest = MemoryTombstone.digest(text)
    return try query(Schema.hasTombstone, [.text(digest)]) { (statement: OpaquePointer) throws -> Bool in
      sqlite3_step(statement) == SQLITE_ROW
    }
  }

  private func addLog(
    entry: String, recordID: String, kind: LogKind, prior: MemoryRecord?, after: Date?, now: Date,
    keep: TimeInterval
  ) throws {
    var priorValue = Value.null
    if let prior {
      let data = try JSONEncoder().encode(prior)
      priorValue = Value.text(String(decoding: data, as: UTF8.self))
    }
    let afterValue = MemoryStore.optionalDate(after)
    let at = MemoryClock.toMillis(now)
    let expires = MemoryClock.toMillis(now.addingTimeInterval(keep))
    let values: [Value] = [
      .text(entry), .text(recordID), .text(kind.rawValue), priorValue, afterValue, .int(at), .int(expires),
    ]
    try change(Schema.addLog, values)
  }

  private func logRow(_ entry: String) throws -> LogRow? {
    try query(Schema.logByEntry, [.text(entry)]) { (statement: OpaquePointer) throws -> LogRow? in
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { return nil }
      guard rc == SQLITE_ROW else { throw self.failure("Memory could not read that.") }
      guard let recordID = self.columnText(statement, 0), let raw = self.columnText(statement, 1),
        let kind = LogKind(rawValue: raw), let expires = self.columnInt(statement, 4)
      else { return nil }
      var prior: MemoryRecord?
      if let json = self.columnText(statement, 2) {
        prior = try? JSONDecoder().decode(MemoryRecord.self, from: Data(json.utf8))
      }
      return LogRow(recordID: recordID, kind: kind, prior: prior, after: self.columnInt(statement, 3), expires: expires)
    }
  }

  private func currentLocked(id: String) throws -> Found? {
    try query(Schema.byID, [.text(id)]) { (statement: OpaquePointer) throws -> Found? in
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { return nil }
      guard rc == SQLITE_ROW else { throw self.failure("Memory could not read that.") }
      guard let record = self.record(from: statement) else { return nil }
      return Found(seq: sqlite3_column_int64(statement, 0), record: record)
    }
  }

  /// Deletes log rows whose time is over and keeps the log under `logLimit` rows. True when a
  /// forgotten record's copy was deleted.
  private func pruneLocked(now: Date) throws -> Bool {
    let nowValue = Value.int(MemoryClock.toMillis(now))
    let forgets = try change(Schema.pruneForgets, [nowValue])
    try change(Schema.pruneLog, [nowValue])
    try change(Schema.capLog, [.int(Int64(MemoryStore.logLimit))])
    return forgets > 0
  }

  /// Merges each index into one segment (this drops the entries of deleted rows), then copies
  /// the WAL into the file and empties it. With `secure_delete`, freed pages hold zeros.
  private func scrubLocked() throws {
    try exec(Schema.optimizeWords)
    try exec(Schema.optimizeTrigrams)
    try exec(Schema.checkpoint)
  }

  // MARK: SQLite

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try exec("COMMIT")
      return result
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw failure("Memory could not save that.")
    }
  }

  /// The cached statement for `sql`, prepared on first use.
  private func prepared(_ sql: String) throws -> OpaquePointer {
    if let cached = cache[sql] { return cached }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let ready = statement else {
      if let statement { sqlite3_finalize(statement) }
      throw failure("Memory could not read that.")
    }
    cache[sql] = ready
    return ready
  }

  /// Binds `values` to the statement for `sql`, runs `body`, then resets the statement for reuse.
  private func query<T>(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
    let statement = try prepared(sql)
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    defer {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
    }
    for (offset, value) in values.enumerated() {
      let position = Int32(offset + 1)
      let rc: Int32
      switch value {
      case .text(let text): rc = sqlite3_bind_text(statement, position, text, -1, transient)
      case .int(let number): rc = sqlite3_bind_int64(statement, position, number)
      case .null: rc = sqlite3_bind_null(statement, position)
      }
      guard rc == SQLITE_OK else { throw failure("Memory could not read that.") }
    }
    return try body(statement)
  }

  /// Runs a statement that returns no rows. Returns how many rows it changed.
  @discardableResult
  private func change(_ sql: String, _ values: [Value]) throws -> Int {
    try query(sql, values) { (statement: OpaquePointer) throws -> Int in
      let rc = sqlite3_step(statement)
      if (rc & 0xff) == SQLITE_CONSTRAINT { throw Taken() }
      guard rc == SQLITE_DONE else { throw self.failure("Memory could not save that.") }
      return Int(sqlite3_changes(self.db))
    }
  }

  private func rows(_ sql: String, _ values: [Value]) throws -> [MemoryRecord] {
    try query(sql, values) { (statement: OpaquePointer) throws -> [MemoryRecord] in
      var out: [MemoryRecord] = []
      while true {
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { break }
        guard rc == SQLITE_ROW else { throw self.failure("Memory could not read that.") }
        if let record = self.record(from: statement) { out.append(record) }
      }
      return out
    }
  }

  private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else {
      return nil
    }
    return String(cString: raw)
  }

  private func columnInt(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, column)
  }

  /// A record from a row in `Schema.columns` order. nil for a row this build cannot read (a
  /// kind, scope, source or review it does not know): such a row stays out of every result.
  private func record(from statement: OpaquePointer) -> MemoryRecord? {
    guard let id = columnText(statement, 1),
      let kind = columnText(statement, 2).flatMap({ MemoryRecord.Kind(rawValue: $0) }),
      let body = columnText(statement, 3),
      let owner = columnText(statement, 5),
      let scopeKind = columnText(statement, 6),
      let scope = MemoryScope(kind: scopeKind, id: columnText(statement, 7) ?? ""),
      let source = columnText(statement, 8).flatMap({ MemorySource(rawValue: $0) }),
      let created = columnInt(statement, 11),
      let updated = columnInt(statement, 12),
      let enabled = columnInt(statement, 14),
      let review = columnText(statement, 15).flatMap({ MemoryRecord.Review(rawValue: $0) }),
      let personal = columnInt(statement, 16)
    else { return nil }
    let provenance = MemoryProvenance(source: source, reference: columnText(statement, 9), app: columnText(statement, 10))
    let expires = columnInt(statement, 13).map { MemoryClock.fromMillis($0) }
    let outside = (columnInt(statement, 18) ?? 0) != 0
    let uses = Int(columnInt(statement, 19) ?? 0)
    let lastUsed = columnInt(statement, 20).map { MemoryClock.fromMillis($0) }
    let archived = columnInt(statement, 21).map { MemoryClock.fromMillis($0) }
    return MemoryRecord(
      id: id, kind: kind, text: body, quote: columnText(statement, 4), owner: owner, scope: scope,
      provenance: provenance, createdAt: MemoryClock.fromMillis(created), updatedAt: MemoryClock.fromMillis(updated),
      expires: expires, enabled: enabled != 0, review: review, personal: personal != 0, chat: columnText(statement, 17),
      outside: outside, useCount: uses, lastUsed: lastUsed, archived: archived)
  }

  /// Values for `Schema.insertRecord` and `Schema.migrateRecord`, in column order.
  private func values(_ record: MemoryRecord) -> [Value] {
    var values: [Value] = []
    values.append(.text(record.id))
    values.append(.text(record.kind.rawValue))
    values.append(.text(record.text))
    values.append(MemoryStore.optionalText(record.quote))
    values.append(.text(record.owner))
    values.append(.text(record.scope.kind))
    values.append(.text(record.scope.id))
    values.append(.text(record.provenance.source.rawValue))
    values.append(MemoryStore.optionalText(record.provenance.reference))
    values.append(MemoryStore.optionalText(record.provenance.app))
    values.append(.int(MemoryClock.toMillis(record.createdAt)))
    values.append(.int(MemoryClock.toMillis(record.updatedAt)))
    values.append(MemoryStore.optionalDate(record.expires))
    values.append(.int(record.enabled ? 1 : 0))
    values.append(.text(record.review.rawValue))
    values.append(.int(record.personal ? 1 : 0))
    values.append(MemoryStore.optionalText(record.chat))
    values.append(.int(record.outside ? 1 : 0))
    return values
  }

  private static func optionalText(_ text: String?) -> Value {
    guard let text else { return Value.null }
    return Value.text(text)
  }

  private static func optionalDate(_ date: Date?) -> Value {
    guard let date else { return Value.null }
    return Value.int(MemoryClock.toMillis(date))
  }

  private func failure(_ words: String) -> SereinError {
    #if DEBUG
      let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
      return SereinError.invalid(words + " (" + detail + ")")
    #else
      return SereinError.invalid(words)
    #endif
  }

  /// Every statement the store runs. Text from people and models is only ever a bound value.
  private enum Schema {
    /// The file's `user_version` this build writes (SPEC 8.2).
    static let version: Int64 = 2
    static let readVersion: String = "PRAGMA user_version"
    /// Version 0 to 1, run once in one transaction by `upgrade`.
    static let upgradeOne: String = """
      ALTER TABLE records ADD COLUMN chat TEXT;
      ALTER TABLE records ADD COLUMN outside INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE records ADD COLUMN replaces TEXT;
      ALTER TABLE records ADD COLUMN superseded INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE records ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE records ADD COLUMN last_used INTEGER;
      ALTER TABLE records ADD COLUMN payload TEXT;
      ALTER TABLE records ADD COLUMN digest TEXT;
      UPDATE records SET outside = 1 WHERE source IN ('page', 'mail', 'app', 'handoff', 'import');
      CREATE INDEX IF NOT EXISTS records_digest ON records(scope_kind, scope_id, digest);
      CREATE INDEX IF NOT EXISTS records_chat ON records(chat);
      CREATE INDEX IF NOT EXISTS records_app ON records(app);
      CREATE INDEX IF NOT EXISTS records_kind ON records(kind, owner, updated);
      CREATE TRIGGER IF NOT EXISTS records_fixed BEFORE UPDATE OF
        id, kind, quote, owner, source, reference, app, chat, created, personal, outside ON records
        BEGIN SELECT RAISE(ABORT, 'fixed column'); END;
      PRAGMA user_version = 1;
      """
    /// Version 1 to 2: when a note left for the archive (`archive`). NULL: it is live. No row is
    /// rewritten, so a version 1 file keeps every note as it was.
    static let upgradeTwo: String = """
      ALTER TABLE records ADD COLUMN archived INTEGER;
      PRAGMA user_version = 2;
      """
    static let pragmas: String = "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA synchronous=NORMAL;"
    static let tables: String = """
      CREATE TABLE IF NOT EXISTS records(
        seq INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL,
        text TEXT NOT NULL,
        quote TEXT,
        owner TEXT NOT NULL,
        scope_kind TEXT NOT NULL,
        scope_id TEXT NOT NULL,
        source TEXT NOT NULL,
        reference TEXT,
        app TEXT,
        created INTEGER NOT NULL,
        updated INTEGER NOT NULL,
        expires INTEGER,
        enabled INTEGER NOT NULL,
        review TEXT NOT NULL,
        personal INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS records_owner ON records(owner, updated);
      CREATE INDEX IF NOT EXISTS records_updated ON records(updated);
      CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(body, tokenize = 'unicode61 remove_diacritics 2');
      CREATE VIRTUAL TABLE IF NOT EXISTS records_tri USING fts5(body, tokenize = 'trigram');
      CREATE TABLE IF NOT EXISTS tombstones(digest TEXT PRIMARY KEY, reason TEXT NOT NULL, at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS log(
        entry TEXT PRIMARY KEY,
        record_id TEXT NOT NULL,
        change_kind TEXT NOT NULL,
        prior TEXT,
        after_updated INTEGER,
        at INTEGER NOT NULL,
        expires INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS log_record ON log(record_id);
      """
    static let columns: String =
      "r.seq, r.id, r.kind, r.text, r.quote, r.owner, r.scope_kind, r.scope_id, r.source, r.reference, r.app, r.created, r.updated, r.expires, r.enabled, r.review, r.personal, r.chat, r.outside, r.use_count, r.last_used, r.archived"
    static let fields: String =
      "id, kind, text, quote, owner, scope_kind, scope_id, source, reference, app, created, updated, expires, enabled, review, personal, chat, outside"
    static let slots: String = "?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18"
    /// Recall rules SQLite can apply before `MemoryRecall.eligible` (which still decides):
    /// on, not archived, not expired (?2), reviewed, not another assistant's private scope (?3), and a learned
    /// record only for its owner. The sources here are the ones that are not `isLearned`.
    static let readable: String =
      " AND r.enabled = 1 AND r.superseded = 0 AND r.archived IS NULL AND (r.expires IS NULL OR r.expires > ?2) AND r.review <> 'unreviewed' AND (r.scope_kind <> 'assistant' OR r.scope_id = ?3) AND (r.source IN ('person', 'migrated') OR r.owner = ?3)"
    /// Live records of other owners (?3), for `whoKnows`.
    static let others: String =
      " AND r.enabled = 1 AND r.superseded = 0 AND r.archived IS NULL AND (r.expires IS NULL OR r.expires > ?2) AND r.review <> 'unreviewed' AND r.owner <> ?3"
    /// Learned records made in one chat (?1), for the chat-delete cascade; ?2 is the limit.
    static let learnedInChat: String =
      "SELECT " + columns + " FROM records r WHERE r.chat = ?1 AND r.source NOT IN ('person', 'migrated') LIMIT ?2"
    /// One more use by the host: ?1 is now, ?2 the id. No fixed column moves (`records_fixed`).
    static let markUsed: String = "UPDATE records SET use_count = use_count + 1, last_used = ?1 WHERE id = ?2"

    /// One owner's (?1) notes file: the notes the person has seen that are not in the archive,
    /// oldest change first. Off notes count: they still take room.
    static let ownedLive: String =
      "SELECT " + columns + " FROM records r WHERE r.owner = ?1 AND r.kind = 'note' AND r.review <> 'unreviewed' AND r.archived IS NULL ORDER BY r.updated, r.seq"
    /// Into the archive at ?1, only a live row: a second pass changes nothing. No fixed column
    /// moves (`records_fixed`), and `updated` stays, so an earlier Undo still holds.
    static let archiveOne: String = "UPDATE records SET archived = ?1 WHERE id = ?2 AND archived IS NULL"
    /// Out of the archive, as the newest note (?1 is now), so the next pass does not send it
    /// straight back; an end date that passed is dropped for the same reason.
    static let unarchiveOne: String = """
      UPDATE records SET archived = NULL, updated = MAX(?1, updated + 1),
        expires = CASE WHEN expires IS NOT NULL AND expires <= ?1 THEN NULL ELSE expires END
      WHERE id = ?2 AND archived IS NOT NULL
      """

    static let insertRecord: String = "INSERT INTO records(" + fields + ") VALUES(" + slots + ")"
    static let migrateRecord: String = "INSERT OR IGNORE INTO records(" + fields + ") VALUES(" + slots + ")"
    static let updateRecord: String =
      "UPDATE records SET text = ?1, scope_kind = ?2, scope_id = ?3, updated = ?4, expires = ?5, enabled = ?6, review = ?7 WHERE seq = ?8 AND updated = ?9"
    static let deleteRecord: String = "DELETE FROM records WHERE seq = ?1"
    static let byID: String = "SELECT " + columns + " FROM records r WHERE r.id = ?1"
    static let hasRecord: String = "SELECT 1 FROM records WHERE id = ?1"
    static let countRecords: String = "SELECT COUNT(*) FROM records"
    static let proposals: String =
      "SELECT " + columns + " FROM records r WHERE r.owner = ?1 AND r.review = 'unreviewed' ORDER BY r.updated DESC LIMIT ?2"
    /// `readable` with no index query: ?1 is not used, ?4 is the limit.
    static let newest: String = "SELECT " + columns + " FROM records r WHERE ?1 IS NULL" + readable + " ORDER BY r.updated DESC LIMIT ?4"

    static let indexWords: String = "INSERT INTO records_fts(rowid, body) VALUES(?1, ?2)"
    static let indexTrigrams: String = "INSERT INTO records_tri(rowid, body) VALUES(?1, ?2)"
    static let unindexWords: String = "DELETE FROM records_fts WHERE rowid = ?1"
    static let unindexTrigrams: String = "DELETE FROM records_tri WHERE rowid = ?1"
    static let searchWords: String =
      "SELECT " + columns + " FROM records_fts JOIN records r ON r.seq = records_fts.rowid WHERE records_fts MATCH ?1"
      + readable + " ORDER BY bm25(records_fts) LIMIT ?4"
    static let searchTrigrams: String =
      "SELECT " + columns + " FROM records_tri JOIN records r ON r.seq = records_tri.rowid WHERE records_tri MATCH ?1"
      + readable + " ORDER BY bm25(records_tri) LIMIT ?4"
    static let othersWords: String =
      "SELECT " + columns + " FROM records_fts JOIN records r ON r.seq = records_fts.rowid WHERE records_fts MATCH ?1"
      + others + " ORDER BY bm25(records_fts) LIMIT ?4"
    static let othersTrigrams: String =
      "SELECT " + columns + " FROM records_tri JOIN records r ON r.seq = records_tri.rowid WHERE records_tri MATCH ?1"
      + others + " ORDER BY bm25(records_tri) LIMIT ?4"
    static let optimizeWords: String = "INSERT INTO records_fts(records_fts) VALUES('optimize')"
    static let optimizeTrigrams: String = "INSERT INTO records_tri(records_tri) VALUES('optimize')"
    static let checkpoint: String = "PRAGMA wal_checkpoint(TRUNCATE)"

    static let addTombstone: String = "INSERT OR REPLACE INTO tombstones(digest, reason, at) VALUES(?1, ?2, ?3)"
    static let hasTombstone: String = "SELECT 1 FROM tombstones WHERE digest = ?1"
    static let dropTombstone: String = "DELETE FROM tombstones WHERE digest = ?1"

    static let addLog: String =
      "INSERT INTO log(entry, record_id, change_kind, prior, after_updated, at, expires) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)"
    static let logByEntry: String = "SELECT record_id, change_kind, prior, after_updated, expires FROM log WHERE entry = ?1"
    static let dropLog: String = "DELETE FROM log WHERE entry = ?1"
    static let dropLogFor: String = "DELETE FROM log WHERE record_id = ?1"
    static let pruneForgets: String = "DELETE FROM log WHERE expires <= ?1 AND change_kind = 'forget'"
    static let pruneLog: String = "DELETE FROM log WHERE expires <= ?1"
    static let capLog: String = "DELETE FROM log WHERE entry NOT IN (SELECT entry FROM log ORDER BY at DESC LIMIT ?1)"
  }
}
