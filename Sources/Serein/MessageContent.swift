import AppKit
import SereinCore
import SwiftUI

struct MessagePiece: Identifiable, Equatable {
  enum Content: Equatable {
    case prose(String)
    case code(String, language: String?)
    /// A line that is only a Markdown image (MessageImage shows a local file).
    case image(source: String, alt: String)
    /// A closed ```chart or ```diagram fence that passed its checks (ReplyGraphic), with the
    /// block's own text and label so Copy and export keep the original fence.
    case graphic(ReplyGraphic, code: String, language: String?)
  }
  let id: Int
  let content: Content
}

/// `![alt](source)`, `![alt](<a path with spaces>)` and an optional "title", alone on a line.
private let messageImagePattern = try! NSRegularExpression(
  pattern: #"^!\[([^\]]*)\]\((?:<([^>]+)>|([^)\s]+))(?:\s+"[^"]*")?\)$"#)

func messageImageLine(_ line: String) -> (alt: String, source: String)? {
  let range = NSRange(line.startIndex..., in: line)
  guard let match = messageImagePattern.firstMatch(in: line, range: range),
    let alt = Range(match.range(at: 1), in: line),
    let source = Range(match.range(at: 2), in: line) ?? Range(match.range(at: 3), in: line)
  else { return nil }
  return (String(line[alt]), String(line[source]))
}

func messagePieces(_ text: String) -> [MessagePiece] {
  var pieces: [MessagePiece] = []
  var buffer = ""
  var language: String?
  var inCode = false
  // Foundation preserves the CR in CRLF; Swift Character splitting does not split its LF.
  let lines = text.components(separatedBy: "\n")
  for (index, line) in lines.enumerated() {
    let raw = line + (index < lines.count - 1 ? "\n" : "")
    let marker = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if inCode {
      if marker == "```" {
        // Only a closed fence draws: while a reply streams, its block stays a code panel.
        let content: MessagePiece.Content = ReplyGraphic(language: language, source: buffer)
          .map { MessagePiece.Content.graphic($0, code: buffer, language: language) } ?? .code(buffer, language: language)
        pieces.append(MessagePiece(id: pieces.count, content: content))
        buffer = ""
        inCode = false
        language = nil
      } else {
        buffer += raw
      }
    } else if marker.hasPrefix("```") && !marker.dropFirst(3).contains("`") {
      if !buffer.isEmpty {
        pieces.append(MessagePiece(id: pieces.count, content: .prose(buffer)))
      }
      buffer = ""
      let label = String(marker.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      language = label.isEmpty ? nil : label
      inCode = true
    } else if let picture = messageImageLine(marker) {
      if !buffer.isEmpty {
        pieces.append(MessagePiece(id: pieces.count, content: .prose(buffer)))
      }
      buffer = ""
      pieces.append(MessagePiece(id: pieces.count, content: .image(source: picture.source, alt: picture.alt)))
    } else {
      buffer += raw
    }
  }
  if inCode {
    pieces.append(MessagePiece(id: pieces.count, content: .code(buffer, language: language)))
  } else if !buffer.isEmpty {
    pieces.append(MessagePiece(id: pieces.count, content: .prose(buffer)))
  }
  return pieces
}

enum MessageBlock: Equatable {
  case paragraph(String)
  case heading(String, level: Int)
  case list([MessageListItem])
  case quote(String)
  case table(header: [String], rows: [[String]], alignment: [MessageTableAlignment])
  case rule
}

struct MessageListItem: Equatable {
  let text: String
  let number: Int?
  let checked: Bool?
}

enum MessageTableAlignment: Equatable { case left, center, right }

private let messageListPattern = try! NSRegularExpression(pattern: #"^(?:([-+*])|([0-9]{1,9})[.)])[ \t]+(.*)$"#)

private func messageListItem(_ line: String) -> MessageListItem? {
  guard let match = messageListPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
    let bodyRange = Range(match.range(at: 3), in: line)
  else { return nil }
  let number = Range(match.range(at: 2), in: line).flatMap { Int(line[$0]) }
  var body = String(line[bodyRange])
  var checked: Bool?
  if body.hasPrefix("[ ] ") || body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
    checked = !body.hasPrefix("[ ]")
    body = String(body.dropFirst(4))
  }
  return MessageListItem(text: body, number: number, checked: checked)
}

private func messageHeading(_ line: String) -> (String, Int)? {
  let hashes = line.prefix { $0 == "#" }.count
  guard (1...6).contains(hashes), line.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) == true
  else { return nil }
  let body = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
    .replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
  return (body, hashes)
}

private func messageRule(_ line: String) -> Bool {
  let marks = line.filter { $0 != " " && $0 != "\t" }
  guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
  return marks.allSatisfy { $0 == first }
}

private func messageTableCells(_ line: String) -> [String]? {
  var cells: [String] = []
  var cell = ""
  var ticks: Int?
  let characters = Array(line)
  var index = 0
  while index < characters.count {
    let character = characters[index]
    if character == "\\", index + 1 < characters.count {
      cell.append(character)
      cell.append(characters[index + 1])
      index += 2
      continue
    }
    if character == "`" {
      var end = index + 1
      while end < characters.count && characters[end] == "`" { end += 1 }
      let count = end - index
      if ticks == nil { ticks = count } else if ticks == count { ticks = nil }
      cell += String(repeating: "`", count: count)
      index = end
      continue
    }
    if character == "|" && ticks == nil {
      cells.append(cell.trimmingCharacters(in: .whitespaces))
      cell = ""
    } else {
      cell.append(character)
    }
    index += 1
  }
  guard !cells.isEmpty else { return nil }
  cells.append(cell.trimmingCharacters(in: .whitespaces))
  if cells.first == "" { cells.removeFirst() }
  if cells.last == "" { cells.removeLast() }
  return cells.isEmpty ? nil : cells
}

private func messageTableAlignment(_ line: String) -> [MessageTableAlignment]? {
  guard let cells = messageTableCells(line) else { return nil }
  var alignment: [MessageTableAlignment] = []
  for cell in cells {
    let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
    alignment.append(cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .right) : .left)
  }
  return alignment
}

