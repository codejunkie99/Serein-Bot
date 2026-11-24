#if DEBUG
import Foundation
import SereinCore

/// Settings pages and their sub-pages (`SettingsCategory`): every stored id, label and alias still
/// opens its page, and a sub-page after the page's name opens that page and is read apart.
extension AssistantCoreChecks {
  static func settingsPaths(_ check: Check) throws {
    // Eight pages in one flat list (docs/demos/simple-settings.decision.md).
    let ids: [String] = ["General", "Talking", "Relay", "Agents", "Computer", "Privacy", "Passwords", "Usage"]
    try check(SettingsCategory.all.map(\.id) == ids, "Settings has its eight pages, in list order")
    try check(SettingsCategory.all.map(\.label) == ["General", "Voice", "Assistants", "AI apps", "Serein's computer", "Privacy", "Vault", "Usage"],
      "The list reads General, Voice, Assistants, AI apps, Serein's computer, Privacy, Vault, Usage")
    try check(SettingsCategory.all.allSatisfy { $0.group.isEmpty }, "The list has no group captions")
    try check(["Appearance", "Wallpaper", "Tabs", "Keyboard"].allSatisfy { SettingsCategory.resolve($0).id == "General" && SettingsCategory.moved($0) == nil },
      "The old Appearance and Keyboard pages open General, which holds what they had")
    try check(["Vault", "Passwords", "Import", "vault"].allSatisfy { SettingsCategory.resolve($0).id == "Passwords" },
      "Vault is the Passwords page under its new name, and the old names still open it")
    for id in ids {
      try check(SettingsCategory.resolve(id).id == id, "The stored id \(id) opens its page")
      try check(SettingsCategory.moved(id) == nil, "The page \(id) is still in Settings, so it opens no Marketplace place")
    }
    // Apps, connections and plugins left Settings for the Marketplace: their old names open its places.
    try check(!SettingsCategory.all.contains { ["Connections", "Plugins"].contains($0.id) },
      "Settings has no Connections or Plugins page")
    try check(SettingsCategory.moved("Plugins") == .plugins && SettingsCategory.moved("plugins/abc") == .plugins,
      "The old Plugins page, with or without a sub-page, opens the Marketplace's Plugins")
    try check(SettingsCategory.moved("Connections") == .yours && SettingsCategory.moved("Composio") == .yours
      && SettingsCategory.moved("MCP") == .yours && SettingsCategory.moved("Connected apps") == .yours,
      "The old Connections page and its app aliases open the Marketplace's Your apps")
    try check(["Mail", "Messages", "Calendar", "Reminders", "Contacts", "Notes", "On this Mac"].allSatisfy { SettingsCategory.moved($0) == .mac },
      "The Mac apps' old aliases open the Marketplace's On this Mac")
    try check(SettingsCategory.moved("MCP connection") == nil && SettingsCategory.resolve("MCP connection").id == "Agents",
      "MCP connection is still a group on AI apps")
    try check(MarketplacePlace.yours.label == "Your apps" && MarketplacePlace.yours.parent == nil && MarketplacePlace.yours.columnRow == .yours,
      "Your apps is a row of the Marketplace's column")
    try check(SettingsCategory.resolve("Serein").id == "Relay", "The alias Serein opens the assistants' page")
    try check(SettingsCategory.resolve("AI apps").id == "Agents", "The label AI apps opens Agents")
    try check(SettingsCategory.resolve("Voice").id == "Talking", "The label Voice opens the Talking page")
    try check(SettingsCategory.resolve("Assistants").id == "Relay", "The label Assistants opens the Relay page")
    try check(SettingsCategory.resolve("history").id == "Privacy", "An alias opens its page in any case")
    try check(SettingsCategory.resolve("Nothing like this").id == "General", "An unknown name opens General")
    try check(SettingsCategory.resolve("Relay/abc").id == "Relay", "A sub-page after the page is ignored by resolve")
    try check(SettingsCategory.resolve("Serein/abc/routines").id == "Relay", "An alias with a sub-page opens its page")
    try check(SettingsCategory.subpath("Relay/abc") == ["abc"], "The sub-page after the page is read")
    try check(SettingsCategory.subpath("Relay//abc/routines/") == ["abc", "routines"], "Empty parts are dropped")
    try check(SettingsCategory.subpath("Relay").isEmpty, "A plain page has no sub-page")
    try check(SettingsCategory.request("Relay", path: ["abc"]) == "Relay/abc", "A request joins the page and its sub-page")
    try check(SettingsCategory.request("Relay", path: []) == "Relay", "A request with no sub-page is the page's id")
    let all = SettingsCategory.all
    let names: [String] = all.map(\.id) + all.map(\.label) + all.flatMap(\.aliases)
    try check(!names.contains { $0.contains(SettingsCategory.separator) }, "No id, label or alias holds the separator")
    try check(all.allSatisfy { !$0.summary.isEmpty }, "Every page has its one sentence")
    try MainActor.assumeIsolated { try settingsSearch(check) }
  }

