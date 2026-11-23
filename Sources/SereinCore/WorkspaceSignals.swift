import Foundation

/// Which workspaces a person's past AI chats lean on, counted on this Mac with no model: tools of a
/// connected app (`mcp__notion__search`), command-line tools (`vercel deploy`) and links to an
/// app's site (notion.so). `sessions_overview` turns the counts into what is worth offering to
/// connect. Names and counts only: no chat text leaves this file.
public enum WorkspaceSignals {
  public struct Workspace: Sendable, Equatable {
    /// The name `connect_app` takes (ConnectCatalog), as the person would say it.
    public let name: String
    /// Words found in an MCP server's name (`mcp__<server>__tool`, a configured server).
    public let servers: [String]
    /// Command-line tools, as the first word of a shell command.
    public let commands: [String]
    /// Hosts, matched as the end of a link's host.
    public let hosts: [String]
  }

  public static let known: [Workspace] = [
    Workspace(name: "Notion", servers: ["notion"], commands: ["ntn"], hosts: ["notion.so", "notion.site"]),
    Workspace(name: "Gmail", servers: ["gmail"], commands: [], hosts: ["mail.google.com"]),
    Workspace(name: "Google Calendar", servers: ["calendar", "gcal"], commands: ["gcalcli"], hosts: ["calendar.google.com"]),
    Workspace(name: "Google Drive", servers: ["drive", "gdrive"], commands: [], hosts: ["drive.google.com"]),
    Workspace(name: "Google Docs", servers: ["gdocs", "googledocs"], commands: [], hosts: ["docs.google.com"]),
    Workspace(name: "GitHub", servers: ["github"], commands: ["gh"], hosts: ["github.com"]),
    Workspace(name: "Linear", servers: ["linear"], commands: [], hosts: ["linear.app"]),
    Workspace(name: "Slack", servers: ["slack"], commands: [], hosts: ["slack.com"]),
    Workspace(name: "Vercel", servers: ["vercel"], commands: ["vercel"], hosts: ["vercel.com", "vercel.app"]),
    Workspace(name: "Jira", servers: ["jira", "atlassian"], commands: ["jira", "acli"], hosts: ["atlassian.net"]),
    Workspace(name: "Figma", servers: ["figma"], commands: [], hosts: ["figma.com"]),
    Workspace(name: "Supabase", servers: ["supabase"], commands: ["supabase"], hosts: ["supabase.co", "supabase.com"]),
    Workspace(name: "Stripe", servers: ["stripe"], commands: ["stripe"], hosts: ["stripe.com"]),
    Workspace(name: "Sentry", servers: ["sentry"], commands: ["sentry-cli"], hosts: ["sentry.io"]),
    Workspace(name: "Airtable", servers: ["airtable"], commands: [], hosts: ["airtable.com"]),
    Workspace(name: "Asana", servers: ["asana"], commands: [], hosts: ["asana.com"]),
    Workspace(name: "Todoist", servers: ["todoist"], commands: [], hosts: ["todoist.com"]),
    Workspace(name: "Trello", servers: ["trello"], commands: [], hosts: ["trello.com"]),
    Workspace(name: "HubSpot", servers: ["hubspot"], commands: [], hosts: ["hubspot.com"]),
    Workspace(name: "Outlook", servers: ["outlook", "microsoft365"], commands: [], hosts: ["outlook.office.com", "outlook.live.com"]),
    Workspace(name: "Dropbox", servers: ["dropbox"], commands: [], hosts: ["dropbox.com"]),
    Workspace(name: "Zoom", servers: ["zoom"], commands: [], hosts: ["zoom.us"]),
  ]

  /// How much of one chat file is read: its start and its end, so a long chat costs no more.
  public static let readLimit = 384 * 1024