// shortcut: top-level blocks and flat lists only; use a CommonMark parser if nested document editing is added.
func messageBlocks(_ text: String) -> [MessageBlock] {
  let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
  var blocks: [MessageBlock] = []
  var index = 0
  func table(at position: Int) -> (header: [String], alignment: [MessageTableAlignment])? {
    guard position + 1 < lines.count, let header = messageTableCells(lines[position]),
      let alignment = messageTableAlignment(lines[position + 1]), header.count == alignment.count
    else { return nil }
    return (header, alignment)
  }
  func beginsBlock(at position: Int) -> Bool {
    let line = lines[position]
    return line.trimmingCharacters(in: .whitespaces).isEmpty || messageHeading(line) != nil
      || messageRule(line) || messageListItem(line) != nil || line.hasPrefix(">") || table(at: position) != nil
  }
  while index < lines.count {
    let line = lines[index]
    if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
    if let (body, level) = messageHeading(line) {
      blocks.append(.heading(body, level: level))
      index += 1
    } else if messageRule(line) {
      blocks.append(.rule)
      index += 1
    } else if let first = messageListItem(line) {
      var items: [MessageListItem] = []
      while index < lines.count, let item = messageListItem(lines[index]), (item.number != nil) == (first.number != nil) {
        items.append(MessageListItem(text: item.text, number: first.number.map { $0 + items.count }, checked: item.checked))
        index += 1
      }
      blocks.append(.list(items))
    } else if line.hasPrefix(">") {
      var quote: [String] = []
      while index < lines.count && lines[index].hasPrefix(">") {
        let body = lines[index].dropFirst()
        quote.append(String(body.first == " " ? body.dropFirst() : body))
        index += 1
      }
      blocks.append(.quote(quote.joined(separator: "\n")))
    } else if let table = table(at: index) {
      index += 2
      var rows: [[String]] = []
      while index < lines.count, let cells = messageTableCells(lines[index]), cells.count == table.header.count {
        rows.append(cells)
        index += 1
      }
      blocks.append(.table(header: table.header, rows: rows, alignment: table.alignment))
    } else {
      var paragraph = [line]
      index += 1
      while index < lines.count && !beginsBlock(at: index) {
        paragraph.append(lines[index])
        index += 1
      }
      blocks.append(.paragraph(paragraph.joined(separator: "\n")))
    }
  }
  return blocks
}

