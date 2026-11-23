import AppKit
import SereinCore
import SwiftUI

/// Settings › Assistants › {Name} (board 15): one assistant's page, from top to bottom: its
/// header (a click on the face changes its icon and colour); the paused banner with Resume; Needs
/// you, which opens its chat; For you (Working for you, Speaks first, Message {Name}); Settings
/// (AI app and model, What it does, Apps it can use, Routines, Memory, Asks first, Links), each
/// row with its current answer and its own sub-page (AssistantSettingsParts.swift); and Manage
/// (Pinned, Hidden, Rename…, Delete {Name}…). Serein has no Pause, Hidden or Delete. Every change
/// goes through the existing paths: `AssistantRowMenu.setPaused` (the change `assistant_change`
/// makes), `setSpeaksFirst`, `saveAssistant`, `chooseRoute`, `AssistantRowState`, `renameProfile`
/// and `AssistantConfirm.deleteAssistant`; nothing here writes team.json itself.
struct AssistantSettingsPage: View {
  @ObservedObject var relay: RelayOrchestrator
  let profileID: String
  /// Off in the inspector, whose own header shows the face and name.
  var header = true
  @Environment(\.settingsNavigation) private var nav
  var body: some View {
    if let profile = relay.team.profiles.first(where: { $0.id == profileID }) {
      page(profile)
        // Drafts belong to the page's assistant: another assistant's page starts empty.
        .id(profile.id)
    } else {
      AssistantSettingsGone()
    }
  }
  /// The page itself; a request for one of its old sub-pages scrolls to that section
  /// (`SettingsInline`).
  private func page(_ profile: RelayProfile) -> some View {
    AssistantSettingsBody(relay: relay, hub: relay.agent.hub, desk: relay.desk, profile: profile, header: header)
  }
}

/// The sub-pages of an assistant's page, after its id.
enum AssistantSettingsKey {
  static let does = "does"
  static let apps = "apps"
  static let routines = "routines"
  static let memory = "memory"
  static let asks = "asks"
  static let links = "links"
  /// The keys that are sections of an assistant's page (`SettingsInline`), in page order.
  static let order = [does, apps, routines, memory, asks, links]
  static let all = Set(order)
  static let titles: [String: String] = [
    does: "What it does", apps: "Apps it can use", routines: "Routines", memory: "Memory", asks: "Asks first", links: "Links",
  ]
  /// "Relay/<id>": Settings › Assistants › that assistant's page; "Relay/<id>/apps" one of its
  /// sub-pages.
  static func request(_ id: String, to sub: String? = nil) -> String {
    let path: [String] = sub.map { [id, $0] } ?? [id]
    return SettingsCategory.request("Relay", path: path)
  }
  /// Opens an assistant's page (or one of its sub-pages) from outside Settings: the details card,
  /// the row's menu, the inspector, the "Added {Name} · Edit" toast, a hand-off's line, Serein's
  /// menu. A team sheet closes first, then Settings opens there.
  @MainActor static func open(_ id: String, to sub: String? = nil) {
    let section: String = request(id, to: sub)
    TeamSheets.shared.dismiss()
    DispatchQueue.main.async { RelayController.shared?.openSettings(section) }
  }
}

/// The page of an assistant that is not there any more (deleted while its page was open).
private struct AssistantSettingsGone: View {
  @Environment(\.settingsNavigation) private var nav
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Not here any more", sentence: "This assistant was deleted. Its chats stay in History.")
      SettingsRowList {
        SettingsSummaryRow(title: "Assistants", answer: "Back to your assistants", hint: "Goes back", open: { nav.go([]) }) {
          SettingsGlyphTile(systemName: "person.2")
        }
      }
    }
  }
}

/// The page itself.
private struct AssistantSettingsBody: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var hub: AgentHub
  /// `relay.desk`: it publishes on its own (the owned links).
  @ObservedObject var desk: AssistantDesk
  let profile: RelayProfile
  var header = true
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var surface = SereinSurface.main
  private var isMain: Bool { profile.id == relay.team.mainProfileID }
  var body: some View {
    let status: SereinStatus = relay.assistantStatus(
      profile.id, hub: hub, online: SereinSurface.online(network.online), connected: SereinSurface.connected(relay.agent),
      unread: surface.unread)
    VStack(alignment: .leading, spacing: 24) {
      if header { AssistantSettingsHeader(relay: relay, profile: profile) }
      if profile.isPaused && !isMain { AssistantPausedBanner(relay: relay, profile: profile) }
      if status == .needsYou { AssistantNeedsYouBanner(relay: relay, profile: profile) }
      SettingsRowList("Thinks with") { AssistantModelRow(relay: relay, profile: profile) }
      SettingsRowList("Its computer") {
        ComputerPlacePicker(computer: ComputerHost.shared.computer(for: profile.id), name: profile.name, asRow: true)
      }
      SettingsRowList("For you") { AssistantForYouRows(relay: relay, profile: profile) }
      // Each of these used to open its own page; they are sections of this one now.
      ForEach(AssistantSettingsKey.order, id: \.self) { key in
        SettingsSection(key, title: AssistantSettingsKey.titles[key] ?? key) {
          AssistantSettingsSectionView(relay: relay, profile: profile, key: key)
        }
      }
      SettingsRowList("Manage", note: isMain ? "Serein is always here: it has no Pause, Hidden or Delete." : nil) {
        AssistantManageRows(relay: relay, profile: profile)
      }
    }
  }
}

