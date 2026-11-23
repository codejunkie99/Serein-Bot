import CryptoKit
import Foundation
import SQLite3

/// One connection per background operation. SQLite serializes writers; WAL allows readers.
public final class SemanticIndex {
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  public init(url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else {
      if let db { sqlite3_close(db) }
      db = nil
      throw SereinError.invalid("Cannot open semantic index")
    }
    sqlite3_busy_timeout(db, 5000)
    try exec(
      "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS embeddings(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, model TEXT NOT NULL, vector BLOB NOT NULL);"
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  deinit { sqlite3_close(db) }
  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw SereinError.invalid("Semantic index write failed")
    }
  }
  private func statement(_ sql: String) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw SereinError.invalid("Semantic index query failed")
    }
    return stmt
  }
  private func bind(_ text: String, to stmt: OpaquePointer, at index: Int32) {
    sqlite3_bind_text(stmt, index, text, -1, transient)
  }
  public static func fingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public func contains(id: String, fingerprint: String, model: String) throws -> Bool {
    let stmt = try statement("SELECT 1 FROM embeddings WHERE id=? AND fingerprint=? AND model=?")
    defer { sqlite3_finalize(stmt) }
    bind(id, to: stmt, at: 1)
    bind(fingerprint, to: stmt, at: 2)
    bind(model, to: stmt, at: 3)
    return sqlite3_step(stmt) == SQLITE_ROW
  }
  /// Every stored visit's text fingerprint for `model`, in one query: a batch checks this map
  /// rather than asking SQLite once per visit.
  public func fingerprints(model: String) throws -> [String: String] {
    let stmt = try statement("SELECT id,fingerprint FROM embeddings WHERE model=?")
    defer { sqlite3_finalize(stmt) }
    bind(model, to: stmt, at: 1)
    var out: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let id = sqlite3_column_text(stmt, 0), let print = sqlite3_column_text(stmt, 1) else { continue }
      out[String(cString: id)] = String(cString: print)
    }
    return out
  }
  public func put(id: String, fingerprint: String, model: String, vector: [Double]) throws {
    guard !vector.isEmpty, vector.count <= 8192, vector.allSatisfy(\.isFinite) else {
      throw SereinError.invalid("Invalid embedding vector")
    }
    let data = try JSONEncoder().encode(vector)
    let stmt = try statement("INSERT OR REPLACE INTO embeddings VALUES(?,?,?,?)")
    defer { sqlite3_finalize(stmt) }
    bind(id, to: stmt, at: 1)
    bind(fingerprint, to: stmt, at: 2)
    bind(model, to: stmt, at: 3)
    _ = data.withUnsafeBytes {
      sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(data.count), transient)
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw SereinError.invalid("Cannot save embedding")
    }
  }
  public func retain(ids: Set<String>) throws {
    // A temporary table avoids SQLite's variable-count limit for large libraries.
    try exec(
      "BEGIN IMMEDIATE; CREATE TEMP TABLE IF NOT EXISTS retained(id TEXT PRIMARY KEY); DELETE FROM retained;"
    )
    do {
      let stmt = try statement("INSERT INTO retained VALUES(?)")
      defer { sqlite3_finalize(stmt) }
      for id in ids {
        bind(id, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
          throw SereinError.invalid("Index retention failed")
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
      }
      try exec("DELETE FROM embeddings WHERE id NOT IN (SELECT id FROM retained); COMMIT;")
    } catch {
      try? exec("ROLLBACK;")
      throw error
    }
  }
  public func nearest(
    _ query: [Double], model: String, limit: Int = 20, among: Set<String>? = nil,
    cancelled: () -> Bool = { false }
  ) throws -> [String] {
    guard !query.isEmpty, query.allSatisfy(\.isFinite) else { return [] }
    let norm = sqrt(query.reduce(0) { $0 + $1 * $1 })
    guard norm > 0 else { return [] }
    let stmt = try statement("SELECT id,vector FROM embeddings WHERE model=?")
    defer { sqlite3_finalize(stmt) }
    bind(model, to: stmt, at: 1)
    var best: [(String, Double)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      if cancelled() { throw CancellationError() }
      guard let id = sqlite3_column_text(stmt, 0), let bytes = sqlite3_column_blob(stmt, 1) else {
        continue
      }
      if let among, !among.contains(String(cString: id)) { continue }
      let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))
      guard let vector = try? JSONDecoder().decode([Double].self, from: data),
        vector.count == query.count
      else { continue }
      let otherNorm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
      guard otherNorm > 0 else { continue }
      let score = zip(query, vector).reduce(0) { $0 + $1.0 * $1.1 } / (norm * otherNorm)
      best.append((String(cString: id), score))
      best.sort { $0.1 > $1.1 }
      if best.count > max(1, limit) { best.removeLast() }
    }
    return best.map(\.0)
  }
}
