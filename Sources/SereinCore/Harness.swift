import Foundation

// MARK: - Drivers

/// A harness implementation Serein knows how to detect and drive. An instance (below) is one
/// configured copy of a driver; Serein keeps one instance per driver, whose id is the driver's
/// raw value except for Claude Code and Codex, which keep their historic ids.
public enum HarnessDriver: String, Codable, CaseIterable, Sendable {
  case claude
  case codex
  case cursor
  case opencode
  case pi
  case ohMyPi = "omp"
  case grok
  case gemini

  public var displayName: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    case .cursor: return "Cursor Agent"
    case .opencode: return "OpenCode"
    case .pi: return "Pi"
    case .ohMyPi: return "Oh My Pi"
    case .grok: return "Grok"
    case .gemini: return "Gemini CLI"
    }
  }
  /// The id stored in threads and run records. Claude Code and Codex keep their old values.
  public var instanceID: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    default: return rawValue
    }
  }
  public init?(instanceID: String) {
    if let match = HarnessDriver.allCases.first(where: { $0.instanceID == instanceID }) {
      self = match
    } else {
      return nil
    }
  }
  /// Executable names looked up on the login-shell PATH, in order.
  public var binaries: [String] {
    switch self {
    case .claude: return ["claude"]
    case .codex: return ["codex"]
    case .cursor: return ["cursor-agent", "agent"]
    case .opencode: return ["opencode"]
    case .pi: return ["pi"]
    case .ohMyPi: return ["omp"]
    case .grok: return ["grok"]
    case .gemini: return ["gemini"]
    }
  }
  public enum Wire: String, Codable, Sendable {
    case claudeStream, codexAppServer, acp, piJSON
  }
  public var wire: Wire {
    switch self {
    case .claude: return .claudeStream
    case .codex: return .codexAppServer
    case .cursor, .opencode, .grok, .gemini: return .acp
    case .pi, .ohMyPi: return .piJSON
    }
  }
  /// How Serein talks to it, for Settings and the report.
  public var protocolLabel: String {
    switch wire {
    case .claudeStream: return "Serein reads its replies as they stream."
    case .codexAppServer: return "Serein keeps Codex running and talks to it, or sends one request at a time."
    case .acp: return "Serein talks to it through the Agent Client Protocol."
    case .piJSON: return "Serein reads its replies line by line."
    }
  }
  /// Every harness found on the Mac is on unless the user turned it off. Being on grants
  /// nothing: each run is still limited by HarnessPolicy and the run's own grants.
  public var enabledByDefault: Bool { true }
  /// Where the harness keeps its own session history, for import (read-only; Serein never
  /// writes there). nil when it keeps none Serein knows of.
  public var sessionStore: HarnessSessionStore? {
    switch self {
    case .claude:
      return HarnessSessionStore(root: "~/.claude/projects", pattern: "*/*.jsonl", format: .jsonl, note: "One JSON-lines transcript per session, grouped by project folder.", verifiedLocally: true)
    case .codex:
      return HarnessSessionStore(root: "~/.codex/sessions", pattern: "YYYY/MM/DD/rollout-*.jsonl", format: .jsonl, note: "One JSON-lines rollout per session, by date.", verifiedLocally: true)
    case .cursor:
      return HarnessSessionStore(root: "~/.cursor/chats", pattern: "<workspace-hash>/<chat-id>/", format: .directory, note: "One folder per chat (meta.json, plus a SQLite store.db once the chat has messages).", verifiedLocally: true)
    case .opencode:
      return HarnessSessionStore(root: "~/.local/share/opencode", pattern: "opencode.db", format: .sqlite, note: "SQLite database; sessions in the session, message and part tables.", verifiedLocally: true)
    case .pi:
      return HarnessSessionStore(root: "~/.pi/agent/sessions", pattern: "--<path>--/<timestamp>_<uuid>.jsonl", format: .jsonl, note: "JSON-lines session tree per file, one folder per working directory.", verifiedLocally: true)
    case .ohMyPi:
      return HarnessSessionStore(root: "~/.omp/agent/sessions", pattern: "--<path>--/*.jsonl", format: .jsonl, note: "Pi's session format (assumed from the fork; not installed here).", verifiedLocally: false)
    case .grok:
      return HarnessSessionStore(root: "~/.grok/sessions", pattern: "session_search.sqlite", format: .sqlite, note: "SQLite search index of sessions; transcripts are stored beside it.", verifiedLocally: true)
    // It keeps checkpoints and logs under ~/.gemini/tmp/<project-hash>/, in a format Serein's
    // import does not read; Serein reads none of its sessions.
    case .gemini:
      return nil
    }
  }
  /// Where the harness keeps its skills, slash commands and MCP-server config, in the user's setup
  /// and in a project, so Serein can list what it has installed (names and short descriptions
  /// only; see `HarnessCatalog`), for this Mac's home and Serein's environment.
  public var capabilitySources: CapabilitySources {
    capabilitySources(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
  }
  /// The same, after the variables each CLI reads to move its home (as SessionHistory.Roots
  /// resolves them). A harness with no such concept leaves the matching field empty. `verified`
  /// says whether the layout was checked against a running copy of the harness.
  public func capabilitySources(home: String, environment: [String: String]) -> CapabilitySources {
    func env(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
    let deep = HarnessCatalog.deep
    switch self {
    case .claude:
      // User and project skills, commands (in subfolders too) and `.mcp.json`; "local"-scope
      // servers and approvals per project in .claude.json (inside CLAUDE_CONFIG_DIR when it is
      // set); enabled plugins.
      let dir = env("CLAUDE_CONFIG_DIR") ?? home + "/.claude"
      let index = (env("CLAUDE_CONFIG_DIR") ?? home) + "/.claude.json"
      return CapabilitySources(
        skills: [SkillRoot(dir + "/skills")], commands: [CommandRoot(dir + "/commands", depth: deep)],
        mcp: [MCPFile(index, .jsonServers)], projectSkills: [SkillRoot(".claude/skills")],
        projectCommands: [CommandRoot(".claude/commands", depth: deep)], projectMCP: [MCPFile(".mcp.json", .jsonServers)],
        claudeHome: dir, claudeIndex: index)
    case .codex:
      // Skills in its home (its bundled ones in skills/.system) and the shared ~/.agents/skills,
      // below category folders; installed plugins; a project's `.agents/skills` and
      // `.codex/config.toml` layer (CodexChecks.projectConfigPresent). Prompts are user-only.
      let dir = env("CODEX_HOME") ?? home + "/.codex"
      return CapabilitySources(
        skills: [dir + "/skills", dir + "/skills/.system", home + "/.agents/skills"].map { SkillRoot($0, depth: 3) },
        commands: [CommandRoot(dir + "/prompts")], mcp: [MCPFile(dir + "/config.toml", .tomlTables)],
        projectSkills: [SkillRoot(".agents/skills", depth: 3)], projectMCP: [MCPFile(".codex/config.toml", .tomlTables)],
        codexHome: dir)
    case .cursor:
      let dir = env("CURSOR_CONFIG_DIR") ?? env("XDG_CONFIG_HOME").map { $0 + "/cursor" } ?? home + "/.cursor"
      return CapabilitySources(
        commands: [CommandRoot(dir + "/commands")], mcp: [MCPFile(dir + "/mcp.json", .jsonServers)],
        projectCommands: [CommandRoot(".cursor/commands")], projectMCP: [MCPFile(".cursor/mcp.json", .jsonServers)])
    case .opencode:
      // From OpenCode's documentation; none of these are set up on the development Mac.
      let dir = (env("XDG_CONFIG_HOME") ?? home + "/.config") + "/opencode"
      return CapabilitySources(
        skills: [SkillRoot(dir + "/skill")], commands: [CommandRoot(dir + "/command")],
        mcp: [MCPFile(dir + "/opencode.json", .opencodeJSON), MCPFile(dir + "/opencode.jsonc", .opencodeJSON)],
        projectSkills: [SkillRoot(".opencode/skill")], projectCommands: [CommandRoot(".opencode/command")],
        projectMCP: [MCPFile("opencode.json", .opencodeJSON), MCPFile("opencode.jsonc", .opencodeJSON)], verified: false)
    case .grok:
      return CapabilitySources(
        mcp: [MCPFile((env("GROK_HOME") ?? home + "/.grok") + "/config.toml", .tomlTables)], verified: false)
    case .gemini:
      // Its commands, extensions and MCP servers live under ~/.gemini, beside its sign-in: nothing
      // is listed for it. (Oh My Pi's opt-in listing reads only the server names in settings.json.)
      return CapabilitySources(verified: false)
    case .pi:
      // From Pi's documentation and source (earendil-works/pi); not installed on the development
      // Mac. Skills at any depth, skipped without a description; prompt templates are its slash
      // commands; MCP through its built-in extension. A project's `.pi/` (working folder only)
      // and `.agents/skills` (up to the repository root) load once the project is trusted.
      let dir = env("PI_CODING_AGENT_DIR") ?? home + "/.pi/agent"
      return CapabilitySources(
        skills: [dir + "/skills", home + "/.agents/skills"].map { SkillRoot($0, depth: deep, requireDescription: true) },
        commands: [CommandRoot(dir + "/prompts")], mcp: [MCPFile(dir + "/mcp.json", .jsonServers)],
        projectSkills: [
          SkillRoot(".pi/skills", depth: deep, walkUp: false, requireDescription: true),
          SkillRoot(".agents/skills", depth: deep, requireDescription: true),
        ],
        projectCommands: [CommandRoot(".pi/prompts", walkUp: false)], piAgentDir: dir, verified: false)
    case .ohMyPi:
      // From Oh My Pi's documentation (can1357/oh-my-pi docs/skills.md, mcp-config.md,
      // slash-command-internals.md, settings.md); not installed on the development Mac. Its own
      // `.omp` sources and `.agent(s)` folders load by default, as do other agents' project
      // folders; other agents' user folders only when `enabledProviders` names them.
      let root = env("PI_CONFIG_DIR") ?? home + "/.omp"
      let dir = (env("OMP_PROFILE") ?? env("PI_PROFILE")).map { root + "/profiles/\($0)/agent" }
        ?? env("PI_CODING_AGENT_DIR") ?? root + "/agent"
      let claude = env("CLAUDE_CONFIG_DIR") ?? home + "/.claude"
      let codex = env("CODEX_HOME") ?? home + "/.codex"
      let config = (env("XDG_CONFIG_HOME") ?? home + "/.config")
      func foreign(_ path: String, _ provider: String) -> SkillRoot { SkillRoot(path, provider: provider, optIn: true) }
      return CapabilitySources(
        skills: [
          SkillRoot(dir + "/skills", requireDescription: true), SkillRoot(home + "/.agent/skills", provider: "agents"),
          SkillRoot(home + "/.agents/skills", provider: "agents"), SkillRoot(dir + "/managed-skills"),
          foreign(claude + "/skills", "claude"), foreign(codex + "/skills", "codex"),
          foreign(config + "/opencode/skill", "opencode"), foreign(config + "/opencode/skills", "opencode"),
        ],
        commands: [
          CommandRoot(dir + "/commands"), CommandRoot(home + "/.agent/commands", provider: "agents"),
          CommandRoot(home + "/.agents/commands", provider: "agents"),
          CommandRoot(claude + "/commands", depth: deep, provider: "claude", optIn: true),
          CommandRoot(codex + "/commands", nameFromFrontMatter: true, provider: "codex", optIn: true),
          CommandRoot(config + "/opencode/commands", nameFromFrontMatter: true, provider: "opencode", optIn: true),
        ],
        mcp: [
          MCPFile(dir + "/mcp.json", .jsonServers), MCPFile(dir + "/.mcp.json", .jsonServers),
          MCPFile(home + "/.claude.json", .jsonServers, provider: "claude", optIn: true),
          MCPFile(claude + "/mcp.json", .jsonServers, provider: "claude", optIn: true),
          MCPFile(codex + "/config.toml", .tomlTables, provider: "codex", optIn: true),
          MCPFile(home + "/.gemini/settings.json", .jsonServers, provider: "gemini", optIn: true),
          MCPFile(config + "/opencode/opencode.json", .opencodeJSON, provider: "opencode", optIn: true),
          MCPFile(config + "/opencode/opencode.jsonc", .opencodeJSON, provider: "opencode", optIn: true),
          MCPFile(home + "/.cursor/mcp.json", .jsonServers, provider: "cursor", optIn: true),
          MCPFile(home + "/.codeium/windsurf/mcp_config.json", .jsonServers, provider: "windsurf", optIn: true),
        ],
        projectSkills: [
          SkillRoot(".omp/skills", walkUp: false, requireDescription: true),
          SkillRoot(".agent/skills", provider: "agents"), SkillRoot(".agents/skills", provider: "agents"),
          SkillRoot(".claude/skills", walkUp: false, provider: "claude"),
          SkillRoot(".codex/skills", walkUp: false, provider: "codex"),
          SkillRoot(".opencode/skill", walkUp: false, provider: "opencode"),
          SkillRoot(".opencode/skills", walkUp: false, provider: "opencode"),
          SkillRoot(".github/skills", walkUp: false, requireDescription: true, provider: "github"),
        ],
        projectCommands: [
          CommandRoot(".omp/commands", walkUp: false), CommandRoot(".agent/commands", provider: "agents"),
          CommandRoot(".agents/commands", provider: "agents"),
          CommandRoot(".claude/commands", depth: deep, walkUp: false, provider: "claude"),
          CommandRoot(".codex/commands", walkUp: false, nameFromFrontMatter: true, provider: "codex"),
          CommandRoot(".opencode/commands", walkUp: false, nameFromFrontMatter: true, provider: "opencode"),
        ],
        projectMCP: [
          MCPFile(".omp/mcp.json", .jsonServers, walkUp: false), MCPFile(".omp/.mcp.json", .jsonServers, walkUp: false),
          MCPFile("mcp.json", .jsonServers, walkUp: false), MCPFile(".mcp.json", .jsonServers, walkUp: false),
          MCPFile(".claude/.mcp.json", .jsonServers, walkUp: false, provider: "claude"),
          MCPFile(".claude/mcp.json", .jsonServers, walkUp: false, provider: "claude"),
          MCPFile(".codex/config.toml", .tomlTables, walkUp: false, provider: "codex"),
          MCPFile(".gemini/settings.json", .jsonServers, walkUp: false, provider: "gemini"),
          MCPFile("opencode.json", .opencodeJSON, walkUp: false, provider: "opencode"),
          MCPFile("opencode.jsonc", .opencodeJSON, walkUp: false, provider: "opencode"),
          MCPFile(".opencode/opencode.json", .opencodeJSON, walkUp: false, provider: "opencode"),
          MCPFile(".cursor/mcp.json", .jsonServers, walkUp: false, provider: "cursor"),
          MCPFile(".windsurf/mcp_config.json", .jsonServers, walkUp: false, provider: "windsurf"),
          MCPFile(".vscode/mcp.json", .vscodeServers, walkUp: false, provider: "vscode"),
        ],
        ompAgentDir: dir, ompRoot: root, frontMatterEnabled: true, verified: false)
    }
  }
  /// Detection and the version, sign-in and model probes were run against the real CLI on a
  /// development Mac (no model call). Pi and Oh My Pi follow their published documentation.
  public var verifiedLocally: Bool {
    switch self {
    case .claude, .codex, .cursor, .opencode, .grok: return true
    case .pi, .ohMyPi, .gemini: return false
    }
  }
  public var installHint: String {
    switch self {
    case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
    case .codex: return "npm install -g @openai/codex"
    case .cursor: return "curl https://cursor.com/install -fsS | bash"
    case .opencode: return "npm install -g opencode-ai"
    // Pi moved to earendil-works; the @mariozechner package stops at 0.73.1.
    case .pi: return "npm install -g @earendil-works/pi-coding-agent"
    case .ohMyPi: return "npm install -g @oh-my-pi/pi-coding-agent"
    case .grok: return "See xAI's Grok CLI instructions"
    case .gemini: return "npm install -g @google/gemini-cli"
    }
  }
  /// One line for places without the setup sheet (the picker's empty state).
  public var signInHint: String {
    "Sign in from Settings › AI apps."
  }
  /// The sign-in command shown before it runs (HarnessCommands has the argv).
  public var signInCommand: String? { HarnessCommands.signIn(self).display }
  /// What the picker, Settings and a refused send say when the CLI reports it is signed out, for a
  /// CLI that signs in only from its own interactive start; nil for the generic wording.
  public var signedOutReason: String? {
    self == .gemini ? "Sign in by running `gemini` once in Terminal." : nil
  }
  /// Official install and update instructions.
  public var docsURL: String {
    switch self {
    case .claude: return "https://docs.anthropic.com/en/docs/claude-code/setup"
    case .codex: return "https://github.com/openai/codex"
    case .cursor: return "https://cursor.com/docs/cli/overview"
    case .opencode: return "https://opencode.ai/docs/"
    case .pi: return "https://github.com/badlogic/pi-mono"
    case .ohMyPi: return "https://www.npmjs.com/package/@oh-my-pi/pi-coding-agent"
    case .grok: return "https://www.npmjs.com/package/@xai-official/grok"
    case .gemini: return "https://github.com/google-gemini/gemini-cli"
    }
  }
  /// The command that updates it: the CLI's own where it has one (it knows how it was installed:
  /// Homebrew, npm or its own installer), npm for the rest. Serein runs it only on the user's
  /// click, in its terminal.
  public var updateCommand: String {
    switch self {
    case .claude: return "claude update"
    case .codex: return "codex update"
    case .cursor: return "cursor-agent update"
    case .opencode: return "opencode upgrade"
    case .pi: return "pi update --self"
    case .ohMyPi: return "omp update"
    case .grok: return "grok update"
    // No update subcommand: npm (or Homebrew, HarnessCommands.update) installs the new release.
    case .gemini: return "npm install -g @google/gemini-cli@latest"
    }
  }
  /// Oldest CLI version Serein's launch arguments and environment scrub are verified against,
  /// or nil while no floor is verified for that driver. Every request consults this through
  /// HarnessVersionGate; Claude Code's floor also covers the credential scrub (AgentFileGuard).
  public static let codexMinimumVersion = "0.169.0"

  public var minimumCLIVersion: String? {
    switch self {
    case .claude: return AgentFileGuard.minimumClaudeVersion
    case .codex: return Self.codexMinimumVersion
    // xAI refuses every turn from an older Grok: "API error (status 426 Upgrade Required): Your
    // Grok CLI version (1.0.3) is outdated. Please update to version 1.0.13 or later" (2026-11-15).
    case .grok: return "1.0.13"
    default: return nil
    }
  }
  /// Environment set on every probe and run so detection never updates the CLI or rewrites its
  /// configuration as a side effect.
  public var quietEnvironment: [String: String] {
    switch self {
    case .claude: return ["DISABLE_AUTOUPDATER": "1"]
    case .opencode:
      return [
        "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_SHARE": "1", "OPENCODE_DISABLE_MODELS_FETCH": "1",
        "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
      ]
    case .pi, .ohMyPi: return ["PI_SKIP_VERSION_CHECK": "1"]
    // Read from the installed binary: the Grok CLI's own switch for its background updater.
    case .grok: return ["GROK_DISABLE_AUTOUPDATER": "1"]
    default: return [:]
    }
  }
  /// Leading arguments every invocation carries for the same reason (Cursor has a hidden switch
  /// that stops its background updater).
  public var quietArguments: [String] {
    switch self {
    case .cursor: return ["--disable-auto-update"]
    default: return []
    }
  }
}

// MARK: - Instances

public struct HarnessInstance: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var driver: HarnessDriver
  public var displayName: String?
  public var enabled: Bool
  /// An absolute path that replaces PATH discovery.
  public var binaryPath: String?
  /// Extra environment for probes and runs. Names Serein sets itself are ignored.
  public var environment: [String: String]
  /// The user turned this instance on or off themselves; setup never changes it again.
  public var userChose: Bool? = nil
  /// "Use my own setup" (off unless the user turns it on, with the risk named): read-only, web-free
  /// answer, library and project turns load the agent's own MCP servers, connectors and login-shell
  /// keys (OwnSetup.applies decides which turns; the user's choices of 2026-10-18).
  public var ownSetup: Bool? = nil
  /// The variable the instance's API key is given to the CLI as (Settings › AI apps › API key).
  /// Only the name is kept here; the key itself is in Keychain.
  public var keyName: String? = nil
  public var usesOwnSetup: Bool { ownSetup == true }
  public init(
    driver: HarnessDriver, enabled: Bool? = nil, displayName: String? = nil,
    binaryPath: String? = nil, environment: [String: String] = [:]
  ) {
    id = driver.instanceID
    self.driver = driver
    self.displayName = displayName
    self.enabled = enabled ?? driver.enabledByDefault
    self.binaryPath = binaryPath
    self.environment = environment
  }
  public var name: String {
    let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return custom.isEmpty ? driver.displayName : String(custom.prefix(40))
  }
  /// The user's extra variables minus anything Serein relies on for safety.
  public var safeEnvironment: [String: String] {
    environment.filter { HarnessEnvironment.allowed(name: $0.key, driver: driver) }
  }
}