  /// Settings search (`SettingsIndex`): every setting it lists is on a page that exists, at a section
  /// or sub-page that page has, and one inside a fold says so, so a click opens the fold first.
  @MainActor private static func settingsSearch(_ check: Check) throws {
    let entries: [SettingsEntry] = SettingsIndex.all
    let pages: Set<String> = Set(SettingsCategory.all.map(\.id))
    try check(Set(entries.map(\.id)).count == entries.count, "Each setting in the search index is listed once")
    try check(entries.allSatisfy { $0.place != nil || pages.contains($0.page) }, "Each setting names a page Settings has, or a Marketplace place")
    let lost: [String] = entries.filter { entry in
      guard entry.place == nil, let key = entry.key else { return false }
      let subpage: Bool = entry.page == "General" && GeneralKey.pages[key] != nil
      return !subpage && !SettingsInline.isSection(key, page: entry.page, under: [])
    }.map(\.id)
    try check(lost.isEmpty, "Each setting's key is a section or a sub-page of its page. Not: \(lost)")
    let unfolded: [String] = entries.filter { entry in
      guard let key = entry.key else { return false }
      return SettingsFolds.folded[entry.page]?.contains(key) == true && !entry.folded
    }.map(\.id)
    try check(unfolded.isEmpty, "A setting whose section sits in a fold is marked folded. Not: \(unfolded)")
    try check(pages.subtracting(["Usage"]).allSatisfy { page in entries.contains { $0.page == page && $0.folded } },
      "Every page with a fold has a folded setting to find")
    func found(_ query: String) -> [String] { SettingsIndex.search(query).map(\.title) }
    try check(found("dark").contains("Theme") && SettingsIndex.search("dark").allSatisfy { $0.page == "General" },
      "Searching dark finds the theme, on General")
    try check(found("webhooks") == ["Links from other apps"] && SettingsIndex.pages("webhooks").map(\.id) == ["Relay"],
      "Searching webhooks finds Links from other apps, and keeps Assistants in the list")
    try check(SettingsIndex.search("webhooks").first.map(SettingsIndex.place) == "Assistants › Advanced",
      "A folded setting says it is under Advanced")
    try check(SettingsIndex.search("bitwarden").first.map(SettingsIndex.place) == "Vault › Options",
      "The Vault's fold is named Options")
    try check(SettingsIndex.search("plugins").contains { $0.place == .plugins } && SettingsIndex.search("composio").first?.place == .yours,
      "What left Settings is still found, and opens its Marketplace place")
    try check(SettingsIndex.search("plugins").first.map(SettingsIndex.place) == "Marketplace › Plugins",
      "A Marketplace result says where it is")
    try check(found("  ").isEmpty && found("zzz").isEmpty, "An empty search, or one nothing matches, lists no setting")
    try check(SettingsIndex.pages("zzz").isEmpty, "A search nothing matches keeps no page")
    try check(found("accessibility") == ["Mac permissions"] && SettingsIndex.search("accessibility").first?.page == "Privacy",
      "Mac permissions are found on Privacy")
    try check(found("serein thinks").contains("Serein thinks with") && SettingsIndex.search("serein thinks").first?.page == "Agents",
      "The app Serein thinks with is found on AI apps")
  }

  /// The sign-in step for every AI app: the CLI's own signed-out errors, and the button's words.
  static func signIn(_ check: Check) throws {
    let signedOut = [
      "Not logged in · Please run /login", "Invalid API key · Please run /login",
      "OAuth token has expired. Please obtain a new token or refresh your existing token.",
      "Error: Not logged in. Run `codex login`.", "unexpected status 401 Unauthorized",
      "Authentication required", "Please set an Auth method in your settings.json",
      "Not authenticated. Run cursor-agent login.",
    ]
    for error in signedOut {
      try check(HarnessParse.asksSignIn(error), "A signed-out error asks for sign-in: \(error)")
    }
    let other = [
      "Claude AI usage limit reached|1800000000", "Codex exited (1). network timeout",
      "Stopped after 20 minutes, the limit for this kind of task.",
      String(repeating: "log line ", count: 80) + "not logged in",
    ]
    for error in other {
      try check(!HarnessParse.asksSignIn(error), "Another error does not ask for sign-in: \(error.prefix(40))")
    }
    for driver in HarnessDriver.allCases {
      let name = driver.displayName
      try check(HarnessParse.signInTitle(name, action: .signIn) == "Sign in to \(name)", "\(name) signs in from its button")
      try check(HarnessParse.signInTitle(name, action: .install) == "Install \(name)", "\(name) installs from its button")
      try check(HarnessParse.signInTitle(name, action: .update) == "Update \(name)", "\(name) updates from its button")
      try check(HarnessParse.signInTitle(name, action: .checking) == "Connect \(name)", "\(name) connects while unknown")
    }
    var snapshot = HarnessSnapshot(instance: HarnessInstance(driver: .claude), status: .ready)
    snapshot.checkedAt = Date()
    snapshot.installed = true
    snapshot.signedIn = false
    try check(HarnessPrimaryAction.of(snapshot) == .signIn, "An installed app that is signed out needs Sign in")
  }
}
#endif
