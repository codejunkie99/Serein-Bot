import Compression
import Foundation

/// A spreadsheet or CSV the person attached to a message, parsed into memory for `table_query`
/// (TableQuery): each sheet's header and rows as text. CSV and TSV are read as RFC 4180 text. An
/// .xlsx is read with `ZipEntries` and Foundation's XMLParser for its shared strings and cell
/// values only: a formula's saved result is read and never the formula, and macros, external
/// links, embedded objects and DTDs are never opened. Nothing is written back. Everything here is pure.
public struct TableFile: Equatable, Sendable {
  public struct Sheet: Equatable, Sendable {
    public var name: String
    /// Header names, unique and never empty (“Column 3” for a blank one).
    public var columns: [String]
    /// Every row below the header, each exactly `columns.count` cells.
    public var rows: [[String]]
    /// A preview read stopped before the sheet's end (`read(_:name:firstRows:)`).
    public var cut = false
  }
  public var sheets: [Sheet]

  /// The most table_query reads: per file, per sheet's rows, and a workbook's first sheets.
  public static let sizeLimit = 20_000_000
  public static let rowLimit = 200_000
  public static let sheetLimit = 12
  /// Cells held in memory per sheet (and shared strings per workbook): a small file cannot make
  /// Serein build arrays past this, whatever its rows say.
  public static let cellLimit = 5_000_000
  /// Columns a preview keeps (the message's text is cut far sooner).
  static let previewColumns = 1_000
  public static let extensions: Set<String> = ["csv", "tsv", "xlsx"]

  /// Whether a file of this name is one table_query reads.
  public static func isTable(_ name: String) -> Bool {
    extensions.contains((name as NSString).pathExtension.lowercased())
  }

