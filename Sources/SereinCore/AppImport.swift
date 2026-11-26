import Foundation

/// Marketplace › Plugins › Import from your AI apps: the MCP servers and skills the person set up in
/// their other AI apps, read from those apps' own setup files, only for the apps the person ticked
/// and only when they ask (`read`). Nothing here runs or writes anything. Everything read is
/// untrusted text: names are cleaned and cut, and a server that cannot come in says why.
/// Environment values and header tokens are secrets: they stay in `Secrets`, which never prints,
/// and the app moves them to the Keychain; a manifest only names them.
public enum AppImport {
  public static let maxServers = 100
  public static let maxSkills = 200
  /// Codex's TOML is read whole into memory: a setup file well past this is not one.
  static let maxTOMLBytes = 1_048_576

  /// The AI apps Serein reads, each by the files it documents for its MCP servers and skills.
  public enum Source: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, claudeDesktop, codex, cursor, gemini
    public var id: String { rawValue }
    public var name: String {
      switch self {
      case .claudeCode: return HarnessDriver.claude.displayName
      case .claudeDesktop: return "Claude Desktop"
      case .codex: return HarnessDriver.codex.displayName
      case .cursor: return "Cursor"
      case .gemini: return HarnessDriver.gemini.displayName
      }
    }
    /// The one file that names its MCP servers (JSON `mcpServers`, or Codex's TOML tables).
    public func configFile(home: String, environment: [String: String]) -> String {
      switch self {
      case .claudeCode:
        // Its user-scope servers sit at the top of `.claude.json`; a project's own stay out.
        return HarnessDriver.claude.capabilitySources(home: home, environment: environment).claudeIndex
          ?? home + "/.claude.json"
      case .claudeDesktop: return home + "/Library/Application Support/Claude/claude_desktop_config.json"
      case .codex:
        return HarnessDriver.codex.capabilitySources(home: home, environment: environment).mcp.first?.path
          ?? home + "/.codex/config.toml"
      case .cursor:
        return HarnessDriver.cursor.capabilitySources(home: home, environment: environment).mcp.first?.path
          ?? home + "/.cursor/mcp.json"
      case .gemini:
        // This file only: Gemini CLI keeps its sign-in in the same folder, which is never listed.
        return home + "/.gemini/settings.json"
      }
    }
    /// Its skill folders (`<name>/SKILL.md`); none for an app that keeps no skills on disk.
    public func skillRoots(home: String, environment: [String: String]) -> [SkillRoot] {
      switch self {
      case .claudeCode: return HarnessDriver.claude.capabilitySources(home: home, environment: environment).skills
      case .codex:
        // Not the skills Codex ships itself (`skills/.system`).
        return HarnessDriver.codex.capabilitySources(home: home, environment: environment).skills
          .filter { !URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix(".") }
      case .claudeDesktop, .cursor, .gemini: return []
      }
    }
    /// Every path `read` opens for this app, as the tick list shows them.
    public func places(home: String, environment: [String: String]) -> [String] {
      [configFile(home: home, environment: environment)] + skillRoots(home: home, environment: environment).map(\.path)
    }
  }

  /// What only the Keychain may keep from a server's setup: environment values by name, and the
  /// bearer token of its Authorization header. It never prints or mirrors its values.
  public struct Secrets: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let env: [String: String]
    public let token: String?
    public var description: String { "secrets kept out of view" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
  }

  /// One MCP server found in an app's setup.
  public struct Server: Identifiable, Equatable, Sendable {
    public var id: String { source.rawValue + ":" + name }
    public let source: Source
    /// Its name in that app, cleaned and cut to 60 characters.
    public let name: String
    /// A local server: the program and its arguments, as that app starts it.
    public let command: String?
    public let args: [String]
    /// A remote server: its https address (`MCPServerConnection.address`).
    public let address: URL?
    /// The address as the app wrote it, also when Serein cannot use it, for the list.
    public let rawAddress: String?
    /// The environment names the program gets, each value kept in the Keychain.
    public let envNames: [String]
    public let secrets: Secrets
    /// Its Authorization token comes from that app's shell, so the person pastes it.
    public let needsToken: Bool
    /// Why it cannot come in, in plain words; nil when it can.
    public let problem: String?

    /// Environment names whose value that app takes from its shell: the person types them.
    public var missing: [String] { envNames.filter { secrets.env[$0] == nil } }
    /// What the list shows: the address, or the program and its arguments, with anything that
    /// looks like a key redacted.
    public var shown: String {
      if let address { return AgentPrivacy.url(address.absoluteString) }
      if let rawAddress { return AgentPrivacy.url(rawAddress) }
      var parts: [String] = [command ?? ""]
      for (index, arg) in args.enumerated() {
        // The value after a bare secret flag (`--token abc`) is a key whatever it looks like.
        let afterFlag: Bool = index > 0 && AppImport.flagWithoutValue(args[index - 1])
        parts.append(afterFlag ? AgentPrivacy.replacement : AgentPrivacy.redact(arg))
      }
      return parts.joined(separator: " ")
    }
    /// The network it may reach once it is in; empty for a server that names nothing to run.
    public var network: String {
      let rawHost: String? = rawAddress.flatMap { URL(string: $0)?.host }
      if let host = address?.host ?? rawHost { return "Reaches \(host)" }
      if command == nil { return "" }
      return "No internet access. Serein runs it in its sandbox, away from your files."
    }
  }

  /// One skill found in an app's skill folders, as Save as Skill would save it.
  public struct Skill: Identifiable, Equatable, Sendable {
    public var id: String { source.rawValue + ":" + name }
    public let source: Source
    /// Its name in that app, cleaned.
    public let name: String
    public let description: String
    /// What Save as Skill saves: the name as a skill name, when to use it, and its instructions.
    public let draft: TaskSkillDraft
    /// Why it cannot come in (the store's name and size rules); nil when it can.
    public let problem: String?
  }

  public struct Found: Equatable, Sendable {
    public var servers: [Server] = []
    public var skills: [Skill] = []
    /// One line per ticked app that offered nothing, or whose file could not be read.
    public var notes: [String] = []
  }

  // MARK: Reading

  /// Reads the ticked apps' files: each app's server file and skill folders, bounded, regular
  /// files only (`HarnessCatalog.text`). The caller runs this from the person's action.
  public static func read(
    _ sources: Set<Source>, home: String = NSHomeDirectory(),
    environment: [String: String] = ProcessInfo.processInfo.environment, fileManager fm: FileManager = .default
  ) -> Found {
    var found = Found()
    for source in Source.allCases where sources.contains(source) {
      let path = source.configFile(home: home, environment: environment)
      var servers: [Server] = []
      // Why a file that is there gave nothing: never reported as having nothing to import.
      var unreadable: String?
      if fm.fileExists(atPath: path) {
        let url = URL(fileURLWithPath: path)
        let limit: Int = source == .codex ? maxTOMLBytes : HarnessCatalog.maxConfigBytes
        let attributes: [FileAttributeKey: Any]? = try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        let size: Int = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size > limit {
          unreadable = "it is over \(limit / 1_048_576) MB"
        } else if let text = try? HarnessCatalog.text(url, fm: fm, limit: limit) {
          let parsed: [Server]?
          if source == .codex { parsed = tomlServers(text, home: home) } else { parsed = jsonServers(text, source: source, home: home) }
          if let parsed {
            servers = parsed
          } else if source == .codex {
            unreadable = "Serein's reader could not read all of it, so nothing was taken from it"
          } else {
            unreadable = "it is not valid JSON"
          }
        } else {
          unreadable = "it is not a text file Serein can read"
        }
      }
      var skills: [Skill] = []
      var seen = Set<String>()
      for root in source.skillRoots(home: home, environment: environment) {
        for folder in HarnessCatalog.skillFolders(URL(fileURLWithPath: root.path), depth: root.depth, fm: fm)
        where skills.count < maxSkills {
          let item = Self.skill(source, folder: folder.name, markdown: folder.markdown)
          if seen.insert(item.name).inserted { skills.append(item) }
        }
      }
      if let unreadable {
        found.notes.append("Could not read \(shown(path, home: home)): \(unreadable).")
      } else if servers.isEmpty && skills.isEmpty {
        found.notes.append("Nothing to import from \(source.name) (read \(shown(path, home: home))).")
      }
      found.servers += servers
      found.skills += skills
    }
    return found
  }

  /// A path with the home folder as `~`.
  public static func shown(_ path: String, home: String) -> String {
    path == home || path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
  }

  // MARK: Servers

  /// One server's setup, the same for every format.
  struct Entry {
    var command: Any?
    var args: Any?
    var env: [String: Any] = [:]
    /// Environment names the app passes through from its own shell (Codex `env_vars`).
    var shellEnv: [String] = []
    var url: Any?
    /// The address speaks the older SSE transport (`type: "sse"`, Gemini CLI's `url`).
    var sse = false
    var headers: [String: Any] = [:]
    /// Header names whose value comes from the app's shell (Codex `env_http_headers`,
    /// `bearer_token_env_var`).
    var shellHeaders: [String] = []
  }

  /// `mcpServers` in a JSON setup file (Claude Code, Claude Desktop, Cursor, Gemini CLI); nil
  /// when the text is not a JSON object.
  public static func jsonServers(_ text: String, source: Source, home: String) -> [Server]? {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
    let object: Any? = try? JSONSerialization.jsonObject(with: Data(text.utf8))
    guard let root = object as? [String: Any] else { return nil }
    let servers = root["mcpServers"] as? [String: Any] ?? [:]
    let found: [Server] = servers.keys.sorted().prefix(maxServers).map { key -> Server in
      let o = servers[key] as? [String: Any] ?? [:]
      var e = Entry(command: o["command"], args: o["args"], env: o["env"] as? [String: Any] ?? [:])
      if source == .gemini {
        // Gemini CLI: `httpUrl` is Streamable HTTP, `url` the older SSE.
        e.url = o["httpUrl"] ?? o["url"]
        e.sse = o["httpUrl"] == nil && o["url"] != nil
      } else {
        e.url = o["url"]
        e.sse = (o["type"] as? String)?.lowercased() == "sse"
      }
      e.headers = o["headers"] as? [String: Any] ?? [:]
      return server(source, key, e, home: home)
    }
    return unique(found)
  }

  /// One row per name: two keys that clean to the same name would share one checkbox, so the
  /// later one is left out.
  static func unique(_ servers: [Server]) -> [Server] {
    var seen = Set<String>()
    return servers.filter { seen.insert($0.name).inserted }
  }

  /// `[mcp_servers.<name>]` tables in Codex's `config.toml`; nil when any of the file is not
  /// TOML this reader takes, so nothing is taken from a file read in part.
  public static func tomlServers(_ text: String, home: String) -> [Server]? {
    guard let root = TOMLLite.parse(text) else { return nil }
    guard case .table(let servers)? = root["mcp_servers"] else { return [] }
    let found: [Server] = servers.keys.sorted().prefix(maxServers).compactMap { key -> Server? in
      guard case .table(let t)? = servers[key] else { return nil }
      var e = Entry(command: t["command"]?.plain, args: t["args"]?.plain, env: t["env"]?.plain as? [String: Any] ?? [:])
      e.shellEnv = (t["env_vars"]?.plain as? [Any] ?? []).compactMap { $0 as? String }
      e.url = t["url"]?.plain
      e.headers = t["http_headers"]?.plain as? [String: Any] ?? [:]
      e.shellHeaders = (t["env_http_headers"]?.plain as? [String: Any] ?? [:]).keys.sorted()
      if t["bearer_token_env_var"] != nil { e.shellHeaders.append("Authorization") }
      return server(.codex, key, e, home: home)
    }
    return unique(found)
  }

  static let envName = "^[A-Z][A-Z0-9_]{0,63}$"

  static func server(_ source: Source, _ rawName: String, _ e: Entry, home: String) -> Server {
    var problem: String?
    func refuse(_ reason: String) { if problem == nil { problem = reason } }
    var command: String?
    var args: [String] = []
    var address: URL?
    var rawAddress: String?
    var envNames: [String] = []
    var values: [String: String] = [:]
    var token: String?
    var needsToken = false
    if let raw = e.url {
      rawAddress = raw as? String
      if e.sse {
        refuse("It uses the older SSE connection, which Serein does not use.")
      } else if let text = raw as? String, let url = MCPServerConnection.address(text) {
        address = url
      } else {
        refuse("Serein connects only to https addresses on a named host, with no ?… part.")
      }
      for header in e.headers.keys.sorted() {
        guard header.lowercased() == "authorization" else {
          refuse("It sends a \(clean(header, 40)) header. Serein sends only a bearer token.")
          continue
        }
        guard let value = e.headers[header] as? String, let bearer = bearerToken(value) else {
          refuse("Its Authorization header is not a bearer token, the only kind Serein sends.")
          continue
        }
        if fromShell(bearer) { needsToken = true } else { token = bearer }
      }
      for header in e.shellHeaders {
        if header.lowercased() == "authorization" { needsToken = true } else {
          refuse("It sends a \(clean(header, 40)) header. Serein sends only a bearer token.")
        }
      }
    } else if let raw = e.command {
      let text = (raw as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        refuse("It names no program to start.")
      } else if text.contains("..") {
        refuse("Its program path leaves its folder.")
      } else if !text.hasPrefix("/"), text.contains("/") {
        refuse("Its program is a path inside \(source.name)'s own folder. Give it a full path there first.")
      } else if text.hasPrefix("/"), text == home || text.hasPrefix(home + "/") {
        refuse("Its program is in your home folder, which Serein's sandbox keeps closed.")
      }
      command = text.isEmpty ? nil : text
      if let list = e.args {
        let items = list as? [Any] ?? []
        args = items.compactMap { $0 as? String }
        if args.count != items.count || !(list is [Any]) { refuse("Its arguments are not all text.") }
      }
      // A key in the arguments would land in the manifest and in the process list: refused.
      if let index = secretArgument(args) {
        refuse("Its argument \(index + 1) carries a key or a value from \(source.name)'s shell. Serein keeps keys only in your Keychain: in \(source.name), pass it as an environment setting, then import again.")
      }
      for key in e.env.keys.sorted() {
        guard key.range(of: envName, options: .regularExpression) != nil else {
          refuse("Its setting \(clean(key, 40)) is not a name Serein can keep (like API_KEY).")
          continue
        }
        guard !reserved(key) else {
          refuse("Its setting \(key) is one Serein sets itself.")
          continue
        }
        let number: String? = (e.env[key] as? NSNumber)?.stringValue
        let value: String? = (e.env[key] as? String) ?? number
        // An empty value is left out: the program starts without that setting.
        if value == "" { continue }
        envNames.append(key)
        if let value, !fromShell(value) { values[key] = value }
      }
      for key in e.shellEnv where key.range(of: envName, options: .regularExpression) != nil && !envNames.contains(key) {
        guard !reserved(key) else {
          refuse("Its setting \(key) is one Serein sets itself.")
          continue
        }
        envNames.append(key)
      }
      if envNames.count > 32 { refuse("It asks for more than 32 settings.") }
    } else {
      refuse("It names neither a program nor an address.")
    }
    return Server(
      source: source, name: clean(rawName, 60), command: command, args: args, address: address, rawAddress: rawAddress,
      envNames: envNames,
      secrets: Secrets(env: values, token: token), needsToken: needsToken, problem: problem)
  }

  /// The token of `Bearer <token>`, or nil for any other kind of Authorization.
  static func bearerToken(_ value: String) -> String? {
    let text = value.trimmingCharacters(in: .whitespaces)
    guard text.lowercased().hasPrefix("bearer ") else { return nil }
    let token = text.dropFirst(7).trimmingCharacters(in: .whitespaces)
    return token.isEmpty ? nil : token
  }
  /// A value the app fills in from its shell (`${NAME}`, `$NAME`), not the value itself.
  static func fromShell(_ value: String) -> Bool { value.contains("${") || value.hasPrefix("$") }

  /// The environment names Serein sets for every program itself, which an import never sets.
  static let reservedEnv: Set<String> = ["PATH", "TMPDIR", "LANG", "SEREIN_PLUGIN_DATA", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"]
  static func reserved(_ name: String) -> Bool { reservedEnv.contains(name) || name.hasPrefix("DYLD_") }

  /// A command-line flag that names a key (`--api-key`, `-token`, `--auth-header`).
  static let secretFlag = #"(?i)^--?[a-z0-9_-]*(token|key|secret|password|passwd|auth|bearer|credential|cookie|session)[a-z0-9_-]*$"#
  /// A secret flag whose value is the next argument (`--token abc`).
  static func flagWithoutValue(_ arg: String) -> Bool {
    !arg.contains("=") && arg.range(of: secretFlag, options: .regularExpression) != nil
  }
  /// The index of the first argument that carries a key, or a value the app fills in from its shell.
  static func secretArgument(_ args: [String]) -> Int? {
    for (index, arg) in args.enumerated() {
      let looksSecret: Bool = AgentPrivacy.redact(arg) != arg
      let shell: Bool = fromShell(arg) || (arg.contains("$") && arg.contains("{"))
      if looksSecret || shell { return index }
      let flag = String(arg.split(separator: "=", maxSplits: 1).first ?? Substring(arg))
      let named: Bool = flag.range(of: secretFlag, options: .regularExpression) != nil
      if named && (arg.contains("=") || index + 1 < args.count) { return index }
    }
    return nil
  }

  /// The local plugin id for an imported program: `imported.` and its name, never one in `taken`.
  public static func pluginID(for server: Server, taken: Set<String>) -> String {
    var slug = server.name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    slug = String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let base = "imported." + (slug.isEmpty ? "server" : slug)
    var candidate = base
    var n = 2
    while taken.contains(candidate) {
      candidate = base + "-\(n)"
      n += 1
    }
    return candidate
  }

  /// The local manifest for an imported program's tools switched on, checked by
  /// `PluginManifest.decode` like any plugin's: the program and arguments as the app starts them,
  /// its environment by name only (the values are in the Keychain), no internet access and none
  /// of the person's files.
  public static func manifest(id: String, server: Server, tools: [MCPServerConnection.ReviewTool]) throws -> Data {
    guard server.problem == nil, let command = server.command else {
      throw SereinError.invalid(server.problem ?? "\(server.name) is not a program Serein can start.")
    }
    guard secretArgument(server.args) == nil else {
      throw SereinError.invalid("\(server.name)'s arguments carry a key. Serein keeps keys only in your Keychain.")
    }
    let on = tools.filter(\.on)
    guard !on.isEmpty else { throw SereinError.invalid("Turn on at least one tool, or skip it.") }
    guard on.count <= MCPServerConnection.maxTools else {
      throw SereinError.invalid(
        "At most \(MCPServerConnection.maxTools) tools can be on at once. Switch \(on.count - MCPServerConnection.maxTools) off.")
    }
    var mcp: [String: Any] = ["command": command]
    if !server.args.isEmpty { mcp["args"] = server.args }
    if !server.envNames.isEmpty { mcp["env"] = server.envNames }
    let object: [String: Any] = [
      "id": id, "name": String(server.name.prefix(60)), "version": "1.0.0",
      "description": String("Imported from \(server.source.name). Starts \(URL(fileURLWithPath: command).lastPathComponent).".prefix(300)),
      "mcp": mcp,
      "tools": on.map { tool -> [String: Any] in
        var entry: [String: Any] = ["name": tool.name, "risk": tool.risk.rawValue]
        if tool.serverName != tool.name { entry["remote"] = tool.serverName }
        return entry
      },
      "permissions": ["files": "none"],
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    _ = try PluginManifest.decode(data)
    return data
  }

  // MARK: Skills

  /// A skill as Save as Skill would take it: its front-matter name as a skill name, its
  /// description as when to use it, its body as the steps, checked by the store's own rules.
  static func skill(_ source: Source, folder: String, markdown: String) -> Skill {
    let fields = HarnessCatalog.frontMatter(markdown)
    let name = clean(fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder, 64)
    let description = clean(fields["description"] ?? "", SkillParser.maxDescription)
    let body = HarnessCatalog.stripFrontMatter(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
    let draft = TaskSkillDraft(name: skillName(name), whenToUse: description, steps: body)
    var problem: String?
    do { _ = try TaskSkill.file(draft) } catch { problem = error.localizedDescription }
    return Skill(source: source, name: name, description: description, draft: draft, problem: problem)
  }

  /// Lowercase words joined by hyphens, up to 64 characters.
  static func skillName(_ name: String) -> String {
    let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String(slug.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  /// Untrusted text for one line: no hidden or reordering characters, spaces collapsed, cut.
  static func clean(_ text: String, _ max: Int) -> String {
    let visible = PluginSchemas.visibleText(text)
      .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    return String(visible.prefix(max))
  }
}

/// Just enough TOML for MCP server tables: `[a.b]` headers, `key = value` with bare, quoted and
/// dotted keys (up to 16 parts), basic and literal strings (one line or three-quoted), arrays and
/// inline tables. Other values (numbers, booleans, dates) are kept as raw text; arrays of tables
/// are skipped. Anything else, a duplicate key or table, or text after a header or value, fails
/// the whole parse: a file is used whole or not at all. Nothing is evaluated.
enum TOMLLite {
  static let maxKeyParts = 16

  indirect enum Value: Equatable {
    case string(String)
    case array([Value])
    case table([String: Value])
    case other(String)
    /// As JSON-like values: a string, an array, a dictionary; a number, boolean or date as its text.
    var plain: Any {
      switch self {
      case .string(let text): return text
      case .array(let items): return items.map(\.plain)
      case .table(let table): return table.mapValues(\.plain)
      case .other(let raw): return raw
      }
    }
  }

  /// The document, or nil when any of it could not be read.
  static func parse(_ text: String) -> [String: Value]? {
    var parser = Parser(Array(text.unicodeScalars))
    let root = parser.document()
    return parser.failed ? nil : root
  }

  /// Sets `path` in `table`, making tables on the way. False for a key already set or a value in
  /// the way of the path, which TOML refuses.
  static func set(_ table: inout [String: Value], _ path: [String], _ value: Value) -> Bool {
    guard let first = path.first else { return false }
    if path.count == 1 {
      guard table[first] == nil else { return false }
      table[first] = value
      return true
    }
    var inner: [String: Value] = [:]
    if case .table(let existing)? = table[first] {
      inner = existing
    } else if table[first] != nil {
      return false
    }
    guard set(&inner, Array(path.dropFirst()), value) else { return false }
    table[first] = .table(inner)
    return true
  }

  /// A key split at the dots outside quotes: bare parts are letters, digits, `-` and `_`; a
  /// double- or single-quoted part keeps its text (an escape in it is not read). Nil when it is
  /// malformed or has more than `maxKeyParts` parts.
  static func keyPath(_ text: String) -> [String]? {
    let s: [Unicode.Scalar] = Array(text.unicodeScalars)
    var i = 0
    var parts: [String] = []
    while true {
      while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
      guard i < s.count else { return nil }
      var part = String.UnicodeScalarView()
      let first: Unicode.Scalar = s[i]
      if first == "\"" || first == "'" {
        i += 1
        while i < s.count, s[i] != first {
          if first == "\"", s[i] == "\\" { return nil }
          part.append(s[i])
          i += 1
        }
        guard i < s.count else { return nil }
        i += 1
      } else {
        while i < s.count, bare(s[i]) {
          part.append(s[i])
          i += 1
        }
        if part.isEmpty { return nil }
      }
      parts.append(String(part))
      guard parts.count <= maxKeyParts else { return nil }
      while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
      if i == s.count { return parts }
      guard s[i] == "." else { return nil }
      i += 1
    }
  }

  /// A bare key's characters: A-Z, a-z, 0-9, `-` and `_`.
  static func bare(_ c: Unicode.Scalar) -> Bool {
    let v: UInt32 = c.value
    if v >= 0x61 && v <= 0x7A { return true }
    if v >= 0x41 && v <= 0x5A { return true }
    if v >= 0x30 && v <= 0x39 { return true }
    return v == 0x2D || v == 0x5F
  }

  struct Parser {
    let s: [Unicode.Scalar]
    var i = 0
    /// Set at the first thing this reader does not take; the parse is then thrown away.
    var failed = false
    init(_ s: [Unicode.Scalar]) {
      self.s = s
      if s.first == "\u{FEFF}" { i = 1 }
    }
    var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }
    var atLineEnd: Bool {
      guard let c = peek else { return true }
      return c == "\n" || c == "\r"
    }
    func at(_ text: String) -> Bool {
      var j = i
      for c in text.unicodeScalars {
        guard j < s.count, s[j] == c else { return false }
        j += 1
      }
      return true
    }
    mutating func spaces() { while let c = peek, c == " " || c == "\t" { i += 1 } }
    mutating func comment() { if peek == "#" { restOfLine() } }
    mutating func restOfLine() { while let c = peek, c != "\n" { i += 1 } }
    /// Spaces, line breaks and comments.
    mutating func blank() {
      while let c = peek {
        if c == " " || c == "\t" || c == "\n" || c == "\r" {
          i += 1
        } else if c == "#" {
          restOfLine()
        } else {
          break
        }
      }
    }

    mutating func document() -> [String: Value] {
      var root: [String: Value] = [:]
      var table: [String]? = []
      var headers = Set<[String]>()
      while true {
        blank()
        guard let c = peek else { break }
        if c == "[" {
          if at("[[") {
            // An array of tables names no server.
            table = nil
            restOfLine()
            continue
          }
          i += 1
          guard let path = key(until: "]"), peek == "]", headers.insert(path).inserted else {
            failed = true
            break
          }
          i += 1
          table = path
          spaces()
          comment()
          guard atLineEnd else {
            failed = true
            break
          }
        } else {
          guard let path = key(until: "="), peek == "=" else {
            failed = true
            break
          }
          i += 1
          spaces()
          guard let value = value(depth: 0) else {
            failed = true
            break
          }
          if let table {
            let full: [String] = table + path
            guard full.count <= TOMLLite.maxKeyParts, TOMLLite.set(&root, full, value) else {
              failed = true
              break
            }
          }
          spaces()
          comment()
          guard atLineEnd else {
            failed = true
            break
          }
        }
      }
      return root
    }

    /// A key up to `end` on this line, quotes respected and kept, split by `keyPath`.
    mutating func key(until end: Unicode.Scalar) -> [String]? {
      var text = String.UnicodeScalarView()
      var quote: Unicode.Scalar?
      while let c = peek, c != "\n" {
        if quote == nil, c == end { break }
        if c == "\"" || c == "'" {
          if quote == nil { quote = c } else if quote == c { quote = nil }
        }
        text.append(c)
        i += 1
      }
      return TOMLLite.keyPath(String(text))
    }

    mutating func value(depth: Int) -> Value? {
      guard depth < 16, let c = peek else { return nil }
      switch c {
      case "\"": return at("\"\"\"") ? multiline(basic: true) : basic()
      case "'": return at("'''") ? multiline(basic: false) : literal()
      case "[":
        i += 1
        var items: [Value] = []
        while true {
          blank()
          if peek == "]" {
            i += 1
            return .array(items)
          }
          guard let item = value(depth: depth + 1) else { return nil }
          items.append(item)
          blank()
          if peek == "," {
            i += 1
          } else if peek == "]" {
            i += 1
            return .array(items)
          } else {
            return nil
          }
        }
      case "{":
        i += 1
        var table: [String: Value] = [:]
        while true {
          spaces()
          if peek == "}" {
            i += 1
            return .table(table)
          }
          guard let path = key(until: "="), peek == "=" else { return nil }
          i += 1
          spaces()
          guard let item = value(depth: depth + 1), TOMLLite.set(&table, path, item) else { return nil }
          spaces()
          if peek == "," {
            i += 1
          } else if peek == "}" {
            i += 1
            return .table(table)
          } else {
            return nil
          }
        }
      default:
        var raw = String.UnicodeScalarView()
        while let c = peek, !",]}#\n\r".unicodeScalars.contains(c) {
          raw.append(c)
          i += 1
        }
        let text = String(raw).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .other(text)
      }
    }
    mutating func basic() -> Value? {
      i += 1
      var out = String.UnicodeScalarView()
      while let c = peek {
        i += 1
        if c == "\"" { return .string(String(out)) }
        if c == "\n" { return nil }
        if c == "\\" {
          guard let e = escape() else { return nil }
          out.append(e)
        } else {
          out.append(c)
        }
      }
      return nil
    }

    mutating func literal() -> Value? {
      i += 1
      var out = String.UnicodeScalarView()
      while let c = peek {
        i += 1
        if c == "'" { return .string(String(out)) }
        if c == "\n" { return nil }
        out.append(c)
      }
      return nil
    }

    mutating func multiline(basic: Bool) -> Value? {
      let fence = basic ? "\"\"\"" : "'''"
      i += 3
      // A line break right after the opening quotes is not part of the string.
      if peek == "\r" { i += 1 }
      if peek == "\n" { i += 1 }
      var out = String.UnicodeScalarView()
      while i < s.count {
        if at(fence) {
          i += 3
          return .string(String(out))
        }
        let c = s[i]
        i += 1
        if basic, c == "\\" {
          if let next = peek, next == "\n" || next == "\r" || next == " " || next == "\t" {
            // A line-ending backslash drops the break and the spaces after it.
            while let w = peek, w == " " || w == "\t" || w == "\n" || w == "\r" { i += 1 }
            continue
          }
          guard let e = escape() else { return nil }
          out.append(e)
        } else {
          out.append(c)
        }
      }
      return nil
    }

    mutating func escape() -> Unicode.Scalar? {
      guard let c = peek else { return nil }
      i += 1
      switch c {
      case "n": return "\n"
      case "t": return "\t"
      case "r": return "\r"
      case "b": return "\u{08}"
      case "f": return "\u{0C}"
      case "e": return "\u{1B}"
      case "\"": return "\""
      case "\\": return "\\"
      case "u", "U":
        let count = c == "u" ? 4 : 8
        guard i + count <= s.count,
          let v = UInt32(String(String.UnicodeScalarView(s[i..<(i + count)])), radix: 16)
        else { return nil }
        i += count
        return Unicode.Scalar(v)
      default: return nil
      }
    }
  }
}
