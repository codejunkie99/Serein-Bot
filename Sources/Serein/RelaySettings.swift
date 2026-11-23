import AppKit
import SereinCore
import SwiftUI

/// Settings › Assistants (id "Relay", alias "Serein"; board 14): one row per assistant (its face,
/// its job and its state), which opens that assistant's page (AssistantSettingsPage.swift); New
/// assistant; Teams; and what every assistant does, one row each, which open their own sub-pages
/// here: Asks first, Default AI app, Ask from any app, Morning brief, Suggest routines, Your
/// reminders, Links from other apps, and under More: Task downloads, Tell me when tasks finish,
/// Recipes and shortcuts. Every row shows whether or not ⌥Space is on: the assistants always work
/// in the window. Look moved to Appearance and the voice switches to Talking.
struct RelaySettings: View {
  @ObservedObject var agent: AgentModel
  @Environment(\.settingsNavigation) private var nav

  var body: some View {
    let key: String? = nav.key(0)
    if let controller = RelayController.shared {
      RelaySettingsPages(relay: controller.relay, agent: agent, controller: controller, key: key)
    } else {
      // Before Serein runs in this window: the two switches that need no assistant.
      VStack(alignment: .leading, spacing: 24) {
        RelayAnyAppSettings(controller: nil)
        RelayDownloadsSettings()
      }
    }
  }

  /// The back link's words for a sub-page here: an assistant's name, or the row's title.
  @MainActor static func title(_ key: String) -> String {
    if let title = RelaySettingsKey.titles[key] { return title }
    if let relay = RelayController.shared?.relay, let profile = relay.team.profiles.first(where: { $0.id == key }) {
      return profile.name
    }
    return "Assistants"
  }
}

/// The sub-pages of Settings › Assistants that are not an assistant's page. An assistant's id is
/// never one of these words.
enum RelaySettingsKey {
  static let teams = "teams"
  static let asks = "asks"
  static let defaultApp = "default-app"
  static let anyApp = "any-app"
  static let reminders = "reminders"
  static let links = "links"
  static let downloads = "downloads"
  static let recipes = "recipes"
  /// The sections after "For every assistant", in page order (Teams sits under the assistants).
  static let order = [asks, defaultApp, anyApp, reminders, links, downloads, recipes]
  static let titles: [String: String] = [
    teams: "Teams", asks: "Asks first", defaultApp: "Default AI app", anyApp: "Ask from any app",
    reminders: "Your reminders", links: "Links from other apps", downloads: "Task downloads",
    recipes: "Recipes and shortcuts",
  ]
}

/// The page, or the sub-page its first key names.
private struct RelaySettingsPages: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var agent: AgentModel
  let controller: RelayController
  let key: String?
  var body: some View {
    // One page (`SettingsInline`): only an assistant's own page opens in its place.
    if let id = key, RelaySettingsKey.titles[id] == nil {
      AssistantSettingsPage(relay: relay, profileID: id)
    } else {
      VStack(alignment: .leading, spacing: 32) {
        RelayAssistantsPage(relay: relay, agent: agent, controller: controller, part: .assistants)
        section(RelaySettingsKey.teams)
        RelayAssistantsPage(relay: relay, agent: agent, controller: controller, part: .everyAssistant)
        ForEach(RelaySettingsKey.order, id: \.self, content: section)
      }
    }
  }
  private func section(_ key: String) -> some View {
    SettingsSection(key, title: RelaySettingsKey.titles[key] ?? key) { sub(key) }
  }
  @ViewBuilder private func sub(_ key: String) -> some View {
    switch key {
    case RelaySettingsKey.teams: RelayTeamsSettings(relay: relay)
    case RelaySettingsKey.asks: RelayAsksSettings(relay: relay, controller: controller)
    case RelaySettingsKey.defaultApp: RelayDefaultAppSettings(relay: relay, agent: agent)
    case RelaySettingsKey.anyApp: RelayAnyAppSettings(controller: controller)
    case RelaySettingsKey.reminders: RelayRemindersSettings(relay: relay)
    case RelaySettingsKey.links: RelayLinksSettings(relay: relay)
    case RelaySettingsKey.downloads: RelayDownloadsSettings()
    default: RelayRecipesSettings(relay: relay)
    }
  }
}

/// Settings › Assistants itself (board 14).
private struct RelayAssistantsPage: View {
  enum Part { case assistants, everyAssistant }
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var agent: AgentModel
  let controller: RelayController
  let part: Part
  @AppStorage(SessionStatusTexts.enabledKey) private var sessionUpdates = true
  @GateStorage(SessionReading.key, unreadable: false) private var readsChats = true

  var body: some View {
    switch part {
    case .assistants:
      SettingsRowList("Your assistants") {
        ForEach(relay.team.profiles) { profile in
          RelayAssistantRow(relay: relay, hub: relay.agent.hub, profile: profile)
        }
        AddProfileField(relay: relay)
      }
    case .everyAssistant:
      SettingsRowList("For every assistant") { everyAssistant }
    }
  }

  @ViewBuilder private var everyAssistant: some View {
    SettingsSwitchRow(
      title: "Morning brief", answer: "Every day at 9", isOn: Binding(get: { relay.briefing }, set: { relay.briefing = $0 }),
      label: "Morning brief at 9", info: RelayAssistantsPage.briefNote
    ) {
      SettingsGlyphTile(systemName: "sunrise")
    }
    SettingsSwitchRow(
      title: "Updates from your AI apps", answer: "When a chat finishes or needs you",
      isOn: $sessionUpdates, label: "Text me when a chat in another AI app finishes or needs me",
      info: "When AI-chat reading is on, your selected AI helper explains the request, final report and recorded actions. This uses provider usage. It keeps limitations visible; interpreting a report is not independent verification. Pending updates survive a restart."
    ) {
      SettingsGlyphTile(systemName: "bubble.left.and.text.bubble.right")
    }
    SettingsSwitchRow(
      title: "Read your AI chats", answer: "To learn about you and catch you up",
      isOn: $readsChats, label: "Let Serein read your chats with your AI apps on this Mac",
      info: "Serein's assistant can read your chats with Claude Code, Codex and your other AI apps on this Mac, through your AI app, which uses some of its usage. It keeps what matters as notes you can change in Library. Turn this off and it stops reading them."
    ) {
      SettingsGlyphTile(systemName: "text.bubble")
    }
    SettingsSwitchRow(
      title: "Suggest routines", answer: "Offers a routine for what you ask for often",
      isOn: Binding(get: { relay.suggestsRoutines }, set: { relay.suggestsRoutines = $0 }), info: RelayAssistantsPage.suggestNote
    ) {
      SettingsGlyphTile(systemName: "sparkles")
    }
    SettingsSwitchRow(
      title: "Tell me when tasks finish", answer: "A sentence or two when a task Serein started ends",
      isOn: Binding(get: { relay.reportsFinishedWork }, set: { relay.reportsFinishedWork = $0 }),
      info: "Serein checks each task it started when it finishes and tells you the result in a sentence or two. Each report is one short reply from your AI app."
    ) {
      SettingsGlyphTile(systemName: "flag")
    }
  }

  static let briefNote = "Once a day Serein checks your calendar, reminders and tasks and tells you what matters in a few sentences. When approvals are still open, it starts with Waiting on you: each one, with Go to card to find it in the chat. You answer those on their cards, never from the brief. Nothing runs that sends, deletes or pays; it reads, then reports. While this is on, it is the day's only morning brief."
  static let suggestNote = "When you ask for the same kind of thing at about the same time on 3 days, Serein offers to make it a routine. It makes nothing until you press Make it. You can also say “stop suggesting routines”."
}

/// One assistant's row: its face (moving by its state), its name, and its job and state.
private struct RelayAssistantRow: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var hub: AgentHub
  let profile: RelayProfile
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var surface = SereinSurface.main
  @Environment(\.settingsNavigation) private var nav
  @Environment(\.palette) private var p
  var body: some View {
    let status: SereinStatus = relay.assistantStatus(
      profile.id, hub: hub, online: SereinSurface.online(network.online), connected: SereinSurface.connected(relay.agent),
      unread: surface.unread)
    let words: String = AssistantSettingsWords.row(relay: relay, profile: profile, status: status)
    let tone: Color? = status == .needsYou ? p.warning : nil
    SettingsSummaryRow(title: profile.name, answer: words, tone: tone, open: { nav.push(profile.id) }) {
      AssistantMark(profile: profile, size: 28, status: status)
    }
  }
}

