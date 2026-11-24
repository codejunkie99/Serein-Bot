import Foundation

/// One Settings page. `id` is what is stored and passed around (`serein.settingsSection`,
/// `openSettings`, `--ui-settings-section`), so it never changes; `label` is what the user reads
/// in the list and the page heading; `aliases` are other names that open the same page;
/// `summary` is the one sentence under the heading that says what to do there.
public struct SettingsCategory: Equatable, Sendable, Identifiable {
  public let id: String
  public let label: String
  /// An `InterfaceIcon` name.
  public let icon: String
  public let aliases: [String]
  public let summary: String
  /// The caption the page sits under in Settings' list; the first group has none.
  public let group: String
  public init(
    _ id: String, label: String? = nil, icon: String, aliases: [String] = [], summary: String = "", group: String = ""
  ) {
    self.id = id
    self.label = label ?? id
    self.icon = icon
    self.aliases = aliases
    self.summary = summary
    self.group = group
  }

  public static let general = "General"
  /// Between a page and its sub-page in a request: "Relay/<assistant id>" opens that assistant's
  /// page under Relay. Ids, labels and aliases never hold it.
  public static let separator: Character = "/"

  /// The pages in list order: eight, in one flat list with no captions
  /// (docs/demos/simple-settings.decision.md). Renamed pages keep their ids (Vault is `Passwords`,
  /// Voice is `Talking`, Assistants is `Relay`, AI apps is `Agents`); a page folded into another
  /// stays an alias of it (Appearance and Keyboard open General), and ReferenceSettings opens
  /// the part that holds what it had. Apps, connections and plugins are in the Marketplace (`moved`).
  public static let all: [SettingsCategory] = [
    SettingsCategory("General", icon: "gearshape", aliases: ["Appearance", "Wallpaper", "Tabs", "Keyboard"],
                     summary: "How Serein looks, starts and updates."),
    SettingsCategory("Talking", label: "Voice", icon: "mic", aliases: ["Talking"], summary: "Talk to Serein, and choose how it talks back."),
    SettingsCategory("Relay", label: "Assistants", icon: "person.2", aliases: ["Serein"],
                     summary: "Your assistants, and how you reach them."),
    // The outside agents' MCP setup is a group on AI apps (`/mcp`).
    SettingsCategory("Agents", label: "AI apps", icon: "terminal", aliases: ["AI apps", "MCP connection"],
                     summary: "The AI apps Serein thinks with."),
    SettingsCategory("Computer", label: "Serein's computer", icon: "desktopcomputer",
                     summary: "A desktop of its own where an assistant works, apart from your Mac."),
    SettingsCategory("Privacy", icon: "hand.raised", aliases: ["History"], summary: "What Serein sees, what it may do, and what it keeps."),
    SettingsCategory("Passwords", label: "Vault", icon: "key", aliases: ["Passwords", "Import"],
                     summary: "Sign-ins and keys Serein keeps for you, in your Mac's Keychain. The AI never sees them."),
    SettingsCategory("Usage", icon: "chart.bar", summary: "What you do in Serein, counted on this Mac only."),
  ]

  /// `pages` split by `group`, in order of first appearance: what Settings' list draws under
  /// each caption. A search keeps the captions of the groups it still has pages in.
  public static func grouped(_ pages: [SettingsCategory]) -> [(group: String, pages: [SettingsCategory])] {
    var result: [(group: String, pages: [SettingsCategory])] = []
    for page in pages {
      if let index = result.firstIndex(where: { $0.group == page.group }) {
        result[index] = (result[index].group, result[index].pages + [page])
      } else {
        result.append((page.group, [page]))
      }
    }
    return result
  }

  /// Apps, connections and plugins are managed in the Marketplace, not in Settings (their two pages
  /// left). The Marketplace place a name that used to open one of them opens now: the old ids, labels
  /// and aliases, in any case, with or without a sub-page. nil for every name Settings still has.
  public static func moved(_ name: String) -> MarketplacePlace? {
    let page: Substring = name.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    switch page.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "plugins": return .plugins
    case "connections", "connected apps", "composio", "mcp": return .yours
    case "mail", "messages", "calendar", "reminders", "contacts", "notes", "on this mac": return .mac
    default: return nil
    }
  }

  /// The page a stored or requested name opens: an id, a label or an alias (any case). A sub-page
  /// after `separator` is ignored here (`subpath` reads it). Anything else opens General.
  public static func resolve(_ name: String, in categories: [SettingsCategory] = all) -> SettingsCategory {
    let page: Substring = name.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let wanted = page.trimmingCharacters(in: .whitespacesAndNewlines)
    func same(_ other: String) -> Bool { other.caseInsensitiveCompare(wanted) == .orderedSame }
    return categories.first { $0.id == wanted }
      ?? categories.first { same($0.id) || same($0.label) || $0.aliases.contains(where: same) }
      ?? categories.first { $0.id == general }
      ?? categories[0]
  }

  /// Everyday words for a page that are not its name, keyed by page id: "mic" finds Voice and
  /// "dark" finds General, where Appearance is. Search only (`search`); a page never opens by one of these (`resolve`).
  public static let synonyms: [String: [String]] = [
    "General": ["startup", "launch", "update", "sleep", "downloads", "search engine",
                "dark", "light", "mode", "theme", "colour", "color", "text size", "font", "bigger",
                "shortcuts", "hotkeys", "keys"],
    "Relay": ["team", "routines", "memory", "persona"],
    "Agents": ["model", "Claude", "Codex", "LLM", "provider"],
    "Computer": ["sandbox", "virtual machine", "VM"],
    "Privacy": ["tracking", "cookies", "ads", "sign-ins", "permissions"],
    "Passwords": ["password", "keychain", "login", "credentials", "secrets", "token", "API key"],
    "Talking": ["mic", "microphone", "speech", "dictation", "wake word", "read aloud"],
    "Usage": ["stats", "statistics", "counts"],
  ]

  /// The pages a Settings search keeps, in list order: each word typed starts a word of the
  /// page's id, label, summary, an alias or a synonym (any case, accents ignored), so "ai" finds AI
  /// apps and not Mail. An empty search keeps every page.
  public static func search(_ query: String, in categories: [SettingsCategory] = all) -> [SettingsCategory] {
    guard !searchWords(query).isEmpty else { return categories }
    return categories.filter { category in
      matches(query, in: [category.id, category.label, category.summary] + category.aliases + (synonyms[category.id] ?? []))
    }
  }
  /// Whether each word typed starts a word of `text` (any case, accents ignored): how a search
  /// matches a page, and one setting on it (`SettingsIndex`). An empty search matches nothing.
  public static func matches(_ query: String, in text: [String]) -> Bool {
    let wanted: [String] = searchWords(query)
    guard !wanted.isEmpty else { return false }
    let words: [String] = searchWords(text.joined(separator: " "))
    return wanted.allSatisfy { word in words.contains { $0.hasPrefix(word) } }
  }
  private static func searchWords(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
      .split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  /// The sub-page a request names after the page: "Relay/abc/routines" gives ["abc", "routines"];
  /// a plain page name gives []. Empty parts are dropped.
  public static func subpath(_ name: String) -> [String] {
    let parts: [Substring] = name.split(separator: separator, omittingEmptySubsequences: true)
    guard name.contains(separator), parts.count > 1 else { return [] }
    return parts.dropFirst().map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  /// The request that opens `path` under page `id`: "Relay/abc".
  public static func request(_ id: String, path: [String]) -> String {
    ([id] + path).joined(separator: String(separator))
  }
}