/// The sizes a message's words use. The transcript keeps 14 on 22-point lines, code at 12.5 and
/// strong words in semibold. A reply on the personal-assistant screens uses 13 on 20, headings at
/// 16 and 13, code in Geist Mono 12 on 18, and medium for strong words, headings and a table's
/// head (DESIGN.md › Personal-assistant screens). RelayPanel sets `.assistant` on its replies.
struct MessageMetrics {
  var body: CGFloat
  var line: CGFloat
  var code: CGFloat
  var codeLine: CGFloat
  /// The code panel's language label.
  var label: CGFloat
  /// Strong words and headings.
  var strong: Font.Weight
  /// A table's first row.
  var tableHead: Font.Weight
  /// A reply on the personal-assistant screens: only the sizes 16, 13 and 12.
  var reply: Bool
  static let transcript = MessageMetrics(
    body: 14, line: 22, code: 12.5, codeLine: 18, label: 11, strong: .semibold, tableHead: .bold, reply: false)
  static let assistant = MessageMetrics(
    body: 13, line: 20, code: 12, codeLine: 18, label: 12, strong: .medium, tableHead: .medium, reply: true)
  /// The words of a chat's message bubble: `assistant`, at Grok's 15 on 22.
  static let bubble = MessageMetrics(
    body: 15, line: 22, code: 12, codeLine: 18, label: 12, strong: .medium, tableHead: .medium, reply: true)
  /// A heading's size and line height: in a reply 16 for levels 1 and 2 and 13 below them; in the
  /// transcript 19, 16, 15 and 14.
  func heading(_ level: Int) -> (size: CGFloat, line: CGFloat) {
    if reply { return level <= 2 ? (16, 22) : (13, 20) }
    let size: CGFloat = level == 1 ? 19 : level == 2 ? 16 : level == 3 ? 15 : 14
    let line: CGFloat = level == 1 ? 27 : level == 2 ? 24 : 22
    return (size, line)
  }
}
private struct MessageMetricsKey: EnvironmentKey {
  static let defaultValue = MessageMetrics.transcript
}
extension EnvironmentValues {
  var messageMetrics: MessageMetrics {
    get { self[MessageMetricsKey.self] }
    set { self[MessageMetricsKey.self] = newValue }
  }
}

