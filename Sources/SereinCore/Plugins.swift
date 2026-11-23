import CryptoKit
import Foundation

/// Plugins extend Relay without changing Serein. A plugin is a folder in `Library/plugins/`:
/// - skills: `SKILL.md` files (the Agent Skills format, agentskills.io) at the folder's root or
///   in `skills/<name>/`. A skill is instructions Relay reads; it grants nothing.
/// - tools: `serein-plugin.json` naming a stdio MCP server and every tool it offers with its
///   risk, plus the permissions it needs (PluginManifest). Serein runs it in its own process
///   group and sandbox, and every call passes Relay's policy and agent history.
public struct PluginSkill: Equatable, Sendable {
  public var name: String
  public var description: String
  public var instructions: String
  public var license: String?
  public var compatibility: String?
  /// The skill's folder, for its supporting files.
  public var folder: URL
}

public enum SkillParser {
  public static let maxFileBytes = 64_000
  public static let maxDescription = 1024
  public static let maxInstructions = 12_000
  /// Supporting files Relay may read: text only, bounded.
  public static let maxSupportBytes = 256 * 1024

  /// Parses `SKILL.md`: YAML front matter between `---` lines with scalar `name`, `description`
  /// and optional `license` and `compatibility`, then the instructions. Indented lines (a
  /// `metadata` map) and unknown keys are kept out; nothing in it is evaluated.
  public static func parse(_ text: String, folder: URL) throws -> PluginSkill {
    guard text.utf8.count <= maxFileBytes else { throw SereinError.invalid("SKILL.md is over 64 KB.") }
    var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
    else { throw SereinError.invalid("SKILL.md must start with front matter between --- lines.") }
    var fields: [String: String] = [:]
    for line in lines[1..<end] {
      guard let first = line.first, first != " ", first != "\t", first != "#",
        let colon = line.firstIndex(of: ":")
      else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
        value = String(value.dropFirst().dropLast())
      }
      guard fields[key] == nil else { throw SereinError.invalid("SKILL.md repeats \(key).") }
      fields[key] = value
    }
    guard let name = fields["name"], name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil,
      name.count <= 64
    else { throw SereinError.invalid("A skill's name is lowercase words joined by hyphens, up to 64 characters.") }
    guard let description = fields["description"], !description.isEmpty, description.count <= maxDescription else {
      throw SereinError.invalid("A skill needs a description under \(maxDescription) characters.")
    }
    let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw SereinError.invalid("The skill \(name) has no instructions.") }
    guard body.count <= maxInstructions else {
      throw SereinError.invalid("The skill \(name)'s instructions are over \(maxInstructions) characters.")
    }
    return PluginSkill(
      name: name, description: description, instructions: body, license: fields["license"],
      compatibility: fields["compatibility"], folder: folder)
  }

  /// A supporting file inside the skill's folder: no `..`, no symbolic links, text, bounded.
  public static func supportFile(_ relative: String, in skill: PluginSkill) throws -> String {
    let parts = relative.split(separator: "/").map(String.init)
    guard !parts.isEmpty, !relative.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
      throw SereinError.invalid("Give a path inside the skill's folder.")
    }
    var url = skill.folder
    for part in parts {
      url.appendPathComponent(part)
      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true { throw SereinError.invalid("Skills cannot follow links.") }
    }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= maxSupportBytes, let data = try? Data(contentsOf: url) else {
      throw SereinError.invalid("No readable file \(relative) in the skill (text up to 256 KB).")
    }
    guard let text = String(data: data, encoding: .utf8) else { throw SereinError.invalid("\(relative) is not text.") }
    return text
  }
  /// The skill's other files, by relative path (for skill_read).
  public static func files(of skill: PluginSkill, limit: Int = 64) -> [String] {
    guard let walker = FileManager.default.enumerator(
      at: skill.folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
    else { return [] }
    var out: [String] = []
    for case let url as URL in walker {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      // The enumerator does not follow links; a link itself is never listed.
      guard values?.isSymbolicLink != true, values?.isRegularFile == true, let relative = PluginCatalog.relative(url, in: skill.folder) else { continue }
      // Nested skills belong to themselves.
      if relative == "SKILL.md" || relative.hasPrefix("skills/") { continue }
      out.append(relative)
      if out.count >= limit { break }
    }
    return out.sorted()
  }
}