/// The page's header: the face at 40 (moving by its state; a click changes its icon and colour),
/// the name in the title size, and its job and team in 13 `secondary`.
struct AssistantSettingsHeader: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @State private var choosing = false
  @Environment(\.palette) private var p
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Button { choosing = true } label: {
        AssistantLiveMark(relay: relay, profile: profile, size: 40).frame(width: 40, height: 40).contentShape(Circle())
      }
      .buttonStyle(.pressable)
      .help("Change \(profile.name)'s icon and colour")
      .accessibilityLabel("\(profile.name)'s icon")
      .accessibilityHint("Changes the icon and the colour")
      .popover(isPresented: $choosing, arrowEdge: .bottom) {
        AssistantLookPicker(relay: relay, profileID: profile.id).environment(\.palette, p)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: profile.name).font(AssistantType.title).foregroundStyle(p.ink).lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: AssistantSettingsWords.jobAndTeam(relay: relay, profile: profile)).font(AssistantType.body)
          .foregroundStyle(p.secondary).lineLimit(2)
      }
      Spacer(minLength: 0)
    }
  }
}

/// The face's popover: the colour swatches (each pick saved as the editor saved its form) and the
/// icon choice (`setIcon`, each pick its own change with Undo on its toast).
private struct AssistantLookPicker: View {
  @ObservedObject var relay: RelayOrchestrator
  let profileID: String
  @State private var problem: String?
  @Environment(\.palette) private var p
  var body: some View {
    if let profile = relay.team.profiles.first(where: { $0.id == profileID }) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Colour").font(AssistantType.meta).foregroundStyle(p.secondary)
        swatches(profile)
        Text("Icon").font(AssistantType.meta).foregroundStyle(p.secondary)
        AssistantIconPicker(name: profile.name, tint: profile.colour, icon: profile.icon) { next, png in
          relay.setIcon(profile.id, next, picture: png)
        }
        if let problem { Text(verbatim: problem).font(AssistantType.meta).foregroundStyle(p.danger) }
      }
      .padding(16).frame(width: 300)
    }
  }
  private func swatches(_ profile: RelayProfile) -> some View {
    let current: String = AssistantColour.key(profile.colour) ?? "indigo"
    return HStack(spacing: 8) {
      ForEach(p.tokens.assistantTints, id: \.key) { tint in
        let selected: Bool = current == tint.key
        Button { choose(tint.key, for: profile) } label: {
          Circle().fill(Color(hex: tint.rgb)).frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(p.borderStrong, lineWidth: 1).opacity(selected ? 0 : 1))
            .padding(2)
            .overlay(Circle().strokeBorder(p.ink, lineWidth: 2).opacity(selected ? 1 : 0))
            .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(tint.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
      }
    }
    .accessibilityElement(children: .contain).accessibilityLabel("Colour")
  }
  private func choose(_ key: String, for profile: RelayProfile) {
    guard key != (AssistantColour.key(profile.colour) ?? "indigo") else { return }
    problem = relay.saveFromSettings(profile, colour: key, scope: relay.editableScope(profile))
  }
}

/// Paused, only while it is: one `card` line with Resume, the page's one primary.
private struct AssistantPausedBanner: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: 12) {
      InterfaceIcon(systemName: "pause.fill", size: 14).foregroundStyle(p.secondary).accessibilityHidden(true)
      Text("Paused. Its routines and links wait.").font(AssistantType.body).foregroundStyle(p.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Resume") { AssistantRowMenu.setPaused(relay, profile, false) }.buttonStyle(PrimaryButton())
        .accessibilityLabel("Resume \(profile.name)")
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .card(p)
    .accessibilityElement(children: .contain)
  }
}

/// Needs you, only while a card waits: the line opens its chat, where the card is answered.
private struct AssistantNeedsYouBanner: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @Environment(\.palette) private var p
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        InterfaceIcon(systemName: "bell", size: 16).foregroundStyle(p.warning).accessibilityHidden(true)
        Text("Waiting for your answer in \(profile.name)'s chat").font(AssistantType.body).foregroundStyle(p.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Open chat").font(AssistantType.name).foregroundStyle(p.accent)
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      .background(p.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).strokeBorder(p.warning.opacity(0.35)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .accessibilityLabel("Waiting for your answer in \(profile.name)'s chat")
    .accessibilityHint("Opens its chat")
  }
  private func open() {
    guard relay.openAssistant(profile.id) else { return }
    dismiss()
  }
}

