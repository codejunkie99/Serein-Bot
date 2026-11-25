import SereinCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ReferenceSettings: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  /// The window's sidebar is hidden: the header row clears the traffic lights and holds Show
  /// sidebar (`showSidebar`), as every other view's first row does.
  var sidebarHidden = false
  var fullScreen = false
  var showSidebar: () -> Void = {}
  @ObservedObject private var textSize = TextSizeController.shared
  @Environment(\.palette) var p
  @AppStorage("serein.settingsSection") private var savedSelected = "General"
  /// Previews open General, or the category named by `--ui-settings-section`.
  @State private var previewSelected: String = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--ui-settings-section"), index + 1 < arguments.count
    else { return "General" }
    return arguments[index + 1]
  }()
  private let isPreview = CommandLine.arguments.contains("--ui-preview")
  private let outsidePreview = CommandLine.arguments.contains("--ui-outside-agents")
  @State private var confirmClear = false
  @State private var status: String?
  @State private var showBrowserImport = false
  /// What the person typed in the search field; empty shows every page. While it holds something,
  /// the column lists the settings that match (`SettingsSearchResults`).
  @State private var query: String = {
    let arguments = CommandLine.arguments
    guard arguments.contains("--ui-preview"), let index = arguments.firstIndex(of: "--ui-settings-search"),
      index + 1 < arguments.count
    else { return "" }
    return arguments[index + 1]
  }()
  /// The open page's id. A label or an alias ("Serein") opens its page; anything else, General.
  private var selected: String {
    get { SettingsCategory.resolve(requested).id }
    nonmutating set {
      if isPreview { previewSelected = newValue } else { savedSelected = newValue }
    }
  }
  /// What was asked to open: the saved page or the preview's. It can name a sub-page after the
  /// page ("Relay/<assistant id>", from `openSettings`); `adoptRequested` opens it.
  private var requested: String { isPreview ? previewSelected : savedSelected }
  /// The open sub-page under `selected`, one key for each level; empty on the page itself. It is
  /// not saved: Settings opens on the page again next time.
  @State private var path: [String] = []
  /// The section of the open page to scroll to: a request for what used to be a sub-page
  /// (`SettingsInline`). Cleared once scrolled, so the same section can be asked for again.
  @State private var section: String?
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  private static let top = "settings.top"
  /// An alias that names what is now a part of a page opens it: "History" opens Privacy › History,
  /// the old Appearance page General's first card, and the old Keyboard page General's sub-page.
  private static let aliasPaths: [String: [String]] = [
    "history": [PrivacyKey.history],
    "appearance": [GeneralKey.appearance], "wallpaper": [GeneralKey.appearance], "tabs": [GeneralKey.appearance],
    "keyboard": [GeneralKey.keyboard],
  ]
  /// Sections that moved to another page (docs/demos/simple-settings.decision.md), by the page and
  /// key a request still names: Allowed without asking and Mac permissions are on Privacy, and the
  /// app Serein thinks with is on AI apps.
  private static let movedSections: [String: [String: (page: String, key: String)]] = [
    "Relay": [
      RelaySettingsKey.asks: ("Privacy", PrivacyKey.allowed),
      RelaySettingsKey.defaultApp: ("Agents", AIAppsKey.defaultApp),
    ],
    "Agents": [AIAppsKey.mac: ("Privacy", PrivacyKey.mac)],
  ]
  /// Settings opens in the main window's card like a tab; the shell's dropdown layer and team
  /// sheets serve it as they serve every other view.
  var body: some View {
    settingsBody.id(textSize.generation)
  }
  /// The header row (where you are, search, close), then the page list and the page.
  var settingsBody: some View {
    VStack(spacing: 0) {
      SettingsTabHeader(
        levels: levels, query: $query, go: { depth in path = Array(path.prefix(depth)) },
        close: { browser.showSettings = false },
        sidebarHidden: sidebarHidden, fullScreen: fullScreen, showSidebar: showSidebar)
      HStack(alignment: .top, spacing: 0) {
        // While the column lists search results no page is the open one; a click on a page clears the search.
        SettingsPageList(query: query, selected: searching ? "" : selected) { id in
          selected = id
          path = []
          status = nil
          query = ""
        }
        content
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(p.background).foregroundStyle(p.ink)
      .font(UIStyle.body).buttonStyle(QuietButton()).controlSize(.small).tint(p.solid)
      .toggleStyle(SettingsToggleStyle())
      .sheet(isPresented: $confirmClear) {
        ClearBrowsingDataSheet(browser: browser, agent: agent) { confirmClear = false }
          .environment(\.palette, p)
      }
      .sheet(isPresented: $showBrowserImport) {
        BrowserOnboarding(browser: browser) {
          UserDefaults.standard.set(true, forKey: "serein.browserImportOnboardingComplete")
          showBrowserImport = false
        }.environment(\.palette, p)
      }
  }
  /// The open page's label, then the title of each open sub-page level: the header's trail.
  private var levels: [String] {
    // While the column lists search results, the trail says so, not the page behind them.
    if searching { return ["Search"] }
    return [SettingsCategory.resolve(selected).label] + path.map { SettingsTitles.title($0, in: selected) }
  }
  /// The page (or sub-page) in its scrolling column.
  private var content: some View {
      ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          if searching {
            // Something is typed in the search field: the settings that match, each with its page.
            SettingsSearchResults(query: query) { entry in show(entry) }
          } else {
          if path.isEmpty { header }
          // On every page that shows a gate switch, and on each of its sub-pages.
          if GateNotice.pages.contains(selected) { GateNotice() }
          // A push or a pop crossfades (`Motion.swap`); under Reduce Motion it happens at once.
          ZStack(alignment: .topLeading) {
            page.id(SettingsCategory.request(selected, path: path)).transition(.opacity)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .animation(reduceMotion ? nil : Motion.swap, value: path)
          .environment(\.settingsNavigation, navigation)
          if let status { Text(status).role(.meta) }
          }
        }.padding(.horizontal, UIStyle.pageGutter).padding(.top, 14).padding(.bottom, 56)
          .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity).id(Self.top)
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(p.background)
      .onChange(of: path) { _, _ in reader.scrollTo(Self.top, anchor: .top) }
      .onChange(of: section) { _, key in
        guard let key else { return }
        // After the page (and a list item's page) has drawn its sections.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          if reduceMotion { reader.scrollTo(key, anchor: .top) } else { withAnimation(Motion.swap) { reader.scrollTo(key, anchor: .top) } }
          section = nil
        }
      }
      .onChange(of: savedSelected) { old, new in
        // Another page opened from outside (`openSettings("Computer")` from a sub-page's link):
        // the sub-page of the old one closes.
        if SettingsCategory.resolve(old).id != SettingsCategory.resolve(new).id { path = [] }
        adoptRequested()
      }
      .onAppear {
        adoptRequested()
        openRequested(reader)
        // `--ui-settings-scroll <group title>`: a preview opens scrolled to that group.
        let arguments = CommandLine.arguments
        guard isPreview else { return }
        let group: String
        if let i = arguments.firstIndex(of: "--ui-settings-scroll"), i + 1 < arguments.count {
          group = arguments[i + 1]
        } else if outsidePreview, selected == "Agents" {
          // `--ui-outside-agents`: the Other agents that use Serein sub-page.
          if path.isEmpty { go([AIAppsKey.outside]) }
          group = "MCP connection"
        } else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reader.scrollTo(group, anchor: .top) }
      }
      }
  }
  /// The page, or the sub-page `path` names under it.
  @ViewBuilder private var page: some View {
    switch selected {
    case "Agents": agents
    case "Relay": RelaySettings(agent: agent)
    case "Computer": ComputerSettings()
    case "Talking": talking
    case "Privacy": privacy
    case "Passwords": passwords
    case "Usage": UsageDashboard()
    // General, which also holds what the Appearance and Keyboard pages had.
    default: general
    }
  }
  /// The page's title and sentence, on the page itself. A sub-page draws its own title; the
  /// header's trail leads back up (Esc goes back one level, × closes Settings).
  private var header: some View {
    let category: SettingsCategory = SettingsCategory.resolve(selected)
    return SettingsPageHeader(category.label, sentence: category.summary)
  }
  private var navigation: SettingsNavigation {
    SettingsNavigation(path: path, push: { key in go(path + [key]) }, pop: { pop() }, go: { next in go(next) })
  }
  /// Opens `next` under the open page: a list item's page opens, and a key that is a section of
  /// its page now scrolls there instead (`SettingsInline`).
  private func go(_ next: [String]) {
    // A section that moved to another page opens where it lives now.
    if let first = next.first, let to = Self.movedSections[selected]?[first] {
      selected = to.page
      path = []
      SettingsFolds.shared.reveal(to.key, on: to.page)
      section = to.key
      return
    }
    let split = SettingsInline.split(next, page: selected)
    if path != split.path { path = split.path }
    if let key = split.section {
      // A section inside the page's Advanced fold: the fold opens before the scroll.
      SettingsFolds.shared.reveal(key, on: selected)
      section = key
    }
  }
  private func pop() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }
  /// Something is typed in the search field (`--ui-settings-search <words>` in a preview).
  private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// A search result was clicked: the search clears and its page opens at the setting, with the
  /// page's fold open when the setting sits inside it. What left Settings opens its Marketplace place.
  private func show(_ entry: SettingsEntry) {
    query = ""
    status = nil
    if let place = entry.place {
      browser.openMarketplace(place)
      return
    }
    if entry.folded { SettingsFolds.shared.set(entry.page, open: true) }
    let sub: [String] = entry.key.map { [$0] } ?? []
    if isPreview || selected == entry.page {
      selected = entry.page
      go(sub)
    } else {
      // The saved page changes: `onChange(of: savedSelected)` closes the old sub-page and adopts this one.
      selected = SettingsCategory.request(entry.page, path: sub)
    }
    // A folded setting with no section of its own: the fold's first row.
    if entry.key == nil, entry.folded { section = "Advanced" }
  }
  /// A request that names a sub-page ("Relay/<assistant id>", from `openSettings` or
  /// `--ui-settings-section`) opens it; the saved choice keeps only the page's id.
  private func adoptRequested() {
    let raw: String = requested
    let named: [String] = SettingsCategory.subpath(raw)
    let sub: [String] = named.isEmpty ? (Self.aliasPaths[raw.lowercased()] ?? []) : named
    guard !sub.isEmpty else { return }
    let id: String = SettingsCategory.resolve(raw).id
    selected = id
    go(sub)
  }
  /// A section the composer asked for (`/mcp`): its page, and for a group that lives
  /// on AI apps (an alias of that page), the sub-page that holds that group.
  private func openRequested(_ reader: ScrollViewProxy) {
    guard let section = browser.requestedSettingsSection else { return }
    browser.requestedSettingsSection = nil
    selected = SettingsCategory.resolve(section).id
    go(SettingsCategory.subpath(section))
    guard section == "MCP connection" else { return }
    // A group in AI apps' Other agents that use Serein, which sits in the page's Advanced fold.
    SettingsFolds.shared.reveal(section, on: selected)
    path = []
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reader.scrollTo(section, anchor: .top) }
  }
  /// Settings › General (GeneralSettings.swift).
  var general: some View { GeneralSettings(browser: browser) }
  /// Settings › AI apps (AIAppsSettings.swift).
  var agents: some View { AIAppsSettings(browser: browser, agent: agent) }
  var talking: some View { TalkingSettings() }
  /// Settings › Privacy (PrivacySettings.swift).
  var privacy: some View { PrivacySettings(browser: browser, confirmClear: $confirmClear) }
  /// Settings › Vault (id `Passwords`): the saved sign-ins and keys with their search, tabs and New
  /// item (`PasswordSettings`). Its Options fold holds the saving options, CSV, Import a chat and
  /// Bring from your browser.
  var passwords: some View {
    VStack(alignment: .leading, spacing: 24) {
      PasswordSettings()
      SettingsAdvanced(page: "Passwords", count: 6, title: "Options") {
        SettingsBlock("Saving and filling") { PasswordOptions() }
        SettingsRowList("From somewhere else") {
          SettingsSummaryRow(
            title: "Import a chat from Claude Code or Codex",
            answer: "Choose one session log and confirm its project folder. Resume keeps its session.",
            hint: "Opens a file chooser", open: { agent.importSession() }
          ) {
            SettingsGlyphTile(systemName: "bubble.left")
          }
        }
        SettingsSection(PasswordsKey.bring, title: "Bring from your browser") {
          SettingsPageHeader("Bring from your browser", sentence: "Bookmarks, history, cookies and sign-ins from your browser or a file. Nothing changes in your browser.")
          importSettings
        }
      }
    }
  }
  var importSettings: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsBlock("From your browser") {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Bookmarks and history")
            Text("Detect local browser profiles, preview counts, then choose exactly what to import.")
              .foregroundStyle(p.secondary)
          }
          Spacer()
          Button("Open browser import…") { showBrowserImport = true }
        }
        SettingsNote("Serein reads a temporary local snapshot and never changes the source browser. Passwords, cookies, passkeys and sign-in secrets are excluded.")
      }
      SettingsBlock("From a file", info: "Sign-ins and cookies you bring work on pages you open in Serein, and on a task you start from one of those pages. Cookie import accepts only an explicit Netscape cookies.txt export and asks again before writing website data. Passkeys remain with your browser or credential provider.") {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Bookmarks HTML")
            Text("Import links from your browser into Saved.").foregroundStyle(p.secondary)
          }
          Spacer()
          Button("Import Bookmarks HTML…") { importBookmarks() }
        }
        Divider().overlay(p.line)
        Button("Import exported website cookies…") { browser.importCookies() }
        Button("Bring sign-ins from Chrome, Firefox, Safari or another browser…") { SignInImportWindow.show() }
        SettingsNote("Sign-ins you bring work on pages you open in Serein, and on a task you start from one. Cookie import asks again before writing website data. Passkeys stay with your browser or credential provider.")
      }
    }
  }
  func group<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
    SettingsGroup(title, content: content)
  }
  func importBookmarks() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.html]
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let parsed = try BrowserDataReader.htmlBookmarks(url)
      let merged = BrowserImportMerger.merge(
        visits: [], marks: parsed.0, existingVisits: browser.visits, existingMarks: browser.marks)
      browser.marks = merged.allMarks
      try browser.library.save(browser.marks, to: "marks/saved.json")
      status = "Imported \(merged.importedMarks.count) bookmarks into Saved."
    } catch { status = error.localizedDescription }
  }
}

/// The sub-pages of Passwords.
enum PasswordsKey {
  static let bring = "bring"
}