/// Settings › Assistants › Ask from any app: ⌥Space in every app, the menu bar, and the two keys.
struct RelayAnyAppSettings: View {
  let controller: RelayController?
  @Environment(\.palette) var p
  @AppStorage(RelayOrchestrator.enabledKey) private var enabled = false
  @AppStorage(RelayOrchestrator.menuBarKey) private var menuBar = false
  @AppStorage(RelayOrchestrator.summonKey) private var summon = RelayHotKey.summon
  @AppStorage(RelayOrchestrator.killKey) private var kill = RelayHotKey.killSwitch
  @AppStorage(RelayController.fnCallKey) private var fnCall = true
  @AppStorage(VoiceRoute.settingKey) private var voiceRouting = true
  @AppStorage(AssistantDock.enabledKey) private var dock = false
  @GateStorage(ScreenContext.enabledKey) private var screenContext = false
  @GateStorage(ScreenContext.pictureKey) private var screenPicture = false
  @GateStorage(ScreenTrail.enabledKey) private var screenTrail = false
  /// What macOS lets Serein do, read when the page appears and again on Check again.
  @State private var accessibilityOn = true
  @State private var screenRecordingOn = true
  @State private var globeUsage = GlobeConflict.current()
  @State private var summonDraft = ""
  @State private var killDraft = ""
  @State private var shortcutError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Ask from any app", sentence: "Reach Serein from every app, and keep it in the menu bar.")
      // The two opt-ins: ⌥Space in every app, and (without it) staying in the menu bar.
      SettingsBlock("From any app", info: enabled ? callInfo : nil) {
        Toggle("Ask Serein from any app with \(RelayHotKey.symbols(summon))", isOn: Binding(get: { enabled }, set: { on in
          enabled = on
          RelayController.shared?.install()
        }))
        SettingsNote("Serein stays in the menu bar, so \(RelayHotKey.symbols(summon)) works with this window closed.")
        if enabled { fnRow }
        if enabled { voiceRow }
        if !enabled {
          Toggle("Keep Serein in the menu bar when you close this window", isOn: Binding(get: { menuBar }, set: { on in
            menuBar = on
            RelayController.shared?.install()
          }))
          SettingsNote("Serein keeps running, so requests and alerts still happen.")
        }
      }
      if enabled { SettingsBlock("What Serein can see", info: Self.seesInfo) { screenRow } }
      SettingsBlock("On your screen") {
        Toggle("Keep your assistants at the edge of the screen", isOn: Binding(get: { dock }, set: { on in
          dock = on
          RelayController.shared?.install()
        }))
        SettingsNote("Each face shows when an assistant is working or needs you. Click one to chat, or drop a file on its chat.")
      }
      SettingsBlock("Shortcuts") { shortcuts }
    }.onAppear {
      summonDraft = summon
      killDraft = kill
      accessibilityOn = MacControl.accessibilityGranted(prompt: false)
      screenRecordingOn = CGPreflightScreenCaptureAccess()
    }
  }

  @ViewBuilder private var fnRow: some View {
    Toggle("Call Serein with the Fn key", isOn: Binding(get: { fnCall }, set: { on in
      fnCall = on
      RelayController.shared?.install()
    }))
    SettingsNote("Tap Fn to write. Hold it to talk and let go to send. Serein sees only that Fn is down, never what you type.")
    if fnCall, let warning = GlobeConflict.warning(for: .fn, usage: globeUsage) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        InterfaceIcon(systemName: "exclamationmark.triangle", size: 13).foregroundStyle(p.warning)
        Text(warning).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Check again") { globeUsage = GlobeConflict.current() }.buttonStyle(QuietButton())
      }.font(UIStyle.meta)
    }
  }

  @ViewBuilder private var voiceRow: some View {
    Toggle("Send what you say to the assistant it fits", isOn: $voiceRouting)
    SettingsNote("Hold \(RelayHotKey.symbols(summon))\(fnCall ? " or Fn" : "") and say the task. It goes to the assistant it fits or the one you name, or else to Serein.")
  }

  private var callInfo: String {
    "Tap \(RelayHotKey.symbols(summon))\(fnCall ? " or Fn" : "") to write to Serein. Hold it to talk, and let go to send. With “Send what you say to the assistant it fits” on, a task that is clearly one assistant's job goes to that assistant and anything else goes to Serein, which answers or hands it on. You can say a name (“Scout, find fares”), or ask for a new assistant and Serein makes one. The bar shows who has your words."
      + (fnCall ? " Fn with another key does nothing here, and while Serein is in front with hold to talk on, Fn types into your field instead." : "")
  }
  static let seesInfo =
    "Each switch is off until you turn it on. While you hold the key, Serein notes the app you are in, the text you selected, and what your pointer rests on, circles or underlines. A file under the pointer (on the Desktop, in Finder, or the document a window shows) goes along too. The picture is of the window you were in when you let go, with a ring round what you marked. The apps and windows you were just in are kept as names only: no text, no pictures, no keys, and for a browser only its name. They stay in memory for ten minutes, are never saved by Serein, and are forgotten when you turn the switch off. A message that carries them is treated like one that read a web page: what you ask it to remember stays with that assistant, and its first use of a connected app asks you. Serein never reads a password field or a password manager. What it takes goes to your AI app, and only with a message you send; your AI app keeps it in its own history, as it does your words."

  /// macOS asks for its own permission the first time a switch is turned on; nothing is asked again
  /// while the key is held.
  @ViewBuilder private var screenRow: some View {
    Toggle("Share what I select or point at while I talk", isOn: Binding(get: { screenContext }, set: { on in
      screenContext = on
      if on { accessibilityOn = MacControl.accessibilityGranted(prompt: true) } else { screenPicture = false }
    }))
    SettingsNote("Serein reads them only while you hold the key and sends them to your AI app with your words. Never a password field or a password manager.")
    if screenContext, !accessibilityOn {
      permissionLine(
        "macOS has not let Serein read other apps yet. Drag Serein into Accessibility.", grant: .accessibility
      ) { accessibilityOn = MacControl.accessibilityGranted(prompt: false) }
    }
    if screenContext {
      Toggle("Include a picture of that window", isOn: Binding(get: { screenPicture }, set: { on in
        screenPicture = on
        if on { screenRecordingOn = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() }
      }))
      SettingsNote("For charts, pictures and anything that is not text. Only that window, never the whole screen.")
      if screenPicture, !screenRecordingOn {
        permissionLine(
          "macOS has not let Serein take pictures of windows yet. Drag Serein into Screen & System Audio Recording.",
          grant: .screen
        ) { screenRecordingOn = CGPreflightScreenCaptureAccess() }
      }
    }
    Toggle("Remember the apps and windows I was just in", isOn: Binding(get: { screenTrail }, set: { on in
      if on {
        ScreenTrailWatch.turnOn()
        accessibilityOn = MacControl.accessibilityGranted(prompt: false)
      } else { ScreenTrailWatch.turnOff() }
    }))
    SettingsNote("Only their names, from the last ten minutes, go to your AI app with a message from the bar. Never a browser's page or a password manager, and Serein saves none of it.")
    if screenTrail, !screenContext, !accessibilityOn {
      permissionLine(
        "macOS has not let Serein read window names yet. Drag Serein into Accessibility.", grant: .accessibility
      ) { accessibilityOn = MacControl.accessibilityGranted(prompt: false) }
    }
  }
  private func permissionLine(_ words: String, grant: MacAccess.Grant, recheck: @escaping () -> Void) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      InterfaceIcon(systemName: "exclamationmark.triangle", size: 13).foregroundStyle(p.warning)
      Text(words).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Open System Settings") { MacAccess.openSettings(grant) }.buttonStyle(QuietButton())
      Button("Check again", action: recheck).buttonStyle(QuietButton())
    }.font(UIStyle.meta)
  }

  /// Keys to pick instead of writing one: each works from any app, and is held to talk.
  private static let summonChoices: [(title: String, value: String)] = [
    ("⌥Space", "opt+space"), ("⌃Space", "ctrl+space"), ("⌃⌥Space", "ctrl+opt+space"), ("⇧⌘Space", "shift+cmd+space"),
    ("F5", "f5"), ("F6", "f6"), ("F13", "f13"),
  ]
  @ViewBuilder private var summonPicker: some View {
    HStack {
      Text("Pick a key")
      Spacer()
      Menu(Self.summonChoices.first { $0.value == summon }?.title ?? "Your own") {
        ForEach(Self.summonChoices.indices, id: \.self) { index in
          Button(Self.summonChoices[index].title) {
            summon = Self.summonChoices[index].value
            summonDraft = summon
            shortcutError = nil
            RelayController.shared?.install()
          }
        }
      }.fixedSize().accessibilityLabel("Pick a key for Ask Serein")
    }
  }

  @ViewBuilder private var shortcuts: some View {
    if controller?.summonTaken == true {
      HStack {
        Text("Another app already uses \(RelayHotKey.symbols(summon)). Serein is in the menu bar meanwhile.")
          .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Use ⌃⌥Space") {
          summon = "ctrl+opt+space"
          summonDraft = summon
          controller?.install()
        }
      }
    }
    summonPicker
    shortcutRow("Ask Serein", draft: $summonDraft, value: $summon)
    shortcutRow("Stop everything", draft: $killDraft, value: $kill)
    if let shortcutError { Text(shortcutError).role(.meta).foregroundStyle(p.danger) }
    if !enabled {
      // Without ⌥Space the global keys are not registered; say where each one still works.
      SettingsNote("These work once “Ask Serein from any app” is on. Stop everything is also in the File menu.")
    }
    SettingsNote("Or write your own, such as opt+space or ctrl+shift+k. A function key such as f5 works alone; on a Mac laptop, turn on standard function keys in System Settings › Keyboard.")
  }

  private func shortcutRow(_ title: String, draft: Binding<String>, value: Binding<String>) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(RelayHotKey.symbols(value.wrappedValue)).font(UIStyle.monoMeta).foregroundStyle(p.secondary)
      TextField("", text: draft).textFieldStyle(.serein).frame(width: 160)
        .accessibilityLabel("\(title) shortcut")
        .onSubmit {
          guard RelayHotKey.parse(draft.wrappedValue) != nil else {
            shortcutError = "“\(draft.wrappedValue)” is not a shortcut."
            return
          }
          shortcutError = nil
          value.wrappedValue = draft.wrappedValue.lowercased()
          RelayController.shared?.install()
        }
    }
  }
}