  /// Parses an attached table. Throws, in words the agent and the person can read, when the file
  /// is over the limits or is not the kind its name says. `firstRows` reads a preview instead: each
  /// sheet stops after that many rows, and a longer sheet is marked `cut` rather than refused.
  public static func read(_ data: Data, name: String, firstRows: Int? = nil) throws -> TableFile {
    guard data.count <= sizeLimit else {
      throw SereinError.invalid("\(name) is over \(Bytes.file(Int64(sizeLimit))), more than table_query reads.")
    }
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "xlsx": return try workbook(data, name: name, firstRows: firstRows)
    case "csv", "tsv":
      let bytes = textBytes(data)
      let separator: UInt8 = ext == "tsv" ? 0x09 : guessSeparator(bytes)
      let limit: Int = firstRows ?? rowLimit + 1
      let parsed = delimited(bytes, separator: separator, limit: limit)
      if firstRows == nil && parsed.over { throw tooManyRows(name, sheet: nil) }
      if firstRows == nil && parsed.full { throw tooManyCells(name, sheet: nil) }
      let kept: [[String]] = Array(parsed.rows.prefix(limit))
      let title: String = (name as NSString).deletingPathExtension
      var sheet = try shaped(name: title, cells: kept, file: name, sheet: nil, preview: firstRows != nil)
      sheet.cut = sheet.cut || parsed.over || parsed.full
      return TableFile(sheets: [sheet])
    default:
      throw SereinError.invalid("table_query reads CSV, TSV and .xlsx files; \(name) is none of them.")
    }
  }

  /// The sheets as tab-separated text for the message's document block and chip, at most
  /// `limit` characters.
  public func previewText(limit: Int) -> String {
    var out = ""
    var count = 0
    for sheet in sheets {
      let rows = "\(sheet.cut ? "first " : "")\(sheet.rows.count) \(sheet.rows.count == 1 ? "row" : "rows")"
      let head = (out.isEmpty ? "" : "\n") + "Sheet: \(sheet.name) (\(rows))\n"
      out += head
      count += head.count
      for row in [sheet.columns] + sheet.rows {
        let line = row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
          .joined(separator: "\t") + "\n"
        out += line
        count += line.count
        if count >= limit { return String(out.prefix(limit)) }
      }
    }
    return out
  }

  static func tooManyRows(_ name: String, sheet: String?) -> SereinError {
    let place = sheet.map { "The sheet “\($0)” of \(name)" } ?? name
    return SereinError.invalid("\(place) has more than \(rowLimit.formatted()) rows, more than table_query reads.")
  }

  static func tooManyCells(_ name: String, sheet: String?) -> SereinError {
    let place: String = sheet.map { "The sheet “\($0)” of \(name)" } ?? name
    return SereinError.invalid("\(place) has more cells than table_query reads (\(cellLimit.formatted())).")
  }

  // MARK: CSV and TSV

  /// The text as UTF-8 bytes without a byte order mark: UTF-16 with its mark, UTF-8, or Windows
  /// Latin-1 (what a spreadsheet saves as “CSV” on many machines).
  static func textBytes(_ data: Data) -> [UInt8] {
    let text: String
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      text = String(data: data, encoding: .utf16) ?? ""
    } else if let utf8 = String(data: data, encoding: .utf8) {
      text = utf8
    } else {
      text = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
    let bytes = Array(text.utf8)
    return bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
  }

  /// Comma, semicolon or tab, whichever the first line holds most of; comma when none.
  static func guessSeparator(_ bytes: [UInt8]) -> UInt8 {
    var counts: [UInt8: Int] = [0x2C: 0, 0x3B: 0, 0x09: 0]
    var quoted = false
    for byte in bytes.prefix(8_192) {
      if byte == 0x22 { quoted.toggle() }
      if quoted { continue }
      if byte == 0x0A || byte == 0x0D { break }
      if counts[byte] != nil { counts[byte, default: 0] += 1 }
    }
    let order: [UInt8] = [0x2C, 0x3B, 0x09]
    let top = order.map { counts[$0] ?? 0 }.max() ?? 0
    return top > 0 ? order.first { counts[$0] == top } ?? 0x2C : 0x2C
  }

  /// RFC 4180 rows: quoted fields may hold separators, quotes (doubled) and line breaks; CRLF,
  /// LF and CR end a row. Reading stops once there are more than `limit` rows (`over`) or more
  /// than `cellLimit` fields (`full`).
  static func delimited(_ bytes: [UInt8], separator: UInt8, limit: Int) -> (rows: [[String]], over: Bool, full: Bool) {
    var rows: [[String]] = []
    var row: [String] = []
    var field: [UInt8] = []
    var fields = 0
    var quoted = false
    var started = false
    var i = 0
    let n = bytes.count
    while i < n {
      let byte = bytes[i]
      if quoted {
        if byte == 0x22 {
          if i + 1 < n && bytes[i + 1] == 0x22 {
            field.append(0x22)
            i += 2
            continue
          }
          quoted = false
        } else {
          field.append(byte)
        }
        i += 1
        continue
      }
      if byte == 0x22 && field.isEmpty {
        quoted = true
        started = true
      } else if byte == separator {
        row.append(String(decoding: field, as: UTF8.self))
        field.removeAll(keepingCapacity: true)
        started = true
        fields += 1
        if fields > cellLimit { return (rows, false, true) }
      } else if byte == 0x0D || byte == 0x0A {
        if byte == 0x0D && i + 1 < n && bytes[i + 1] == 0x0A { i += 1 }
        row.append(String(decoding: field, as: UTF8.self))
        field.removeAll(keepingCapacity: true)
        rows.append(row)
        row = []
        started = false
        fields += 1
        if rows.count > limit { return (rows, true, false) }
        if fields > cellLimit { return (rows, false, true) }
      } else {
        field.append(byte)
        started = true
      }
      i += 1
    }
    if started || !field.isEmpty || !row.isEmpty {
      row.append(String(decoding: field, as: UTF8.self))
      rows.append(row)
      fields += 1
    }
    return (rows, rows.count > limit, fields > cellLimit)
  }

  /// The first row with any value is the header; empty rows go, and every row gets the header's
  /// width. Blank header names become “Column N”, and a repeated name gets “ 2”, “ 3”. A sheet
  /// whose padded rows would pass `cellLimit` is refused, or for a `preview` narrowed (and `cut`).
  static func shaped(name: String, cells: [[String]], file: String, sheet: String?, preview: Bool) throws -> Sheet {
    let trimmed: [[String]] = cells.map { (row: [String]) -> [String] in
      row.map { (cell: String) -> String in cell.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let filled: [[String]] = trimmed.filter { (row: [String]) -> Bool in row.contains(where: { !$0.isEmpty }) }
    guard let header = filled.first else { return Sheet(name: name, columns: [], rows: []) }
    let widths: [Int] = filled.map { (row: [String]) -> Int in
      let last: Int = row.lastIndex(where: { !$0.isEmpty }) ?? -1
      return last + 1
    }
    var width: Int = widths.max() ?? 0
    var narrowed = false
    if width > cellLimit / filled.count {
      guard preview else { throw tooManyCells(file, sheet: sheet) }
      width = max(1, cellLimit / filled.count)
      narrowed = true
    }
    if preview && width > previewColumns {
      width = previewColumns
      narrowed = true
    }
    var taken = Set<String>()
    let columns: [String] = (0..<width).map { (index: Int) -> String in
      let base: String = index < header.count && !header[index].isEmpty ? header[index] : "Column \(index + 1)"
      var candidate = base
      var count = 2
      while taken.contains(candidate.lowercased()) {
        candidate = "\(base) \(count)"
        count += 1
      }
      taken.insert(candidate.lowercased())
      return candidate
    }
    let rows: [[String]] = filled.dropFirst().map { (row: [String]) -> [String] in
      (0..<width).map { (index: Int) -> String in index < row.count ? row[index] : "" }
    }
    return Sheet(name: name, columns: columns, rows: rows, cut: narrowed)
  }

  // MARK: .xlsx

  /// Bytes an .xlsx may expand to across the parts read, so a small archive cannot fill memory.
  static let unpackedLimit = 240_000_000

  static func workbook(_ data: Data, name: String, firstRows: Int?) throws -> TableFile {
    let unreadable = SereinError.invalid(
      "\(name) could not be read as an .xlsx workbook. A password-protected workbook cannot be read.")
    guard let zip = ZipEntries(data) else { throw unreadable }
    var budget = unpackedLimit
    func part(_ path: String) throws -> Data? {
      guard let entry = zip.entries[path] else { return nil }
      guard entry.size <= budget else {
        throw SereinError.invalid("\(name) is too large once unpacked for table_query to read.")
      }
      guard let bytes = zip.data(path, budget: budget) else { throw unreadable }
      budget -= bytes.count
      return Data(bytes)
    }
    // Sheets in workbook order, each found through the workbook's relationships.
    var targets: [(name: String, path: String)] = []
    if let workbook = try part("xl/workbook.xml"), let rels = try part("xl/_rels/workbook.xml.rels") {
      let sheets = try XMLElements.attributes(of: "sheet", in: workbook)
      let links = try XMLElements.attributes(of: "Relationship", in: rels)
      var byID: [String: String] = [:]
      for link in links where (link["Type"] ?? "").hasSuffix("/worksheet") {
        guard let id = link["Id"], let target = link["Target"] else { continue }
        byID[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
      }
      for sheet in sheets {
        // The relationship id is in the relationships namespace, whatever its prefix is called.
        guard let id = sheet.first(where: { $0.key == "id" || $0.key.hasSuffix(":id") })?.value,
          let path = byID[id]
        else { continue }
        targets.append((name: sheet["name"] ?? "Sheet \(targets.count + 1)", path: path))
      }
    }
    if targets.isEmpty {
      let paths = zip.entries.keys.filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      targets = paths.enumerated().map { (name: "Sheet \($0.offset + 1)", path: $0.element) }
    }
    guard !targets.isEmpty else { throw unreadable }
    var shared: [String] = []
    if let strings = try part("xl/sharedStrings.xml") {
      let reader = SharedStrings()
      try XMLElements.parse(strings, with: reader)
      if reader.full { throw tooManyCells(name, sheet: nil) }
      shared = reader.strings
    }
    var sheets: [Sheet] = []
    for target in targets.prefix(sheetLimit) {
      guard let xml = try part(target.path) else { continue }
      let limit: Int = firstRows ?? rowLimit + 1
      let reader = SheetCells(shared: shared, limit: limit)
      try XMLElements.parse(xml, with: reader)
      if firstRows == nil && reader.over { throw tooManyRows(name, sheet: target.name) }
      if firstRows == nil && reader.full { throw tooManyCells(name, sheet: target.name) }
      let kept: [[String]] = Array(reader.rows.prefix(limit))
      var sheet = try shaped(name: target.name, cells: kept, file: name, sheet: target.name, preview: firstRows != nil)
      sheet.cut = sheet.cut || reader.over || reader.full
      sheets.append(sheet)
    }
    guard !sheets.isEmpty else { throw unreadable }
    return TableFile(sheets: sheets)
  }
}

/// The entries of a zip archive by name, each expanded only when asked for: stored and deflated
/// entries (Compression's raw DEFLATE), never an encrypted one, and never past a byte budget.
/// ZIP64 archives are not read (an attached table is at most 20 MB).
struct ZipEntries {
  struct Entry {
    var method: Int
    var flags: Int
    var compressed: Int
    var size: Int
    var offset: Int
  }
  let bytes: [UInt8]
  let entries: [String: Entry]

  static func u16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | (Int(b[at + 1]) << 8) }
  static func u32(_ b: [UInt8], _ at: Int) -> Int { u16(b, at) | (u16(b, at + 2) << 16) }

  init?(_ data: Data) {
    let b = [UInt8](data)
    guard b.count >= 22 else { return nil }
    // The end-of-central-directory record, within the last 64 KB (its comment's most).
    var end = -1
    var at = b.count - 22
    let floor = max(0, b.count - 22 - 65_535)
    while at >= floor {
      if b[at] == 0x50 && b[at + 1] == 0x4B && b[at + 2] == 0x05 && b[at + 3] == 0x06 {
        end = at
        break
      }
      at -= 1
    }
    guard end >= 0 else { return nil }
    let count = Self.u16(b, end + 10)
    var cursor = Self.u32(b, end + 16)
    var entries: [String: Entry] = [:]
    for _ in 0..<count {
      guard cursor >= 0, cursor + 46 <= b.count, Self.u32(b, cursor) == 0x0201_4B50 else { return nil }
      let nameLength = Self.u16(b, cursor + 28)
      let extra = Self.u16(b, cursor + 30)
      let comment = Self.u16(b, cursor + 32)
      guard cursor + 46 + nameLength <= b.count else { return nil }
      let name = String(decoding: b[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
      entries[name] = Entry(
        method: Self.u16(b, cursor + 10), flags: Self.u16(b, cursor + 8), compressed: Self.u32(b, cursor + 20),
        size: Self.u32(b, cursor + 24), offset: Self.u32(b, cursor + 42))
      cursor += 46 + nameLength + extra + comment
    }
    bytes = b
    self.entries = entries
  }

  /// The entry's bytes, or nil when it is missing, encrypted, of another method, cut short,
  /// or larger than `budget` once expanded.
  func data(_ name: String, budget: Int) -> [UInt8]? {
    guard let entry = entries[name], entry.flags & 1 == 0, entry.size <= budget,
      entry.offset + 30 <= bytes.count, Self.u32(bytes, entry.offset) == 0x0403_4B50
    else { return nil }
    let start = entry.offset + 30 + Self.u16(bytes, entry.offset + 26) + Self.u16(bytes, entry.offset + 28)
    guard entry.compressed >= 0, start + entry.compressed <= bytes.count else { return nil }
    switch entry.method {
    case 0:
      guard entry.compressed == entry.size else { return nil }
      return Array(bytes[start..<(start + entry.size)])
    case 8:
      guard entry.size > 0 else { return [] }
      guard entry.compressed > 0 else { return nil }
      var out = [UInt8](repeating: 0, count: entry.size)
      let written = bytes.withUnsafeBufferPointer { source -> Int in
        out.withUnsafeMutableBufferPointer { target -> Int in
          guard let from = source.baseAddress, let to = target.baseAddress else { return 0 }
          return compression_decode_buffer(to, entry.size, from + start, entry.compressed, nil, COMPRESSION_ZLIB)
        }
      }
      return written == entry.size ? out : nil
    default:
      return nil
    }
  }
}

/// XMLParser for a workbook's parts: no external entities, and no part with a DTD at all, so
/// an entity can neither reach outside the file nor expand without bound.
enum XMLElements {
  static func parse(_ data: Data, with delegate: XMLParserDelegate) throws {
    let refused = SereinError.invalid("This workbook holds a part Serein does not read.")
    // UTF-16 (or any wide encoding) would hide a DTD from the byte search below.
    let head: [UInt8] = Array(data.prefix(4))
    if head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) || head.contains(0) { throw refused }
    if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
      throw refused
    }
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = false
    parser.delegate = delegate
    let parsed: Bool = parser.parse()
    // A reader that stopped at its own limit aborted the parse; its caller says why.
    let sheetStopped: Bool = (delegate as? SheetCells)?.stopped == true
    let stringsStopped: Bool = (delegate as? SharedStrings)?.full == true
    if !parsed && !sheetStopped && !stringsStopped {
      throw SereinError.invalid("Part of this workbook is not well-formed, so it could not be read.")
    }
  }

  /// An element's name without its namespace prefix (`x:row` is `row`).
  static func local(_ name: String) -> Substring {
    name.split(separator: ":").last ?? Substring(name)
  }

  /// The attributes of every element named `element`, in document order.
  static func attributes(of element: String, in data: Data) throws -> [[String: String]] {
    let reader = XMLAttributes(element)
    try parse(data, with: reader)
    return reader.found
  }
}

/// The attributes of each element of one name (`XMLElements.attributes`).
final class XMLAttributes: NSObject, XMLParserDelegate {
  let element: String
  private(set) var found: [[String: String]] = []
  init(_ element: String) { self.element = element }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    if XMLElements.local(elementName) == element { found.append(attributeDict) }
  }
}