/// One installed plugin folder: its skills and its tool manifest, and what was wrong with it.
public struct PluginPackage: Sendable {
  public var id: String
  public var folder: URL
  public var skills: [PluginSkill]
  public var manifest: PluginManifest?
  public var problems: [String]
  public var name: String { manifest?.name ?? skills.first?.name ?? id }
}

public enum PluginCatalog {
  public static let directory = "plugins"
  /// `url`'s path inside `folder`, comparing resolved paths (/var and /private/var are one).
  static func relative(_ url: URL, in folder: URL) -> String? {
    let base = folder.resolvingSymlinksInPath().path + "/"
    let path = url.resolvingSymlinksInPath().path
    guard path.hasPrefix(base) else { return nil }
    let relative = String(path.dropFirst(base.count))
    return relative.isEmpty || relative.split(separator: "/").contains("..") ? nil : relative
  }
  /// Every plugin folder under `root` (the library's plugins folder), sorted by id.
  public static func scan(_ root: URL) -> [PluginPackage] {
    let manager = FileManager.default
    guard let folders = try? manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
    else { return [] }
    return folders.compactMap { folder -> PluginPackage? in
      let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
      return load(folder)
    }.sorted { $0.id < $1.id }
  }
  public static func load(_ folder: URL) -> PluginPackage {
    var package = PluginPackage(id: folder.lastPathComponent, folder: folder, skills: [], manifest: nil, problems: [])
    func skill(at dir: URL) {
      let file = dir.appendingPathComponent("SKILL.md")
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
      do { package.skills.append(try SkillParser.parse(text, folder: dir)) } catch {
        package.problems.append("\(dir.lastPathComponent)/SKILL.md: \(error.localizedDescription)")
      }
    }
    skill(at: folder)
    let nested = folder.appendingPathComponent("skills")
    for dir in ((try? FileManager.default.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil)) ?? [])
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      skill(at: dir)
    }
    let manifestFile = folder.appendingPathComponent(PluginManifest.fileName)
    if let data = try? Data(contentsOf: manifestFile) {
      do {
        let manifest = try PluginManifest.decode(data)
        package.manifest = manifest
        package.id = manifest.id
      } catch { package.problems.append("\(PluginManifest.fileName): \(error.localizedDescription)") }
    }
    if package.skills.isEmpty && package.manifest == nil && package.problems.isEmpty {
      package.problems.append("No SKILL.md or \(PluginManifest.fileName) in this folder.")
    }
    return package
  }
  /// Copies a plugin folder into the library: regular files only (no links), bounded, so a
  /// plugin is a fixed copy the user reviewed, not a live link into somewhere else.
  public static func install(from source: URL, into root: URL, maxFiles: Int = 400, maxBytes: Int = 64 * 1024 * 1024) throws -> URL {
    let manager = FileManager.default
    let probe = load(source)
    guard !probe.skills.isEmpty || probe.manifest != nil else {
      throw SereinError.invalid(probe.problems.first ?? "That folder is not a plugin.")
    }
    let name = probe.id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    let target = root.appendingPathComponent(name, isDirectory: true)
    guard !manager.fileExists(atPath: target.path) else { throw SereinError.invalid("A plugin named \(name) is already installed.") }
    guard let walker = manager.enumerator(
      at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey],
      options: [.skipsHiddenFiles])
    else { throw SereinError.invalid("Cannot read that folder.") }
    var files: [(URL, String)] = []
    var total = 0
    for case let url as URL in walker {
      let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey])
      if v.isSymbolicLink == true { throw SereinError.invalid("Plugins cannot contain links (\(url.lastPathComponent)).") }
      guard v.isRegularFile == true else { continue }
      total += v.fileSize ?? 0
      guard let relative = relative(url, in: source) else { throw SereinError.invalid("Cannot read \(url.lastPathComponent).") }
      files.append((url, relative))
      guard files.count <= maxFiles, total <= maxBytes else {
        throw SereinError.invalid("That plugin is too large (over \(maxFiles) files or \(maxBytes / 1_048_576) MB).")
      }
    }
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let staging = root.appendingPathComponent(".installing-" + UUID().uuidString, isDirectory: true)
    do {
      for (url, relative) in files {
        let destination = staging.appendingPathComponent(relative)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: url, to: destination)
      }
      try manager.moveItem(at: staging, to: target)
    } catch {
      try? manager.removeItem(at: staging)
      throw error
    }
    return target
  }
}

