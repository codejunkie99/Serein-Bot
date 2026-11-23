import AppKit
import Foundation
import SereinCore

/// Full access asks once per project; the answer is remembered on this Mac (GateSettings).
enum FullAccessConsent {
  static let key = "serein.fullAccessProjects"
  static func confirmed(_ projectID: String?) -> Bool {
    guard let projectID else { return false }
    return (GateSettings.shared.stringArray(forKey: key) ?? []).contains(projectID)
  }
  /// A chat may use Full access in the project: confirmed once, or Serein is at Allow all, which
  /// stores nothing, so the project asks again once the level is lowered.
  static func allowed(_ projectID: String?, at level: ApprovalLevel) -> Bool {
    projectID != nil && (level == .proactive || confirmed(projectID))
  }
  @MainActor static func allowed(_ projectID: String?) -> Bool {
    allowed(projectID, at: RelayOrchestrator.shared?.level ?? .everyStep)
  }
  /// Shows the confirmation the first time. Returns true when Full access may be used.
  @MainActor static func request(projectID: String?, projectName: String?) -> Bool {
    guard let projectID else { return false }
    if allowed(projectID) { return true }
    let alert = NSAlert()
    alert.messageText = "Allow Full access in \(projectName ?? "this project")?"
    alert.informativeText =
      "The agent can run commands and change files in this project without asking. Websites still go only through Serein's browser, and Stop ends everything it started. You can switch back to Supervised at any time."
    alert.addButton(withTitle: "Allow Full Access")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    var all = GateSettings.shared.stringArray(forKey: key) ?? []
    all.append(projectID)
    GateSettings.shared.set(all, forKey: key)
    return true
  }
}

/// A reply in a chat that its own CLI answers (LinkedSessions.repliesInApp) runs with that app's
/// own settings: Serein's approval steps do not apply, and the CLI has no window to ask in. Serein
/// asks before the first reply in each thread; the answer is remembered on this Mac, for the
/// thread or, when the person says so, for every chat of that app (GateSettings).
@MainActor enum LinkedReplyConsent {
  static let threadsKey = "serein.linkedReplyThreads"
  static let appsKey = "serein.linkedReplyApps"
  /// Replaced in checks, which have no window to ask in.
  static var request: (_ thread: String, _ link: SessionLink, _ folder: String?) -> Bool = ask

  static func ask(_ thread: String, _ link: SessionLink, _ folder: String?) -> Bool {
    let defaults = GateSettings.shared
    let threads = defaults.stringArray(forKey: threadsKey) ?? []
    let apps = defaults.stringArray(forKey: appsKey) ?? []
    if threads.contains(thread) || apps.contains(link.driver) { return true }
    let driver = HarnessDriver(rawValue: link.driver)
    let risk = driver == .pi || driver == .ohMyPi
      ? "\(link.name) has no approval step, so it can change files and run commands on this Mac without asking."
      : "It can change files and run commands on this Mac as its own settings allow, and here it cannot stop to ask you first."
    let place = folder.map { " It works in “\(URL(fileURLWithPath: $0).lastPathComponent)”." } ?? ""
    let alert = NSAlert()
    alert.messageText = "Send this to \(link.name) with its own settings?"
    alert.informativeText = """
      Serein does not run \(link.name) itself, so Serein's approval steps do not apply to this chat. \(risk)\(place)

      Web page text you attach goes to \(link.name) too, and words on a page can tell it to do things.
      """
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Do not ask again for \(link.name)"
    alert.addButton(withTitle: "Send")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    if alert.suppressionButton?.state == .on {
      defaults.set(apps + [link.driver], forKey: appsKey)
    } else {
      // ponytail: the newest 500 threads are kept; an older thread asks again.
      defaults.set(Array((threads + [thread]).suffix(500)), forKey: threadsKey)
    }
    return true
  }
}
