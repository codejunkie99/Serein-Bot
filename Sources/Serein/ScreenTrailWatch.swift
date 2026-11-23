import AppKit
import SereinCore

@MainActor final class ScreenTrailWatch {
  static let shared = ScreenTrailWatch()
  nonisolated static var enabled: Bool { GateSettings.shared.bool(forKey: ScreenTrail.enabledKey) }
  static let declinedKey = "serein.relay.screenTrail.declined"
  static var declined: Bool { UserDefaults.standard.bool(forKey: declinedKey) }
  static var live: Bool { enabled && RelayOrchestrator.enabled }
  static func turnOn() {
    GateSettings.shared.set(true, forKey: ScreenTrail.enabledKey)
    _ = MacControl.accessibilityGranted(prompt: !RunMode.automated)
  }
  /// Switched off by hand: that is an answer, so the card is not offered again.
  static func turnOff() {
    GateSettings.shared.set(false, forKey: ScreenTrail.enabledKey)
    RelayOrchestrator.setSetting(true, forKey: declinedKey)
  }

  private var trail = ScreenTrail()
  private var timer: Timer?
  private var gate: NSObjectProtocol?
  private var opensWebPages: [String: Bool] = [:]
  // shortcut: asks on the main thread every 3 seconds, so a window in front for less is missed and an app that does not answer costs up to half a second each time; follow Accessibility's own notices off the main thread if either matters.
  private static let every: TimeInterval = 3

  private init() {}

  func refresh() {
    if gate == nil {
      gate = NotificationCenter.default.addObserver(forName: GateSettings.changed, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
    }
    guard Self.live else {
      timer?.invalidate()
      timer = nil
      trail = ScreenTrail()
      opensWebPages = [:]
      return
    }
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.look() }
    }
    look()
  }

  private func look() {
    guard Self.enabled, !RunMode.automated, let front = NSWorkspace.shared.frontmostApplication else { return }
    let name = front.localizedName ?? ""
    let isSerein = front.processIdentifier == ProcessInfo.processInfo.processIdentifier
    let web = opensWeb(front)
    let readable = !isSerein && !web && !RelayAutonomy.holdsSecrets(app: name, bundleID: front.bundleIdentifier)
      && MacControl.accessibilityGranted(prompt: false)
    note(
      app: name, bundleID: front.bundleIdentifier, window: readable ? ScreenContextCapture.focusedWindow(of: front)?.title : nil,
      isSerein: isSerein, opensWebPages: web)
  }

  func note(app: String, bundleID: String?, window: String?, isSerein: Bool, opensWebPages: Bool, at now: Date = Date()) {
    guard Self.live else { return }
    trail.note(app: app, bundleID: bundleID, window: window, isSerein: isSerein, opensWebPages: opensWebPages, at: now)
  }

  func attachment(now: Date = Date()) -> SereinAttachment? {
    guard Self.enabled, let body = trail.body(now: now) else { return nil }
    return SereinAttachment(
      title: ScreenTrail.title, icon: "clock.arrow.circlepath", body: body,
      note: "The apps and windows you had in front in the last ten minutes. Serein gets it with your message")
  }

  private func opensWeb(_ app: NSRunningApplication) -> Bool {
    let key = app.bundleIdentifier ?? ""
    if let known = opensWebPages[key] { return known }
    let offered = URL(string: "https://example.com").map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
    let answer = ScreenTrail.opensWebPages(
      bundleID: app.bundleIdentifier, path: app.bundleURL?.standardizedFileURL.path,
      handlers: Set(offered.map(\.standardizedFileURL.path)),
      installed: { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0).map(\.standardizedFileURL.path) })
    opensWebPages[key] = answer
    return answer
  }
}
