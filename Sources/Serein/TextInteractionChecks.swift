#if DEBUG
import AppKit
import SereinCore

/// Real native text commands, with synthetic text and an isolated pasteboard.
@MainActor func checkTextInteractions() async throws {
  func check(_ value: Bool, _ label: String) throws {
    if !value { throw SereinError.invalid("Text interaction: " + label) }
  }
  let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
  editor.font = messageNativeFont(size: 14)
  var returns: [Bool] = []
  editor.onReturn = { returns.append($0) }
  func enter(_ flags: NSEvent.ModifierFlags = [], code: UInt16 = 36) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
    editor.keyDown(with: event)
  }
  enter(.shift)
  try check(editor.string == "\n" && returns.isEmpty, "Shift-Return inserts into an empty draft")
  editor.string = "one🙂two"
  editor.setSelectedRange(NSRange(location: 5, length: 0))
  enter(.shift)
  try check(editor.string == "one🙂\ntwo", "Shift-Return inserts at a UTF-16 caret")
  editor.setSelectedRange(NSRange(location: 0, length: 3))
  enter([.shift, .option])
  try check(editor.string == "\n🙂\ntwo", "Shift-Return replaces selected text and wins over Option")
  let draft = editor.string
  enter()
  enter(.option)
  enter(.shift, code: 76)
  try check(returns == [false, true] && editor.string != draft, "Return submits, Option-Return routes, keypad Enter adds a line")

  editor.string = "one"
  let frame = editor.frame
  let oneLine = nativeTextHeight(editor, width: 320)
  editor.string = "one\n"
  let twoLines = nativeTextHeight(editor, width: 320)
  try check(twoLines > oneLine, "a trailing newline reserves its own visible line")
  editor.string = String(repeating: "synthetic wrapping text ", count: 30)
  let wide = nativeTextHeight(editor, width: 320)
  let narrow = nativeTextHeight(editor, width: 160)
  try check(narrow > wide, "native text wraps when the panel narrows")
  try check(editor.frame == frame, "measurement leaves the live frame unchanged during resize/fullscreen")

  let host = MessageTextHost()
  host.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
  host.layout()
  let transcript = host.textView
  try check(transcript.frame == host.bounds, "the native transcript stays inside its SwiftUI sizing host")
  transcript.isEditable = false
  transcript.isSelectable = true
  transcript.string = "Synthetic answer\nSecond line"
  transcript.setSelectedRange(NSRange(location: 10, length: 6))
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  try check(transcript.writeSelection(to: pasteboard, types: transcript.writablePasteboardTypes),
    "read-only transcript permits copying a selection")
  try check(pasteboard.string(forType: .string) == "answer", "selection copies only the selected text")
  let selection = transcript.selectedRange()
  _ = nativeTextHeight(transcript, width: 120)
  try check(transcript.selectedRange() == selection && !transcript.isEditable,
    "layout preserves read-only transcript selection")

  // Markdown is rendered in several native views. Select All and copying must span
  // those views, in source order, without including a different reply or composer.
  let reply = MessageSelection()
  let first = MessageTextView(frame: .zero)
  let codeBlock = MessageTextView(frame: .zero)
  let last = MessageTextView(frame: .zero)
  for view in [first, codeBlock, last] { view.isEditable = false; view.isSelectable = true }
  first.string = "First paragraph 🙂"
  codeBlock.string = "let value = 42\nprint(value)"
  last.string = "Last paragraph"
  reply.register(last, order: [2, 0], separator: "\n\n")
  reply.register(first, order: [0, 0], separator: "\n\n")
  reply.register(codeBlock, order: [1, 0], separator: "\n\n")
  codeBlock.selectAll(nil)
  let completeReply = first.string + "\n\n" + codeBlock.string + "\n\n" + last.string
  try check(reply.selectedText == completeReply && [first, codeBlock, last].allSatisfy {
    $0.selectedRange() == NSRange(location: 0, length: ($0.string as NSString).length)
  }, "Select All from a middle block selects the whole reply across paragraphs and code")
  try check(first.writeSelection(to: pasteboard, types: first.writablePasteboardTypes)
    && pasteboard.string(forType: .string) == completeReply,
    "native selection copy includes the entire reply in document order")
  reply.select(from: 6, to: (completeReply as NSString).length - 5)
  let crossBlockSelection = (completeReply as NSString).substring(
    with: NSRange(location: 6, length: (completeReply as NSString).length - 11))
  try check(reply.selectedText == crossBlockSelection && reply.copy(to: pasteboard)
    && pasteboard.string(forType: .string) == crossBlockSelection,
    "a partial selection crosses block boundaries and preserves Unicode and newlines")
  reply.select(from: (completeReply as NSString).length - 5, to: 6)
  try check(reply.selectedText == crossBlockSelection, "reverse selection spans the same blocks")
  try check(transcript.selectedRange() == selection && transcript.messageSelection == nil && editor.isEditable,
    "reply selection leaves another message and the editable composer alone")

  let cell = MessageTextView(frame: .zero)
  cell.string = "Table cell"
  reply.register(cell, order: [2, 1], separator: "\t")
  last.selectAll(nil)
  try check(reply.selectedText == completeReply + "\tTable cell", "table cells share the reply's selection in row order")
  reply.unregister(cell)
  last.selectAll(nil)
  try check(reply.selectedText == completeReply && cell.messageSelection == nil,
    "removed or reused blocks do not leave stale content in the reply selection")
  first.moveLeft(nil)
  try check(reply.selectedText.isEmpty && reply.selectedRange.location == 0,
    "an arrow collapses the entire selection instead of leaving other blocks selected")
  first.moveToEndOfDocumentAndModifySelection(nil)
  try check(reply.selectedText == completeReply, "keyboard extension reaches the end of the whole reply")
  let emoji = (first.string as NSString).range(of: "🙂")
  reply.select(from: emoji.location, to: emoji.location)
  first.moveRightAndModifySelection(nil)
  try check(reply.selectedText == "🙂", "keyboard selection preserves composed Unicode characters")

  // Render two native blocks with focus in only one. Both must paint the same active
  // highlight, then return to inactive selection when focus moves to the composer.
  let previousKeyWindow = NSApp.keyWindow
  let highlightWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
    styleMask: [.titled], backing: .buffered, defer: true)
  highlightWindow.isReleasedWhenClosed = false
  highlightWindow.appearance = NSAppearance(named: .aqua)
  defer {
    highlightWindow.close()
    previousKeyWindow?.makeKey()
  }
  let highlightReply = MessageSelection()
  let highlightHosts = [MessageTextHost(), MessageTextHost()]
  for (index, host) in highlightHosts.enumerated() {
    let view = host.textView
    view.isEditable = false
    view.isSelectable = true
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.font = messageNativeFont(size: 14)
    view.string = "    Selected paragraph \(index)"
    highlightReply.register(view, order: [index], separator: "\n\n")
    host.frame = NSRect(x: 0, y: CGFloat(index) * 45, width: 300, height: 40)
    highlightWindow.contentView?.addSubview(host)
    host.layout()
  }
  let otherInput = NSTextView(frame: NSRect(x: 0, y: 90, width: 300, height: 40))
  otherInput.font = messageNativeFont(size: 14)
  otherInput.textContainerInset = .zero
  otherInput.textContainer?.lineFragmentPadding = 0
  otherInput.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor,
    .foregroundColor: NSColor.selectedTextColor]
  otherInput.string = "    Native selection reference"
  highlightWindow.contentView?.addSubview(otherInput)
  highlightWindow.makeKeyAndOrderFront(nil)
  // Activation and WindowServer key-window changes complete on later run-loop turns.
  // Wait for this fixture window, not merely the verifier's previous app window.
  for _ in 0..<30 {
    if NSApp.isActive && highlightWindow.isKeyWindow { break }
    NSApp.activate(ignoringOtherApps: true)
    highlightWindow.makeKey()
    try await Task.sleep(for: .milliseconds(100))
  }
  try check(NSApp.isActive && highlightWindow.isKeyWindow,
    "the highlight fixture receives application and key-window focus")
  func selectionPixel(_ view: NSTextView) -> NSColor? {
    guard let layout = view.layoutManager, let container = view.textContainer,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    layout.ensureLayout(for: container)
    let glyph = layout.glyphRange(forCharacterRange: NSRange(location: 1, length: 1), actualCharacterRange: nil)
    let selectedGlyphs = layout.glyphRange(forCharacterRange: view.selectedRange(), actualCharacterRange: nil)
    var selectionRect: NSRect?
    layout.enumerateEnclosingRects(forGlyphRange: glyph, withinSelectedGlyphRange: selectedGlyphs,
      in: container) { rect, stop in selectionRect = rect; stop.pointee = true }
    guard let selectionRect else { return nil }
    let rect = selectionRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let x = Int(rect.midX * CGFloat(bitmap.pixelsWide) / view.bounds.width)
    let bitmapY = view.isFlipped ? rect.midY : view.bounds.height - rect.midY
    let y = Int(bitmapY * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
    return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
  }
  func colorsMatch(_ a: NSColor?, _ b: NSColor?) -> Bool {
    guard let a = a?.usingColorSpace(.deviceRGB), let b = b?.usingColorSpace(.deviceRGB) else { return false }
    return abs(a.redComponent - b.redComponent) < 0.025
      && abs(a.greenComponent - b.greenComponent) < 0.025
      && abs(a.blueComponent - b.blueComponent) < 0.025
  }
  // Compare with pixels rendered by AppKit in the same context. The cached bitmap is
  // color managed, so its components can differ from an NSColor's raw RGB values.
  highlightWindow.makeFirstResponder(otherInput)
  otherInput.selectAll(nil)
  let nativeColor = selectionPixel(otherInput)
  highlightWindow.makeFirstResponder(highlightHosts[0].textView)
  highlightReply.selectAll()
  let focusedColor = selectionPixel(highlightHosts[0].textView)
  let siblingColor = selectionPixel(highlightHosts[1].textView)
  try check(highlightReply.isActive(in: highlightWindow)
    && colorsMatch(focusedColor, nativeColor)
    && colorsMatch(focusedColor, siblingColor),
    "every selected reply block paints the same active system highlight (active=\(highlightReply.isActive(in: highlightWindow)), native=\(String(describing: nativeColor)), focused=\(String(describing: focusedColor)), sibling=\(String(describing: siblingColor)))")
  highlightWindow.makeFirstResponder(otherInput)
  try check(!highlightReply.isActive(in: highlightWindow)
    && !colorsMatch(selectionPixel(highlightHosts[1].textView), focusedColor)
    && highlightReply.selectedText == "    Selected paragraph 0\n\n    Selected paragraph 1",
    "focus outside the reply dims its whole selection without clearing the selected text")
}
#endif
