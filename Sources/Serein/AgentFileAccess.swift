import AppKit
import Darwin
import SereinCore
import SwiftUI

/// Agent CLIs are child processes of Serein and inherit its macOS privacy access. Serein never
/// asks for Full Disk Access, but the user may have given it anyway. When an agent starts, Serein
/// checks whether it can open files that only Full Disk Access unlocks and, if so, warns once in
/// Settings › AI apps and the at-work popover.
@MainActor final class FullDiskAccessNotice: ObservableObject {
  static let shared = FullDiskAccessNotice()
  static let dismissedKey = "serein.fullDiskAccessWarningDismissed"
  @Published private(set) var detected = false
  @Published private(set) var dismissed = UserDefaults.standard.bool(forKey: dismissedKey)

  var showing: Bool { detected && !dismissed }

  /// Called at every agent launch. Opens the probe files without reading them.
  func check() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    detected = AgentFileGuard.holdsFullDiskAccess(home: home, canOpen: Self.canOpen)
  }
  func dismiss() {
    dismissed = true
    UserDefaults.standard.set(true, forKey: Self.dismissedKey)
  }
  func openPrivacySettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    {
      NSWorkspace.shared.open(url)
    }
  }
  nonisolated static func canOpen(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return false
    }
    if isDirectory.boolValue {
      guard let dir = opendir(url.path) else { return false }
      closedir(dir)
      return true
    }
    let fd = open(url.path, O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    close(fd)
    return true
  }
}

/// The one-time warning. Hidden once dismissed or when Serein does not hold the access.
struct FullDiskAccessWarning: View {
  @ObservedObject var notice = FullDiskAccessNotice.shared
  var compact = false
  @Environment(\.palette) var p
  var body: some View {
    if notice.showing {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 8) {
          InterfaceIcon(systemName: "exclamationmark.triangle", size: 13).foregroundStyle(p.warning)
          VStack(alignment: .leading, spacing: 4) {
            Text("Serein has Full Disk Access").font(UIStyle.bodyStrong).foregroundStyle(p.ink)
            // Let Serein read Messages needs it: then the warning says what it is for.
            Text(
              Connections.readsMessages()
                ? "Agents you start from Serein inherit it, so they could read mail, messages and other private files. Serein uses it only for Let Serein read Messages; turn that off in Marketplace › On this Mac and remove Serein in System Settings › Privacy & Security › Full Disk Access when you no longer need it."
                : "Agents you start from Serein inherit it, so they could read mail, messages and other private files. Serein doesn't need it. Remove Serein in System Settings › Privacy & Security › Full Disk Access."
            ).role(.meta).fixedSize(horizontal: false, vertical: true)
          }
        }
        HStack(spacing: 8) {
          Spacer()
          Button("Got it") { notice.dismiss() }.buttonStyle(QuietButton())
          Button("Open System Settings") { notice.openPrivacySettings() }.buttonStyle(QuietButton())
        }
      }.padding(compact ? 12 : 14)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
        .accessibilityElement(children: .contain)
    }
  }
}
