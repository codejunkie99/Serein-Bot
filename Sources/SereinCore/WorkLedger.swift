import Foundation
import SQLite3

/// The work ledger: one row for each run that an assistant does by itself. A row is a schedule
/// that came due, a link delivery, a light ask, or a proposal from an assistant. The rows live
/// in one SQLite file (`relay/work.sqlite`, WAL), so a quit or a crash loses no queued run.
///
/// States and the only moves (`Transition`):
/// `queued → started → finished | failed`, `queued → missed | dropped`, `started → missed`.
///
/// - No move ends in `queued`. Only `enqueue` makes a queued row, so a run that started can
///   never queue again. A trigger in the file refuses every other move, so a stray write
///   cannot break this rule.
/// - After a crash, `recoverAfterLaunch` makes every `started` row `missed`. Serein never runs
///   it again, because nobody knows what it did.
/// - `enqueue` is unique on (kind, dedupe key). A repeat writes nothing and returns the row
///   that is there.
/// - Each move is one `UPDATE … WHERE id = ? AND state = ?` and tells if it applied. Two
///   callers cannot both start one row.
///
/// Open it once, off the main thread. It keeps one connection and reuses its prepared
/// statements. Every list has a cap. A lock makes the calls safe from more than one thread.
public final class WorkLedger: @unchecked Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    /// One occurrence of a routine. Its key is `scheduleKey(id:due:)`.
    case schedule
    /// One delivery to a link. Its key is `HookGate.Admitted.dedupeKey`.
    case link
    /// A light ask to another assistant.
    case ask
    /// An assistant's proposal that waits for the person's card.
    case proposal
  }

  public enum State: String, Codable, CaseIterable, Sendable {
    case queued, started, finished, failed, missed, dropped

    /// The states that one move reaches from this state.
    public var next: Set<State> {
      let moves: [Transition] = Transition.allCases.filter { $0.from == self }
      let targets: [State] = moves.map { $0.to }
      return Set(targets)
    }
    /// No move leaves a final state.
    public var isFinal: Bool { next.isEmpty }
  }

  /// The only moves. Each has one fixed start state and one fixed end state, and none ends in
  /// `queued`.
  public enum Transition: String, CaseIterable, Sendable {
    /// queued → started. It adds one to `attempts`.
    case start
    /// started → finished.
    case finish
    /// started → failed.
    case fail
    /// queued → missed: it did not start in time (the Mac slept, or Serein was closed).
    case miss
    /// queued → dropped: the person or the shell removed it before it started.
    case drop
    /// started → missed: it stopped and nobody knows its effect. It never runs again.
    case interrupt

    public var from: State {
      switch self {
      case .start, .miss, .drop: return .queued
      case .finish, .fail, .interrupt: return .started
      }
    }
    public var to: State {
      switch self {
      case .start: return .started
      case .finish: return .finished
      case .fail: return .failed
      case .miss, .interrupt: return .missed
      case .drop: return .dropped
      }
    }
  }

  /// One queued run, as the file holds it.
  public struct Row: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let kind: Kind
    /// The assistant that owns the run. Its turn runs in that assistant's chat.
    public let owner: String
    public let dedupeKey: String
    /// What the run reads, at most `WorkLedger.maxPayload` characters.
    public let payload: String
    public let state: State
    /// How many times it started. With these moves it is 0 or 1.
    public let attempts: Int
    public let created: Date
    /// When it is due to run.
    public let due: Date
    public let started: Date?
    /// When it became finished, failed, missed or dropped.
    public let ended: Date?
    /// Why it ended, in plain words, when the caller gave a reason.
    public let note: String?
    /// When the person cleared it from the Missed card.
    public let cleared: Date?
  }

  /// What `enqueue` did: `isNew` is false when a row with that kind and key was there.
  public struct Enqueued: Equatable, Sendable {
    public let row: Row
    public let isNew: Bool
  }

  // Limits are counts of Unicode characters (scalars), the same unit as SQLite's length().
  public static let maxPayload = 16_000
  public static let maxKey = 512
  public static let maxOwner = 200
  public static let maxNote = 500
  /// No list returns more rows than this.
  public static let maxRows = 200
  /// `prune` removes ended rows older than this.
  public static let keepDays = 30
  /// The note on a row that `recoverAfterLaunch` made missed.
  public static let interruptedNote = "Serein stopped while this ran. It did not run again."

  /// The key for one occurrence of a schedule: `sched:<id>:<due>`, due in whole seconds.
  /// Enqueue it before you move the schedule to its next due time. If a crash comes between
  /// the two steps, the schedule is due again at the same time, and the repeat writes nothing.
  public static func scheduleKey(id: String, due: Date) -> String {
    let seconds = Int64(due.timeIntervalSince1970.rounded(.down))
    return "sched:\(id):\(seconds)"
  }

  /// The key of the one re-run of a turn the person interrupted. nil for a re-run itself, so a
  /// second interruption queues nothing.
  public static func resumeKey(_ key: String) -> String? {
    let suffix = ":resume"
    guard !key.hasSuffix(suffix), key.count + suffix.count <= maxKey else { return nil }
    return key + suffix
  }

  /// All states that some chain of moves reaches from `state`. The checks use it to show that
  /// no path leads from `started` back to `queued`.
  public static func reachable(from state: State) -> Set<State> {
    var found: Set<State> = []
    var open: [State] = [state]
    while let current = open.popLast() {
      for target in current.next where !found.contains(target) {
        found.insert(target)
        open.append(target)
      }
    }
    return found
  }

  private let db: OpaquePointer
  private let lock = NSLock()
  private var statements: [String: OpaquePointer] = [:]
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  /// Opens (or makes) the ledger at `url`: folder 0700, file 0600, WAL, full sync, so a row is
  /// on disk when `enqueue` returns. A link answers 200 only after that.
  public init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var handle: OpaquePointer?
    let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
      if let handle { sqlite3_close(handle) }
      throw SereinError.invalid("Cannot open the list of queued work")
    }
    sqlite3_busy_timeout(opened, 5000)
    do {
      try Self.exec(opened, Self.schema)
      try Self.exec(opened, Self.guards())
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      sqlite3_close(opened)
      throw error
    }
    db = opened
  }

  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    sqlite3_close(db)
  }

  // MARK: writes

  /// Adds one queued run, or returns the row that has this kind and key. A repeat writes
  /// nothing: not the payload, not the times. Start a run only when `isNew` is true, or when
  /// `queued` lists the row.
  public func enqueue(
    _ kind: Kind, owner: String, dedupeKey: String, payload: String, due: Date? = nil,
    now: Date = Date()
  ) throws -> Enqueued {
    try Self.validate(owner: owner, key: dedupeKey, payload: payload)
    lock.lock()
    defer { lock.unlock() }
    let insert = try statement(Self.insertSQL)
    defer { sqlite3_reset(insert) }
    bind(kind.rawValue, at: 1, in: insert)
    bind(owner, at: 2, in: insert)
    bind(dedupeKey, at: 3, in: insert)
    bind(payload, at: 4, in: insert)
    sqlite3_bind_double(insert, 5, now.timeIntervalSince1970)
    sqlite3_bind_double(insert, 6, (due ?? now).timeIntervalSince1970)
    guard sqlite3_step(insert) == SQLITE_DONE else {
      throw SereinError.invalid("Cannot save the queued work")
    }
    let added = sqlite3_changes(db) == 1
    guard let row = try rowLocked(kind: kind, dedupeKey: dedupeKey) else {
      throw SereinError.invalid("Cannot read the queued work")
    }
    return Enqueued(row: row, isNew: added)
  }

  /// Applies one move to row `id`: one `UPDATE … WHERE id = ? AND state = ?`. True when the
  /// row was in `transition.from` and now is in `transition.to`; false when it was not (it
  /// moved first, or it is not there). `note` (cut to `maxNote`) is kept on moves that end a run.
  public func move(_ id: Int64, _ transition: Transition, now: Date = Date(), note: String? = nil)
    throws -> Bool
  {
    lock.lock()
    defer { lock.unlock() }
    return try moveLocked(id, transition, now: now, note: note)
  }

  /// Launch recovery. Call it once after you open the ledger, before any run starts. Every
  /// `started` row becomes `missed`, with `interruptedNote`. Nothing runs again. Returns the
  /// rows it changed (at most `maxRows`), for the Missed card. A second call changes nothing.
  public func recoverAfterLaunch(now: Date = Date()) throws -> [Row] {
    lock.lock()
    defer { lock.unlock() }
    try Self.exec(db, "BEGIN IMMEDIATE")
    var changed: [Int64] = []
    do {
      while true {
        let ids = try startedIDsLocked()
        var progressed = false
        for id in ids {
          let moved = try moveLocked(id, .interrupt, now: now, note: Self.interruptedNote)
          if moved {
            changed.append(id)
            progressed = true
          }
        }
        if ids.isEmpty || !progressed { break }
      }
      try Self.exec(db, "COMMIT")
    } catch {
      try? Self.exec(db, "ROLLBACK")
      throw error
    }
    var rows: [Row] = []
    for id in changed.prefix(Self.maxRows) {
      if let row = try rowLocked(id: id) { rows.append(row) }
    }
    return rows
  }

  /// Takes a missed row off the Missed card. The row stays, so its key still stops a repeat.
  /// True when it was missed and not yet cleared.
  public func clearMissed(_ id: Int64, now: Date = Date()) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let stmt = try statement(Self.clearSQL)
    defer { sqlite3_reset(stmt) }
    sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
    sqlite3_bind_int64(stmt, 2, id)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SereinError.invalid("Cannot change the queued work")
    }
    return sqlite3_changes(db) == 1
  }

  /// Removes rows that ended more than `keepDays` days before `now`: finished, failed and
  /// dropped rows, and missed rows the person cleared. A missed row that is not cleared stays
  /// for the Missed card. Queued and started rows always stay. Returns how many it removed.
  public func prune(now: Date = Date()) throws -> Int {
    lock.lock()
    defer { lock.unlock() }
    let cutoff = now.addingTimeInterval(-TimeInterval(Self.keepDays) * 86_400)
    let stmt = try statement(Self.pruneSQL)
    defer { sqlite3_reset(stmt) }
    sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SereinError.invalid("Cannot change the queued work")
    }
    return Int(sqlite3_changes(db))
  }

  // MARK: reads

  /// The next queued rows, the earliest due first. `owner` limits them to one assistant; nil
  /// gives every owner's rows. `limit` is kept between 1 and `maxRows`.
  public func queued(owner: String? = nil, limit: Int = 20) throws -> [Row] {
    lock.lock()
    defer { lock.unlock() }
    let stmt = try statement(Self.queuedSQL)
    defer { sqlite3_reset(stmt) }
    if let owner { bind(owner, at: 1, in: stmt) } else { sqlite3_bind_null(stmt, 1) }
    sqlite3_bind_int64(stmt, 2, Int64(Self.capped(limit)))
    return try collect(stmt)
  }

  /// Missed rows the person did not clear, the newest first, for the Missed card.
  public func missed(limit: Int = 50) throws -> [Row] {
    lock.lock()
    defer { lock.unlock() }
    let stmt = try statement(Self.missedSQL)
    defer { sqlite3_reset(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(Self.capped(limit)))
    return try collect(stmt)
  }

  public func row(id: Int64) throws -> Row? {
    lock.lock()
    defer { lock.unlock() }
    return try rowLocked(id: id)
  }

  // MARK: SQL

  static let columns =
    "id, kind, owner, dedupe, payload, state, attempts, created, due, started, ended, note, cleared"

  static let schema = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=FULL;
    PRAGMA secure_delete=ON;
    CREATE TABLE IF NOT EXISTS work(
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      owner TEXT NOT NULL,
      dedupe TEXT NOT NULL,
      payload TEXT NOT NULL,
      state TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      created REAL NOT NULL,
      due REAL NOT NULL,
      started REAL,
      ended REAL,
      note TEXT,
      cleared REAL,
      UNIQUE(kind, dedupe)
    );
    CREATE INDEX IF NOT EXISTS work_next ON work(state, owner, due);
    CREATE INDEX IF NOT EXISTS work_ended ON work(state, ended);
    """

  /// Triggers made from `Kind` and `Transition` each time the file opens, so the file and the
  /// code always agree: a new row must be queued and of a known kind, and a state change must
  /// be one of the moves.
  static func guards() -> String {
    let kindNames: [String] = Kind.allCases.map { "'\($0.rawValue)'" }
    let kinds = kindNames.joined(separator: ",")
    let pairNames: [String] = Transition.allCases.map { "'\($0.from.rawValue)>\($0.to.rawValue)'" }
    let pairs = pairNames.joined(separator: ",")
    return """
      BEGIN;
      DROP TRIGGER IF EXISTS work_born_queued;
      CREATE TRIGGER work_born_queued BEFORE INSERT ON work
        WHEN NEW.state <> 'queued' OR NEW.kind NOT IN (\(kinds))
        BEGIN SELECT RAISE(ABORT, 'work ledger: a new row must be queued'); END;
      DROP TRIGGER IF EXISTS work_moves;
      CREATE TRIGGER work_moves BEFORE UPDATE OF state ON work
        WHEN (OLD.state || '>' || NEW.state) NOT IN (\(pairs))
        BEGIN SELECT RAISE(ABORT, 'work ledger: this move is not allowed'); END;
      COMMIT;
      """
  }

  static let insertSQL =
    "INSERT INTO work(kind, owner, dedupe, payload, state, attempts, created, due) VALUES(?1, ?2, ?3, ?4, 'queued', 0, ?5, ?6) ON CONFLICT(kind, dedupe) DO NOTHING"
  static let byKeySQL = "SELECT \(WorkLedger.columns) FROM work WHERE kind = ?1 AND dedupe = ?2"
  static let byIDSQL = "SELECT \(WorkLedger.columns) FROM work WHERE id = ?1"
  static let startSQL =
    "UPDATE work SET state = ?1, attempts = attempts + 1, started = ?2 WHERE id = ?3 AND state = ?4"
  static let endSQL =
    "UPDATE work SET state = ?1, ended = ?2, note = ?5 WHERE id = ?3 AND state = ?4"
  static let startedIDsSQL = "SELECT id FROM work WHERE state = 'started' ORDER BY id LIMIT ?1"
  static let queuedSQL =
    "SELECT \(WorkLedger.columns) FROM work WHERE state = 'queued' AND (?1 IS NULL OR owner = ?1) ORDER BY due, id LIMIT ?2"
  static let missedSQL =
    "SELECT \(WorkLedger.columns) FROM work WHERE state = 'missed' AND cleared IS NULL ORDER BY ended DESC, id DESC LIMIT ?1"
  static let clearSQL =
    "UPDATE work SET cleared = ?1 WHERE id = ?2 AND state = 'missed' AND cleared IS NULL"
  static let pruneSQL =
    "DELETE FROM work WHERE ended < ?1 AND (state IN ('finished', 'failed', 'dropped') OR (state = 'missed' AND cleared IS NOT NULL))"

  // MARK: helpers (call with the lock held)

  private func moveLocked(_ id: Int64, _ transition: Transition, now: Date, note: String?) throws
    -> Bool
  {
    let starting = transition.to == .started
    let stmt = try statement(starting ? Self.startSQL : Self.endSQL)
    defer { sqlite3_reset(stmt) }
    bind(transition.to.rawValue, at: 1, in: stmt)
    sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
    sqlite3_bind_int64(stmt, 3, id)
    bind(transition.from.rawValue, at: 4, in: stmt)
    if !starting {
      if let note {
        bind(Self.cut(note, Self.maxNote), at: 5, in: stmt)
      } else {
        sqlite3_bind_null(stmt, 5)
      }
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SereinError.invalid("Cannot change the queued work")
    }
    return sqlite3_changes(db) == 1
  }

  private func startedIDsLocked() throws -> [Int64] {
    let stmt = try statement(Self.startedIDsSQL)
    defer { sqlite3_reset(stmt) }
    sqlite3_bind_int64(stmt, 1, Int64(Self.maxRows))
    var ids: [Int64] = []
    while true {
      let code = sqlite3_step(stmt)
      if code == SQLITE_ROW {
        ids.append(sqlite3_column_int64(stmt, 0))
      } else if code == SQLITE_DONE {
        break
      } else {
        throw SereinError.invalid("Cannot read the queued work")
      }
    }
    return ids
  }

  private func rowLocked(id: Int64) throws -> Row? {
    let stmt = try statement(Self.byIDSQL)
    defer { sqlite3_reset(stmt) }
    sqlite3_bind_int64(stmt, 1, id)
    return try collect(stmt).first
  }

  private func rowLocked(kind: Kind, dedupeKey: String) throws -> Row? {
    let stmt = try statement(Self.byKeySQL)
    defer { sqlite3_reset(stmt) }
    bind(kind.rawValue, at: 1, in: stmt)
    bind(dedupeKey, at: 2, in: stmt)
    return try collect(stmt).first
  }

  /// A prepared statement, made once and reused. It comes back reset with no bindings.
  private func statement(_ sql: String) throws -> OpaquePointer {
    if let cached = statements[sql] {
      sqlite3_reset(cached)
      sqlite3_clear_bindings(cached)
      return cached
    }
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let made = prepared else {
      sqlite3_finalize(prepared)
      throw SereinError.invalid("Cannot read the queued work")
    }
    statements[sql] = made
    return made
  }

  /// Binds the whole text with its byte count, so a NUL in it does not cut it.
  private func bind(_ text: String, at index: Int32, in stmt: OpaquePointer) {
    let length = Int32(text.utf8.count)
    sqlite3_bind_text(stmt, index, text, length, transient)
  }

  private func collect(_ stmt: OpaquePointer) throws -> [Row] {
    var rows: [Row] = []
    while true {
      let code = sqlite3_step(stmt)
      if code == SQLITE_ROW {
        // A row with a kind or state this version does not know is skipped, not guessed.
        if let row = Self.decode(stmt) { rows.append(row) }
      } else if code == SQLITE_DONE {
        break
      } else {
        throw SereinError.invalid("Cannot read the queued work")
      }
    }
    return rows
  }

  private static func decode(_ stmt: OpaquePointer) -> Row? {
    guard let kindName = text(stmt, 1), let kind = Kind(rawValue: kindName),
      let stateName = text(stmt, 5), let state = State(rawValue: stateName)
    else { return nil }
    let created = date(stmt, 7) ?? Date(timeIntervalSince1970: 0)
    let due = date(stmt, 8) ?? created
    return Row(
      id: sqlite3_column_int64(stmt, 0), kind: kind, owner: text(stmt, 2) ?? "",
      dedupeKey: text(stmt, 3) ?? "", payload: text(stmt, 4) ?? "", state: state,
      attempts: Int(sqlite3_column_int64(stmt, 6)), created: created, due: due,
      started: date(stmt, 9), ended: date(stmt, 10), note: text(stmt, 11),
      cleared: date(stmt, 12))
  }

  private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
      let pointer = sqlite3_column_text(stmt, column)
    else { return nil }
    let count = Int(sqlite3_column_bytes(stmt, column))
    let bytes = UnsafeBufferPointer(start: pointer, count: count)
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func date(_ stmt: OpaquePointer, _ column: Int32) -> Date? {
    guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(stmt, column))
  }

  private static func exec(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw SereinError.invalid("Cannot change the queued work")
    }
  }

  static func validate(owner: String, key: String, payload: String) throws {
    let ownerSize = owner.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    guard ownerSize > 0, owner.unicodeScalars.count <= maxOwner else {
      throw SereinError.invalid("Work needs an owner of 1 to \(maxOwner) characters")
    }
    let keySize = key.unicodeScalars.count
    guard keySize > 0, keySize <= maxKey else {
      throw SereinError.invalid("Work needs a key of 1 to \(maxKey) characters")
    }
    guard payload.unicodeScalars.count <= maxPayload else {
      throw SereinError.invalid("Work text is longer than \(maxPayload) characters")
    }
  }

  static func capped(_ limit: Int) -> Int { min(max(limit, 1), maxRows) }

  /// The first `limit` Unicode characters of `text`.
  static func cut(_ text: String, _ limit: Int) -> String {
    let scalars = text.unicodeScalars
    guard scalars.count > limit else { return text }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars.prefix(limit))
    return String(view)
  }
}
