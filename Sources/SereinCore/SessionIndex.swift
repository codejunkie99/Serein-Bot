import Foundation

/// One CLI session found in local Claude Code or Codex history. Content is untrusted data.
public struct DiscoveredSession: Codable, Equatable, Sendable {
  /// The harness's raw value ("claude", "codex", "opencode", "grok", …).
  public var provider: String
  public var id: String
  /// The folder it ran in; empty when the store does not say (some Cursor transcripts).
  public var cwd: String
  public var title: String
  public var date: Date
  /// The transcript file, where the harness resumes or Serein imports by file.
  public var file: String?
  public init(provider: String, id: String, cwd: String, title: String, date: Date, file: String? = nil) {
    self.provider = provider
    self.id = id
    self.cwd = cwd
    self.title = title
    self.date = date
    self.file = file
  }
}

/// A folder that appears in CLI history, with its newest sessions.
public struct DiscoveredProject: Codable, Equatable, Identifiable {
  public var path: String
  public var name: String
  public var lastActive: Date
  public var sessions: [DiscoveredSession]  // newest first, at most 5
  public var id: String { path }
}

/// Pure parsers and a bounded scanner for `~/.claude/projects` and `~/.codex/sessions`.
/// Nothing here runs until the caller invokes it; the app only does so after the user agrees.
public enum SessionIndex {
  public static let headLimit = 64 * 1024
  static let filesPerRoot = 400
  static let filesPerClaudeFolder = 8

  // MARK: Reading

