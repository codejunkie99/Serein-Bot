import SereinCore
import SwiftUI

/// One setting a Settings search finds: its name as the page shows it, the page it is on, and where
/// on that page (docs/demos/simple-settings.decision.md). Search lists these, and a click opens the
/// page there; the control stays on its page, so a gated switch keeps its one authentication check.
struct SettingsEntry: Identifiable, Equatable {
  let title: String
  /// The page's id (`SettingsCategory.id`).
  let page: String
  /// The section or sub-page key `ReferenceSettings.go` opens; nil is the top of the page (or of
  /// its fold, when `folded`).
  var key: String?
  /// Inside the page's Advanced fold: the fold opens first.
  var folded = false
  /// What left Settings for the Marketplace: the place that holds it now. `page` is then unused.
  var place: MarketplacePlace?
  /// Everyday words that are not in the title.
  var words: [String] = []
  var id: String { (place.map { "marketplace.\($0)" } ?? page) + "/" + title }
}

/// Every setting a search can find, in page order then the order on the page.
@MainActor enum SettingsIndex {
  static let all: [SettingsEntry] = general + voice + assistants + aiApps + computer + privacy + vault + [
    SettingsEntry(title: "What you did in Serein", page: "Usage", words: ["usage", "stats", "tokens", "counts"]),
  ] + marketplace