/// A workbook's shared strings: each `si` item's text runs joined, phonetic guides left out.
/// Stops past `TableFile.cellLimit` items (`full`).
final class SharedStrings: NSObject, XMLParserDelegate {
  private(set) var strings: [String] = []
  private(set) var full = false
  private var current = ""
  private var item = false
  private var text = false
  private var phonetic = false

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    switch XMLElements.local(elementName) {
    case "si":
      item = true
      current = ""
    case "rPh": phonetic = true
    case "t": text = item && !phonetic
    default: break
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if text { current += string }
  }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
  ) {
    switch XMLElements.local(elementName) {
    case "t": text = false
    case "rPh": phonetic = false
    case "si":
      strings.append(current)
      item = false
      if strings.count > TableFile.cellLimit {
        full = true
        parser.abortParsing()
      }
    default: break
    }
  }
}

/// One worksheet's cell values by row and column (`r` references, gaps kept empty). A shared
/// string is looked up, a boolean reads TRUE or FALSE, and every other value (a number, a date's
/// serial number, a formula's saved result, an inline string, an error) is the text saved in the
/// cell. Formulas are never read. An empty cell is not stored, so a far reference with no value
/// costs nothing. Stops once there are more than `limit` rows (`over`) or the stored cells pass
/// `TableFile.cellLimit` (`full`).
final class SheetCells: NSObject, XMLParserDelegate {
  let shared: [String]
  let limit: Int
  private(set) var rows: [[String]] = []
  private(set) var over = false
  private(set) var full = false
  /// Cells held in `rows` so far, gaps included.
  private var stored = 0
  var stopped: Bool { over || full }
  private var row: [String] = []
  private var column = 0
  private var cellColumn = 0
  private var cellType = ""
  private var text = ""
  private var value = false
  private var inline = false
  private var phonetic = false
  /// The widest sheet a spreadsheet allows (column XFD).
  static let maxColumns = 16_384

