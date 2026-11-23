import AppKit
import SereinCore
import Foundation

/// Setup's "Control your apps": macOS asks once per app before Serein may script it (Privacy &
/// Security › Automation). This puts every one of those questions to the person at once, during
/// setup, instead of one by one in the middle of tasks. An app that is not open opens hidden for
/// its question and closes again; macOS does all the asking and Serein never changes the answers.
@MainActor enum EverydayAppsAccess {
  /// The apps Serein's own tools script, in the order macOS asks about them.
  nonisolated static let bundleIDs = [
    "com.apple.systemevents", "com.apple.finder", "com.apple.Safari", "com.google.Chrome",
    "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS",
  ]
  /// Each app's last answer ("allowed" or "denied"), kept because macOS cannot say for an app
  /// that is closed.
  static let answersKey = "serein.onboarding.appsAnswers"
  /// How long a hidden app has to open before its question is skipped.
  static let launchWait: Duration = .seconds(6)

  /// The apps above that this Mac has.
  static var installed: [String] {
    bundleIDs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
  }

  /// Denied when any app's answer is no, granted once every installed app answered yes. macOS's
  /// live answer counts when it has one; a closed app's kept answer counts otherwise.
  static var state: MacAccess.State {
    let kept = UserDefaults.standard.dictionary(forKey: answersKey) as? [String: String] ?? [:]
    let answers: [AutomationState?] = installed.map { id in
      MacAccess.automationState(bundleID: id) ?? kept[id].flatMap { $0 == "allowed" ? .allowed : $0 == "denied" ? .denied : nil }
    }
    if answers.contains(.denied) { return .denied }
    return answers.allSatisfy { $0 == .allowed } ? .granted : .unknown
  }

  /// Asks macOS about each installed app in turn, keeping each answer. Each question waits for
  /// the person's answer; an app that would not open stays unasked, so the row stays open.
  static func askAll() async {
    var kept = UserDefaults.standard.dictionary(forKey: answersKey) as? [String: String] ?? [:]
    for bundleID in installed {
      guard let answer = await ask(bundleID) else { continue }
      kept[bundleID] = answer == .allowed ? "allowed" : "denied"
    }
    UserDefaults.standard.set(kept, forKey: answersKey)
  }

  /// macOS's answer for one app, or nil when it could not be asked.
  private static func ask(_ bundleID: String) async -> AutomationState? {
    let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    if !wasRunning {
      guard await openHidden(bundleID) else { return nil }
    }
    // Blocks until the person answers macOS's question, so it runs off the main thread.
    let status = await Task.detached { askMacOS(bundleID) }.value
    if !wasRunning {
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }
    switch status {
    case noErr: return .allowed
    case OSStatus(errAEEventNotPermitted): return .denied
    default: return nil
    }
  }

  private static func openHidden(_ bundleID: String) async -> Bool {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.hides = true
    configuration.addsToRecentItems = false
    guard (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil else { return false }
    let deadline = ContinuousClock.now + launchWait
    while ContinuousClock.now < deadline {
      if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.isFinishedLaunching == true { return true }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return false
  }

  /// macOS's own question for one app: nothing is sent to it.
  nonisolated private static func askMacOS(_ bundleID: String) -> OSStatus {
    let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    return withExtendedLifetime(descriptor) {
      guard let address = descriptor.aeDesc else { return OSStatus(procNotFound) }
      return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, true)
    }
  }
}