/// For you: Working for you (Serein's own row says why it has no switch), Speaks first, and
/// Message {Name}.
private struct AssistantForYouRows: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @Environment(\.dismiss) private var dismiss
  private var isMain: Bool { profile.id == relay.team.mainProfileID }
  var body: some View {
    if isMain {
      SettingsListRow(
        name: "Working for you", status: "Serein answers for everyone. Stop Everything stops all work.", expandable: false
      ) {
        SettingsGlyphTile(systemName: "bolt")
      } trailing: {
        EmptyView()
      } live: {
        EmptyView()
      } details: {
        EmptyView()
      }
    } else {
      SettingsSwitchRow(
        title: "Working for you",
        answer: profile.isPaused ? "Paused. Its routines and links wait until you turn it back on." : "Runs its routines and links",
        isOn: Binding(get: { !profile.isPaused }, set: { on in AssistantRowMenu.setPaused(relay, profile, !on) }),
        label: "\(profile.name) works for you"
      ) {
        SettingsGlyphTile(systemName: "bolt")
      }
    }
    AssistantSpeaksFirstRow(relay: relay, profile: profile)
    SettingsSummaryRow(
      title: "Message \(profile.name)", answer: "Opens its chat with the keyboard in the message bar", hint: "Opens its chat",
      open: message
    ) {
      SettingsGlyphTile(systemName: "bubble.left")
    }
  }
  private func message() {
    guard relay.openAssistant(profile.id) else { return }
    dismiss()
    NotificationCenter.default.post(name: SereinSurface.focus, object: nil)
  }
}

/// One former sub-page of an assistant's page, drawn as its section.
private struct AssistantSettingsSectionView: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  let key: String
  var body: some View {
    switch key {
    case AssistantSettingsKey.does: AssistantDoesSettings(relay: relay, profile: profile)
    case AssistantSettingsKey.apps: AssistantAppsSettings(relay: relay, profile: profile)
    case AssistantSettingsKey.routines:
      SettingsPageHeader("Routines", sentence: "What \(profile.name) runs on its own: its schedules, goals and alerts.")
      RoutineSettings(relay: relay, owner: profile.id, name: profile.name)
    case AssistantSettingsKey.memory:
      SettingsPageHeader("Memory", sentence: "What \(profile.name) keeps about you, and what it learned for you to review.")
      AssistantMemorySettings(relay: relay, profile: profile)
    case AssistantSettingsKey.asks:
      if let controller = RelayController.shared {
        RelayAsksSettings(relay: relay, controller: controller, shared: true)
      }
    default: AssistantLinksSettings(relay: relay, desk: relay.desk, profile: profile)
    }
  }
}

/// AI app and model: the app's logo and the model's name. A click opens Serein's own picker of AI
/// apps and models beside the row (`AssistantAppPicker`: `ModelPickerView` with `assistant:`,
/// Keel's size capped to the window); a pick sets this assistant's own route (`chooseRoute`). While
/// a move that could change who pays waits on its card, the row says where.
private struct AssistantModelRow: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @State private var open = false
  @Environment(\.palette) private var p
  var body: some View {
    let engine: AgentModel.ChatEngine = relay.chatEngine(ofAssistant: profile.id)
    let model: String = ModelPill.name(engine)
    let named: String = "\(engine.provider.name) · \(model)"
    let saved: String = profile.route == nil ? "Default · " + named : named
    let answer: String = waitingWords ?? saved
    SettingsSummaryRow(
      title: "AI app and model", answer: answer, tone: waitingWords == nil ? nil : p.warning,
      hint: "Opens the list of AI apps and models", open: { open = true }
    ) {
      SettingsLogoTile(provider: engine.provider)
    }
    .popover(isPresented: $open, arrowEdge: .trailing) {
      AssistantAppPicker(relay: relay, profile: profile) { open = false }.environment(\.palette, p)
    }
  }
  /// The card for a move onto another bill (`askRoute`: "Switch {Name} to …?") waits in a chat.
  private var waitingWords: String? {
    let prefix: String = "Switch \(profile.name) to "
    guard let card = relay.approvals.first(where: { $0.effect == .pay && $0.title.hasPrefix(prefix) }) else { return nil }
    let owner: String = relay.assistantOwning(thread: card.threadID).map { relay.profileName($0) } ?? relay.team.activeName
    return "Waiting for your answer in \(owner)'s chat"
  }
}

