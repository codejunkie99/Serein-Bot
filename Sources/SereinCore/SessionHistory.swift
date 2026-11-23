import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Every past agent session on this Mac, from each harness's own store, for the Agents list and
/// the Projects page. Kept in the library with each source's stamp (device, inode, size, date;
/// a database's stamp includes its write-ahead log), so a launch shows the list at once and
/// re-reads only the sources that changed. No count limit. Read only with session discovery's
/// consent; transcript text stays on this Mac and is untrusted. Stores are opened read-only and
/// never changed.
public struct SessionHistory: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var stamp: String
    public var sessions: [DiscoveredSession]
  }
  public static let path = "agents/sessions.json"
  /// By source: a transcript file, or a database that holds many sessions.
  public private(set) var entries: [String: Entry] = [:]
  /// How the entries were read. A history saved by an older reader (nil or lower) is read again
  /// whole, so later fixes (redacted titles, Cursor folders) reach stamps that did not change.
  /// 3: sessions of the apps Serein no longer has leave the list.
  public private(set) var format: Int? = SessionHistory.currentFormat
  public static let currentFormat = 3
  public var isCurrent: Bool { format == Self.currentFormat }
  public init() {}
  /// Fixed sessions by source (previews).
  public init(sessions: [String: DiscoveredSession]) {
    entries = sessions.mapValues { Entry(stamp: "", sessions: [$0]) }
  }

  /// Newest first.
  public var sessions: [DiscoveredSession] {
    entries.values.flatMap(\.sessions).sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
  }

  /// Where each harness keeps its sessions on this Mac, after the variables each CLI reads.
  public struct Roots: Equatable, Sendable {
    public var claude, codexSessions, codexHome, opencodeDB, pi, ohMyPi, grok, cursorChats, cursorProjects: String
    public init(home: String, environment: [String: String] = [:]) {
      func env(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
      claude = (env("CLAUDE_CONFIG_DIR") ?? home + "/.claude") + "/projects"
      codexHome = env("CODEX_HOME") ?? home + "/.codex"
      codexSessions = codexHome + "/sessions"
      opencodeDB = (env("XDG_DATA_HOME") ?? home + "/.local/share") + "/opencode/opencode.db"
      pi = (env("PI_CODING_AGENT_DIR") ?? home + "/.pi/agent") + "/sessions"
      ohMyPi = home + "/.omp/agent/sessions"
      grok = (env("GROK_HOME") ?? home + "/.grok") + "/sessions"
      let cursor = env("CURSOR_CONFIG_DIR") ?? env("XDG_CONFIG_HOME").map { $0 + "/cursor" } ?? home + "/.cursor"
      cursorChats = cursor + "/chats"
      cursorProjects = home + "/.cursor/projects"
    }
    /// Folders to watch: each store's folder (a database's folder holds its log).
    public var folders: [String] {
      [claude, codexSessions, codexHome, pi, ohMyPi, grok, cursorChats, cursorProjects,
       (opencodeDB as NSString).deletingLastPathComponent]
    }
    /// Codex's newest thread database (`state_5.sqlite` today).
    public var codexDB: String? {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: codexHome)) ?? []
      return names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        .max { $0.compare($1, options: .numeric) == .orderedAscending }.map { codexHome + "/" + $0 }
    }
    /// The same paths with symbolic links resolved, as file walkers and FSEvents report them.
    var real: Roots {
      var r = self
      for key in [\Roots.claude, \.codexSessions, \.codexHome, \.opencodeDB, \.pi, \.ohMyPi, \.grok,
                  \.cursorChats, \.cursorProjects] {
        let path = r[keyPath: key]
        let parent = (path as NSString).deletingLastPathComponent
        r[keyPath: key] = FileManager.default.fileExists(atPath: path)
          ? SessionHistory.real(path) : SessionHistory.real(parent) + "/" + (path as NSString).lastPathComponent
      }
      return r
    }
  }

  /// The source a changed path belongs to, and its harness; nil for anything else. With a Codex
  /// thread database, its rollout files count as changes to it (one list, no doubles).
  public static func source(_ path: String, roots r: Roots, codexDB: String? = nil) -> (driver: HarnessDriver, source: String)? {
    func under(_ root: String) -> [Substring]? {
      path.hasPrefix(root + "/") ? path.dropFirst(root.count + 1).split(separator: "/") : nil
    }
    func database(_ db: String) -> Bool { path == db || path == db + "-wal" }
    if database(r.opencodeDB) { return (.opencode, r.opencodeDB) }
    if let parts = under(r.claude), parts.count == 2, path.hasSuffix(".jsonl") { return (.claude, path) }
    if let parts = under(r.codexHome), parts.count == 1 {
      let name = String(parts[0])
      if name.hasPrefix("state_"), name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal") {
        return (.codex, r.codexHome + "/" + (name.hasSuffix("-wal") ? String(name.dropLast(4)) : name))
      }
    }
    if under(r.codexSessions) != nil, (path as NSString).lastPathComponent.hasPrefix("rollout-"), path.hasSuffix(".jsonl") {
      return (.codex, codexDB ?? path)
    }
    for (driver, root) in [(HarnessDriver.pi, r.pi), (.ohMyPi, r.ohMyPi)] {
      if let parts = under(root), parts.count == 2, path.hasSuffix(".jsonl") { return (driver, path) }
    }
    if let parts = under(r.grok), parts.count == 3 {
      return (.grok, r.grok + "/" + parts[0] + "/" + parts[1] + "/summary.json")
    }
    if let parts = under(r.cursorChats), parts.count == 3, parts[2] == "store.db" || parts[2] == "store.db-wal" {
      return (.cursor, r.cursorChats + "/" + parts[0] + "/" + parts[1] + "/store.db")
    }
    if let parts = under(r.cursorProjects), parts.count == 4, parts[1] == "agent-transcripts", path.hasSuffix(".jsonl") {
      return (.cursor, path)
    }
    return nil
  }

  /// Every source on this Mac.
  public static func sources(roots r: Roots, fileManager fm: FileManager = .default) -> [String] {
    var out: [String] = []
    func walk(_ root: String, depth: Int, _ keep: (String) -> Bool) {
      guard let walker = fm.enumerator(atPath: root) else { return }
      while let relative = walker.nextObject() as? String {
        if walker.level > depth { walker.skipDescendants(); continue }
        if keep(relative) { out.append(root + "/" + relative) }
      }
    }
    walk(r.claude, depth: 2) { $0.hasSuffix(".jsonl") && $0.split(separator: "/").count == 2 }
    if let db = r.codexDB { out.append(db) } else {
      walk(r.codexSessions, depth: 4) { ($0 as NSString).lastPathComponent.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
    }
    if fm.fileExists(atPath: r.opencodeDB) { out.append(r.opencodeDB) }
    for root in [r.pi, r.ohMyPi] { walk(root, depth: 2) { $0.hasSuffix(".jsonl") } }
    walk(r.grok, depth: 3) { $0.hasSuffix("/summary.json") && $0.split(separator: "/").count == 3 }
    walk(r.cursorChats, depth: 3) { $0.hasSuffix("/store.db") }
    walk(r.cursorProjects, depth: 4) { relative in
      let parts = relative.split(separator: "/")
      return parts.count == 4 && parts[1] == "agent-transcripts" && relative.hasSuffix(".jsonl")
    }
    return out
  }

  /// Reads the given changed paths again (every source when `paths` is nil), skipping sources
  /// whose stamp is unchanged; sources that are gone leave the list. `known` are folders that
  /// Cursor's hashed and slugged names are matched against; sessions in `hidden` folders
  /// (Serein's own helpers) are never listed.
  public mutating func refresh(_ paths: Set<String>?, roots given: Roots, known: Set<String>, hidden: Set<String>) {
    let roots = given.real
    let codexDB = roots.codexDB
    var targets: [String: HarnessDriver] = [:]
    if let paths {
      for path in paths {
        if let hit = Self.source(path, roots: roots, codexDB: codexDB) {
          targets[hit.source] = hit.driver
          continue
        }
        // A folder moved, renamed, put back or deleted is reported once, not file by file: the
        // sessions stored under it are checked, and the files in it now are read.
        let inside = path.hasSuffix("/") ? path : path + "/"
        for key in entries.keys where key.hasPrefix(inside) {
          if let hit = Self.source(key, roots: roots, codexDB: codexDB) { targets[hit.source] = hit.driver }
        }
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, let walker = FileManager.default.enumerator(atPath: path) {
          while let relative = walker.nextObject() as? String {
            if walker.level > 4 { walker.skipDescendants(); continue }
            if let hit = Self.source(inside + relative, roots: roots, codexDB: codexDB) { targets[hit.source] = hit.driver }
          }
        }
      }
    } else {
      let all = Self.sources(roots: roots)
      entries = entries.filter { all.contains($0.key) }
      for path in all { if let hit = Self.source(path, roots: roots, codexDB: codexDB) { targets[hit.source] = hit.driver } }
    }
    let hiddenReal = Set(hidden.map(Self.real))
    // Cursor names folders by hash or slug, matched against every other session's folder: read last.
    var index: CursorIndex?
    func cursorIndex() -> CursorIndex {
      if let index { return index }
      let made = CursorIndex(known.union(entries.values.flatMap { $0.sessions.map(\.cwd) }).filter { !$0.isEmpty })
      index = made
      return made
    }
    for (source, driver) in targets.sorted(by: { ($0.value == .cursor ? 1 : 0, $0.key) < ($1.value == .cursor ? 1 : 0, $1.key) }) {
      guard let stamp = Self.stamp(source) else {
        entries[source] = nil
        continue
      }
      if entries[source]?.stamp == stamp { continue }
      let sessions = Self.read(source, driver: driver, cursor: driver == .cursor ? cursorIndex() : CursorIndex([]))
        .filter { $0.cwd.isEmpty || !hiddenReal.contains(Self.real($0.cwd)) }
      entries[source] = Entry(stamp: stamp, sessions: sessions)
    }
    // A Cursor chat read before its folder was known keeps its stamp: its folder comes from its
    // path alone, so it is matched again without a read.
    for (source, entry) in entries where entry.sessions.contains(where: { $0.provider == "cursor" && $0.cwd.isEmpty }) {
      let cwd = cursorIndex().folder(source)
      guard !cwd.isEmpty, !hiddenReal.contains(Self.real(cwd)) else { continue }
      entries[source]?.sessions = entry.sessions.map { session in
        var placed = session
        if placed.provider == "cursor", placed.cwd.isEmpty { placed.cwd = cwd }
        return placed
      }
    }
  }

  /// Known folders by the names Cursor gives them: the md5 of the path (`chats/<md5>/…/store.db`)
  /// and the slug (`projects/<slug>/agent-transcripts/…`). A name that several folders share
  /// (`/a/my-app` and `/a/my_app` have one slug) matches none, rather than one picked at random.
  struct CursorIndex {
    private var byName: [String: [String]] = [:]
    init(_ folders: Set<String>) {
      for folder in folders.sorted() {
        byName["md5:" + SessionHistory.md5(folder), default: []].append(folder)
        byName["slug:" + SessionHistory.cursorSlug(folder), default: []].append(folder)
      }
    }
    /// The one folder a Cursor source names, else "".
    func folder(_ source: String) -> String {
      let parts = source.split(separator: "/").map(String.init)
      let key: String
      if source.hasSuffix("store.db") {
        guard parts.count >= 3 else { return "" }
        key = "md5:" + parts[parts.count - 3]
      } else {
        guard parts.count >= 4 else { return "" }
        key = "slug:" + parts[parts.count - 4]
      }
      let hits = byName[key] ?? []
      return hits.count == 1 ? hits[0] : ""
    }
  }

  /// A file's stamp; a database's includes its write-ahead log.
  static func stamp(_ path: String) -> String? {
    func one(_ path: String) -> String? {
      var info = stat()
      guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
      return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }
    guard let main = one(path) else { return nil }
    let isDatabase = path.hasSuffix(".db") || path.hasSuffix(".sqlite")
    return isDatabase ? main + "|" + (one(path + "-wal") ?? "") : main
  }

  /// realpath(3): unlike URL.resolvingSymlinksInPath, it keeps the /private prefix.
  public static func real(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func modified(_ path: String) -> Date {
    var info = stat()
    var newest = lstat(path, &info) == 0 ? Double(info.st_mtimespec.tv_sec) : 0
    if lstat(path + "-wal", &info) == 0 { newest = max(newest, Double(info.st_mtimespec.tv_sec)) }
    return Date(timeIntervalSince1970: newest)
  }
  static func clean(_ title: String?) -> String? {
    SessionIndex.userTitle(title).map { AgentPrivacy.redact(String($0.prefix(160))) }
  }

  static func read(_ source: String, driver: HarnessDriver, cursor: CursorIndex) -> [DiscoveredSession] {
    switch driver {
    case .claude: return claude(source).map { [$0] } ?? []
    case .codex: return source.hasSuffix(".jsonl") ? codexRollout(source).map { [$0] } ?? [] : codex(source)
    case .opencode: return opencode(source)
    case .pi, .ohMyPi: return piFormat(source, driver: driver).map { [$0] } ?? []
    case .grok: return grok(source).map { [$0] } ?? []
    // No source: Serein does not read Gemini CLI's store (HarnessDriver.sessionStore).
    case .gemini: return []
    case .cursor:
      return (source.hasSuffix("store.db") ? cursorChat(source, cursor: cursor) : cursorTranscript(source, cursor: cursor))
        .map { [$0] } ?? []
    }
  }

  // MARK: Claude Code and Codex

  static func claude(_ path: String) -> DiscoveredSession? {
    let url = URL(fileURLWithPath: path)
    guard let head = SessionIndex.readHead(url),
      var session = SessionIndex.parseClaude(head: head, mtime: modified(path), fallbackID: url.deletingPathExtension().lastPathComponent)
    else { return nil }
    // Claude Code writes its own title (custom, then generated) as the session goes on; else the
    // first request, which may hold a secret, as every other harness's.
    if let tail = tail(path), let title = ExternalSessionReader.claudeTitle(tail) {
      session.title = AgentPrivacy.redact(title)
    } else {
      session.title = AgentPrivacy.redact(session.title)
    }
    session.file = path
    return session
  }

  /// A rollout file, for Codex versions without a thread database.
  static func codexRollout(_ path: String) -> DiscoveredSession? {
    let url = URL(fileURLWithPath: path)
    guard let head = SessionIndex.readHead(url),
      var session = SessionIndex.parseCodex(head: head, mtime: modified(path), fallbackID: url.deletingPathExtension().lastPathComponent)
    else { return nil }
    session.title = AgentPrivacy.redact(session.title)
    session.file = path
    return session
  }

  /// Codex's thread database: every thread, also those whose history lives only in the database
  /// (most do today). Archived threads and subagents are left out.
  static func codex(_ db: String) -> [DiscoveredSession] {
    let query = """
      SELECT id, cwd, COALESCE(NULLIF(name, ''), NULLIF(title, ''), first_user_message), updated_at, rollout_path, source
      FROM threads WHERE COALESCE(archived, 0) = 0
      """
    let fallback = """
      SELECT id, cwd, COALESCE(NULLIF(title, ''), first_user_message), updated_at, rollout_path, source
      FROM threads WHERE COALESCE(archived, 0) = 0
      """
    let rows = SQLiteRows.read(db, query) ?? SQLiteRows.read(db, fallback) ?? []
    return rows.compactMap { row in
      guard let id = row[0], let cwd = row[1], !(row[5] ?? "").hasPrefix("{") else { return nil }
      let updated = Double(row[3] ?? "") ?? 0
      let file = row[4].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
      return DiscoveredSession(
        provider: "codex", id: id, cwd: cwd, title: clean(row[2]) ?? "Codex session",
        date: Date(timeIntervalSince1970: updated > 1e11 ? updated / 1000 : updated), file: file)
    }
  }

  // MARK: OpenCode

  /// Group by `directory`, the real working folder; child sessions are subagents.
  static func opencode(_ db: String) -> [DiscoveredSession] {
    let rows = SQLiteRows.read(db, """
      SELECT id, directory, title, time_updated FROM session
      WHERE parent_id IS NULL AND time_archived IS NULL
      """) ?? []
    return rows.compactMap { row in
      guard let id = row[0], let cwd = row[1] else { return nil }
      return DiscoveredSession(
        provider: "opencode", id: id, cwd: cwd, title: clean(row[2]) ?? "OpenCode session",
        date: Date(timeIntervalSince1970: (Double(row[3] ?? "") ?? 0) / 1000))
    }
  }

  // MARK: Pi and Oh My Pi

  /// One file per session: a `session` header with id and cwd, then entries. The title is the
  /// last `session_info` name, else the first request.
  static func piFormat(_ path: String, driver: HarnessDriver) -> DiscoveredSession? {
    // The first 4 MB: a session with pictures or long tool output can be hundreds of MB.
    guard let data = SessionIndex.readHead(URL(fileURLWithPath: path), limit: 4_000_000) else { return nil }
    var id: String?, cwd: String?, name: String?, first: String?
    for line in data.split(separator: 10) {
      guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      switch json["type"] as? String {
      case "session":
        id = json["id"] as? String
        cwd = json["cwd"] as? String
      case "session_info":
        if let value = json["name"] as? String, !value.isEmpty { name = value }
      case "message" where first == nil:
        let message = json["message"] as? [String: Any] ?? [:]
        guard message["role"] as? String == "user" else { continue }
        if let text = message["content"] as? String { first = text }
        else {
          first = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
        }
      default: continue
      }
    }
    guard let id, let cwd else { return nil }
    return DiscoveredSession(
      provider: driver.rawValue, id: id, cwd: cwd,
      title: clean(name) ?? clean(first) ?? "\(driver.displayName) session", date: modified(path), file: path)
  }

  // MARK: Grok

  /// `summary.json` per session; subagent sessions are left out. The title is Grok's own when it
  /// made one, else the first request in the chat history.
  static func grok(_ summary: String) -> DiscoveredSession? {
    guard let data = FileManager.default.contents(atPath: summary),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let info = json["info"] as? [String: Any], let id = info["id"] as? String, let cwd = info["cwd"] as? String
    else { return nil }
    if let kind = json["session_kind"] as? String, kind.hasPrefix("subagent") { return nil }
    var title = clean(json["generated_title"] as? String)
    if title == nil {
      let history = (summary as NSString).deletingLastPathComponent + "/chat_history.jsonl"
      if let head = SessionIndex.readHead(URL(fileURLWithPath: history)) {
        for line in head.split(separator: 10) {
          guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            entry["type"] as? String == "user", entry["synthetic_reason"] == nil
          else { continue }
          let text = (entry["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
          title = clean(text.replacingOccurrences(of: "<user_query>", with: "").replacingOccurrences(of: "</user_query>", with: ""))
          if title != nil { break }
        }
      }
    }
    let date = SessionIndex.iso(json["last_active_at"]) ?? SessionIndex.iso(json["updated_at"]) ?? modified(summary)
    return DiscoveredSession(provider: "grok", id: id, cwd: cwd, title: title ?? "Grok session", date: date)
  }

  // MARK: Cursor

  /// `chats/<md5 of the folder>/<chat id>/store.db`: the folder is found by hashing known folders.
  static func cursorChat(_ db: String, cursor: CursorIndex) -> DiscoveredSession? {
    guard let hex = SQLiteRows.read(db, "SELECT value FROM meta WHERE key = '0'")?.first?[0],
      let data = Data(hexString: hex),
      let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let root = meta["latestRootBlobId"] as? String, !root.isEmpty
    else { return nil }
    let parts = db.split(separator: "/")
    let id = meta["agentId"] as? String ?? (parts.count >= 2 ? String(parts[parts.count - 2]) : "")
    let cwd = cursor.folder(db)
    let name = (meta["name"] as? String).flatMap { $0 == "New Agent" ? nil : $0 }
    return DiscoveredSession(provider: "cursor", id: id, cwd: cwd, title: clean(name) ?? "Cursor chat", date: modified(db))
  }

  /// `projects/<slug>/agent-transcripts/<id>/<id>.jsonl`: the slug is the folder with every other
  /// character a dash, so it is matched against known folders.
  static func cursorTranscript(_ path: String, cursor: CursorIndex) -> DiscoveredSession? {
    let url = URL(fileURLWithPath: path)
    let parts = url.pathComponents
    guard parts.count >= 4, let head = SessionIndex.readHead(url) else { return nil }
    var first: String?
    for line in head.split(separator: 10) {
      guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        json["role"] as? String == "user"
      else { continue }
      let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
      let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
      first = text.replacingOccurrences(of: "<user_query>", with: "").replacingOccurrences(of: "</user_query>", with: "")
      if clean(first) != nil { break }
    }
    let cwd = cursor.folder(path)
    return DiscoveredSession(
      provider: "cursor", id: url.deletingPathExtension().lastPathComponent, cwd: cwd,
      title: clean(first) ?? "Cursor chat", date: modified(path), file: path)
  }

  public static func md5(_ text: String) -> String {
    Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public static func cursorSlug(_ path: String) -> String {
    var out = ""
    for scalar in path.unicodeScalars {
      let keep = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
      if keep { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("-") { out += "-" }
    }
    return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  static func tail(_ path: String, bytes: Int = 64 * 1024) -> Data? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
    return try? handle.read(upToCount: bytes)
  }
}

/// Read-only SQLite reads of another app's store. Never `immutable`: rows still in the
/// write-ahead log must be seen. Text columns (`read`) or raw bytes (`readData`); nil when the
/// query does not fit the schema.
enum SQLiteRows {
  /// `values` fill the statement's `?` placeholders in order.
  static func read(_ path: String, _ sql: String, _ values: [String] = []) -> [[String?]]? {
    rows(path, sql, values) { statement, column in
      sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
  }
  /// Each column's bytes, so a BLOB (an archived message text) survives its NUL bytes; text and
  /// numbers come back as their text. nil for NULL and for an empty value.
  static func readData(_ path: String, _ sql: String, _ values: [String] = []) -> [[Data?]]? {
    rows(path, sql, values) { statement, column in
      guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
      return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
  }
  private static func rows<Cell>(
    _ path: String, _ sql: String, _ values: [String], _ cell: (OpaquePointer, Int32) -> Cell?
  ) -> [[Cell?]]? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }
      return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      sqlite3_finalize(statement)
      return nil
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    var found: [[Cell?]] = []
    let columns = sqlite3_column_count(statement)
    while sqlite3_step(statement) == SQLITE_ROW {
      found.append((0..<columns).map { cell(statement, $0) })
    }
    return found
  }
}

extension Data {
  init?(hexString: String) {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hexString.utf8.count / 2)
    var high: UInt8?
    for c in hexString.utf8 {
      let v: UInt8
      switch c {
      case 48...57: v = c - 48
      case 65...70: v = c - 55
      case 97...102: v = c - 87
      default: return nil
      }
      if let h = high { bytes.append(h << 4 | v); high = nil } else { high = v }
    }
    guard high == nil else { return nil }
    self.init(bytes)
  }
}

/// `codex cloud list --json`: the user's Codex Cloud tasks, read by the Codex CLI with its own
/// sign-in. Status is one of pending, ready, applied, error.
public struct CloudTask: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var status: String
  public var url: String?
  public var environment: String?
  public var updatedAt: Date?
  public init(id: String, title: String, status: String, url: String? = nil, environment: String? = nil, updatedAt: Date? = nil) {
    self.id = id
    self.title = title
    self.status = status
    self.url = url
    self.environment = environment
    self.updatedAt = updatedAt
  }

  /// One page of `codex cloud list --json`: its tasks and the cursor of the next page, if any.
  public static func page(_ data: Data) -> (tasks: [CloudTask], cursor: String?) {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return (list(data), (json["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 })
  }
  public static func list(_ data: Data) -> [CloudTask] {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let iso = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (json["tasks"] as? [[String: Any]] ?? []).compactMap { task in
      guard let id = task["id"] as? String, !id.isEmpty else { return nil }
      let updated: Date? =
        (task["updated_at"] as? String).flatMap { fractional.date(from: $0) ?? iso.date(from: $0) }
        ?? (task["updated_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
      return CloudTask(
        id: String(id.prefix(120)), title: AgentPrivacy.redact(String(((task["title"] as? String) ?? "Codex Cloud task").prefix(160))),
        status: String(((task["status"] as? String) ?? "").prefix(20)),
        url: (task["url"] as? String).flatMap { $0.hasPrefix("https://") ? String($0.prefix(500)) : nil },
        environment: (task["environment_label"] as? String).map { String($0.prefix(80)) }, updatedAt: updated)
    }
  }
}
