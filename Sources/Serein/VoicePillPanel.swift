import AppKit
import Combine
import SereinCore
import SwiftUI

/// The voice pill on screen (VoicePill.swift has its rules): a small panel at the foot of the
/// screen the pointer is on, over every app and Space, that never takes the keyboard. Holding the
/// Ask Serein shortcut shows it in place of the bar (`RelayController.beginListen`); the words go
/// through the bar's own send (`RelayController.handOff`).
@MainActor final class VoicePillController: ObservableObject {
  static let size = NSSize(width: 132, height: 62)
  /// Above the Dock and the screen's foot, where Wispr-style pills sit.
  static let lift: CGFloat = 28
  @Published private(set) var pill = VoicePill()
  /// A click on a pill the menu bar button started: it ends as a release would.
  var onClick: () -> Void = {}
  private var panel: NSPanel?
  private var feed: [AnyCancellable] = []

  /// Shows the pill for a dictation about to start: the wave follows its meter once it records.
  func begin(_ dictation: Dictation, latched: Bool) {
    pill.begin(latched: latched)
    feed = [
      dictation.$recording.filter { $0 }.sink { [weak self] _ in self?.pill.micOpened() },
      dictation.meter.$level.sink { [weak self] in self?.pill.hear($0) },
    ]
    present()
  }
  /// The preview's stand-in for a microphone: the same phases, readings it is handed.
  func beginPreview() {
    pill.begin(latched: true)
    feed = []
    present()
  }
  func micOpened() { pill.micOpened() }
  func hear(_ level: Float) { pill.hear(level) }
  /// Let go: the wave settles while the words are finished.
  func release() {
    feed = []
    pill.release()
  }
  /// The words are finished: the pill goes and says what happens to them.
  func end(heard: String, chatInFront: Bool) -> VoicePill.Handoff {
    feed = []
    let handoff = pill.end(heard: heard, chatInFront: chatInFront)
    panel?.orderOut(nil)
    return handoff
  }
  func cancel() {
    feed = []
    pill.cancel()
    panel?.orderOut(nil)
  }

  private func present() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    // A hold from the keyboard passes clicks through to the app below; the button's pill ends on a click.
    panel.ignoresMouseEvents = !pill.latched
    let mouse = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: (frame.midX - Self.size.width / 2).rounded(), y: frame.minY + Self.lift))
    }
    panel.orderFrontRegardless()
  }
  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.contentView = NSHostingView(rootView: VoicePillView(controller: self))
    return panel
  }
}

/// Serein's icon on top, the voice's wave along the bottom.
private struct VoicePillView: View {
  @ObservedObject var controller: VoicePillController
  @ObservedObject private var appearance = AppearanceController.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let p = appearance.palette
    let pill = controller.pill
    VStack(spacing: 7) {
      SereinAppIconImage(size: 22)
        .opacity(pill.phase == .sending && !reduceMotion ? 0.6 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(), value: pill.phase == .sending)
      HStack(alignment: .center, spacing: 2) {
        ForEach(Array(pill.levels.enumerated()), id: \.offset) { _, level in
          Capsule().fill(p.accent).frame(width: 2.5, height: 3 + CGFloat(level) * 16)
        }
      }
      .frame(height: 19)
      .opacity(pill.phase == .listening ? 1 : 0.45)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pill.levels)
    }
    .frame(width: VoicePillController.size.width, height: VoicePillController.size.height)
    .barGlass(in: Capsule(style: .continuous))
    .contentShape(Capsule())
    .onTapGesture { if pill.latched { controller.onClick() } }
    .environment(\.palette, p)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.label(pill))
    .accessibilityAddTraits(pill.latched ? .isButton : [])
  }
  private static func label(_ pill: VoicePill) -> String {
    switch pill.phase {
    case .hidden, .waiting: return "Serein, getting ready to listen"
    case .listening: return pill.latched ? "Serein is listening. Click to send." : "Serein is listening. Let go to send."
    case .sending: return "Serein, sending what you said"
    }
  }
}
