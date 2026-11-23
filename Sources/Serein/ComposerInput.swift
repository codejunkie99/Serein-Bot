import AppKit
import CoreText
import SwiftUI

/// Native editing keeps selection, IME input and Shift-Return inside the text system.
struct ComposerInput: NSViewRepresentable {
  var placeholder: String
  @Binding var text: String
  @Binding var focused: Bool
  var minHeight: CGFloat = 22
  var maxHeight: CGFloat = 200
  var lineSpacing: CGFloat = 4
  var label = "Task message"
  var onReturn: (_ option: Bool) -> Void
  var onCommandKey: ((NSEvent) -> Bool)? = nil
  var onSelection: ((NSRange) -> Void)? = nil
  var moveCaretToEndOnChange = false
  @Environment(\.palette) private var p

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    let editor = ComposerTextView(frame: .zero)
    editor.isRichText = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.drawsBackground = false
    editor.textContainerInset = .zero
    editor.textContainer?.lineFragmentPadding = 0
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.delegate = context.coordinator
    editor.focusChanged = { [weak coordinator = context.coordinator] value in
      DispatchQueue.main.async { coordinator?.input.focused = value }
    }
    scroll.documentView = editor
    updateNSView(scroll, context: context)
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.input = self
    guard let editor = scroll.documentView as? ComposerTextView else { return }
    let font = messageNativeFont(size: 14)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    let ink = NSColor(p.ink)
    if editor.font != font { editor.font = font }
    if editor.textColor != ink { editor.textColor = ink }
    if editor.insertionPointColor != ink { editor.insertionPointColor = ink }
    if editor.defaultParagraphStyle != paragraph {
      editor.defaultParagraphStyle = paragraph
      editor.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
        range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
    }
    if !editor.hasMarkedText() {
      let typing: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
      if !NSDictionary(dictionary: editor.typingAttributes).isEqual(to: typing) { editor.typingAttributes = typing }
    }
    let hint = NSAttributedString(string: placeholder, attributes: [
      .font: font, .foregroundColor: NSColor(p.faint), .paragraphStyle: paragraph,
    ])
    if !editor.placeholder.isEqual(to: hint) {
      editor.placeholder = hint
      editor.needsDisplay = true
    }
    editor.setAccessibilityLabel(label)
    editor.onReturn = onReturn
    editor.onCommandKey = onCommandKey
    if editor.string != text && !editor.hasMarkedText() {
      let selection = editor.selectedRange()
      editor.string = text
      editor.setSelectedRange(NSRange(location: moveCaretToEndOnChange ? (text as NSString).length : min(selection.location, (text as NSString).length), length: 0))
      editor.needsDisplay = true
    }
    if focused && scroll.window?.firstResponder !== editor {
      DispatchQueue.main.async { [weak editor] in
        guard let editor, context.coordinator.input.focused else { return }
        editor.window?.makeFirstResponder(editor)
      }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite,
      let editor = nsView.documentView as? NSTextView else { return nil }
    let height = nativeTextHeight(editor, width: width)
    return CGSize(width: width, height: min(maxHeight, max(minHeight, height)))
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    guard let editor = scroll.documentView as? ComposerTextView else { return }
    NativeTextMeasurement.release(forView: editor)
    editor.delegate = nil
    editor.focusChanged = nil
    editor.onReturn = nil
    editor.onCommandKey = nil
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var input: ComposerInput
    init(_ input: ComposerInput) { self.input = input }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
      let selection = editor.selectedRange()
      DispatchQueue.main.async { [weak self] in self?.input.onSelection?(selection) }
    }
    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? NSTextView else { return }
      input.text = editor.string
      if !editor.hasMarkedText() { input.onSelection?(editor.selectedRange()) }
      editor.needsDisplay = true
    }
  }
}

final class ComposerTextView: NSTextView {
  var placeholder = NSAttributedString()
  var onReturn: ((Bool) -> Void)?
  var onCommandKey: ((NSEvent) -> Bool)?
  var focusChanged: ((Bool) -> Void)?
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    // A placeholder longer than the field ends in an ellipsis instead of a hidden second line.
    if string.isEmpty { placeholder.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]) }
  }
  override func keyDown(with event: NSEvent) {
    if !hasMarkedText(), onCommandKey?(event) == true { return }
    guard [36, 76].contains(event.keyCode), !hasMarkedText(),
      event.modifierFlags.intersection([.command, .control]).isEmpty
    else { super.keyDown(with: event); return }
    if event.modifierFlags.contains(.shift) {
      insertNewlineIgnoringFieldEditor(nil)
    } else {
      onReturn?(event.modifierFlags.contains(.option))
    }
  }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { focusChanged?(true) }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { focusChanged?(false) }
    return accepted
  }
}