/// Manage: Pinned and Hidden (the list's own marks, `AssistantRowState`), Rename… in place
/// (`renameProfile`, with the "Another assistant is called…" refusal) and Delete {Name}… (the
/// delete card in the chat, then the receipt's toast with its 10-second Undo). Serein has no
/// Hidden or Delete.
private struct AssistantManageRows: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @ObservedObject private var rowState = AssistantRowState.shared
  @State private var renaming = false
  @State private var draft = ""
  @State private var problem: String?
  @FocusState private var focused: Bool
  @Environment(\.palette) private var p
  @Environment(\.dismiss) private var dismiss
  private var isMain: Bool { profile.id == relay.team.mainProfileID }
  var body: some View {
    let pinned: Bool = rowState.pinned.contains(profile.id)
    SettingsSwitchRow(
      title: "Pinned", answer: "At the top of your list. Only the list changes.",
      isOn: Binding(get: { pinned }, set: { on in if on { rowState.pin(profile.id) } else { rowState.unpin(profile.id) } }),
      label: "Pin \(profile.name)"
    ) {
      SettingsGlyphTile(systemName: "pin")
    }
    if !isMain {
      let hidden: Bool = rowState.hidden.contains(profile.id)
      SettingsSwitchRow(
        title: "Hidden", answer: "Off your list. It still runs; pause it to stop its routines.",
        isOn: Binding(get: { hidden }, set: { on in if on { rowState.hide(profile.id) } else { rowState.show(profile.id) } }),
        label: "Hide \(profile.name) from the sidebar"
      ) {
        SettingsGlyphTile(systemName: "eye.slash")
      }
    }
    if renaming { renameField } else {
      SettingsSummaryRow(title: "Rename…", answer: profile.name, hint: "Renames it here", open: startRename) {
        SettingsGlyphTile(systemName: "pencil")
      }
    }
    if !isMain {
      SettingsSummaryRow(
        title: "Delete \(profile.name)…", answer: "Its chats stay in History. You can undo.", danger: true,
        hint: "Asks in its chat first", open: delete
      ) {
        SettingsGlyphTile(systemName: "trash").foregroundStyle(p.danger)
      }
    }
  }
  private var renameField: some View {
    HStack(spacing: 12) {
      SettingsGlyphTile(systemName: "pencil").accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        TextField("Name", text: $draft).textFieldStyle(.plain).font(AssistantType.body).foregroundStyle(p.ink)
          .focused($focused)
          .onSubmit(saveRename)
          .onExitCommand { renaming = false }
          .accessibilityLabel("Rename \(profile.name)")
          .onChange(of: draft) { _, value in
            problem = nil
            if value.count > RelayProfile.nameLimit { draft = String(value.prefix(RelayProfile.nameLimit)) }
          }
        Text(verbatim: problem ?? "Press Return to save, Esc to keep \(profile.name)").font(AssistantType.meta)
          .foregroundStyle(problem == nil ? p.secondary : p.danger)
      }
      Spacer(minLength: 8)
      Button("Save", action: saveRename).buttonStyle(QuietButton())
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .settingsRowHairline()
    .onAppear { focused = true }
  }
  private func startRename() {
    draft = profile.name
    problem = nil
    renaming = true
  }
  private func saveRename() {
    let clean: String = RelayProfile.cleanName(draft)
    guard !clean.isEmpty, clean != profile.name else {
      renaming = false
      return
    }
    guard relay.renameProfile(profile.id, to: clean) else {
      problem = "Another assistant is called \(clean)."
      return
    }
    renaming = false
  }
  /// The delete card waits in the chat, so Settings closes first to show it.
  private func delete() {
    dismiss()
    let who: RelayProfile = profile
    let orchestrator: RelayOrchestrator = relay
    DispatchQueue.main.async { AssistantConfirm.deleteAssistant(orchestrator, who) }
  }
}

/// The words an assistant's rows and header say.
@MainActor enum AssistantSettingsWords {
  /// Its job: Serein's own line, the job it was given, its label, or how to give it one.
  static func job(relay: RelayOrchestrator, profile: RelayProfile) -> String {
    if profile.id == relay.team.mainProfileID { return "Your chief of staff" }
    if let job = AssistantRoster.job(of: profile) { return job }
    if let label = profile.label, !label.isEmpty { return label }
    return "No job yet. Tell \(profile.name) what to do."
  }
  /// "Finds fares and hotels · In the Lisbon trip team".
  static func jobAndTeam(relay: RelayOrchestrator, profile: RelayProfile) -> String {
    let job: String = job(relay: relay, profile: profile)
    guard let team = relay.team.groups(of: profile.id).first else { return job }
    return job + " · In the \(team.name) team"
  }
  /// A row on Settings › Assistants: "Finds fares and hotels · Needs you", or "Paused".
  static func row(relay: RelayOrchestrator, profile: RelayProfile, status: SereinStatus) -> String {
    if status == .paused { return "Paused" }
    let job: String = profile.id == relay.team.mainProfileID ? "Your chief of staff" : (AssistantRoster.job(of: profile) ?? "No job yet")
    return job + " · " + status.words
  }
  /// What its Speaks first level means.
  static func speaksFirst(_ level: RelayProactive.Level, name: String) -> String {
    switch level {
    case .off: return "\(name) speaks only when you ask"
    case .light: return "A morning line and failed work, now and then"
    case .jarvis: return "Also a check-in when \(name) has something useful"
    case .always: return "A check-in about every hour"
    }
  }
}

/// Speaks first (`setSpeaksFirst`, one journaled change with Undo on its toast). For Serein it is
/// what Check-ins was: Settings' level stays in step with it.
struct AssistantSpeaksFirstRow: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  var body: some View {
    let level: RelayProactive.Level = relay.speaksFirst(profile)
    let choices: [SettingsChoice<RelayProactive.Level>] = RelayProactive.Level.allCases.map {
      SettingsChoice(value: $0, label: $0.title)
    }
    SettingsChoiceRow(
      title: "Speaks first", answer: AssistantSettingsWords.speaksFirst(level, name: profile.name),
      selection: Binding(get: { relay.speaksFirst(profile) }, set: { next in
        guard next != relay.speaksFirst(profile) else { return }
        relay.setSpeaksFirst(profile.id, next)
      }),
      choices: choices
    ) {
      SettingsGlyphTile(systemName: "bubble.left.and.bubble.right")
    }
    .help("All assistants share one daily limit and stay quiet at night. Each time one speaks first it uses some of your AI app's usage.")
  }
}

