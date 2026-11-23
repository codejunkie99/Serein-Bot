import Foundation

/// A table an assistant collected from web pages: a Markdown table in its reply with a column
/// named Source that holds each row's page address. Each other cell is checked word for word
/// against the text Serein showed the agent for that page, normalized the way Compare checks its
/// quotes (`CompareVerifier`), and a cell that is not found is marked, never hidden. Saving and
/// copying go through `csv()`, `markdown()` and `tabSeparated()`, which redact every field.
/// Everything here is pure.
public struct CollectedTable: Equatable, Sendable {
  public struct Row: Equatable, Sendable {
    /// The value cells as the reply wrote them (inline Markdown), one per column.
    public var cells: [String]
    /// The page address the Source cell named, or nil when it held none.
    public var source: String?
  }
  public static let sourceName = "Source"
  /// A Source naming a file the person attached rather than a page (`attached:sales.csv`): its
  /// rows are checked against what table_query returned for that file (TableQuery).
  public static let filePrefix = "attached:"
  /// Between two result rows in the recorded text of a file, so a row is checked within one row.
  public static let rowBreak: Character = "\u{1E}"
  /// The value columns as the reply wrote them; Source is not among them.
  public var columns: [String]
  public var rows: [Row]
  /// Where Source sat in the reply's header, so the view can drop its alignment too.
  public var sourceIndex: Int

  /// nil unless the header has a Source column and another column, and a row's Source holds a
  /// web address or an attached file (`attached:<file>`), so a plain table that happens to have
  /// a Source column stays a plain table.
  public init?(header: [String], rows: [[String]]) {
    guard header.count >= 2,
      let source = header.lastIndex(where: { Self.plain($0).caseInsensitiveCompare(Self.sourceName) == .orderedSame })
    else { return nil }
    sourceIndex = source
    columns = header.enumerated().filter { $0.offset != source }.map(\.element)
    self.rows = rows.map { row in
      Row(cells: (0..<header.count).filter { $0 != source }.map { $0 < row.count ? row[$0] : "" },
        source: source < row.count ? Self.address(row[source]) : nil)
    }
    guard self.rows.contains(where: { $0.source != nil }) else { return nil }
  }

  // MARK: sources