  private static let general: [SettingsEntry] = [
    SettingsEntry(title: "Theme", page: "General", key: GeneralKey.appearance, words: ["dark", "light", "mode", "appearance", "colour", "color"]),
    SettingsEntry(title: "Text size", page: "General", key: GeneralKey.appearance, words: ["font", "bigger", "smaller", "zoom"]),
    SettingsEntry(title: "Open Serein when you log in", page: "General", key: GeneralKey.startup, words: ["startup", "launch", "login items"]),
    SettingsEntry(title: "Keep the Mac awake while tasks run", page: "General", key: GeneralKey.startup, words: ["sleep"]),
    SettingsEntry(title: "Search engine", page: "General", key: GeneralKey.search, words: ["DuckDuckGo", "Google"]),
    SettingsEntry(title: "Updates", page: "General", key: GeneralKey.updates, words: ["version", "check now"]),
    SettingsEntry(title: "Darken pages a task shows you", page: "General", folded: true, words: ["dark", "websites"]),
    SettingsEntry(title: "Serein's look", page: "General", key: GeneralKey.look, folded: true, words: ["hologram", "glow", "avatar", "face"]),
    SettingsEntry(title: "Keyboard shortcuts", page: "General", key: GeneralKey.keyboard, folded: true, words: ["hotkeys", "keys"]),
    SettingsEntry(title: "Downloads", page: "General", key: GeneralKey.downloads, folded: true, words: ["folder", "files"]),
    SettingsEntry(title: "Tips and setup", page: "General", key: GeneralKey.tips, folded: true, words: ["show tips", "onboarding", "welcome"]),
  ]
  private static let voice: [SettingsEntry] = [
    SettingsEntry(title: "Hold a key to talk instead of typing", page: "Talking", words: ["push to talk", "dictation", "speech", "mic"]),
    SettingsEntry(title: "Say “Serein” to ask", page: "Talking", words: ["wake phrase", "wake word", "hey"]),
    SettingsEntry(title: "Language", page: "Talking", words: ["speak", "locale"]),
    SettingsEntry(title: "Read replies aloud", page: "Talking", words: ["voice", "speak", "talks"]),
    SettingsEntry(title: "Setup and microphone", page: "Talking", folded: true, words: ["mic", "input", "test"]),
    SettingsEntry(title: "Speak progress in calls", page: "Talking", folded: true),
    SettingsEntry(title: "Answer low-risk questions by voice", page: "Talking", folded: true, words: ["calls"]),
    SettingsEntry(title: "Fix likely mishearings and drop fillers with my AI app", page: "Talking", folded: true, words: ["privacy", "transcript"]),
    SettingsEntry(title: "Keep my recordings for 30 days", page: "Talking", folded: true, words: ["privacy", "audio"]),
  ]
  private static let assistants: [SettingsEntry] = [
    SettingsEntry(title: "Your assistants", page: "Relay", words: ["persona", "memory", "routines", "add", "name"]),
    SettingsEntry(title: "Teams", page: "Relay", key: RelaySettingsKey.teams, words: ["group"]),
    SettingsEntry(title: "Morning brief", page: "Relay", words: ["daily", "briefing"]),
    SettingsEntry(title: "Tell me when tasks finish", page: "Relay", words: ["notifications", "notify"]),
    SettingsEntry(title: "Ask Serein from any app", page: "Relay", key: RelaySettingsKey.anyApp, words: ["shortcut", "hotkey", "summon", "menu bar", "Fn"]),
    SettingsEntry(title: "Updates from your AI apps", page: "Relay", folded: true, words: ["notifications"]),
    SettingsEntry(title: "Read your AI chats", page: "Relay", folded: true, words: ["Claude Code", "Codex", "learn"]),
    SettingsEntry(title: "Suggest routines", page: "Relay", folded: true),
    SettingsEntry(title: "What Serein can see while you talk", page: "Relay", folded: true, words: ["screen", "selection", "window", "picture"]),
    SettingsEntry(title: "Keep your assistants at the edge of the screen", page: "Relay", folded: true, words: ["dock", "faces"]),
    SettingsEntry(title: "Shortcuts for asking and stopping", page: "Relay", folded: true, words: ["hotkey", "stop", "kill switch"]),
    SettingsEntry(title: "Your reminders", page: "Relay", key: RelaySettingsKey.reminders, folded: true, words: ["schedule", "alerts", "goals"]),
    SettingsEntry(title: "Links from other apps", page: "Relay", key: RelaySettingsKey.links, folded: true, words: ["webhooks"]),
    SettingsEntry(title: "Task downloads", page: "Relay", key: RelaySettingsKey.downloads, folded: true, words: ["files"]),
    SettingsEntry(title: "Recipes and shortcuts", page: "Relay", key: RelaySettingsKey.recipes, folded: true, words: ["prompts", "saved"]),
  ]
  private static let aiApps: [SettingsEntry] = [
    SettingsEntry(title: "Serein thinks with", page: "Agents", key: AIAppsKey.defaultApp, words: ["default", "AI app", "model"]),
    SettingsEntry(title: "Your AI apps", page: "Agents", words: ["Claude Code", "Codex", "sign in", "connect", "install"]),
    SettingsEntry(title: "New chats", page: "Agents", key: AIAppsKey.newChats, folded: true, words: ["starts with", "effort", "asks before", "model"]),
    SettingsEntry(title: "Model providers", page: "Agents", folded: true, words: ["API key", "provider"]),
    SettingsEntry(title: "Background helpers", page: "Agents", key: AIAppsKey.helpers, folded: true),
    SettingsEntry(title: "Other agents that use Serein", page: "Agents", key: AIAppsKey.outside, folded: true, words: ["MCP", "outside"]),
    SettingsEntry(title: "Delete threads", page: "Agents", folded: true, words: ["chats"]),
    SettingsEntry(title: "Use fast steps", page: "Agents", folded: true, words: ["beta"]),
    SettingsEntry(title: "Projects always allowed to edit", page: "Agents", folded: true, words: ["approve", "files"]),
    SettingsEntry(title: "Agent history", page: "Agents", folded: true),
  ]
  private static let computer: [SettingsEntry] = [
    SettingsEntry(title: "Let assistants use Serein's computer", page: "Computer", words: ["sandbox", "virtual machine", "VM", "desktop"]),
    SettingsEntry(title: "Each assistant's computer", page: "Computer", words: ["reset", "delete", "move"]),
    SettingsEntry(title: "Where computers run", page: "Computer", folded: true, words: ["Docker", "cloud", "E2B", "Daytona", "SSH", "remote"]),
    SettingsEntry(title: "Memory and processors", page: "Computer", folded: true, words: ["RAM", "CPU", "limits", "image"]),
  ]
  private static let privacy: [SettingsEntry] = [
    SettingsEntry(title: "The page you're viewing", page: "Privacy", words: ["sees", "context", "tab"]),
    SettingsEntry(title: "Mac permissions", page: "Privacy", key: PrivacyKey.mac, words: ["accessibility", "screen recording", "full disk access", "background"]),
    SettingsEntry(title: "Allowed without asking", page: "Privacy", key: PrivacyKey.allowed, words: ["approvals", "always allow", "asks before"]),
    SettingsEntry(title: "Sites Serein treats differently", page: "Privacy", key: PrivacyKey.sites, words: ["never", "block", "ask first"]),
    SettingsEntry(title: "History", page: "Privacy", key: PrivacyKey.history, words: ["save history", "keep", "delete"]),
    SettingsEntry(title: "Task recordings", page: "Privacy", words: ["screen", "video"]),
    SettingsEntry(title: "Clear saved data…", page: "Privacy", words: ["delete", "cookies", "cache", "erase"]),
    SettingsEntry(title: "Cookie and consent banners", page: "Privacy", folded: true),
    SettingsEntry(title: "Routine steps go ahead on", page: "Privacy", key: PrivacyKey.routineSites, folded: true, words: ["sites"]),
    SettingsEntry(title: "Sites Serein stays signed in to", page: "Privacy", key: PrivacyKey.signIns, folded: true, words: ["sign-ins", "cookies"]),
    SettingsEntry(title: "Tools that sites offer", page: "Privacy", key: PrivacyKey.pageTools, folded: true, words: ["page tools"]),
    SettingsEntry(title: "Chats on this Mac", page: "Privacy", key: PrivacyKey.chats, folded: true, words: ["Claude Code", "Codex"]),
    SettingsEntry(title: "Site permissions", page: "Privacy", key: PrivacyKey.permissions, folded: true, words: ["camera", "microphone", "location", "notifications"]),
    SettingsEntry(title: "Ads and trackers", page: "Privacy", key: PrivacyKey.blocking, folded: true, words: ["block", "tracking"]),
  ]
  private static let vault: [SettingsEntry] = [
    SettingsEntry(title: "Saved sign-ins and keys", page: "Passwords", words: ["password", "credentials", "secrets", "keychain", "token", "API key", "new item"]),
    SettingsEntry(title: "Offer to save passwords when you sign in", page: "Passwords", folded: true),
    SettingsEntry(title: "Password managers", page: "Passwords", folded: true, words: ["1Password", "Bitwarden"]),
    SettingsEntry(title: "Import or export sign-ins as CSV", page: "Passwords", folded: true),
    SettingsEntry(title: "Import a chat from Claude Code or Codex", page: "Passwords", folded: true, words: ["session"]),
    SettingsEntry(title: "Bring from your browser", page: "Passwords", key: PasswordsKey.bring, folded: true, words: ["import", "bookmarks", "history", "cookies", "Chrome", "Safari"]),
  ]
  /// What left Settings: a search still finds it, and opens the Marketplace place that has it.
  private static let marketplace: [SettingsEntry] = [
    SettingsEntry(title: "Your connected apps", page: "", place: .yours, words: ["connections", "MCP", "Composio", "remove", "manage"]),
    SettingsEntry(title: "Plugins", page: "", place: .plugins, words: ["skills", "extensions"]),
    SettingsEntry(title: "Mail, Calendar and other apps on this Mac", page: "", place: .mac, words: ["messages", "reminders", "contacts", "notes", "commands"]),
  ]

