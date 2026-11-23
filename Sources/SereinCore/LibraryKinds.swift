import Foundation

/// The kinds of things the Library shows, each in its own view: photos in a grid, files, links,
/// audio and dashboards. Pure.
///
/// A name or an address gives `photo`, `audio`, `file` or `link`. Only a saved `DashboardSpec`
/// is a `dashboard`: no file name or address gives that kind, so a downloaded file cannot show
/// as a dashboard.
public enum LibraryKind: String, Codable, CaseIterable, Sendable {
  case photo, file, link, audio, dashboard

  public static let photoExtensions: Set<String> = [
    "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif", "dng",
  ]
  public static let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "oga", "opus", "caf",
  ]

  /// The kind for a file extension, with or without its dot, in any case. An extension that is
  /// not a photo or audio extension gives `file`.
  public init(fileExtension raw: String) {
    var ext = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while ext.hasPrefix(".") { ext.removeFirst() }
    if LibraryKind.photoExtensions.contains(ext) {
      self = .photo
    } else if LibraryKind.audioExtensions.contains(ext) {
      self = .audio
    } else {
      self = .file
    }
  }

  /// The kind for an address. A file address takes the kind of its extension. A web address
  /// (http or https, with a host) is a `link`, also when it names a picture: the Library keeps the
  /// address, not the picture. nil for every other address (`javascript:`, `data:`, `mailto:`…),
  /// which the Library does not keep.
  public init?(url: URL) {
    if url.isFileURL {
      self = LibraryKind(fileExtension: url.pathExtension)
      return
    }
    let scheme = (url.scheme ?? "").lowercased()
    guard scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
    self = .link
  }

  /// The heading in the Library ("Photos").
  public var title: String {
    switch self {
    case .photo: return "Photos"
    case .file: return "Files"
    case .link: return "Links"
    case .audio: return "Audio"
    case .dashboard: return "Dashboards"
    }
  }
}

/// One thing in the Library, as plain values. The caller gives only the items the reader may
/// already see: the memory store's scopes and the personal-read mark decide that before this.
public struct LibraryItem: Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var kind: LibraryKind
  /// The assistant that kept it; nil for something the person kept.
  public var assistant: String?
  public var date: Date
  /// A second line that search also reads: a file name or a web host. Never page text.
  public var detail: String?
  public init(id: String, title: String, kind: LibraryKind, assistant: String? = nil, date: Date, detail: String? = nil) {
    self.id = id
    self.title = title
    self.kind = kind
    self.assistant = assistant
    self.date = date
    self.detail = detail
  }
}

/// A Library search: words, a kind, an assistant and dates. Each part that is set must match;
/// a part that is nil matches all. The result is newest first and has at most `limit` items.
public struct LibraryQuery: Equatable, Sendable {
  public static let defaultLimit = 40
  public static let maxLimit = 200
  /// Longer text is cut to this many characters, and at most `maxWords` words count.
  public static let maxText = 200
  public static let maxWords = 8

  /// Every word must be in the title or the second line, in any case and with or without accents.
  public var text: String?
  public var kind: LibraryKind?
  public var assistant: String?
  /// Both ends count.
  public var dates: ClosedRange<Date>?
  /// 1 to `maxLimit`; a value out of range is moved into it.
  public var limit: Int

  public init(
    text: String? = nil, kind: LibraryKind? = nil, assistant: String? = nil, dates: ClosedRange<Date>? = nil,
    limit: Int = LibraryQuery.defaultLimit
  ) {
    self.text = text
    self.kind = kind
    self.assistant = assistant
    self.dates = dates
    self.limit = limit
  }

  /// The words that must match, lowercased, at most `maxWords`.
  public var words: [String] {
    guard let text = text else { return [] }
    let short = String(text.prefix(LibraryQuery.maxText)).lowercased()
    let parts = short.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return Array(parts.prefix(LibraryQuery.maxWords))
  }

  public func matches(_ item: LibraryItem) -> Bool {
    matches(item, words: words)
  }

  /// The items that match, newest first. Items with the same date sort by title, then by id, so
  /// the order is the same each time.
  public func run(_ items: [LibraryItem]) -> [LibraryItem] {
    let terms = words
    let found: [LibraryItem] = items.filter { matches($0, words: terms) }
    let sorted: [LibraryItem] = found.sorted(by: LibraryQuery.newerFirst)
    let cap = Swift.min(Swift.max(limit, 1), LibraryQuery.maxLimit)
    return Array(sorted.prefix(cap))
  }

  func matches(_ item: LibraryItem, words terms: [String]) -> Bool {
    if let kind = kind, item.kind != kind { return false }
    if let assistant = assistant, item.assistant != assistant { return false }
    if let dates = dates, !dates.contains(item.date) { return false }
    if terms.isEmpty { return true }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let haystack: String = item.title + "\n" + (item.detail ?? "")
    for term in terms where haystack.range(of: term, options: options) == nil {
      return false
    }
    return true
  }

