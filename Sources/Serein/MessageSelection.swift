import AppKit
import SwiftUI

private struct MessageSelectionKey: EnvironmentKey {
  static let defaultValue: MessageSelection? = nil
}

private struct MessageSelectionPrefixKey: EnvironmentKey {
  static let defaultValue: [Int] = []
}

extension EnvironmentValues {
  var messageSelection: MessageSelection? {
    get { self[MessageSelectionKey.self] }
    set { self[MessageSelectionKey.self] = newValue }
  }
  /// Where a message sits in a transcript's one selection (`RelayMessages`): its text views order
  /// after this prefix, so a drag runs from one message into the next as it reads.
  var messageSelectionPrefix: [Int] {
    get { self[MessageSelectionPrefixKey.self] }
    set { self[MessageSelectionPrefixKey.self] = newValue }
  }
}

/// One selection for an entire rendered reply, including its separate Markdown text views.
/// The views keep their native styling and accessibility; ordering follows the document,
/// rather than the frames of table cells or horizontally scrolled code.
@MainActor final class MessageSelection {
  private final class Entry {
    weak var view: MessageTextView?
    init(_ view: MessageTextView) { self.view = view }
  }
  private struct Block {
    let view: MessageTextView
    let range: NSRange
  }
  private var entries: [Entry] = []
  private var anchor: Int?
  private var extent = 0
  private var updatingSelection = false
  /// While something is selected: a click anywhere else in the window clears it, as in any
  /// Mac text view.
  private var outsideClick: Any?

  func register(_ view: MessageTextView, order: [Int], separator: String) {
    if view.messageSelection === self, view.selectionOrder == order,
      view.selectionSeparator == separator { return }
    if view.messageSelection !== self { view.messageSelection?.unregister(view) }
    entries.removeAll { $0.view == nil }
    if !entries.contains(where: { $0.view === view }) { entries.append(Entry(view)) }
    view.messageSelection = self
    view.selectionOrder = order
    view.selectionSeparator = separator
  }

  func unregister(_ view: MessageTextView) {
    entries.removeAll { $0.view == nil || $0.view === view }
    if view.messageSelection === self { view.messageSelection = nil }
  }

  func isActive(in window: NSWindow?) -> Bool {
    guard NSApplication.shared.isActive, let window, window.isKeyWindow,
      let focused = window.firstResponder as? MessageTextView else { return false }
    return focused.messageSelection === self
  }

  /// Redraws the blocks whose highlight follows whether the selection is active: those with
  /// something selected. The others draw nothing that changes, and a long chat has many.
  func invalidateDisplay() {
    for entry in entries {
      guard let view = entry.view, view.selectedRange().length > 0 else { continue }
      view.needsDisplay = true
    }
  }

  private func document() -> (text: String, blocks: [Block]) {
    let views = entries.compactMap(\.view).sorted {
      $0.selectionOrder.lexicographicallyPrecedes($1.selectionOrder)
    }
    var text = ""
    var blocks: [Block] = []
    for view in views {
      if !blocks.isEmpty { text += view.selectionSeparator }
      let start = (text as NSString).length
      text += view.string
      blocks.append(Block(view: view, range: NSRange(location: start, length: (view.string as NSString).length)))
    }
    return (text, blocks)
  }

  func select(from start: Int, to end: Int) {
    updatingSelection = true
    defer {
      updatingSelection = false
      watchOutsideClicks(selectedRange.length > 0)
    }
    let document = document()
    let length = (document.text as NSString).length
    anchor = min(max(0, start), length)
    extent = min(max(0, end), length)
    let selected = selectedRange
    for block in document.blocks {
      let overlap = NSIntersectionRange(selected, block.range)
      let location = overlap.length > 0 ? overlap.location - block.range.location
        : min(max(0, extent - block.range.location), block.range.length)
      block.view.setSelectedRange(NSRange(location: location, length: overlap.length))
      block.view.needsDisplay = true
    }
  }