/// Settings › Assistants › Task downloads. Every agent task's downloads, Serein's or not: off
/// unless the person turns it on (TaskShelf).
struct RelayDownloadsSettings: View {
  @GateStorage(TaskDownloadPolicy.enabledKey) private var taskDownloads = false
  static let info =
    "The first file from each site asks you, in every task. Files wait unopened on the task until you keep them, which moves them to Downloads; the rest are deleted with the task. Apps, disk images, installers, scripts and archives are always refused, and scheduled requests never download."
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Task downloads", sentence: "Choose whether tasks may download files.")
      SettingsBlock("Downloads", info: Self.info) {
        Toggle("Let tasks download files", isOn: $taskDownloads)
        SettingsNote("The first file from each site asks you. Files wait unopened until you keep them. Apps, disk images, installers, scripts and archives are always refused, and scheduled requests never download.")
      }
    }
  }
}

/// Settings › Assistants › Asks first: what every assistant asks about first. Only risky steps
/// shows its confirmation first (RelayController.setLevel).
struct RelayAsksSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  /// On an assistant's page: the level is the same for every assistant, and the page says so.
  var shared = false
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader(
        "Asks first",
        sentence: shared ? "The same for every assistant. A change here changes it for all of them."
          : "Choose what every assistant asks you about before it acts.")
      SettingsBlock("Serein asks before") {
        AskBeforeControl(relay: relay, controller: controller)
        // The footnote holds for both choices, so a hairline sets it apart from the last note.
        Divider().overlay(p.line).padding(.vertical, 4)
        SettingsNote(ApprovalLevel.footnote(killLabel: controller.killLabel))
      }
    }
  }
}

/// Settings › Assistants › Default AI app: the app Serein, and every assistant without an AI app
/// of its own, thinks with ("Serein thinks with"), each with its logo.
private struct RelayDefaultAppSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var agent: AgentModel
  @Environment(\.palette) var p
  private var providers: [Provider] { Provider.allCases.filter { $0.thinksForSerein && agent.available[$0] != nil } }
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader(
        "Default AI app",
        sentence: "Serein uses this AI app's sign-in, like any task. The tasks it starts use it too unless Serein picks another.")
      SettingsRowList("Serein thinks with", note: providers.isEmpty ? nil : "An assistant with its own AI app keeps it. Choose one on its page.") {
        if providers.isEmpty {
          SettingsEmptyRow(glyph: "terminal", text: "No AI app on this Mac can think for Serein yet. Set one up in Settings › AI apps.")
        }
        ForEach(providers) { provider in providerRow(provider) }
      }
    }
  }
  private func providerRow(_ provider: Provider) -> some View {
    let chosen: Bool = relay.provider == provider
    return Button { relay.provider = provider } label: {
      SettingsListRow(name: provider.name, status: chosen ? "Used now" : "Not used", expandable: false) {
        SettingsLogoTile(provider: provider)
      } trailing: {
        InterfaceIcon(systemName: "checkmark", size: 13).foregroundStyle(p.ink).opacity(chosen ? 1 : 0)
      } live: {
        EmptyView()
      } details: {
        EmptyView()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(provider.name)
    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
  }
}

/// Settings › Assistants › Teams: each team with its members and lead, Delete Team (it asks once
/// and says what is kept), New team…, and the recent changes to assistants and teams with Undo.
private struct RelayTeamsSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  /// The team waiting on its delete confirmation.
  @State private var removingTeam: AssistantGroup?
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Teams", sentence: "Assistants hand work only to others in a team they share.")
      SettingsRowList("Your teams") {
        if relay.team.teams.isEmpty {
          SettingsEmptyRow(glyph: "person.3", text: "No teams yet. Ask Serein to “make a team that …”, or make one here.")
        }
        ForEach(relay.team.teams) { group in teamRow(group) }
        SettingsSummaryRow(title: "New team…", answer: "Pick a starter, or make your own", hint: "Opens the new team sheet", open: {
          TeamSheets.shared.present(.newTeam(.home))
        }) {
          SettingsGlyphTile(systemName: "plus")
        }
      }
      if !relay.teamJournal.isEmpty { recentChanges }
    }
    // Delete asks once and says what is kept.
    .confirmationDialog(
      "Delete the team \(removingTeam?.name ?? "")?",
      isPresented: Binding(get: { removingTeam != nil }, set: { if !$0 { removingTeam = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete Team", role: .destructive) {
        if let group = removingTeam { relay.removeGroup(group.id) }
        removingTeam = nil
      }
    } message: {
      Text("Its assistants stay, with their chats and notes.")
    }
  }
  private func teamRow(_ group: AssistantGroup) -> some View {
    let members: String = group.memberIDs.map { (id: String) -> String in
      let lead: String = id == group.leadID ? " (lead)" : ""
      return relay.profileName(id) + lead
    }.joined(separator: ", ")
    return SettingsListRow(name: group.name, status: members, expandable: false) {
      SettingsGlyphTile(systemName: "person.3")
    } trailing: {
      Button("Delete Team") { removingTeam = group }.buttonStyle(QuietButton())
        .help("Deletes the team \(group.name). Its assistants stay.")
        .accessibilityLabel("Delete the team \(group.name); its assistants stay")
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }
  private var recentChanges: some View {
    SettingsBlock("Recent changes to assistants and teams") {
      ForEach(relay.teamJournal.suffix(6).reversed(), id: \.id) { entry in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.text).lineLimit(2)
            Text("\(entry.actor == "user" ? "You" : "Serein") · \(entry.at.formatted(date: .omitted, time: .shortened))").role(.meta)
          }
          Spacer()
          Button("Undo") { relay.undoTeam(entry) }.controlSize(.small)
            .disabled(RelayJournal.undoneTeam(entry, current: relay.team) == nil)
            .help("Puts the assistants and teams back as they were before this change. Undo newer changes first.")
            .accessibilityLabel("Undo: \(entry.text)")
        }
      }
    }
  }
}

