import Foundation

/// What a report shows besides its words: the lines a session changed (biggest files as bars),
/// how its tests went, how long it worked, and the pictures, videos and sounds it made. The host
/// builds it from facts (git, the project folder, the transcript's steps), never from a model, and
/// it is display only: no part of it is ever given to a model. A session report has one session's
/// reel; the morning brief has yesterday's, rolled up from those (`day`).
public struct ReportReel: Codable, Equatable, Sendable {
  public enum Tests: String, Codable, Sendable { case passed, failed }

  public struct FileChange: Codable, Equatable, Sendable {
    /// Its place in the project ("app/page.tsx").
    public var path: String
    public var added: Int
    public var removed: Int
    public init(path: String, added: Int, removed: Int) {
      self.path = path
      self.added = added
      self.removed = removed
    }
    public var churn: Int { added + removed }
  }

  public struct Media: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, video, audio }
    public var kind: Kind
    /// Its copy in the library ("chat-images/reel-<id>.mp4"); the original may change or go.
    public var path: String
    /// The original's file name, as the card's caption.
    public var name: String
    /// The project it came from, by its display name.
    public var project: String?
    public var made: Date
    public init(kind: Kind, path: String, name: String, project: String?, made: Date) {
      self.kind = kind
      self.path = path
      self.name = name
      self.project = project
      self.made = made
    }
    public var id: String { path }
  }

  /// "Codex in stxs", or "Yesterday".
  public var title: String
  /// The biggest changes, at most `fileLimit`.
  public var files: [FileChange] = []
  /// Every file changed, with those not listed.
  public var filesTotal = 0
  public var added = 0
  public var removed = 0
  public var tests: Tests?
  /// Minutes of work; nil when unknown.
  public var minutes: Int?
  /// Newest first, at most `mediaLimit`.
  public var media: [Media] = []
  /// A day's reel only: how many sessions it rolls up, and in which projects.
  public var sessions: Int?
  public var projects: [String]?

  public init(title: String) { self.title = title }

  public static let fileLimit = 4
  public static let mediaLimit = 12
  /// What a card holds of one kind, so one busy screenshot folder does not crowd out a video. The
  /// card draws four tiles at most; the viewer pages through the rest.
  public static let perKind: [Media.Kind: Int] = [.image: 8, .video: 2, .audio: 2]
  /// Copies larger than this stay out: a report is not a backup.
  public static let maxBytes: [Media.Kind: Int] = [.image: 20_000_000, .video: 150_000_000, .audio: 50_000_000]

  /// Nothing worth drawing: no changes, no tests and nothing made.
  public var isEmpty: Bool { filesTotal == 0 && tests == nil && media.isEmpty }

  // MARK: Git

  /// `git diff --numstat` / `git log --numstat --format=` output as changes, one per path, biggest
  /// first. Binary files ("-\t-\tpath") count as changed with no lines; a rename
  /// ("a => b", "dir/{a => b}") is its new name.
  public static func numstat(_ output: String) -> [FileChange] {
    var byPath: [String: FileChange] = [:]
    var order: [String] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else { continue }
      let path = renamed(String(parts[2]))
      guard !path.isEmpty else { continue }
      let added = Int(parts[0]) ?? 0
      let removed = Int(parts[1]) ?? 0
      guard parts[0] == "-" || Int(parts[0]) != nil else { continue }
      if var known = byPath[path] {
        known.added += added
        known.removed += removed
        byPath[path] = known
      } else {
        byPath[path] = FileChange(path: path, added: added, removed: removed)
        order.append(path)
      }
    }
    // Biggest first; ties keep git's order.
    return order.enumerated().compactMap { index, path in byPath[path].map { (index, $0) } }
      .sorted { $0.1.churn != $1.1.churn ? $0.1.churn > $1.1.churn : $0.0 < $1.0 }
      .map(\.1)
  }

  private static func renamed(_ path: String) -> String {
    if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}"), open < close,
      let arrow = path[open...close].range(of: " => ")
    {
      let head = path[..<open]
      let tail = path[path.index(after: close)...]
      let new = path[arrow.upperBound..<close]
      return (head + new + tail).replacingOccurrences(of: "//", with: "/")
    }
    if let arrow = path.range(of: " => ") { return String(path[arrow.upperBound...]) }
    return path
  }

  /// The reel's changes from `files`: totals over all, bars for the biggest.
  public mutating func setChanges(_ files: [FileChange]) {
    filesTotal = files.count
    added = files.reduce(0) { $0 + $1.added }
    removed = files.reduce(0) { $0 + $1.removed }
    self.files = Array(files.prefix(Self.fileLimit))
  }

  // MARK: Made media

  public static func kind(ofExtension ext: String) -> Media.Kind? {
    switch ext.lowercased() {
    case "png", "jpg", "jpeg", "gif", "webp", "heic": return .image
    case "mp4", "mov", "m4v": return .video
    case "mp3", "m4a", "wav", "aac", "aiff", "caf": return .audio
    default: return nil
    }
  }

  /// Folders a project scan never walks: dependencies, build output, caches and version control.
  /// Their files are made by tools, not shown by the session.
  public static let skippedFolders: Set<String> = [
    ".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".next", ".nuxt", ".svelte-kit", "dist",
    ".venv", "venv", "__pycache__", ".cache", "target", ".turbo", "coverage", ".swiftpm", ".idea", ".gradle",
    "vendor", ".expo", ".parcel-cache", "out",
  ]

  public struct Candidate: Equatable, Sendable {
    public var path: String
    public var modified: Date
    public var bytes: Int
    public init(path: String, modified: Date, bytes: Int) {
      self.path = path
      self.modified = modified
      self.bytes = bytes
    }
  }

  /// Which files in a project the session made: media written between `since` and `until`, not
  /// empty and not over its kind's size, newest first, at most `perKind` of each and `mediaLimit`
  /// in all. Files written before the turn began are the person's own and never show.
  public static func pick(_ candidates: [Candidate], since: Date, until: Date) -> [Candidate] {
    var counts: [Media.Kind: Int] = [:]
    var out: [Candidate] = []
    let fresh = candidates.filter { $0.modified >= since && $0.modified <= until && $0.bytes > 0 }
      .sorted { $0.modified > $1.modified }
    for candidate in fresh {
      guard let kind = kind(ofExtension: (candidate.path as NSString).pathExtension),
        candidate.bytes <= maxBytes[kind] ?? 0, counts[kind, default: 0] < perKind[kind] ?? 0
      else { continue }
      counts[kind, default: 0] += 1
      out.append(candidate)
      if out.count == mediaLimit { break }
    }
    return out
  }

  // MARK: Tests

  /// How the turn's tests went, from its steps: any failed run is a failure.
  public static func tests(_ activities: [TranscriptActivity]) -> Tests? {
    let runs = activities.filter { $0.tool == "test" }
    guard !runs.isEmpty else { return nil }
    return runs.contains { $0.failed } ? .failed : .passed
  }

  // MARK: A day

  /// One session's reel and when it was made, as the day's log keeps it.
  public struct Stamped: Codable, Equatable, Sendable {
    public var at: Date
    public var project: String?
    public var reel: ReportReel
    public init(at: Date, project: String?, reel: ReportReel) {
      self.at = at
      self.project = project
      self.reel = reel
    }
  }

  /// The day before `now`'s sessions as one reel ("Yesterday"); nil when none had anything to
  /// show. File bars add up by project and path; tests fail if any failed.
  public static func day(_ log: [Stamped], before now: Date, calendar: Calendar = .current) -> ReportReel? {
    let today = calendar.startOfDay(for: now)
    guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
    let entries = log.filter { $0.at >= start && $0.at < today && !$0.reel.isEmpty }.sorted { $0.at < $1.at }
    guard !entries.isEmpty else { return nil }
    var reel = ReportReel(title: "Yesterday")
    reel.sessions = entries.count
    var projects: [String] = []
    for project in entries.compactMap(\.project) where !projects.contains(project) { projects.append(project) }
    reel.projects = projects
    var merged: [String: FileChange] = [:]
    var order: [String] = []
    for entry in entries {
      // A file listed only in a session's total still counts in the day's total.
      reel.filesTotal += entry.reel.filesTotal
      reel.added += entry.reel.added
      reel.removed += entry.reel.removed
      for file in entry.reel.files {
        let key = (entry.project.map { $0 + "/" } ?? "") + file.path
        if var known = merged[key] {
          known.added += file.added
          known.removed += file.removed
          merged[key] = known
          reel.filesTotal -= 1
        } else {
          merged[key] = FileChange(path: key, added: file.added, removed: file.removed)
          order.append(key)
        }
      }
      if let tests = entry.reel.tests { reel.tests = reel.tests == .failed ? .failed : tests == .failed ? .failed : .passed }
      if let minutes = entry.reel.minutes { reel.minutes = (reel.minutes ?? 0) + minutes }
    }
    reel.files = Array(order.compactMap { merged[$0] }.sorted { $0.churn > $1.churn }.prefix(fileLimit))
    var counts: [Media.Kind: Int] = [:]
    for media in entries.flatMap(\.reel.media).sorted(by: { $0.made > $1.made })
    where counts[media.kind, default: 0] < perKind[media.kind] ?? 0 && reel.media.count < mediaLimit {
      counts[media.kind, default: 0] += 1
      reel.media.append(media)
    }
    return reel
  }

  /// Keeps the last `days` days of the log.
  public static func pruned(_ log: [Stamped], now: Date, days: Int = 3) -> [Stamped] {
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    return log.filter { $0.at >= cutoff }
  }

  // MARK: Words

  /// "+312 −80 in 6 files · tests passed · 42 min · 3 pictures": the card's summary line, read by
  /// VoiceOver and spoken by Listen.
  public var summary: String {
    var parts: [String] = []
    if let sessions, sessions > 0 { parts.append(sessions == 1 ? "1 session" : "\(sessions) sessions") }
    if filesTotal > 0 { parts.append("+\(added) −\(removed) in " + (filesTotal == 1 ? "1 file" : "\(filesTotal) files")) }
    if let tests { parts.append(tests == .passed ? "tests passed" : "tests failed") }
    if let minutes, minutes > 0 { parts.append(Self.duration(minutes)) }
    let made = Dictionary(grouping: media, by: \.kind)
    for kind in [Media.Kind.image, .video, .audio] {
      guard let count = made[kind]?.count, count > 0 else { continue }
      let word = kind == .image ? "picture" : kind == .video ? "video" : "sound"
      parts.append("\(count) \(word)\(count == 1 ? "" : "s")")
    }
    return parts.joined(separator: " · ")
  }

  /// Listen's words: plain and spoken, not the card's symbols.
  public var narration: String {
    var lines: [String] = [title + "."]
    if let sessions, sessions > 0 {
      let places = (projects ?? []).prefix(3)
      lines.append((sessions == 1 ? "One session" : "\(sessions) sessions") + (places.isEmpty ? "" : " in " + Self.list(Array(places))) + ".")
    }
    if filesTotal > 0 {
      lines.append("\(added) lines added and \(removed) removed across " + (filesTotal == 1 ? "one file." : "\(filesTotal) files."))
    }
    if let tests { lines.append(tests == .passed ? "Tests passed." : "Some tests failed.") }
    if let minutes, minutes > 0 { lines.append("About \(Self.duration(minutes, spoken: true)) of work.") }
    if !media.isEmpty { lines.append(media.count == 1 ? "It made one file to look at." : "It made \(media.count) files to look at.") }
    return lines.joined(separator: " ")
  }

  public static func duration(_ minutes: Int, spoken: Bool = false) -> String {
    guard minutes >= 60 else { return spoken ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(minutes) min" }
    let hours = minutes / 60
    let rest = minutes % 60
    if spoken { return "\(hours) hour\(hours == 1 ? "" : "s")" + (rest > 0 ? " \(rest) minutes" : "") }
    return "\(hours)h" + (rest > 0 ? " \(rest)m" : "")
  }

  private static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
  }
}