public enum HarnessEnvironment {
  /// Variables a user may not override: they carry Serein's own safety settings.
  static let reserved: Set<String> = [
    "PATH", "HOME", "CODEX_HOME", "CLAUDECODE", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG",
    "OPENCODE_CONFIG_DIR", "OPENCODE_PERMISSION", "OPENCODE_SERVER_PASSWORD",
    "OPENCODE_SERVER_USERNAME", "OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_PURE",
    "OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_EXTERNAL_SKILLS",
    "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "OPENCODE_DISABLE_AUTOUPDATE",
    "PI_SKIP_VERSION_CHECK", "GROK_DISABLE_AUTOUPDATER", "OPENCODE_DISABLE_LSP_DOWNLOAD", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "NODE_OPTIONS",
  ]
  public static func allowed(name: String, driver: HarnessDriver) -> Bool {
    guard !reserved.contains(name), name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil
    else { return false }
    return true
  }
  /// The variable a key saved with no name of its own is given as. Codex reads `CODEX_API_KEY`
  /// from the environment, never `OPENAI_API_KEY`; a name the person saved stays theirs.
  public static func keyName(_ driver: HarnessDriver) -> String {
    switch driver {
    case .claude: return "ANTHROPIC_API_KEY"
    case .codex: return "CODEX_API_KEY"
    case .gemini: return "GEMINI_API_KEY"
    case .cursor: return "CURSOR_API_KEY"
    case .grok: return "XAI_API_KEY"
    case .opencode: return "OPENCODE_API_KEY"
    default: return "NAME_API_KEY"
    }
  }
  /// Why an API key is refused in the text box (it is saved there as plain text).
  public static let keyFieldMessage = "API keys go in the key field (Keychain)."
  /// Parses the Settings text box: one NAME=value per line; blank lines and # comments skipped.
  /// Returns the variables kept and the lines rejected. An API key name is rejected too
  /// (`ModelRoutes.isKeyName`, `keyFieldMessage`): keys go in the key field, which keeps them in
  /// Keychain.
  public static func parse(_ text: String, driver: HarnessDriver) -> (values: [String: String], rejected: [String]) {
    var values: [String: String] = [:]
    var rejected: [String] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard let eq = line.firstIndex(of: "=") else {
        rejected.append(line)
        continue
      }
      let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: eq)...])
      if allowed(name: name, driver: driver), !ModelRoutes.isKeyName(name), value.count <= 4096 {
        values[name] = value
      } else {
        rejected.append(name)
      }
    }
    return (values, rejected)
  }
  public static func format(_ values: [String: String]) -> String {
    values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\n")
  }
}