/// Settings › Assistants › Your reminders: the reminders, requests, goals and alerts that belong
/// to no assistant (`profileID` nil), with their recent changes. Over them, the day line: every
/// schedule's runs around now, assistants' too, each opening its schedule's editor.
private struct RelayRemindersSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  /// The schedule a mark on the day line opened, until its editor closes.
  @State private var opened: RelayReminder?
  var body: some View {
    let all: [RelayReminder] = relay.reminders + UIPreview.affectSchedules
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Your reminders", sentence: "What runs for you on its own, and belongs to no assistant.")
      if all.contains(where: { !TodoBoard.isReminder($0.id) }) {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          ScheduleDayLine(marks: ScheduleDay.marks(all, now: context.date), now: context.date,
                          owner: { id in owner(of: id, in: all) },
                          open: { id in opened = all.first { $0.id == id } })
        }
      }
      RoutineSettings(relay: relay, owner: nil, name: "Serein")
    }
    .sheet(item: $opened) { reminder in
      ReminderEditor(relay: relay, reminder: reminder) { opened = nil }.environment(\.palette, p)
    }
  }
  private func owner(of id: String, in all: [RelayReminder]) -> String? {
    guard let profileID = all.first(where: { $0.id == id })?.profileID else { return nil }
    return relay.team.profiles.first { $0.id == profileID }?.name
  }
}

/// Settings › Assistants › Links from other apps: whether this Mac accepts links, your own links
/// with Remove, and Add (its secret shown once). Links an assistant owns are on its page.
private struct RelayLinksSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  @State private var newHookName = ""
  @State private var newHookSecret: String?
  /// The system could not make a random secret, so the last Add hook made nothing.
  @State private var hookFailed = false
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Links from other apps", sentence: "Let other apps on this Mac start Serein with a private address.")
      SettingsBlock("Webhooks", info: "Reaching the receiver from outside this Mac needs a tunnel you set up. Links an assistant owns are on that assistant's page.") { webhooks }
    }
  }
  @ViewBuilder private var webhooks: some View {
    Toggle("Accept webhooks on this Mac", isOn: Binding(
      get: { RelayHookServer.enabled },
      set: { RelayHookServer.enabled = $0; relay.runHookServer() }))
    SettingsNote(
      "Anything on this Mac can wake Serein with a POST to http://127.0.0.1:\(RelayHook.port)\(RelayHook.path)/<secret>. It listens on this Mac only.")
    if RelayHookServer.enabled {
      if relay.hookRegistry.isEmpty {
        Text("No hooks yet.").role(.meta)
      } else {
        ForEach(relay.hookRegistry, id: \.id) { hook in
          HStack {
            InterfaceIcon(systemName: "bolt.horizontal", size: 12).foregroundStyle(p.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(hook.name)
              Text(hook.createdAt.formatted(date: .abbreviated, time: .omitted)).role(.meta)
            }
            Spacer()
            Button("Remove") { relay.removeHook(hook.id) }.controlSize(.small)
          }
        }
      }
      HStack {
        TextField("Name (e.g. deploy-done)", text: $newHookName).controlSize(.small)
        Button("Add hook") {
          let name = newHookName.trimmingCharacters(in: .whitespaces)
          guard !name.isEmpty else { return }
          newHookSecret = relay.addHook(name: name)
          hookFailed = newHookSecret == nil
          if !hookFailed { newHookName = "" }
        }.controlSize(.small)
      }
      if hookFailed {
        SettingsNote("Serein couldn’t make a secure secret, so no hook was added. Try again.")
      }
      if let secret = newHookSecret {
        SettingsNote(
          "Copy the secret now — Serein keeps only its fingerprint and cannot show it again:\n\(secret)")
      }
    }
  }
}

/// Settings › Assistants › Recipes and shortcuts.
private struct RelayRecipesSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Recipes and shortcuts", sentence: "What you taught Serein once, and words you use often.")
      RecipeSettings(relay: relay)
      ShortcutSettings()
    }
  }
}

/// The schedules, goals and alerts of one owner (an assistant's id, or nil for the person's own),
/// each with Edit, Pause, Run now, Delete and its history; New goal for that owner; and the recent
/// changes to them with Undo. Each change applies at once and is listed with its Undo.
struct RoutineSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let owner: String?
  /// Who the empty lines name: "Serein", or the assistant's name.
  let name: String
  @Environment(\.palette) var p
  /// The goal New goal is making, until it is saved or cancelled.
  @State private var goalDraft: RelayReminder?
  private var mine: [RelayReminder] { relay.reminders.filter { $0.profileID == owner } }
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      goals
      SettingsBlock("Reminders and scheduled requests", info: "Scheduled requests run on this Mac while it is awake and Serein is open, in its window or the menu bar. Closing the lid puts the Mac to sleep: a run it missed waits in Serein's chat with Run now and Skip. Settings › General can open Serein when you log in.") {
        SettingsNote("Scheduled requests run while this Mac is awake and Serein is open. A run it missed waits in Serein's chat with Run now and Skip.")
        let plain: [RelayReminder] = mine.filter { $0.goal == nil }
        if plain.isEmpty {
          let empty: String = owner == nil ? "Nothing scheduled. Ask Serein to remind you." : "Nothing scheduled. Ask \(name) in its chat to set one up."
          Text(verbatim: empty).role(.meta)
        } else {
          ForEach(plain.sorted { $0.due < $1.due }, id: \.id) { reminder in
            ReminderRow(relay: relay, reminder: reminder)
          }
        }
      }
      SettingsBlock("Alerts") {
        let watches: [RelayWatch] = relay.watches.filter { $0.profileID == owner }
        if watches.isEmpty {
          let empty: String = owner == nil ? "Nothing watched. Ask Serein to tell you when something changes." : "Nothing watched. Ask \(name) to tell you when something changes."
          Text(verbatim: empty).role(.meta)
        } else {
          ForEach(watches, id: \.id) { watch in
            WatchRow(relay: relay, watch: watch)
          }
        }
      }
      recentChanges
    }
    .sheet(isPresented: Binding(get: { goalDraft != nil }, set: { if !$0 { goalDraft = nil } })) {
      if let goalDraft {
        ReminderEditor(relay: relay, reminder: goalDraft, creating: true) { self.goalDraft = nil }.environment(\.palette, p)
      }
    }
  }
  private var goals: some View {
    SettingsBlock("Goals", info: "Serein checks each goal on its schedule, keeps a short progress note and tells you only what is new. Checks read; any other step asks you. A goal ends on its end date, when it is met, or when you press Done.") {
      let all: [RelayReminder] = relay.reminders.filter { $0.goal != nil }
      let owned: [RelayReminder] = mine.filter { $0.goal != nil }
      if owned.isEmpty {
        let empty: String = owner == nil ? "No goals. Ask Serein to track something that takes days, or add one here." : "No goals. Ask \(name) to track something that takes days, or add one here."
        Text(verbatim: empty).role(.meta)
      } else {
        ForEach(owned.sorted { $0.goalEnded == $1.goalEnded ? $0.due < $1.due : !$0.goalEnded }, id: \.id) { reminder in
          if let goal = reminder.goal { GoalRow(relay: relay, reminder: reminder, goal: goal) }
        }
      }
      HStack {
        Button("New goal") {
          let now = Date()
          goalDraft = RelayReminder(
            text: "", due: now.addingTimeInterval(60), repeats: .daily, action: true,
            goal: RelayGoal(ends: now.addingTimeInterval(RelayGoal.defaultSpan)), profileID: owner)
        }.controlSize(.small)
          .disabled(all.count >= RelayGoal.maxGoals)
          .accessibilityLabel("Add a goal")
        Spacer()
      }
      SettingsNote("Serein checks each goal on its schedule and tells you only what is new. Checks only read; any other step asks you.")
    }
  }
  /// The recent changes to this owner's schedules: the owner of the item before the change, or of
  /// the item now when the change added it.
  @ViewBuilder private var recentChanges: some View {
    let changes: [RelayScheduleChange] = relay.scheduleChanges.filter { changeOwner($0) == owner }
    if !changes.isEmpty {
      SettingsBlock("Recent changes to schedules") {
        ForEach(changes.suffix(8).reversed(), id: \.id) { change in
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
              Text(change.summary).lineLimit(1)
              Text("\(change.actor == "user" ? "You" : "Serein") · \(change.at.formatted(date: .omitted, time: .shortened))")
                .role(.meta)
            }.accessibilityElement(children: .combine)
            Spacer()
            Button("Undo") { relay.undoSchedule(change) }.controlSize(.small)
              .accessibilityLabel("Undo: \(change.summary)")
          }
        }
      }
    }
  }
  private func changeOwner(_ change: RelayScheduleChange) -> String? {
    if let before = change.reminder { return before.profileID }
    if let before = change.watch { return before.profileID }
    if let now = relay.reminders.first(where: { $0.id == change.itemID }) { return now.profileID }
    return relay.watches.first(where: { $0.id == change.itemID })?.profileID
  }
}

