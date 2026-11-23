import Foundation
import SQLite3

/// A small durable checkpoint store, separate from WorkLedger's deliberately non-replayable
/// action runs. FULL sync/WAL commits the checkpoint before another read or extraction starts.
public final class ResearchStore: @unchecked Sendable {
  private let db: OpaquePointer
  private let lock = NSLock()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  public init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let opened = handle else {
      if let handle { sqlite3_close(handle) }
      throw SereinError.invalid("The research notebook could not be opened.")
    }
    sqlite3_busy_timeout(opened, 5_000)
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      guard sqlite3_exec(opened, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS research(id TEXT PRIMARY KEY, body BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else {
        throw SereinError.invalid("The research notebook could not be prepared.")
      }
    } catch { sqlite3_close(opened); throw error }
    db = opened
  }
  deinit { sqlite3_close(db) }

  public func jobs() throws -> [ResearchJob] {
    lock.lock()
    defer { lock.unlock() }
    let stmt = try prepare("SELECT body FROM research LIMIT 41")
    defer { sqlite3_finalize(stmt) }
    var jobs: [ResearchJob] = []
    var result = sqlite3_step(stmt)
    while result == SQLITE_ROW {
      let size = Int(sqlite3_column_bytes(stmt, 0))
      guard size > 0, size <= 2_000_000, let bytes = sqlite3_column_blob(stmt, 0) else {
        throw SereinError.invalid("A research checkpoint is unreadable. It has been preserved.")
      }
      let job = try JSONDecoder().decode(ResearchJob.self, from: Data(bytes: bytes, count: size))
      try job.validate()
      jobs.append(job)
      result = sqlite3_step(stmt)
    }
    guard result == SQLITE_DONE, jobs.count <= ResearchJob.maxJobs else {
      throw SereinError.invalid("The research notebook could not be read. It has been preserved.")
    }
    return jobs.sorted { $0.createdAt < $1.createdAt }
  }

  public func save(_ job: ResearchJob) throws {
    try job.validate()
    let data = try JSONEncoder().encode(job)
    // Comparison citations enlarge a checkpoint. Refuse an oversized update before writing,
    // keeping the previous checkpoint readable under the same limit used by jobs().
    guard data.count <= 2_000_000 else { throw SereinError.invalid("The research checkpoint is too large. Its previous progress has been preserved.") }
    lock.lock()
    defer { lock.unlock() }
    let stmt = try prepare("INSERT INTO research(id, body) SELECT ?1, ?2 WHERE (SELECT count(*) FROM research) < 40 OR EXISTS(SELECT 1 FROM research WHERE id = ?1) ON CONFLICT(id) DO UPDATE SET body = excluded.body")
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, job.id, -1, transient)
    _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), transient) }
    guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
      throw SereinError.invalid("Research progress could not be saved. The notebook may be full.")
    }
  }

  public func remove(id: String) throws {
    lock.lock()
    defer { lock.unlock() }
    let stmt = try prepare("DELETE FROM research WHERE id = ?1")
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, id, -1, transient)
    guard sqlite3_step(stmt) == SQLITE_DONE else { throw SereinError.invalid("The research notebook could not be removed.") }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw SereinError.invalid("The research notebook could not be read or written.")
    }
    return stmt
  }
}