/// `serein-plugin.json`: who the plugin is, the stdio MCP server it runs, each tool with its risk,
/// and what it may reach. Unknown keys are refused, so a typo never silently grants nothing or
/// something else.
public struct PluginManifest: Codable, Equatable, Sendable {
  public static let fileName = "serein-plugin.json"
  public enum Risk: String, Codable, CaseIterable, Sendable { case read, write, send, delete, pay }
  public struct Tool: Codable, Equatable, Sendable {
    public var name: String
    public var risk: Risk
    public var description: String?
    /// The server's own name for the tool when it is not a valid local `name` (a server
    /// connected by address may name tools `getIssue` or `notion-search`). Calls and schema
    /// checks use it; Relay only ever sees `name`.
    public var remote: String?
    /// The name the server knows the tool by.
    public var serverName: String { remote ?? name }
    /// The words the gate raises the risk by (`ApprovalGate.pluginEffect`): the local name and,
    /// when there is one, the server's own, split into words (`deletePage`, `delete-page`), so a
    /// mild local name cannot hide what the server's name says.
    public var gateName: String {
      guard let remote else { return name }
      let words = remote.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "[-.]", with: " ", options: .regularExpression)
      return name + " " + words
    }
  }
  public struct Server: Codable, Equatable, Sendable {
    /// Relative to the plugin folder (`./bin/server`), or an interpreter on the system
    /// (`/usr/bin/python3`, `node`) with the script in `args`. Absent when `url` is set.
    public var command: String?
    /// A remote MCP server (Streamable HTTP, https only). The reviewed manifest URL is the
    /// only endpoint contacted — the sandbox is the network itself.
    public var url: String?
    /// The name of the Keychain secret sent as a bearer token to `url`.
    public var token: String?
    /// `"oauth2"`: the user signs in once in the browser (PKCE, dynamic registration) and
    /// Serein keeps the tokens in the Keychain, refreshing them itself.
    public var auth: String?
    public var args: [String]?
    /// Names of environment values the user supplies in Settings (kept in the Keychain).
    public var env: [String]?

    /// The one endpoint rule, shared by `validate()` and the host that connects, so a manifest
    /// that is accepted is also usable: https anywhere; plain http only to the machine itself,
    /// where TLS protects nothing. Nil for anything else.
    public static func remoteURL(_ string: String) -> URL? {
      guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
        let host = url.host?.lowercased(), !host.isEmpty
      else { return nil }
      let loopback = ["127.0.0.1", "localhost", "::1"].contains(host)
      switch url.scheme?.lowercased() {
      case "https": return url
      case "http" where loopback: return url
      default: return nil
      }
    }
  }
  public struct Permissions: Codable, Equatable, Sendable {
    /// Hosts the server may reach (`api.example.com`), or none.
    public var network: [String]?
    /// `none` or `plugin-data` (its own folder in the library).
    public var files: String?
  }
  public var id: String
  public var name: String
  public var version: String
  public var description: String
  public var author: String?
  public var license: String?
  public var homepage: String?
  public var mcp: Server?
  public var tools: [Tool]?
  public var permissions: Permissions?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name, version, description, author, license, homepage, mcp, tools, permissions
  }
  public static func decode(_ data: Data) throws -> PluginManifest {
    guard data.count <= 64_000 else { throw SereinError.invalid("The manifest is over 64 KB.") }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SereinError.invalid("The manifest is not a JSON object.")
    }
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    if let unknown = object.keys.first(where: { !known.contains($0) }) {
      throw SereinError.invalid("Unknown manifest key \(unknown).")
    }
    let manifest: PluginManifest
    do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) } catch {
      throw SereinError.invalid("The manifest does not match the format: \(error.localizedDescription)")
    }
    try manifest.validate()
    return manifest
  }
  public func validate() throws {
    guard id.range(of: "^[a-z0-9]+([.-][a-z0-9]+)*$", options: .regularExpression) != nil, id.count <= 80 else {
      throw SereinError.invalid("id is lowercase letters and digits joined by dots or hyphens (dev.example.weather).")
    }
    guard !name.isEmpty, name.count <= 60 else { throw SereinError.invalid("name is 1 to 60 characters.") }
    guard version.range(of: "^\\d+\\.\\d+(\\.\\d+)?([-+][0-9A-Za-z.-]+)?$", options: .regularExpression) != nil else {
      throw SereinError.invalid("version is like 1.0.0.")
    }
    guard !description.isEmpty, description.count <= 300 else { throw SereinError.invalid("description is 1 to 300 characters.") }
    let tools = self.tools ?? []
    guard (mcp == nil) == tools.isEmpty else {
      throw SereinError.invalid(mcp == nil ? "Tools need an mcp server." : "List every tool the server offers, with its risk.")
    }
    guard tools.count <= 40 else { throw SereinError.invalid("At most 40 tools.") }
    var seen = Set<String>()
    for tool in tools {
      guard tool.name.range(of: "^[a-z][a-z0-9_]{0,47}$", options: .regularExpression) != nil else {
        throw SereinError.invalid("Tool name \(tool.name) is lowercase letters, digits and underscores.")
      }
      guard seen.insert(tool.name).inserted else { throw SereinError.invalid("Tool \(tool.name) is listed twice.") }
      if let remote = tool.remote {
        guard remote.range(of: "\\A[A-Za-z0-9_.-]{1,128}\\z", options: .regularExpression) != nil else {
          throw SereinError.invalid("Tool \(tool.name)'s remote name is letters, digits, dots, hyphens and underscores.")
        }
      }
    }
    // Two local names for one server tool would review it twice under different risks.
    guard Set(tools.map(\.serverName)).count == tools.count else {
      throw SereinError.invalid("Two tools name the same server tool.")
    }
    if let server = mcp {
      let remote = server.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !remote.isEmpty {
        guard (server.command ?? "").isEmpty else {
          throw SereinError.invalid("mcp is a command or a url, not both.")
        }
        // https everywhere; plain http only to the machine itself, where TLS protects nothing.
        // The same rule the host applies when it connects, so an accepted manifest is usable.
        guard Server.remoteURL(remote) != nil else {
          throw SereinError.invalid("mcp.url is an https URL (plain http only for 127.0.0.1).")
        }
        if let token = server.token {
          guard token.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil else {
            throw SereinError.invalid("mcp.token is a name like API_KEY.")
          }
          guard (server.env ?? []).contains(token) else {
            throw SereinError.invalid("mcp.token \(token) must also be listed in env, so the user can enter it.")
          }
        }
        if let auth = server.auth {
          guard auth == "oauth2" else { throw SereinError.invalid("mcp.auth is oauth2.") }
          guard server.token == nil else { throw SereinError.invalid("mcp is a token or an oauth2 sign-in, not both.") }
        }
      } else {
        let command = server.command ?? ""
        guard !command.isEmpty, !command.contains("..") else { throw SereinError.invalid("mcp.command is a file in the plugin or a system interpreter.") }
      }
      for name in server.env ?? [] where name.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) == nil {
        throw SereinError.invalid("env names are like API_KEY.")
      }
    }
    if let files = permissions?.files, !["none", "plugin-data"].contains(files) {
      throw SereinError.invalid("permissions.files is none or plugin-data.")
    }
    for host in permissions?.network ?? [] {
      guard host.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", options: .regularExpression) != nil else {
        throw SereinError.invalid("network lists host names such as api.example.com.")
      }
      // Removing this check accepts 127.0.0.1 and 169.254.169.254 as host names.
      if ConnectGate.isRawIP(host) {
        throw SereinError.invalid("network lists host names, not raw IP addresses.")
      }
    }
  }
  /// The name Relay calls a plugin tool by: `<plugin>__<tool>`, with the id's dots as underscores.
  public func qualified(_ tool: String) -> String {
    id.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_") + "__" + tool
  }
  /// What the install review shows, in plain words.
  public var permissionSummary: [String] {
    var out: [String] = []
    let hosts = permissions?.network ?? []
    out.append(hosts.isEmpty ? "No internet access" : "Reaches " + hosts.joined(separator: ", "))
    out.append(permissions?.files == "plugin-data" ? "Keeps its own files in Serein's library" : "No access to your files")
    if let env = mcp?.env, !env.isEmpty { out.append("Asks you for: " + env.joined(separator: ", ")) }
    return out
  }
}

