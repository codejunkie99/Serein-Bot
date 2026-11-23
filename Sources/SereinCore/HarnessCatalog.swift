import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Where an installed capability comes from: the user's own setup or one project (the folder and
/// its parents up to the repository root).
public enum CapabilityScope: String, Codable, Sendable {
  case user, project
}

/// What a paired harness has installed: its skills, its slash commands and the MCP servers it is
/// configured to talk to, for the user's setup and, when asked, one project — including what the
/// harness's own plugins or packages add. Serein only lists names, short descriptions and whether
/// each is on, so Relay (and Settings › AI apps) can answer "what can Claude Code do here?"; it
/// never reads a server's command, arguments, URL, headers or environment, and never runs
/// anything. Everything parsed is untrusted text: names and details are length-capped and counts
/// are bounded.
public struct HarnessCapability: Equatable, Sendable, Codable {
  public var name: String
  /// A one-line description, or why an item is off. Never a secret, path, argument or environment value.
  public var detail: String?
  public var scope: CapabilityScope
  /// False when the harness has it but would not use it: a server switched off or waiting for the
  /// user's approval, a project the harness does not trust yet, or a plugin that is not turned on.
  public var enabled: Bool
  public init(name: String, detail: String? = nil, scope: CapabilityScope = .user, enabled: Bool = true) {
    self.name = name
    self.detail = detail
    self.scope = scope
    self.enabled = enabled
  }
}

/// Everything one harness offers, by kind. Empty kinds are simply empty (a harness may have no
/// concept of skills or commands).
public struct HarnessCapabilityReport: Equatable, Sendable, Codable {
  public var driver: HarnessDriver
  /// The project folder that was read for project scope; nil for the user's setup alone.
  public var project: String?
  public var skills: [HarnessCapability]
  public var commands: [HarnessCapability]
  public var mcpServers: [HarnessCapability]
  /// False when the layout comes from the harness's documentation and source, not from checking a
  /// running copy of it (see `CapabilitySources.verified`).
  public var verified: Bool
  public init(
    driver: HarnessDriver, project: String? = nil, skills: [HarnessCapability] = [],
    commands: [HarnessCapability] = [], mcpServers: [HarnessCapability] = [], verified: Bool = true
  ) {
    self.driver = driver
    self.project = project
    self.skills = skills
    self.commands = commands
    self.mcpServers = mcpServers
    self.verified = verified
  }
  public var isEmpty: Bool { skills.isEmpty && commands.isEmpty && mcpServers.isEmpty }
  public var total: Int { skills.count + commands.count + mcpServers.count }
}

/// A folder of skills (`<name>/SKILL.md`). User paths are absolute; project paths are relative to
/// a project folder.
public struct SkillRoot: Sendable, Equatable {
  public var path: String
  /// Folder levels that may hold skills: 1 for `<root>/<skill>`, more where skills may sit in
  /// grouping folders.
  public var depth: Int
  /// Project only: also look in each parent up to the repository root, not just the project folder.
  public var walkUp: Bool
  /// The harness skips a skill whose front matter has no description.
  public var requireDescription: Bool
  /// The harness source this root belongs to, for harnesses that switch sources on and off
  /// (Oh My Pi's `enabledProviders` / `disabledProviders`); nil for always on.
  public var provider: String?
  /// Read only when the user opted this source in (Oh My Pi's foreign user-level sources).
  public var optIn: Bool
  public init(
    _ path: String, depth: Int = 1, walkUp: Bool = true, requireDescription: Bool = false,
    provider: String? = nil, optIn: Bool = false
  ) {
    self.path = path
    self.depth = depth
    self.walkUp = walkUp
    self.requireDescription = requireDescription
    self.provider = provider
    self.optIn = optIn
  }
}

/// A folder of `*.md` slash commands.
public struct CommandRoot: Sendable, Equatable {
  public var path: String
  /// 1 for files directly in the folder; more to include subfolders (the name stays the file's).
  public var depth: Int
  public var walkUp: Bool
  /// A front-matter `name` replaces the file name (Oh My Pi's Codex and OpenCode sources).
  public var nameFromFrontMatter: Bool
  public var provider: String?
  public var optIn: Bool
  public init(
    _ path: String, depth: Int = 1, walkUp: Bool = true, nameFromFrontMatter: Bool = false,
    provider: String? = nil, optIn: Bool = false
  ) {
    self.path = path
    self.depth = depth
    self.walkUp = walkUp
    self.nameFromFrontMatter = nameFromFrontMatter
    self.provider = provider
    self.optIn = optIn
  }
}

/// A config file that may name MCP servers.
public struct MCPFile: Sendable, Equatable {
  public var path: String
  public var format: CapabilitySources.MCPFormat
  public var walkUp: Bool
  public var provider: String?
  public var optIn: Bool
  public init(
    _ path: String, _ format: CapabilitySources.MCPFormat, walkUp: Bool = true, provider: String? = nil,
    optIn: Bool = false
  ) {
    self.path = path
    self.format = format
    self.walkUp = walkUp
    self.provider = provider
    self.optIn = optIn
  }
}