/// Settings › AI apps, saved in the library.
public struct HarnessSettings: Codable, Equatable, Sendable {
  public static let path = "agents/harnesses.json"
  public var instances: [HarnessInstance]
  public init(instances: [HarnessInstance] = HarnessDriver.allCases.map { HarnessInstance(driver: $0) }) {
    self.instances = instances
    normalize()
  }
  private enum CodingKeys: String, CodingKey { case instances }
  private struct Lossy: Decodable {
    let instance: HarnessInstance?
    init(from decoder: Decoder) throws { instance = try? HarnessInstance(from: decoder) }
  }
  /// An entry for an app Serein no longer has is dropped, not the whole list.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    instances = try values.decode([Lossy].self, forKey: .instances).compactMap(\.instance)
  }
  /// One instance per driver, in driver order; unknown or duplicate entries are dropped.
  public mutating func normalize() {
    var byDriver: [HarnessDriver: HarnessInstance] = [:]
    for instance in instances where byDriver[instance.driver] == nil {
      var fixed = instance
      fixed.id = instance.driver.instanceID
      // Detected harnesses are on unless the user turned them off.
      if fixed.userChose != true { fixed.enabled = true }
      if let path = fixed.binaryPath?.trimmingCharacters(in: .whitespaces), path.isEmpty || !path.hasPrefix("/") {
        fixed.binaryPath = nil
      }
      byDriver[instance.driver] = fixed
    }
    instances = HarnessDriver.allCases.map { byDriver[$0] ?? HarnessInstance(driver: $0) }
  }
  public func instance(_ driver: HarnessDriver) -> HarnessInstance {
    instances.first { $0.driver == driver } ?? HarnessInstance(driver: driver)
  }
  public mutating func update(_ instance: HarnessInstance) {
    if let i = instances.firstIndex(where: { $0.driver == instance.driver }) {
      instances[i] = instance
    } else {
      instances.append(instance)
    }
    normalize()
  }
  public static func load(from library: Library) -> HarnessSettings {
    var settings = library.load(HarnessSettings.self, from: path) ?? HarnessSettings()
    settings.normalize()
    return settings
  }
  public func save(to library: Library) throws {
    try FileManager.default.createDirectory(
      at: library.root.appendingPathComponent("agents"), withIntermediateDirectories: true)
    try library.save(self, to: Self.path)
  }
}

