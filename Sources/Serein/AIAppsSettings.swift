import SereinCore
import SwiftUI

/// Settings › AI apps (id "Agents"; docs/demos/simple-settings.decision.md): the app Serein thinks
/// with, then one row per AI app (`HarnessSettingsSection`), each opening its own page
/// (`HarnessAppSettings`). Everything else folds under Advanced: New chats (what new chats start
/// with, the effort, Asks before, all three also in the message box), Model providers, Background
/// helpers, Other agents that use Serein, Delete threads, Fast steps · Beta, the projects always
/// allowed to edit and Agent history. Mac permissions are on Privacy.
struct AIAppsSettings: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @Environment(\.settingsNavigation) private var nav
  var body: some View {
    // One page (`SettingsInline`): only an AI app's own page opens in its place.
    if let key = nav.key(0), AIAppsKey.titles[key] == nil {
      HarnessAppSettings(agent: agent, key: key)
    } else {
      AIAppsPage(browser: browser, agent: agent) { key in section(key) }
    }
  }
  private func section(_ key: String) -> AnyView {
    AnyView(SettingsSection(key, title: AIAppsKey.titles[key] ?? key) { sub(key) })
  }
  @ViewBuilder private func sub(_ key: String) -> some View {
    switch key {
    case AIAppsKey.helpers:
      SettingsPageHeader("Background helpers", sentence: "Small jobs your AI app does on its own. Each switch says what it sends.")
      FeatureSettings()
    default:
      SettingsPageHeader("Other agents that use Serein", sentence: "Let an agent outside Serein work on web pages through it, in its own tabs.")
      if let access = OutsideAgents.shared { OutsideAgentsSettings(access: access).id("MCP connection") }
    }
  }
  /// The back link's words for a sub-page here.
  @MainActor static func title(_ key: String) -> String {
    if let title = AIAppsKey.titles[key] { return title }
    return HarnessAppSettings.title(key)
  }
}

/// The parts of AI apps that are not an AI app's own page (those are its driver's name).
enum AIAppsKey {
  /// Mac access moved to Privacy (`PrivacyKey.mac`); a request for it opens there (`ReferenceSettings`).
  static let mac = "mac"
  static let defaultApp = "default-app"
  static let newChats = "new-chats"
  static let helpers = "helpers"
  static let outside = "outside"
  /// The headed sections inside Advanced, in page order.
  static let order = [helpers, outside]
  /// Every part a request scrolls to, by key.
  static let titles: [String: String] = [
    defaultApp: "Serein thinks with", newChats: "New chats", helpers: "Background helpers",
    outside: "Other agents that use Serein",
  ]
}

private struct AIAppsPage: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  /// Draws one former sub-page as its section.
  let section: (String) -> AnyView
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var codexCatalog = CodexCatalog.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      if let controller = RelayController.shared {
        RelayDefaultAppSettings(relay: controller.relay, agent: agent).id(AIAppsKey.defaultApp)
      }
      HarnessSettingsSection(agent: agent)
      SettingsAdvanced(page: "Agents", count: 9) {
        SettingsRowList("New chats", note: "The message box picks these for each chat too.") {
          startsWith
          if !effortLevels.isEmpty { effortRow }
          permissionsRow
        }.id(AIAppsKey.newChats)
        DirectProviderSettings()
        ForEach(AIAppsKey.order, id: \.self) { key in section(key) }
        ThreadDeletionSettings(agent: agent)
        FastStepsSettings()
        EditApprovalSettings(browser: browser)
        AgentHistorySettings(browser: browser)
      }
      SettingsMovedNote("Mac permissions are in Settings › Privacy.")
    }
  }

  /// The default model's display name from the harness's list.
  private var modelName: String {
    let d = agent.taskDefault
    let id = ClaudeModelID.split(d.model).base
    if let choice = registry.models(d.provider).first(where: { $0.id == id }), !choice.name.isEmpty {
      return choice.name
    }
    // No pick yet: the app's own listed default, by its real name.
    if d.model.isEmpty, let listed = registry.chosen(d.provider, d.model) { return listed.name }
    return d.model.isEmpty ? d.provider.shortName : d.model
  }
  /// The effort levels the default model offers; none hides the Effort row.
  private var effortLevels: [String] {
    let d = agent.taskDefault
    return registry.models(d.provider).first { $0.id == ClaudeModelID.split(d.model).base }?.effortLevels ?? []
  }

  /// What a new chat starts on (AgentModel.taskDefault); no open chat changes here. The pill
  /// opens Serein's own picker (`ModelPickerView(setsDefault: true)` in Settings' dropdown layer).
  private var startsWith: some View {
    let provider: Provider = agent.taskDefault.provider
    let effort: String? = HarnessOption.effortShown(agent.taskDefault.effort, levels: effortLevels)
    let answer: String = [provider.name, modelName, effort].compactMap { $0 }.joined(separator: " · ")
    return SettingsListRow(name: "New chats start with", status: answer, expandable: false) {
      SettingsLogoTile(provider: provider)
    } trailing: {
      DropdownPill(kind: .models, owner: "settings", help: "Choose the AI app and model for new chats") {
        HarnessGlyph(provider: provider, size: 14, tinted: true, logo: true)
        Text(modelName).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
        InterfaceIcon(systemName: "chevron.down", size: 8)
      }
      .accessibilityLabel("New chats start with")
      .accessibilityValue("\(provider.name), \(modelName)")
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }
  private var effortRow: some View {
    let choices: [SettingsChoice<String>] = effortLevels.map { SettingsChoice(value: $0, label: EffortLadder.label($0)) }
    return SettingsChoiceRow(
      title: "Effort", answer: "How long the model thinks before it answers", selection: $agent.taskDefault.effort,
      choices: choices
    ) {
      SettingsGlyphTile(systemName: "gauge.with.dots.needle.33percent")
    }
  }
  /// Task permissions, out of the fold because it keeps you safe. Full access still asks first
  /// (`FullAccessConsent`); a no leaves the choice as it was.
  private var permissionsRow: some View {
    let choices: [SettingsChoice<RunPermissionMode>] = RunPermissionMode.allCases.map {
      SettingsChoice(value: $0, label: $0.label)
    }
    return SettingsChoiceRow(
      title: "Asks before", answer: agent.permission.detail,
      selection: Binding(get: { agent.permission }, set: { mode in setPermission(mode) }), choices: choices
    ) {
      SettingsGlyphTile(systemName: "lock.shield")
    }
  }
  private func setPermission(_ mode: RunPermissionMode) {
    guard mode != agent.permission else { return }
    if mode == .fullAccess {
      let project = agent.mode == .project ? agent.projectID : nil
      guard FullAccessConsent.request(projectID: project, projectName: nil) else { return }
    }
    agent.permission = mode
  }
}

/// Privacy › Mac permissions (it was Privacy › Mac permissions): Full Disk Access, the Mac permissions,
/// and Let assistants work in the background (MacBackground; off by default).
struct MacPermissionsSettings: View {
  @GateStorage(MacBackgroundPolicy.enabledKey) var macBackground = false
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Mac permissions", sentence: "For tasks sent to Anywhere: AI apps see and operate Mac apps, one approved step at a time.")
      SettingsBlock("Mac permissions") {
        FullDiskAccessWarning()
        MacAccessRows()
        Toggle("Let assistants work in the background", isOn: $macBackground)
          .onChange(of: macBackground) { _, on in if !on { MacBackground.shared.turnedOff() } }
        SettingsNote("Serein acts in the app's window without moving your pointer. Some apps need the foreground.")
      }
    }
  }
}
