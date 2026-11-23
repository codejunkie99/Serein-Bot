import Darwin
import Foundation

/// A helper a running outside session started: one of Claude Code's subagents (its own transcript
/// under `<session>/subagents/`) or a Codex thread spawned by the session (a session file whose
/// header names it as the parent). Display evidence only, like `ExternalSession`.
public struct ExternalSubagent: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  /// running or needsUser while it works; nil once it finished.
  public var state: ExternalSession.State?
  public var updatedAt: Date
  /// Its own transcript, inside the session's harness folder; nil in previews.
  public var log: String?
  public init(id: String, title: String, state: ExternalSession.State?, updatedAt: Date, log: String? = nil) {
    self.id = id; self.title = title; self.state = state; self.updatedAt = updatedAt; self.log = log
  }
}

/// Serial-use cache, run with the session scan. It reads only logs inside the session's own
/// harness folder: each helper's 64 KiB tail (for its state), Claude Code's small `.meta.json`
/// (for its description) and the first line of Codex files beside the session (once per file).
public struct ExternalSubagentReader {
  /// The newest helpers kept per session.
  public static let limit = 12
  /// A helper whose file has not changed for this long has stopped, whatever its last line says.
  public static let stale: TimeInterval = 10 * 60
  private struct Header {
    var stamp: String
    var parent: String?
    var title: String
  }
  private var headers: [String: Header] = [:]
  public init() {}

  /// Helpers by the session's id, for sessions that have any.
  public mutating func read(_ sessions: [ExternalSession], home: String = NSHomeDirectory(), now: Date = Date())
    -> [String: [ExternalSubagent]]
  {
    var found: [String: [ExternalSubagent]] = [:]
    for session in sessions {
      guard let log = session.log, ExternalSessionReader.allowedLog(log, driver: session.driver, home: home) else { continue }
      let helpers: [ExternalSubagent]
      switch session.driver {
      case .claude: helpers = Self.claude(log: log, now: now)
      case .codex: helpers = codex(sessionID: String(session.id.drop { $0 != ":" }.dropFirst()), log: log, now: now)
      default: helpers = []
      }
      if !helpers.isEmpty { found[session.id] = helpers }
    }
    headers = headers.filter { FileManager.default.fileExists(atPath: $0.key) }
    return found
  }

  /// `<session>.jsonl` → `<session>/subagents/agent-<id>.jsonl`, named by its `.meta.json`
  /// description (else its agent type).
  static func claude(log: String, now: Date) -> [ExternalSubagent] {
    let folder = String(log.dropLast(".jsonl".count)) + "/subagents"
    let files = newest(in: folder) { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
    return files.map { path, date in
      let base = String(path.dropLast(".jsonl".count))
      var title = "Subagent"
      if let data = small(base + ".meta.json"),
        let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        title = (meta["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          ?? (meta["agentType"] as? String) ?? title
      }
      let state = now.timeIntervalSince(date) > stale ? nil : tail(path).flatMap(ExternalSessionReader.claudeState)
      let id = String(URL(fileURLWithPath: base).lastPathComponent.dropFirst("agent-".count))
      return ExternalSubagent(id: "claude:" + id, title: String(title.prefix(120)), state: state, updatedAt: date, log: path)
    }
  }

  /// Codex files in the session's day folder whose header says `parent_thread_id` is this session
  /// (`source.subagent.thread_spawn`); named by the agent's nickname and the path it was given.
  mutating func codex(sessionID: String, log: String, now: Date) -> [ExternalSubagent] {
    guard !sessionID.isEmpty else { return [] }
    let folder = (log as NSString).deletingLastPathComponent
    var helpers: [ExternalSubagent] = []
    for (path, date) in Self.newest(in: folder, keep: 200, { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }) where path != log {
      guard let header = header(path), header.parent == sessionID else { continue }
      let state = now.timeIntervalSince(date) > Self.stale ? nil : Self.tail(path).flatMap(ExternalSessionReader.codexState)
      helpers.append(ExternalSubagent(id: "codex:" + URL(fileURLWithPath: path).lastPathComponent, title: header.title,
                                      state: state, updatedAt: date, log: path))
      if helpers.count == Self.limit { break }
    }
    return helpers
  }

  private mutating func header(_ path: String) -> Header? {
    guard let stamp = Self.stamp(path) else { return nil }
    if let cached = headers[path], cached.stamp == stamp { return cached }
    var header = Header(stamp: stamp, parent: nil, title: "Subagent")
    if let line = Self.firstLine(path),
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let payload = object["payload"] as? [String: Any],
      let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
    {
      header.parent = spawn["parent_thread_id"] as? String
      let nickname = (spawn["agent_nickname"] as? String) ?? ""
      let task = ((spawn["agent_path"] as? String) ?? "").split(separator: "/").last
        .map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
      header.title = String([nickname, task].filter { !$0.isEmpty }.joined(separator: ": ").prefix(120))
      if header.title.isEmpty { header.title = "Subagent" }
    }
    headers[path] = header
    return header
  }

  /// Regular files in `folder` matching `name`, newest first.
  private static func newest(in folder: String, keep: Int = limit, _ name: (String) -> Bool) -> [(String, Date)] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
    var files: [(String, Date)] = []
    for file in names where name(file) {
      let path = folder + "/" + file
      var info = stat()
      guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
      files.append((path, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))))
    }
    return Array(files.sorted { $0.1 > $1.1 }.prefix(keep))
  }
  private static func stamp(_ path: String) -> String? {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec)"
  }
  private static func handle(_ path: String) -> FileHandle? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
  }
  /// A small JSON file, at most 16 KiB.
  private static func small(_ path: String) -> Data? {
    guard let handle = handle(path) else { return nil }
    defer { try? handle.close() }
    return try? handle.read(upToCount: 16 * 1024)
  }
  /// The last 64 KiB, cut to whole lines.
  private static func tail(_ path: String) -> Data? {
    guard let handle = handle(path) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let offset = size > 64 * 1024 ? size - 64 * 1024 : 0
    guard (try? handle.seek(toOffset: offset)) != nil, var data = try? handle.readToEnd() else { return nil }
    if offset > 0, let newline = data.firstIndex(of: 10) { data = Data(data[data.index(after: newline)...]) }
    if let newline = data.lastIndex(of: 10) { data = Data(data[...newline]) } else { data = Data() }
    return data
  }
  /// The first line (Codex's session header), at most 2 MiB.
  private static func firstLine(_ path: String) -> Data? {
    guard let handle = handle(path) else { return nil }
    defer { try? handle.close() }
    var line = Data()
    while line.count < 2 * 1024 * 1024, let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      if let newline = chunk.firstIndex(of: 10) { return line + chunk[..<newline] }
      line += chunk
    }
    return nil
  }
}
