import AppKit
import SereinCore
import SwiftUI

/// The sections of an assistant's page (AssistantSettingsPage.swift) that edit what it is:
/// Instructions (its one box), Apps it can use (Can use and the sites it never opens, never wider
/// than the person's settings) and Links (the links it owns, with Copy link, Pause and Delete).
/// Each change is saved through the existing paths.

/// Instructions: the assistant's one box, in the person's own words (`AssistantInstructions`),
/// which it reads every turn. Save puts them in one place (`setInstructions`); Revert puts back
/// the saved words. Unsaved words belong to this page's assistant: the page is drawn again, empty,
/// for another one. Over the limit (old fields that did not fit together at launch), the count
/// turns red and Save says to shorten them.
struct AssistantInstructionsSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @Environment(\.palette) private var p
  /// Unsaved words; nil shows the saved ones.
  @State private var draft: String?
  @State private var problem: String?
  private var saved: String { relay.instructionsText(profile) }
  private var words: String { draft ?? saved }
  private var changed: Bool { draft.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) != saved } ?? false }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SettingsPageHeader(
        "Instructions", sentence: "What \(profile.name) should know and how it should work, in your words. It reads them every turn.")
      field
      SettingsSaveBar(changed: changed, problem: problem, subject: "the instructions", revert: {
        draft = nil
        problem = nil
      }, save: save)
    }
  }
  private var field: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField("Such as: Keep replies short. Never book anything before asking me.", text: Binding(
        get: { words }, set: { draft = $0 }), axis: .vertical)
      .textFieldStyle(.plain).font(AssistantType.body).lineLimit(5...14).foregroundStyle(p.ink)
      .padding(8).background(p.background, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
      .textInputCursor()
      .accessibilityLabel("Instructions for \(profile.name)")
      HStack(alignment: .top) {
        Text("Advice only: it never grants access or skips asking first.").role(.meta)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        let count: Int = words.trimmingCharacters(in: .whitespacesAndNewlines).count
        Text("\(count.formatted()) / \(AssistantInstructions.limit.formatted())").font(AssistantType.figures)
          .foregroundStyle(count > AssistantInstructions.limit ? p.danger : p.secondary).fixedSize()
      }
    }
  }
  private func save() {
    problem = relay.setInstructions(words, for: profile)
    guard problem == nil else { return }
    draft = nil
  }
}