struct MessageContent: View {
  let text: String
  var showsCopyButton = true
  /// What the reply's turn read (AgentMessage.read), for the source line under a chart or diagram.
  var read: ReplySources? = nil
  /// The whole reply's citations when this text is one piece of it (ChatBubbles), so a marker
  /// finds a source list in another piece; nil reads them from this text.
  var cited: CitedAnswer? = nil
  @Environment(\.palette) private var p
  @Environment(\.messageMetrics) private var metrics
  @State private var selection = MessageSelection()
  /// A transcript's one selection, when this reply is inside one (`RelayMessages`).
  @Environment(\.messageSelection) private var shared
  @Environment(\.messageSelectionPrefix) private var prefix
  var body: some View {
    let prefix = shared == nil ? [] : self.prefix
    let cited = self.cited ?? messageCachedCitations(text)
    VStack(alignment: .leading, spacing: 12) {
      ForEach(messageCachedPieces(text)) { piece in
        switch piece.content {
        case .prose(let prose):
          MessageProse(text: prose, selectionPrefix: prefix + [piece.id], cited: cited)
        case .code(let code, let language):
          codePanel(code, language: language, selectionOrder: prefix + [piece.id, 0])
        case .image(let source, let alt):
          MessageImage(source: source, alt: alt)
        case .graphic(let graphic, let code, let language):
          ReplyGraphicPanel(graphic: graphic, fenced: messageFence(code, language: language), read: read,
            showsCopyButton: showsCopyButton)
        }
      }
    }.environment(\.messageSelection, shared ?? selection)
      .foregroundStyle(p.ink).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func codePanel(_ code: String, language: String?, selectionOrder: [Int]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(verbatim: CodeFormat.name(code, language: language))
          .font(UIStyle.mono(metrics.label)).foregroundStyle(p.secondary)
        Spacer()
        CodeCopyButton(text: code)
          .opacity(showsCopyButton ? 1 : 0)
          .allowsHitTesting(showsCopyButton)
          .accessibilityHidden(!showsCopyButton)
      }.padding(.leading, 12).padding(.trailing, 5).frame(height: 28)
        .background(p.codeHeader)
      Rectangle().fill(p.line).frame(height: 1)
      ScrollView(.horizontal) {
        let leading = messageHalfLeading(size: metrics.code, lineHeight: metrics.codeLine, mono: true)
        // A fence's closing newline is not a line of code; copy still uses the exact source.
        SelectableMessageText(text: messageHighlightedCode(messageDisplayCode(code), language: language, light: !p.isDark),
          size: metrics.code, mono: true, lineSpacing: leading * 2, selectionOrder: selectionOrder)
          .padding(.vertical, leading)
          .fixedSize(horizontal: true, vertical: true).padding(.horizontal, 12).padding(.vertical, 10)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.background(p.codePanel, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .clipShape(RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A fenced block as the reply wrote it: the label, the code and the closing fence.
func messageFence(_ code: String, language: String?) -> String {
  let label: String = language ?? ""
  let closes: Bool = code.hasSuffix("\n") || code.isEmpty
  let ending: String = closes ? "" : "\n"
  return "```\(label)\n\(code)\(ending)```"
}

/// Drops trailing line endings so the panel has no empty band under the last line.
private func messageDisplayCode(_ code: String) -> String {
  var end = code.endIndex
  while end > code.startIndex, code[code.index(before: end)].isNewline { end = code.index(before: end) }
  return String(code[..<end])
}

private func messageHalfLeading(size: CGFloat, lineHeight: CGFloat, mono: Bool = false, weight: Font.Weight = .regular) -> CGFloat {
  let font = messageNativeFont(size: size, weight: weight, mono: mono, textScale: 1)
  return max(0, lineHeight - NSLayoutManager().defaultLineHeight(for: font)) / 2
}

@MainActor func messageInlineText(_ source: String, size: CGFloat, weight: Font.Weight, color: Color, accent: Color) -> AttributedString {
  let key = MessageInlineStyleKey(source: source, size: size, weight: weight, color: color,
    accent: accent, textScale: UIStyle.textScale)
  return MessageStyledTextCaches.inline.value(for: key) {
    let value = messageUncachedInlineText(source, size: size, weight: weight, color: color, accent: accent)
    return (value, source.utf8.count * 4 + value.runs.count * 256)
  }
}

/// Kept separate so the focused synthetic benchmark can compare a cache miss with reuse.
func messageUncachedInlineText(_ source: String, size: CGFloat, weight: Font.Weight, color: Color, accent: Color) -> AttributedString {
  var text = (try? AttributedString(markdown: source,
    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
  for run in Array(text.runs) {
    let intent = run.inlinePresentationIntent ?? []
    let runWeight: Font.Weight = intent.contains(.stronglyEmphasized) && weight != .bold ? .semibold : weight
    var font = intent.contains(.code) ? UIStyle.mono(size, weight: runWeight) : UIStyle.font(size, weight: runWeight)
    if intent.contains(.emphasized) { font = font.italic() }
    text[run.range].font = font
    text[run.range].foregroundColor = intent.contains(.code) ? accent : color
    if intent.contains(.code) { text[run.range].backgroundColor = accent.opacity(0.12) }
    if run.link != nil { text[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: color) }
  }
  return text
}

private struct MessageText: View {
  let text: String
  /// nil: the body size and line height of `messageMetrics`.
  var size: CGFloat? = nil
  var lineHeight: CGFloat? = nil
  var weight: Font.Weight = .regular
  var color: Color?
  var selectionOrder: [Int] = []
  var selectionSeparator = "\n\n"
  /// The reply's citations: each marker in this text links to its claim and page.
  var cited: CitedAnswer? = nil
  @Environment(\.palette) private var p
  @Environment(\.messageMetrics) private var metrics
  @Environment(\.openURL) private var openURL
  /// The marker whose claim is lit and whose page shows under the text, by its place in `marks`.
  /// `--ui-affect-cited-answer open` opens each paragraph's first.
  @State private var open: Int? = MessageText.previewOpen ? 0 : nil
  private static let previewOpen = CommandLine.arguments.contains("--ui-preview")
    && CommandLine.arguments.drop(while: { $0 != "--ui-affect-cited-answer" }).dropFirst().first == "open"
  var body: some View {
    let points: CGFloat = size ?? metrics.body
    let line: CGFloat = lineHeight ?? metrics.line
    let leading = messageHalfLeading(size: points, lineHeight: line, weight: weight)
    let color = self.color ?? p.ink
    let styled = messageInlineText(cited?.marked(text) ?? text, size: points, weight: weight, color: color, accent: p.accent)
    let marks = cited?.marks(in: String(styled.characters)) ?? []
    if marks.isEmpty {
      SelectableMessageText(text: styled,
        size: points, weight: weight, strong: metrics.strong, lineSpacing: leading * 2,
        selectionOrder: selectionOrder, selectionSeparator: selectionSeparator)
        .padding(.vertical, leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        SelectableMessageText(text: messageCitedText(styled, marks: marks, open: open, accent: p.accent),
          size: points, weight: weight, strong: metrics.strong, lineSpacing: leading * 2,
          selectionOrder: selectionOrder, selectionSeparator: selectionSeparator)
          .padding(.vertical, leading)
          .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == messageCiteScheme else {
              openURL(url)
              return .handled
            }
            let index = Int(url.host ?? "")
            open = open == index ? nil : index
            return .handled
          })
        if let open, marks.indices.contains(open), let page = cited?.source(marks[open].number) {
          CitedSourceCard(source: page, note: "The reply cites this page for the lit words. Serein did not read it; open it to check.")
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private let messageCiteScheme = "serein-cite"

/// The shown text with each marker as a link to its own place in `marks`, and the open marker's
/// claim lit. Only attributes change, so selection and copy keep the same characters.
private func messageCitedText(_ text: AttributedString, marks: [CitedAnswer.Mark], open: Int?, accent: Color) -> AttributedString {
  var text = text
  func span(_ offsets: Range<Int>) -> Range<AttributedString.Index> {
    let chars = text.characters
    return chars.index(chars.startIndex, offsetBy: offsets.lowerBound)..<chars.index(chars.startIndex, offsetBy: offsets.upperBound)
  }
  if let open, marks.indices.contains(open), !marks[open].claim.isEmpty {
    let claim = span(marks[open].claim)
    text[claim].backgroundColor = accent.opacity(0.14)
  }
  for (index, mark) in marks.enumerated() {
    let marker = span(mark.marker)
    text[marker].link = URL(string: "\(messageCiteScheme)://\(index)")
    text[marker].backgroundColor = accent.opacity(index == open ? 0.3 : 0.12)
  }
  return text
}

@MainActor private enum MessageCitationCache {
  static let answers = MessageRenderCache<String, CitedAnswer?>(costLimit: 1_024 * 1_024)
}

/// A reply's citations, parsed once per text (CitedAnswer); nil for the many replies with none.
@MainActor func messageCachedCitations(_ text: String) -> CitedAnswer? {
  MessageCitationCache.answers.value(for: text) {
    let value = CitedAnswer(reply: text)
    return (value, text.utf8.count + (value?.sources.count ?? 0) * 256)
  }
}

/// The page a citation names, unfolded under its claim (affectUI Cited Answer): its number and
/// host, its title and address, the passage Serein matched on it when it checked one, and
/// Open page. `note` says how far the page was checked.
struct CitedSourceCard: View {
  let source: CitedAnswer.Source
  var quote: String? = nil
  let note: String
  @Environment(\.palette) private var p
  @Environment(\.openURL) private var openURL
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        CitationNumber(number: source.number, open: true)
        Text(source.host).font(UIStyle.metaStrong).lineLimit(1)
        Spacer(minLength: 8)
        if let url = URL(string: source.url) {
          Button("Open page") { openURL(url) }.buttonStyle(QuietButton())
        }
      }
      if let title = source.title {
        Text(title).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(2)
      }
      if let quote {
        Text("\u{201C}" + quote + "\u{201D}").font(UIStyle.meta).foregroundStyle(p.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 10)
          .overlay(alignment: .leading) { Rectangle().fill(p.accent.opacity(0.6)).frame(width: 2) }
      }
      Text(source.url).font(UIStyle.microMono).foregroundStyle(p.faint).lineLimit(1).truncationMode(.middle)
      Text(note).font(UIStyle.micro).foregroundStyle(p.faint).fixedSize(horizontal: false, vertical: true)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).assistantCard(p)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Source \(source.number), \(source.host)")
  }
}

/// A citation's number as a small chip; `open` while its page shows.
struct CitationNumber: View {
  let number: Int
  var open = false
  @Environment(\.palette) private var p
  var body: some View {
    Text("\(number)").font(UIStyle.font(11, weight: .medium)).monospacedDigit().foregroundStyle(p.ink)
      .frame(minWidth: 18, minHeight: 18).padding(.horizontal, 2)
      .background(p.accent.opacity(open ? 0.3 : 0.12), in: RoundedRectangle(cornerRadius: 5))
  }
}

private struct MessageProse: View {
  let text: String
  let selectionPrefix: [Int]
  var cited: CitedAnswer? = nil
  @Environment(\.palette) private var p
  @Environment(\.messageMetrics) private var metrics
  var body: some View {
    let blocks = messageCachedBlocks(text)
    VStack(alignment: .leading, spacing: 12) {
      ForEach(blocks.indices, id: \.self) { index in
        block(blocks[index], order: selectionPrefix + [index])
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private func block(_ block: MessageBlock, order: [Int]) -> some View {
    switch block {
    case .paragraph(let text):
      MessageText(text: text, selectionOrder: order, cited: cited)
    case .heading(let text, let level):
      let heading: (size: CGFloat, line: CGFloat) = metrics.heading(level)
      MessageText(text: text, size: heading.size, lineHeight: heading.line, weight: metrics.strong, selectionOrder: order)
        .accessibilityAddTraits(.isHeader)
    case .list(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(items.indices, id: \.self) { index in
          HStack(alignment: .top, spacing: 8) {
            marker(items[index]).frame(minWidth: 18, alignment: .leading)
            MessageText(text: items[index].text, selectionOrder: order + [index],
              selectionSeparator: index == 0 ? "\n\n" : "\n", cited: cited)
          }
        }
      }
    case .quote(let text):
      MessageText(text: text, color: p.secondary, selectionOrder: order)
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)
        .background(p.accent.opacity(0.05), in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6))
        .overlay(alignment: .leading) { Rectangle().fill(p.accent.opacity(0.6)).frame(width: 2) }
    case .table(let header, let rows, let alignment):
      // A table with a Source column was collected from pages or an attached file (table_query):
      // each row names its page or file, and each value is checked on it (CollectedTableCard).
      if let collected = CollectedTable(header: header, rows: rows) {
        CollectedTableCard(table: collected, alignment: alignment)
      } else {
        table(header: header, rows: rows, alignment: alignment, order: order)
      }
    case .rule:
      Rectangle().fill(p.line).frame(height: 1).accessibilityHidden(true)
    }
  }
  @ViewBuilder private func marker(_ item: MessageListItem) -> some View {
    if let checked = item.checked {
      ZStack {
        RoundedRectangle(cornerRadius: 3).fill(checked ? p.accent : Color.clear)
        RoundedRectangle(cornerRadius: 3).stroke(checked ? p.accent : p.line)
        if checked { InterfaceIcon(systemName: "checkmark", size: 12).foregroundStyle(p.background) }
      }.frame(width: 16, height: 16).frame(height: metrics.line)
        .accessibilityLabel(checked ? "Completed task" : "Unchecked task")
    } else if let number = item.number {
      Text("\(number).").font(UIStyle.font(metrics.body)).foregroundStyle(p.accent).frame(height: metrics.line)
    } else {
      Circle().fill(p.accent).frame(width: 5, height: 5).padding(.leading, 1).frame(height: metrics.line)
        .accessibilityHidden(true)
    }
  }
  private func table(header: [String], rows: [[String]], alignment: [MessageTableAlignment], order: [Int]) -> some View {
    let allRows = [header] + rows
    return ScrollView(.horizontal) {
      // shortcut: native Grid uses intrinsic columns; add measured proportional wrapping if wide tables become a core workflow.
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(allRows.indices, id: \.self) { row in
          if row > 0 { Rectangle().fill(p.borderStrong).frame(height: 1).gridCellColumns(header.count).gridCellUnsizedAxes(.horizontal) }
          GridRow {
            ForEach(header.indices, id: \.self) { column in
              let align: Alignment = alignment[column] == .right ? .trailing : alignment[column] == .center ? .center : .leading
              MessageText(text: allRows[row][column], weight: row == 0 ? metrics.tableHead : .regular,
                selectionOrder: order + [row, column],
                selectionSeparator: column > 0 ? "\t" : row > 0 ? "\n" : "\n\n")
                .fixedSize(horizontal: true, vertical: true).frame(minWidth: 48, alignment: align)
                .padding(.vertical, 8).padding(.leading, column == 0 ? 0 : 12).padding(.trailing, 12)
                .gridColumnAlignment(alignment[column] == .right ? .trailing : alignment[column] == .center ? .center : .leading)
            }
          }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

// Source: pinned Zeron theme.rs SyntaxPalette::dark, git_graph_tone (HSL saturation × 0.72).
private let messageSyntaxKeyword = Color(.sRGB, red: 0.55954839, green: 0.58739103, blue: 0.92829858)
private let messageSyntaxString = Color(.sRGB, red: 0.11656290, green: 0.71602925, blue: 0.52864868)
private let messageSyntaxNumber = Color(.sRGB, red: 0.86000000, green: 0.66362411, blue: 0.14000000)
private let messageSyntaxComment = Color(white: 0.60)
// Light: the same hues deepened so each clears 4.5:1 on the light code panel (#F8F8F8).
private let messageSyntaxLight = (
  keyword: Color(hex: 0x4A45C8), string: Color(hex: 0x05775A), number: Color(hex: 0x925B05),
  comment: Color(hex: 0x666666))

@MainActor func messageHighlightedCode(_ code: String, language: String?, light: Bool = false) -> AttributedString {
  let key = MessageCodeStyleKey(source: code, language: language?.lowercased(), light: light)
  return MessageStyledTextCaches.code.value(for: key) {
    let value = messageUncachedHighlightedCode(code, language: key.language, light: light)
    return (value, code.utf8.count * 4 + value.runs.count * 256)
  }
}

@MainActor func messageUncachedHighlightedCode(_ code: String, language: String?, light: Bool) -> AttributedString {
  let keywords: String
  let comments: String
  switch language?.lowercased() {
  case "swift":
    keywords = "actor|async|await|break|case|catch|class|continue|defer|do|else|enum|extension|for|func|guard|if|import|in|let|private|public|return|some|static|struct|switch|throw|throws|try|var|where|while"
    comments = #"//[^\r\n]*|/\*[\s\S]*?\*/"#
  case "rust", "rs":
    keywords = "as|async|await|break|const|continue|else|enum|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|static|struct|trait|type|unsafe|use|where|while"
    comments = #"//[^\r\n]*|/\*[\s\S]*?\*/"#
  case "javascript", "js", "typescript", "ts":
    keywords = "async|await|break|case|catch|class|const|continue|default|delete|else|export|extends|finally|for|from|function|if|import|in|interface|let|new|return|static|switch|throw|try|type|typeof|var|while|yield"
    comments = #"//[^\r\n]*|/\*[\s\S]*?\*/"#
  case "python", "py":
    keywords = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|if|import|in|is|lambda|not|or|pass|raise|return|try|while|with|yield"
    comments = #"#[^\r\n]*"#
  case "json":
    keywords = "(?!)"
    comments = "(?!)"
  default:
    return AttributedString(code)
  }
  // shortcut: common tokens only; use a language syntax engine for nested comments, multiline strings and semantic roles.
  let pattern = "(" + comments + #")|("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*')|(\b(?:true|false|null|nil|None|True|False|0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b)|(\b(?:"# + keywords + #")\b)"#
  // Only the five fixed language patterns enter this cache; page content is never a pattern.
  let regex = MessageStyledTextCaches.regex.value(for: pattern) {
    (try! NSRegularExpression(pattern: pattern), pattern.utf8.count * 4)
  }
  // Attribute the original buffer in place. Concatenating a fresh attributed substring
  // for every token repeatedly copied growing code and allocated thousands of small strings.
  var result = AttributedString(code)
  let colors = light ? messageSyntaxLight
    : (keyword: messageSyntaxKeyword, string: messageSyntaxString, number: messageSyntaxNumber,
      comment: messageSyntaxComment)
  for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
    guard let range = Range(match.range, in: code),
      let start = AttributedString.Index(range.lowerBound, within: result),
      let end = AttributedString.Index(range.upperBound, within: result) else { continue }
    result[start..<end].foregroundColor = match.range(at: 1).location != NSNotFound ? colors.comment
      : match.range(at: 2).location != NSNotFound ? colors.string
      : match.range(at: 3).location != NSNotFound ? colors.number : colors.keyword
  }
  return result
}

#if DEBUG
@MainActor func checkMessagePieces() {
  assert(messagePieces("").isEmpty)
  assert(messagePieces("Hello") == [MessagePiece(id: 0, content: .prose("Hello"))])
  assert(messagePieces("Before\n```swift\nlet x = 1\n\n```\nAfter") == [
    MessagePiece(id: 0, content: .prose("Before\n")),
    MessagePiece(id: 1, content: .code("let x = 1\n\n", language: "swift")),
    MessagePiece(id: 2, content: .prose("After")),
  ])
  assert(messagePieces("```\n\nunfinished") == [
    MessagePiece(id: 0, content: .code("\nunfinished", language: nil))
  ])
  assert(messagePieces("```swift") == [MessagePiece(id: 0, content: .code("", language: "swift"))])
  assert(messagePieces("```\nunfinished\n") == [
    MessagePiece(id: 0, content: .code("unfinished\n", language: nil))
  ])
  assert(messagePieces("```swift\r\nprint(1)\r\n\r\n```\r\n") == [
    MessagePiece(id: 0, content: .code("print(1)\r\n\r\n", language: "swift"))
  ])
  let inline = "Use ```inline``` here.\n````swift\ncode\n````"
  assert(messagePieces(inline) == [MessagePiece(id: 0, content: .prose(inline))])
  assert(messagePieces("```swift`") == [MessagePiece(id: 0, content: .prose("```swift`"))])
  assert(messagePieces("```\n``` trailing\n```") == [
    MessagePiece(id: 0, content: .code("``` trailing\n", language: nil))
  ])
  let prose = """
    ## Review **results**
    The first paragraph keeps `inline code` and [a source](https://example.invalid).

    - [x] Native layout checked
    - [ ] Keyboard review pending
    3. Preserve source context
    9. Check the next step
    > A quoted **observation**.
    > Its second line stays in the quote.

    | Feature | Status |
    | :--- | ---: |
    | Spacing | Ready |
    ---
    After the rule.
    """
  assert(messageBlocks(prose) == [
    .heading("Review **results**", level: 2),
    .paragraph("The first paragraph keeps `inline code` and [a source](https://example.invalid)."),
    .list([MessageListItem(text: "Native layout checked", number: nil, checked: true),
      MessageListItem(text: "Keyboard review pending", number: nil, checked: false)]),
    .list([MessageListItem(text: "Preserve source context", number: 3, checked: nil),
      MessageListItem(text: "Check the next step", number: 4, checked: nil)]),
    .quote("A quoted **observation**.\nIts second line stays in the quote."),
    .table(header: ["Feature", "Status"], rows: [["Spacing", "Ready"]], alignment: [.left, .right]),
    .rule, .paragraph("After the rule."),
  ])
  assert(messageBlocks("| Code | Value |\n| --- | :---: |\n| `a|b` | escaped \\| pipe |") == [
    .table(header: ["Code", "Value"], rows: [["`a|b`", "escaped \\| pipe"]], alignment: [.left, .center])
  ])
  let unsupported = "<section>Readable HTML text</section>\n  - Indented list\n| invalid | table |\n| -- | : |"
  assert(messageBlocks(unsupported) == [.paragraph(unsupported)])
  let rawCode = "\t// ## Not a heading\r\nlet value = \"| --- |\"\r\n\r\n"
  assert(messagePieces("## Before\n```swift\r\n" + rawCode + "```\r\nAfter") == [
    MessagePiece(id: 0, content: .prose("## Before\n")),
    MessagePiece(id: 1, content: .code(rawCode, language: "swift")),
    MessagePiece(id: 2, content: .prose("After")),
  ])
  // Paint must never change the selected/copied source, including Unicode and CRLF.
  let highlightedSource = "let value = \"emoji 🧪 and // text\" // comment\r\n\t42\n\n"
  for language in ["swift", "rust", "javascript", "typescript", "python", "json", "unknown"] {
    assert(String(messageHighlightedCode(highlightedSource, language: language).characters) == highlightedSource)
  }
  let syntaxColors = messageHighlightedCode("let value = \"text\" // comment\n42", language: "swift")
    .runs.compactMap(\.foregroundColor)
  assert(syntaxColors.contains(messageSyntaxKeyword) && syntaxColors.contains(messageSyntaxString)
    && syntaxColors.contains(messageSyntaxNumber) && syntaxColors.contains(Color(white: 0.60)))
  let inlineText = messageInlineText("**bold** *italic* `code` [link](https://example.invalid)",
    size: 14, weight: .regular, color: Palette.light.ink, accent: Palette.light.accent)
  assert(String(inlineText.characters) == "bold italic code link")
  assert(inlineText.runs.contains { $0.link?.absoluteString == "https://example.invalid" })
}
#endif