// MARK: - Models

/// One option the composer can show for a model: a select (effort, context window) or a switch
/// (fast mode, thinking).
public struct HarnessOption: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case select, toggle }
  public struct Choice: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public init(_ id: String, _ label: String) {
      self.id = id
      self.label = label
    }
  }
  public var id: String
  public var label: String
  public var kind: Kind
  public var choices: [Choice]
  public var defaultValue: String
  /// The app's own id for this option where Serein's `id` is its shared name ("effort"): what
  /// Cursor's `session/set_config_option` expects. nil when the two are the same.
  public var nativeID: String? = nil
  public static func select(_ id: String, _ label: String, _ choices: [Choice], default value: String? = nil)
    -> HarnessOption
  {
    HarnessOption(
      id: id, label: label, kind: .select, choices: choices,
      defaultValue: value ?? choices.first?.id ?? "")
  }
  public static func toggle(_ id: String, _ label: String, default on: Bool = false) -> HarnessOption {
    HarnessOption(id: id, label: label, kind: .toggle, choices: [], defaultValue: on ? "true" : "false")
  }
  public static func effortLabel(_ id: String) -> String {
    switch id {
    case "xhigh": return "X-High"
    case "max": return "Max"
    default: return id.prefix(1).uppercased() + id.dropFirst()
    }
  }
  /// The effort word shown beside a model's name: none for a model that lists no effort levels,
  /// as none is sent for it.
  public static func effortShown(_ id: String, levels: [String]) -> String? {
    levels.isEmpty ? nil : effortLabel(id)
  }
  public static func effort(_ levels: [String], default value: String? = nil) -> HarnessOption {
    select("effort", "Reasoning", levels.map { Choice($0, effortLabel($0)) }, default: value)
  }
}

