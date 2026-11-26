import AppKit
import Combine
import SereinCore
import SwiftUI

/// The voice pill on screen (VoicePill.swift has its rules): a tiny pill resting at the foot of the
/// screen the pointer is on, just above the Dock, over every app and Space, never taking the
/// keyboard. Holding the Ask Serein shortcut grows it, Serein's mark spinning inside, in place of the bar
/// (`RelayController.beginListen`); the words go through the bar's own send, which brings Serein's
/// chat forward (`RelayController.handOff`).
@MainActor final class VoicePillController: ObservableObject {
  /// Room for the grown capsule, the mark's glow as it swells, and the shadow.
  static let panelSize = NSSize(width: 160, height: 64)
  static let restSize = CGSize(width: 38, height: 8)
  static let grownSize = CGSize(width: 64, height: 36)
  /// The mark's orbits; with its glow it takes 1.6 times this (`SereinGlowMark`).
  static let markSize: CGFloat = 19
  /// Space under the capsule inside the panel, for its shadow.
  static let shadowRoom: CGFloat = 8
  @Published private(set) var pill = VoicePill()
  /// The tiny pill stays on screen between talks (the Ask Serein shortcut is on).
  @Published private(set) var resting = false
  /// A click on the resting pill starts a talk; a click on one the button started sends it.
  var onClick: () -> Void = {}
  /// The microphone or speech recognition could not start: Serein says why in the bar.
  var onMicFailed: () -> Void = {}
  private var panel: NSPanel?
  private var feed: [AnyCancellable] = []
  private var putAway: Task<Void, Never>?

  func rest(_ on: Bool) {
    resting = on
    if on { present() } else if !pill.shown { panel?.orderOut(nil) }
  }
  /// Grows the pill for a dictation about to start: the mark moves with its meter once it records.
  func begin(_ dictation: Dictation, latched: Bool) {
    pill.begin(latched: latched)
    feed = [
      dictation.$recording.filter { $0 }.sink { [weak self] _ in self?.pill.micOpened() },
      dictation.meter.$level.sink { [weak self] in self?.pill.hear($0) },
      // dropFirst: the error a past dictation left is not this one's.
      dictation.$error.dropFirst().compactMap { $0 }.sink { [weak self] _ in self?.onMicFailed() },
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
  /// Let go: the mark settles while the words are finished.
  func release() {
    feed = []
    pill.release()
    takeClicks()
  }
  /// The words are finished: the pill shrinks back and says what happens to them.
  func end(heard: String) -> VoicePill.Handoff {
    feed = []
    let handoff = pill.end(heard: heard)
    settle()
    return handoff
  }
  func cancel() {
    feed = []
    pill.cancel()
    settle()
  }
  fileprivate func clicked() { onClick() }

  /// Back to rest: the tiny pill stays, or the panel goes once the shrink has played.
  private func settle() {
    takeClicks()
    guard !resting else { return }
    putAway?.cancel()
    putAway = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard let self, !Task.isCancelled, !self.pill.shown, !self.resting else { return }
      self.panel?.orderOut(nil)
    }
  }
  /// A hold from the keyboard lets clicks through to the app below; the resting pill and the
  /// button's pill take them.
  private func takeClicks() {
    panel?.ignoresMouseEvents = pill.shown && !pill.latched
  }
  private func present() {
    putAway?.cancel()
    let panel = self.panel ?? makePanel()
    self.panel = panel
    takeClicks()
    let mouse = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: (frame.midX - Self.panelSize.width / 2).rounded(), y: frame.minY))
    }
    panel.orderFrontRegardless()
  }
  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The capsule draws its own shadow: a window's would stay the shape it had before a resize.
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.contentView = NSHostingView(rootView: VoicePillView(controller: self))
    return panel
  }
}

/// A black capsule like a dictation pill: tiny at rest; grown, Serein's mark inside, its orbits
/// spinning and swelling with the voice.
private struct VoicePillView: View {
  @ObservedObject var controller: VoicePillController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let pill = controller.pill
    let grown = pill.shown
    let size = grown ? VoicePillController.grownSize : VoicePillController.restSize
    Capsule(style: .continuous)
      .fill(Color.black.opacity(grown ? 0.94 : 0.72))
      .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(grown ? 0.14 : 0.4), lineWidth: 1))
      .overlay { if grown { mark(pill).transition(.scale(scale: 0.3).combined(with: .opacity)) } }
      .frame(width: size.width, height: size.height)
      .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
      .contentShape(Capsule())
      .onTapGesture { if !grown || pill.latched { controller.clicked() } }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Self.label(pill))
      .accessibilityAddTraits(!grown || pill.latched ? .isButton : [])
      .padding(.bottom, VoicePillController.shadowRoom)
      .frame(width: VoicePillController.panelSize.width, height: VoicePillController.panelSize.height, alignment: .bottom)
      .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: grown)
  }
  /// The mark's orbits turn by `pill.turn` and it swells by `pill.level`; with Reduce Motion it
  /// only brightens.
  private func mark(_ pill: VoicePill) -> some View {
    let swell = CGFloat(pill.level)
    return SereinGlowMark(size: VoicePillController.markSize, turn: reduceMotion ? nil : pill.turn)
      .scaleEffect(reduceMotion ? 1 : 1 + swell * 0.4)
      .brightness(Double(swell) * 0.2)
      .opacity(pill.phase == .listening ? 1 : 0.55)
      .animation(reduceMotion ? nil : .linear(duration: 0.06), value: pill.turn)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pill.level)
  }
  private static func label(_ pill: VoicePill) -> String {
    switch pill.phase {
    case .hidden: return "Talk to Serein"
    case .waiting: return "Serein, getting ready to listen"
    case .listening: return pill.latched ? "Serein is listening. Click to send." : "Serein is listening. Let go to send."
    case .sending: return "Serein, sending what you said"
    }
  }
}
