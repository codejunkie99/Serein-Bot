import AppKit
import Sparkle
import SwiftUI

/// Updates through Sparkle. A build with a configured feed shows Sparkle's
/// window when a newer build is signed with Serein's update key, and replaces this app on install.
/// A local build has no feed address, so nothing here asks the network.
@MainActor final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
  static let shared = Updates()
  private var controller: SPUStandardUpdaterController?
  /// The version Sparkle found and has not installed yet. The Update button shows while this is set.
  @Published private(set) var pending: String?
  /// True once an automatic download is ready. Sparkle also installs it when Serein quits.
  @Published private(set) var downloaded = false
  /// Installs the ready download and relaunches without another window.
  private var installNow: (() -> Void)?
  /// Set just before an install that the Update button or an agent started relaunches Serein,
  /// so the quit that follows asks nothing more: the Update button already asked about running
  /// tasks, and an agent's install request was that agent's own choice. Sparkle's own Install
  /// and Relaunch never sets it, so that quit still asks about running work. Cleared when that
  /// quit is cancelled or the update cycle aborts.
  private(set) var installing = false
  /// The quit that an install started did not go ahead (a download question, say).
  func installCancelled() { installing = false }
  /// How many agent tasks run now. A restart stops them, so the Update button asks first.
  var activeTasks: @MainActor () -> Int = { 0 }

  /// "0.2.1 (166)": the version people read and the build number Sparkle compares.
  static var version: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return short }
    return "\(short) (\(build))"
  }

  var isAvailable: Bool { controller != nil }

  /// Called once at launch. Sparkle asks on the second launch whether it may check by itself.
  /// Until then it checks only from the menu or Settings.
  func start() {
    guard controller == nil,
      Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
      Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String
    else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    objectWillChange.send()
  }

  func check() { controller?.checkForUpdates(nil) }

  /// The Update button. A download that is ready installs and relaunches at once; when agent
  /// tasks run, it asks first, because the restart stops them. Otherwise Sparkle's window
  /// offers the found version.
  func update() {
    guard let installNow else { return check() }
    let running = activeTasks()
    if running > 0 {
      let alert = NSAlert()
      alert.messageText = running == 1 ? "1 task is still running" : "\(running) tasks are still running"
      alert.informativeText =
        "The update restarts Serein and stops \(running == 1 ? "it" : "them"). If you wait, the update installs when you quit."
      alert.addButton(withTitle: "Restart and update")
      alert.addButton(withTitle: "Later")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    installing = true
    installNow()
  }

  /// An agent's install request: installs the ready download a moment later, so the answer
  /// reaches the agent first. False when no download is ready.
  func installReady() -> Bool {
    guard let installNow else { return false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.installing = true
      installNow()
    }
    return true
  }

  /// UI previews only: shows the Update button without a feed.
  func previewPending(_ version: String) { pending = version }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    pending = item.displayVersionString
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    pending = nil
    forgetDownload()
  }

  /// The install handler belongs to one update cycle. When that cycle ends without an install,
  /// the handler is dead, and the button must open Sparkle's window again.
  private func forgetDownload() {
    installNow = nil
    downloaded = false
    installing = false
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { forgetDownload() }

  /// "Skip This Version" in Sparkle's window: the button goes too.
  func updater(
    _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
    forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState
  ) {
    guard choice == .skip else { return }
    pending = nil
    forgetDownload()
  }

  /// Only when the user turned on automatic installs. Returning true keeps the download for the
  /// Update button; Sparkle still installs it when Serein quits.
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    pending = item.displayVersionString
    installNow = immediateInstallHandler
    downloaded = true
    return true
  }

  var checksAutomatically: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set {
      controller?.updater.automaticallyChecksForUpdates = newValue
      if !newValue { controller?.updater.automaticallyDownloadsUpdates = false }
      objectWillChange.send()
    }
  }
  var installsAutomatically: Bool {
    get { controller?.updater.automaticallyDownloadsUpdates ?? false }
    set {
      controller?.updater.automaticallyDownloadsUpdates = newValue
      objectWillChange.send()
    }
  }
}

/// Shown only while a new version is waiting: beside Settings in the tab band, and as a
/// full-width row in the sidebar, where the footer has no room for it.
struct UpdateButton: View {
  var wide = false
  @ObservedObject private var updates = Updates.shared
  var body: some View {
    if let version = updates.pending {
      Button { updates.update() } label: {
        HStack(spacing: 5) {
          InterfaceIcon(systemName: "arrow.down.circle", size: 13)
          if wide {
            Text(updates.downloaded ? "Restart to update to \(version)" : "Update to Serein \(version)")
            Spacer(minLength: 0)
          } else {
            Text("Update")
          }
        }
      }.buttonStyle(PrimaryButton()).fixedSize(horizontal: !wide, vertical: true)
        .help(updates.downloaded ? "Install Serein \(version) and relaunch" : "Install Serein \(version)")
        .accessibilityLabel(updates.downloaded ? "Restart to update to Serein \(version)" : "Update to Serein \(version)")
    }
  }
}

struct UpdatesSettings: View {
  @ObservedObject private var updates = Updates.shared
  @Environment(\.palette) private var p

  private static let info =
    "Serein reads its configured update feed, once a day when the automatic check is on. The request includes this app’s version and nothing else about you. Install replaces this app and reopens it. Your settings and library stay. An update is installed only when its signature matches Serein's update key."
  var body: some View {
    SettingsGroup("Updates", info: updates.isAvailable ? Self.info : nil) {
      HStack {
        Text("Serein \(Updates.version)")
        Spacer()
        Button("Check now") { updates.check() }.disabled(!updates.isAvailable)
      }
      if let version = updates.pending {
        HStack(spacing: 10) {
          InterfaceIcon(systemName: "arrow.down.circle", size: 14).foregroundStyle(p.accent)
          Text(updates.downloaded ? "Serein \(version) is ready to install" : "Serein \(version) is available")
            .role(.body)
          Spacer()
          Button(updates.downloaded ? "Restart to update" : "Update") { updates.update() }
            .buttonStyle(PrimaryButton())
        }
      }
      if updates.isAvailable {
        Toggle(
          "Check for updates automatically",
          isOn: Binding(get: { updates.checksAutomatically }, set: { updates.checksAutomatically = $0 }))
        Toggle(
          "Download and install updates automatically",
          isOn: Binding(get: { updates.installsAutomatically }, set: { updates.installsAutomatically = $0 })
        ).disabled(!updates.checksAutomatically)
        SettingsNote(
          "With the automatic check on, Serein reads its configured update feed once a day and sends only this app’s version. An update installs only when its signature matches Serein's update key."
        )
      } else {
        SettingsNote("Serein Free updates are installed manually.")
      }
    }
  }
}