extension RelayOrchestrator {
  /// What `profile` may use as its page edits it: its own scope, or the person's places when it
  /// has none, never wider than the person's settings now.
  func editableScope(_ profile: RelayProfile) -> AssistantScope {
    var scope: AssistantScope = profile.scope ?? AssistantScope(destinations: personPlaces)
    scope.destinations = scope.destinations.intersection(personPlaces)
    return scope
  }
  /// One change from an assistant's page (its colour, job, instructions, places or sites), saved
  /// the way the editor saved its whole form (`saveAssistant`: one journaled change with Undo on
  /// its toast; it never widens past the person's settings). The rest stays as it is. nil when
  /// saved; else why not.
  func saveFromSettings(_ profile: RelayProfile, colour: String?, scope: AssistantScope) -> String? {
    saveAssistant(
      profile.id, name: profile.name, colour: colour, icon: profile.icon, picture: nil, scope: scope,
      speaksFirst: speaksFirst(profile))
  }
}

/// Serein's own words (What it does, for the main assistant): its name and the line about you,
/// and its standing instructions (`RelayPersona`), each saved with Save and put back with Revert,
/// and the recent changes to them with Undo. They live in the folder of the assistant you talk
/// to, so they show only while that is Serein; the drafts belong to Serein and go when another
/// assistant answers.
struct SereinPersonaSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @Environment(\.palette) var p
  /// Unsaved standing instructions; nil shows the saved words, so an allowed proposal or an
  /// undo appears at once.
  @State private var instructionsDraft: String?
  /// Unsaved name and line about the user, saved together like the instructions, so a space
  /// typed at the end of a word stays while the person types; nil shows the saved words.
  @State private var nameDraft: String?
  @State private var aboutDraft: String?
  private var instructionsChanged: Bool {
    guard let instructionsDraft else { return false }
    return (RelayPersona(rules: instructionsDraft).sanitized()?.rules ?? "") != relay.persona.rules
  }
  private var personalityChanged: Bool {
    guard nameDraft != nil || aboutDraft != nil else { return false }
    let draft = RelayPersona(
      name: nameDraft ?? relay.persona.name, about: aboutDraft ?? relay.persona.about, rules: relay.persona.rules
    ).sanitized() ?? RelayPersona()
    return draft.name != relay.persona.name || draft.about != relay.persona.about
  }
  var body: some View {
    if relay.team.activeID == profile.id {
      VStack(alignment: .leading, spacing: 24) {
        personality
        standingInstructions
        changes
      }
      // Unsaved words belong to the assistant they were typed for, never to the one switched to.
      .onChange(of: relay.team.activeID) { _, _ in
        instructionsDraft = nil
        nameDraft = nil
        aboutDraft = nil
      }
    } else {
      SettingsBlock("Its own words") {
        Text("\(profile.name)'s name, the line about you and its standing instructions change while you talk to \(profile.name).")
          .role(.meta).fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Talk to \(profile.name)") { _ = relay.openAssistant(profile.id) }.buttonStyle(QuietButton())
            .disabled(!relay.canSwitchAssistant)
            .help(relay.canSwitchAssistant ? "Opens \(profile.name)'s chat behind Settings" : "Available when this reply is done")
          Spacer()
        }
      }
    }
  }
  private var personality: some View {
    SettingsBlock("Personality") {
      TextField("Name (what you call it)", text: Binding(
        get: { nameDraft ?? relay.persona.name }, set: { nameDraft = $0 }))
        .textFieldStyle(.roundedBorder)
      TextField("About you and how it should talk (one line)", text: Binding(
        get: { aboutDraft ?? relay.persona.about }, set: { aboutDraft = $0 }))
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Revert") {
          nameDraft = nil
          aboutDraft = nil
        }.controlSize(.small)
          .disabled(nameDraft == nil && aboutDraft == nil)
          .accessibilityLabel("Revert the name and the line about you to the saved words")
        Button("Save") {
          relay.updatePersona(RelayPersona(
            name: nameDraft ?? relay.persona.name, about: aboutDraft ?? relay.persona.about, rules: relay.persona.rules))
          nameDraft = nil
          aboutDraft = nil
        }.buttonStyle(PrimaryButton()).disabled(!personalityChanged)
          .accessibilityLabel("Save the name and the line about you")
        Spacer()
      }
      SettingsNote("Advice Serein reads every turn: a name and a line about you. It grants no access and is advice, not tools.")
    }
  }
  private var standingInstructions: some View {
    SettingsBlock("Standing instructions", info: "Serein follows up to \(RelayPersona.rulesLimit) of these every turn. They are preferences: they cannot let Serein skip asking before it acts. Serein can only suggest a change, which you allow or decline on a card. Every change is listed below and can be undone.") {
      TextField("One instruction per line, such as “never book before asking”", text: Binding(
        get: { instructionsDraft ?? relay.persona.rules }, set: { instructionsDraft = $0 }), axis: .vertical)
        .textFieldStyle(.roundedBorder).lineLimit(3...6)
        .accessibilityLabel("Standing instructions, one per line")
      HStack {
        Button("Revert") { instructionsDraft = nil }.controlSize(.small)
          .disabled(instructionsDraft == nil)
          .accessibilityLabel("Revert the standing instructions to the saved words")
        Button("Save") {
          if let instructionsDraft { relay.updateInstructions(instructionsDraft) }
          instructionsDraft = nil
        }.buttonStyle(PrimaryButton()).disabled(!instructionsChanged)
          .accessibilityLabel("Save the standing instructions")
        Spacer()
      }
      SettingsNote("Serein follows up to \(RelayPersona.rulesLimit) of these every turn. They are preferences and cannot let Serein skip asking before it acts. Every change is listed below and can be undone.")
    }
  }
  /// The changes to the standing instructions, with Undo (the notes' own are under Memory).
  @ViewBuilder private var changes: some View {
    let entries: [RelayJournalEntry] = Array(relay.journal.filter(\.isInstruction).suffix(8).reversed())
    if !entries.isEmpty {
      SettingsBlock("Recent changes to the instructions") {
        ForEach(entries, id: \.id) { entry in
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
              Text((entry.action == .removed ? (entry.priorText ?? "") : entry.text)
                .replacingOccurrences(of: "\n", with: " · ")).lineLimit(1)
              Text("\(entry.actor) · \(entry.action.rawValue) · \(entry.at.formatted(date: .omitted, time: .shortened))")
                .role(.meta)
            }
            Spacer()
            Button("Undo") { relay.undo(entry) }.controlSize(.small)
              .disabled(RelayJournal.undoneInstructions(entry, current: relay.persona.rules) == nil)
              .help("Puts back the instructions from before this change. Undo newer changes first.")
              .accessibilityLabel("Undo this change to the standing instructions")
          }
        }
      }
    }
  }
}