/// How a plugin command is allowed to use the network.
/// A manifest with no hosts gets no network. A manifest that lists hosts uses the egress proxy
/// and never an open network. Returning open network here omits `(deny network*)` from the profile.
public enum PluginCommandNetwork {
  public static func limit(hosts: [String]) -> (openNetwork: Bool, requiresProxy: Bool) {
    if hosts.isEmpty { return (false, false) }
    return (false, true)
  }

  /// The sandbox profile for `plugin test` and `plugin validate`.
  /// `proxyPort` is the egress listener. It is applied only when the manifest lists hosts.
  public static func profile(home: URL, plugin: URL, data: URL?, hosts: [String], proxyPort: UInt16?) -> String {
    let limit = limit(hosts: hosts)
    return PluginSandbox.profile(
      home: home, plugin: plugin, data: data,
      network: limit.openNetwork, proxyPort: limit.requiresProxy ? proxyPort : nil)
  }
}

/// The macOS sandbox a plugin's server runs in: it reads the system and its own folder, writes
/// only its data folder and temporary files, never reads or writes the user's home otherwise,
/// and has no open network. Hosts named in the manifest go through the egress proxy. When a proxy port is given, ALL
/// outbound network is denied except a loopback egress proxy on that port (PluginEgress), which
/// enforces the manifest's hosts per connection; a stack that bypasses the proxy fails closed.
public enum PluginSandbox {
  public static func profile(home: URL, plugin: URL, data: URL?, network: Bool, proxyPort: UInt16? = nil) -> String {
    // The sandbox matches physical paths (/private/tmp, not /tmp); Foundation's resolving
    // drops /private again, so libc's realpath gives the spelling the kernel sees.
    func paths(_ url: URL) -> [String] {
      let path = url.standardizedFileURL.path
      let real = realpath(path, nil).map { p -> String in
        defer { free(p) }
        return String(cString: p)
      } ?? path
      return path == real ? [path] : [path, real]
    }
    func subpaths(_ urls: [URL]) -> String {
      urls.flatMap(paths).map { "(subpath " + jsonString($0) + ")" }.joined(separator: " ")
    }
    var rules = [
      "(version 1)", "(allow default)",
      "(deny file-read* file-write* " + subpaths([home]) + ")",
      "(deny file-write* (subpath \"/\"))",
      "(allow file-write* (subpath \"/dev\") (subpath \"/private/tmp\") (subpath \"/private/var/folders\"))",
      // Its installed files stay as the user reviewed them, wherever the library is.
      "(deny file-write* " + subpaths([plugin]) + ")",
      "(allow file-read* " + subpaths([plugin]) + ")",
    ]
    if let data { rules.append("(allow file-read* file-write* " + subpaths([data]) + ")") }
    if let proxyPort {
      rules.append("(deny network*)")
      // sandbox-exec accepts only `*` or `localhost` as the host here; "127.0.0.1:PORT" fails to compile.
      rules.append("(allow network-outbound (remote ip \"localhost:\(proxyPort)\"))")
    } else if !network {
      rules.append("(deny network*)")
    }
    rules.append("(deny mach-lookup (global-name \"com.apple.cfprefsd.daemon\") (global-name \"com.apple.cfprefsd.agent\"))")
    return rules.joined(separator: "\n") + "\n"
  }
}

