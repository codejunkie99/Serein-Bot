import AppKit
import SereinCore
import SwiftUI

#if DEBUG
/// Synthetic content only: native sizing, style invalidation, cache bounds and timings.
/// The baseline is the original detached TextKit algorithm, retained only in this check.
@MainActor func checkTextPerformance() throws {
  func check(_ value: Bool, _ label: String) throws {
    if !value { throw SereinError.invalid("Text performance: " + label) }
  }
  let view = NSTextView(frame: NSRect(x: 7, y: 11, width: 640, height: 80))
  view.font = messageNativeFont(size: 14)
  view.string = "Synthetic wrapping text 🙂 汉字 " + String(repeating: "wrap words ", count: 40)
  let frame = view.frame
  view.setSelectedRange(NSRange(location: 4, length: 12))
  let selected = view.selectedRange()
  let measurement = NativeTextMeasurement.forView(view)
  let first = measurement.height(width: 320)
  try check(first == baselineNativeTextHeight(view, width: 320), "wrapped height matches the original algorithm")
  let layouts = measurement.layoutPassCount
  for _ in 0..<20 { _ = measurement.height(width: 320) }
  try check(measurement.layoutPassCount == layouts && measurement.snapshotCount == 1
    && measurement.naturalWidthPassCount == 0, "repeated finite widths perform no new snapshot, layout or natural-width work")
  let narrow = measurement.height(width: 160)
  try check(narrow > first && narrow == baselineNativeTextHeight(view, width: 160), "narrow width wraps correctly")
  let natural = measurement.naturalWidth()
  let baselineNatural = ceil(view.attributedString().boundingRect(
    with: NSSize(width: 100_000, height: 100_000_000),
    options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
  try check(natural == baselineNatural, "intrinsic code/table width matches the original measurement")
  _ = measurement.naturalWidth()
  try check(measurement.naturalWidthPassCount == 1 && view.frame == frame && view.selectedRange() == selected,
    "intrinsic width is cached and sizing preserves the live frame and selection")

  view.string = "one"
  let oneLine = measurement.height(width: 320)
  view.string = "one\n"
  try check(measurement.height(width: 320) > oneLine, "a source edit and trailing newline invalidate the height")
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineSpacing = 20
  view.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
    range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
  try check(measurement.height(width: 320) == baselineNativeTextHeight(view, width: 320),
    "attribute-only edits invalidate the snapshot")
  view.font = messageNativeFont(size: 28)
  try check(measurement.height(width: 320) == baselineNativeTextHeight(view, width: 320),
    "font changes invalidate sizing")
  let unrelated = NSTextView(frame: .zero)
  unrelated.font = messageNativeFont(size: 14)
  unrelated.string = "independent"
  try check(NativeTextMeasurement.forView(unrelated) !== measurement,
    "different messages never share a live-view measurement cache")

  // A control demonstrates why the check must not wait for NSTextView disposal:
  // AppKit can hold even an uncached view after its lexical scope/autorelease pool.
  weak var controlView: NSTextView?
  weak var releasedView: NSTextView?
  weak var releasedMeasurement: NativeTextMeasurement?
  autoreleasepool {
    let control = NSTextView(frame: .zero)
    control.string = "ephemeral synthetic text"
    controlView = control
    let temporary = NSTextView(frame: .zero)
    temporary.string = "ephemeral synthetic text"
    releasedView = temporary
    releasedMeasurement = NativeTextMeasurement.forView(temporary)
    _ = nativeTextHeight(temporary, width: 320)
    NativeTextMeasurement.release(forView: temporary)
  }
  try check(releasedMeasurement == nil && (releasedView == nil || controlView != nil),
    "teardown releases detached measurement and observer independently of native view disposal")

  let renderer = MessageNativeTextRenderer()
  let inline = messageInlineText("**bold** *italic* `code` [link](https://example.invalid)\n  next 🙂",
    size: 14, weight: .regular, color: Palette.dusk.ink, accent: Palette.dusk.accent)
  var style = MessageNativeTextStyle(lineSpacing: 4, ink: Palette.dusk.ink)
  let initial = renderer.render(inline, style: style)!
  try check(initial.string == "bold italic code link\n  next 🙂",
    "cached Markdown preserves whitespace, Unicode and display text")
  try check(renderer.render(inline, style: style) == nil, "unchanged attributed input avoids native reconstruction")
  let ns = initial.string as NSString
  let link = ns.range(of: "link")
  let code = ns.range(of: "code")
  try check(initial.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.invalid")
    && initial.attribute(.underlineStyle, at: link.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue
    && initial.attribute(.backgroundColor, at: code.location, effectiveRange: nil) != nil,
    "native links, underline and inline-code background survive caching")
  let plain = AttributedString("plain")
  _ = renderer.render(plain, style: style)
  style.ink = Palette.light.ink
  let light = renderer.render(plain, style: style)!
  try check(light.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor(Palette.light.ink),
    "theme changes rebuild plain-text ink")
  style.textScale = 1.5
  let scaled = renderer.render(plain, style: style)!
  try check((scaled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == style.size * 1.5,
    "text scale rebuilds the native font")
  style.weight = .semibold
  try check(renderer.render(plain, style: style) != nil, "font weight invalidates native runs")
  style.lineSpacing = 9
  let spaced = renderer.render(plain, style: style)!
  try check((spaced.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing == 9,
    "line spacing invalidates native paragraphs")

  let cache = MessageRenderCache<String, String>(costLimit: 5, entryLimit: 2)
  var creates = 0
  func cached(_ key: String, cost: Int = 2) -> String {
    cache.value(for: key) { creates += 1; return (key, cost) }
  }
  _ = cached("a"); _ = cached("b"); _ = cached("a"); _ = cached("c")
  try check(creates == 3 && cache.count == 2 && cache.cost == 4, "bounded LRU cache reuses a hit and evicts one old entry")
  _ = cached("oversized", cost: 6)
  try check(cache.count == 2 && cache.cost == 4, "oversized values do not displace bounded cached values")
  _ = cached("b")
  try check(creates == 5 && cache.count == 2 && cache.cost <= cache.costLimit, "evicted values recompute within both bounds")
  for source in ["", "one\n\n## Two\n- [x] three", "```swift\r\nlet x = 1\r\n```", "```\nunfinished\n"] {
    try check(messageCachedPieces(source) == messagePieces(source)
      && messageCachedBlocks(source) == messageBlocks(source), "block and fence caches preserve parser output")
  }
  for light in [false, true] {
    let code = "let value = \"emoji 🧪\" // comment\r\n\t42\n"
    let highlighted = messageHighlightedCode(code, language: "swift", light: light)
    try check(String(highlighted.characters) == code
      && highlighted == messageHighlightedCode(code, language: "swift", light: light),
      "highlight caches preserve raw code and repeated styling")
  }
  print("PASS: native text cache reuse, sizing, selection, style invalidation and memory bounds")
  try benchmarkTextPerformance()
  try checkColdTextPerformance()
}

@MainActor private func baselineNativeTextHeight(_ view: NSTextView, width: CGFloat) -> CGFloat {
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

@MainActor private func benchmarkTextPerformance() throws {
  let paragraph = "Synthetic paragraph with **bold** and *italic* words, [a link](https://example.invalid), `inline code`, Unicode 🙂 汉字, and enough text to wrap.\n\n"
  let source = String(repeating: paragraph, count: 120)
  let view = NSTextView(frame: .zero)
  view.font = messageNativeFont(size: 14)
  view.string = source
  let iterations = 8
  var checksum: CGFloat = 0
  func timing(_ label: String, _ work: () -> Void) -> Double {
    work()
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations { work() }
    let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1_000 / Double(iterations)
    print("BENCH: \(label): \(String(format: "%.6f", milliseconds)) ms/call")
    return milliseconds
  }
  print("BENCH: \(source.utf8.count) synthetic UTF-8 bytes, \(iterations) iterations, 640-point width; no provider or private data")
  _ = timing("original finite-width sizing") {
    checksum += ceil(view.attributedString().boundingRect(
      with: NSSize(width: 100_000, height: 100_000_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
    checksum += baselineNativeTextHeight(view, width: 640)
  }
  _ = timing("cached finite-width sizing") { checksum += nativeTextHeight(view, width: 640) }
  _ = timing("original block parse") { checksum += CGFloat(messageBlocks(source).count) }
  _ = timing("cached block parse") { checksum += CGFloat(messageCachedBlocks(source).count) }
  _ = timing("original styled inline Markdown") {
    checksum += CGFloat(messageUncachedInlineText(source, size: 14, weight: .regular,
      color: Palette.dusk.ink, accent: Palette.dusk.accent).runs.count)
  }
  _ = timing("cached styled inline Markdown") {
    checksum += CGFloat(messageInlineText(source, size: 14, weight: .regular,
      color: Palette.dusk.ink, accent: Palette.dusk.accent).runs.count)
  }
  if !checksum.isFinite || checksum <= 0 { throw SereinError.invalid("Text benchmark produced invalid sizing") }
}
#endif
