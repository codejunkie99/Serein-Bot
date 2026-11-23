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

  /// The captions of Settings' list, in order: the pages of each follow it (`group`).
  public static let assistantsGroup = "Assistants and apps"
  public static let dataGroup = "Your data"

  /// The pages in list order, each group's together. Renamed pages retain their ids; merged pages
  /// remain aliases.
  public static let all: [SettingsCategory] = [
    SettingsCategory("General", icon: "gearshape", summary: "Choose how Serein starts, where files go and how it updates."),
    // The old Tabs page's id stays an alias.
    SettingsCategory("Appearance", icon: "paintpalette", aliases: ["Wallpaper", "Tabs"],
                     summary: "Choose how Serein looks."),
    SettingsCategory("Talking", label: "Voice", icon: "mic", aliases: ["Talking"], summary: "Talk to Serein, and choose how it talks back."),
    SettingsCategory("Keyboard", icon: "keyboard", summary: "The keys for each menu command."),
    SettingsCategory("Relay", label: "Assistants", icon: "person.2", aliases: ["Serein"],
                     summary: "Your assistants, and what every assistant does.", group: assistantsGroup),
    // The outside agents' MCP setup is a group on AI apps (`/mcp`).
    SettingsCategory("Agents", label: "AI apps", icon: "terminal", aliases: ["AI apps", "MCP connection"],
                     summary: "The AI apps on this Mac that Serein uses, and what new chats start with.", group: assistantsGroup),
    // Mail, Messages, Calendar, Reminders, Contacts and Notes (Connections, NativeConnection), and
    // apps connected through Composio (ComposioApps) or by their MCP server's address (MCPConnectionsRows).
    SettingsCategory("Connections", icon: "envelope", aliases: ["Mail", "Messages", "Calendar", "Reminders", "Contacts", "Notes", "Connected apps", "Composio", "MCP"],
                     summary: "The apps Serein can use for you.", group: assistantsGroup),
    SettingsCategory("Computer", label: "Serein's computer", icon: "desktopcomputer",
                     summary: "A desktop of its own where an assistant works, apart from your Mac.", group: assistantsGroup),
    SettingsCategory("Plugins", icon: "puzzlepiece.extension", summary: "Add tools to Serein from a folder, a link or the community list.",
                     group: assistantsGroup),
    SettingsCategory("Privacy", icon: "hand.raised", aliases: ["History"], summary: "Choose what Serein sees and what it keeps.",
                     group: dataGroup),
    SettingsCategory("Passwords", icon: "key", aliases: ["Import"],
                     summary: "Your saved passwords, and ones to bring in.", group: dataGroup),
    SettingsCategory("Usage", icon: "chart.bar", summary: "What you do in Serein, counted on this Mac only.", group: dataGroup),
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
  /// "dark" finds Appearance. Search only (`search`); a page never opens by one of these (`resolve`).
  public static let synonyms: [String: [String]] = [
    "General": ["startup", "launch", "update", "sleep", "downloads", "search engine"],
    "Appearance": ["dark", "light", "mode", "theme", "colour", "color", "text size", "font", "bigger"],
    "Relay": ["team", "routines", "memory", "persona"],
    "Agents": ["model", "Claude", "Codex", "LLM", "provider"],
    "Connections": ["email", "iMessage", "integrations"],
    "Computer": ["sandbox", "virtual machine", "VM"],
    "Privacy": ["tracking", "cookies", "ads", "sign-ins", "permissions"],
    "Passwords": ["password", "keychain", "login"],
    "Talking": ["mic", "microphone", "speech", "dictation", "wake word", "read aloud"],
    "Plugins": ["extensions", "skills", "add-ons"],
    "Keyboard": ["shortcuts", "hotkeys", "keys"],
    "Usage": ["stats", "statistics", "counts"],
  ]

  /// The pages a Settings search keeps, in list order: each word typed starts a word of the
  /// page's id, label, summary, an alias or a synonym (any case, accents ignored), so "ai" finds AI
  /// apps and not Mail. An empty search keeps every page.
  public static func search(_ query: String, in categories: [SettingsCategory] = all) -> [SettingsCategory] {
    let wanted: [String] = searchWords(query)
    guard !wanted.isEmpty else { return categories }
    return categories.filter { category in
      let text: [String] = [category.id, category.label, category.summary] + category.aliases + (synonyms[category.id] ?? [])
      let words: [String] = searchWords(text.joined(separator: " "))
      return wanted.allSatisfy { word in words.contains { $0.hasPrefix(word) } }
    }
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