/// A plugin tool's schema, pinned at review: the same name, description and input schema, in a
/// stable spelling. A server that later offers a different schema is refused until reviewed.
public enum PluginSchemas {
  /// `hints` also pins the tool's MCP annotation hints (readOnlyHint, destructiveHint, …), for a
  /// server connected by address whose risks come from them: a changed hint is a changed tool.
  public static func fingerprint(_ tool: [String: Any], hints: Bool = false) -> String {
    var kept: [String: Any] = [
      "name": tool["name"] ?? "", "description": tool["description"] ?? "",
      "inputSchema": tool["inputSchema"] ?? [:],
    ]
    if hints {
      let annotations = tool["annotations"] as? [String: Any] ?? [:]
      kept["hints"] = annotations.filter { $0.key.hasSuffix("Hint") }
    }
    let data = (try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])) ?? Data()
    // FNV-1a 64: a change detector for a reviewed schema, not a security hash.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }
  /// The tools Relay sees: only those the manifest lists, renamed `<plugin>__<tool>`, with the
  /// declared risk in the description. Returns the schemas and the manifest tools the server
  /// did not offer. `fenced` marks the server's own description as untrusted text (a server
  /// connected by address, whose words nobody reviewed in a manifest).
  public static func relayTools(
    _ offered: [[String: Any]], manifest: PluginManifest, fenced: Bool = false
  ) -> (tools: [[String: Any]], missing: [String]) {
    var tools: [[String: Any]] = []
    var missing: [String] = []
    for declared in manifest.tools ?? [] {
      guard let tool = offered.first(where: { $0["name"] as? String == declared.serverName }) else {
        missing.append(declared.name)
        continue
      }
      var schema = tool["inputSchema"] as? [String: Any] ?? ["type": "object"]
      if schema["type"] == nil { schema["type"] = "object" }
      // The server's words inside the schema reach the model too: short and escaped.
      if fenced { schema = (untrustedSchema(schema) as? [String: Any]) ?? ["type": "object"] }
      let raw = tool["description"] as? String ?? declared.description ?? ""
      let description = String((fenced ? visibleText(raw) : raw).prefix(600))
      let shown: String = fenced ? UntrustedText.wrap("tool_description", description) : description
      tools.append([
        "name": manifest.qualified(declared.name),
        "description": "[\(manifest.name) plugin · \(declared.risk.rawValue)] \(shown)",
        "inputSchema": schema,
      ])
    }
    return (tools, missing)
  }

  /// A schema with every nested `description` and `title` string cut to 200 characters, its
  /// invisible characters removed and escaped (`UntrustedText.escape`); the rest unchanged.
  public static func untrustedSchema(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
      return Dictionary(uniqueKeysWithValues: object.map { key, inner -> (String, Any) in
        if ["description", "title"].contains(key), let text = inner as? String {
          return (key, UntrustedText.escape(String(visibleText(text).prefix(200))))
        }
        return (key, untrustedSchema(inner))
      })
    }
    if let array = value as? [Any] { return array.map(untrustedSchema) }
    return value
  }

  /// Text without the characters that reorder or hide what a person reads (bidirectional
  /// overrides and isolates) and without control characters other than line breaks and tabs, so
  /// the review card shows what the model gets.
  public static func visibleText(_ text: String) -> String {
    var kept = String.UnicodeScalarView()
    kept.append(contentsOf: text.unicodeScalars.filter { scalar in
      let v = scalar.value
      if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return false }
      if v < 0x20 { return v == 0x0A || v == 0x09 }
      return v != 0x7F
    })
    return String(kept)
  }
}

