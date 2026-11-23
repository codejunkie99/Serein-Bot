import AppKit
import Combine
import IOKit.pwr_mgt
import SereinCore
import ServiceManagement
import SwiftUI

/// Settings › General › Keep the Mac awake while tasks run (off by default). One idle-sleep
/// assertion, held only while a task runs, a detached job runs in a computer on this Mac
/// (`ComputerHost.localJobsRunning`, which refreshes this as jobs start and end) or a scheduled
/// run is due within two minutes (`KeepAwake`), and released at once otherwise and at quit. The display may still sleep, and
/// closing the lid still sleeps the Mac: the assertion never covers it.
@MainActor final class MacAwake: ObservableObject {
  static let shared = MacAwake()
  static let key = "serein.keepAwake"
  static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
  /// What the assertion is held for now; 0 while none is held.
  @Published private(set) var tasks = 0
  /// “Keeping your Mac awake for 2 tasks” while the assertion is held.
  var line: String? { KeepAwake.line(tasks) }
  private var assertion: IOPMAssertionID?
  private weak var relay: RelayOrchestrator?
  private var watch: AnyCancellable?
  private var timer: Timer?

  /// Follows the work that counts: runs starting and ending, Serein's reply, the schedules and
  /// the queue; the timer catches a run coming within two minutes while nothing else changes.
  func start(relay: RelayOrchestrator) {
    guard self.relay == nil else { return }
    self.relay = relay
    let hub = relay.agent.hub
    // Debounced: a published value changes just after it is announced.
    watch = hub.$runs.map { _ in () }
      .merge(with: hub.$revision.map { _ in () }, relay.$sending.map { _ in () },
             relay.$reminders.map { _ in () }, relay.$scheduledQueue.map { _ in () })
      .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
      .sink { [weak self] in self?.refresh() }
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    // Two minutes of lead leave room: macOS may coalesce the fire.
    timer?.tolerance = 5
    refresh()
  }
  /// Holds or releases the assertion to match the setting and the work now.
  func refresh(now: Date = Date()) {
    guard Self.enabled, let relay else { return release() }
    // As ⌘Q counts it: every task but Serein's own run, then Serein's reply once.
    let running = relay.agent.hub.slotted.count + (relay.working ? 1 : 0)
    let count = KeepAwake.tasks(
      running: running, queued: relay.scheduledQueue.count, reminders: relay.reminders, now: now,
      paused: relay.state.paused, jobs: ComputerHost.shared.localJobsRunning)
    guard count > 0 else { return release() }
    if assertion == nil {
      var id = IOPMAssertionID(0)
      // Idle sleep only: the display may sleep, and closing the lid still sleeps the Mac.
      let made = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        KeepAwake.reason as CFString, &id)
      guard made == kIOReturnSuccess else { return release() }
      assertion = id
    }
    if tasks != count { tasks = count }
  }
  /// Lets the Mac sleep again: nothing to keep it awake for, the setting is off, or Serein quits.
  func release() {
    if let assertion { IOPMAssertionRelease(assertion) }
    assertion = nil
    if tasks != 0 { tasks = 0 }
  }
}

/// Open at login, for Settings and for the chat's offer once schedules exist: a login item
/// through `SMAppService.mainApp`, which needs the packaged app.
@MainActor enum LoginLaunch {
  /// A `swift run` build has no bundle macOS can open at login.
  static var packaged: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
  static var enabled: Bool { packaged && SMAppService.mainApp.status == .enabled }
  /// The chat's offer, once declined, is not made again (Settings › General keeps the switch).
  static let declinedKey = "serein.loginOffer.declined"
  static var declined: Bool { UserDefaults.standard.bool(forKey: declinedKey) }
  /// Adds Serein to the login items: nil once macOS will open it, else what is left to do (an
  /// approval in System Settings, which this opens).
  static func turnOn() -> String? {
    guard packaged else { return "Opening at login needs the packaged app." }
    do { try SMAppService.mainApp.register() } catch { return error.localizedDescription }
    switch SMAppService.mainApp.status {
    case .enabled: return nil
    case .requiresApproval:
      SMAppService.openSystemSettingsLoginItems()
      return "Allow Serein in System Settings › General › Login Items."
    case .notFound: return "macOS cannot find this copy of Serein. Move it to Applications, then try again."
    default: return "Serein could not be added to your login items."
    }
  }
}

/// Settings › General › Startup and sleep: open at login (a login item through
/// `SMAppService.mainApp`, off by default) and keep the Mac awake while tasks run.
struct StartupSettings: View {
  @Environment(\.palette) private var p
  @ObservedObject private var awake = MacAwake.shared
  @AppStorage(MacAwake.key) private var keepAwake = false
  /// Read from macOS on appear and when Serein comes back to the front, only in the packaged app.
  @State private var status: SMAppService.Status = .notRegistered
  @State private var problem: String?
  /// Login items need the packaged app; a `swift run` build has no bundle macOS can open.
  private let packaged = LoginLaunch.packaged

  var body: some View {
    Toggle("Open Serein when you log in", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
      .disabled(!packaged)
    if packaged {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(statusLine).role(.meta).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 12)
        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
          .buttonStyle(QuietButton())
          .help("System Settings › General › Login Items")
      }.padding(.top, -12)
      if let problem { Text(problem).role(.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true) }
    } else {
      SettingsNote("Opening at login needs the packaged app (scripts/build.sh). This copy runs from a build folder, which macOS cannot open at login.")
    }
    Divider().overlay(p.line)
    Toggle("Keep the Mac awake while tasks run", isOn: $keepAwake)
      .onChange(of: keepAwake) { _, _ in MacAwake.shared.refresh() }
    SettingsNote(awake.line.map { $0 + "." }
      ?? "Only while a task runs, a detached job runs in Serein's computer on this Mac (Docker or built-in), or a scheduled run is due within two minutes. The display can still sleep, and closing the lid still puts the Mac to sleep.")
      .onAppear(perform: refreshStatus)
      // Back from System Settings: the approval may have changed.
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        refreshStatus()
      }
  }

  private func refreshStatus() {
    if packaged { status = SMAppService.mainApp.status }
  }
  /// On only once macOS will open Serein; waiting for approval reads as off, with the status line
  /// and Open Login Items saying what is left to do.
  private var opensAtLogin: Bool { status == .enabled }
  private var statusLine: String {
    switch status {
    case .enabled: return "Serein opens when you log in."
    case .requiresApproval: return "Needs your approval in System Settings › General › Login Items."
    case .notFound: return "macOS cannot find this copy of Serein. Move it to Applications, then turn this on again."
    case .notRegistered: return "Off."
    @unknown default: return "Off."
    }
  }
  private func setOpensAtLogin(_ on: Bool) {
    guard packaged else { return }
    problem = nil
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      problem = error.localizedDescription
    }
    refreshStatus()
  }
}