public struct HarnessModel: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var blurb: String
  public var isNew: Bool
  public var isLegacy: Bool
  public var isDefault: Bool
  /// The upstream provider for routers (OpenCode · Anthropic).
  public var subProvider: String?
  public var options: [HarnessOption]
  /// models.dev facts for a model a provider connection lists (ProviderStore.decorate).
  public var facts: ModelFacts?
  public init(
    id: String, name: String, blurb: String = "", isNew: Bool = false, isLegacy: Bool = false,
    isDefault: Bool = false, subProvider: String? = nil, options: [HarnessOption] = [], facts: ModelFacts? = nil
  ) {
    self.facts = facts
    self.id = id
    self.name = name
    self.blurb = blurb
    self.isNew = isNew
    self.isLegacy = isLegacy
    self.isDefault = isDefault
    self.subProvider = subProvider
    self.options = options
  }
  public func option(_ id: String) -> HarnessOption? { options.first { $0.id == id } }
  public var effortLevels: [String] { option("effort")?.choices.map(\.id) ?? [] }
  public var hasFastMode: Bool { option("fast") != nil }
  public var contextChoices: [String] { option("context")?.choices.map(\.id) ?? [] }
  public var choice: ModelChoice {
    ModelChoice(model: id, name: name, tier: .balanced, blurb: blurb)
  }
}

// MARK: - Capabilities

/// What Serein can enforce on a harness. A mode is offered only when every limit it needs is
/// enforceable (HarnessPolicy).
public struct HarnessCapabilities: Codable, Equatable, Sendable {
  /// Serein's browser MCP server can be given to the harness for one run.
  public var canInjectMCP = false
  /// File edits can be blocked unless the run grants them.
  public var canRestrictToReadOnly = false
  /// Edits and commands can be confined to the project folder.
  public var canSandboxEdits = false
  /// Shell commands can be turned off.
  public var canBlockShell = false
  /// The harness's own web fetch, search and browser tools can be turned off, so websites are
  /// reached only through Serein's browser capability.
  public var canDisableOwnWeb = false
  /// The user's own MCP servers, plugins and hooks can be kept out of Serein's runs.
  public var canIsolateUserConfig = false
  public var supportsResume = false
  public var supportsInterrupt = false
  public var supportsImages = false
  /// Plain-language reasons a limit is missing, shown in Settings.
  public var notes: [String] = []
  public init() {}

  /// What the driver allows by design. Runtime preflight (user hooks, MCP servers) can only
  /// remove capabilities from this.
  public static func base(_ driver: HarnessDriver) -> HarnessCapabilities {
    var c = HarnessCapabilities()
    switch driver {
    case .claude, .codex:
      c.canInjectMCP = true
      c.canRestrictToReadOnly = true
      c.canSandboxEdits = driver == .codex
      c.canBlockShell = true
      c.canDisableOwnWeb = true
      c.canIsolateUserConfig = true
      c.supportsResume = true
      c.supportsInterrupt = true
      c.supportsImages = true
    case .opencode:
      c.canInjectMCP = true
      c.canRestrictToReadOnly = true
      c.canBlockShell = true
      c.canDisableOwnWeb = true
      c.canIsolateUserConfig = true
      c.supportsResume = true
      c.supportsInterrupt = true
    case .cursor:
      // Every tool call outside the user's allow list asks first, and Serein answers.
      c.canInjectMCP = true
      c.canRestrictToReadOnly = true
      c.canBlockShell = true
      c.canDisableOwnWeb = true
      c.canIsolateUserConfig = true
      c.supportsResume = true
      c.supportsInterrupt = true
      c.notes.append(
        "Cursor reads its own settings, the project's and Claude Code's for hooks, plugins, connected tools and allowed commands, and Serein cannot switch that off. Serein checks those files before every run and declines when any of them could act without asking.")
    case .pi, .ohMyPi:
      // Pi has no MCP: Serein's Pi extension (PiBrowser.js) forwards its browser tools.
      c.canInjectMCP = driver == .pi
      c.canRestrictToReadOnly = true
      c.canBlockShell = true
      c.canDisableOwnWeb = true
      // Oh My Pi 18.11.3's code starts the MCP servers in its own settings and gives their tools
      // to the model also with --no-tools (read, not yet run): not offered until that is checked.
      c.canIsolateUserConfig = driver == .pi
      c.supportsResume = true
      c.supportsInterrupt = true
      c.notes.append(
        driver == .pi
          ? "Pi gets Serein's web tools through a small Pi extension. In web and page tasks those are its only tools: its own file, shell and edit tools are off. Pi never asks before it acts, so Serein does not offer it for Mac tasks; your library and project files stay with Claude Code and Codex. macOS walls it off from your mail, messages, browser data, keys, keychains, Serein's own website data and library, and other agents' sign-ins."
          : "Oh My Pi can start the connected tools in its own settings and give them to the model, also when Serein turns its tools off, so Serein does not offer it for tasks or helper requests until that is checked. Its linked chats still open and reply in its own CLI.")
    case .grok:
      c.canInjectMCP = true
      c.supportsResume = true
      c.supportsInterrupt = true
      c.notes.append(
        "Grok's agent mode loads your ~/.grok plugins, hooks and connected tools, and Serein cannot turn them off. Serein offers Grok for web, page, answer and Mac tasks, with Serein's web tools; your plugins, hooks and connected tools stay on in them. Grok asks before each command, file edit and connected tool there, and Serein declines all but its own web tools. It reads files and lists folders without asking, also outside the task's folder, but macOS walls it off from your mail, messages, browser data, keys, keychains, Serein's own website data and library, and other agents' sign-ins.")
    case .gemini:
      c.canInjectMCP = true
      c.supportsResume = true
      c.supportsInterrupt = true
      c.notes.append(
        "Gemini CLI loads your ~/.gemini settings, extensions and connected tools, and keeps its own Google web search, and Serein cannot turn them off. Serein offers it for web, page, answer and Mac tasks, with Serein's web tools. Serein starts it in its default approval mode, so it asks before each command, file edit and web fetch, and Serein declines all but its own web tools, which count only when Gemini names them as tools of Serein's server (otherwise they are declined too); a tool your Gemini settings allow without asking still runs. It reads files, lists folders and searches the web without asking, but macOS walls it off from your mail, messages, browser data, keys, keychains, Serein's own website data and library, and other agents' sign-ins. Serein never reads its sign-in: sign in by running gemini once in Terminal. Checked against its documentation, not yet against a running copy.")
    }
    return c
  }
}