/// One reminder or scheduled request: when it runs next, its state, and the person's own
/// controls. Each change applies at once, needs no card (the person is the one deciding) and
/// lands in Recent changes to schedules, where it can be undone.
struct ReminderRow: View {
  @ObservedObject var relay: RelayOrchestrator
  let reminder: RelayReminder
  @Environment(\.palette) var p
  @Environment(\.dismiss) private var dismiss
  @State private var editing = false
  @State private var showHistory = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        InterfaceIcon(systemName: reminder.action ? "bolt" : "bell", size: 12).foregroundStyle(p.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(reminder.text)
          Text(timing).role(.meta)
          if let last = reminder.history?.last {
            Text("Last run \(last.at.formatted(date: .abbreviated, time: .shortened)): \(last.title)").role(.meta)
          }
          if reminder.paused == true, reminder.pausedByUpdate == true {
            Text("Paused by an update, because it did not run while Serein was off. Resume it to run it again.")
              .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if reminder.paused == true, reminder.pausedByCost == true {
            Text(RelayOrchestrator.costPauseLine(reminder) + " Resume to run it now, or change the limit in Edit.")
              .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if reminder.paused == true, reminder.limitReached, let limit = reminder.limit {
            Text("Stopped after \(limit) run\(limit == 1 ? "" : "s"). Resume to run it \(limit) more, or change the limit in Edit.")
              .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if reminder.paused == true, (reminder.failures ?? 0) >= RelayUnattended.failureLimit {
            Text("Paused after \(reminder.failures ?? RelayUnattended.failureLimit) failed attempts").role(.meta)
              .foregroundStyle(p.warning)
          } else if reminder.paused != true, let result = reminder.lastResult {
            Text("Last: \(result)").role(.meta).lineLimit(1)
          }
        }.accessibilityElement(children: .combine)
        Spacer()
        Button("Edit") { editing = true }.controlSize(.small)
          .accessibilityLabel("Edit \(reminder.text)")
        if reminder.paused == true {
          Button("Resume") { relay.resumeSchedule(reminder) }.controlSize(.small)
            .accessibilityLabel("Resume \(reminder.text)")
        } else {
          Button("Pause") { relay.pauseSchedule(reminder) }.controlSize(.small)
            .accessibilityLabel("Pause \(reminder.text)")
        }
        if reminder.action {
          Button("Run now") { relay.runNow(reminder) }.controlSize(.small)
            .disabled(reminder.limitReached || relay.state.paused)
            .help(relay.state.paused
              ? "Serein is stopped. Resume it first."
              : "Runs once now, under the same rules as a timed run: steps still ask.")
            .accessibilityLabel("Run \(reminder.text) now")
        }
        Button("Delete") {
          relay.changeReminder(reminder.id, "Deleted \(RelayOrchestrator.short(reminder.text))") { $0 = nil }
        }.controlSize(.small)
          .accessibilityLabel("Delete \(reminder.text)")
      }
      if let history = reminder.history, !history.isEmpty {
        DisclosureGroup(isExpanded: $showHistory) {
          ScheduleHistory(runs: history) { thread in
            dismiss()
            SereinRouter.open(threadID: thread)
          }
        } label: {
          Text("History").role(.meta)
            .accessibilityLabel("History of \(reminder.text), \(history.count) run\(history.count == 1 ? "" : "s")")
        }.padding(.leading, 20)
      }
    }
    .sheet(isPresented: $editing) {
      ReminderEditor(relay: relay, reminder: reminder) { editing = false }.environment(\.palette, p)
    }
    .onAppear {
      // `--ui-schedule-editor <id>`: a preview opens this schedule's editor.
      if RunMode.previewing,
        CommandLine.arguments.drop(while: { $0 != "--ui-schedule-editor" }).dropFirst().first == reminder.id {
        editing = true
      }
    }
  }
  /// “Next: Tue, Oct 28, 9:00 AM · Weekdays · stops after 3 runs (1 so far) · ~9k tokens a run ·
  /// 27k of 50k this week”, or Paused.
  private var timing: String {
    var parts = [reminder.paused == true ? "Paused" : "Next: " + ScheduleHistory.when(reminder.due)]
    if reminder.repeats != .none { parts.append(reminder.scheduleTitle) }
    if let limit = reminder.limit { parts.append("stops after \(limit) run\(limit == 1 ? "" : "s") (\(reminder.runs ?? 0) so far)") }
    if let average = reminder.averageTokens { parts.append("~\(UsageLedger.Summary.short(average)) tokens a run") }
    if let week = RelayOrchestrator.weekLine(reminder) { parts.append(week) }
    return parts.joined(separator: " · ")
  }
}

/// One ongoing goal: what it is after, how its checks went, what they found (page text, said so),
/// its progress note, why it ended, and the person's own controls, as ReminderRow.
struct GoalRow: View {
  @ObservedObject var relay: RelayOrchestrator
  let reminder: RelayReminder
  let goal: RelayGoal
  @Environment(\.palette) var p
  @Environment(\.dismiss) private var dismiss
  @State private var editing = false
  @State private var showFindings = false
  @State private var showHistory = false

  var body: some View {
    let now = Date()
    let fresh = goal.fresh(now: now).count
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        InterfaceIcon(systemName: "target", size: 12).foregroundStyle(p.secondary).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(reminder.text)
          Text(counts(fresh: fresh)).role(.meta)
          Text(timing).role(.meta)
          if let ended = goal.ended {
            Text(verbatim: "Ended: " + ended).role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if reminder.paused == true, reminder.pausedByUpdate == true {
            Text("Paused by an update, because it did not run while Serein was off. Resume it to check again.")
              .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if reminder.paused == true, reminder.pausedByCost == true {
            Text(RelayOrchestrator.costPauseLine(reminder) + " Resume to check now, or change the limit in Edit.")
              .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if reminder.paused == true, reminder.limitReached, let limit = reminder.limit {
            Text("Stopped after \(limit) check\(limit == 1 ? "" : "s"). Resume to check \(limit) more, or change the limit in Edit.")
              .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if reminder.paused == true, (reminder.failures ?? 0) >= RelayUnattended.failureLimit {
            Text("Paused after \(reminder.failures ?? RelayUnattended.failureLimit) failed checks").role(.meta)
              .foregroundStyle(p.warning)
          }
          if let note = goal.note {
            Text(verbatim: "Progress: " + note).role(.meta).lineLimit(3).fixedSize(horizontal: false, vertical: true)
          }
        }.accessibilityElement(children: .combine)
        Spacer()
        Button("Edit") { editing = true }.controlSize(.small)
          .accessibilityLabel("Edit goal \(reminder.text)")
        if goal.ended == nil {
          if reminder.paused == true {
            Button("Resume") { relay.resumeSchedule(reminder) }.controlSize(.small)
              .accessibilityLabel("Resume goal \(reminder.text)")
          } else {
            Button("Pause") { relay.pauseSchedule(reminder) }.controlSize(.small)
              .accessibilityLabel("Pause goal \(reminder.text)")
          }
          Button("Check now") { relay.runNow(reminder) }.controlSize(.small)
            .disabled(reminder.paused == true || relay.state.paused)
            .help(relay.state.paused
              ? "Serein is stopped. Resume it first."
              : "Checks once now, under the same rules as a timed check: steps beyond reading still ask.")
            .accessibilityLabel("Check goal \(reminder.text) now")
          Button("Done") { relay.endGoal(reminder) }.controlSize(.small)
            .help("Ends the goal now. Its findings stay here.")
            .accessibilityLabel("Mark goal \(reminder.text) done")
        } else if goal.ends > now {
          Button("Resume") { relay.resumeSchedule(reminder) }.controlSize(.small)
            .help("Starts checking again until its end date.")
            .accessibilityLabel("Resume goal \(reminder.text)")
        }
        Button("Delete") {
          relay.changeReminder(reminder.id, "Deleted goal \(RelayOrchestrator.short(reminder.text))") { $0 = nil }
        }.controlSize(.small)
          .accessibilityLabel("Delete goal \(reminder.text)")
      }
      if let findings = goal.findings, !findings.isEmpty {
        DisclosureGroup(isExpanded: $showFindings) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Written from web pages Serein read; check them before you act.").role(.meta)
            ForEach(Array(findings.enumerated().reversed()), id: \.offset) { _, finding in
              HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  if now.timeIntervalSince(finding.at) < 86_400 { Text("New").role(.meta).foregroundStyle(p.accent) }
                  Text(ScheduleHistory.when(finding.at)).font(UIStyle.monoMeta)
                  Text(verbatim: finding.text).lineLimit(2)
                }.accessibilityElement(children: .combine)
                Spacer()
                if let link = finding.link {
                  Button("Open") {
                    dismiss()
                    relay.browser.openInDefaultBrowser(link)
                    SereinRouter.bringWindowForward?()
                  }.controlSize(.small)
                    .help(link)
                    .accessibilityLabel("Open the page of the finding from \(ScheduleHistory.when(finding.at))")
                }
              }
            }
          }.padding(.top, 4)
        } label: {
          Text("Findings").role(.meta)
            .accessibilityLabel("Findings of goal \(reminder.text), \(findings.count), \(fresh) new")
        }.padding(.leading, 20)
      }
      if let history = reminder.history, !history.isEmpty {
        DisclosureGroup(isExpanded: $showHistory) {
          ScheduleHistory(runs: history) { thread in
            dismiss()
            SereinRouter.open(threadID: thread)
          }
        } label: {
          Text("History").role(.meta)
            .accessibilityLabel("History of goal \(reminder.text), \(history.count) check\(history.count == 1 ? "" : "s")")
        }.padding(.leading, 20)
      }
    }
    .sheet(isPresented: $editing) {
      ReminderEditor(relay: relay, reminder: reminder) { editing = false }.environment(\.palette, p)
    }
  }
  /// “Checked 5 times · 2 new since yesterday”.
  private func counts(fresh: Int) -> String {
    let checks = goal.checks ?? 0
    guard checks > 0 else { return "Not checked yet" }
    return "Checked \(checks) time\(checks == 1 ? "" : "s") · \(fresh) new since yesterday"
  }
  /// “Next check: Tue, Oct 28, 9:00 AM · Daily · until Nov 26”, or Paused, or the day it ended.
  private var timing: String {
    let until = "until " + goal.ends.formatted(date: .abbreviated, time: .omitted)
    if goal.ended != nil { return "Ended · was " + reminder.scheduleTitle.lowercased() + ", " + until }
    let next = reminder.paused == true ? "Paused" : "Next check: " + ScheduleHistory.when(reminder.due)
    return [next, reminder.scheduleTitle, until].joined(separator: " · ")
  }
}