/// Memory on an assistant's page (affectUI Memory Panel, with Agent / Memory): Learn from your
/// chats (the same for every assistant), the learned notes waiting for review with Keep and
/// Discard, then its notes grouped by who may read them (`MemoryPanel`). Each note says where it
/// came from, links the chat it was made in and says when Serein last used it, with Edit in
/// place, Pause and Forget. A note the memory journal holds (the assistant you talk to, not
/// paused) is edited and forgotten through `updateNotes`, so the journal below
/// (`MemoryJournalView`) records each change with its Undo; any other note is changed in the
/// store with the toast's Undo, as another assistant's Forget always was. Pause turns a note off
/// in the store (it is never recalled) and Resume turns it back on. The records are read off the
/// main thread when the page opens and after each change (`settingsMemory`).
struct AssistantMemorySettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @Environment(\.palette) var p
  @State private var loaded: AssistantSettingsMemory?
  /// Counts the changes made here, so the records are read again after each.
  @State private var generation = 0
  /// The note edited in place, its words so far, and why the last save was refused.
  @State private var editing: String? = UIPreview.affectMemoryPanelEditing
  @State private var draft = ""
  @State private var problem: String?
  @FocusState private var editorFocused: Bool
  private var active: Bool { relay.team.activeID == profile.id }
  /// The preview's fixture (`--ui-affect-memory-panel`): previews open no store.
  private var fixture: AssistantSettingsMemory? { UIPreview.affectMemoryPanel(owner: profile.id) }
  /// The assistant you talk to lists Serein's own notes, which change before the store does.
  private var live: Bool { active && fixture == nil }
  private var rows: [MemoryRecord] {
    let notes: [RelayNote]? = live ? Array(relay.notes.reversed()) : nil
    return MemoryPanel.rows(live: notes, records: (fixture ?? loaded)?.notes ?? [], owner: profile.id)
  }
  private var waiting: [RelayNote] { live ? Array(relay.proposals.reversed()) : ((fixture ?? loaded)?.waiting ?? []) }
  static let learningInfo = "Uses some of your AI app’s usage: a chat that has been quiet for 6 hours, at most 8 chats a day. Serein finds a few notes about you, such as preferences, ongoing work and standing instructions, and keeps each one private to the assistant whose chat it was. It never keeps a password or other secret, and it uses no note until you keep it below or say yes when you ask what it remembers."

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsBlock("Learning", info: Self.learningInfo) {
        Toggle("Learn from your chats", isOn: Binding(get: { relay.learnsNotes }, set: { relay.learnsNotes = $0 }))
        SettingsNote("The same for every assistant. It never keeps a password or other secret, and it uses no note until you keep it.")
      }
      if !waiting.isEmpty { waitingList }
      notesList
      if active {
        SettingsBlock("Memory journal") { MemoryJournalView(relay: relay, name: profile.name) }
      }
    }
    .task(id: "\(profile.id)|\(generation)|\(active)") { await load() }
    .onReceive(NotificationCenter.default.publisher(for: AssistantSettingsMemory.changed)) { _ in generation += 1 }
    .onAppear {
      // The preview opens a note in edit mode: its words start in the field.
      if let id = editing, draft.isEmpty, let record = rows.first(where: { $0.id == id }) { draft = record.text }
    }
  }
  private var waitingList: some View {
    SettingsBlock("Learned, waiting for your review") {
      ForEach(waiting, id: \.id) { proposal in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(proposal.text)
            if let quote = proposal.quote { Text("“\(quote)”").role(.meta) }
          }
          Spacer()
          Button("Keep") { review(proposal, keep: true) }.controlSize(.small)
            .accessibilityLabel("Keep the note \(proposal.text)")
          Button("Discard") { review(proposal, keep: false) }.controlSize(.small)
            .accessibilityLabel("Discard the note \(proposal.text)")
        }
      }
    }
  }
  @ViewBuilder private var notesList: some View {
    let groups: [MemoryPanel.Group] = MemoryPanel.groups(rows, owner: profile.id)
    if groups.isEmpty {
      SettingsBlock("What \(profile.name) remembers") {
        let empty: String = !live && fixture == nil && loaded == nil ? "Reading…" : "No notes yet. Tell \(profile.name) something to remember."
        Text(verbatim: empty).role(.meta)
      }
    } else {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(groups, id: \.scope) { group in
          SettingsBlock(MemoryPanel.title(group.scope, owner: profile.id, in: relay.team)) {
            ForEach(group.records, id: \.id) { record in noteRow(record) }
          }
        }
      }
    }
  }
  private func noteRow(_ record: MemoryRecord) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        if editing == record.id {
          editor(record)
        } else {
          Text(record.text).foregroundStyle(record.enabled ? p.ink : p.secondary)
        }
        if let quote = record.quote { Text("“\(quote)”").role(.meta) }
        if let expires = record.expires {
          Text("Until \(expires.formatted(date: .abbreviated, time: .omitted))").role(.meta)
            .foregroundStyle(p.warning)
        }
        origin(record)
      }
      Spacer(minLength: 0)
      if editing != record.id { actions(record) }
    }
  }
  /// Where it came from, the chat it was made in (a press opens it), when it was saved, when
  /// Serein last used it (only when the store recorded a use) and whether it is paused.
  private func origin(_ record: MemoryRecord) -> some View {
    var after: [String] = [record.createdAt.formatted(date: .abbreviated, time: .omitted)]
    if let used = record.lastUsed { after.append("Last used " + used.formatted(date: .abbreviated, time: .omitted)) }
    if !record.enabled { after.append("Paused") }
    // A hidden chat's title never shows; its note still says where it came from.
    let chat: String? = record.chat.flatMap { relay.desk.hiddenThreads.contains($0) ? nil : $0 }
    let title: String? = chat.flatMap { RunningChats.chatTitle($0, relay: relay, run: nil) }
    return HStack(spacing: 4) {
      Text(verbatim: MemoryPanel.origin(record, names: relay.memoryNames)).role(.meta)
      if let chat, let title {
        Button("in “\(title)”") { RelayController.shared?.openThread(chat) }
          .buttonStyle(.link).font(UIStyle.meta).lineLimit(1)
          .help("Opens the chat this note came from")
          .accessibilityLabel("Open the chat \(title)")
      }
      Text(verbatim: "· " + after.joined(separator: " · ")).role(.meta).lineLimit(1)
    }
  }
  @ViewBuilder private func actions(_ record: MemoryRecord) -> some View {
    // A Library file or a dashboard keeps only Forget: its words are not a note's.
    if record.kind == .note {
      Button("Edit") { startEditing(record) }.controlSize(.small)
        .accessibilityLabel("Edit the note \(record.text)")
      Button(record.enabled ? "Pause" : "Resume") { pause(record) }.controlSize(.small)
        .help(record.enabled ? "Serein stops using this note until you resume it." : "Serein can use this note again.")
        .accessibilityLabel("\(record.enabled ? "Pause" : "Resume") the note \(record.text)")
    }
    Button("Forget") { forget(record) }.controlSize(.small)
      .accessibilityLabel("Forget the note \(record.text)")
  }
  /// Return saves, Escape puts the words back; a refusal says why under the field.
  private func editor(_ record: MemoryRecord) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Note", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...6)
        .focused($editorFocused)
        .onSubmit { save(record) }
        .onExitCommand { cancelEditing() }
        .accessibilityLabel("Edit the note")
      if let problem { Text(verbatim: problem).role(.meta).foregroundStyle(p.warning) }
      HStack(spacing: 8) {
        Button("Save") { save(record) }.controlSize(.small)
        Button("Cancel") { cancelEditing() }.controlSize(.small)
      }
    }
  }
  /// True when the memory journal holds the note, so its change goes through `updateNotes`.
  private func journaled(_ record: MemoryRecord) -> Bool {
    live && relay.notes.contains { $0.id == record.id }
  }
  private func load() async {
    guard fixture == nil else { return }
    loaded = await relay.settingsMemory(of: profile.id)
  }
  private func review(_ proposal: RelayNote, keep: Bool) {
    if live {
      if keep { relay.keep(proposal) } else { relay.discard(proposal) }
      return
    }
    let id: String = proposal.id
    Task { @MainActor in
      _ = await relay.reviewProposal(id, keep: keep)
      generation += 1
    }
  }
  private func startEditing(_ record: MemoryRecord) {
    editing = record.id
    draft = record.text
    problem = nil
    editorFocused = true
  }
  private func cancelEditing() {
    editing = nil
    problem = nil
  }
  private func save(_ record: MemoryRecord) {
    let words: String
    do {
      words = try MemoryPanel.edit(draft)
    } catch {
      problem = error.localizedDescription
      return
    }
    cancelEditing()
    guard words != record.text else { return }
    if journaled(record) {
      relay.updateNotes { notes in
        if let index = notes.firstIndex(where: { $0.id == record.id }) { notes[index].text = words }
      }
      return
    }
    let id: String = record.id
    Task { @MainActor in
      let changed: Bool = await relay.editFromSettings(id, text: words)
      generation += 1
      // The note changed meanwhile or is gone: the words stay in the field.
      guard !changed else { return }
      editing = id
      draft = words
      problem = "That note changed meanwhile. Try again."
    }
  }
  private func pause(_ record: MemoryRecord) {
    let id: String = record.id
    let on: Bool = !record.enabled
    Task { @MainActor in
      _ = await relay.pauseFromSettings(id, on: on)
      generation += 1
    }
  }
  private func forget(_ record: MemoryRecord) {
    if journaled(record) {
      relay.updateNotes { RelayMemory.forget(record.id, in: &$0) }
      return
    }
    let id: String = record.id
    Task { @MainActor in
      _ = await relay.forgetFromSettings(id)
      generation += 1
    }
  }
}

