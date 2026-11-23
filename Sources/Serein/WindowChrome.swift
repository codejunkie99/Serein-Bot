import AppKit
import SereinCore
import SwiftUI

/// Window chrome measurements: the sidebar sits on the window background, the content is one
/// inset rounded card, and the traffic lights live inside the sidebar's header card.
extension UIStyle {
  /// Gap between the window edge, the sidebar contents, the content card and the task panel.
  static let chromeInset: CGFloat = 8
  /// One compact sidebar, with no separate rail. Settings keeps its own 256-point category column.
  /// Grows with the text size (Settings › Appearance) so sidebar labels keep their room, and by
  /// what the person dragged its edge (`sidebarExtraKey`); dragged narrower than the list goes,
  /// it is the rail of faces (`sidebarRailKey`, `SidebarWidth`).
  static var wallWidth: CGFloat { sidebarRail ? SidebarWidth.rail : sidebarUsual + sidebarExtra }
  static var sidebarUsual: CGFloat { (244 * textScale).rounded() }
  static let sidebarExtraKey = "serein.sidebarExtraWidth"
  static let sidebarRailKey = "serein.sidebarRail"
  /// A new install opens the sidebar as the rail; a drag of its edge saves the person's choice.
  static let sidebarRailDefault = true
  static let sidebarExtraMax: CGFloat = SidebarWidth.extra.upperBound
  static var sidebarExtra: CGFloat {
    SidebarWidth.clamped(CGFloat(UserDefaults.standard.double(forKey: sidebarExtraKey)))
  }
  static var sidebarRail: Bool { UserDefaults.standard.object(forKey: sidebarRailKey) as? Bool ?? sidebarRailDefault }
  /// Content card and task panel radius (measured on the reference: about 10).
  static let contentRadius: CGFloat = 10
  /// Sidebar header card (the daily drawing behind the traffic lights): 216 × 124 at 8, 8.
  static let headerCardHeight: CGFloat = 124
  static let headerCardRadius: CGFloat = 10
  /// Close button's top-left corner from the header card's top-left corner (centres at 30, 29).
  static let trafficLightInsetX: CGFloat = 15
  static let trafficLightInsetY: CGFloat = 14
  /// Room the three window buttons take inside the content card when the sidebar is hidden:
  /// from the card edge to just past the zoom button, plus a gap before the next control.
  static let trafficLightGutter: CGFloat = trafficLightInsetX + 14 + 2 * 20 + 10
  /// Sidebar rows, from the reference: 30-point Serein, New tab and tabs, 32-point bottom
  /// buttons, 12-point side inset for rows.
  static let sidebarRowHeight: CGFloat = 30
  static let sidebarRowInset: CGFloat = 12
  /// Docked task panel width at the default window size.
  static let taskPanelWidth: CGFloat = 380
}

/// Back, Forward and Reload: 28-point square targets with a soft wash on hover.
struct ToolbarIconButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ToolbarIconBody(configuration: configuration)
  }
  private struct ToolbarIconBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.palette) var p
    @Environment(\.isEnabled) var enabled
    var body: some View {
      configuration.label.foregroundStyle(enabled ? p.ink : p.faint)
        .frame(width: 28, height: 28)
        .background(configuration.isPressed ? p.selected : hovered && enabled ? p.hover : .clear,
          in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .contentShape(Rectangle()).onHover { hovered = $0 }
    }
  }
}