/// Where a harness keeps the things we list and how its config is written: user roots (absolute,
/// after the variables that move each home) and project roots (relative to a project folder), plus
/// the homes that hold a harness's own rules for plugins, trust and switches.
public struct CapabilitySources: Sendable, Equatable {
  /// How a harness records the MCP servers it connects to.
  public enum MCPFormat: Sendable, Equatable {
    /// JSON with a top-level `mcpServers` object (Claude Code, Cursor, Pi, Gemini…).
    case jsonServers
    /// TOML with `[mcp_servers.<name>]` tables (Codex, Grok).
    case tomlTables
    /// JSON(C) with a top-level `mcp` object (OpenCode).
    case opencodeJSON
    /// VS Code's `.vscode/mcp.json`: a top-level `servers` object (or `mcp.servers`).
    case vscodeServers
  }
  public var skills: [SkillRoot]
  public var commands: [CommandRoot]
  public var mcp: [MCPFile]
  public var projectSkills: [SkillRoot]
  public var projectCommands: [CommandRoot]
  public var projectMCP: [MCPFile]
  /// Claude Code's config folder (`~/.claude` or `CLAUDE_CONFIG_DIR`): its plugins and settings.
  public var claudeHome: String?
  /// Claude Code's `.claude.json`: per-project servers and the user's approvals for them.
  public var claudeIndex: String?
  /// Codex's home (`~/.codex` or `CODEX_HOME`): its plugins.
  public var codexHome: String?
  /// Pi's agent directory (`~/.pi/agent` or `PI_CODING_AGENT_DIR`): trust, packages, MCP switch.
  public var piAgentDir: String?
  /// Oh My Pi's active agent directory and config root (`~/.omp`): settings, server lists, plugins.
  public var ompAgentDir: String?
  public var ompRoot: String?
  /// Oh My Pi honours `enabled: false` in a skill's front matter.
  public var frontMatterEnabled: Bool
  /// True when this layout was checked against a running copy of the harness on a Mac; false when
  /// it follows the harness's documentation and source only.
  public var verified: Bool
  public init(
    skills: [SkillRoot] = [], commands: [CommandRoot] = [], mcp: [MCPFile] = [], projectSkills: [SkillRoot] = [],
    projectCommands: [CommandRoot] = [], projectMCP: [MCPFile] = [], claudeHome: String? = nil,
    claudeIndex: String? = nil, codexHome: String? = nil, piAgentDir: String? = nil,
    ompAgentDir: String? = nil, ompRoot: String? = nil, frontMatterEnabled: Bool = false, verified: Bool = true
  ) {
    self.skills = skills
    self.commands = commands
    self.mcp = mcp
    self.projectSkills = projectSkills
    self.projectCommands = projectCommands
    self.projectMCP = projectMCP
    self.claudeHome = claudeHome
    self.claudeIndex = claudeIndex
    self.codexHome = codexHome
    self.piAgentDir = piAgentDir
    self.ompAgentDir = ompAgentDir
    self.ompRoot = ompRoot
    self.frontMatterEnabled = frontMatterEnabled
    self.verified = verified
  }
  public var skillDirs: [String] { skills.map(\.path) }
  public var mcpFiles: [String] { mcp.map(\.path) }
  public var isEmpty: Bool {
    skills.isEmpty && commands.isEmpty && mcp.isEmpty && !hasProjectScope && codexHome == nil && ompRoot == nil
  }
  /// Whether a project can add anything of its own.
  public var hasProjectScope: Bool {
    !projectSkills.isEmpty || !projectCommands.isEmpty || !projectMCP.isEmpty || claudeIndex != nil
      || claudeHome != nil || piAgentDir != nil
  }
}

/// Pure parsers (safe on untrusted text) plus a bounded disk reader that assembles one harness's
/// report from the files its `CapabilitySources` points at.
public enum HarnessCatalog {
  public static let maxPerKind = 400
  public static let maxName = 80
  public static let maxDetail = 300
  /// SKILL.md and command files we open at all: enough for front matter and a lead paragraph.
  public static let maxReadBytes = 128 * 1024
  /// Config files get a larger budget: Claude Code's `~/.claude.json` keeps project state in the
  /// same file as `mcpServers`, so it grows well past a skill's size.
  public static let maxConfigBytes = 8 * 1024 * 1024
  /// Folders a skill or command search may open, across all levels, before it stops.
  static let maxScannedFolders = 2000
  /// Plugin marketplaces, plugins per marketplace, and packages looked at.
  static let maxPlugins = 200
  /// "Any depth" for harnesses that search every level below a root.
  public static let deep = 8

  // MARK: Parsers

  /// A skill's name and description from `SKILL.md` front matter (scalar or a `>`/`|` block),
  /// tolerant of the many third-party skills that do not follow Serein's own strict rules. The
  /// harnesses name a skill by its front-matter `name` (Codex reports it, not the
  /// folder); the folder name stands in when there is none.
  public static func skill(folder: String, markdown: String) -> HarnessCapability {
    let fields = frontMatter(markdown)
    let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder
    return HarnessCapability(name: clip(name, maxName), detail: fields["description"].map { clip($0, maxDetail) })
  }

  /// A slash command's name (`/<file>` without its extension) and a one-line summary: front-matter
  /// `description` when present, else the first prose line of the body.
  public static func command(file: String, markdown: String) -> HarnessCapability {
    let base = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    let fields = frontMatter(markdown)
    let detail = fields["description"] ?? firstProseLine(stripFrontMatter(markdown))
    return HarnessCapability(name: clip("/" + base, maxName), detail: detail.map { clip($0, maxDetail) })
  }

  /// MCP server names from one config file's text, by format.
  public static func mcpServers(_ text: String, format: CapabilitySources.MCPFormat) -> [String] {
    mcpServerStates(text, format: format).map(\.name)
  }

  /// MCP server names and whether the config switches each off (`enabled = false`,
  /// `"disabled": true`). Names and that flag only — never a command, argument, URL, header or
  /// environment value.
  public static func mcpServerStates(_ text: String, format: CapabilitySources.MCPFormat) -> [(name: String, enabled: Bool)] {
    switch format {
    case .jsonServers: return jsonServerStates(text, key: "mcpServers", topLevel: false)
    case .opencodeJSON: return jsonServerStates(stripLineComments(text), key: "mcp", topLevel: false)
    case .tomlTables: return tomlServerStates(text)
    case .vscodeServers:
      let json = jsonObject(stripLineComments(text))
      let servers = json["servers"] as? [String: Any] ?? (json["mcp"] as? [String: Any])?["servers"] as? [String: Any] ?? [:]
      return serverStates(servers)
    }
  }

  /// Servers Claude Code keeps for one project in `~/.claude.json` (`projects[<folder>].mcpServers`),
  /// for any of the given folders (the project and its parents up to the repository root).
  public static func perProjectServers(_ text: String, folders: [String]) -> [String] {
    claudeProjectState(text, folders: folders).local
  }

  // MARK: Disk reader

