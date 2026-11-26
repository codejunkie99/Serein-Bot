import Foundation
import SQLite3

/// The chat registry's SQLite file (`ChatRegistry.folder`/`database`): chats with their
/// watermark, redacted messages, sorted facets, an FTS5 index over both, and which provider last
/// read each thread. Times are epoch milliseconds. Opened like `MemoryStore`: folder 0700, file
/// 0600, WAL, one serialized connection. Callers run it off the main actor (`OffMain`).
public final class ChatRegistryStore: @unchecked Sendable {
  public let url: URL
  private let db: OpaquePointer
  private let lock = NSLock()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private enum Value {
    case text(String)
    case int(Int64)
    case null
  }

  static let schema = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    CREATE TABLE IF NOT EXISTS chats(
      thread TEXT PRIMARY KEY, title TEXT NOT NULL, provider TEXT NOT NULL, project TEXT,
      personal INTEGER NOT NULL, first_at INTEGER NOT NULL, last_at INTEGER NOT NULL, messages INTEGER NOT NULL,
      mark_count INTEGER NOT NULL, mark_id TEXT, mark_at INTEGER NOT NULL, indexed_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS messages(
      thread TEXT NOT NULL, id TEXT NOT NULL, at INTEGER NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
      tools TEXT NOT NULL, PRIMARY KEY(thread, id));
    CREATE TABLE IF NOT EXISTS facets(
      thread TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('project', 'topic', 'person', 'task', 'decision', 'preference')),
      value TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(thread, kind, value));
    CREATE TABLE IF NOT EXISTS readers(thread TEXT PRIMARY KEY, provider TEXT NOT NULL, at INTEGER NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(thread UNINDEXED, kind UNINDEXED, text, tokenize = 'unicode61');
    PRAGMA user_version = 1;
    """

  public init(url: URL) throws {
    self.url = url
    let files = FileManager.default
    let folder = url.deletingLastPathComponent()
    try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    if !files.fileExists(atPath: url.path) {
      guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw SereinError.invalid("The chat registry could not make its file.")
      }
    }
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let opened = handle else {
      if let handle { sqlite3_close(handle) }
      throw SereinError.invalid("The chat registry could not open its file.")
    }
    sqlite3_busy_timeout(opened, 5_000)
    guard sqlite3_exec(opened, Self.schema, nil, nil, nil) == SQLITE_OK else {
      sqlite3_close(opened)
      throw SereinError.invalid("The chat registry could not be prepared.")
    }
    db = opened
    for suffix in ["-wal", "-shm"] where files.fileExists(atPath: url.path + suffix) {
      try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
    }
  }

  deinit { sqlite3_close(db) }

  // MARK: Reads

  /// Every chat with its facets, for the slice and the markdown.
  public func digests() throws -> [ChatRegistry.Digest] {
    lock.lock()
    defer { lock.unlock() }
    var facets: [String: [ChatRegistry.Facet]] = [:]
    try each("SELECT thread, kind, value, at FROM facets", []) { row in
      guard let thread = text(row, 0), let kind = text(row, 1).flatMap(ChatRegistry.Kind.init), let value = text(row, 2) else { return }
      facets[thread, default: []].append(ChatRegistry.Facet(kind: kind, value: value, at: date(row, 3)))
    }
    var out: [ChatRegistry.Digest] = []
    try each("SELECT thread, title, provider, project, personal, first_at, last_at, messages, mark_count, mark_id, mark_at FROM chats", []) { row in
      guard let thread = text(row, 0) else { return }
      let chat = ChatRegistry.Row(
        thread: thread, title: text(row, 1) ?? "", provider: text(row, 2) ?? "", project: text(row, 3),
        personal: sqlite3_column_int64(row, 4) != 0, firstAt: date(row, 5), lastAt: date(row, 6),
        messages: Int(sqlite3_column_int64(row, 7)),
        mark: ChatRegistry.Mark(count: Int(sqlite3_column_int64(row, 8)), lastID: text(row, 9), at: date(row, 10)))
      out.append(ChatRegistry.Digest(row: chat, facets: facets[thread] ?? []))
    }
    return out
  }

  /// The provider that last read each thread.
  public func readers() throws -> [String: String] {
    lock.lock()
    defer { lock.unlock() }
    var out: [String: String] = [:]
    try each("SELECT thread, provider FROM readers", []) { row in
      if let thread = text(row, 0), let provider = text(row, 1) { out[thread] = provider }
    }
    return out
  }

  /// Threads whose messages or facets match `query`, best first (FTS5 bm25).
  public func search(_ query: String, limit: Int = 20) throws -> [String] {
    let terms = ChatRegistry.words(query).prefix(12).map { "\"" + $0 + "\"" }
    guard !terms.isEmpty else { return [] }
    lock.lock()
    defer { lock.unlock() }
    var out: [String] = []
    // FTS5 allows bm25 only in a plain full-text query, so best rows come first and threads dedupe here.
    try each("SELECT thread FROM search WHERE search MATCH ?1 ORDER BY rank LIMIT ?2",
             [.text(terms.joined(separator: " OR ")), .int(Int64(limit * 8))]) { row in
      if let thread = text(row, 0), !out.contains(thread), out.count < limit { out.append(thread) }
    }
    return out
  }

  // MARK: Writes

  /// Writes each update in one transaction and drops chats not in `keep` (deleted chats).
  /// Returns whether anything changed; nothing to do opens no transaction.
  @discardableResult
  public func apply(_ updates: [ChatRegistry.Update], keep: Set<String>? = nil, now: Date = Date()) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    var gone: [String] = []
    if let keep {
      try each("SELECT thread FROM chats", []) { row in
        if let thread = text(row, 0), !keep.contains(thread) { gone.append(thread) }
      }
    }
    guard !updates.isEmpty || !gone.isEmpty else { return false }
    try exec("BEGIN IMMEDIATE")
    do {
      for thread in gone { try drop(thread, chat: true) }
      for update in updates { try write(update, now: now) }
      try exec("COMMIT")
    } catch {
      _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
      throw error
    }
    return true
  }

  /// Records the provider that read `thread`. False when it was already the one.
  @discardableResult
  public func noteReader(thread: String, provider: String, at: Date = Date()) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return try change("""
      INSERT INTO readers(thread, provider, at) VALUES(?1, ?2, ?3)
      ON CONFLICT(thread) DO UPDATE SET provider = excluded.provider, at = excluded.at WHERE provider != excluded.provider
      """, [.text(thread), .text(provider), .int(Self.millis(at))]) > 0
  }

  private func write(_ update: ChatRegistry.Update, now: Date) throws {
    let row = update.row
    if update.reset { try drop(row.thread, chat: false) }
    try change("""
      INSERT INTO chats(thread, title, provider, project, personal, first_at, last_at, messages, mark_count, mark_id, mark_at, indexed_at)
      VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
      ON CONFLICT(thread) DO UPDATE SET title = excluded.title, provider = excluded.provider, project = excluded.project,
        personal = excluded.personal, first_at = excluded.first_at, last_at = excluded.last_at, messages = excluded.messages,
        mark_count = excluded.mark_count, mark_id = excluded.mark_id, mark_at = max(chats.mark_at, excluded.mark_at),
        indexed_at = excluded.indexed_at
      """, [.text(row.thread), .text(row.title), .text(row.provider), row.project.map(Value.text) ?? .null,
            .int(row.personal ? 1 : 0), .int(Self.millis(row.firstAt)), .int(Self.millis(row.lastAt)), .int(Int64(row.messages)),
            .int(Int64(row.mark.count)), row.mark.lastID.map(Value.text) ?? .null, .int(Self.millis(row.mark.at)), .int(Self.millis(now))])
    for message in update.messages where !message.text.isEmpty {
      let tools = message.tools.map(\.label).joined(separator: "\n")
      if try change("INSERT OR IGNORE INTO messages(thread, id, at, role, text, tools) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                    [.text(row.thread), .text(message.id), .int(Self.millis(message.at)), .text(message.role),
                     .text(message.text), .text(tools)]) > 0 {
        try change("INSERT INTO search(thread, kind, text) VALUES(?1, 'message', ?2)", [.text(row.thread), .text(message.text)])
      }
    }
    for value in update.done {
      try change("DELETE FROM facets WHERE thread = ?1 AND kind = 'task' AND lower(value) = lower(?2)", [.text(row.thread), .text(value)])
    }
    for facet in update.facets {
      let added = try change("INSERT OR IGNORE INTO facets(thread, kind, value, at) VALUES(?1, ?2, ?3, ?4)",
                             [.text(row.thread), .text(facet.kind.rawValue), .text(facet.value), .int(Self.millis(facet.at))])
      if added > 0 {
        try change("INSERT INTO search(thread, kind, text) VALUES(?1, ?2, ?3)", [.text(row.thread), .text(facet.kind.rawValue), .text(facet.value)])
      } else {
        try change("UPDATE facets SET at = max(at, ?4) WHERE thread = ?1 AND kind = ?2 AND value = ?3",
                   [.text(row.thread), .text(facet.kind.rawValue), .text(facet.value), .int(Self.millis(facet.at))])
      }
    }
    try change("""
      DELETE FROM facets WHERE thread = ?1 AND rowid NOT IN (
        SELECT rowid FROM (SELECT rowid, row_number() OVER (PARTITION BY kind ORDER BY at DESC) AS n FROM facets WHERE thread = ?1)
        WHERE n <= ?2)
      """, [.text(row.thread), .int(Int64(ChatRegistry.keptPerKind))])
  }

  /// Removes a thread's messages, facets and search rows, and its chat row when `chat`.
  private func drop(_ thread: String, chat: Bool) throws {
    for table in ["messages", "facets", "search"] + (chat ? ["chats", "readers"] : []) {
      try change("DELETE FROM \(table) WHERE thread = ?1", [.text(thread)])
    }
  }

  // MARK: SQLite

  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }

  /// Text from people and models is only ever a bound value.
  private func run<T>(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let ready = statement else {
      if let statement { sqlite3_finalize(statement) }
      throw failure()
    }
    defer { sqlite3_finalize(ready) }
    for (offset, value) in values.enumerated() {
      let position = Int32(offset + 1)
      let rc: Int32
      switch value {
      case .text(let text): rc = sqlite3_bind_text(ready, position, text, -1, transient)
      case .int(let number): rc = sqlite3_bind_int64(ready, position, number)
      case .null: rc = sqlite3_bind_null(ready, position)
      }
      guard rc == SQLITE_OK else { throw failure() }
    }
    return try body(ready)
  }

  @discardableResult
  private func change(_ sql: String, _ values: [Value]) throws -> Int {
    try run(sql, values) { statement in
      guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
      return Int(sqlite3_changes(db))
    }
  }

  private func each(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> Void) throws {
    try run(sql, values) { statement in
      while true {
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return }
        guard rc == SQLITE_ROW else { throw failure() }
        try body(statement)
      }
    }
  }

  private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: raw)
  }

  private func date(_ statement: OpaquePointer, _ column: Int32) -> Date {
    Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, column)) / 1_000)
  }

  static func millis(_ date: Date) -> Int64 {
    let value = date.timeIntervalSince1970 * 1_000
    return value.isFinite ? Int64(max(-9e15, min(9e15, value)).rounded()) : 0
  }

  private func failure() -> SereinError {
    #if DEBUG
      return SereinError.invalid("The chat registry could not save that. (" + String(cString: sqlite3_errmsg(db)) + ")")
    #else
      return SereinError.invalid("The chat registry could not save that.")
    #endif
  }
}