/// Includes the extra line fragment so a trailing newline immediately grows the editor.
@MainActor func nativeTextHeight(_ view: NSTextView, width: CGFloat) -> CGFloat {
  NativeTextMeasurement.forView(view).height(width: width)
}

/// A detached TextKit stack keeps measurement from resizing the live view during a
/// SwiftUI layout pass. Reuse it across proposals, and cache only four recent widths.
/// Storage edits invalidate every result, including attribute-only style changes.
@MainActor final class NativeTextMeasurement {
  private static var associationKey: UInt8 = 0
  private weak var view: NSTextView?
  private let storage = NSTextStorage()
  private let layout = NSLayoutManager()
  private let container = NSTextContainer(size: .zero)
  private var observer: NSObjectProtocol?
  private var needsSnapshot = true
  private var fallbackFont: NSFont?
  private var heights: [(width: CGFloat, height: CGFloat)] = []
  private var unwrappedWidth: CGFloat?
  #if DEBUG
  private(set) var snapshotCount = 0
  private(set) var layoutPassCount = 0
  private(set) var naturalWidthPassCount = 0
  #endif

  static func forView(_ view: NSTextView) -> NativeTextMeasurement {
    if let existing = objc_getAssociatedObject(view, &associationKey) as? NativeTextMeasurement {
      return existing
    }
    let measurement = NativeTextMeasurement(view)
    objc_setAssociatedObject(view, &associationKey, measurement, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return measurement
  }

  /// SwiftUI teardown releases derived storage immediately. AppKit can keep an
  /// NSTextView alive past removal from its host, so do not wait for view deallocation.
  static func release(forView view: NSTextView) {
    objc_setAssociatedObject(view, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  private init(_ view: NSTextView) {
    self.view = view
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    if let source = view.textStorage {
      observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
        object: source, queue: nil) { [weak self] _ in
          MainActor.assumeIsolated { self?.invalidate() }
        }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func invalidate() {
    needsSnapshot = true
    heights.removeAll(keepingCapacity: true)
    unwrappedWidth = nil
  }

  private func updateSnapshot() {
    guard let view else { return }
    let font = view.font ?? messageNativeFont(size: 14)
    if fallbackFont != font {
      fallbackFont = font
      heights.removeAll(keepingCapacity: true)
    }
    guard needsSnapshot else { return }
    storage.setAttributedString(view.attributedString())
    #if DEBUG
    snapshotCount += 1
    #endif
    needsSnapshot = false
  }

  func naturalWidth() -> CGFloat {
    updateSnapshot()
    if let unwrappedWidth { return unwrappedWidth }
    #if DEBUG
    naturalWidthPassCount += 1
    #endif
    // NSAttributedString's drawing-based boundingRect becomes very expensive for large
    // highlighted code. A CoreText typesetter measures each complete source line with the
    // same glyph advances and paragraph attributes, without drawing or rebuilding TextKit.
    let typesetter = CTTypesetterCreateWithAttributedString(storage)
    let string = storage.string as NSString
    var location = 0
    var widest: Double = 0
    while location < string.length {
      var start = 0, end = 0, contentsEnd = 0
      string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0))
      // CoreText treats a zero-length CFRange as "to the end", not an empty line.
      if contentsEnd > start {
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: contentsEnd - start))
        widest = max(widest, CTLineGetTypographicBounds(line, nil, nil, nil))
      }
      location = end
    }
    // Preserve the existing 100,000-point line-wrapping bound for pathological single
    // lines. Normal code and table cells take the cheap complete-line measurement above.
    let width = widest <= 100_000 ? ceil(widest) : ceil(storage.boundingRect(
      with: NSSize(width: 100_000, height: 100_000_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
    unwrappedWidth = width
    return width
  }

  func height(width: CGFloat) -> CGFloat {
    updateSnapshot()
    let width = max(1, width.isFinite ? width : 1)
    if let index = heights.firstIndex(where: { $0.width == width }) {
      let hit = heights.remove(at: index)
      heights.append(hit)
      return hit.height
    }
    container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    #if DEBUG
    layoutPassCount += 1
    #endif
    let height = ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY,
      layout.defaultLineHeight(for: fallbackFont ?? messageNativeFont(size: 14))))
    heights.append((width, height))
    if heights.count > 4 { heights.removeFirst() }
    return height
  }
}