// MARK: - Snapshots

public struct HarnessSnapshot: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case checking, ready, needsSignIn, needsUpdate, missing, disabled, error
  }
  public var instanceID: String
  public var driver: HarnessDriver
  public var enabled: Bool
  public var installed = false
  public var path: String?
  public var version: String?
  /// nil when the CLI cannot say without a model call.
  public var signedIn: Bool?
  /// Why the last probe could not confirm a sign-in (HarnessParse.Auth.problem).
  public var signInProblem: String?
  /// A plan or provider label, never an email address.
  public var account: String?
  public var latestVersion: String?
  public var needsUpdate = false
  public var status: Status
  public var message: String
  public var models: [HarnessModel] = []
  public var capabilities: HarnessCapabilities
  public var checkedAt: Date?
  /// The switches that start the CLI in ACP mode, read from its own `--help` when it was probed
  /// (Gemini CLI renamed its switch across versions); the launch passes them. nil when it was not
  /// probed or its help lists no ACP mode.
  public var acpArguments: [String]?
  public init(instance: HarnessInstance, status: Status = .checking, message: String? = nil) {
    instanceID = instance.id
    driver = instance.driver
    enabled = instance.enabled
    self.status = instance.enabled ? status : .disabled
    self.message =
      message
      ?? (instance.enabled
        ? "Not checked yet." : "\(instance.name) is off. Turn it on in Settings › AI apps.")
    capabilities = .base(instance.driver)
  }
  public static let noACPMode = "This Gemini CLI is too old for Serein. Update it."
  /// An enabled, installed Gemini CLI whose help listed no ACP mode when it was probed: Serein
  /// cannot drive it until it updates. (An enabled instance is always probed.)
  public var lacksACPMode: Bool { driver == .gemini && enabled && installed && acpArguments == nil }
  /// Installed below Serein's floor (HarnessVersionGate): every request is refused until it
  /// updates, whether or not a newer release has been seen.
  public var tooOld: Bool {
    installed && HarnessVersionGate.refusal(driver: driver, version: version, mode: "answer") != nil
  }
  /// The one-line state shown in the picker rail and Settings.
  public static func summarize(_ s: HarnessSnapshot, name: String) -> (Status, String) {
    if !s.enabled { return (.disabled, s.installed ? "Detected · Enable in Settings" : "Off") }
    if !s.installed { return (.missing, "\(name) is not installed.") }
    if s.lacksACPMode { return (.needsUpdate, noACPMode) }
    if s.signedIn == false { return (.needsSignIn, s.driver.signedOutReason ?? "Not signed in") }
    // The floor applies to every request, so the probe surfaces it with the answer-mode wording.
    // Shown beside the app's Update button (Settings › AI apps, the model picker), so it names
    // no place to go.
    if s.tooOld, let version = s.version, let minimum = s.driver.minimumCLIVersion {
      return (.needsUpdate, "\(name) \(version) is too old for Serein, which needs \(minimum) or later. Choose Update.")
    }
    if s.needsUpdate {
      return (.needsUpdate, "Update available\(s.latestVersion.map { " (\($0))" } ?? "").")
    }
    if let problem = s.signInProblem { return (.error, problem) }
    let version = s.version.map { "v\($0)" } ?? "Installed"
    let app = BundledCLI.app(s.path).map { "Comes with the \($0) app" }
    return (.ready, [version, app, s.account].compactMap { $0 }.joined(separator: " · "))
  }
}

/// The version half of a launch decision: Serein's fixed launch arguments and environment scrub
/// only parse on CLIs that support them, so a too-old CLI is refused with an update instruction
/// before anything starts. A nil version (probe not run yet) only blocks file modes, where the
/// credential isolation must be provable before anything is exposed.
public enum HarnessVersionGate {
  /// nil means the version gate allows the request; other policy layers still apply.
  public static func refusal(driver: HarnessDriver, version: String?, mode: String) -> String? {
    guard let minimum = driver.minimumCLIVersion else { return nil }
    let fileMode = ["project", "library"].contains(mode)
    if fileMode, driver == .claude, version == nil {
      return "Refresh Claude Code in Settings › AI apps before allowing file access."
    }
    guard let version, HarnessParse.isOlder(version, than: minimum) else { return nil }
    // Only Claude Code's floor covers the credential scrub (AgentFileGuard).
    // Plain words and the place to act: Settings › AI apps has the Update button
    // (HarnessPrimaryAction), so nobody is sent to a terminal.
    return fileMode && driver == .claude
      ? "Update \(driver.displayName) to \(minimum) or later before it works on your files, so Serein can keep your passwords and keys out of its reach. Choose Update in Settings › AI apps."
      : "\(driver.displayName) \(version) is too old for Serein, which needs \(minimum) or later. Choose Update in Settings › AI apps."
  }
}

