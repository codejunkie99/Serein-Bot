#if DEBUG
import AppKit
import SwiftUI
import SereinCore

/// Exercise the real message container's native tracking callbacks and rendered
/// controls, without changing the desktop pointer or the user's clipboard.
@MainActor func checkMessageHoverControls() async throws {
  let previousKeyWindow = NSApp.keyWindow
  defer { previousKeyWindow?.makeKey() }
  for palette in [Palette.light, .dusk] {
    for isLatest in [false, true] {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
        styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
      let host = NSHostingView(rootView: MessageHoverControls(alwaysVisible: isLatest) { visible in
        VStack(alignment: .leading, spacing: 6) {
          MessageContent(text: "Synthetic reply.\n\n```swift\nlet value = true\n```", showsCopyButton: visible)
          MessageCopyButton(text: "Synthetic reply", isVisible: visible)
        }.frame(width: 320, height: 180, alignment: .topLeading)
      }.environment(\.palette, palette).environment(\.sereinReducedEffects, true)
        .background(palette.background))
      window.contentView = host
      window.makeKeyAndOrderFront(nil)
      defer { window.close() }
      func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
      }
      try await settle()
      func trackingView(in view: NSView) -> NSView? {
        view.updateTrackingAreas()
        if view.trackingAreas.contains(where: {
          $0.options.isSuperset(of: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag])
            && ($0.owner as? NSView) === view
        }) { return view }
        return view.subviews.lazy.compactMap { trackingView(in: $0) }.first
      }
      guard let tracking = trackingView(in: host),
        tracking.hitTest(NSPoint(x: tracking.bounds.midX, y: tracking.bounds.midY)) == nil else {
        throw SereinError.invalid("Message hover: passive native tracking area is missing")
      }
      func hover(_ entered: Bool) throws {
        let point = entered ? NSPoint(x: tracking.bounds.midX, y: tracking.bounds.midY) : NSPoint(x: -10, y: -10)
        guard let event = NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited,
          location: tracking.convert(point, to: nil), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
          throw SereinError.invalid("Message hover: native event creation failed")
        }
        if entered { tracking.mouseEntered(with: event) } else { tracking.mouseExited(with: event) }
      }
      func pixels(_ state: String) throws -> Data {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
          throw SereinError.invalid("Message hover: rendered bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["SEREIN_MESSAGE_HOVER_CAPTURES"] {
          let url = URL(fileURLWithPath: directory, isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(
            "\(palette.isDark ? "dark" : "light")-\(isLatest ? "latest" : "older")-\(state).png"))
        }
        guard let data = bitmap.bitmapData else { throw SereinError.invalid("Message hover: pixels unavailable") }
        return Data(bytes: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
      }
      try hover(false)
      try await settle()
      let frame = host.bounds
      let idle = try pixels("idle")
      try hover(true)
      try await settle()
      let active = try pixels("hover")
      guard host.bounds == frame, isLatest ? idle == active : idle != active else {
        throw SereinError.invalid("Message hover: \(isLatest ? "latest controls changed" : "older controls did not reveal") in \(palette.rawValue)")
      }
      try hover(false)
      try await settle()
      guard host.bounds == frame, try pixels("leave") == idle else {
        throw SereinError.invalid("Message hover: controls or layout did not return to idle in \(palette.rawValue)")
      }
    }
    print("PASS: older message Copy controls reveal on hover; latest controls remain visible in \(palette.rawValue)")
  }
  try await checkReplyAccessoryInsideRow()
}

/// A long reply's Reply and ⋯ hang past its bubble. They must end inside the row, or the pointer
/// leaves the message's hover area on its way to them and they hide before the click.
@MainActor private func checkReplyAccessoryInsideRow() async throws {
  final class Box { var frame: CGRect = .zero }
  let box = Box()
  let width: CGFloat = 520
  let long = String(repeating: "A reply long enough to take the whole reply width. ", count: 6)
  let row = SereinReplyBubble(text: long) { Text(long) } accessory: {
    Color.clear.frame(width: 110, height: 24)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("row")) } action: { box.frame = $0 }
  }
  .frame(width: width).coordinateSpace(name: "row")
  .environment(\.palette, .light).environment(\.sereinReducedEffects, true)
  let host = NSHostingView(rootView: row)
  host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
  for _ in 0..<3 {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(60))
  }
  guard box.frame.width > 0, box.frame.maxX <= width else {
    throw SereinError.invalid("Message hover: a long reply's controls end at \(box.frame.maxX), past the \(width)-point row")
  }
  print("PASS: a long reply's Reply and ⋯ stay inside its row")
}
#endif