/// Apps it can use: a switch for each place the person allows (each saved at once, at least one
/// stays on), a row that opens the Settings page for a place the person has off, the sites it
/// never opens on top of the person's own, and its computer. It can never use more than the
/// person allows Serein (`saveAssistant` refuses it, and those switches are not shown). While it
/// can use Connected apps, "Connected apps it can use" narrows them to the apps switched on
/// (`AssistantScope.apps`): every app by default, apps connected later included.
struct AssistantAppsSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @ObservedObject private var composio = ComposioApps.shared
  @ObservedObject private var plugins = PluginHost.shared
  @Environment(\.palette) private var p
  @GateStorage(ComputerPolicy.enabledKey) private var computerOn = false
  @State private var problem: String?
  @State private var appsProblem: String?
  /// Composio's accounts are listed: until then the app switches would save a list without them.
  @State private var appsLoaded = false
  @State private var site = ""
  @State private var siteProblem: String?
  private static let notes: [AssistantPlace: String] = [
    .web: "Look things up and use websites in its own tabs.", .page: "Work on the page you're viewing, after you say yes.",
    .answer: "Reply in words, without opening anything.", .mac: "Use apps on your Mac.", .project: "Work in your project folders.",
    .mail: "Search, read and draft your email; sending asks you.",
    .messages: "Send texts that ask you first; read chosen conversations if you allow it.",
    .calendar: "Read your calendar and reminders; changes ask you.",
    .contacts: "Find names, email addresses and phone numbers. Read only.",
    .connectedApps: "Use apps you connected, like Gmail or Slack, through Composio or an MCP server.",
    .computer: "Work in its own computer, apart from your Mac.",
  ]
  var body: some View {
    let scope: AssistantScope = relay.editableScope(profile)
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Apps it can use", sentence: "What \(profile.name) may use. It never gets more than you allow Serein.")
      SettingsRowList("Can use", note: problem) {
        ForEach(AssistantPlace.allCases, id: \.self) { place in placeRow(place, scope: scope) }
      }
      // Serein itself follows the Marketplace's switches (On this Mac, Your apps); only another assistant gets its own list.
      if profile.id != relay.team.mainProfileID, scope.destinations.contains(.connectedApps) { appsBlock(scope) }
      SettingsBlock("Sites it never opens") { sites(scope) }
      SettingsRowList("Its computer") {
        SettingsSummaryRow(
          title: "Serein's computer", answer: computerAnswer(scope), hint: "Opens Settings › Serein's computer",
          open: { TeamSheets.openSettings(TeamSheets.settingsPage(.computer)) }
        ) {
          SettingsGlyphTile(systemName: "desktopcomputer")
        }
      }
    }
    .task {
      guard ComposioApps.available, profile.id != relay.team.mainProfileID else { return }
      do {
        try await composio.refresh()
        appsLoaded = true
      } catch {
        appsProblem = "Your Composio apps could not be listed, so this list can't be changed now. \(error.localizedDescription)"
      }
    }
  }
  @ViewBuilder private func placeRow(_ place: AssistantPlace, scope: AssistantScope) -> some View {
    if relay.personPlaces.contains(place) {
      SettingsSwitchRow(
        title: place.label, answer: Self.notes[place] ?? "",
        isOn: Binding(get: { scope.destinations.contains(place) }, set: { on in set(place, on) }),
        label: "\(profile.name) can use \(place.label)"
      ) {
        SettingsGlyphTile(systemName: CanUseChips.icon(place))
      }
    } else {
      let page: (id: String, name: String) = TeamSheets.settingsPage(place)
      SettingsSummaryRow(
        title: place.label, answer: "Off for Serein. Turn it on in \(page.name).", hint: "Opens \(page.name)",
        open: { TeamSheets.openSettings(page) }
      ) {
        SettingsGlyphTile(systemName: CanUseChips.icon(place))
      }
      .opacity(0.6)
    }
  }
  private func set(_ place: AssistantPlace, _ on: Bool) {
    problem = nil
    var scope: AssistantScope = relay.editableScope(profile)
    if on {
      scope.destinations.insert(place)
    } else if scope.destinations.count <= 1 {
      // At least one place stays on: the switch stays as it was.
      problem = "\(profile.name) needs at least one thing it can use."
      return
    } else {
      scope.destinations.remove(place)
    }
    problem = relay.saveFromSettings(profile, colour: AssistantColour.key(profile.colour), scope: scope)
  }
  @ViewBuilder private func sites(_ scope: AssistantScope) -> some View {
    if !scope.neverSites.isEmpty {
      FlowChips(items: scope.neverSites) { host in
        HStack(spacing: 4) {
          Text(verbatim: host).font(UIStyle.monoMeta).foregroundStyle(p.ink).lineLimit(1)
          Button { removeSite(host) } label: {
            InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary).frame(width: 14, height: 14)
              .contentShape(Rectangle())
          }.buttonStyle(.pressable).accessibilityLabel("Remove \(host)")
        }.padding(.leading, 8).padding(.trailing, 4).frame(height: 22).background(p.track, in: Capsule())
      }
    }
    HStack(spacing: 8) {
      TextField("Add a site, like example.com", text: $site).textFieldStyle(.serein)
        .onSubmit(addSite).accessibilityLabel("Add a site")
      Button("Add", action: addSite).buttonStyle(QuietButton()).disabled(site.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    if let siteProblem { Text(verbatim: siteProblem).font(AssistantType.meta).foregroundStyle(p.danger) }
    SettingsNote("\(profile.name) won't open these, on top of your own Never sites.")
  }
  private func addSite() {
    siteProblem = nil
    guard let host = SitePolicy.site(site) else {
      siteProblem = "Use a site name, like example.com."
      return
    }
    var scope: AssistantScope = relay.editableScope(profile)
    guard scope.neverSites.count < AssistantBoard.neverSitesLimit else {
      siteProblem = "\(AssistantBoard.neverSitesLimit) sites is the most for one assistant."
      return
    }
    if !scope.neverSites.contains(host) { scope.neverSites.append(host) }
    siteProblem = relay.saveFromSettings(profile, colour: AssistantColour.key(profile.colour), scope: scope)
    if siteProblem == nil { site = "" }
  }
  private func removeSite(_ host: String) {
    var scope: AssistantScope = relay.editableScope(profile)
    scope.neverSites.removeAll { $0 == host }
    siteProblem = relay.saveFromSettings(profile, colour: AssistantColour.key(profile.colour), scope: scope)
  }
  /// One connected app as the list shows it: a Composio app (by its slug) or a server connected
  /// by address (by its plugin id).
  private struct AppChoice: Identifiable {
    let id: String
    let name: String
    let server: Bool
  }
  private var appChoices: [AppChoice] {
    var rows: [AppChoice] = []
    if ComposioApps.available {
      for app in Set(composio.accounts.map(\.app)).sorted() {
        rows.append(AppChoice(id: AssistantScope.composioAppKey(app), name: ConnectedApps.name(app), server: false))
      }
    }
    for package in plugins.packages where plugins.isConnection(package) {
      rows.append(AppChoice(id: AssistantScope.connectionAppKey(package.id), name: package.name, server: true))
    }
    return rows
  }
  @ViewBuilder private func appsBlock(_ scope: AssistantScope) -> some View {
    let choices = appChoices
    SettingsRowList("Connected apps it can use", note: appsProblem) {
      SettingsSwitchRow(
        title: "Every connected app",
        answer: scope.apps == nil ? "Apps you connect later too" : "Only the apps switched on below",
        isOn: Binding(get: { scope.apps == nil }, set: { every in setEveryApp(every, choices: choices) }),
        label: "\(profile.name) can use every connected app"
      ) {
        SettingsGlyphTile(systemName: "square.grid.2x2")
      }
      if scope.apps != nil {
        ForEach(choices) { choice in
          SettingsSwitchRow(
            title: choice.name, answer: choice.server ? "MCP server" : "Through Composio",
            isOn: Binding(get: { scope.allowsApp(choice.id) }, set: { on in setApp(choice.id, on, choices: choices) }),
            label: "\(profile.name) can use \(choice.name)"
          ) {
            SettingsGlyphTile(systemName: choice.server ? "server.rack" : "square.grid.2x2")
          }
        }
      }
    }
    .disabled(ComposioApps.available && !appsLoaded)
    SettingsNote(
      choices.isEmpty
        ? "No apps are connected yet. Connect them in the Marketplace."
        : "\(profile.name) can't list, read or change an app switched off here. Your own settings for each app still apply.")
  }
  /// Off keeps the apps it has now, so the switches below start where it was; on is every app again.
  private func setEveryApp(_ every: Bool, choices: [AppChoice]) {
    appsProblem = nil
    var scope: AssistantScope = relay.editableScope(profile)
    scope.apps = every ? nil : choices.map(\.id)
    appsProblem = relay.saveFromSettings(profile, colour: AssistantColour.key(profile.colour), scope: scope)
  }
  private func setApp(_ key: String, _ on: Bool, choices: [AppChoice]) {
    appsProblem = nil
    var scope: AssistantScope = relay.editableScope(profile)
    var list: [String] = scope.apps ?? choices.map(\.id)
    list.removeAll { $0 == key }
    if on { list.append(key) }
    scope.apps = list
    appsProblem = relay.saveFromSettings(profile, colour: AssistantColour.key(profile.colour), scope: scope)
  }
  private func computerAnswer(_ scope: AssistantScope) -> String {
    guard computerOn else { return "Off for Serein" }
    return scope.destinations.contains(.computer) ? "On · its own desktop" : "It can't use it"
  }
}