  /// Hits per workspace name in one chat's raw text. Each kind counts once per distinct use, so a
  /// chat that pastes one link a hundred times does not outweigh a chat that works in the app.
  public static func count(_ text: String) -> [String: Int] {
    var hits: [String: Int] = [:]
    let servers = matches(#"mcp__([A-Za-z0-9_-]+?)__"#, in: text)
    let commands = shellCommands(in: text)
    let hosts = matches(#"https?://([A-Za-z0-9.-]+)"#, in: text).map { $0.lowercased() }
    for workspace in known {
      var n = 0
      n += servers.filter { name in workspace.servers.contains { name.lowercased().contains($0) } }.count
      n += commands.filter { workspace.commands.contains($0) }.count
      n += Set(hosts.filter { host in workspace.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }).count
      if n > 0 { hits[workspace.name] = n }
    }
    return hits
  }

  /// The chat file's text, start and end only (`readLimit`).
  public static func sample(_ data: Data) -> String {
    guard data.count > readLimit else { return String(decoding: data, as: UTF8.self) }
    let half = readLimit / 2
    return String(decoding: data.prefix(half), as: UTF8.self) + "\n" + String(decoding: data.suffix(half), as: UTF8.self)
  }

  /// MCP servers named in an AI app's own settings: `mcpServers` keys anywhere in a JSON file
  /// (Claude Code's ~/.claude.json, its projects, Cursor, Gemini) and `[mcp_servers.<name>]` tables
  /// in Codex's config.toml. Names only; their commands, keys and headers are never read out.
  public static func configuredServers(json data: Data) -> [String] {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var names: [String] = []
    func walk(_ value: Any, depth: Int) {
      guard depth < 6 else { return }
      if let object = value as? [String: Any] {
        if let servers = object["mcpServers"] as? [String: Any] { names += servers.keys }
        for child in object.values { walk(child, depth: depth + 1) }
      }
    }
    walk(root, depth: 0)
    return Array(Set(names)).sorted()
  }
  public static func configuredServers(toml text: String) -> [String] {
    Array(Set(matches(#"(?m)^\s*\[mcp_servers\.\"?([A-Za-z0-9_-]+)\"?\]"#, in: text))).sorted()
  }

  /// Workspace names for configured server names.
  public static func workspaces(forServers names: [String]) -> [String] {
    known.filter { workspace in names.contains { name in workspace.servers.contains { name.lowercased().contains($0) } } }
      .map(\.name)
  }

  /// What is worth offering: used in at least two chats, or set up in an AI app already, and not
  /// connected to Serein. Most chats first; at most `limit`.
  public struct Suggestion: Sendable, Equatable {
    public let name: String
    public let chats: Int
    public let configured: Bool
  }
  public static func suggestions(chats: [String: Int], configured: Set<String>, connected: Set<String>, limit: Int = 4)
    -> [Suggestion]
  {
    let names = Set(chats.keys).union(configured).subtracting(connected)
    return names.map { Suggestion(name: $0, chats: chats[$0] ?? 0, configured: configured.contains($0)) }
      .filter { $0.chats >= 2 || $0.configured }
      .sorted { ($0.chats, $0.configured ? 1 : 0, $1.name) > ($1.chats, $1.configured ? 1 : 0, $0.name) }
      .prefix(limit).map { $0 }
  }

  // MARK: Reading

  private static func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
  }

  /// The first word of each shell command in a chat: Claude Code's Bash `command` and Codex's
  /// `cmd` (plain, or inside a tool call's escaped JSON), split at `&&`, `;` and `|`, past `cd`
  /// and environment settings.
  static func shellCommands(in text: String) -> [String] {
    let raw = matches(#"\\?"(?:command|cmd)\\?"\s*:\s*\\?"((?:[^"\\]|\\[^"]){1,400})"#, in: text)
    var words: [String] = []
    for command in raw {
      let unescaped = command.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
      for part in unescaped.components(separatedBy: CharacterSet(charactersIn: "&;|\n")) {
        let tokens = part.split(separator: " ").map(String.init).filter { !$0.contains("=") }
        guard let first = tokens.first, first != "cd" else { continue }
        let word = first == "npx" || first == "bunx" ? (tokens.dropFirst().first ?? first) : first
        words.append(URL(fileURLWithPath: word).lastPathComponent)
      }
    }
    return words
  }
}
