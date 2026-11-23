import Foundation

/// Composer commands are parsed before routing, queueing, attachments, or model invocation.
/// A terminal command is a handoff, never a prompt disguised as a successful action.
public struct SlashCommand: Equatable, Identifiable, Sendable {
  public enum Action: String, Sendable {
    case newChat, model, harness, plan, stop, settings, mcp, help, status, agents, usage
    case terminal, native
    /// One of the person's saved prompts (PromptShortcuts): it fills the draft, nothing more.
    case shortcut
  }
  public var name: String
  public var summary: String
  public var action: Action
  public var driver: HarnessDriver?
  public var nativeName: String?
  public var id: String { name }
  public init(_ name: String, _ summary: String, _ action: Action, driver: HarnessDriver? = nil,
              nativeName: String? = nil) {
    self.name = name; self.summary = summary; self.action = action; self.driver = driver
    self.nativeName = nativeName
  }
}

public enum SlashCommands {
  public struct Invocation: Equatable, Sendable {
    public var name: String
    public var arguments: String
  }
  /// Paths, URLs, multiline prose, and escaped //text remain ordinary text.
  public static func parse(_ text: String) -> Invocation? {
    guard text.hasPrefix("/"), !text.hasPrefix("//"), !text.contains("\n"), !text.contains("\r") else { return nil }
    let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    guard let first = parts.first, validName(String(first)) else { return nil }
    return Invocation(name: String(first).lowercased(), arguments: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
  }
  public static func validName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 80 && name.utf8.allSatisfy {
      (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || [45, 95, 58, 46].contains($0)
    }
  }
  public static func query(_ text: String) -> String? {
    guard text.hasPrefix("/"), !text.hasPrefix("//"), !text.contains(where: { $0.isWhitespace }),
      text == "/" || validName(String(text.dropFirst())) else { return nil }
    return String(text.dropFirst()).lowercased()
  }
  public static let shared: [SlashCommand] = [
    .init("new", "Start a new chat; keep this chat in history", .newChat),
    .init("model", "Choose a model and reasoning level", .model),
    .init("harness", "Switch the agent used for this chat", .harness),
    .init("plan", "Turn Serein’s plan-first mode on or off", .plan),
    .init("stop", "Stop this chat’s active task", .stop),
    .init("settings", "Open Serein settings", .settings),
    .init("mcp", "Pair an outside agent and copy its MCP configuration", .mcp),
    .init("agents", "Install, sign in, or update an agent", .agents),
    .init("status", "Show this chat’s harness, model, and task state", .status),
    .init("usage", "Open Serein’s usage overview", .usage),
    .init("help", "Show command help and harness documentation", .help),
  ]
  public static func catalog(_ driver: HarnessDriver?) -> [SlashCommand] {
    guard let driver else { return shared }
    return shared + nativeCommands(driver).map { name, summary in
      let collision = shared.contains { $0.name == name }
      return SlashCommand(collision ? "\(driver.rawValue):\(name)" : name, summary, .terminal,
        driver: driver, nativeName: name)
    }
  }
  public static let aliases = ["clear": "new", "newchat": "new", "models": "model", "config": "settings"]
  public static func find(_ name: String, driver: HarnessDriver?) -> SlashCommand? {
    catalog(driver).first { $0.name == name } ?? shared.first { $0.name == aliases[name] }
  }
  public static func filter(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
    guard !query.isEmpty else { return commands }
    let prefixes = commands.filter { $0.name.hasPrefix(query) }
    if !prefixes.isEmpty { return prefixes.filter { $0.name == query } + prefixes.filter { $0.name != query } }
    return commands.filter {
      $0.name.contains(query) || (query.count >= 3 && $0.summary.localizedCaseInsensitiveContains(query))
    }
  }
  /// Curated from each harness's own documentation. Exact installed-version help remains
  /// in its terminal. ACP announcements add installed-session commands.
  public static func nativeCommands(_ d: HarnessDriver) -> [(String, String)] {
    switch d {
    case .claude: return [("compact", "Compact Claude’s session context"), ("context", "Inspect Claude’s context usage"), ("cost", "Inspect Claude’s session cost"), ("resume", "Choose a Claude session"), ("skills", "Browse Claude skills"), ("mcp", "Manage Claude’s MCP servers"), ("help", "Open Claude’s command help")]
    case .codex: return [("compact", "Compact Codex’s session context"), ("review", "Review changes with Codex"), ("diff", "Inspect the working tree diff"), ("resume", "Choose a Codex session"), ("fork", "Branch a Codex conversation"), ("permissions", "Configure Codex’s permissions"), ("mcp", "Inspect Codex’s MCP tools"), ("status", "Inspect Codex’s native session status")]
    case .cursor: return [("summarize", "Summarize Cursor’s session context"), ("compress", "Alias for Cursor’s summarize command"), ("resume", "Choose a Cursor session"), ("fork", "Fork a Cursor conversation"), ("about", "Inspect Cursor’s CLI version and account"), ("mcp", "Manage Cursor’s MCP servers"), ("help", "Open Cursor’s command help")]
    case .opencode: return [("compact", "Compact OpenCode’s session context"), ("sessions", "Browse OpenCode sessions"), ("undo", "Undo an OpenCode message"), ("redo", "Redo an OpenCode message"), ("init", "Create project instructions with OpenCode"), ("connect", "Connect an OpenCode provider"), ("help", "Open OpenCode’s command help")]
    case .pi: return [("compact", "Compact Pi’s session context"), ("tree", "Browse Pi’s session tree"), ("fork", "Fork a Pi conversation"), ("resume", "Choose a Pi session"), ("login", "Connect a Pi provider"), ("settings", "Configure Pi’s native settings")]
    case .ohMyPi: return [("compact", "Compact Oh My Pi’s session context"), ("tree", "Browse Oh My Pi’s session tree"), ("fork", "Fork an Oh My Pi conversation"), ("resume", "Choose an Oh My Pi session"), ("model", "Choose Oh My Pi’s model"), ("settings", "Configure Oh My Pi’s native settings")]
    case .grok: return [("compact", "Compact Grok’s session context"), ("context", "Inspect Grok’s context usage"), ("resume", "Choose a Grok session"), ("sessions", "Manage Grok sessions"), ("skills", "Browse Grok skills"), ("mcps", "Manage Grok’s MCP servers"), ("help", "Open Grok’s command help")]
    case .gemini: return [("compress", "Compress Gemini’s session context"), ("resume", "Choose a Gemini session"), ("about", "Inspect Gemini CLI’s version"), ("mcp", "Manage Gemini’s MCP servers"), ("init", "Create project instructions with Gemini"), ("settings", "Configure Gemini’s native settings"), ("help", "Open Gemini’s command help")]
    }
  }
  public static func docs(_ driver: HarnessDriver) -> String {
    switch driver {
    case .claude: return "https://code.claude.com/docs/en/interactive-mode"
    case .codex: return "https://developers.openai.com/codex/cli/slash-commands"
    case .cursor: return "https://cursor.com/docs/cli/reference/slash-commands"
    case .opencode: return "https://opencode.ai/docs/tui/"
    case .pi: return "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md"
    case .ohMyPi: return "https://github.com/can1357/oh-my-pi/blob/main/docs/slash-command-internals.md"
    case .grok: return "https://docs.x.ai/build/modes-and-commands"
    case .gemini: return "https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/commands.md"
    }
  }
  public static let nativeACPNames: Set<String> = ["compact", "compress", "summarize"]

  /// Untrusted advertisements only contribute bounded labels. They cannot select an action.
  public static func advertised(_ update: [String: Any], driver: HarnessDriver) -> [SlashCommand]? {
    guard update["sessionUpdate"] as? String == "available_commands_update" else { return nil }
    var seen = Set<String>()
    return ((update["availableCommands"] as? [[String: Any]]) ?? []).prefix(100).compactMap { row in
      guard let name = row["name"] as? String, validName(name), seen.insert(name).inserted else { return nil }
      let summary = String((row["description"] as? String ?? "Harness command").filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(160))
      return SlashCommand("\(driver.rawValue):\(name)", summary, nativeACPNames.contains(name) ? .native : .terminal, driver: driver, nativeName: name)
    }
  }
}
