import SereinCore
import SwiftUI

/// Settings › AI apps (id "Agents"): one row per AI app (`HarnessSettingsSection`), each opening
/// its own page (`HarnessAppSettings`); New chats (what new chats start with, in Serein's own
/// picker with the app logos; the effort; Task permissions, which still asks before Full access);
/// On this Mac (Mac access, Background helpers, Other agents that use Serein), each
/// its own sub-page; and one More fold for the rest (Fast steps · Beta, Delete threads, the
/// projects always allowed to edit, Agent history, the Codex note).
struct AIAppsSettings: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  /// The More fold; `--ui-settings-advanced` opens it in a preview.
  @Binding var more: Bool
  @Environment(\.settingsNavigation) private var nav
  var body: some View {
    // One page (`SettingsInline`): only an AI app's own page opens in its place.
    if let key = nav.key(0), AIAppsKey.titles[key] == nil {
      HarnessAppSettings(agent: agent, key: key)
    } else {
      AIAppsPage(browser: browser, agent: agent, more: $more) { key in section(key) }
    }
  }
  private func section(_ key: String) -> AnyView {
    AnyView(SettingsSection(key, title: AIAppsKey.titles[key] ?? key) { sub(key) })
  }
  @ViewBuilder private func sub(_ key: String) -> some View {
    switch key {
    case AIAppsKey.mac: AIAppsMacAccess()
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

/// The sub-pages of AI apps that are not an AI app's own page (those are its driver's name).
enum AIAppsKey {
  static let mac = "mac"
  static let helpers = "helpers"
  static let outside = "outside"
  /// The sections under New chats, in page order.
  static let order = [mac, helpers, outside]
  static let titles: [String: String] = [
    mac: "Mac access", helpers: "Background helpers", outside: "Other agents that use Serein",
  ]
}

private struct AIAppsPage: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @Binding var more: Bool
  /// Draws one former sub-page as its section.
  let section: (String) -> AnyView
  @ObservedObject private var registry = HarnessRegistry.shared
  @ObservedObject private var codexCatalog = CodexCatalog.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 32) {
      HarnessSettingsSection(agent: agent)
      DirectProviderSettings()
      SettingsRowList("New chats") {
        startsWith
        if !effortLevels.isEmpty { effortRow }
        permissionsRow
      }
      ForEach(AIAppsKey.order, id: \.self) { key in section(key) }
      DisclosureGroup(isExpanded: $more) {
        VStack(alignment: .leading, spacing: 24) {
          ThreadDeletionSettings(agent: agent)
          FastStepsSettings()
          EditApprovalSettings(browser: browser)
          AgentHistorySettings(browser: browser)
        }.padding(.top, 16)
      } label: {
        Text("More").font(AssistantType.name)
      }.id("Advanced")
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

/// AI apps › Mac access: Full Disk Access, the Mac permissions, and Let assistants work in the
/// background (MacBackground; off by default).
private struct AIAppsMacAccess: View {
  @GateStorage(MacBackgroundPolicy.enabledKey) var macBackground = false
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Mac access", sentence: "For tasks sent to Anywhere: AI apps see and operate Mac apps, one approved step at a time.")
      SettingsBlock("Mac access") {
        FullDiskAccessWarning()
        MacAccessRows()
        Toggle("Let assistants work in the background", isOn: $macBackground)
          .onChange(of: macBackground) { _, on in if !on { MacBackground.shared.turnedOff() } }
        SettingsNote("Serein acts in the app's window without moving your pointer. Some apps need the foreground.")
      }
    }
  }
}