  static func newerFirst(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
    if a.date != b.date { return a.date > b.date }
    if a.title != b.title { return a.title < b.title }
    return a.id < b.id
  }
}

/// A dashboard the person asked for: a title, one stat, at most `maxRows` rows, and the memory
/// records it came from, so it can update when those records change. Every text field is one
/// line of plain text. The text can come from pages or mail, so the shell shows it as text only.
public struct DashboardSpec: Codable, Equatable, Sendable {
  public enum Direction: String, Codable, CaseIterable, Sendable { case up, down, flat }
  /// How the stat moved: a direction and short words ("12%").
  public struct Trend: Codable, Equatable, Sendable {
    public var direction: Direction
    public var text: String
    public init(direction: Direction, text: String) {
      self.direction = direction
      self.text = text
    }
  }
  public struct Stat: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public var trend: Trend?
    public init(label: String, value: String, trend: Trend? = nil) {
      self.label = label
      self.value = value
      self.trend = trend
    }
  }
  public struct Row: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public init(label: String, value: String) {
      self.label = label
      self.value = value
    }
  }

  public static let maxRows = 6
  public static let maxTitle = 60
  public static let maxLabel = 40
  public static let maxValue = 40
  public static let maxTrend = 12
  public static let maxSources = 40
  public static let maxSourceID = 200

  /// What is wrong with a dashboard, in plain words.
  public enum Problem: Error, Equatable, Sendable {
    case noTitle
    case titleTooLong
    case noStat
    case trendNotPlain
    case tooManyRows
    case emptyRow
    case tooLong
    case notOneLine
    case noSources
    case tooManySources
    case badSource
    case sameSourceTwice

    public var words: String {
      switch self {
      case .noTitle: return "Give the dashboard a name."
      case .titleTooLong: return "Use a name of \(DashboardSpec.maxTitle) characters or fewer."
      case .noStat: return "The main number needs a name and a value."
      case .trendNotPlain: return "Use \(DashboardSpec.maxTrend) characters or fewer to show how it moved."
      case .tooManyRows: return "A dashboard can have \(DashboardSpec.maxRows) rows or fewer."
      case .emptyRow: return "Each row needs a name and a value."
      case .tooLong: return "Use \(DashboardSpec.maxLabel) characters or fewer for each name and value."
      case .notOneLine: return "Write each name and value on one line."
      case .noSources: return "Say which saved notes the numbers come from."
      case .tooManySources: return "A dashboard can come from \(DashboardSpec.maxSources) saved notes or fewer."
      case .badSource: return "One of the saved notes in the list is not correct."
      case .sameSourceTwice: return "A saved note is listed two times."
      }
    }
  }

  public var title: String
  public var stat: Stat
  public var rows: [Row]
  /// The memory record ids it came from, in order, or "assistant:<id>" for an assistant whose
  /// chat gave the numbers (`DashboardDraft`).
  public var sources: [String]
  /// Made in a chat that carries the personal-read mark: the dashboard keeps the mark (SPEC I7).
  /// Optional, so a saved spec without it decodes.
  public var personal: Bool? = nil

  public init(title: String, stat: Stat, rows: [Row] = [], sources: [String]) {
    self.title = title
    self.stat = stat
    self.rows = rows
    self.sources = sources
  }

  /// Every problem, each named once, in a fixed order; empty when the dashboard can be saved.
  public func validate() -> [Problem] {
    var found: [Problem] = []
    func add(_ problem: Problem) {
      if !found.contains(problem) { found.append(problem) }
    }
    let name = DashboardSpec.trimmed(title)
    if name.isEmpty { add(.noTitle) }
    if name.count > DashboardSpec.maxTitle { add(.titleTooLong) }
    if DashboardSpec.trimmed(stat.label).isEmpty || DashboardSpec.trimmed(stat.value).isEmpty { add(.noStat) }
    if let trend = stat.trend {
      let words = DashboardSpec.trimmed(trend.text)
      if words.isEmpty || words.count > DashboardSpec.maxTrend { add(.trendNotPlain) }
    }
    if rows.count > DashboardSpec.maxRows { add(.tooManyRows) }
    for row in rows where DashboardSpec.trimmed(row.label).isEmpty || DashboardSpec.trimmed(row.value).isEmpty {
      add(.emptyRow)
    }
    var fields: [(text: String, limit: Int)] = [(stat.label, DashboardSpec.maxLabel), (stat.value, DashboardSpec.maxValue)]
    for row in rows {
      fields.append((row.label, DashboardSpec.maxLabel))
      fields.append((row.value, DashboardSpec.maxValue))
    }
    for field in fields where DashboardSpec.trimmed(field.text).count > field.limit {
      add(.tooLong)
    }
    var lines: [String] = fields.map { $0.text }
    lines.append(title)
    if let trend = stat.trend { lines.append(trend.text) }
    for line in lines where !DashboardSpec.isOneLine(line) {
      add(.notOneLine)
    }
    if sources.isEmpty { add(.noSources) }
    if sources.count > DashboardSpec.maxSources { add(.tooManySources) }
    for source in sources where !DashboardSpec.isSourceID(source) {
      add(.badSource)
    }
    if Set(sources).count != sources.count { add(.sameSourceTwice) }
    return found
  }

  public var isValid: Bool { validate().isEmpty }

  static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
  /// No line breaks and no hidden characters (`SafeFileName.hidden`).
  static func isOneLine(_ s: String) -> Bool {
    !s.unicodeScalars.contains { CharacterSet.newlines.contains($0) || SafeFileName.hidden($0) }
  }
  /// A record id: 1 to `maxSourceID` characters, with no space and no hidden character.
  static func isSourceID(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= maxSourceID else { return false }
    return !s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || SafeFileName.hidden($0) }
  }
}