  /// The settings a search keeps, in index order: each word typed starts a word of the setting's
  /// name, its extra words or its page's label. An empty search keeps none.
  static func search(_ query: String) -> [SettingsEntry] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    return all.filter { entry in
      SettingsCategory.matches(query, in: [entry.title, label(entry)] + entry.words)
    }
  }
  /// The pages a search keeps in Settings' list: those `SettingsCategory.search` finds by name, and
  /// every page that holds a setting the search finds.
  static func pages(_ query: String) -> [SettingsCategory] {
    let named: Set<String> = Set(SettingsCategory.search(query).map(\.id))
    let holding: Set<String> = Set(search(query).filter { $0.place == nil }.map(\.page))
    return SettingsCategory.all.filter { named.contains($0.id) || holding.contains($0.id) }
  }
  /// The page as the list names it: "Vault" for `Passwords`, "Marketplace" for what left Settings.
  static func label(_ entry: SettingsEntry) -> String {
    entry.place == nil ? SettingsCategory.resolve(entry.page).label : "Marketplace"
  }
  /// Where the setting is, as the result row says it: "Privacy › Advanced", "Marketplace › Plugins".
  static func place(_ entry: SettingsEntry) -> String {
    if let place = entry.place { return "Marketplace › \(place.label)" }
    let page: String = label(entry)
    guard entry.folded else { return page }
    return "\(page) › \(entry.page == "Passwords" ? "Options" : "Advanced")"
  }
  static func icon(_ entry: SettingsEntry) -> String {
    entry.place == nil ? SettingsCategory.resolve(entry.page).icon : "square.grid.2x2"
  }
}

/// Settings' column while something is typed in the search field: one row for each setting that
/// matches, with where it is. A click opens its page there (`show`).
struct SettingsSearchResults: View {
  let query: String
  let show: (SettingsEntry) -> Void
  var body: some View {
    let found: [SettingsEntry] = SettingsIndex.search(query)
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Search", sentence: found.isEmpty ? "" : (found.count == 1 ? "1 setting matches." : "\(found.count) settings match."))
      SettingsRowList {
        if found.isEmpty {
          SettingsEmptyRow(glyph: "magnifyingglass", text: "No setting matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”. Try another word.")
        }
        ForEach(Array(found.enumerated()), id: \.element.id) { index, entry in
          SettingsResultRow(entry: entry, divider: index > 0) { show(entry) }
        }
      }
    }
  }
}

/// One search result: the setting's name over where it is, and a chevron. A click anywhere on the
/// row shows it. The first row draws no hairline above it.
private struct SettingsResultRow: View {
  let entry: SettingsEntry
  let divider: Bool
  let open: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    let place: String = SettingsIndex.place(entry)
    Button(action: open) {
      SettingsListRow(name: entry.title, status: place, divider: divider, expandable: false) {
        SettingsGlyphTile(systemName: SettingsIndex.icon(entry))
      } trailing: {
        InterfaceIcon(systemName: "chevron.right", size: 12).foregroundStyle(p.secondary).opacity(0.6)
      } live: {
        EmptyView()
      } details: {
        EmptyView()
      }
      .background(hovered ? p.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .onHover { hovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(entry.title), \(place)")
    .accessibilityHint("Shows this setting")
    .accessibilityAddTraits(.isButton)
  }
}