  /// Reads at most `limit` bytes and drops a trailing partial line when the file was cut.
  public static func readHead(_ url: URL, limit: Int = headLimit) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
    guard data.count > limit else { return data }
    var head = data.prefix(limit)
    if let newline = head.lastIndex(of: 10) { head = head.prefix(upTo: newline) }
    return Data(head)
  }

  // MARK: Parsing

  static func lines(_ head: Data) -> [Substring] {
    String(decoding: head, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
  }
  static func object(_ line: Substring) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
  }
  static func text(of content: Any?) -> String? {
    if let s = content as? String { return s }
    if let parts = content as? [[String: Any]] {
      let joined = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
      return joined.isEmpty ? nil : joined
    }
    return nil
  }
  /// Skips wrapper text that CLIs inject before the person's own first message.
  public static func userTitle(_ raw: String?) -> String? {
    guard var s = userRequest(raw) else { return nil }
    // A link reads as its words: "[PR #318](https://…)" is "PR #318"; a bare address as its host.
    s = s.replacingOccurrences(of: #"\[([^\]\n]+)\]\([^)\s]+\)"#, with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: #"https?://(?:www\.)?([^/\s]+)[^\s]*"#, with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "\n", with: " ")
    while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
    return String(s.prefix(120))
  }
  /// The person's own words in a message, line breaks kept; nil for text a CLI or client added.
  public static func userRequest(_ raw: String?) -> String? {
    guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
      return nil
    }
    for skip in [
      "<command-", "<local-command", "<environment_context", "<user_instructions", "# AGENTS.md",
      "<INSTRUCTIONS", "Caveat:", "<system-reminder", "[Request interrupted", "<task-notification", "<codex_internal_context",
    ] where s.hasPrefix(skip) { return nil }
    // Pi puts the files it was given (Serein's pictures) first, as <file name="…">…</file>.
    while s.hasPrefix("<file name=\""), let end = s.range(of: "</file>") {
      s = String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if s.isEmpty { return nil }
    // Serein's own context (attached pages, elements, pictures, console errors, plan mode) comes
    // first; the request follows the "User request:" line that no block closes after. Page text
    // can hold that line, but never a block's closing tag (UntrustedText.escape).
    if PageContext.openings.contains(where: s.hasPrefix) {
      let closing = #"</(untrusted_[a-z_]+|pointed_element|serein_facts)>"#
      var markers: [Range<String.Index>] = []
      var from = s.startIndex
      while let marker = s.range(of: "\n\nUser request:\n", range: from..<s.endIndex) {
        markers.append(marker)
        from = marker.upperBound
      }
      let last = markers.first { s.range(of: closing, options: .regularExpression, range: $0.upperBound..<s.endIndex) == nil }
      if let marker = last ?? markers.last {
        s = String(s[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
      }
    }
    // The Codex app puts attached files first; the request follows "## My request:".
    if s.hasPrefix("# Files mentioned by the user") {
      guard let heading = s.range(of: "\n## My request") else { return nil }
      s = String(s[heading.upperBound...].drop { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty { return nil }
    }
    // Blocks a client wraps around the request (<timestamp>…</timestamp>, <image_files>…) and
    // image markers are not the request.
    s = s.replacingOccurrences(of: #"<([A-Za-z_]+)>[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\[Image[^\]]*\]"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    // Text a host adds after the request ("<host_note>…") is not the request.
    if let note = s.range(of: "<host_note>") {
      let before = s[..<note.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      if !before.isEmpty { s = before }
    }
    return s
  }
  public static func iso(_ value: Any?) -> Date? {
    guard let s = value as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
  }

  /// Claude Code: lines carry `cwd`, `sessionId`, `message.content`. `fallbackID` is the file stem.
  /// The session date is the file's modification time.
  public static func parseClaude(head: Data, mtime: Date, fallbackID: String) -> DiscoveredSession? {
    var cwd: String?
    var id: String?
    var title: String?
    for line in lines(head) {
      guard let obj = object(line) else { continue }
      if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
      if id == nil, let s = obj["sessionId"] as? String { id = s }
      if title == nil, obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
        let message = obj["message"] as? [String: Any], message["role"] as? String == "user"
      {
        title = userTitle(text(of: message["content"]))
      }
      if cwd != nil && title != nil { break }
    }
    guard let cwd else { return nil }
    return DiscoveredSession(
      provider: "claude", id: id ?? fallbackID, cwd: cwd, title: title ?? "Untitled session",
      date: mtime)
  }

  /// Codex: first line is `session_meta` with `payload.{id,cwd,timestamp}`. A very long first line
  /// that was cut at the byte limit still yields `cwd` and `id` through a text fallback.
  public static func parseCodex(head: Data, mtime: Date, fallbackID: String) -> DiscoveredSession? {
    var cwd: String?
    var id: String?
    var title: String?
    var date: Date?
    for (index, line) in lines(head).enumerated() {
      if let obj = object(line) {
        let payload = obj["payload"] as? [String: Any] ?? [:]
        switch obj["type"] as? String {
        case "session_meta":
          cwd = cwd ?? payload["cwd"] as? String
          id = id ?? payload["id"] as? String
          date = date ?? iso(payload["timestamp"]) ?? iso(obj["timestamp"])
        case "event_msg":
          if title == nil, payload["type"] as? String == "user_message" {
            title = userTitle(payload["message"] as? String)
          }
        case "response_item":
          if title == nil, payload["type"] as? String == "message",
            payload["role"] as? String == "user"
          {
            title = userTitle(text(of: payload["content"]))
          }
        default: break
        }
      } else if index == 0 {
        let s = String(line)
        cwd = firstMatch(#""cwd"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: s).map(unescape)
        id = firstMatch(#""id"\s*:\s*"([0-9a-fA-F-]{8,})""#, in: s)
      }
      if cwd != nil && title != nil { break }
    }
    guard let cwd else { return nil }
    return DiscoveredSession(
      provider: "codex", id: id ?? fallbackID, cwd: cwd, title: title ?? "Untitled session",
      date: date ?? mtime)
  }
  static func firstMatch(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
      let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
      let r = Range(m.range(at: 1), in: s)
    else { return nil }
    return String(s[r])
  }
  static func unescape(_ s: String) -> String {
    (try? JSONSerialization.jsonObject(
      with: Data("\"\(s)\"".utf8), options: [.fragmentsAllowed]) as? String) ?? s
  }

  // MARK: Grouping

  /// Resolves paths, drops missing or uninteresting folders, and dedupes by resolved path.
  public static func group(
    _ sessions: [DiscoveredSession], home: String = NSHomeDirectory(),
    fileManager: FileManager = .default
  ) -> [DiscoveredProject] {
    var byPath: [String: [DiscoveredSession]] = [:]
    var usable: [String: Bool] = [:]
    for var s in sessions {
      guard !Task.isCancelled else { return [] }
      guard s.cwd.hasPrefix("/") else { continue }
      let path = URL(fileURLWithPath: s.cwd).resolvingSymlinksInPath().standardized.path
      if usable[path] == nil {
        var isDir: ObjCBool = false
        usable[path] =
          fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
          && !isUninteresting(path, home: home)
      }
      guard usable[path] == true else { continue }
      s.cwd = path
      byPath[path, default: []].append(s)
    }
    return byPath.map { path, list in
      let sorted = list.sorted { $0.date > $1.date }
      return DiscoveredProject(
        path: path, name: URL(fileURLWithPath: path).lastPathComponent,
        lastActive: sorted[0].date, sessions: Array(sorted.prefix(5)))
    }.sorted { $0.lastActive > $1.lastActive }
  }
  static func isUninteresting(_ path: String, home: String) -> Bool {
    let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
    if path == "/" || path == resolvedHome { return true }
    for part in ["/.claude/worktrees/", "/.codex/", "/node_modules/"] where path.contains(part) {
      return true
    }
    return path.hasPrefix("/private/tmp") || path.hasPrefix("/private/var/folders")
  }

  // MARK: Scanning

  static func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      ?? .distantPast
  }
  /// What the last pass listed and read, kept so that a pass after a file event lists only the
  /// folders the event touched and reads only the files whose time changed. Throwaway.
  public struct Scan: Sendable {
    struct File: Sendable {
      var path: String
      var modified: Date
    }
    struct Root: Sendable {
      /// Each folder's session files, as last listed.
      var listed: [String: [File]] = [:]
      /// What each file's head gave, by path, with the time the file had when it was read.
      var read: [String: (modified: Date, session: DiscoveredSession?)] = [:]
    }
    var claude = Root()
    var codex = Root()
    public init() {}
  }

  /// The folders a pass lists again for FSEvents `paths`: the Claude Code project folder
  /// (`root/<folder>`) a path falls in, or for Codex the folder holding a session file (a folder's
  /// own event names itself). Nil when a path is a root itself or outside both: list everything.
  public static func touched(_ paths: [String], claudeRoot: URL, codexRoot: URL)
    -> (claude: Set<String>, codex: Set<String>)?
  {
    var claude: Set<String> = []
    var codex: Set<String> = []
    for event in paths {
      let path = event.hasSuffix("/") ? String(event.dropLast()) : event
      if path.hasPrefix(claudeRoot.path + "/"),
        let folder = path.dropFirst(claudeRoot.path.count + 1).split(separator: "/").first
      {
        claude.insert(claudeRoot.path + "/" + folder)
      } else if path.hasPrefix(codexRoot.path + "/") {
        codex.insert(path.hasSuffix(".jsonl") ? (path as NSString).deletingLastPathComponent : path)
      } else {
        return nil
      }
    }
    return (claude, codex)
  }

  /// One pass over both roots: lists the `touched` folders again (every folder when nil, as at
  /// launch) and reads the head of each file new or changed since `scan` read it. It finds the
  /// sessions a pass that read everything would find.
  public static func sessions(
    claudeRoot: URL, codexRoot: URL, touched: (claude: Set<String>, codex: Set<String>)?, scan: inout Scan,
    fileManager fm: FileManager = .default
  ) -> [DiscoveredSession] {
    // Paths are built from the roots' own strings, as `touched` builds them, so a folder listed
    // after an event replaces the one listed at launch.
    if let touched {
      for folder in touched.claude { scan.claude.listed[folder] = claudeFiles(folder, fm) }
      for folder in touched.codex {
        scan.codex.listed = scan.codex.listed.filter { $0.key != folder && !$0.key.hasPrefix(folder + "/") }
        scan.codex.listed.merge(codexFiles(under: folder, fm)) { $1 }
      }
    } else {
      let folders = ((try? fm.contentsOfDirectory(atPath: claudeRoot.path)) ?? []).map { claudeRoot.path + "/" + $0 }
      scan.claude.listed = Dictionary(folders.map { ($0, claudeFiles($0, fm)) }) { $1 }
      scan.codex.listed = codexFiles(under: codexRoot.path, fm)
    }
    return sessions(&scan.claude) { parseClaude(head: $0, mtime: $1, fallbackID: $2) }
      + sessions(&scan.codex) { parseCodex(head: $0, mtime: $1, fallbackID: $2) }
  }
  /// A Claude Code project folder's newest transcripts.
  static func claudeFiles(_ folder: String, _ fm: FileManager) -> [Scan.File] {
    let files = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".jsonl") }.map {
      Scan.File(path: folder + "/" + $0, modified: modified(URL(fileURLWithPath: folder + "/" + $0)))
    }
    return Array(files.sorted { $0.modified > $1.modified }.prefix(filesPerClaudeFolder))
  }
  /// Codex's session files under `folder`, by the folder that holds each.
  static func codexFiles(under folder: String, _ fm: FileManager) -> [String: [Scan.File]] {
    guard let walker = fm.enumerator(atPath: folder) else { return [:] }
    var files: [String: [Scan.File]] = [:]
    for case let relative as String in walker {
      guard !Task.isCancelled else { return [:] }
      let name = (relative as NSString).lastPathComponent
      // Hidden folders are not walked, as Codex keeps none of its sessions there.
      if name.hasPrefix(".") { walker.skipDescendants() }
      guard name.hasSuffix(".jsonl"), name.hasPrefix("rollout-") else { continue }
      let path = folder + "/" + relative
      files[(path as NSString).deletingLastPathComponent, default: []]
        .append(Scan.File(path: path, modified: modified(URL(fileURLWithPath: path))))
    }
    return files
  }
  /// The newest `filesPerRoot` files of a root, each read again only when its time changed.
  static func sessions(_ root: inout Scan.Root, parse: (Data, Date, String) -> DiscoveredSession?) -> [DiscoveredSession] {
    let files = root.listed.values.joined().sorted { $0.modified > $1.modified }.prefix(filesPerRoot)
    var read: [String: (modified: Date, session: DiscoveredSession?)] = [:]
    var sessions: [DiscoveredSession] = []
    for file in files {
      guard !Task.isCancelled else { return [] }
      if let known = root.read[file.path], known.modified == file.modified {
        read[file.path] = known
      } else {
        let url = URL(fileURLWithPath: file.path)
        // Each head and its parsed lines are freed before the next file, not after the last.
        let parsed: DiscoveredSession?? = autoreleasepool {
          readHead(url).map { parse($0, file.modified, url.deletingPathExtension().lastPathComponent) }
        }
        // A head that could not be read is tried again next pass.
        guard let parsed else { continue }
        read[file.path] = (file.modified, parsed)
      }
      if let session = read[file.path]?.session { sessions.append(session) }
    }
    root.read = read
    return sessions
  }
  /// The full scan of both roots, grouped by resolved folder. Call only after consent.
  public static func discover(claudeRoot: URL, codexRoot: URL, home: String = NSHomeDirectory())
    -> [DiscoveredProject]
  {
    var scan = Scan()
    return group(sessions(claudeRoot: claudeRoot, codexRoot: codexRoot, touched: nil, scan: &scan), home: home)
  }
  public static func defaultClaudeRoot(home: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
  }
  public static func defaultCodexRoot(home: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: home).appendingPathComponent(".codex/sessions")
  }
}

// MARK: - Repository summary

public struct GitSummary: Codable, Equatable {
  public var branch: String
  public var commits: [String]
  public init(branch: String, commits: [String]) {
    self.branch = branch
    self.commits = commits
  }
  public static func parse(branch: String, log: String) -> GitSummary {
    GitSummary(
      branch: String(branch.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
      commits: log.split(separator: "\n").prefix(5).map { String($0.prefix(160)) })
  }
  static func run(_ args: [String], timeout: TimeInterval) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch { return nil }
    final class Box: @unchecked Sendable { var data = Data() }
    let box = Box()
    let read = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      box.data = out.fileHandleForReading.readDataToEndOfFile()
      read.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = done.wait(timeout: .now() + 1)
      return nil
    }
    _ = read.wait(timeout: .now() + 1)
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: box.data.prefix(64_000), as: UTF8.self)
  }
  /// Branch and the last five commit subjects via `/usr/bin/git -C`. Nil when not a repository.
  public static func read(path: String, timeout: TimeInterval = 3) -> GitSummary? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
      let branch = run(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout)
    else { return nil }
    let log = run(["-C", path, "--no-pager", "log", "-5", "--format=%s"], timeout: timeout) ?? ""
    return parse(branch: branch, log: log)
  }
}

// MARK: - Activity markers

public struct ProjectActivityState: Equatable {
  public var running = false
  public var needsYou = false
  public var doneToday = false
  public var lastEvent: Date?
  public init() {}
}

public enum ProjectActivity {
  /// Activity per project id from the run log (latest record per run).
  public static func states(
    runs: [RunRecord], now: Date = Date(), calendar: Calendar = .current
  ) -> [String: ProjectActivityState] {
    var result: [String: ProjectActivityState] = [:]
    for run in runs {
      guard let id = run.projectID else { continue }
      var state = result[id] ?? ProjectActivityState()
      switch run.outcome {
      case .running: state.running = true
      case .waiting: state.needsYou = true
      case .done:
        if calendar.isDate(run.endedAt ?? run.lastEventAt, inSameDayAs: now) {
          state.doneToday = true
        }
      case .stuck, .stopped: break
      }
      state.lastEvent = max(state.lastEvent ?? .distantPast, run.lastEventAt)
      result[id] = state
    }
    return result
  }
  /// Higher sorts first: needs you, then running, then done today.
  public static func rank(_ state: ProjectActivityState?) -> Int {
    guard let state else { return 0 }
    return (state.needsYou ? 8 : 0) + (state.running ? 4 : 0) + (state.doneToday ? 2 : 0)
  }
}

extension ProjectInsight {
  public static let path = "projects/insights.json"
  public static func loadAll(library: Library) -> [String: ProjectInsight] {
    library.load([String: ProjectInsight].self, from: path) ?? [:]
  }
  public static func saveAll(_ all: [String: ProjectInsight], library: Library) throws {
    try library.save(all, to: path)
  }
}

// MARK: - Routing evidence

public struct ProjectInsight: Codable, Equatable {
  public var sessionTitles: [String]
  public var git: GitSummary?
  public init(sessionTitles: [String] = [], git: GitSummary? = nil) {
    self.sessionTitles = sessionTitles
    self.git = git
  }
  /// String fields for the router's project entry. The whole entry is untrusted data.
  public var routingFields: [String: String] {
    var f: [String: String] = [:]
    if !sessionTitles.isEmpty {
      f["recent_sessions"] = sessionTitles.prefix(5).joined(separator: " | ")
    }
    if let git {
      f["branch"] = git.branch
      if !git.commits.isEmpty { f["recent_commits"] = git.commits.joined(separator: " | ") }
    }
    return f
  }
}