  /// Brackets end an address (a Markdown link's text) except in the redaction token, which an agent
  /// copies from the addresses it was shown.
  private static let addressPattern = try! NSRegularExpression(
    pattern: #"https?://(?:[^\s<>()\[\]|"']|\[REDACTED\])+"#, options: .caseInsensitive)

  /// The first web address in a Source cell: bare, in angle brackets or as a Markdown link. A
  /// literal redaction token is percent-encoded, as the agent's addresses carry it.
  public static func address(_ cell: String) -> String? {
    if cell.range(of: filePrefix, options: .caseInsensitive) != nil {
      let words = plain(cell)
      if words.lowercased().hasPrefix(filePrefix) {
        let name = String(words.dropFirst(filePrefix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : filePrefix + name
      }
    }
    guard let match = addressPattern.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)),
      let range = Range(match.range, in: cell)
    else { return nil }
    let address = String(cell[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
      .replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
    guard let url = URL(string: address), url.host?.isEmpty == false else { return nil }
    return address
  }

  /// Whether a row's source is an attached file (`filePrefix`), and that file's name.
  public static func isFile(_ source: String) -> Bool { source.lowercased().hasPrefix(filePrefix) }
  public static func fileName(_ source: String) -> String {
    isFile(source) ? String(source.dropFirst(filePrefix.count)) : source
  }

  /// The site a row came from, as the Source column shows it: the host without “www.”, or the
  /// attached file's name.
  public static func site(_ address: String) -> String {
    if isFile(address) { return fileName(address) }
    guard let host = URL(string: address)?.host?.lowercased(), !host.isEmpty else { return address }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  /// One key per page for the page-text record and a row's source: no query, fragment or
  /// credentials (as `AgentPrivacy.url` shows addresses to agents), lowercased, no trailing slash.
  public static func key(_ address: String) -> String {
    if isFile(address) { return filePrefix + fileName(address).lowercased() }
    let clean = AgentPrivacy.url(address)
    guard clean != AgentPrivacy.replacement else { return "" }
    var key = clean.lowercased()
    while key.hasSuffix("/") { key.removeLast() }
    return key
  }

  // MARK: the word-for-word check

  /// A cell's visible words: inline Markdown (emphasis, code, links, escapes) read as text.
  public static func plain(_ cell: String) -> String {
    let text = (try? AttributedString(markdown: cell, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      .map { String($0.characters) } ?? cell
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether `value` appears word for word in `page` (already `TabText.normalize`d), not inside a
  /// longer word or number: “4” is not found in “2024”, “4.5” or “1,4”, nor “299” in “1,299”.
  /// With `near`, only a match inside one of those ranges of `page` counts; its neighbours are
  /// still read from the whole page.
  public static func grounded(_ value: String, in page: String?, near: [Range<String.Index>]? = nil) -> Bool {
    found(TabText.normalize(plain(value)), in: page, near: near)
  }

  /// `grounded` for a value already read as plain, normalized words.
  static func found(_ words: String, in page: String?, near: [Range<String.Index>]? = nil) -> Bool {
    guard let page, !words.isEmpty else { return false }
    let joined = { (c: Character?) in c.map { $0.isLetter || $0.isNumber } ?? false }
    let digit = { (c: Character?) in c?.isNumber ?? false }
    let mark = { (c: Character?) in c == "." || c == "," }
    var from = page.startIndex
    while from < page.endIndex, let found = page.range(of: words, range: from..<page.endIndex) {
      let previous = found.lowerBound > page.startIndex ? page.index(before: found.lowerBound) : nil
      let before = previous.map { page[$0] }
      let after = found.upperBound < page.endIndex ? page[found.upperBound] : nil
      let next = after.map { _ in page.index(after: found.upperBound) }
      // A decimal or thousands mark between digits joins them into one number.
      let digitBeforeMark = previous.map { $0 > page.startIndex && page[page.index(before: $0)].isNumber } ?? false
      let digitAfterMark = next.map { $0 < page.endIndex && page[$0].isNumber } ?? false
      let joinedBefore = (joined(before) && joined(words.first)) || (mark(before) && digitBeforeMark && digit(words.first))
      let joinedAfter = (joined(after) && joined(words.last)) || (mark(after) && digitAfterMark && digit(words.last))
      // A value that itself starts or ends with punctuation is bounded by it.
      if !joinedBefore && !joinedAfter
        && (near?.contains(where: { $0.lowerBound <= found.lowerBound && found.upperBound <= $0.upperBound }) ?? true)
      {
        return true
      }
      from = page.index(after: found.lowerBound)
    }
    return false
  }

  /// A normalized value short or bare enough (a rating, a price, a name of a few letters) to
  /// appear by chance elsewhere on a page that lists many rows.
  static func isShort(_ normalized: String) -> Bool {
    normalized.count < 5 || !normalized.contains(where: \.isLetter)
  }

  /// On a page several rows share, the ranges of it near this row: up to 50 windows of 400
  /// characters each side of the row's anchor, its longest value that is not short, not in
  /// `exclude` (values other rows on the page share, such as “In stock”) and found on the page.
  /// None when no such value is found.
  static func windows(_ cells: [String], in page: String, exclude: Set<String>) -> [Range<String.Index>] {
    let candidates = cells.map { ($0, TabText.normalize(plain($0))) }
      .filter { !isShort($0.1) && !exclude.contains($0.1) }
      .sorted { $0.1.count > $1.1.count }
    guard let anchor = candidates.first(where: { grounded($0.0, in: page) })?.1 else { return [] }
    var out: [Range<String.Index>] = []
    var from = page.startIndex
    while out.count < 50, from < page.endIndex, let found = page.range(of: anchor, range: from..<page.endIndex) {
      let start = page.index(found.lowerBound, offsetBy: -400, limitedBy: page.startIndex) ?? page.startIndex
      let end = page.index(found.upperBound, offsetBy: 400, limitedBy: page.endIndex) ?? page.endIndex
      out.append(start..<end)
      from = found.upperBound
    }
    return out
  }

  /// For each row and value column: true when the cell is empty or found on its row's page. On a
  /// page two or more rows name (a list of results), a short value counts only near its row's
  /// anchor (`windows`), so another result's rating or price does not pass for it; a value two or
  /// more of those rows share is never an anchor.
  /// `pages` maps `key(_:)` to normalized page text. nil when the task was cancelled (a reply that
  /// is still streaming changes the table again).
  public func checks(pages: [String: String]) async -> [[Bool]]? {
    var uses: [String: Int] = [:]
    // Per page key, how many of the rows naming it hold each value that is not short.
    var values: [String: [String: Int]] = [:]
    for row in rows {
      guard let source = row.source else { continue }
      let key = Self.key(source)
      uses[key, default: 0] += 1
      for words in Set(row.cells.map { TabText.normalize(Self.plain($0)) }) where !Self.isShort(words) {
        values[key, default: [:]][words, default: 0] += 1
      }
    }
    let shared = values.mapValues { counts in Set(counts.filter { $0.value >= 2 }.keys) }
    var fileRows: [String: [String]] = [:]
    var out: [[Bool]] = []
    out.reserveCapacity(rows.count)
    for row in rows {
      if Task.isCancelled { return nil }
      let key = row.source.map(Self.key)
      let page = key.flatMap { pages[$0] }
      if let key, let page, Self.isFile(key) {
        if fileRows[key] == nil { fileRows[key] = page.split(separator: Self.rowBreak).map(String.init) }
        out.append(Self.fileChecks(row.cells, rows: fileRows[key] ?? []))
        continue
      }
      guard let key, let page, uses[key, default: 0] >= 2 else {
        out.append(row.cells.map { Self.plain($0).isEmpty || Self.grounded($0, in: page) })
        continue
      }
      let near = Self.windows(row.cells, in: page, exclude: shared[key] ?? [])
      out.append(row.cells.map { cell in
        let words = TabText.normalize(Self.plain(cell))
        if words.isEmpty { return true }
        if !Self.isShort(words) { return Self.grounded(cell, in: page) }
        return Self.grounded(cell, in: page, near: near)
      })
    }
    return out
  }

  /// A row from an attached file is checked within one row of what table_query returned: the
  /// returned row holding most of its values. A value that row lacks is unchecked, so a count or
  /// a total from another row does not pass for it.
  static func fileChecks(_ cells: [String], rows: [String]) -> [Bool] {
    let words = cells.map { TabText.normalize(plain($0)) }
    var best = words.map(\.isEmpty)
    var most = -1
    for line in rows {
      let found = words.map { $0.isEmpty || Self.found($0, in: line) }
      let count = found.filter { $0 }.count
      if count > most {
        best = found
        most = count
        if count == words.count { break }
      }
    }
    return best
  }

  // MARK: copy and save

  /// Characters a spreadsheet reads as the start of a formula (CRLF is one Character in Swift).
  static let formulaLeads: Set<Character> = ["=", "+", "-", "@", "\t", "\r", "\r\n"]

  /// A cell a spreadsheet would run as a formula gets a leading apostrophe, so a page cannot plant
  /// one (`=HYPERLINK(…)` stays text).
  public static func neutralized(_ field: String) -> String {
    guard let first = field.first, formulaLeads.contains(first) else { return field }
    return "'" + field
  }

  /// The header then each row as plain, redacted fields; Source is the last column, as the page
  /// address or the attached file's name.
  private var fields: [[String]] {
    let head = columns.map(Self.plain) + [Self.sourceName]
    let body = rows.map { $0.cells.map(Self.plain) + [$0.source.map(Self.fileName) ?? ""] }
    return ([head] + body).map { $0.map { AgentPrivacy.redact($0) } }
  }

  /// RFC 4180: a field holding a quote, comma, CR or LF is quoted and its quotes doubled; lines end
  /// in CRLF. Formula-leading fields are neutralized first. A byte order mark leads, so a
  /// spreadsheet opens it as UTF-8 (“€12”, “Café”).
  public func csv() -> String {
    func field(_ raw: String) -> String {
      let value = Self.neutralized(raw)
      guard value.contains(where: { $0 == "\"" || $0 == "," || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else { return value }
      return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return "\u{FEFF}" + fields.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
  }

  /// One line per row for the pasteboard: tab-separated, a tab or line break inside a cell becomes
  /// a space, and formula-leading fields are neutralized, since a paste into a sheet runs them too.
  public func tabSeparated() -> String {
    fields.map { row in
      row.map { Self.neutralized($0.components(separatedBy: CharacterSet(charactersIn: "\t").union(.newlines)).joined(separator: " ")) }
        .joined(separator: "\t")
    }.joined(separator: "\n") + "\n"
  }

  /// A Markdown table with Source as a link named by its site.
  public func markdown() -> String {
    func cell(_ s: String) -> String {
      s.components(separatedBy: .newlines).joined(separator: " ")
        .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
    }
    let all = fields
    var lines = ["| " + all[0].map(cell).joined(separator: " | ") + " |",
      "|" + String(repeating: " --- |", count: all[0].count)]
    for (index, row) in all.dropFirst().enumerated() {
      let source = row.last ?? ""
      // An attached file is named, never linked.
      let file = rows[index].source.map(Self.isFile) ?? false
      let link = source.isEmpty ? "" : file ? cell(source) : "[\(cell(Self.site(source)))](<\(source)>)"
      lines.append("| " + (row.dropLast().map(cell) + [link]).joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// How an agent writes a collected table so Serein shows it as one (`CollectedTable`).
public enum CollectedTablePrompt {
  public static let table = "When you collect values from web pages into a table, write it as a Markdown table whose last column is named Source and holds the address of the page each row came from, and copy every value exactly as that page writes it: Serein checks each value word for word against its page and marks the ones it cannot find."
  /// Relay also proposes the columns first, through ask_user.
  public static let relay = "Before a long collection into a table (many pages or more than ten rows), propose the columns with ask_user (one question with columns) and use the columns the user sends back. " + table
}