/// Places the standard window buttons inside the sidebar header card (or, with the sidebar
/// hidden, at the leading end of the content card's toolbar; both share the same spot).
/// AppKit lays the titlebar out again on resize, key changes and full screen, so every one of
/// those re-applies the position. In full screen AppKit owns the buttons and they are left alone.
@MainActor final class WindowChrome: NSObject, ObservableObject {
  static let shared = WindowChrome()
  @Published private(set) var fullScreen = false
  /// The sidebar header card's frame from the window's top-left, for preview logs.
  var headerCardFrame: CGRect = .zero
  /// The sidebar shows as its rail: the three buttons centre on its one column, as its tiles do,
  /// and move there with the shell's own curve (at once under Reduce Motion and in previews).
  var onRail = false {
    didSet {
      guard onRail != oldValue else { return }
      let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || RunMode.previewing
      NSAnimationContext.runAnimationGroup { context in
        context.duration = still ? 0 : 0.25
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layout(animated: !still)
      }
    }
  }
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []
  /// Top-left of the close button from the window's top-left corner.
  static var buttonOrigin: CGPoint {
    CGPoint(x: UIStyle.chromeInset + UIStyle.trafficLightInsetX,
      y: UIStyle.chromeInset + UIStyle.trafficLightInsetY)
  }
  /// Centre-to-centre spacing of the standard buttons.
  static let spacing: CGFloat = 20
  /// Titlebar height: it spans the header row so the buttons stay inside its bounds.
  static var titlebarHeight: CGFloat { UIStyle.chromeInset + UIStyle.headerHeight }

  func attach(_ window: NSWindow) {
    self.window = window
    fullScreen = window.styleMask.contains(.fullScreen)
    let names: [Notification.Name] = [
      NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
      NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
      NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
      NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didDeminiaturizeNotification,
    ]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: window, queue: .main
      ) { [weak self] note in
        let name = note.name
        MainActor.assumeIsolated { self?.handle(name) }
      })
    }
    layout()
  }

  private func handle(_ name: Notification.Name) {
    switch name {
    case NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification:
      fullScreen = true
      return
    case NSWindow.willExitFullScreenNotification:
      return
    case NSWindow.didExitFullScreenNotification:
      fullScreen = false
    default: break
    }
    layout()
    // AppKit may finish its own titlebar pass after the notification; settle on the next turn.
    DispatchQueue.main.async { [weak self] in self?.layout() }
  }

  /// Standard button frames from the window's top-left corner, for preview logs.
  func buttonFrames() -> [String: [Int]] {
    guard let window else { return [:] }
    var out: [String: [Int]] = [:]
    let names: [(String, NSWindow.ButtonType)] = [("close", .closeButton), ("minimize", .miniaturizeButton), ("zoom", .zoomButton)]
    for (name, type) in names {
      guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
      let inWindow = superview.convert(button.frame, to: nil)
      out[name] = [Int(inWindow.minX.rounded()), Int((window.frame.height - inWindow.maxY).rounded()),
        Int(inWindow.width.rounded()), Int(inWindow.height.rounded())]
    }
    return out
  }

  func layout(animated: Bool = false) {
    guard let window, !window.styleMask.contains(.fullScreen),
      let close = window.standardWindowButton(.closeButton),
      let titlebar = close.superview, let container = titlebar.superview
    else { return }
    let height = Self.titlebarHeight
    let frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
    if container.frame != frame { container.frame = frame }
    if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let firstX = onRail ? Self.railButtonX(buttonWidth: close.frame.width) : Self.buttonOrigin.x
    for (index, type) in buttons.enumerated() {
      guard let button = window.standardWindowButton(type) else { continue }
      let origin = NSPoint(
        x: firstX + CGFloat(index) * Self.spacing,
        y: titlebar.isFlipped
          ? Self.buttonOrigin.y
          : titlebar.bounds.height - Self.buttonOrigin.y - button.frame.height)
      guard button.frame.origin != origin else { continue }
      if animated { button.animator().setFrameOrigin(origin) } else { button.setFrameOrigin(origin) }
    }
  }
  /// The close button's left edge that centres the three buttons on the rail, whose tiles centre
  /// on the same line (the rail starts at the window's edge).
  static func railButtonX(buttonWidth: CGFloat) -> CGFloat {
    ((SidebarWidth.rail - 2 * spacing - buttonWidth) / 2).rounded()
  }
}