/// One assistant's notes as its page lists them (newest first, then its paused ones) and its
/// learned notes waiting.
struct AssistantSettingsMemory: Equatable {
  var notes: [MemoryRecord]
  var waiting: [RelayNote]
  /// Posted after a toast's Undo, so an open page reads its list again.
  static let changed = Notification.Name("SereinSettingsMemoryChanged")
}

extension RelayOrchestrator {
  /// One assistant's records as its Settings page lists them: what it may read (newest first),
  /// then its own paused notes, which search never returns, and its learned notes waiting for
  /// review, read through its own reader (`memoryReader`), off the main thread; nil while the
  /// store is not open. The person's own list: no model reads it, so no chat is marked.
  func settingsMemory(of profileID: String) async -> AssistantSettingsMemory? {
    guard let memory = await memoryStore() else { return nil }
    let reader = memoryReader(profileID)
    let read = try? await memory.run {
      (store: MemoryStore) -> (records: [MemoryRecord], paused: [MemoryRecord], waiting: [MemoryRecord]) in
      let records = try store.search("", reader: reader, limit: MemoryStore.recallLimit).reveal { true }
      let paused = try store.notes(owner: profileID).filter { !$0.enabled }
      let waiting = try store.proposals(owner: profileID)
      return (records: records, paused: Array(paused.reversed()), waiting: waiting)
    }
    guard let read else { return nil }
    let waiting: [RelayNote] = read.waiting.map { Self.relayNote($0) }
    return AssistantSettingsMemory(notes: read.records + read.paused, waiting: waiting)
  }