  /// Nothing selected, in every view of this selection.
  func clear() {
    updatingSelection = true
    defer { updatingSelection = false }
    anchor = nil
    extent = 0
    for entry in entries {
      guard let view = entry.view else { continue }
      view.setSelectedRange(NSRange(location: 0, length: 0))
      view.needsDisplay = true
    }
    watchOutsideClicks(false)
  }

  private func watchOutsideClicks(_ on: Bool) {
    if !on {
      if let outsideClick { NSEvent.removeMonitor(outsideClick) }
      outsideClick = nil
      return
    }
    guard outsideClick == nil else { return }
    outsideClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        let inside = self.entries.contains { entry in
          guard let view = entry.view, view.window === event.window, !view.isHidden else { return false }
          return view.convert(view.bounds, to: nil).contains(event.locationInWindow)
        }
        // A right-click on the selection keeps it for Copy; anywhere else it goes.
        if !inside { self.clear() }
      }
      return event
    }
  }

  var selectedRange: NSRange {
    let start = anchor ?? extent
    return NSRange(location: min(start, extent), length: abs(extent - start))
  }

  var selectedText: String {
    let text = document().text as NSString
    let range = selectedRange
    let start = min(range.location, text.length)
    return text.substring(with: NSRange(location: start, length: min(range.length, text.length - start)))
  }

  func selectAll() { select(from: 0, to: (document().text as NSString).length) }

  @discardableResult func copy(to pasteboard: NSPasteboard) -> Bool {
    let text = selectedText
    guard !text.isEmpty else { return false }
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }

  private func offset(of view: MessageTextView) -> Int {
    document().blocks.first(where: { $0.view === view })?.range.location ?? 0
  }

  func begin(in view: MessageTextView, at point: NSPoint, extending: Bool,
    granularity: NSSelectionGranularity) -> NSRange {
    let local = view.convert(point, from: nil)
    let index = min(view.characterIndexForInsertion(at: local), (view.string as NSString).length)
    let range = view.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: granularity)
    let base = offset(of: view)
    let initial = NSRange(location: base + range.location, length: range.length)
    if extending, let anchor { select(from: anchor, to: initial.location + initial.length) }
    else { select(from: initial.location, to: NSMaxRange(initial)) }
    return initial
  }

  func extend(at point: NSPoint, initial: NSRange, granularity: NSSelectionGranularity) {
    let blocks = document().blocks.filter { $0.view.window != nil && !$0.view.isHidden }
    guard let nearest = blocks.min(by: { distance(point, to: $0.view) < distance(point, to: $1.view) }) else { return }
    let view = nearest.view
    let index = min(view.characterIndexForInsertion(at: view.convert(point, from: nil)), nearest.range.length)
    let range = view.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: granularity)
    let end = nearest.range.location + range.location
    if granularity == .selectByCharacter {
      select(from: anchor ?? initial.location, to: end)
    } else if end < initial.location {
      select(from: NSMaxRange(initial), to: end)
    } else {
      select(from: initial.location, to: end + range.length)
    }
  }

  private func distance(_ point: NSPoint, to view: NSView) -> CGFloat {
    let rect = view.convert(view.bounds, to: nil)
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return dx * dx + dy * dy
  }

  func extendToDocumentEdge(from view: MessageTextView, end: Bool) {
    let start = anchor ?? (offset(of: view) + view.selectedRange().location)
    select(from: start, to: end ? (document().text as NSString).length : 0)
  }

  func nativeSelectionDidChange(in view: MessageTextView) {
    guard !updatingSelection && !view.suppressMessageSelectionUpdates else { return }
    let base = offset(of: view)
    let range = view.selectedRange()
    select(from: base + range.location, to: base + NSMaxRange(range))
  }

  func move(from view: MessageTextView, forward: Bool, extending: Bool) {
    let text = document().text as NSString
    if anchor == nil {
      let range = view.selectedRange()
      anchor = offset(of: view) + range.location
      extent = (anchor ?? 0) + range.length
    }
    let range = selectedRange
    let next: Int
    if !extending && range.length > 0 { next = forward ? NSMaxRange(range) : range.location }
    else if forward {
      next = extent < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: extent)) : text.length
    } else {
      next = extent > 0 ? text.rangeOfComposedCharacterSequence(at: extent - 1).location : 0
    }
    select(from: extending ? (anchor ?? next) : next, to: next)
  }

  /// Continue dragging when the pointer reaches the transcript's visible edge. Code's
  /// horizontal scroller is skipped; it must not trap selection inside that code panel.
  func autoscroll(from view: NSView, event: NSEvent) {
    var parent = view.superview
    while let ancestor = parent {
      if let scroll = ancestor as? NSScrollView, let document = scroll.documentView,
        document.bounds.height > scroll.contentView.bounds.height {
        let clip = scroll.contentView
        let point = document.convert(event.locationInWindow, from: nil)
        let visible = clip.bounds
        let delta: CGFloat = point.y < visible.minY ? -18 : point.y > visible.maxY ? 18 : 0
        if delta != 0 {
          let y = min(max(0, visible.minY + delta), max(0, document.bounds.height - visible.height))
          clip.scroll(to: NSPoint(x: visible.minX, y: y))
          scroll.reflectScrolledClipView(clip)
        }
        return
      }
      parent = ancestor.superview
    }
  }
}

