import AppKit
import Combine
import SereinCore
import SwiftUI

/// The glow around the screen's edge, over every app, while Serein works in a Mac app or a page.
/// `ScreenSignal` decides when; this draws it on the screen in use. No window here takes the
/// keyboard or a click.
@MainActor final class ScreenSignals {
  static let shared = ScreenSignals()
  /// Settings › Serein's look. On unless turned off.
  static let key = "serein.relay.screenSignals"
  static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

  private weak var controller: RelayController?
  private var watch: AnyCancellable?
  /// The runs at work, each watched for its next step: a command or an edit is no board change.
  private var runWatch: AnyCancellable?
  private var watched: [ObjectIdentifier] = []
  private let runChanged = PassthroughSubject<Void, Never>()
  /// One strip for each edge, not one window over the screen: the middle stays free of any
  /// window of Serein's, so nothing that asks what is under a point finds Serein there.
  private var edges: [NSPanel] = []
  private var drawn = Drawn()

  /// What is on screen now.
  private struct Drawn: Equatable {
    var shown = ScreenSignal.Shown()
    var tint: UInt32 = 0
    var screen = NSRect.zero
    /// Reduce Transparency, Reduce Motion.
    var plain = false
    var still = false
  }

  /// Follows Serein from now on. Checks and previews show nothing (`preview` aside).
  func install(controller: RelayController) {
    guard watch == nil, !RunMode.automated else { return }
    self.controller = controller
    let relay = controller.relay
    let center = NotificationCenter.default
    let workspace = NSWorkspace.shared.notificationCenter
    func signal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
      publisher.map { _ in () }.eraseToAnyPublisher()
    }
    watch = Publishers.MergeMany([
      signal(relay.objectWillChange), signal(controller.objectWillChange), signal(controller.dictation.$recording),
      signal(relay.browser.agentTabs.$runs), signal(relay.agent.hub.$runs), signal(relay.agent.hub.$now),
      signal(runChanged),
      signal(center.publisher(for: UserDefaults.didChangeNotification)),
      signal(center.publisher(for: NSApplication.didChangeScreenParametersNotification)),
      signal(workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)),
      signal(workspace.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)),
    ])
    // Serein's reply publishes a change for every few words; the glow needs none of them sooner.
    .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
    .sink { [weak self] in self?.refresh() }
  }

  private func refresh() {
    guard let controller else { return }
    let runs = Self.activeRuns(controller.relay)
    if runs.map(ObjectIdentifier.init) != watched {
      watched = runs.map(ObjectIdentifier.init)
      runWatch = Publishers.MergeMany(runs.map(\.objectWillChange)).sink { [runChanged] in runChanged.send() }
    }
    let live = Self.current(controller)
    draw(Self.on ? live.shown : ScreenSignal.Shown(), tint: live.tint)
  }

  /// What Serein's state asks for now, and the hologram's colour in that state.
  static func current(_ controller: RelayController) -> (shown: ScreenSignal.Shown, tint: UInt32) {
    let relay = controller.relay
    let state = RelayPanelView.avatarState(
      relay: relay, listening: controller.dictation.recording || controller.wakeWords != nil, speaking: controller.speaking)
    let work = activeRuns(relay).map { run in
      // The consent card holds every run's Mac step, not only Serein's own.
      let waiting = relay.consentWaiting || relay.approvals.contains { $0.threadID == run.spec.threadID }
        || (run === relay.run && !relay.questionForms.isEmpty)
      return Self.work(run, board: run.boardInfo(relay.browser), waiting: waiting)
    }
    return (ScreenSignal.resolve(state: state, work: work), tint(relay.look, state))
  }

  /// One run as the rule reads it. `waiting`: the run cannot act until the person answers.
  static func work(_ run: AgentRun, board: AgentTabBoard.RunInfo?, waiting: Bool) -> ScreenSignal.Work {
    // A warm chat keeps its board from turn to turn: a step from before this turn is not this run's.
    let step = board?.ended == true ? nil : board?.steps.last { $0.time >= run.record.startedAt }
    let other = run.steps.last?.time
    return ScreenSignal.Work(
      controls: ScreenSignal.holdsControls(
        tool: step?.tool, at: step?.time, failed: step?.failed != nil, waiting: waiting, otherAt: other))
  }

  private static func activeRuns(_ relay: RelayOrchestrator) -> [AgentRun] {
    ([relay.run].compactMap { $0 } + relay.childRuns).filter(\.isActive)
  }

  /// The hologram's colour in this state, so the glow matches it.
  private static func tint(_ look: RelayLook, _ state: RelayLook.State) -> UInt32 {
    UInt32((look.states[state.rawValue]?.primary ?? look.palette.primary).dropFirst(), radix: 16) ?? 0x4C7DFF
  }

  private func draw(_ shown: ScreenSignal.Shown, tint: UInt32, on screen: NSScreen? = nil) {
    guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
    let workspace = NSWorkspace.shared
    let reduced = CommandLine.arguments.contains("--ui-reduced-effects")
    let next = Drawn(
      shown: shown, tint: tint, screen: screen.frame,
      plain: reduced || workspace.accessibilityDisplayShouldReduceTransparency,
      still: reduced || workspace.accessibilityDisplayShouldReduceMotion)
    guard next != drawn else { return }
    drawn = next
    drawGlow(next)
  }

  // MARK: the glow

  private enum Edge: CaseIterable {
    case top, bottom, left, right

    func frame(in screen: NSRect, depth: CGFloat) -> NSRect {
      switch self {
      case .top: return NSRect(x: screen.minX, y: screen.maxY - depth, width: screen.width, height: depth)
      case .bottom: return NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: depth)
      case .left: return NSRect(x: screen.minX, y: screen.minY, width: depth, height: screen.height)
      case .right: return NSRect(x: screen.maxX - depth, y: screen.minY, width: depth, height: screen.height)
      }
    }
    /// From the screen's edge inward, in a layer's unit square.
    var inward: (from: CGPoint, to: CGPoint) {
      switch self {
      case .top: return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
      case .bottom: return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
      case .left: return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
      case .right: return (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
      }
    }
  }

  private func drawGlow(_ next: Drawn) {
    guard next.shown.glow else { return edges.forEach { fade($0, to: 0) } }
    if edges.isEmpty { edges = Edge.allCases.map { _ in Self.panel() } }
    let color = NSColor(hex: next.tint)
    for (edge, window) in zip(Edge.allCases, edges) {
      // Reduce Transparency: a plain line. Otherwise light that fades into the screen.
      window.setFrame(edge.frame(in: next.screen, depth: next.plain ? 4 : 30), display: true)
      let light = CAGradientLayer()
      light.colors = next.plain
        ? [color.cgColor, color.cgColor]
        : [color.withAlphaComponent(0.9).cgColor, color.withAlphaComponent(0.3).cgColor, color.withAlphaComponent(0).cgColor]
      if !next.plain { light.locations = [0, 0.3, 1] }
      (light.startPoint, light.endPoint) = edge.inward
      if !next.still {
        // Core Animation runs the pulse: the app does no work for a frame of it.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.5
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        light.add(pulse, forKey: "pulse")
      }
      let view = NSView()
      view.layer = light
      view.wantsLayer = true
      window.contentView = view
      fade(window, to: 1)
    }
  }

  // MARK: windows

  private static func panel() -> NSPanel {
    let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    // Over the menu bar and full-screen apps.
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.hidesOnDeactivate = false
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    return window
  }

  private func fade(_ window: NSPanel?, to alpha: CGFloat) {
    guard let window else { return }
    if alpha > 0, !window.isVisible {
      window.alphaValue = 0
      window.orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      window.animator().alphaValue = alpha
    } completionHandler: {
      // A window asked back while it faded out stays.
      if window.alphaValue == 0 { window.orderOut(nil) }
    }
  }

  // MARK: preview

  /// `--ui-preview serein --ui-screen-signals`: the glow as it looks over other apps, through a
  /// fixed round of states on each display in turn until the preview quits. Each step prints
  /// whether it glows and its windows' numbers.
  func preview() {
    guard CommandLine.arguments.contains("--ui-screen-signals") else { return }
    let atControls = [ScreenSignal.Work(controls: true)]
    let round: [(RelayLook.State, [ScreenSignal.Work], seconds: Double)] = [
      (.thinking, [], 2), (.working, atControls, 3), (.alert, atControls, 3),
      (.working, [ScreenSignal.Work(controls: false)], 3), (.idle, [], 2),
    ]
    Task { @MainActor in
      while true {
        for screen in NSScreen.screens {
          for (state, work, seconds) in round {
            let shown = ScreenSignal.resolve(state: state, work: work)
            draw(shown, tint: Self.tint(RelayLook.serein, state), on: screen)
            let step: [String: Any] = [
              "event": "serein-screen-signals", "glow": shown.glow,
              "glowWindows": edges.map(\.windowNumber),
            ]
            if var line = try? JSONSerialization.data(withJSONObject: step, options: .sortedKeys) {
              line.append(10)
              FileHandle.standardOutput.write(line)
            }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
          }
        }
      }
    }
  }
}