  /// Forget on a Memory page for a note the journal does not hold: the note leaves the store
  /// (its digest stays, so learning never proposes it again), and the toast's Undo brings it back
  /// while the store keeps its copy (`UndoToken.removalWindow`). False when nothing was forgotten.
  func forgetFromSettings(_ id: String) async -> Bool {
    guard let memory = await memoryStore() else { return false }
    let write: MemoryWrite? = try? await memory.run { (store: MemoryStore) -> MemoryWrite in try store.forget(id: id) }
    await refreshNotes()
    guard let write, case .done(let entry) = write else { return false }
    offerSettingsUndo("Forgot the note.", entry: entry, kind: .memoryForgot)
    return true
  }

  /// Edit in place for a note the journal does not hold (another assistant's, or a paused one):
  /// the store takes the new words through the same edit as every note (`MemoryRecord.edited`:
  /// marked edited, where it came from never changes), and the toast's Undo puts the old words
  /// back. False when the note is gone or changed meanwhile.
  func editFromSettings(_ id: String, text: String) async -> Bool {
    guard let memory = await memoryStore() else { return false }
    let words: String = text
    let write: MemoryWrite? = try? await memory.run { (store: MemoryStore) -> MemoryWrite in
      guard let current = try store.record(id: id) else { return .missing }
      return try store.update(id: id, expected: current.updatedAt, edit: MemoryEdit(text: words))
    }
    await refreshNotes()
    guard let write, case .done(let entry) = write else { return false }
    offerSettingsUndo("Changed the note.", entry: entry, kind: .memorySaved)
    return true
  }

  /// Pause (`on` false) or Resume on a Memory page: the note turns off in the store, so it is
  /// never recalled, or back on, and the lists are read again. Resume is the way back, so no
  /// toast. False when nothing changed.
  @discardableResult
  func pauseFromSettings(_ id: String, on: Bool) async -> Bool {
    guard let memory = await memoryStore() else { return false }
    let write: MemoryWrite? = try? await memory.run { (store: MemoryStore) -> MemoryWrite in
      guard let current = try store.record(id: id) else { return .missing }
      return try store.update(id: id, expected: current.updatedAt, edit: MemoryEdit(enabled: on))
    }
    await refreshNotes()
    guard let write, case .done = write else { return false }
    return true
  }

  /// The toast after a change on a Memory page, whose Undo reverses the store's log entry
  /// (`revertMemory`) and tells an open page to read its list again.
  private func offerSettingsUndo(_ line: String, entry: String, kind: Receipt.Kind) {
    let token: UndoToken = UndoToken.removal(entry: Self.memoryUndoPrefix + entry, kind: kind)
    ToastCenter.shared.show(line, actionTitle: "Undo", commandZ: true) { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        _ = await self.revertMemory(token)
        NotificationCenter.default.post(name: AssistantSettingsMemory.changed, object: nil)
      }
    }
  }
}