final class MessageTextView: NSTextView {
  weak var messageSelection: MessageSelection?
  var selectionOrder: [Int] = []
  var selectionSeparator = "\n\n"
  var suppressMessageSelectionUpdates = false
  private var windowObservers: [NSObjectProtocol] = []

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    messageSelection?.invalidateDisplay()
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    messageSelection?.invalidateDisplay()
    return accepted
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    windowObservers.removeAll()
    if let window {
      let changes: [(Notification.Name, Any)] = [
        (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
        (NSApplication.didBecomeActiveNotification, NSApplication.shared),
        (NSApplication.didResignActiveNotification, NSApplication.shared),
      ]
      // Each block redraws its own highlight: one block telling every block in a long chat's
      // selection, for each of them, would redraw the chat once per block.
      for (name, object) in changes {
        windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: object,
          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redrawHighlight() }
          })
      }
    }
    // Joining the window changes no other block's highlight.
    redrawHighlight()
  }

  private func redrawHighlight() {
    if selectedRange().length > 0 { needsDisplay = true }
  }

  deinit {
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
  }

  override func selectAll(_ sender: Any?) {
    guard let messageSelection else { super.selectAll(sender); return }
    messageSelection.selectAll()
  }

  override func copy(_ sender: Any?) {
    guard let messageSelection else { super.copy(sender); return }
    messageSelection.copy(to: .general)
  }

  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    if let messageSelection,
      types.contains(.string) || types.contains(NSPasteboard.PasteboardType("NSStringPboardType")) {
      return messageSelection.copy(to: pboard)
    }
    return super.writeSelection(to: pboard, types: types)
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)), let messageSelection {
      return messageSelection.selectedRange.length > 0
    }
    return super.validateUserInterfaceItem(item)
  }

  override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
    guard let messageSelection else { super.moveToBeginningOfDocumentAndModifySelection(sender); return }
    messageSelection.extendToDocumentEdge(from: self, end: false)
  }

  override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
    guard let messageSelection else { super.moveToEndOfDocumentAndModifySelection(sender); return }
    messageSelection.extendToDocumentEdge(from: self, end: true)
  }

  override func moveLeft(_ sender: Any?) {
    guard let messageSelection else { super.moveLeft(sender); return }
    messageSelection.move(from: self, forward: false, extending: false)
  }

  override func moveRight(_ sender: Any?) {
    guard let messageSelection else { super.moveRight(sender); return }
    messageSelection.move(from: self, forward: true, extending: false)
  }

  override func moveLeftAndModifySelection(_ sender: Any?) {
    guard let messageSelection else { super.moveLeftAndModifySelection(sender); return }
    messageSelection.move(from: self, forward: false, extending: true)
  }

  override func moveRightAndModifySelection(_ sender: Any?) {
    guard let messageSelection else { super.moveRightAndModifySelection(sender); return }
    messageSelection.move(from: self, forward: true, extending: true)
  }

  override func moveBackward(_ sender: Any?) {
    guard let messageSelection else { super.moveBackward(sender); return }
    messageSelection.move(from: self, forward: false, extending: false)
  }
  override func moveForward(_ sender: Any?) {
    guard let messageSelection else { super.moveForward(sender); return }
    messageSelection.move(from: self, forward: true, extending: false)
  }
  override func moveBackwardAndModifySelection(_ sender: Any?) {
    guard let messageSelection else { super.moveBackwardAndModifySelection(sender); return }
    messageSelection.move(from: self, forward: false, extending: true)
  }
  override func moveForwardAndModifySelection(_ sender: Any?) {
    guard let messageSelection else { super.moveForwardAndModifySelection(sender); return }
    messageSelection.move(from: self, forward: true, extending: true)
  }

  override func mouseDown(with event: NSEvent) {
    guard let messageSelection, let window else { super.mouseDown(with: event); return }
    window.makeFirstResponder(self)
    let granularity: NSSelectionGranularity = event.clickCount >= 3 ? .selectByParagraph
      : event.clickCount == 2 ? .selectByWord : .selectByCharacter
    let initial = messageSelection.begin(in: self, at: event.locationInWindow,
      extending: event.modifierFlags.contains(.shift), granularity: granularity)
    var dragged = false
    var lastDrag: NSEvent?
    NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.03)
    defer { NSEvent.stopPeriodicEvents() }
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
      until: .distantFuture, inMode: .eventTracking, dequeue: true) {
      if next.type == .leftMouseUp { break }
      if next.type == .leftMouseDragged { dragged = true; lastDrag = next }
      if let lastDrag {
        messageSelection.autoscroll(from: self, event: lastDrag)
        messageSelection.extend(at: lastDrag.locationInWindow, initial: initial, granularity: granularity)
      }
    }
    // A click still opens a Markdown link; a drag starting on that link selects text.
    if !dragged && event.clickCount == 1 && !event.modifierFlags.contains(.shift) {
      let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
      if index < (string as NSString).length, let link = textStorage?.attribute(.link, at: index, effectiveRange: nil) {
        _ = delegate?.textView?(self, clickedOnLink: link, at: index)
      }
    }
  }
}

/// AppKit emphasizes only the first-responder NSTextView. A reply has several native
/// text views, so paint their selected glyphs with the same system highlight while any
/// block in that reply has focus. Keep normal inactive selection when focus leaves it.
final class MessageLayoutManager: NSLayoutManager {
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    // TextKit's drawing override is not actor annotated; NSView display runs on main.
    MainActor.assumeIsolated {
      guard let container = textContainers.first, let view = container.textView as? MessageTextView,
        view.messageSelection?.isActive(in: view.window) == true,
        view.selectedRange().length > 0 else { return }
      let selectedGlyphs = glyphRange(forCharacterRange: view.selectedRange(), actualCharacterRange: nil)
      let visibleGlyphs = NSIntersectionRange(glyphsToShow, selectedGlyphs)
      guard visibleGlyphs.length > 0 else { return }
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSColor.selectedTextBackgroundColor.setFill()
      enumerateEnclosingRects(forGlyphRange: visibleGlyphs, withinSelectedGlyphRange: selectedGlyphs,
        in: container) { rect, _ in
          rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }
  }
}