/// A dashboard from `dashboard_make`'s arguments (the fix round): a title, one to `maxStats`
/// stats and up to `DashboardSpec.maxRows` rows, and the assistants the numbers come from. The
/// words come from a model and can come from pages or mail, so each one is cut to one line and to
/// the spec's limits first; the result must pass `DashboardSpec.validate`. The spec has one stat:
/// the first is its big number, and the others lead the rows. Pure.
public enum DashboardDraft {
  public static let maxStats = 3
  /// The prefix of a source that names an assistant.
  public static let assistantSource = "assistant:"

  /// The spec, and how many stats and rows did not fit.
  public struct Built: Equatable, Sendable {
    public var spec: DashboardSpec
    public var leftOut: Int
  }

  /// `title`, `stats` (label, value, optional `trend` up, down or flat and `change` words),
  /// `rows` (label, value) and `sources` (assistant names; unknown names are left out, and with
  /// none the assistant that acts, `actingID`, is the source).
  public static func parse(_ a: [String: Any], team: RelayTeam, actingID: String) -> Result<Built, DashboardSpec.Problem> {
    let title: String = line(a["title"], limit: DashboardSpec.maxTitle)
    let stats: [[String: Any]] = (a["stats"] as? [[String: Any]]) ?? []
    let given: [[String: Any]] = (a["rows"] as? [[String: Any]]) ?? []
    guard let first = stats.first else { return .failure(.noStat) }
    var stat = DashboardSpec.Stat(
      label: line(first["label"], limit: DashboardSpec.maxLabel), value: line(first["value"], limit: DashboardSpec.maxValue))
    let change: String = line(first["change"], limit: DashboardSpec.maxTrend)
    if !change.isEmpty {
      let direction: DashboardSpec.Direction = DashboardSpec.Direction(rawValue: line(first["trend"], limit: 8).lowercased()) ?? .flat
      stat.trend = DashboardSpec.Trend(direction: direction, text: change)
    }
    var rows: [DashboardSpec.Row] = []
    var dropped = max(stats.count - maxStats, 0)
    let more: [[String: Any]] = Array(stats.dropFirst().prefix(maxStats - 1)) + given
    for item in more {
      guard rows.count < DashboardSpec.maxRows else {
        dropped += 1
        continue
      }
      rows.append(DashboardSpec.Row(
        label: line(item["label"], limit: DashboardSpec.maxLabel), value: line(item["value"], limit: DashboardSpec.maxValue)))
    }
    var sources: [String] = []
    for name in (a["sources"] as? [String]) ?? [] {
      guard let profile = team.profile(named: name.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
      let source: String = assistantSource + profile.id
      if !sources.contains(source) { sources.append(source) }
    }
    if sources.isEmpty { sources = [assistantSource + actingID] }
    let spec = DashboardSpec(title: title, stat: stat, rows: rows, sources: Array(sources.prefix(DashboardSpec.maxSources)))
    if let problem = spec.validate().first { return .failure(problem) }
    return .success(Built(spec: spec, leftOut: dropped))
  }

  /// One line of plain text at most `limit` characters: line breaks become spaces, hidden
  /// characters go (`ConnectLink.oneLine`). A number stays as it was written.
  static func line(_ raw: Any?, limit: Int) -> String {
    var text: String = ""
    if let words = raw as? String {
      text = words
    } else if let number = raw as? Int {
      text = String(number)
    } else if let number = raw as? Double, abs(number) < 1e15 {
      text = number == number.rounded() ? String(Int(number)) : String(number)
    }
    let flat: String = ConnectLink.oneLine(text).trimmingCharacters(in: .whitespaces)
    return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces)
  }
}
