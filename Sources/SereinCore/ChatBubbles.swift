import Foundation

/// A reply as text messages: each short paragraph is its own bubble, as a person sends one thought
/// at a time. Code, tables and pictures keep the column, outside a bubble. A reply with headings is
/// a document and stays whole; too many plain parts are one longer message in one bubble. Only the drawing changes: every word stays, in
/// order. A paragraph may start with a tag, `[reply 2]`, naming the message it answers in a burst:
/// the tag leaves the words and rides on the piece.
public enum ChatBubbles {
  public enum Kind: Sendable, Equatable {
    /// Words in a bubble.
    case words
    /// Code, a table, a picture or a whole document, drawn in the column.
    case document
  }

  public struct Piece: Sendable, Equatable, Identifiable {
    public let id: Int
    public let kind: Kind
    public let text: String
    /// Which message of the burst it answers, from 1; nil when it does not say.
    public let replyTag: Int?
    public init(id: Int, kind: Kind, text: String, replyTag: Int? = nil) {
      self.id = id
      self.kind = kind
      self.text = text
      self.replyTag = replyTag
    }
  }

  /// More parts than this read as a document, not as messages.
  public static let maxBubbles = 6

  public static func split(_ text: String) -> [Piece] {
    let whole = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !whole.isEmpty else { return [] }
    let scanned = scan(whole)
    let blocks = merged(scanned.blocks)
    guard !blocks.isEmpty else { return [] }
    // Different answers keep their own document/list boundaries, including when one has a
    // heading. Collapsing the whole reply would discard the later answers' quote associations.
    if Set(blocks.compactMap(\.tag)).count > 1 {
      return groups(blocks).flatMap { group in split(render(group)) }.enumerated().map {
        Piece(id: $0.offset, kind: $0.element.kind, text: $0.element.text, replyTag: $0.element.replyTag)
      }
    }
    if blocks.contains(where: \.heading) || (blocks.count > maxBubbles && blocks.contains(where: \.rich)) {
      return [Piece(id: 0, kind: .document, text: scanned.plain, replyTag: blocks.compactMap(\.tag).first)]
    }
    // Many short paragraphs are one longer message, still in its bubble.
    if blocks.count > maxBubbles {
      return [Piece(id: 0, kind: .words, text: scanned.plain, replyTag: blocks.compactMap(\.tag).first)]
    }
    return blocks.enumerated().map { index, block in
      Piece(id: index, kind: block.rich ? .document : .words, text: block.lines.joined(separator: "\n"), replyTag: block.tag)
    }
  }

  /// The words without their tags, for Copy, Read aloud and a preview line.
  public static func plain(_ text: String) -> String {
    split(text).map(\.text).joined(separator: "\n\n")
  }

  /// A reply as it is saved: its words without tags, and each piece's tag. Words with no tag come
  /// back exactly as they were.
  public static func tagged(_ text: String) -> (text: String, tags: [Int: Int]) {
    let pieces = split(text)
    let tags = pieces.reduce(into: [Int: Int]()) { found, piece in
      if let tag = piece.replyTag { found[piece.id] = tag }
    }
    guard !tags.isEmpty else { return (text, [:]) }
    let plain = pieces.map(\.text).joined(separator: "\n\n")
    // Removing tags may join lists or documents. Never attach a quote to a different piece.
    return (plain, split(plain).map(\.text) == pieces.map(\.text) ? tags : [:])
  }

  /// Sort whole tagged answers, not paragraphs within an answer. Untagged continuations stay
  /// with their preceding answer; an unknown tag is preserved as unassigned introductory text.
  /// During streaming, hold later answers until the earlier tags have arrived.
  public static func ordered(_ text: String, replies count: Int, streaming: Bool = false) -> String {
    guard count > 1 else { return text }
    let parts = groups(scan(text.replacingOccurrences(of: "\r\n", with: "\n")).blocks)
    guard parts.contains(where: { $0.first?.tag != nil }) else { return text }
    let present = Set(parts.compactMap { $0.first?.tag })
    var through = 0
    while through < count && present.contains(through + 1) { through += 1 }
    func rank(_ group: [Block]) -> Int {
      guard let tag = group.first?.tag, (1...count).contains(tag) else { return 0 }
      return tag
    }
    return parts.enumerated().filter { !streaming || rank($0.element) <= through }
      .sorted { a, b in
        let left = rank(a.element), right = rank(b.element)
        return left == right ? a.offset < b.offset : left < right
      }.map { render($0.element) }.joined(separator: "\n\n")
  }

  private static func groups(_ blocks: [Block]) -> [[Block]] {
    var result: [[Block]] = []
    for block in blocks {
      if result.isEmpty || block.tag != nil { result.append([block]) }
      else { result[result.count - 1].append(block) }
    }
    return result
  }

