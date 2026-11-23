import AppKit
import SwiftUI

/// The message owns hover so its Copy controls stay reachable over native text,
/// code panels and the controls themselves, without changing the row's size.
///
/// The controls show beside the message under the pointer only, unless `alwaysVisible` (a
/// transcript's latest Copy). With Full Keyboard Access on they stay in the Tab order, and show
/// while one of them holds the keyboard.
struct MessageHoverControls<Content: View>: View {
  var alwaysVisible = false
  @ViewBuilder var content: (Bool) -> Content
  @State private var hovered = false
  @State private var focused = false
  var body: some View {
    content(alwaysVisible || hovered || focused)
      .background(MessageHoverArea(onHover: { hovered = $0 }))
      .onPreferenceChange(MessageControlsFocused.self) { focused = $0 }
  }
}

/// Whether one of a message's controls (`MessageActions`) holds the keyboard, or its ⋯ menu is open.
struct MessageControlsFocused: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct MessageHoverArea: NSViewRepresentable {
  var onHover: (Bool) -> Void
  func makeNSView(context: Context) -> MessageHoverView {
    let view = MessageHoverView()
    view.onHover = onHover
    return view
  }
  func updateNSView(_ view: MessageHoverView, context: Context) {
    view.onHover = onHover
  }
}

@MainActor private final class MessageHoverView: NSView {
  var onHover: ((Bool) -> Void)?
  private var hoverArea: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
}