  init(shared: [String], limit: Int) {
    self.shared = shared
    self.limit = limit
  }

  /// The zero-based column of a reference such as “AB12”.
  static func columnIndex(_ reference: String) -> Int? {
    var number = 0
    var letters = 0
    for scalar in reference.unicodeScalars {
      let upper: UInt32 = scalar.value & 0xDF
      guard scalar.value < 128, upper >= 65, upper <= 90 else { break }
      number = number * 26 + Int(upper - 64)
      letters += 1
      if letters > 3 { return nil }
    }
    return letters == 0 ? nil : number - 1
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    switch XMLElements.local(elementName) {
    case "row":
      row = []
      column = 0
      // A row number past the next one leaves empty rows between, as the sheet shows them.
      if let number = attributeDict["r"].flatMap({ Int($0) }), number - 1 > rows.count, number - 1 <= limit {
        rows += Array(repeating: [String](), count: number - 1 - rows.count)
      }
    case "c":
      cellType = attributeDict["t"] ?? "n"
      cellColumn = attributeDict["r"].flatMap(Self.columnIndex) ?? column
      text = ""
    case "v": value = !inline
    case "is": inline = true
    case "rPh": phonetic = true
    case "t": value = inline && !phonetic
    default: break
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if value { text += string }
  }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
  ) {
    switch XMLElements.local(elementName) {
    case "v", "t": value = false
    case "rPh": phonetic = false
    case "is": inline = false
    case "c":
      let cell: String
      switch cellType {
      case "s":
        let index = Int(text.trimmingCharacters(in: .whitespaces)) ?? -1
        cell = index >= 0 && index < shared.count ? shared[index] : ""
      case "b": cell = text == "1" ? "TRUE" : text == "0" ? "FALSE" : text
      default: cell = text
      }
      column = cellColumn + 1
      guard !cell.isEmpty, cellColumn >= 0, cellColumn < Self.maxColumns else { break }
      if cellColumn >= row.count { row += Array(repeating: "", count: cellColumn - row.count + 1) }
      row[cellColumn] = cell
    case "row":
      rows.append(row)
      stored += row.count
      if rows.count > limit {
        over = true
        parser.abortParsing()
      } else if stored > TableFile.cellLimit {
        full = true
        parser.abortParsing()
      }
    default: break
    }
  }
}