/// A plugin on GitHub, pinned to one commit: the link the user pasted, read as owner, repository,
/// branch/tag/commit and folder. Files are fetched from that commit only and each one must hash
/// to the tree's Git blob id, so a moved branch can never mix versions.
public struct GitHubPluginSource: Equatable, Sendable {
  public var owner: String
  public var repo: String
  /// A branch, tag or commit; nil means the default branch.
  public var ref: String?
  /// The plugin's folder inside the repository ("" for the root).
  public var path: String
  public init(owner: String, repo: String, ref: String?, path: String) {
    self.owner = owner
    self.repo = repo
    self.ref = ref
    self.path = path
  }

  /// github.com/owner/repo, …/tree/<ref>/<folder>, …/blob/<ref>/<folder>/serein-plugin.json
  /// (or SKILL.md). A ref with a slash in it is not supported: use a commit link.
  public static func parse(_ text: String) -> GitHubPluginSource? {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !t.contains("://") { t = "https://" + t }
    guard let url = URL(string: t), url.scheme == "https", url.host?.lowercased() == "github.com" || url.host?.lowercased() == "www.github.com"
    else { return nil }
    var parts = url.path.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return nil }
    let valid = "^[A-Za-z0-9._-]+$"
    let owner = parts.removeFirst()
    var repo = parts.removeFirst()
    if repo.hasSuffix(".git") { repo.removeLast(4) }
    guard owner.range(of: valid, options: .regularExpression) != nil, repo.range(of: valid, options: .regularExpression) != nil,
      repo != ".", repo != ".."
    else { return nil }
    var ref: String?
    if parts.count >= 2, ["tree", "blob", "commit"].contains(parts[0]) {
      ref = parts[1]
      parts.removeFirst(2)
    } else if !parts.isEmpty {
      return nil
    }
    if let last = parts.last, [PluginManifest.fileName, "SKILL.md"].contains(last) { parts.removeLast() }
    guard parts.allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty }),
      ref.map({ $0.range(of: valid, options: .regularExpression) != nil }) ?? true
    else { return nil }
    return GitHubPluginSource(owner: owner, repo: repo, ref: ref, path: parts.joined(separator: "/"))
  }
  public var api: String { "https://api.github.com/repos/\(owner)/\(repo)" }
  public func raw(_ commit: String, _ file: String) -> String {
    "https://raw.githubusercontent.com/\(owner)/\(repo)/\(commit)/" + file.split(separator: "/").map {
      String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
    }.joined(separator: "/")
  }
  /// One file to fetch: its path inside the plugin folder, Git blob id and size.
  public struct Entry: Equatable, Sendable {
    public var path: String
    public var sha: String
    public var size: Int
  }
  /// The plugin's files from a recursive Git tree. Links and submodules are refused; so is a
  /// tree too large to review.
  public func entries(tree: [[String: Any]], truncated: Bool, maxFiles: Int = 200, maxBytes: Int = 16 * 1_048_576) throws -> [Entry] {
    guard !truncated else { throw SereinError.invalid("That repository is too large to read in one go. Link the plugin's folder.") }
    let prefix = path.isEmpty ? "" : path + "/"
    var out: [Entry] = []
    var total = 0
    for item in tree {
      guard let itemPath = item["path"] as? String, itemPath.hasPrefix(prefix) || prefix.isEmpty else { continue }
      let relative = String(itemPath.dropFirst(prefix.count))
      guard !relative.isEmpty else { continue }
      let mode = item["mode"] as? String ?? ""
      let type = item["type"] as? String ?? ""
      if type == "tree" { continue }
      guard type == "blob", mode != "120000" else {
        throw SereinError.invalid("Plugins cannot contain links or submodules (\(relative)).")
      }
      // Hidden files and folders are left out, as in a local install.
      if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
      guard let sha = item["sha"] as? String, sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
        throw SereinError.invalid("The repository listed \(relative) without a valid id.")
      }
      let size = item["size"] as? Int ?? 0
      total += size
      out.append(Entry(path: relative, sha: sha, size: size))
      guard out.count <= maxFiles, total <= maxBytes else {
        throw SereinError.invalid("That plugin is too large (over \(maxFiles) files or \(maxBytes / 1_048_576) MB).")
      }
    }
    guard !out.isEmpty else { throw SereinError.invalid("No files at \(path.isEmpty ? "the repository's root" : path).") }
    guard out.contains(where: { $0.path == PluginManifest.fileName || $0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md") }) else {
      throw SereinError.invalid("That folder has no \(PluginManifest.fileName) or SKILL.md.")
    }
    return out
  }
  /// Git's blob id: SHA-1 of "blob <size>\0" followed by the bytes.
  public static func blobID(_ data: Data) -> String {
    // Git's own choice of hash: an identity check against the tree, not a security boundary
    // (the user reviews what was fetched before anything runs).
    var hash = Insecure.SHA1()
    hash.update(data: Data("blob \(data.count)\0".utf8))
    hash.update(data: data)
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
