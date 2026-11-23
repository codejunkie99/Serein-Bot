import AppKit
import Combine
import SereinCore
import SwiftUI

/// An invisible, event-driven adapter between the main shell and its tip policy. The wrapper
/// stays empty when this window has no assistant (checks, private/auxiliary windows).
struct GuidanceContextView: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var setupShowing: Bool
  var body: some View {
    if let controller = SereinSurface.controller {
      GuidanceContextContent(browser: browser, agent: agent, controller: controller,
        relay: controller.relay, hub: agent.hub, setupShowing: setupShowing)
    }
  }
}

private struct GuidanceContextContent: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var controller: RelayController
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var hub: AgentHub
  var setupShowing: Bool
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var taskInput = GuidanceTaskInput.shared
  @ObservedObject private var placement = SereinSurface.main.placement
  @ObservedObject private var guide = GuideCenter.shared
  @ObservedObject private var menu = SereinMenuCenter.shared
  @ObservedObject private var dropdown = ComposerDropdown.shared
  @ObservedObject private var connect = SereinConnect.shared
  @ObservedObject private var edits = EditReview.shared
  @StateObject private var native = GuidanceWindowState()
  @State private var webPage = false
  @AppStorage(RelayController.columnKey) private var besideEnabled = true
  @AppStorage(RelayOrchestrator.enabledKey) private var barEnabled = false
  @AppStorage(SereinGuide.barUsedKey) private var barUsed = false
  // Observe settings changes made in another window, while the getters retain DEBUG overrides.
  @GateStorage(RelayOrchestrator.autopilotKey) private var approvalSetting = false
  @GateStorage(RelayOrchestrator.proactiveKey) private var checkInSetting = "off"

  private var hints: HintCenter { .shared }
  private var context: HintCenter.Context {
    _ = approvalSetting
    _ = checkInSetting
    var c = HintCenter.Context()
    c.isKeyWindow = native.state.isKey
    c.replying = relay.working
    c.approvalWaiting = !relay.approvals.isEmpty || relay.consentWaiting
      || hub.runs.contains { $0.record.outcome == .waiting }
      || edits.reviews.contains {
        !$0.approvals.isEmpty && $0.resolution == nil && edits.held.held(reviewID: $0.id) == nil
      }
    c.questionWaiting = !relay.questionForms.isEmpty || !relay.dueReminders.isEmpty || !relay.missedRuns.isEmpty
    c.composerHasText = taskInput.hasText || !surface.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || (browser.section == ShellSection.thread && !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      || (controller.panelShown && !controller.summonDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    c.sheetOpen = native.state.hasSheet || browser.showSettings || browser.showMarketplace || connect.flow != nil || connect.showOthers
    c.menuOpen = native.state.menuOpen || menu.presented != nil
    c.popoverOpen = native.state.popoverOpen || dropdown.open != nil || controller.panelShown
    c.setupShowing = setupShowing
    // Upgrade evidence is local chat history; disconnected held messages are not transcripts.
    c.hasMessages = relay.transcript.contains { $0.role == "you" }
      || relay.pastChats.contains { $0.messages.contains { $0.role == "you" } }
    c.besideEnabled = besideEnabled
    c.isSereinFull = browser.section == ShellSection.serein && placement.place == .full
    c.isOnTab = browser.section == ShellSection.browser || browser.section == ShellSection.thread
    c.sereinVisible = placement.place.shows && placement.view == .chat
    c.isBesideWebPage = browser.section == ShellSection.browser && placement.place == .beside && webPage
    c.guideBesideVisible = guide.itemVisible(.beside)
    c.optionSpaceEnabled = barEnabled
    c.barUsed = barUsed
    c.everyStep = relay.level == .everyStep
    c.checkInsOff = relay.proactiveLevel == .off
    return c
  }
  /// Observe only whether the selected address is a webpage, never any page content.
  private var pagePublisher: AnyPublisher<Bool, Never> {
    guard let tab = browser.active else { return Just(false).eraseToAnyPublisher() }
    return tab.$address.map { address in
      guard let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
      return scheme == "http" || scheme == "https"
    }.removeDuplicates().eraseToAnyPublisher()
  }
  var body: some View {
    GuidanceWindowProbe(observer: native)
      .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
      .onReceive(pagePublisher) { webPage = $0 }
      .onChange(of: context, initial: true) { _, value in hints.update(context: value) }
      // Nonempty drafts already block tips. These events also restart the quiet period after
      // each keystroke, including edits that leave the draft empty.
      .onChange(of: surface.draft) { _, _ in hints.recordInteraction() }
      .onChange(of: agent.draft) { _, _ in
        if browser.section == ShellSection.thread { hints.recordInteraction() }
      }
      .onChange(of: controller.summonDraft) { _, _ in
        if controller.panelShown { hints.recordInteraction() }
      }
      .onAppear { installActions() }
      .onDisappear {
        var hidden = context
        hidden.isKeyWindow = false
        hints.update(context: hidden)
      }
  }
  private func installActions() {
    hints.actions = HintCenter.Actions(
      turnOnOptionSpace: { [weak controller] in
        guard let controller else { return }
        RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.enabledKey)
        controller.install()
        // Enabling never silently changes the shortcut. The normal Settings control offers
        // “Use ⌃⌥Space” if another app owns ⌥Space.
        if controller.summonTaken { controller.openSettings(SettingsCategory.request("Relay", path: [RelaySettingsKey.anyApp])) }
      },
      chooseApprovals: {
        NotificationCenter.default.post(name: Notification.Name("SereinHintChooseApprovals"), object: nil)
      },
      turnOnCheckIns: { [weak relay] in
        guard let relay else { return }
        if RelayOrchestrator.persists {
          relay.proactiveLevel = .newInstallDefault
        } else {
          // A fixture never opens GateSettings, so this stays in memory.
          GateSettings.shared.set(RelayProactive.Level.newInstallDefault.rawValue, forKey: RelayOrchestrator.proactiveKey)
          relay.objectWillChange.send()
        }
      })
  }
}