/// One alert: what it checks, when it checks next, and the person's own controls, as ReminderRow.
struct WatchRow: View {
  @ObservedObject var relay: RelayOrchestrator
  let watch: RelayWatch
  @Environment(\.palette) var p
  @Environment(\.dismiss) private var dismiss
  @State private var editing = false
  @State private var showHistory = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        InterfaceIcon(systemName: "binoculars", size: 12).foregroundStyle(p.secondary).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(watch.name)
          Text(String(watch.source.prefix(90))).font(UIStyle.monoMeta).lineLimit(1)
          Text(timing).role(.meta)
          if let last = watch.history?.last {
            Text("Last check \(last.at.formatted(date: .abbreviated, time: .shortened)): \(last.title)").role(.meta)
          }
          if watch.paused == true, watch.pausedByUpdate == true {
            Text("Paused by an update, because it did not run while Serein was off. Resume it to check again.")
              .role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
          } else if watch.paused == true, (watch.failures ?? 0) >= RelayUnattended.failureLimit {
            Text("Paused after \(watch.failures ?? RelayUnattended.failureLimit) failed checks").role(.meta)
              .foregroundStyle(p.warning)
          }
        }.accessibilityElement(children: .combine)
        Spacer()
        Button("Edit") { editing = true }.controlSize(.small)
          .accessibilityLabel("Edit alert \(watch.name)")
        if watch.paused == true {
          Button("Resume") { relay.resumeWatch(watch) }.controlSize(.small)
            .accessibilityLabel("Resume alert \(watch.name)")
        } else {
          Button("Pause") { relay.pauseWatch(watch) }.controlSize(.small)
            .accessibilityLabel("Pause alert \(watch.name)")
        }
        Button("Check now") { relay.checkWatchNow(watch) }.controlSize(.small)
          .disabled(relay.state.paused)
          .help(relay.state.paused ? "Serein is stopped. Resume it first." : "Checks once now, the same way a timed check does.")
          .accessibilityLabel("Check alert \(watch.name) now")
        Button("Delete") {
          relay.changeWatch(watch.id, "Deleted \(RelayOrchestrator.short(watch.name))") { $0 = nil }
        }.controlSize(.small)
          .accessibilityLabel("Delete alert \(watch.name)")
      }
      if let history = watch.history, !history.isEmpty {
        DisclosureGroup(isExpanded: $showHistory) {
          ScheduleHistory(runs: history) { thread in
            dismiss()
            SereinRouter.open(threadID: thread)
          }
        } label: {
          Text("History").role(.meta)
            .accessibilityLabel("History of alert \(watch.name), \(history.count) check\(history.count == 1 ? "" : "s")")
        }.padding(.leading, 20)
      }
    }
    .sheet(isPresented: $editing) {
      WatchEditor(relay: relay, watch: watch) { editing = false }.environment(\.palette, p)
    }
  }
  /// “Next: Tue, Oct 28, 9:15 AM · every 15 min · checks are free, ~2k tokens a change”, or Paused.
  private var timing: String {
    let next = watch.lastCheckedAt.map { "Next: " + ScheduleHistory.when($0.addingTimeInterval(TimeInterval(watch.minutes) * 60)) }
      ?? "Next: soon"
    // A check reads without a model; only a change starts a turn, whose tokens its run keeps.
    let cost = watch.averageTokens.map { " · checks are free, ~\(UsageLedger.Summary.short($0)) tokens a change" } ?? ""
    return (watch.paused == true ? "Paused" : next) + " · every \(watch.minutes) min" + cost
  }
}

/// A schedule's last runs, newest first: when, what came of it, and its chat.
struct ScheduleHistory: View {
  let runs: [RelayReminder.Run]
  let open: (String) -> Void
  static func when(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(runs.enumerated().reversed()), id: \.offset) { _, run in
        HStack(alignment: .firstTextBaseline) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.when(run.at)).font(UIStyle.monoMeta)
            Text(run.title)
            if let tokens = run.tokens, tokens > 0 { Text("\(UsageLedger.Summary.short(tokens)) tokens").role(.meta) }
            if let result = run.result { Text(result).role(.meta).lineLimit(1) }
          }.accessibilityElement(children: .combine)
          Spacer()
          if let thread = run.thread {
            Button("Open chat") { open(thread) }.controlSize(.small)
              .accessibilityLabel("Open the chat of the run on \(Self.when(run.at))")
          }
        }
      }
    }.padding(.top, 4)
  }
}

/// Edit a reminder or scheduled request: its words, when it runs, and for a request how many
/// runs it may make and whether a run waits for the last one. Saved at once, undoable.
private struct ReminderEditor: View {
  let relay: RelayOrchestrator
  let reminder: RelayReminder
  /// New goal: `reminder` is a draft that the first save adds.
  var creating = false
  var close: () -> Void
  @Environment(\.palette) var p
  enum When: String, CaseIterable, Identifiable {
    case once, daily, weekdays, weekly, minutes, custom
    var id: String { rawValue }
    var title: String {
      switch self {
      case .once: return "Once"
      case .daily: return "Daily"
      case .weekdays: return "Weekdays"
      case .weekly: return "Weekly"
      case .minutes: return "Every few minutes"
      case .custom: return "Custom"
      }
    }
  }
  @State private var text: String
  @State private var when: When
  @State private var due: Date
  @State private var every: Int
  @State private var cron: String
  @State private var limited: Bool
  @State private var limit: Int
  @State private var capped: Bool
  @State private var weekly: Int
  @State private var skip: Bool
  @State private var runLate: Bool
  @State private var ends: Date
  @State private var quietOn: Bool
  @State private var quietLimit: Int
  @State private var note: String
  @State private var problem: String?