  private static func render(_ blocks: [Block]) -> String {
    blocks.map { block in
      (block.tag.map { "[reply \($0)] " } ?? "") + block.lines.joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  /// While a reply streams, a tag still being written at the start of a paragraph stays hidden.
  public static func withoutPartialTag(_ text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    guard let last = lines.last?.trimmingCharacters(in: .whitespaces).lowercased(), !last.isEmpty,
      lines.count == 1 || lines[lines.count - 2].trimmingCharacters(in: .whitespaces).isEmpty
    else { return text }
    let whole = "[reply "
    let building = whole.hasPrefix(last)
      || (last.hasPrefix(whole) && last.count <= whole.count + 2 && last.dropFirst(whole.count).allSatisfy(\.isNumber))
    return building ? lines.dropLast().joined(separator: "\n") : text
  }

  private struct Block {
    var lines: [String] = []
    var rich = false
    var heading = false
    var list = false
    var tag: Int?
  }

  /// Blocks between blank lines. A fence is one block, blank lines and all, open or closed, and
  /// nothing inside it counts as markup.
  private static func scan(_ text: String) -> (blocks: [Block], plain: String) {
    var blocks: [Block] = []
    var current = Block()
    var plain: [String] = []
    var inFence = false
    var carried: Int?
    func flush() {
      if !current.lines.isEmpty { blocks.append(current) }
      current = Block()
    }
    for original in text.components(separatedBy: "\n") {
      var line = original
      var marker = line.trimmingCharacters(in: .whitespaces)
      if inFence {
        current.lines.append(line)
        plain.append(line)
        if marker == "```" { inFence = false }
      } else if marker.isEmpty {
        flush()
        plain.append(line)
      } else {
        if current.lines.isEmpty {
          // A tag starts a paragraph, on its line or on one of its own just above.
          if let found = replyTag(marker) {
            carried = found.tag
            line = found.rest
            marker = line.trimmingCharacters(in: .whitespaces)
            if marker.isEmpty { continue }
          }
          current.tag = carried
          carried = nil
          current.list = isListItem(marker)
        }
        if isFenceOpening(marker) {
          inFence = true
          current.rich = true
        }
        if isTableLine(marker) || marker.hasPrefix("![") { current.rich = true }
        if isHeading(marker) || isRule(marker) { current.heading = true }
        current.lines.append(line)
        plain.append(line)
      }
    }
    flush()
    return (blocks, plain.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func replyTag(_ marker: String) -> (tag: Int, rest: String)? {
    let start = "[reply "
    guard marker.lowercased().hasPrefix(start) else { return nil }
    let after = marker.dropFirst(start.count)
    let digits = after.prefix { $0.isASCII && $0.isNumber }
    guard (1...2).contains(digits.count), let tag = Int(digits), tag >= 1, after.dropFirst(digits.count).first == "]" else { return nil }
    let rest = after.dropFirst(digits.count + 1).drop { $0 == " " || $0 == "\t" }
    return (tag, String(rest))
  }

  /// A list written with blank lines between its items, or an indented line under an item, stays
  /// one message.
  private static func merged(_ blocks: [Block]) -> [Block] {
    blocks.reduce(into: [Block]()) { result, block in
      let indented = block.lines.first?.first?.isWhitespace == true
      guard let last = result.last, last.list, !block.rich, !last.rich, block.tag == nil, block.list || indented else {
        result.append(block)
        return
      }
      var joined = last
      joined.lines += [""] + block.lines
      joined.heading = last.heading || block.heading
      result[result.count - 1] = joined
    }
  }

  private static func isFenceOpening(_ marker: String) -> Bool {
    marker.hasPrefix("```") && !marker.dropFirst(3).contains("`")
  }

  private static func isHeading(_ marker: String) -> Bool {
    let hashes = marker.prefix { $0 == "#" }.count
    return (1...6).contains(hashes) && marker.dropFirst(hashes).first == " "
  }

  private static func isRule(_ marker: String) -> Bool {
    marker.count >= 3 && Set(marker).count == 1 && ["-", "*", "_"].contains(marker.first)
  }

  private static func isTableLine(_ marker: String) -> Bool {
    if marker.hasPrefix("|"), marker.hasSuffix("|"), marker.count > 1 { return true }
    // The rule under a table's head, written without its outer pipes.
    return marker.contains("|") && marker.contains("-") && marker.allSatisfy { "|-: ".contains($0) }
  }

  private static func isListItem(_ marker: String) -> Bool {
    if marker.hasPrefix("- ") || marker.hasPrefix("* ") || marker.hasPrefix("+ ") { return true }
    let digits = marker.prefix { $0.isNumber }
    return !digits.isEmpty && marker.dropFirst(digits.count).hasPrefix(". ")
  }
}