/// AppKit supplies the events that SwiftUI's view state cannot: the exact key window, attached
/// sheets, native menu tracking and popovers. It watches only while the probe is mounted.
@MainActor private final class GuidanceWindowState: ObservableObject {
  struct State: Equatable {
    var isKey = false
    var hasSheet = false
    var menuOpen = false
    var popoverOpen = false
  }
  @Published private(set) var state = State()
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []
  private var menus = Set<ObjectIdentifier>()
  private var popovers = Set<ObjectIdentifier>()
  private var beginningSheet = false
  private var closed = false
  private let capture = CommandLine.arguments.contains("--ui-preview")
    && CommandLine.arguments.contains("--ui-capture")

  func attach(_ value: NSWindow?) {
    guard window !== value else { return }
    detach()
    window = value
    guard value != nil else { return }
    closed = false
    let center = NotificationCenter.default
    let windowEvents: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
      NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
    ]
    for name in windowEvents {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated { self?.windowEvent(note) }
      })
    }
    for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                 NSPopover.willShowNotification, NSPopover.didCloseNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated { self?.transientEvent(note) }
      })
    }
    refresh()
  }
  func detach(publish: Bool = true) {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []; menus = []; popovers = []
    beginningSheet = false; closed = false; window = nil
    if publish, state != State() { state = State() }
  }
  private func windowEvent(_ note: Notification) {
    if let source = note.object as? NSWindow, source === window {
      if note.name == NSWindow.willBeginSheetNotification { beginningSheet = true }
      if note.name == NSWindow.didEndSheetNotification { beginningSheet = false }
      if note.name == NSWindow.willCloseNotification { closed = true }
      if note.name == NSWindow.didBecomeKeyNotification || note.name == NSWindow.didDeminiaturizeNotification { closed = false }
    }
    refresh()
    // Sheet notifications can precede the attachedSheet/key-window mutation. One deferred
    // refresh observes that completed transition; this is not a repeating clock.
    DispatchQueue.main.async { [weak self] in self?.refresh() }
  }
  private func transientEvent(_ note: Notification) {
    guard let object = note.object as AnyObject? else { return }
    let id = ObjectIdentifier(object)
    switch note.name {
    case NSMenu.didBeginTrackingNotification: menus.insert(id)
    case NSMenu.didEndTrackingNotification: menus.remove(id)
    case NSPopover.willShowNotification: popovers.insert(id)
    case NSPopover.didCloseNotification: popovers.remove(id)
    default: break
    }
    refresh()
  }
  private func refresh() {
    var next = State()
    next.menuOpen = !menus.isEmpty
    next.popoverOpen = !popovers.isEmpty
    if let window {
      next.hasSheet = beginningSheet || window.attachedSheet != nil
      // Never accept an unrelated key window (Settings, private windows or the floating bar).
      let primary = window === (NSApp.delegate as? AppDelegate)?.window
      let shown = window.isVisible && !window.isMiniaturized && !closed
      next.isKey = primary && shown && (capture || (NSApp.isActive && window.isKeyWindow
        && NSApp.keyWindow === window && window.occlusionState.contains(.visible)))
    }
    if next != state { state = next }
  }
}

private struct GuidanceWindowProbe: NSViewRepresentable {
  var observer: GuidanceWindowState
  func makeNSView(context: Context) -> GuidanceProbeView {
    let view = GuidanceProbeView()
    view.observer = observer
    return view
  }
  func updateNSView(_ view: GuidanceProbeView, context: Context) { view.observer = observer }
  static func dismantleNSView(_ view: GuidanceProbeView, coordinator: ()) {
    view.observer?.detach(publish: false)
    view.observer = nil
  }
}
private final class GuidanceProbeView: NSView {
  weak var observer: GuidanceWindowState?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Publishing during a SwiftUI layout pass is forbidden; bind after that pass completes.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.observer?.attach(self.window)
    }
  }
}
