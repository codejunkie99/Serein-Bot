import AppKit
import CoreText
import SereinCore
import SwiftUI

#if DEBUG
/// Cold and growing synthetic workloads; exact-content cache hits are not timed here.
@MainActor func checkColdTextPerformance() throws {
  func check(_ value: Bool, _ label: String) throws {
    if !value { throw SereinError.invalid("Cold text performance: " + label) }
  }
  // This flag runs before normal startup: measure the shipped fonts too.
  if let directory = Bundle.assets.url(forResource: "Fonts", withExtension: nil),
    let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
    for file in files where ["otf", "ttf"].contains(file.pathExtension.lowercased()) {
      CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }
  }
  let code = (0..<300).map { "let value\($0) = \"Unicode 🧪 汉字\" // comment \(42 + $0)\r\n" }.joined()
  let fixture = "**bold** *italic fj* `code` [link](https://example.invalid)\n\t汉字🙂🧪 café é 👩🏽‍💻 العربية עברית 123\r\n"
  let samples = ["", "short", "one\n", "one\r\n", "\tTabs and trailing spaces    ",
    "  Indented  \nlonger line", "\n\nblank\n\nlines\n", fixture, String(repeating: "very long unbroken word", count: 20),
    "\u{2028}line separator\u{2029}paragraph separator", "\rCR\rline", "\tfirst\tsecond\tthird"]
  let view = NSTextView(frame: NSRect(x: 4, y: 8, width: 640, height: 80))
  let frame = view.frame
  for size: CGFloat in [12.5, 14, 19] {
    for mono in [false, true] {
      for sample in samples {
        let text = messageUncachedInlineText(sample, size: size, weight: .regular,
          color: Palette.dusk.ink, accent: Palette.dusk.accent)
        let style = MessageNativeTextStyle(size: size, mono: mono, lineSpacing: 4, ink: Palette.dusk.ink)
        let native = MessageNativeTextRenderer().render(text, style: style)!
        try check(native.isEqual(to: coldBaselineNativeText(text, style: style)),
          "single-buffer conversion preserves complete native attributes and Unicode")
        view.textStorage!.setAttributedString(native)
        let selected = NSRange(location: min(2, native.length), length: min(3, max(0, native.length - 2)))
        view.setSelectedRange(selected)
        let measurement = NativeTextMeasurement.forView(view)
        let oldWidth = ceil(native.boundingRect(with: NSSize(width: 100_000, height: 100_000_000),
          options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
        try check(measurement.naturalWidth() == oldWidth,
          "CoreText width matches drawing width across fonts, Unicode and line endings (old=\(oldWidth), new=\(measurement.naturalWidth()), sample=\(sample.prefix(40)))")
        for width: CGFloat in [160, 640] {
          try check(measurement.height(width: width) == coldBaselineTextHeight(view, width: width),
            "finite-width layout preserves glyph height and extra line fragments")
        }
        try check(view.frame == frame && view.selectedRange() == selected,
          "cold sizing preserves selection and live frame")
      }
    }
  }
  let oversizedLine = AttributedString(String(repeating: "W", count: 20_000))
  let oversizedNative = MessageNativeTextRenderer().render(oversizedLine,
    style: MessageNativeTextStyle(ink: Palette.dusk.ink))!
  view.textStorage!.setAttributedString(oversizedNative)
  let boundedWidth = ceil(oversizedNative.boundingRect(
    with: NSSize(width: 100_000, height: 100_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
  try check(NativeTextMeasurement.forView(view).naturalWidth() == boundedWidth && boundedWidth <= 100_000,
    "oversized single lines preserve the existing intrinsic-width wrapping bound")

  for light in [false, true] {
    for language: String? in [nil, "swift", "rs", "typescript", "py", "json", "unknown"] {
      for source in ["", code, "/* unfinished\r\ncomment */ let x = 1́\n", "let x = \"unfinished 🧪\n", "# emoji 👩🏽‍💻\r\n\t42", "\r\n\n\t"] {
        try check(coldSyntaxMatchesBaseline(source, language: language, light: light),
          "in-place syntax ranges preserve original token attributes and source characters")
      }
    }
  }
  // Prefixes can change earlier tokenization; both paths parse the complete current source.
  var prefix = ""
  for scalar in "let value = \"👩🏽‍💻 é\" /* unfinished\r\ncomment */\n42\n".unicodeScalars {
    prefix.unicodeScalars.append(scalar)
    try check(coldSyntaxMatchesBaseline(prefix, language: "swift", light: false),
      "growing Unicode/string/comment prefixes retain full-source semantics")
  }
  try checkColdStyledRunsDetectDifferences(check)
  for palette in [Palette.dusk, .light] {
    let styledCode = messageUncachedHighlightedCode(code, language: "swift", light: !palette.isDark)
    let style = MessageNativeTextStyle(size: 12.5, mono: true, lineSpacing: 2, ink: palette.ink)
    let native = MessageNativeTextRenderer().render(styledCode, style: style)!
    try check(native.isEqual(to: coldBaselineNativeText(styledCode, style: style)),
      "all code token fonts, colors, paragraph styles and UTF-16 ranges match the previous native rendering")
  }
  NativeTextMeasurement.release(forView: view)
  print("PASS: cold attributes, syntax-prefix equivalence, CoreText widths, finite layout and selection")
  try benchmarkColdTextPerformance(code: code)
}

/// One attribute run as exact UTF-8 bytes. Syntax output is compared this way, not with
/// `AttributedString ==`: on macOS 15.7, Foundation alone reports multi-run CRLF text as different
/// when its bytes, runs and attributes are identical, and some of its run slices miscount their
/// characters (LF text is unaffected). This is also stricter: `==` treats canonically equivalent
/// text as equal, while these bytes must match exactly.
private struct ColdStyledRun: Equatable {
  let bytes: [UInt8]
  let attributes: AttributeContainer
}

private func coldStyledRuns(_ text: AttributedString) -> [ColdStyledRun] {
  text.runs.map { ColdStyledRun(bytes: Array(String(text[$0.range].characters).utf8), attributes: $0.attributes) }
}

@MainActor private func coldSyntaxMatchesBaseline(_ source: String, language: String?, light: Bool) -> Bool {
  let runs = coldStyledRuns(messageUncachedHighlightedCode(source, language: language, light: light))
  return runs == coldStyledRuns(coldBaselineHighlightedCode(source, language: language, light: light))
    && runs.flatMap(\.bytes) == Array(source.utf8)
}

/// Proves the exact comparison still fails for each kind of change it exists to catch.
@MainActor private func checkColdStyledRunsDetectDifferences(_ check: (Bool, String) throws -> Void) throws {
  let styled = coldBaselineHighlightedCode("let value = 1 // note\r\n", language: "swift", light: false)
  let baseline = coldStyledRuns(styled)
  guard let token = styled.runs.first?.range else {
    throw SereinError.invalid("Cold text performance: comparison control has no first run")
  }
  var recolored = styled
  recolored[token].foregroundColor = Color.red
  var shifted = styled
  let shiftedEnd = shifted.index(token.upperBound, offsetByCharacters: 1)
  shifted[token.upperBound..<shiftedEnd].foregroundColor = shifted[token].foregroundColor
  var edited = styled
  edited.characters[token.lowerBound] = "L"
  var equivalent = AttributedString("e\u{301}")
  equivalent.foregroundColor = Color.red
  var composed = AttributedString("\u{E9}")
  composed.foregroundColor = Color.red
  try check(coldStyledRuns(recolored) != baseline, "exact syntax comparison detects a changed token color")
  try check(coldStyledRuns(shifted) != baseline, "exact syntax comparison detects a moved token boundary")
  try check(coldStyledRuns(edited) != baseline, "exact syntax comparison detects a changed source character")
  try check(coldStyledRuns(equivalent) != coldStyledRuns(composed),
    "exact syntax comparison detects canonically equivalent but different source bytes")
}

@MainActor private func coldBaselineTextHeight(_ view: NSTextView, width: CGFloat) -> CGFloat {
  let storage = NSTextStorage(attributedString: view.attributedString())
  let layout = NSLayoutManager()
  let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
  container.lineFragmentPadding = 0
  storage.addLayoutManager(layout)
  layout.addTextContainer(container)
  layout.ensureLayout(for: container)
  let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
  return ceil(max(height, layout.defaultLineHeight(for: view.font ?? messageNativeFont(size: 14))))
}

@MainActor private func benchmarkColdTextPerformance(code: String) throws {
  var checksum: CGFloat = 0
  func timing(_ label: String, iterations: Int = 3, warmup: Bool = true, _ work: () -> Void) {
    if warmup { work() }
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations { work() }
    print("COLD BENCH: \(label): \(String(format: "%.3f", (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(iterations))) ms/call")
  }
  let styledCode = messageUncachedHighlightedCode(code, language: "swift", light: false)
  let style = MessageNativeTextStyle(size: 12.5, mono: true, lineSpacing: 2, ink: Palette.dusk.ink)
  let native = MessageNativeTextRenderer().render(styledCode, style: style)!
  let view = NSTextView(frame: .zero)
  view.textStorage!.setAttributedString(native)
  defer { NativeTextMeasurement.release(forView: view) }
  print("COLD BENCH: \(code.utf8.count) UTF-8 bytes, 300 lines, \(styledCode.runs.count) runs, font \(messageNativeFont(size: 12.5, mono: true).fontName)")
  timing("previous code highlighting") { checksum += CGFloat(coldBaselineHighlightedCode(code, language: "swift", light: false).runs.count) }
  timing("single-buffer code highlighting") { checksum += CGFloat(messageUncachedHighlightedCode(code, language: "swift", light: false).runs.count) }
  timing("previous native conversion") { checksum += CGFloat(coldBaselineNativeText(styledCode, style: style).length) }
  timing("single-buffer native conversion") { checksum += CGFloat(MessageNativeTextRenderer().render(styledCode, style: style)!.length) }
  timing("previous cold intrinsic sizing", iterations: 1, warmup: false) {
    let width = ceil(native.boundingRect(with: NSSize(width: 100_000, height: 100_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
    checksum += coldBaselineTextHeight(view, width: width)
  }
  timing("CoreText cold intrinsic sizing") {
    NativeTextMeasurement.release(forView: view)
    let measurement = NativeTextMeasurement.forView(view)
    checksum += measurement.height(width: measurement.naturalWidth())
  }
  timing("previous cold finite sizing") { checksum += coldBaselineTextHeight(view, width: 640) }
  timing("current cold finite sizing") { NativeTextMeasurement.release(forView: view); checksum += nativeTextHeight(view, width: 640) }
  let lines = code.components(separatedBy: "\n")
  let growing = stride(from: 25, through: 300, by: 25).map { lines.prefix($0).joined(separator: "\n") }
  func stream(_ previous: Bool) {
    for source in growing {
      let highlighted = previous ? coldBaselineHighlightedCode(source, language: "swift", light: false)
        : messageUncachedHighlightedCode(source, language: "swift", light: false)
      let native = previous ? coldBaselineNativeText(highlighted, style: style)
        : MessageNativeTextRenderer().render(highlighted, style: style)!
      view.textStorage!.setAttributedString(native)
      if previous {
        let width = ceil(native.boundingRect(with: NSSize(width: 100_000, height: 100_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
        checksum += coldBaselineTextHeight(view, width: width)
      } else {
        let measurement = NativeTextMeasurement.forView(view)
        checksum += measurement.height(width: measurement.naturalWidth())
      }
    }
  }
  timing("previous growing code, 12 distinct updates", iterations: 1, warmup: false) { stream(true) }
  timing("current growing code, 12 distinct updates", iterations: 3) { stream(false) }
  let proseUnit = "A **synthetic** paragraph with *italic* text, `inline code`, [a source](https://example.invalid), and Unicode 汉字🙂. "
  let proseSnapshots = (1...12).map { String(repeating: proseUnit, count: $0 * 10) }
  func proseStream(_ previous: Bool) {
    for source in proseSnapshots {
      let text = messageUncachedInlineText(source, size: 14, weight: .regular,
        color: Palette.dusk.ink, accent: Palette.dusk.accent)
      let style = MessageNativeTextStyle(lineSpacing: 4, ink: Palette.dusk.ink)
      let native = previous ? coldBaselineNativeText(text, style: style)
        : MessageNativeTextRenderer().render(text, style: style)!
      view.textStorage!.setAttributedString(native)
      checksum += previous ? coldBaselineTextHeight(view, width: 640) : nativeTextHeight(view, width: 640)
    }
  }
  timing("previous growing prose, 12 distinct updates", iterations: 3) { proseStream(true) }
  timing("current growing prose, 12 distinct updates", iterations: 3) { proseStream(false) }
  let cells = (0..<240).map { "Cell \($0) **bold** `code` 汉字🙂" }
  timing("previous cold 240 table cells", iterations: 3) {
    for cell in cells {
      let text = messageUncachedInlineText(cell, size: 14, weight: .regular, color: Palette.dusk.ink, accent: Palette.dusk.accent)
      let native = coldBaselineNativeText(text, style: MessageNativeTextStyle(ink: Palette.dusk.ink))
      view.textStorage!.setAttributedString(native)
      let width = ceil(native.boundingRect(with: NSSize(width: 100_000, height: 100_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
      checksum += coldBaselineTextHeight(view, width: width)
    }
  }
  timing("current cold 240 table cells", iterations: 3) {
    for cell in cells {
      let text = messageUncachedInlineText(cell, size: 14, weight: .regular, color: Palette.dusk.ink, accent: Palette.dusk.accent)
      view.textStorage!.setAttributedString(MessageNativeTextRenderer().render(text, style: MessageNativeTextStyle(ink: Palette.dusk.ink))!)
      let measurement = NativeTextMeasurement.forView(view)
      checksum += measurement.height(width: measurement.naturalWidth())
    }
  }
  if !checksum.isFinite || checksum <= 0 { throw SereinError.invalid("Cold text benchmark produced invalid measurements") }
}

@MainActor private func coldBaselineNativeText(_ text: AttributedString, style: MessageNativeTextStyle) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = style.lineSpacing
    let native = NSMutableAttributedString(string: "")
    for run in text.runs {
      let intent = run.inlinePresentationIntent ?? []
      let runWeight = intent.contains(.stronglyEmphasized) && style.weight != .bold ? .semibold : style.weight
      var font = messageNativeFont(size: style.size, weight: runWeight,
        mono: style.mono || intent.contains(.code), textScale: style.textScale)
      if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(run.foregroundColor ?? style.ink), .paragraphStyle: paragraph,
      ]
      if let background = run.backgroundColor { attributes[.backgroundColor] = NSColor(background) }
      if let link = run.link {
        attributes[.link] = link
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      native.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
    }
    return native
}
private let coldBaselineKeyword = Color(.sRGB, red: 0.55954839, green: 0.58739103, blue: 0.92829858)
private let coldBaselineString = Color(.sRGB, red: 0.11656290, green: 0.71602925, blue: 0.52864868)
private let coldBaselineNumber = Color(.sRGB, red: 0.86000000, green: 0.66362411, blue: 0.14000000)
private let coldBaselineComment = Color(white: 0.60)
// Light: the same hues deepened so each clears 4.5:1 on the light code panel (#F8F8F8).
private let coldBaselineLight = (
  keyword: Color(hex: 0x4A45C8), string: Color(hex: 0x05775A), number: Color(hex: 0x925B05),
  comment: Color(hex: 0x666666))

@MainActor private func coldBaselineHighlightedCode(_ code: String, language: String?, light: Bool) -> AttributedString {
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
  var result = AttributedString()
  var end = code.startIndex
  for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
    guard let range = Range(match.range, in: code) else { continue }
    result += AttributedString(String(code[end..<range.lowerBound]))
    var token = AttributedString(String(code[range]))
    let colors = light ? coldBaselineLight
      : (keyword: coldBaselineKeyword, string: coldBaselineString, number: coldBaselineNumber,
        comment: coldBaselineComment)
    token.foregroundColor = match.range(at: 1).location != NSNotFound ? colors.comment
      : match.range(at: 2).location != NSNotFound ? colors.string
      : match.range(at: 3).location != NSNotFound ? colors.number : colors.keyword
    result += token
    end = range.upperBound
  }
  result += AttributedString(String(code[end...]))
  return result
}


#endif