  init(relay: RelayOrchestrator, reminder: RelayReminder, creating: Bool = false, close: @escaping () -> Void) {
    self.relay = relay
    self.reminder = reminder
    self.creating = creating
    self.close = close
    let minutes = reminder.everyMinutes
    let when: When
    switch reminder.repeats {
    case .none: when = .once
    case .daily: when = .daily
    case .weekdays: when = .weekdays
    case .weekly: when = .weekly
    case .cron: when = minutes.map { RelayReminder.minuteChoices.contains($0) } == true ? .minutes : .custom
    }
    _text = State(initialValue: reminder.text)
    _when = State(initialValue: when)
    _due = State(initialValue: reminder.due)
    _every = State(initialValue: minutes.flatMap { RelayReminder.minuteChoices.contains($0) ? $0 : nil } ?? 30)
    _cron = State(initialValue: reminder.cron ?? "")
    _limited = State(initialValue: reminder.limit != nil)
    _limit = State(initialValue: reminder.limit ?? 3)
    _capped = State(initialValue: reminder.weeklyTokens != nil)
    _weekly = State(initialValue: reminder.weeklyTokens ?? 100_000)
    _skip = State(initialValue: reminder.skipsWhileBusy)
    _runLate = State(initialValue: reminder.runLate == true)
    _ends = State(initialValue: reminder.goal?.ends ?? Date())
    _quietOn = State(initialValue: reminder.goal?.quietLimit != nil)
    _quietLimit = State(initialValue: reminder.goal?.quietLimit ?? 5)
    _note = State(initialValue: reminder.goal?.note ?? "")
  }
  private var isGoal: Bool { reminder.goal != nil }
  private var heading: String {
    if isGoal { return creating ? "New goal" : "Edit goal" }
    return reminder.action ? "Edit scheduled request" : "Edit reminder"
  }
  /// The limits on offer, with one set elsewhere (by Serein, at its creation) kept in the list.
  static func weeklyChoices(including current: Int) -> [Int] {
    Array(Set(RelayReminder.weeklyTokenChoices + [current])).sorted()
  }
  /// What it costs and what the limit does, under the toggle: the estimate for the schedule as
  /// edited, then the rule.
  private var costNote: String {
    var draft = reminder
    switch when {
    case .once: draft.repeats = .none
    case .daily: draft.repeats = .daily
    case .weekdays: draft.repeats = .weekdays
    case .weekly: draft.repeats = .weekly
    case .minutes:
      draft.repeats = .cron
      draft.cron = RelayReminder.cron(everyMinutes: every)
    case .custom:
      draft.repeats = .cron
      draft.cron = cron
    }
    let estimate = relay.costEstimate(draft).map { $0 + " " } ?? ""
    return estimate + "Counts the tokens its runs use each week. Past the limit only this schedule pauses, until the next week."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        heading,
        subtitle: creating
          ? "Serein checks it on its own and tells you only what is new. Checks read; any other step asks you."
          : "Saved changes apply at once. Undo them in Recent changes to schedules."
      ) { EmptyView() }
      TextField(isGoal ? "What Serein looks for, and where" : reminder.action ? "What Serein does" : "Reminder", text: $text, axis: .vertical)
        .textFieldStyle(.serein).lineLimit(2...5)
        .accessibilityLabel(isGoal ? "The goal" : reminder.action ? "What Serein does" : "Reminder text")
      HStack {
        Text(isGoal ? "Checks" : "When")
        Spacer()
        // A goal checks again and again.
        SettingsPopUp(isGoal ? "How often it checks" : "When it runs", selection: $when,
          choices: When.allCases.filter { !isGoal || $0 != .once }.map { SettingsChoice(value: $0, label: $0.title) }, showsTitle: false)
      }
      switch when {
      case .once, .daily, .weekdays, .weekly:
        DatePicker(when == .once ? "At" : isGoal ? "Next check" : "Next run", selection: $due, displayedComponents: [.date, .hourAndMinute])
          .accessibilityLabel(when == .once ? "Run at" : isGoal ? "Next check" : "Next run")
      case .minutes:
        HStack {
          Text("Every")
          Spacer()
          SettingsPopUp("Minutes between runs", selection: $every,
            choices: RelayReminder.minuteChoices.map { SettingsChoice(value: $0, label: "\($0) minutes") }, showsTitle: false)
        }
      case .custom:
        TextField("17 9 * * 1-5", text: $cron).textFieldStyle(.serein).font(UIStyle.monoMeta)
          .accessibilityLabel("Custom schedule, as a cron")
        SettingsNote("Minute, hour, day of month, month and day of week, in your time zone: 17 9 * * 1-5 is 9:17 every weekday.")
      }
      if reminder.action, when != .once {
        Toggle("Stop after a number of runs", isOn: $limited)
        if limited {
          Stepper("Stop after \(limit) run\(limit == 1 ? "" : "s")", value: $limit, in: 1...1000)
            .accessibilityLabel("Number of runs before it stops")
            .accessibilityValue("\(limit)")
          SettingsNote("Counts from when you save. Serein pauses it after the last run and says so here.")
        }
        Toggle("Skip a run if the last one is still going", isOn: $skip)
      }
      if reminder.action {
        Toggle("Pause past a weekly token limit", isOn: $capped)
        if capped {
          HStack {
            Text("Pause after")
            Spacer()
            SettingsPopUp("Weekly token limit", selection: $weekly,
              choices: Self.weeklyChoices(including: weekly).map { SettingsChoice(value: $0, label: "\(UsageLedger.Summary.short($0)) tokens a week") },
              showsTitle: false)
          }
        }
        SettingsNote(costNote)
      }
      if reminder.action {
        Toggle("Run late if the Mac was asleep", isOn: $runLate)
        SettingsNote("Off, a run missed while your Mac slept or Serein was closed waits in Serein's chat with Run now and Skip.")
      }
      if isGoal {
        DatePicker("Ends", selection: $ends, displayedComponents: [.date])
          .accessibilityLabel("Goal ends on")
        Toggle("End after quiet checks in a row", isOn: $quietOn)
        if quietOn {
          Stepper("End after \(quietLimit) check\(quietLimit == 1 ? "" : "s") with nothing new", value: $quietLimit, in: 1...100)
            .accessibilityLabel("Quiet checks in a row before it ends")
            .accessibilityValue("\(quietLimit)")
        }
        TextField("Progress note", text: $note, axis: .vertical)
          .textFieldStyle(.serein).lineLimit(2...6)
          .accessibilityLabel("Progress note")
        SettingsNote("Each check reads this note and writes the next one from web pages, so read it as such. Undo an edit in Recent changes to schedules.")
      }
      if let problem { Text(problem).role(.meta).foregroundStyle(p.danger) }
      HStack {
        Spacer()
        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        Button("Save") { save() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: UIStyle.wide(520)).background(p.panel).foregroundStyle(p.ink).font(UIStyle.body)
      .buttonStyle(QuietButton()).controlSize(.small).tint(p.accent).toggleStyle(SettingsToggleStyle())
  }

  private func save() {
    var repeats = RelayReminder.Repeat.none
    var expression: String?
    switch when {
    case .once: repeats = .none
    case .daily: repeats = .daily
    case .weekdays: repeats = .weekdays
    case .weekly: repeats = .weekly
    case .minutes:
      repeats = .cron
      expression = RelayReminder.cron(everyMinutes: every)
    case .custom:
      repeats = .cron
      expression = cron
    }
    let now = Date()
    let action = reminder.action
    let draft: RelayReminder? = creating ? reminder : nil
    let summary = creating ? "Added goal \(RelayOrchestrator.short(text))"
      : (isGoal ? "Edited goal " : "Edited ") + RelayOrchestrator.short(reminder.text)
    let goalEdit: (note: String, ends: Date, quiet: Int?)? = isGoal ? (note, ends, quietOn ? quietLimit : nil) : nil
    let weeklyLimit = capped ? weekly : nil
    do {
      try relay.changeReminder(reminder.id, summary) { current in
        guard let old = current ?? draft else { throw SereinError.invalid("This schedule was removed.") }
        var next = try old.editing(
          text: text, due: due, repeats: repeats, cron: expression,
          limit: action && repeats != .none ? (limited ? limit : nil) : old.limit,
          skipIfBusy: action ? skip : old.skipsWhileBusy, now: now)
        if let goalEdit {
          next = try next.editingGoal(note: goalEdit.note, ends: goalEdit.ends, quietLimit: goalEdit.quiet, now: now)
        }
        if action { next = try next.limitingWeek(to: weeklyLimit, now: now) }
        if action { next.runLate = runLate ? true : nil }
        current = next
      }
      close()
    } catch {
      problem = error.localizedDescription
    }
  }
}