// MARK: - Run permission modes

/// How much a run may do without stopping. Grants (edits, actions) still decide what it may
/// touch; this decides how the harness asks.
public enum RunPermissionMode: String, Codable, CaseIterable, Sendable {
  case supervised
  case autoAcceptEdits = "auto-accept-edits"
  case auto
  case fullAccess = "full-access"
  public var label: String {
    switch self {
    case .supervised: return "Supervised"
    case .autoAcceptEdits: return "Auto-accept edits"
    case .auto: return "Auto"
    case .fullAccess: return "Full access"
    }
  }
  /// In the words of “Serein asks before”, the one permission choice the person knows: each mode
  /// says what the task asks before, so nobody learns a second vocabulary.
  public var detail: String {
    switch self {
    case .supervised: return "Asks before anything this task was not allowed."
    case .autoAcceptEdits: return "Asks before commands. Allowed project edits apply."
    case .auto: return "Asks before risky commands. Routine ones run in the project. Needs edits allowed."
    case .fullAccess: return "Never asks in the project. Needs edits allowed and a one-time confirmation."
    }
  }
  public var icon: String {
    switch self {
    case .supervised: return "lock"
    case .autoAcceptEdits: return "pencil"
    case .auto: return "sparkles"
    case .fullAccess: return "lock.open"
    }
  }
  /// Auto and Full access let the harness run commands, so they need a project with edits.
  public var needsProjectEdits: Bool { self == .auto || self == .fullAccess }
}

/// The composer's project chip: one choice for "Allow project edits" and the run permission.
/// Project tasks run on `HarnessPolicy.fileDrivers`, where Supervised and Auto-accept edits launch
/// with the same flags, so both read as "Edit files".
public enum ProjectAccess: String, CaseIterable, Identifiable, Sendable {
  case review, edit, commands, full
  public var id: String { rawValue }
  public init(edits: Bool, permission: RunPermissionMode) {
    guard edits else {
      self = .review
      return
    }
    switch permission {
    case .supervised, .autoAcceptEdits: self = .edit
    case .auto: self = .commands
    case .fullAccess: self = .full
    }
  }
  public var edits: Bool { self != .review }
  public var permission: RunPermissionMode {
    switch self {
    case .review, .edit: return .supervised
    case .commands: return .auto
    case .full: return .fullAccess
    }
  }
  /// What a project task asks before, finishing “Ask before …”; nil never asks. The one wording
  /// for the menu, the chip and the task line, under the same heading as `ApprovalLevel`.
  public var asksBefore: String? {
    switch self {
    case .review: return "edits"
    case .edit: return "commands"
    case .commands: return "risky commands"
    case .full: return nil
    }
  }
  public var title: String { asksBefore.map { "Ask before \($0)" } ?? "Never ask (full access)" }
  /// The chip's short note.
  public var note: String { asksBefore.map { "asks before \($0)" } ?? "never asks" }
}

// MARK: - Policy

public enum HarnessVerdict: Equatable, Sendable {
  case allowed
  case refused(String)
  public var allowed: Bool { self == .allowed }
  public var reason: String? {
    if case .refused(let r) = self { return r }
    return nil
  }
}

/// Decides whether a harness may run a Serein mode, from what Serein can enforce on it.
/// `mode` is TaskMode.runKey.
public enum HarnessPolicy {
  public static let concreteModes = ["answer", "library", "anywhere", "research", "page", "project"]