  /// Reads one harness's installed capabilities for the user's setup and, with `project`, that
  /// project's own. Read-only and bounded: names, descriptions and on/off flags from fixed file
  /// names, regular files under a size cap, a limited folder search. Links are followed the way
  /// the harnesses follow them (skills installed as symbolic links, dotfile-managed configs).
  /// `home` and `environment` (CLAUDE_CONFIG_DIR, CODEX_HOME, PI_CODING_AGENT_DIR…) are injectable.
  public static func read(
    _ driver: HarnessDriver, project: String? = nil, home: String = NSHomeDirectory(),
    environment: [String: String] = ProcessInfo.processInfo.environment, fileManager fm: FileManager = .default
  ) -> HarnessCapabilityReport {
    let s = driver.capabilitySources(home: home, environment: environment)
    let name = driver.displayName
    var skills = Entries()
    var commands = Entries()
    var servers = Entries()

    var folders: [URL] = []
    if let project, !project.isEmpty {
      folders = CodexChecks.projectFolders(
        from: URL(fileURLWithPath: project, isDirectory: true), home: home, fileManager: fm)
    }
    let here = folders.first

    // Oh My Pi switches whole sources on and off; everything else reads every root.
    let omp = s.ompAgentDir.map { OMPConfig(agentDir: URL(fileURLWithPath: $0), project: here, fm: fm) }
    func allowed(_ provider: String?, _ optIn: Bool) -> Bool {
      guard let omp, let provider else { return true }
      if omp.disabledProviders.contains(provider) { return false }
      return !optIn || omp.enabledProviders.contains(provider) || omp.enabledProviders.contains("*")
        || omp.enabledProviders.contains("all")
    }

    // Pi loads a project's own resources only once the user trusts the project.
    var projectGate: (Bool, String?)?
    if let dir = s.piAgentDir, let here {
      switch piTrust(agentDir: URL(fileURLWithPath: dir), project: here, home: home, fm: fm) {
      case true?: projectGate = nil
      case false?: projectGate = (false, "Not trusted in Pi")
      case nil: projectGate = (false, "Waiting for project trust in Pi")
      }
    }

    func addSkills(_ root: SkillRoot, _ dir: URL, _ scope: CapabilityScope, prefix: String = "") {
      for found in skillFolders(dir, depth: root.depth, fm: fm) {
        var c = skill(folder: found.name, markdown: found.markdown)
        c.name = clip(prefix + c.name, maxName)
        let fields = frontMatter(found.markdown)
        if root.requireDescription, (fields["description"] ?? "").isEmpty {
          c.enabled = false
          c.detail = "No description, so \(name) skips it"
        } else if s.frontMatterEnabled, fields["enabled"] == "false" {
          c.enabled = false
          c.detail = "Turned off in its SKILL.md"
        }
        if scope == .project, let gate = projectGate { (c.enabled, c.detail) = (false, gate.1) }
        skills.add(c, scope)
      }
    }
    func addCommands(_ root: CommandRoot, _ dir: URL, _ scope: CapabilityScope, prefix: String = "") {
      for file in markdownFiles(dir, depth: root.depth, fm: fm) {
        let markdown = (try? text(file, fm: fm)) ?? ""
        var c = command(file: file.lastPathComponent, markdown: markdown)
        if root.nameFromFrontMatter, let named = frontMatter(markdown)["name"], !named.isEmpty { c.name = "/" + named }
        c.name = clip("/" + prefix + c.name.dropFirst(), maxName)
        if scope == .project, let gate = projectGate { (c.enabled, c.detail) = (false, gate.1) }
        commands.add(c, scope)
      }
    }
    /// One server: `state` is on/off and a reason.
    func addServer(_ name: String, _ scope: CapabilityScope, _ state: (Bool, String?)) {
      var state = state
      if scope == .project, let gate = projectGate { state = (false, gate.1) }
      servers.add(HarnessCapability(name: clip(name, maxName), detail: state.1, enabled: state.0), scope)
    }

    let index = s.claudeIndex.flatMap { try? text(URL(fileURLWithPath: $0), fm: fm, limit: maxConfigBytes) }
    let claude = index.map { claudeProjectState($0, folders: folders.map(\.path)) } ?? ClaudeProjectState()
    /// Claude Code switches a server off per project with `/mcp`.
    func claudeState(_ name: String, _ on: Bool) -> (Bool, String?) {
      if claude.disabled.contains(name) { return (false, "Turned off in this project") }
      return on ? (true, nil) : (false, "Turned off in its config")
    }
    func ownState(_ on: Bool) -> (Bool, String?) { on ? (true, nil) : (false, "Turned off in its config") }
    func addServers(_ file: MCPFile, _ url: URL, _ scope: CapabilityScope) {
      guard let config = try? text(url, fm: fm, limit: maxConfigBytes) else { return }
      for (name, on) in mcpServerStates(config, format: file.format) {
        addServer(name, scope, s.claudeIndex != nil && scope == .user ? claudeState(name, on) : ownState(on))
      }
    }

    // The user's setup.
    for root in s.skills where allowed(root.provider, root.optIn) { addSkills(root, URL(fileURLWithPath: root.path), .user) }
    for root in s.commands where allowed(root.provider, root.optIn) { addCommands(root, URL(fileURLWithPath: root.path), .user) }
    for file in s.mcp where allowed(file.provider, file.optIn) { addServers(file, URL(fileURLWithPath: file.path), .user) }

    // Plugins and packages. Claude Code names their items `<plugin>:<item>` and their servers
    // `plugin:<plugin>:<server>`; Codex keeps a plugin's server names as they are and lists servers
    // from installed plugins that are off, as `codex mcp list` does.
    if let home = s.claudeHome {
      for plugin in claudePlugins(home: URL(fileURLWithPath: home), project: here, fm: fm) {
        let prefix = plugin.name + ":"
        addSkills(SkillRoot(""), plugin.folder.appendingPathComponent("skills"), plugin.scope, prefix: prefix)
        addCommands(CommandRoot(""), plugin.folder.appendingPathComponent("commands"), plugin.scope, prefix: prefix)
        for (name, on) in pluginServers(plugin.folder, manifest: ".claude-plugin/plugin.json", fm: fm) {
          let full = "plugin:" + plugin.name + ":" + name
          addServer(full, plugin.scope, claudeState(full, on))
        }
      }
    }
    if let home = s.codexHome {
      for plugin in codexPlugins(home: URL(fileURLWithPath: home), fm: fm) {
        if plugin.enabled {
          addSkills(SkillRoot("", depth: 3), plugin.folder.appendingPathComponent("skills"), .user, prefix: plugin.name + ":")
        }
        for (name, on) in pluginServers(plugin.folder, manifest: ".codex-plugin/plugin.json", fm: fm) {
          addServer(name, .user, plugin.enabled ? ownState(on) : (false, "Its plugin \(plugin.name) is off"))
        }
      }
    }
    if let root = s.ompRoot, allowed("omp-plugins", false) {
      for folder in packageFolders(URL(fileURLWithPath: root).appendingPathComponent("plugins/node_modules"), fm: fm) {
        addSkills(SkillRoot("", requireDescription: true), folder.appendingPathComponent("skills"), .user)
        addCommands(CommandRoot(""), folder.appendingPathComponent("commands"), .user)
      }
    }
    if let dir = s.piAgentDir {
      let agent = URL(fileURLWithPath: dir)
      for package in piPackages(settings: agent.appendingPathComponent("settings.json"), installRoot: agent, home: home, fm: fm) {
        for skillDir in package.skills { addSkills(SkillRoot("", depth: deep, requireDescription: true), skillDir, .user) }
        for promptDir in package.prompts { addCommands(CommandRoot(""), promptDir, .user) }
      }
    }

    // The project's own.
    if let here {
      for root in s.projectSkills where allowed(root.provider, root.optIn) {
        for folder in root.walkUp ? folders : [here] { addSkills(root, folder.appendingPathComponent(root.path), .project) }
      }
      for root in s.projectCommands where allowed(root.provider, root.optIn) {
        for folder in root.walkUp ? folders : [here] { addCommands(root, folder.appendingPathComponent(root.path), .project) }
      }
      for file in s.projectMCP where allowed(file.provider, file.optIn) {
        for folder in file.walkUp ? folders : [here] {
          let url = folder.appendingPathComponent(file.path)
          guard let config = try? text(url, fm: fm, limit: maxConfigBytes) else { continue }
          for (name, ownFlag) in mcpServerStates(config, format: file.format) {
            guard s.claudeIndex != nil else { addServer(name, .project, ownState(ownFlag)); continue }
            // Claude Code asks before using a project's `.mcp.json` servers.
            if claude.declined.contains(name) {
              addServer(name, .project, (false, "Declined in Claude Code"))
            } else if claude.approved.contains(name) || claudeApprovesAll(s, folder: here, fm: fm) {
              addServer(name, .project, claudeState(name, ownFlag))
            } else {
              addServer(name, .project, (false, "Waiting for approval in Claude Code"))
            }
          }
        }
      }
      for name in claude.local { addServer(name, .project, claudeState(name, true)) }

      // Pi: a project entry without `command`, `url` or `type` only switches the user-level server of
      // the same name; the project's own packages load with the rest of the project.
      if s.piAgentDir != nil {
        let project = jsonObject((try? text(here.appendingPathComponent(".pi/mcp.json"), fm: fm, limit: maxConfigBytes)) ?? "")
        for (server, value) in (project["mcpServers"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
          let entry = value as? [String: Any] ?? [:]
          let on = entry["enabled"] as? Bool != false
          let isOverride = entry["command"] == nil && entry["url"] == nil && entry["type"] == nil
          if isOverride, servers.contains(server, .user) {
            if projectGate == nil, !on { servers.update(server, .user) { ($0.enabled, $0.detail) = (false, "Turned off in this project") } }
            if projectGate == nil, on { servers.update(server, .user) { ($0.enabled, $0.detail) = (true, nil) } }
          } else {
            addServer(server, .project, ownState(on))
          }
        }
        for package in piPackages(
          settings: here.appendingPathComponent(".pi/settings.json"), installRoot: here.appendingPathComponent(".pi"),
          home: home, fm: fm)
        {
          for skillDir in package.skills { addSkills(SkillRoot("", depth: deep, requireDescription: true), skillDir, .project) }
          for promptDir in package.prompts { addCommands(CommandRoot(""), promptDir, .project) }
        }
      }
    }

    // Switches that apply across sources.
    if let dir = s.piAgentDir, piMCPOff(agentDir: URL(fileURLWithPath: dir), project: projectGate == nil ? here : nil, fm: fm) {
      servers.updateAll { ($0.enabled, $0.detail) = (false, "Pi's built-in MCP support is turned off") }
    }
    if let omp {
      skills.updateAll { if omp.disabledSkills.contains($0.name) { ($0.enabled, $0.detail) = (false, "Turned off in Oh My Pi settings") } }
      servers.updateAll {
        if omp.disabledServers.contains($0.name) {
          ($0.enabled, $0.detail) = (false, "Turned off in Oh My Pi")
        } else if omp.enabledServers.contains($0.name), !$0.enabled {
          ($0.enabled, $0.detail) = (true, nil)
        }
      }
    }

    return HarnessCapabilityReport(
      driver: driver, project: project, skills: skills.sorted, commands: commands.sorted, mcpServers: servers.sorted,
      verified: s.verified)
  }

  /// A plain-text report for the `--probe-capabilities` checks: a count line, then one line per
  /// item with its scope, whether it is off, and the start of its description.
  public static func describe(_ r: HarnessCapabilityReport, perKind: Int = 400) -> [String] {
    func count(_ items: [HarnessCapability]) -> String {
      let project = items.filter { $0.scope == .project }.count
      let off = items.filter { !$0.enabled }.count
      var notes: [String] = []
      if project > 0 { notes.append("\(project) project") }
      if off > 0 { notes.append("\(off) off") }
      return notes.isEmpty ? "\(items.count)" : "\(items.count) (\(notes.joined(separator: ", ")))"
    }
    var lines = [
      "\(r.driver.displayName): skills=\(count(r.skills)) commands=\(count(r.commands)) mcp=\(count(r.mcpServers))"
        + (r.verified ? "" : " [from docs, unverified]")
    ]
    for (kind, items) in [("skill", r.skills), ("command", r.commands), ("mcp", r.mcpServers)] {
      for item in items.prefix(perKind) {
        let tags = (item.scope == .project ? " [project]" : "") + (item.enabled ? "" : " [off]")
        lines.append("    \(kind): \(item.name)\(tags)" + (item.detail.map { " — \(String($0.prefix(70)))" } ?? ""))
      }
    }
    return lines
  }

  /// Collects one kind: first of a name wins within a scope, bounded, sorted user-first then by name.
  struct Entries {
    private(set) var items: [HarnessCapability] = []
    private var seen: Set<String> = []
    mutating func add(_ c: HarnessCapability, _ scope: CapabilityScope) {
      guard items.count < maxPerKind, !c.name.isEmpty else { return }
      var c = c
      c.scope = scope
      guard seen.insert(scope.rawValue + "\u{0}" + c.name).inserted else { return }
      items.append(c)
    }
    func contains(_ name: String, _ scope: CapabilityScope) -> Bool { seen.contains(scope.rawValue + "\u{0}" + name) }
    mutating func update(_ name: String, _ scope: CapabilityScope, _ change: (inout HarnessCapability) -> Void) {
      for i in items.indices where items[i].name == name && items[i].scope == scope { change(&items[i]) }
    }
    mutating func updateAll(_ change: (inout HarnessCapability) -> Void) {
      for i in items.indices { change(&items[i]) }
    }
    var sorted: [HarnessCapability] {
      items.sorted { ($0.scope == .project ? 1 : 0, $0.name) < ($1.scope == .project ? 1 : 0, $1.name) }
    }
  }

  // MARK: Claude Code

  /// What `~/.claude.json` records for a project: its local-scope servers, the servers switched off
  /// there, and the user's answers about the project's `.mcp.json` servers.
  struct ClaudeProjectState: Equatable {
    var local: [String] = []
    var disabled: Set<String> = []
    var approved: Set<String> = []
    var declined: Set<String> = []
  }
  static func claudeProjectState(_ text: String, folders: [String]) -> ClaudeProjectState {
    guard !folders.isEmpty, let projects = jsonObject(text)["projects"] as? [String: Any] else { return ClaudeProjectState() }
    let wanted = Set(folders.map(standardPath))
    var state = ClaudeProjectState()
    var local: Set<String> = []
    for (key, value) in projects where wanted.contains(standardPath(key)) {
      guard let entry = value as? [String: Any] else { continue }
      if let servers = entry["mcpServers"] as? [String: Any] { local.formUnion(servers.keys) }
      state.disabled.formUnion(entry["disabledMcpServers"] as? [String] ?? [])
      state.approved.formUnion(entry["enabledMcpjsonServers"] as? [String] ?? [])
      state.declined.formUnion(entry["disabledMcpjsonServers"] as? [String] ?? [])
    }
    state.local = local.sorted()
    return state
  }

  struct Plugin: Equatable {
    var name: String
    var folder: URL
    var scope: CapabilityScope
    var enabled: Bool
  }

  /// Plugins Claude Code would load: installed (`plugins/installed_plugins.json`) and turned on in
  /// `enabledPlugins` — user settings, then the project's own settings, which override them. A
  /// plugin installed for another project is left out.
  static func claudePlugins(home: URL, project: URL?, fm: FileManager) -> [Plugin] {
    guard let installed = settings(home.appendingPathComponent("plugins/installed_plugins.json"), fm: fm)["plugins"] as? [String: Any]
    else { return [] }
    let userEnabled = settings(home.appendingPathComponent("settings.json"), fm: fm)["enabledPlugins"] as? [String: Any] ?? [:]
    var projectEnabled: [String: Any] = [:]
    if let project {
      for file in [".claude/settings.json", ".claude/settings.local.json"] {
        let values = settings(project.appendingPathComponent(file), fm: fm)["enabledPlugins"] as? [String: Any] ?? [:]
        projectEnabled.merge(values) { _, new in new }
      }
    }
    var out: [Plugin] = []
    for key in installed.keys.sorted().prefix(maxPlugins) {
      let byProject = projectEnabled[key] as? Bool
      let byUser = userEnabled[key] as? Bool
      guard (byProject ?? byUser) == true else { continue }
      let raw = installed[key]
      let entries = (raw as? [[String: Any]]) ?? [raw as? [String: Any]].compactMap { $0 }
      for entry in entries {
        guard let path = entry["installPath"] as? String, isDirectory(URL(fileURLWithPath: path), fm) else { continue }
        let scope: CapabilityScope
        if (entry["scope"] as? String ?? "user") == "user" {
          scope = byProject == true && byUser != true ? .project : .user
        } else if let projectPath = entry["projectPath"] as? String, let project, standardPath(projectPath) == project.path {
          scope = .project
        } else {
          continue
        }
        if project == nil && scope == .project { continue }
        let name = String(key.split(separator: "@").first ?? Substring(key))
        out.append(Plugin(name: name, folder: URL(fileURLWithPath: path, isDirectory: true), scope: scope, enabled: true))
        break
      }
    }
    return out
  }

  /// Claude Code's `enableAllProjectMcpServers`, in user or project settings.
  static func claudeApprovesAll(_ s: CapabilitySources, folder: URL?, fm: FileManager) -> Bool {
    var files: [URL] = []
    if let home = s.claudeHome { files.append(URL(fileURLWithPath: home).appendingPathComponent("settings.json")) }
    if let folder {
      files += [".claude/settings.json", ".claude/settings.local.json"].map { folder.appendingPathComponent($0) }
    }
    return files.contains { settings($0, fm: fm)["enableAllProjectMcpServers"] as? Bool == true }
  }

  // MARK: Codex

  /// Codex plugins installed in `plugins/cache/<marketplace>/<plugin>/<version>`, each on when
  /// `config.toml` turns `[plugins."<plugin>@<marketplace>"]` on. The newest version folder is used.
  static func codexPlugins(home: URL, fm: FileManager) -> [Plugin] {
    let config = (try? text(home.appendingPathComponent("config.toml"), fm: fm, limit: maxConfigBytes)) ?? ""
    let states = tomlPluginStates(config)
    var out: [Plugin] = []
    for market in subfolders(home.appendingPathComponent("plugins/cache"), fm: fm).prefix(maxPlugins) {
      for plugin in subfolders(market, fm: fm).prefix(maxPlugins) {
        let versions = subfolders(plugin, fm: fm).filter {
          isRegularFile($0.appendingPathComponent(".codex-plugin/plugin.json"), fm)
        }
        guard let folder = versions.max(by: { modified($0, fm) < modified($1, fm) }) else { continue }
        let manifest = settings(folder.appendingPathComponent(".codex-plugin/plugin.json"), fm: fm)
        let name = (manifest["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? plugin.lastPathComponent
        let key = plugin.lastPathComponent + "@" + market.lastPathComponent
        out.append(Plugin(name: name, folder: folder, scope: .user, enabled: states[key] ?? false))
      }
    }
    return out
  }

  /// A plugin's MCP servers: the manifest's `mcpServers` (an object, or a path to a JSON file
  /// inside the plugin), else the plugin's `.mcp.json`.
  static func pluginServers(_ folder: URL, manifest: String, fm: FileManager) -> [(name: String, enabled: Bool)] {
    let declared = settings(folder.appendingPathComponent(manifest), fm: fm)["mcpServers"]
    if let object = declared as? [String: Any] { return serverStates(object) }
    var file = folder.appendingPathComponent(".mcp.json")
    if let path = declared as? String {
      guard let inside = inside(folder, path) else { return [] }
      file = inside
    }
    guard let config = try? text(file, fm: fm, limit: maxConfigBytes) else { return [] }
    return jsonServerStates(config, key: "mcpServers", topLevel: true)
  }

  // MARK: Pi

  /// Pi's saved trust decision for a project (`<agent-dir>/trust.json`: canonical folder → true,
  /// false or null), the closest folder's decision winning; then `defaultProjectTrust` ("always"
  /// trusts). nil means Pi would ask. The home folder's own decision is not a project decision.
  static func piTrust(agentDir: URL, project: URL, home: String, fm: FileManager) -> Bool? {
    let store = settings(agentDir.appendingPathComponent("trust.json"), fm: fm)
    let homePath = realPath(home)
    var current = realPath(project.path)
    for _ in 0..<64 {
      if current != homePath, let decision = store[current] as? Bool { return decision }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current || parent.isEmpty { break }
      current = parent
    }
    switch settings(agentDir.appendingPathComponent("settings.json"), fm: fm)["defaultProjectTrust"] as? String {
    case "always": return true
    case "never": return false
    default: return nil
    }
  }

  /// `-builtin:mcp` in Pi's `extensions` setting; a trusted project's own setting overrides the user's.
  static func piMCPOff(agentDir: URL, project: URL?, fm: FileManager) -> Bool {
    func state(_ url: URL) -> Bool? {
      let entries = settings(url, fm: fm)["extensions"] as? [String] ?? []
      if entries.contains("-builtin:mcp") { return true }
      if entries.contains("+builtin:mcp") { return false }
      return nil
    }
    if let project, let value = state(project.appendingPathComponent(".pi/settings.json")) { return value }
    return state(agentDir.appendingPathComponent("settings.json")) ?? false
  }

  /// The skill and prompt folders of the Pi packages a settings file declares (`packages`): npm
  /// packages in `<root>/npm/node_modules/<name>`, git ones in `<root>/git/<host>/<path>`, local
  /// paths relative to the settings file. A package's `pi` manifest names its `skills` and
  /// `prompts`; without one, its `skills/` and `prompts/` folders are used.
  static func piPackages(settings file: URL, installRoot: URL, home: String, fm: FileManager) -> [(skills: [URL], prompts: [URL])] {
    let declared = settings(file, fm: fm)["packages"] as? [Any] ?? []
    var out: [(skills: [URL], prompts: [URL])] = []
    for raw in declared.prefix(maxPlugins) {
      guard let source = (raw as? String) ?? (raw as? [String: Any])?["source"] as? String,
        let folder = piPackageFolder(source, installRoot: installRoot, base: file.deletingLastPathComponent(), home: home),
        isDirectory(folder, fm)
      else { continue }
      let manifest = settings(folder.appendingPathComponent("package.json"), fm: fm)["pi"] as? [String: Any]
      func resources(_ key: String) -> [URL] {
        guard let manifest else { return [folder.appendingPathComponent(key)] }
        return (manifest[key] as? [String] ?? []).compactMap { entry in
          // A glob names files in the folder before its first wildcard.
          let path = entry.split(separator: "/").prefix { !$0.contains("*") }.joined(separator: "/")
          return inside(folder, path.isEmpty ? "." : path)
        }
      }
      out.append((resources("skills"), resources("prompts")))
    }
    return out
  }
  static func piPackageFolder(_ source: String, installRoot: URL, base: URL, home: String) -> URL? {
    if source.hasPrefix("npm:") {
      // `npm:@scope/name@1.0` → `@scope/name`: a version follows the last `@` after the first character.
      var spec = String(source.dropFirst(4))
      if let at = spec.lastIndex(of: "@"), at != spec.startIndex { spec = String(spec[..<at]) }
      guard !spec.isEmpty, !spec.split(separator: "/").contains("..") else { return nil }
      return installRoot.appendingPathComponent("npm/node_modules/" + spec)
    }
    let gitPrefixes = ["git:", "https://", "http://", "ssh://", "git@"]
    if let prefix = gitPrefixes.first(where: source.hasPrefix) {
      // `<host>/<path>[@ref]`; `git@host:path` becomes `host/path`. A ref follows the last `@`.
      var spec = String(source.dropFirst(prefix.count)).replacingOccurrences(of: ":", with: "/")
      if let at = spec.lastIndex(of: "@") { spec = String(spec[..<at]) }
      if spec.hasSuffix(".git") { spec.removeLast(4) }
      guard !spec.isEmpty, !spec.split(separator: "/").contains("..") else { return nil }
      return installRoot.appendingPathComponent("git/" + spec)
    }
    if source.hasPrefix("~/") { return URL(fileURLWithPath: home).appendingPathComponent(String(source.dropFirst(2))) }
    if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
    return base.appendingPathComponent(source).standardizedFileURL
  }

  // MARK: Oh My Pi

  /// The Oh My Pi settings that decide what it loads: user `config.yml` (or `config.yaml`, or the
  /// legacy `settings.json`), then the project's `.omp/settings.json` and `.omp/config.yml`, whose
  /// arrays replace the user's; and the user `mcp.json`'s server allow and deny lists.
  struct OMPConfig {
    var enabledProviders: Set<String> = []
    var disabledProviders: Set<String> = []
    var disabledSkills: Set<String> = []
    var disabledServers: Set<String> = []
    var enabledServers: Set<String> = []
    init(agentDir: URL, project: URL?, fm: FileManager) {
      func yaml(_ url: URL) -> String? { try? text(url, fm: fm, limit: maxConfigBytes) }
      let userYAML = yaml(agentDir.appendingPathComponent("config.yml")) ?? yaml(agentDir.appendingPathComponent("config.yaml"))
      let userJSON = userYAML == nil ? settings(agentDir.appendingPathComponent("settings.json"), fm: fm) : [:]
      let projectYAML = project.flatMap { yaml($0.appendingPathComponent(".omp/config.yml")) }
      let projectJSON = project.map { settings($0.appendingPathComponent(".omp/settings.json"), fm: fm) } ?? [:]
      func list(_ key: String) -> [String] {
        projectYAML.flatMap { HarnessCatalog.yamlList($0, key: key) } ?? projectJSON[key] as? [String]
          ?? userYAML.flatMap { HarnessCatalog.yamlList($0, key: key) } ?? userJSON[key] as? [String] ?? []
      }
      enabledProviders = Set(list("enabledProviders"))
      disabledProviders = Set(list("disabledProviders"))
      disabledSkills = Set(list("disabledExtensions").compactMap { $0.hasPrefix("skill:") ? String($0.dropFirst(6)) : nil })
      let mcp = settings(agentDir.appendingPathComponent("mcp.json"), fm: fm)
      disabledServers = Set(mcp["disabledServers"] as? [String] ?? [])
      enabledServers = Set(mcp["enabledServers"] as? [String] ?? [])
    }
  }

  /// Package folders in a `node_modules` folder, scoped (`@scope/name`) ones included.
  static func packageFolders(_ dir: URL, fm: FileManager) -> [URL] {
    subfolders(dir, fm: fm).prefix(maxPlugins).flatMap { folder -> [URL] in
      folder.lastPathComponent.hasPrefix("@") ? Array(subfolders(folder, fm: fm).prefix(maxPlugins)) : [folder]
    }
  }

  // MARK: Front matter

  /// Scalars and `>`/`|` block values from `--- … ---` front matter. Unknown keys and indented
  /// (map) entries are kept out; nothing is evaluated.
  static func frontMatter(_ text: String) -> [String: String] {
    var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
    else { return [:] }
    var fields: [String: String] = [:]
    var i = 1
    while i < end {
      let line = lines[i]
      guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
        let colon = line.firstIndex(of: ":")
      else { i += 1; continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if value.first == ">" || value.first == "|" {
        // A block scalar: gather the more-indented lines that follow and fold them to one line.
        var block: [String] = []
        var j = i + 1
        while j < end {
          let next = lines[j]
          let trimmed = next.trimmingCharacters(in: .whitespaces)
          if !trimmed.isEmpty, next.first != " ", next.first != "\t" { break }
          block.append(trimmed)
          j += 1
        }
        value = block.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        i = j
      } else {
        if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
          value = String(value.dropFirst().dropLast())
        }
        i += 1
      }
      if fields[key] == nil, !key.isEmpty { fields[key] = collapseSpaces(value) }
    }
    return fields
  }

  static func stripFrontMatter(_ text: String) -> String {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
    else { return text }
    return lines[(end + 1)...].joined(separator: "\n")
  }

  /// The first line of prose: not blank, not a heading, list bullet, HTML comment or front-matter fence.
  static func firstProseLine(_ body: String) -> String? {
    for raw in body.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("<!--") || line.hasPrefix("---")
        || line.hasPrefix(">") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("```")
      { continue }
      return collapseSpaces(line)
    }
    return nil
  }

  // MARK: Config parsers

  static func jsonObject(_ text: String) -> [String: Any] {
    guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
  }

  /// Servers in a JSON object property (`mcpServers`, `mcp`), or with `topLevel` the file's own
  /// entries when it has no such property (a plugin's `.mcp.json` may be a bare map).
  static func jsonServerStates(_ text: String, key: String, topLevel: Bool) -> [(name: String, enabled: Bool)] {
    let json = jsonObject(text)
    if let object = json[key] as? [String: Any] { return serverStates(object) }
    return topLevel ? serverStates(json.filter { $0.value is [String: Any] }) : []
  }
  static func serverStates(_ object: [String: Any]) -> [(name: String, enabled: Bool)] {
    object.keys.sorted().map { name in
      let entry = object[name] as? [String: Any] ?? [:]
      return (name, entry["disabled"] as? Bool != true && entry["enabled"] as? Bool != false)
    }
  }

  /// One TOML table per header, with its `key = value` scalars (raw text, comments cut). Enough
  /// for headers and booleans; nothing is evaluated.
  static func tomlTables(_ text: String) -> [(path: [String], values: [String: String])] {
    var tables: [(path: [String], values: [String: String])] = []
    for raw in text.components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        let inner = line.dropFirst(line.hasPrefix("[[") ? 2 : 1)
        tables.append((tomlKeyPath(inner.prefix { $0 != "]" }), [:]))
      } else if !tables.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") {
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        let scalar = value.first == "\"" ? value : value.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
        tables[tables.count - 1].values[key] = scalar
      }
    }
    return tables
  }
  /// `mcp_servers."with.dot".env` → ["mcp_servers", "with.dot", "env"].
  static func tomlKeyPath(_ head: Substring) -> [String] {
    var parts: [String] = []
    var current = ""
    var quoted = false
    for ch in head {
      if ch == "\"" { quoted.toggle(); continue }
      if ch == ".", !quoted {
        parts.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(ch)
      }
    }
    parts.append(current.trimmingCharacters(in: .whitespaces))
    return parts.filter { !$0.isEmpty }
  }

  /// `[mcp_servers.<name>]` servers, in order, each off when its table says `enabled = false`.
  /// Sub-tables (`[mcp_servers.<name>.env]`) only name the server.
  static func tomlServerStates(_ text: String) -> [(name: String, enabled: Bool)] {
    var order: [String] = []
    var enabled: [String: Bool] = [:]
    for table in tomlTables(text) where table.path.count >= 2 && table.path[0] == "mcp_servers" {
      let name = table.path[1]
      if enabled[name] == nil {
        order.append(name)
        enabled[name] = true
      }
      if table.path.count == 2, table.values["enabled"] == "false" { enabled[name] = false }
    }
    return order.sorted().map { ($0, enabled[$0] ?? true) }
  }

  /// `[plugins."<plugin>@<marketplace>"]` tables: on unless `enabled = false`.
  static func tomlPluginStates(_ text: String) -> [String: Bool] {
    var states: [String: Bool] = [:]
    for table in tomlTables(text) where table.path.count == 2 && table.path[0] == "plugins" {
      states[table.path[1]] = table.values["enabled"] != "false"
    }
    return states
  }

  /// A top-level YAML list of plain strings — `key: [a, b]` or `key:` followed by `- a` lines —
  /// or nil when the key is absent. Map entries (path-scoped rules) are left out.
  public static func yamlList(_ text: String, key: String) -> [String]? {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return nil }
    let rest = uncommented(lines[start].dropFirst(key.count + 1))
    if rest.hasPrefix("[") {
      return rest.dropFirst().prefix { $0 != "]" }.split(separator: ",")
        .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }
    if !rest.isEmpty { return [unquoted(rest)] }
    var items: [String] = []
    for line in lines[(start + 1)...] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      if line.first != " " && line.first != "\t" && line.first != "-" { break }
      guard trimmed.hasPrefix("- ") else { continue }
      let item = uncommented(trimmed.dropFirst(2))
      // A map entry has `key: value` or a bare `key:`; `skill:name` is a plain string.
      let isMap = item.contains(": ") || item.hasSuffix(":")
      if item.first == "\"" || item.first == "'" || !isMap { items.append(unquoted(item)) }
    }
    return items
  }
  static func uncommented(_ s: Substring) -> String {
    String(s.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
  }
  static func unquoted(_ s: String) -> String {
    if s.count >= 2, let q = s.first, q == "\"" || q == "'", s.last == q { return String(s.dropFirst().dropLast()) }
    return s
  }

  /// Strips `//` line comments so a JSONC config parses as JSON; a config that still fails simply
  /// yields no names.
  static func stripLineComments(_ text: String) -> String {
    text.components(separatedBy: "\n").map { line -> String in
      line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : line
    }.joined(separator: "\n")
  }

  // MARK: File helpers

  /// A regular file's text, at most `limit` bytes; links resolve to their destination.
  static func text(_ url: URL, fm: FileManager, limit: Int = maxReadBytes) throws -> String {
    let real = url.resolvingSymlinksInPath()
    guard let attributes = try? fm.attributesOfItem(atPath: real.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { throw SereinError.invalid("not a file") }
    if let size = (attributes[.size] as? NSNumber)?.intValue, size > limit { throw SereinError.invalid("too large") }
    let data = try Data(contentsOf: real)
    guard data.count <= limit, let string = String(data: data, encoding: .utf8) else {
      throw SereinError.invalid("not text")
    }
    return string
  }

  static func settings(_ url: URL, fm: FileManager) -> [String: Any] {
    jsonObject((try? text(url, fm: fm, limit: maxConfigBytes)) ?? "")
  }

  /// Skill folders (ones holding `SKILL.md`) under `dir`, up to `depth` levels down. A folder with
  /// `SKILL.md` is a skill and is not searched further; hidden folders are skipped; each real
  /// folder is opened once, so a link cycle ends.
  static func skillFolders(_ dir: URL, depth: Int, fm: FileManager) -> [(name: String, markdown: String)] {
    var out: [(name: String, markdown: String)] = []
    var visited: Set<String> = []
    func walk(_ url: URL, _ level: Int) {
      guard out.count < maxPerKind, visited.count < maxScannedFolders else { return }
      let real = url.resolvingSymlinksInPath().standardizedFileURL.path
      guard visited.insert(real).inserted, let names = try? fm.contentsOfDirectory(atPath: real) else { return }
      for name in names.sorted() where !name.hasPrefix(".") {
        let child = url.appendingPathComponent(name)
        guard isDirectory(child, fm) else { continue }
        let file = child.appendingPathComponent("SKILL.md")
        if isRegularFile(file, fm) {
          out.append((name, (try? text(file, fm: fm)) ?? ""))
          if out.count >= maxPerKind { return }
        } else if level < depth {
          walk(child, level + 1)
        }
      }
    }
    walk(dir, 1)
    return out
  }

  /// `*.md` files in `dir` and, with `depth` above 1, its subfolders (hidden ones skipped, each
  /// real folder once), sorted by path and capped. Links resolve to regular files.
  static func markdownFiles(_ dir: URL, depth: Int = 1, fm: FileManager) -> [URL] {
    var out: [URL] = []
    var visited: Set<String> = []
    func walk(_ url: URL, _ level: Int) {
      guard out.count < maxPerKind, visited.count < maxScannedFolders else { return }
      let real = url.resolvingSymlinksInPath().standardizedFileURL.path
      guard visited.insert(real).inserted, let names = try? fm.contentsOfDirectory(atPath: real) else { return }
      for name in names.sorted() where !name.hasPrefix(".") {
        let child = url.appendingPathComponent(name)
        if name.lowercased().hasSuffix(".md"), isRegularFile(child, fm) {
          out.append(child)
          if out.count >= maxPerKind { return }
        } else if level < depth, isDirectory(child, fm) {
          walk(child, level + 1)
        }
      }
    }
    walk(dir, 1)
    return out
  }

  /// Visible subfolders of `dir` (links followed), sorted by name.
  static func subfolders(_ dir: URL, fm: FileManager) -> [URL] {
    guard let names = try? fm.contentsOfDirectory(atPath: dir.resolvingSymlinksInPath().path) else { return [] }
    return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0) }
      .filter { isDirectory($0, fm) }
  }

  /// `relative` inside `folder`, or nil when it would leave it.
  static func inside(_ folder: URL, _ relative: String) -> URL? {
    let candidate = folder.appendingPathComponent(relative).standardizedFileURL
    let base = folder.standardizedFileURL.path
    return candidate.path == base || candidate.path.hasPrefix(base + "/") ? candidate : nil
  }

  static func isDirectory(_ url: URL, _ fm: FileManager) -> Bool {
    var isDir: ObjCBool = false
    return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }
  static func isRegularFile(_ url: URL, _ fm: FileManager) -> Bool {
    (try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.type] as? FileAttributeType == .typeRegular
  }
  static func modified(_ url: URL, _ fm: FileManager) -> Date {
    (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
  }
  static func standardPath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
  /// The canonical path the way Node's `realpath` gives it (`/private/tmp`, not `/tmp`), which
  /// Pi's trust store uses. Foundation's own resolution drops the
  /// `/private` prefix, so this asks the system directly.
  static func realPath(_ path: String) -> String {
    #if canImport(Darwin)
      if let resolved = Darwin.realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
      }
    #endif
    return standardPath(path)
  }

  static func clip(_ s: String, _ max: Int) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count <= max ? trimmed : String(trimmed.prefix(max - 1)) + "…"
  }
  static func collapseSpaces(_ s: String) -> String {
    s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
  }
}
