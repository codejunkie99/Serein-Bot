import AppKit
import SereinCore
import SwiftUI

/// Every key GateSettings holds (relay/gates.json): each switch and consent that loosens a gate.
/// `GateSettings.migrate` moves them out of UserDefaults once, at launch.
@MainActor enum GateKeys {
  static var all: [String] {
    // Built in typed steps: as one chained expression the type checker gives up.
    var keys: [String] = [
      // Serein asks before (the approval level and Autopilot) and its one-time consent card.
      RelayOrchestrator.autopilotKey, ApprovalLevel.defaultedKey,
      // What a new task may do: clicks and typing (with its one-time reset), project edits, Mac apps.
      ActionClickDefault.key, ActionClickDefault.migratedKey,
      AgentModel.AccessToggle.edits.rawValue, AgentModel.AccessToggle.mac.rawValue,
      // Person-only consents: Always allow edits, Full access, a linked CLI's own settings.
      ProjectEditApprovals.key, FullAccessConsent.key, LinkedReplyConsent.threadsKey, LinkedReplyConsent.appsKey,
      // Mac access › Let assistants work in the background; a spoken allow in a call.
      MacBackgroundPolicy.enabledKey, RelayController.voiceAnswersKey,
      // Serein's computer and its limits.
      ComputerPolicy.enabledKey, ComputerPolicy.autoSetUpKey, ComputerPolicy.memoryKey, ComputerPolicy.cpuKey, VirtualMachinePolicy.memoryKey,
      // Mail and Messages, Messages reading and its chats and days.
      Connections.messagesReadKey, Connections.chatsKey, Connections.daysKey,
      // Connected apps: the switch, read and change, scheduled use, blocked tools.
      ComposioApps.switchKey, ComposioApps.changesKey, ComposioApps.unattendedKey, ComposioApps.blockedKey,
      // Webhooks, task downloads, page tools and their sites, site rules, outside-content marks.
      RelayHookServer.switchKey, TaskDownloadPolicy.enabledKey, PageTools.enabledKey, PageTools.sitesKey,
      SiteRules.key, OutsideThreads.key, RoutineGrants.sitesKey,
      // What reaches an agent: sites kept away, consent overlays, the tab you are on.
      BrowserTab.excludedSitesKey, BrowserModel.mostPrivateKey, SereinPageChip.shareKey,
      // Check-ins (the quietest is Never), reading the person's AI chats, iCloud password sync and
      // password managers in Sign in as.
      RelayOrchestrator.proactiveKey, SessionReading.key, PasswordVault.syncDefaultsKey, PasswordManagers.enabledKey,
      // Say “Serein” to ask: the microphone listening while it is on.
      WakeListener.enabledKey,
      // Show and tell: what is selected or pointed at during a hold, and the window's picture.
      ScreenContext.enabledKey, ScreenContext.pictureKey,
      ScreenTrail.enabledKey,
    ]
    // Every background feature sends data to a model.
    keys += AgentFeature.allCases.map(FeaturePolicy.key)
    for connection in Connection.allCases {
      keys.append(Connections.key(connection))
      keys.append(Connections.scheduledKey(connection))
    }
    for connection in NativeConnection.allCases {
      keys.append(connection.switchKey)
      keys.append(connection.scheduledKey)
    }
    keys.append(MacFiles.wholeMacKey)
    return keys
  }
  /// Keys made per site, each gathered into one map: location, notification and autoplay choices.
  static let maps = [SitePermissions.gateKey: SitePermissions.siteDefaultsPrefix]
}

/// Redraws the views that show a gate switch whenever GateSettings changes.
final class GateWatch: ObservableObject {
  static let shared = GateWatch()
  private var token: NSObjectProtocol?
  private init() {
    token = NotificationCenter.default.addObserver(forName: GateSettings.changed, object: nil, queue: .main) {
      [weak self] _ in self?.objectWillChange.send()
    }
  }
}

/// `@AppStorage` for a key GateSettings holds: the same use in a view, with the value in the
/// Library. The initial value is shown while nothing is stored, and `unreadable`, when given,
/// while the file cannot be read (the value the code then uses).
@propertyWrapper struct GateStorage<Value>: DynamicProperty {
  @ObservedObject private var watch = GateWatch.shared
  private let key: String
  private let initial: Value
  private let fallback: Value?
  init(wrappedValue: Value, _ key: String, unreadable: Value? = nil) {
    initial = wrappedValue
    self.key = key
    fallback = unreadable
  }
  var wrappedValue: Value {
    get {
      if let fallback, GateSettings.shared.unreadable { return fallback }
      return GateSettings.shared.object(forKey: key) as? Value ?? initial
    }
    nonmutating set { GateSettings.shared.set(newValue, forKey: key) }
  }
  var projectedValue: Binding<Value> { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
}

/// At the top of the Settings pages that hold gate switches, and of every sub-page under them
/// (ReferenceSettings draws it for the whole path), while relay/gates.json cannot be read
/// (every switch there is at its safest value and no change is saved) or the last change could
/// not be saved (GateSettings).
struct GateNotice: View {
  /// The pages that show a switch GateSettings holds.
  static let pages: Set<String> = ["Agents", "Relay", "Computer", "Privacy", "Passwords", "Talking"]
  @ObservedObject private var watch = GateWatch.shared
  @Environment(\.palette) private var p
  var body: some View {
    if let line {
      HStack(alignment: .top, spacing: 8) {
        InterfaceIcon(systemName: "exclamationmark.triangle", size: 13).foregroundStyle(p.warning)
          .accessibilityHidden(true)
        Text(line).role(.meta).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        if let url = GateSettings.shared.fileURL {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .buttonStyle(QuietButton())
            .accessibilityLabel("Show Serein's safety settings file in Finder")
        }
      }.padding(14)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
        .accessibilityElement(children: .contain)
    }
  }
  /// The file cannot be read, or the last change could not be saved; nil when neither.
  private var line: String? {
    if GateSettings.shared.unreadable {
      return "Serein couldn't read its safety settings, so it is using the safest ones. Changes can't be saved until this is fixed."
    }
    return GateSettings.shared.saveFailed ? "Serein couldn't save a safety setting; it lasts until you quit." : nil
  }
}