  /// The harnesses that may run Project and Library tasks: Serein enforces its private-file and
  /// credential exclusions only for these (OpenCode through its file guard, EngineChecks+ACPGuard).
  /// The model picker offers no other for those tasks.
  public static let fileDrivers: Set<HarnessDriver> = [.claude, .codex, .opencode]
  /// The harness a Project or Library task moves to when `current` cannot work on files: the one
  /// the project used last if it is set up, else the first that is set up, else Claude Code (the
  /// send then says how to set it up). Nil when `current` can.
  public static func fileHarness(
    current: HarnessDriver?, lastUsed: HarnessDriver?, available: Set<HarnessDriver>
  ) -> HarnessDriver? {
    fit(current: current, lastUsed: lastUsed, available: HarnessDriver.allCases.filter(available.contains),
      allows: fileDrivers.contains) ?? (current.map(fileDrivers.contains) == false ? .claude : nil)
  }
  /// The harness a task moves to when `current` cannot run its place (`allows`): `lastUsed` when it
  /// can and is set up, else the first of `available`, in order, that can. Nil when `current` can
  /// (or is unknown), or when none can; the send's refusal then says what to choose.
  public static func fit(
    current: HarnessDriver?, lastUsed: HarnessDriver? = nil, available: [HarnessDriver],
    allows: (HarnessDriver) -> Bool
  ) -> HarnessDriver? {
    guard let current, !allows(current) else { return nil }
    if let lastUsed, available.contains(lastUsed), allows(lastUsed) { return lastUsed }
    return available.first(where: allows)
  }
  /// The harnesses that run web, page, answer and Mac tasks with their own setup on: their own
  /// plugins, hooks, MCP servers and web tools, and in answer and Mac tasks no read-only or
  /// no-shell guarantee from Serein (the user's choice on 2026-10-17, with that risk named).
  /// Every other check in `verdict` still applies; project and library stay on `fileDrivers`.
  /// Checked live over ACP with Serein's arguments: Grok 1.0.50 asks before every command, file
  /// edit and MCP tool call, also when its config says always-approve, and Serein declines all
  /// but its own browser tools; it reads files and lists folders without asking, also outside
  /// the task's folder. Gemini CLI, from its documentation and not yet checked live,
  /// is started in its default approval mode, so it asks before commands, edits and web fetches;
  /// it reads, lists and searches without asking.
  public static let ownSetupDrivers: Set<HarnessDriver> = [.grok, .gemini]
  public static let ownSetupModes: Set<String> = ["research", "page", "answer", "anywhere"]
  static func ownSetupAllowed(_ driver: HarnessDriver, mode: String) -> Bool {
    ownSetupDrivers.contains(driver) && ownSetupModes.contains(mode)
  }
  /// Pi and Oh My Pi never ask before they act. The user gave Pi Serein's browser for web and page
  /// tasks only (2026-10-18), not control of the Mac, so Anywhere stays closed to them although
  /// their shell can be turned off. Serein's own turns are the exception (`relay`, the user's
  /// choice on 2026-11-15): Pi thinks for Serein with its built-ins off and only Serein's tools,
  /// each with its own ask.
  static let noMacDrivers: Set<HarnessDriver> = [.pi, .ohMyPi]
  /// "Claude Code, Codex, Cursor or OpenCode": the harnesses whose own limits allow `test`, for
  /// a refusal that says what to choose.
  static func choices(_ test: (HarnessDriver, HarnessCapabilities) -> Bool) -> String {
    let names = HarnessDriver.allCases.filter { test($0, .base($0)) }.map(\.displayName)
    guard let last = names.last else { return "another agent" }
    return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
  }
  public static func verdict(
    driver: HarnessDriver, capabilities c: HarnessCapabilities, mode: String, edits: Bool,
    permission: RunPermissionMode, relay: Bool = false
  ) -> HarnessVerdict {
    let name = driver.displayName
    if mode == "auto" {
      // Routing runs on Claude Code, Codex or the selected OpenCode model; the routed turn is checked again.
      return .allowed
    }
    let ownSetup = ownSetupAllowed(driver, mode: mode)
    guard c.canIsolateUserConfig || ownSetup else {
      return .refused(
        "\(name) would load your own MCP servers, plugins or hooks, and Serein cannot turn them off for its tasks.")
    }
    guard c.canDisableOwnWeb || ownSetup else {
      return .refused(
        "\(name) has its own web tools that Serein cannot turn off. Websites must go through Serein's browser.")
    }
    if ["project", "library"].contains(mode), !fileDrivers.contains(driver) {
      let destination = mode == "library" ? "Library" : "Project"
      return .refused(
        "Can't send with \(name) in \(destination) mode: Serein cannot enforce its private-file and credential exclusions. Switch to Answer for a chat, or choose \(choices { d, _ in fileDrivers.contains(d) }) for file tasks.")
    }
    switch mode {
    case "research", "page":
      guard c.canInjectMCP else {
        return .refused(
          "\(name) cannot receive Serein's browser tools, so it cannot work on websites. Choose \(choices { d, c in (c.canIsolateUserConfig && c.canDisableOwnWeb || ownSetupAllowed(d, mode: mode)) && c.canInjectMCP }) for this task.")
      }
    case "anywhere":
      let macChoices = choices { d, c in
        let own = ownSetupAllowed(d, mode: mode)
        return (c.canIsolateUserConfig && c.canDisableOwnWeb || own) && c.canInjectMCP && (c.canBlockShell || own)
          && !noMacDrivers.contains(d)
      }
      guard c.canInjectMCP, c.canBlockShell || ownSetup else {
        return .refused("\(name) cannot be limited to Serein's Mac tool without a shell. Choose \(macChoices) for this task.")
      }
      guard !noMacDrivers.contains(driver) || relay else {
        return .refused("\(name) never asks before it acts, so Serein does not give it control of your Mac. Choose \(macChoices) for this task.")
      }
    case "answer":
      guard c.canRestrictToReadOnly && c.canBlockShell || ownSetup else {
        return .refused("\(name) cannot be kept from changing files or running commands.")
      }
    case "library":
      guard c.canRestrictToReadOnly, c.canBlockShell || c.canSandboxEdits else {
        return .refused("\(name) cannot be kept read-only in your library.")
      }
    case "project":
      if !edits {
        guard c.canRestrictToReadOnly, c.canBlockShell || c.canSandboxEdits else {
          return .refused("\(name) cannot be kept read-only. Allow edits to use it here.")
        }
      }
    default:
      return .refused("\(name) does not support this kind of task.")
    }
    return .allowed
  }

  /// Modes offered at all (with edits granted and Supervised), for Settings.
  public static func offeredModes(driver: HarnessDriver, capabilities: HarnessCapabilities) -> [String] {
    concreteModes.filter {
      verdict(
        driver: driver, capabilities: capabilities, mode: $0, edits: $0 == "project",
        permission: .supervised
      ).allowed
    }
  }
  public static func modeLabel(_ key: String) -> String {
    switch key {
    case "answer": return "Answer"
    case "library": return "Library"
    case "anywhere": return "Anywhere"
    case "research": return "Research"
    case "page": return "This page"
    case "project": return "Project"
    default: return key
    }
  }
}

// MARK: - First-run setup

/// What the setup step and Settings show for one harness, and which detected harnesses setup
/// turns on by itself.
public enum HarnessSetup {
  public enum State: String, Sendable { case ready, needsSignIn, needsUpdate, detectedOff, notInstalled, checking }
  public static func state(_ s: HarnessSnapshot?, enabled: Bool) -> State {
    guard let s, s.checkedAt != nil else { return .checking }
    if !s.installed { return .notInstalled }
    if !enabled { return .detectedOff }
    if s.signedIn == false { return .needsSignIn }
    if s.needsUpdate || s.tooOld { return .needsUpdate }
    return .ready
  }
  public static func label(_ state: State) -> String {
    switch state {
    case .ready: return "Ready"
    case .needsSignIn: return "Needs sign-in"
    case .needsUpdate: return "Update available"
    case .detectedOff: return "Detected · not enabled"
    case .notInstalled: return "Not installed"
    case .checking: return "Checking…"
    }
  }
  /// Every detected harness is turned on unless the user turned it off themselves.
  public static func shouldAutoEnable(_ instance: HarnessInstance, snapshot s: HarnessSnapshot?) -> Bool {
    !instance.enabled && instance.userChose != true && s?.installed == true
  }
  /// Detected harnesses first (in driver order), then the ones not installed.
  public static func order(_ instances: [HarnessInstance], snapshots: [HarnessDriver: HarnessSnapshot]) -> (detected: [HarnessInstance], missing: [HarnessInstance]) {
    let detected = instances.filter { snapshots[$0.driver]?.installed == true }
    let missing = instances.filter { snapshots[$0.driver]?.installed != true }
    return (detected, missing)
  }
}

/// A harness's own session history location (read-only).
public struct HarnessSessionStore: Equatable, Sendable {
  public enum Format: String, Sendable { case jsonl, sqlite, directory }
  /// Starts with "~/".
  public var root: String
  /// Layout under the root, for people and the importer.
  public var pattern: String
  public var format: Format
  public var note: String
  /// The location was seen on a development Mac (read-only listing, contents not parsed).
  public var verifiedLocally: Bool
  public func url(home: String) -> URL {
    URL(fileURLWithPath: root.hasPrefix("~/") ? home + root.dropFirst(1) : root)
  }
}