/// Links: the links this assistant owns (`OwnedLink`, `spec.owner`), each with Copy link (the
/// address and secret go on the clipboard marked concealed, `copyLink`), Pause or Resume
/// (`setLinkPaused`) and Delete (`removeLinkForUndo`, with Undo on its toast for 10 seconds), and
/// whether this Mac takes links at all, which opens Assistants › Links from other apps. Nothing
/// changes while relay/links.json could not be read.
struct AssistantLinksSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var desk: AssistantDesk
  let profile: RelayProfile
  @Environment(\.settingsNavigation) private var nav
  @Environment(\.palette) private var p
  private var unreadable: Bool { relay.isUnreadable(RelayOrchestrator.linksFile) }
  var body: some View {
    let mine: [OwnedLink] = desk.links.filter { $0.spec.owner == profile.id }
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Links", sentence: "Addresses other apps use to start \(profile.name). Ask \(profile.name) in its chat to make one.")
      SettingsRowList("Its links", note: unreadable ? RelayStateFile.words(for: RelayOrchestrator.linksFile) : nil) {
        if mine.isEmpty {
          SettingsEmptyRow(glyph: "link", text: "No links yet. Ask \(profile.name) to “make a link for when …”.")
        }
        ForEach(mine) { link in linkRow(link) }
      }
      SettingsRowList("On this Mac") {
        SettingsSummaryRow(
          title: "Links from other apps", answer: RelayHookServer.enabled ? "This Mac takes links" : "Off: this Mac takes no links",
          open: { nav.go([RelaySettingsKey.links]) }
        ) {
          SettingsGlyphTile(systemName: "network")
        }
      }
    }
  }
  private func linkRow(_ link: OwnedLink) -> some View {
    let when: String = link.lastDelivery.map { "Last used " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not used yet"
    let state: String = link.isPaused ? "Paused · " : "On · "
    let status: String = state + when
    return SettingsListRow(name: link.spec.name, status: status, expandable: false) {
      SettingsGlyphTile(systemName: "link")
    } trailing: {
      HStack(spacing: 4) {
        Button("Copy link") { relay.copyLink(link.id) }.buttonStyle(QuietButton())
          .accessibilityLabel("Copy the link \(link.spec.name)")
        Button(link.isPaused ? "Resume" : "Pause") { relay.setLinkPaused(link.id, !link.isPaused) }.buttonStyle(QuietButton())
          .disabled(unreadable)
          .accessibilityLabel((link.isPaused ? "Resume the link " : "Pause the link ") + link.spec.name)
        Button("Delete") { delete(link) }.buttonStyle(QuietButton()).disabled(unreadable)
          .accessibilityLabel("Delete the link \(link.spec.name)")
      }
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }
  private func delete(_ link: OwnedLink) {
    let id: String = link.id
    guard relay.removeLinkForUndo(id) != nil else { return }
    let orchestrator: RelayOrchestrator = relay
    ToastCenter.shared.show("Deleted \(link.spec.name).", actionTitle: "Undo", commandZ: true) {
      _ = orchestrator.restoreRemovedLink(id)
    }
  }
}