/// Edit an alert: its name, what it reads and how often. A new read starts over, so the edit
/// itself never fires the alert.
private struct WatchEditor: View {
  let relay: RelayOrchestrator
  let watch: RelayWatch
  var close: () -> Void
  @Environment(\.palette) var p
  @State private var name: String
  @State private var source: String
  @State private var minutes: Int
  @State private var problem: String?

  init(relay: RelayOrchestrator, watch: RelayWatch, close: @escaping () -> Void) {
    self.relay = relay
    self.watch = watch
    self.close = close
    _name = State(initialValue: watch.name)
    _source = State(initialValue: watch.source)
    _minutes = State(initialValue: watch.minutes)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader("Edit alert", subtitle: "Saved changes apply at once. Undo them in Recent changes to schedules.") {
        EmptyView()
      }
      TextField("Name", text: $name).textFieldStyle(.serein).accessibilityLabel("Alert name")
      TextField(watch.kind == .script ? "AppleScript read" : "Page address", text: $source, axis: .vertical)
        .textFieldStyle(.serein).font(UIStyle.monoMeta).lineLimit(1...8)
        .accessibilityLabel(watch.kind == .script ? "AppleScript the alert reads" : "Page the alert checks")
      SettingsNote(
        watch.kind == .script
          ? "A read-only AppleScript over Calendar, Reminders, Notes or Finder. A new read learns its starting answer first."
          : "A public page, https://…. A new page learns its starting text first.")
      Stepper("Every \(minutes) min", value: $minutes, in: RelayWatch.minMinutes...10_080, step: 15)
        .accessibilityLabel("Minutes between checks")
        .accessibilityValue("\(minutes)")
      if let problem { Text(problem).role(.meta).foregroundStyle(p.danger) }
      HStack {
        Spacer()
        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        Button("Save") { save() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: UIStyle.wide(520)).background(p.panel).foregroundStyle(p.ink).font(UIStyle.body)
      .buttonStyle(QuietButton()).controlSize(.small).tint(p.accent)
  }

  private func save() {
    do {
      try relay.changeWatch(watch.id, "Edited \(RelayOrchestrator.short(watch.name))") { current in
        guard let old = current else { throw SereinError.invalid("This alert was removed.") }
        current = try old.editing(name: name, source: source, minutes: minutes)
      }
      close()
    } catch {
      problem = error.localizedDescription
    }
  }
}

/// New assistant, as a row of Settings › Assistants: type a name, press Return. It is made the
/// way the sidebar's New assistant makes one (`addAssistant`: the next free tint, Speaks first
/// Never, the "Added {Name} · Edit" toast); a refusal says why under the field.
struct AddProfileField: View {
  let relay: RelayOrchestrator
  @State private var name = ""
  @State private var problem: String?
  @FocusState private var focused: Bool
  @Environment(\.palette) private var p
  private var typed: Bool { !RelayProfile.cleanName(name).isEmpty }
  var body: some View {
    HStack(spacing: 12) {
      SettingsGlyphTile(systemName: "plus").accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        TextField("New Serein", text: $name).textFieldStyle(.plain).font(AssistantType.body).foregroundStyle(p.ink)
          .focused($focused)
          .accessibilityLabel("New Serein's name")
          .onSubmit(add)
          .onChange(of: name) { _, value in
            problem = nil
            if value.count > RelayProfile.nameLimit { name = String(value.prefix(RelayProfile.nameLimit)) }
          }
        Text(verbatim: problem ?? "Type a name, then press Return").font(AssistantType.meta)
          .foregroundStyle(problem == nil ? p.secondary : p.danger)
      }
      Spacer(minLength: 8)
      if typed {
        Button("Add", action: add).buttonStyle(QuietButton())
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .contentShape(Rectangle())
    .onTapGesture { focused = true }
    .settingsRowHairline()
  }
  private func add() {
    let clean: String = RelayProfile.cleanName(name)
    guard !clean.isEmpty else { return }
    if relay.team.profiles.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
      problem = "Another assistant is called \(clean)."
      return
    }
    guard relay.team.profiles.count < AssistantBoard.rosterLimit else {
      problem = AssistantBoard.fullRoster
      return
    }
    guard relay.addAssistant(named: clean) != nil else {
      problem = "\(clean) wasn't made. Try again when the reply is done."
      return
    }
    name = ""
  }
}

/// Appearance › Serein's look: the hologram in every state, the look Serein wears, and who may change it.
struct RelayLookSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  @Environment(\.palette) var p
  @AppStorage(RelayOrchestrator.hologramKey) private var hologram = RelayOrchestrator.hologramDefault
  @AppStorage(ScreenSignals.key) private var screenSignals = true
  @State private var preview: RelayLook.State = .idle
  @State private var problem: String?
  private static let shown: [RelayLook.State] = [.idle, .listening, .thinking, .speaking, .working, .alert, .error, .dormant]

  var body: some View {
    SettingsGroup("Serein's look", info: "Serein can redesign itself. Ask it (“make yourself green”, “you’re too bright”), or let it pick a look for the day, at most twice a day. Every state keeps its own shape: thinking spins, listening turns toward you, a task in progress orbits. Undo goes back one look.") {
      RelayAvatarStage(
        state: preview, look: relay.look,
        jobs: preview == .working ? [RelayAvatarJob(id: "a", state: "running"), RelayAvatarJob(id: "b", state: "running")] : [])
        .frame(height: 180)
      // Chips that wrap at the group's width: a segmented control with eight states cannot shrink
      // below its titles, and it pushed the whole Settings sheet past both of its edges.
      FlowChips(items: Self.shown) { state in
        stateChip(state)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("State")
      Text(relay.look.states[preview.rawValue].map { "\(preview.title): \($0.formation ?? "") rings, \($0.core ?? relay.look.core.shape) core" } ?? "")
        .role(.meta)
      SettingsPopUp("Look", selection: Binding(get: { selected }, set: choose),
        choices: (isPreset ? [] : [SettingsChoice(value: "custom", label: "\(relay.look.name) (Serein’s design)")])
          + RelayLook.presets.map { SettingsChoice(value: "preset:" + $0.name, label: $0.name) }, menuWidth: 260)
      Text(credit).role(.meta).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Ask Serein for a new look") {
          relay.ask(RelayLookDraft.designPrompt)
          controller.show()
        }
        Button("Undo") { relay.undoLook() }.disabled(relay.looks.history.isEmpty)
        Button("Reset") { choose("preset:" + RelayLook.serein.name) }.disabled(relay.look == RelayLook.serein)
      }
      if let problem { Text(problem).role(.meta).foregroundStyle(p.danger) }
      Toggle("Show the hologram", isOn: $hologram)
      Toggle("Glow at the screen’s edge while Serein works in an app or a page", isOn: $screenSignals)
      Toggle("Let Serein change its look on its own", isOn: Binding(get: { relay.restyleOnItsOwn }, set: { relay.restyleOnItsOwn = $0 }))
      SettingsNote(
        "Ask Serein for a look (“make yourself green”), or let it pick one for the day, at most twice a day. Undo goes back one look.")
    }
  }
  /// One state to preview: the chosen one on the `selected` wash.
  private func stateChip(_ state: RelayLook.State) -> some View {
    let chosen: Bool = preview == state
    return Button { preview = state } label: {
      Text(state.title).font(UIStyle.meta)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(chosen ? p.selected : Color.clear, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.pressable)
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }
  private var isPreset: Bool { RelayLook.presets.contains(relay.look) }
  private var selected: String { isPreset ? "preset:" + relay.look.name : "custom" }
  private func choose(_ tag: String) {
    guard tag.hasPrefix("preset:"), let look = RelayLook.preset(String(tag.dropFirst(7))), look != relay.look else { return }
    do {
      try relay.wear(look, by: .you)
      problem = nil
    } catch { problem = error.localizedDescription }
  }
  private var credit: String {
    let current = relay.looks.current
    switch current.by {
    case .preset: return "Serein’s own look."
    case .you: return "You chose this look."
    case .relay:
      let when = current.at.formatted(date: .abbreviated, time: .omitted)
      return "Serein chose this look \(current.own ? "on its own" : "when you asked") on \(when)" + (current.reason.map { ": “\($0)”" } ?? ".")
    }
  }
}
