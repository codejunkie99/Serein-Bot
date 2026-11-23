import Foundation
import SereinCore
import Security

/// Installed plugins (PluginCatalog) and their tool servers. A server runs only for a call:
/// Serein starts it in its own process group under its sandbox (PluginSandbox), checks that the
/// tool's schema is still the one the user reviewed, makes the one call and ends the group. Only
/// Relay's run sees plugin tools, and each call passes RelayAutonomy and agent history first
/// (BrowserModel.perform).
@MainActor final class PluginHost: ObservableObject {
  static let shared = PluginHost()
  /// What Serein keeps per plugin: on or off, and the tool schemas the user reviewed.
  struct State: Codable, Equatable {
    var enabled = false
    /// Qualified tool name → schema fingerprint at review.
    var pinned: [String: String] = [:]
    /// The tools Relay is shown (`<plugin>__<tool>`), as JSON.
    var toolsJSON = "[]"
    /// Where it came from, for a plugin added from GitHub: "owner/repo/path@commit".
    var source: String? = nil
    /// The link it was added from and the full commit, for update checks.
    var link: String? = nil
    var commit: String? = nil
    /// The https address of an app's MCP server connected by address (Settings › Connections):
    /// its manifest is local, built from a review of the server's own tool list. Nil otherwise.
    var address: String? = nil
    /// For a connection: every tool the person reviewed, on or off, by its server name, pinned
    /// with its hints (`MCPServerConnection.pins`). A tool missing here or differing is unreviewed.
    var reviewed: [String: String]? = nil
    /// For a connection: the server's tool list changed since the review, so it is off until
    /// the person reviews it again.
    var held: Bool? = nil
    /// For a connection: "Scheduled tasks may use this". The door no longer reads it: an
    /// unattended run follows its own level (ApprovalDoor.answer).
    var scheduled: Bool? = nil
    /// For a connection: "Reads go ahead without asking". The door no longer reads it: a read
    /// runs at every level (ApprovalDoor.answer).
    var reads: Bool? = nil
    /// A skill the person saved from a finished task (Save as Skill). Its text is pinned under
    /// `skillPin` when they save or turn it on, so a copy changed on disk is off until they do again.
    var saved: Bool? = nil
    /// The AI app an imported server or skill came from (Settings › Plugins › Import from your AI
    /// apps). An imported server's tool descriptions and answers reach the model fenced, as text
    /// nobody reviewed.
    var imported: String? = nil
  }
  static let skillPin = "SKILL.md"
  @Published private(set) var packages: [PluginPackage] = []
  @Published private(set) var states: [String: State] = [:]
  @Published var busy: String?
  private(set) var library: Library?
  static let callTimeout: TimeInterval = 20

  var root: URL? { library?.root.appendingPathComponent(PluginCatalog.directory, isDirectory: true) }

  func configure(library: Library) {
    self.library = library
    if let root {
      try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      chmod(root.path, 0o700)
    }
    states = library.load([String: State].self, from: "plugins-state.json") ?? [:]
    reload()
  }
  func reload() {
    guard let root else { return }
    packages = PluginCatalog.scan(root)
  }
  private func save() { try? library?.save(states, to: "plugins-state.json") }

  // MARK: what Relay sees

  /// Serein's own skills (Skills/ in its bundle, such as design-your-look), then those of
  /// enabled plugins (skill-only plugins are on once installed). A plugin cannot replace one of
  /// Serein's: the first skill with a name is the one Relay reads. These are the stable prompt's.
  var installedSkills: [PluginSkill] {
    Self.builtInSkills + packages.filter { states[$0.id]?.saved != true && isEnabled($0) }.flatMap(\.skills)
  }
  /// Skills saved from finished tasks that the person turned on. They ride in each turn's context
  /// (RelayPrompt.volatile), so turning one on or off never changes the stable prompt.
  var savedSkills: [PluginSkill] {
    // A plugin installed later with the same skill name wins skill_read, so it is not listed as saved.
    let installed = Set(installedSkills.map(\.name))
    return packages.filter { states[$0.id]?.saved == true && isEnabled($0) }.flatMap(\.skills)
      .filter { !installed.contains($0.name) }
  }
  /// Every skill Relay may read (skill_list, skill_read); a saved skill never replaces another.
  var skills: [PluginSkill] { installedSkills + savedSkills }
  static let builtInSkills: [PluginSkill] = {
    guard let folder = Bundle.assets.url(forResource: "Skills", withExtension: nil) else { return [] }
    return PluginCatalog.scan(folder).flatMap(\.skills)
  }()
  func isEnabled(_ package: PluginPackage) -> Bool {
    if let state = states[package.id], state.saved == true {
      // Read only as the person reviewed it.
      return state.enabled && package.manifest == nil && state.pinned[Self.skillPin] == TaskSkill.pin(package.skills)
    }
    return package.manifest?.mcp == nil ? states[package.id]?.enabled ?? true : states[package.id]?.enabled == true
  }
  /// A server connected by address (Settings › Connections) rather than a plugin folder or link.
  func isConnection(_ package: PluginPackage) -> Bool { states[package.id]?.address != nil }
  /// Every enabled plugin tool, as Relay's CLI lists it. A connection's tools are offered only
  /// while the assistant Serein acts for may use connected apps (AssistantScope).
  var relayTools: [[String: Any]] {
    // Without Serein's assistant there is no one to check the place for: connections stay out.
    let connections = RelayOrchestrator.shared.map { $0.placeRefusal(.connectedApps) == nil } ?? false
    return packages.filter { isEnabled($0) && $0.manifest?.mcp != nil && (connections || !isConnection($0)) }
      .flatMap { package -> [[String: Any]] in
      let json = states[package.id]?.toolsJSON ?? "[]"
      return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
    }
  }
  /// The plugin and declared tool behind a qualified name, when that plugin is on.
  func tool(_ qualified: String) -> (package: PluginPackage, manifest: PluginManifest, tool: PluginManifest.Tool)? {
    for package in packages where isEnabled(package) {
      guard let manifest = package.manifest, let tools = manifest.tools else { continue }
      if let tool = tools.first(where: { manifest.qualified($0.name) == qualified }) { return (package, manifest, tool) }
    }
    return nil
  }

  // MARK: install, enable, remove

  /// Copies a plugin folder in. Tool plugins stay off until `enable` reviewed their tools.
  @discardableResult
  func install(from folder: URL, source: String? = nil, link: String? = nil, commit: String? = nil) throws -> PluginPackage {
    guard let root else { throw SereinError.invalid("Serein's library is not ready.") }
    let target = try PluginCatalog.install(from: folder, into: root)
    reload()
    guard let package = packages.first(where: { $0.folder.standardizedFileURL == target.standardizedFileURL }) else {
      throw SereinError.invalid("The plugin was copied but could not be read.")
    }
    states[package.id] = State(enabled: package.manifest?.mcp == nil, source: source, link: link, commit: commit)
    save()
    return package
  }
  /// Save as Skill: the person's reviewed draft as its own skill-only plugin, through the same
  /// copy, size caps and Remove as any other. It is off until the person turns it on, and its
  /// text is pinned as saved. A skill is text for the prompt; nothing here grants access.
  /// `importedFrom` names the AI app a skill imported by the same rules came from.
  @discardableResult
  func saveSkill(_ draft: TaskSkillDraft, importedFrom: String? = nil) throws -> PluginPackage {
    guard let root else { throw SereinError.invalid("Serein's library is not ready.") }
    let file = try TaskSkill.file(draft)
    let taken = Set(Self.builtInSkills.map(\.name) + packages.flatMap(\.skills).map(\.name) + packages.map(\.id))
    guard !taken.contains(file.name) else {
      throw SereinError.invalid("A skill named \(file.name) already exists. Choose another name.")
    }
    let manager = FileManager.default
    // Staged inside the plugins folder (0700); the catalog skips hidden folders.
    let staging = root.appendingPathComponent(".saving-" + UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: staging) }
    let folder = staging.appendingPathComponent(file.name, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let skillFile = folder.appendingPathComponent("SKILL.md")
    try Data(file.text.utf8).write(to: skillFile, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: skillFile.path)
    // Its state goes first: a skill-only folder with no state would read as on at the next launch.
    states[file.name] = State(
      enabled: false, pinned: [Self.skillPin: TaskSkill.pin([file.skill])], saved: true, imported: importedFrom)
    save()
    let target: URL
    do { target = try PluginCatalog.install(from: folder, into: root) } catch {
      states[file.name] = nil
      save()
      throw error
    }
    reload()
    guard let package = packages.first(where: { $0.folder.standardizedFileURL == target.standardizedFileURL }) else {
      throw SereinError.invalid("The skill was saved but could not be read.")
    }
    return package
  }
  /// Starts the server once, keeps only the tools its manifest lists, pins their schemas, and
  /// turns the plugin on. Fails when the server does not offer every declared tool.
  func enable(_ package: PluginPackage) async throws {
    guard let manifest = package.manifest, manifest.mcp != nil else {
      // Turning a saved skill on is its review: its settings row shows the whole text.
      if states[package.id]?.saved == true { states[package.id]?.pinned = [Self.skillPin: TaskSkill.pin(package.skills)] }
      setEnabled(package, true)
      return
    }
    busy = package.id
    defer { busy = nil }
    let listed = try await listTools(package, manifest)
    let connection = isConnection(package)
    // An imported program's list was pinned at its import card, as a connection's is at its own.
    let program: Bool = !connection && states[package.id]?.imported != nil
    let pinnedList: Bool = connection || program
    // Their schemas come only from the tools that can be reviewed at all.
    let offered = pinnedList ? MCPServerConnection.offered(listed).map { $0.tool } : listed
    // They turn on only with the tool list the person reviewed, exactly.
    if pinnedList {
      let changed = MCPServerConnection.changes(listed, reviewed: states[package.id]?.reviewed ?? [:])
      guard changed.isEmpty else {
        hold(package)
        throw SereinError.invalid(Self.heldMessage(manifest.name, changed, program: program))
      }
    }
    // An imported server's own words are as unreviewed as a connection's.
    let fenced = pinnedList
    let (tools, missing) = PluginSchemas.relayTools(offered, manifest: manifest, fenced: fenced)
    guard missing.isEmpty else {
      throw SereinError.invalid("\(manifest.name) does not offer " + missing.joined(separator: ", ") + ", which its manifest lists.")
    }
    var pinned: [String: String] = [:]
    for declared in manifest.tools ?? [] {
      if let schema = offered.first(where: { $0["name"] as? String == declared.serverName }) {
        pinned[manifest.qualified(declared.name)] = PluginSchemas.fingerprint(schema, hints: pinnedList)
      }
    }
    var state = states[package.id] ?? State()
    state.held = nil
    state.enabled = true
    state.pinned = pinned
    state.toolsJSON = jsonString(tools)
    states[package.id] = state
    save()
  }
  func setEnabled(_ package: PluginPackage, _ on: Bool) {
    var state = states[package.id] ?? State()
    state.enabled = on
    states[package.id] = state
    save()
  }
  func remove(_ package: PluginPackage) throws {
    guard let root, package.folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
    try FileManager.default.removeItem(at: package.folder)
    if let manifest = package.manifest {
      for name in manifest.mcp?.env ?? [] { Self.saveSecret(nil, plugin: manifest.id, name: name) }
      // Signed-in tokens go with the plugin; a removed plugin keeps no access.
      Self.saveOAuth(plugin: manifest.id, tokens: nil)
      if let data = dataFolder(manifest) { try? FileManager.default.removeItem(at: data) }
    }
    states[package.id] = nil
    save()
    reload()
  }

  // MARK: calls

  /// One call: start the server, check the tool's pinned schema, call, end the server.
  func call(_ qualified: String, _ arguments: [String: Any]) async throws -> [String: Any] {
    guard let (package, manifest, declared) = tool(qualified) else { throw SereinError.invalid("That plugin tool is off.") }
    let connection = isConnection(package)
    let page = connection ? "Settings › Connections" : "Settings › Plugins"
    let program: Bool = !connection && states[package.id]?.imported != nil
    // A connection's and an imported program's answers are their data, never instructions, and
    // their whole tool list must still be the one reviewed.
    let pinnedList: Bool = connection || program
    let untrusted = pinnedList
    let tag = connection ? "connected_app" : "imported_tool"
    guard let pinned = states[package.id]?.pinned[qualified] else {
      throw SereinError.invalid("\(manifest.name) needs a review in \(page) before use.")
    }
    // A connection's whole tool list must still be the reviewed one: a new tool or a changed
    // hint holds the connection until the person reviews it again.
    let reviewed = pinnedList ? states[package.id]?.reviewed ?? [:] : nil
    // A write is never sent twice: once its call went out, a lost answer is reported, not retried.
    let sent = CallSentFlag()
    let readOnly = ApprovalGate.pluginEffect(name: declared.gateName, declared: declared.risk, effect: .read) == .read
    let retries = !connection || readOnly
    let result: [String: Any]
    do {
      result = try await session(package, manifest, mayRetry: { retries || !sent.value }) { rpc in
        let listed = try PluginSession.listTools(rpc)
        var offered = listed
        if let reviewed {
          let changed = MCPServerConnection.changes(listed, reviewed: reviewed)
          if !changed.isEmpty { throw ConnectionToolsChanged(names: changed) }
          offered = MCPServerConnection.offered(listed).map { $0.tool }
        }
        guard let schema = offered.first(where: { $0["name"] as? String == declared.serverName }),
          PluginSchemas.fingerprint(schema, hints: pinnedList) == pinned
        else {
          throw SereinError.invalid("\(manifest.name) changed its \(declared.name) tool since you reviewed it. Review it again in \(page).")
        }
        sent.value = true
        return try rpc("tools/call", ["name": declared.serverName, "arguments": arguments])
      }
    } catch let changed as ConnectionToolsChanged {
      hold(package)
      throw SereinError.invalid(Self.heldMessage(manifest.name, changed.names, program: program))
    } catch {
      guard connection else { throw error }
      // Only the server's own words are its data and fenced; Serein's messages pass as they are.
      let fromServer = error is PluginSession.ServerError
      let quoted = fromServer
        ? UntrustedText.outside("connected_app", String(error.localizedDescription.prefix(600))) : error.localizedDescription
      guard !readOnly, sent.value else { throw fromServer ? SereinError.invalid(quoted) : error }
      StepJournal.live?.cannotTell()
      throw SereinError.invalid(
        "Unknown whether it ran: \(manifest.name) did not give a clear answer to \(declared.name). It was not tried again. Check in \(manifest.name), and ask the person before trying it again. The answer was:\n" + quoted)
    }
    let items = (result["content"] as? [[String: Any]] ?? []).prefix(20)
    if result["isError"] as? Bool == true {
      let text = String(items.compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(2000))
      // Cut first, then fenced once, so the closing tag is never cut off.
      throw SereinError.invalid(untrusted ? UntrustedText.outside(tag, text) : text)
    }
    let content = items.map { item -> [String: Any] in
      if item["type"] as? String == "text" {
        let text = String((item["text"] as? String ?? "").prefix(100_000))
        guard untrusted else { return ["type": "text", "text": text] }
        // An app's answer is often compact JSON on one line, which the line cap would cut: a value per line.
        let json: String? = (try? JSONSerialization.jsonObject(with: Data(text.utf8))).map { UntrustedText.json($0) }
        return ["type": "text", "text": UntrustedText.outside(tag, json ?? text)]
      }
      if item["type"] as? String == "image", let data = item["data"] as? String, data.count < 4_000_000 { return item }
      return ["type": "text", "text": "[\(item["type"] as? String ?? "unknown") content omitted]"]
    }
    return ["content": Array(content)]
  }

  private func listTools(_ package: PluginPackage, _ manifest: PluginManifest) async throws -> [[String: Any]] {
    let result = try await session(package, manifest) { rpc in ["tools": try PluginSession.listTools(rpc)] }
    return result["tools"] as? [[String: Any]] ?? []
  }

  func dataFolder(_ manifest: PluginManifest) -> URL? {
    guard manifest.permissions?.files == "plugin-data", let library else { return nil }
    return library.root.appendingPathComponent("plugin-data/\(manifest.id)", isDirectory: true)
  }

  /// Runs the server for one exchange off the main actor. `body` gets a blocking JSON-RPC call.
  /// `mayRetry` is asked before a remote exchange is repeated after a refreshed sign-in.
  private func session(
    _ package: PluginPackage, _ manifest: PluginManifest, mayRetry: @escaping () -> Bool = { true },
    _ body: @escaping (_ rpc: (String, [String: Any]) throws -> [String: Any]) throws -> [String: Any]
  ) async throws -> [String: Any] {
    guard let server = manifest.mcp else { throw SereinError.invalid("\(manifest.name) has no tools.") }
    // Remote: the reviewed manifest URL is the only endpoint contacted, and the bearer token
    // stays in the Keychain. No process, so the sandbox is the allow-list itself.
    if let urlString = server.url?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty {
      // Same rule as validation: https anywhere, plain http only to the machine itself.
      guard let url = PluginManifest.Server.remoteURL(urlString), let host = url.host else {
        throw SereinError.invalid("\(manifest.name)'s server URL is https (plain http only for 127.0.0.1).")
      }
      if let allowed = manifest.permissions?.network, !allowed.isEmpty,
        !allowed.contains(where: { PluginSession.hostMatches(host, $0) })
      {
        throw SereinError.invalid("\(manifest.name) may only reach \(allowed.joined(separator: ", ")).")
      }
      return try await remoteExchange(
        plugin: manifest.id, name: manifest.name, url: url, oauth: server.auth == "oauth2", tokenName: server.token,
        page: isConnection(package) ? "Settings › Connections" : "Settings › Plugins", mayRetry: mayRetry, body)
    }
    return try await commandExchange(
      id: manifest.id, name: manifest.name, folder: package.folder, command: server.command ?? "",
      args: server.args ?? [], env: server.env ?? [], hosts: manifest.permissions?.network ?? [],
      data: dataFolder(manifest), body)
  }

  /// One exchange with a local server: started from `folder` in its own process group under its
  /// sandbox, its environment values from the Keychain under plugin `id`, and the network only
  /// through the egress proxy for `hosts` (none without hosts). Also lists an imported program's
  /// tools before its manifest exists.
  private func commandExchange(
    id: String, name: String, folder: URL, command commandName: String, args: [String], env: [String],
    hosts declaredHosts: [String], data: URL?,
    _ body: @escaping (_ rpc: (String, [String: Any]) throws -> [String: Any]) throws -> [String: Any]
  ) async throws -> [String: Any] {
    let command = commandName.hasPrefix("/")
      ? commandName
      : commandName.contains("/")
        ? folder.appendingPathComponent(commandName).standardizedFileURL.path
        : AgentModel.locate(commandName) ?? commandName
    guard command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) else {
      throw SereinError.invalid("\(name)'s server \(commandName) is not an executable file.")
    }
    if !commandName.hasPrefix("/"), commandName.contains("/"),
      !command.hasPrefix(folder.standardizedFileURL.path + "/") {
      throw SereinError.invalid("\(name)'s server must be inside its folder.")
    }
    if let data {
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8"]
    environment["TMPDIR"] = NSTemporaryDirectory()
    if let data { environment["SEREIN_PLUGIN_DATA"] = data.path }
    for key in env {
      guard let value = Self.secret(plugin: id, name: key) else {
        throw SereinError.invalid("\(name) needs \(key). Add it in Settings › Plugins.")
      }
      environment[key] = value
    }
    // A manifest that names hosts gets a real per-host boundary: all outbound network is
    // denied except one ephemeral loopback proxy, and the plugin's environment points the
    // HTTP stacks there. A library that bypasses the proxy fails closed.
    var egress: PluginEgress?
    let limit = PluginCommandNetwork.limit(hosts: declaredHosts)
    if limit.requiresProxy { egress = try PluginEgress(allowed: declaredHosts) }
    if let egress {
      let proxy = "http://127.0.0.1:\(egress.port)"
      for name in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] { environment[name] = proxy }
      environment["NO_PROXY"] = "127.0.0.1,localhost"
    }
    let profile = PluginCommandNetwork.profile(
      home: FileManager.default.homeDirectoryForCurrentUser, plugin: folder, data: data,
      hosts: declaredHosts, proxyPort: egress?.port)
    let arguments = ["-p", profile, command] + args
    let timeout = Self.callTimeout
    return try await Task.detached(priority: .userInitiated) {
      defer { egress?.stop() }
      return try PluginSession.run(
        arguments: arguments, folder: folder, environment: environment, timeout: timeout, body: body)
    }.value
  }

  /// One exchange with a remote server: the bearer token from the Keychain (signed-in tokens,
  /// refreshed as needed, or a pasted one), then JSON-RPC to `url` only. Also used before a
  /// connection is installed, to list the tools the person reviews.
  func remoteExchange(
    plugin id: String, name: String, url: URL, oauth: Bool, tokenName: String?, page: String,
    mayRetry: @escaping () -> Bool = { true },
    _ body: @escaping (_ rpc: (String, [String: Any]) throws -> [String: Any]) throws -> [String: Any]
  ) async throws -> [String: Any] {
    var headers: [String: String] = [:]
    if oauth {
      // The sign-in's own failure names the page this plugin or connection lives on.
      do { headers["Authorization"] = "Bearer \(try await Self.bearer(plugin: id))" } catch {
        throw SereinError.invalid("Sign in to \(name) again in \(page).")
      }
    } else if let tokenName {
      guard let value = Self.secret(plugin: id, name: tokenName) else {
        throw SereinError.invalid("\(name) needs \(tokenName). Add it in \(page).")
      }
      headers["Authorization"] = "Bearer \(value)"
    }
    let remoteTimeout = Self.callTimeout
    do {
      return try await Task.detached(priority: .userInitiated) { [headers] in
        try PluginSession.runRemote(url: url, headers: headers, timeout: remoteTimeout, body: body)
      }.value
    } catch is PluginSession.Unauthorized {
      // One refresh, one retry; a second 401 asks for a fresh sign-in. A write already sent is
      // not sent again (`mayRetry`).
      guard oauth, mayRetry(), let tokens = Self.oauthTokens(plugin: id),
        let access = try? await Self.refresh(plugin: id, tokens: tokens)
      else {
        throw SereinError.invalid(oauth ? "\(name) needs you to sign in again in \(page)." : "\(name) refused the token. Check it in \(page).")
      }
      headers["Authorization"] = "Bearer \(access)"
      return try await Task.detached(priority: .userInitiated) { [headers] in
        try PluginSession.runRemote(url: url, headers: headers, timeout: remoteTimeout, body: body)
      }.value
    }
  }

  /// Turns a connection or an imported program off until its changed tool list is reviewed again.
  func hold(_ package: PluginPackage) {
    var state = states[package.id] ?? State()
    state.enabled = false
    state.held = true
    states[package.id] = state
    save()
  }
  /// `program`: an imported program, whose Plugins row has no Review tools.
  static func heldMessage(_ name: String, _ changed: [String], program: Bool = false) -> String {
    let names: String = changed.prefix(6).joined(separator: ", ")
    let next: String = program
      ? "It is off. Remove it in Settings › Plugins and import it again to review them."
      : "It is off until you review them again in Settings › Connections."
    return "\(name)'s tools changed since you reviewed them (\(names)). " + next
  }

  // MARK: secrets

  private static func secretItem(plugin: String, name: String) -> KeychainItem {
    KeychainItem(service: "Serein plugin \(plugin)", account: name)
  }
  static func secret(plugin: String, name: String) -> String? {
    secretItem(plugin: plugin, name: name).read()
  }
  static func saveSecret(_ value: String?, plugin: String, name: String) {
    secretItem(plugin: plugin, name: name).replace(with: value)
  }

  // MARK: oauth tokens (remote plugins)

  static func oauthTokens(plugin: String) -> PluginOAuth.Tokens? {
    guard let json = secret(plugin: plugin, name: "oauth-tokens") else { return nil }
    return try? JSONDecoder().decode(PluginOAuth.Tokens.self, from: Data(json.utf8))
  }
  static func saveOAuth(plugin: String, tokens: PluginOAuth.Tokens?) {
    let json = tokens.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    saveSecret(json, plugin: plugin, name: "oauth-tokens")
  }
  /// The access token a remote plugin call goes out with: the stored one, or a refreshed one.
  static func bearer(plugin: String) async throws -> String {
    guard let tokens = oauthTokens(plugin: plugin) else {
      throw SereinError.invalid("Sign in to this plugin in Settings › Plugins.")
    }
    if !PluginOAuth.expired(tokens) { return tokens.accessToken }
    return try await refresh(plugin: plugin, tokens: tokens)
  }
  static func refresh(plugin: String, tokens: PluginOAuth.Tokens) async throws -> String {
    guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty,
      let endpoint = tokens.tokenEndpoint, let clientID = tokens.clientID
    else {
      throw SereinError.invalid("Sign in to this plugin again in Settings › Plugins.")
    }
    let fresh = try await PluginOAuth.exchange(
      PluginOAuth.refreshRequest(refreshToken: refreshToken, clientID: clientID), tokenEndpoint: endpoint)
    var merged = fresh
    if merged.refreshToken == nil { merged.refreshToken = refreshToken }
    merged.tokenEndpoint = endpoint
    merged.clientID = clientID
    saveOAuth(plugin: plugin, tokens: merged)
    return merged.accessToken
  }
}


extension PluginHost {
  /// The enabled plugin tools for one Relay task, in a private file next to its capability;
  /// the helper's arguments that name it. Removed when the task ends (BrowserModel.endTask).
  static func toolListFile(for task: BrowserTask) -> URL {
    task.file.deletingPathExtension().appendingPathExtension("plugins.json")
  }
  func writeToolList(for task: BrowserTask) throws -> [String] {
    let tools = relayTools
    guard !tools.isEmpty else { return [] }
    let file = Self.toolListFile(for: task)
    try Data(jsonString(tools).utf8).write(to: file, options: .atomic)
    chmod(file.path, 0o600)
    return ["--plugins", file.path]
  }
}

// MARK: GitHub

extension PluginHost {
  /// A plugin fetched from GitHub at one commit, waiting in a private folder for the user's review.
  struct Fetched {
    var folder: URL
    var source: String
    var commit: String
  }
  #if DEBUG
  /// Checks serve GitHub's answers here instead of the network.
  static var fetchOverride: ((URL) async throws -> Data)?
  #endif

  /// Resolves the link to a commit, lists the plugin's folder in that commit's tree, and fetches
  /// each file from that commit, checking it against the tree's blob id. Nothing runs; the
  /// caller shows the review, then installs from `folder` and removes it.
  func fetch(_ link: String) async throws -> Fetched {
    guard let source = GitHubPluginSource.parse(link) else {
      throw SereinError.invalid("Paste a GitHub link to a plugin, such as github.com/owner/repo/tree/main/my-plugin.")
    }
    let commitInfo = try await Self.json(URL(string: source.api + "/commits/" + (source.ref ?? "HEAD"))!)
    guard let commit = commitInfo["sha"] as? String, commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
      throw SereinError.invalid("GitHub did not name a commit for that link.")
    }
    let tree = try await Self.json(URL(string: source.api + "/git/trees/\(commit)?recursive=1")!)
    let entries = try source.entries(tree: tree["tree"] as? [[String: Any]] ?? [], truncated: tree["truncated"] as? Bool ?? false)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-plugin-" + UUID().uuidString, isDirectory: true)
    do {
      for entry in entries {
        let file = (source.path.isEmpty ? "" : source.path + "/") + entry.path
        let data = try await Self.get(URL(string: source.raw(commit, file))!)
        guard GitHubPluginSource.blobID(data) == entry.sha else {
          throw SereinError.invalid("\(entry.path) did not match the commit's copy. Nothing was installed.")
        }
        let url = folder.appendingPathComponent(entry.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        // Git's executable bit is in the mode; the server file needs it when the manifest runs it directly.
        if (tree["tree"] as? [[String: Any]])?.first(where: { $0["path"] as? String == file })?["mode"] as? String == "100755" {
          chmod(url.path, 0o755)
        }
      }
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
    let label = "\(source.owner)/\(source.repo)" + (source.path.isEmpty ? "" : "/" + source.path)
    return Fetched(folder: folder, source: label + "@" + String(commit.prefix(12)), commit: commit)
  }

  private static func json(_ url: URL) async throws -> [String: Any] {
    let data = try await get(url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SereinError.invalid("GitHub answered with something unexpected.")
    }
    if let message = object["message"] as? String, object["sha"] == nil, object["tree"] == nil {
      throw SereinError.invalid("GitHub: \(message.prefix(200))")
    }
    return object
  }
  /// No cookies, no credentials, no redirects, bounded: public files only.
  private static func get(_ url: URL) async throws -> Data {
    #if DEBUG
    if let fetchOverride { return try await fetchOverride(url) }
    #endif
    guard let host = url.host, ["api.github.com", "raw.githubusercontent.com"].contains(host) else {
      throw SereinError.invalid("Only GitHub is used for plugin links.")
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("Serein", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw SereinError.invalid("No answer from GitHub.") }
    guard http.statusCode == 200 else {
      throw SereinError.invalid(http.statusCode == 403 || http.statusCode == 429
        ? "GitHub is limiting requests right now. Try again in a few minutes." : "GitHub answered \(http.statusCode) for \(url.path).")
    }
    guard data.count <= 16 * 1_048_576 else { throw SereinError.invalid("A file in that plugin is too large.") }
    return data
  }
  private static let session = EphemeralHTTP.session()
}

extension PluginHost {
  /// A newer commit of a GitHub plugin, fetched for review; nil when it is up to date.
  func checkUpdate(_ package: PluginPackage) async throws -> Fetched? {
    guard let link = states[package.id]?.link else { throw SereinError.invalid("\(package.name) was not added from GitHub.") }
    let fetched = try await fetch(link)
    if fetched.commit == states[package.id]?.commit {
      try? FileManager.default.removeItem(at: fetched.folder)
      return nil
    }
    return fetched
  }
  /// Replaces a plugin's files with a reviewed newer copy. Its keys and data folder stay; a tool
  /// plugin is off again until the user turns it on, which reviews its tools afresh.
  func update(_ package: PluginPackage, with fetched: Fetched) throws {
    let probe = try replaceFiles(package, from: fetched.folder)
    var state = states[package.id] ?? State()
    state.enabled = probe.manifest?.mcp == nil
    state.pinned = [:]
    state.toolsJSON = "[]"
    state.source = fetched.source
    state.commit = fetched.commit
    states[package.id] = state
    try? library?.save(states, to: "plugins-state.json")
    reload()
  }
  /// Swaps a plugin's installed files for a reviewed copy of the same plugin, or changes nothing.
  /// Its keys, tokens and data folder stay. The caller resets its state.
  func replaceFiles(_ package: PluginPackage, from folder: URL) throws -> PluginPackage {
    let probe = PluginCatalog.load(folder)
    guard probe.id == package.id else {
      throw SereinError.invalid("The new version is a different plugin (\(probe.id)). Nothing was changed.")
    }
    guard let root else { throw SereinError.invalid("Serein's library is not ready.") }
    let aside = root.appendingPathComponent(".previous-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.moveItem(at: package.folder, to: aside)
    do {
      let target = try PluginCatalog.install(from: folder, into: root)
      guard target.lastPathComponent == package.folder.lastPathComponent else {
        try? FileManager.default.removeItem(at: target)
        throw SereinError.invalid("The new version installs under another name. Nothing was changed.")
      }
      try? FileManager.default.removeItem(at: aside)
    } catch {
      try? FileManager.default.moveItem(at: aside, to: package.folder)
      throw error
    }
    return probe
  }
}

// MARK: connections by address (Settings › Connections)

/// A connection's server answered with a tool list unlike the reviewed one (thrown inside the
/// exchange, off the main actor).
private struct ConnectionToolsChanged: Error { let names: [String] }
/// Whether a tools/call went out, set inside the exchange and read after it, so a write whose
/// answer is lost is reported instead of sent again.
private final class CallSentFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var sent = false
  var value: Bool {
    get { lock.lock(); defer { lock.unlock() }; return sent }
    set { lock.lock(); sent = newValue; lock.unlock() }
  }
}

extension PluginHost {
  /// A server being connected or reviewed again: its address, the local plugin id its manifest
  /// and Keychain items use, and how it signs in.
  struct Draft: Equatable {
    var url: URL
    var id: String
    var name: String
    var auth: MCPServerConnection.Auth
    /// The server's sign-in supports a browser sign-in with app registration.
    var canSignIn: Bool
    /// Where that sign-in happens, shown before it starts.
    var signInHost: String? = nil
  }

  /// Reads a pasted address and finds how it signs in: OAuth discovery with app registration
  /// (the plugin sign-in), else no sign-in when the server lists its tools to anyone, else a
  /// pasted token. Nothing is stored.
  func draft(_ text: String) async throws -> Draft {
    guard let url = MCPServerConnection.address(text) else { throw SereinError.invalid(MCPServerConnection.addressHelp) }
    guard let id = MCPServerConnection.id(for: url) else { throw SereinError.invalid("That address has no host name.") }
    if let existing = packages.first(where: { $0.id == id }) {
      throw SereinError.invalid("\(existing.name) is already connected. Remove it first to connect this address.")
    }
    let name = MCPServerConnection.name(for: url)
    let metadata = try? await PluginOAuth.discover(serverURL: url)
    if let metadata, metadata.registrationEndpoint != nil {
      return Draft(url: url, id: id, name: name, auth: .oauth, canSignIn: true, signInHost: metadata.signInHost)
    }
    var draft = Draft(url: url, id: id, name: name, auth: .none, canSignIn: false)
    if (try? await offeredTools(draft)) == nil { draft.auth = .token }
    return draft
  }

  /// The draft for a connection already added, to review its tools again.
  func draft(for package: PluginPackage) -> Draft? {
    guard let address = states[package.id]?.address, let url = MCPServerConnection.address(address),
      let server = package.manifest?.mcp
    else { return nil }
    let auth: MCPServerConnection.Auth = server.auth == "oauth2" ? .oauth : server.token != nil ? .token : .none
    return Draft(url: url, id: package.id, name: package.name, auth: auth, canSignIn: auth == .oauth)
  }

  /// The server's whole tool list, with the draft's sign-in.
  func offeredTools(_ draft: Draft) async throws -> [[String: Any]] {
    let result = try await remoteExchange(
      plugin: draft.id, name: draft.name, url: draft.url, oauth: draft.auth == .oauth,
      tokenName: draft.auth == .token ? MCPServerConnection.tokenName : nil, page: "Settings › Connections"
    ) { rpc in ["tools": try PluginSession.listTools(rpc)] }
    return result["tools"] as? [[String: Any]] ?? []
  }

  /// The review card's rows: for a new draft every tool, for an added connection its tools as
  /// the server offers them now, marked new or changed against the last review.
  func review(_ draft: Draft) async throws -> [MCPServerConnection.ReviewTool] {
    let offered = try await offeredTools(draft)
    guard !offered.isEmpty else { throw SereinError.invalid("\(draft.name) offers no tools.") }
    let package = packages.first { $0.id == draft.id }
    return MCPServerConnection.review(
      offered, previous: package?.manifest?.tools, reviewed: package.flatMap { states[$0.id]?.reviewed })
  }

  /// The person confirmed the card: the local manifest for the tools switched on is checked and
  /// installed (or replaces the last one) through the plugin install path, every reviewed tool is
  /// pinned with its hints, and the connection turns on through `enable`, which refuses it if
  /// the server's list changed meanwhile. With `turnOn` false (an imported server) it stays off
  /// until the person turns it on in its row.
  /// `readsGoAhead`: the review's "Reads go ahead without asking" for a new connection; nil keeps
  /// what the connection had (a review made again, an imported server).
  @discardableResult
  func connect(
    _ draft: Draft, review: [MCPServerConnection.ReviewTool], turnOn: Bool = true, readsGoAhead: Bool? = nil
  ) async throws -> PluginPackage {
    let data = try MCPServerConnection.manifest(id: draft.id, name: draft.name, address: draft.url, auth: draft.auth, tools: review)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-connection-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    try data.write(to: folder.appendingPathComponent(PluginManifest.fileName), options: .atomic)
    if let existing = packages.first(where: { $0.id == draft.id }) {
      guard isConnection(existing) else { throw SereinError.invalid("A plugin named \(existing.name) is already installed.") }
      _ = try replaceFiles(existing, from: folder)
      reload()
    } else {
      _ = try install(from: folder)
    }
    guard let package = packages.first(where: { $0.id == draft.id }) else {
      throw SereinError.invalid("The connection was saved but could not be read.")
    }
    var state = states[package.id] ?? State()
    state.enabled = false
    state.pinned = [:]
    state.toolsJSON = "[]"
    state.address = draft.url.absoluteString
    state.reviewed = MCPServerConnection.pins(review)
    state.held = nil
    if let readsGoAhead { state.reads = readsGoAhead ? true : nil }
    states[package.id] = state
    save()
    if turnOn { try await enable(package) }
    return package
  }

  /// A draft given up before it was added: its sign-in or token leaves the Keychain.
  func discard(_ draft: Draft) {
    guard !packages.contains(where: { $0.id == draft.id }) else { return }
    Self.saveOAuth(plugin: draft.id, tokens: nil)
    Self.saveSecret(nil, plugin: draft.id, name: MCPServerConnection.tokenName)
  }

  /// "Scheduled tasks may use this", per connection.
  func setScheduled(_ package: PluginPackage, _ on: Bool) {
    var state = states[package.id] ?? State()
    state.scheduled = on ? true : nil
    states[package.id] = state
    save()
  }
  /// "Reads go ahead without asking", per connection.
  func setReads(_ package: PluginPackage, _ on: Bool) {
    var state = states[package.id] ?? State()
    state.reads = on ? true : nil
    states[package.id] = state
    save()
  }
}

// MARK: import from the person's other AI apps (Settings › Plugins)

extension PluginHost {
  /// A server picked in the import list, on its way in: the plugin id its manifest and Keychain
  /// items use, and for an address the connection draft it joins Settings › Connections as.
  struct ImportDraft: Equatable {
    let server: AppImport.Server
    let id: String
    var connection: Draft?
  }

  /// Gives a picked server its plugin id and moves the secrets its setup held into the Keychain
  /// under that id. An address is a connection: a token from its setup is its sign-in, a token
  /// from that app's shell is one the person pastes, and otherwise it signs in as a pasted
  /// address does (`draft(_:)`). Nothing runs yet.
  func importDraft(_ server: AppImport.Server) async throws -> ImportDraft {
    if let problem = server.problem { throw SereinError.invalid(problem) }
    if let url = server.address {
      guard let id = MCPServerConnection.id(for: url) else { throw SereinError.invalid("That address has no host name.") }
      if let existing = packages.first(where: { $0.id == id }) {
        throw SereinError.invalid("\(existing.name) is already connected. Remove it first to import this one.")
      }
      let name = String(server.name.prefix(60))
      if server.secrets.token != nil || server.needsToken {
        Self.saveSecret(server.secrets.token, plugin: id, name: MCPServerConnection.tokenName)
        let draft = Draft(url: url, id: id, name: name, auth: .token, canSignIn: false)
        return ImportDraft(server: server, id: id, connection: draft)
      }
      var found = try await draft(url.absoluteString)
      found.name = name
      return ImportDraft(server: server, id: id, connection: found)
    }
    let id = AppImport.pluginID(for: server, taken: Set(packages.map(\.id)))
    for (name, value) in server.secrets.env { Self.saveSecret(value, plugin: id, name: name) }
    return ImportDraft(server: server, id: id, connection: nil)
  }

  /// The review rows for what a picked server offers, every tool on up to the cap. An address
  /// lists them with its sign-in; a program starts once, after the person asked on its card,
  /// under its sandbox with no internet access, from an empty private folder.
  func importTools(_ draft: ImportDraft) async throws -> [MCPServerConnection.ReviewTool] {
    if let connection = draft.connection { return try await review(connection) }
    guard let command = draft.server.command else { throw SereinError.invalid("\(draft.server.name) names no program.") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-import-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = try await commandExchange(
      id: draft.id, name: draft.server.name, folder: folder, command: command, args: draft.server.args,
      env: draft.server.envNames, hosts: [], data: nil
    ) { rpc in ["tools": try PluginSession.listTools(rpc)] }
    let tools = result["tools"] as? [[String: Any]] ?? []
    guard !tools.isEmpty else { throw SereinError.invalid("\(draft.server.name) offers no tools.") }
    return MCPServerConnection.review(tools)
  }

  /// The person confirmed a picked server's card: an address joins Settings › Connections and a
  /// program Settings › Plugins, each as a local manifest of the tools switched on, through the
  /// plugin install path, off until the person turns it on there, which refuses a tool list
  /// unlike the one on the card.
  @discardableResult
  func importServer(_ draft: ImportDraft, review: [MCPServerConnection.ReviewTool]) async throws -> PluginPackage {
    let package: PluginPackage
    if let connection = draft.connection {
      package = try await connect(connection, review: review, turnOn: false)
    } else {
      let data = try AppImport.manifest(id: draft.id, server: draft.server, tools: review)
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-import-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: folder) }
      try data.write(to: folder.appendingPathComponent(PluginManifest.fileName), options: .atomic)
      package = try install(from: folder)
    }
    states[package.id]?.imported = draft.server.source.name
    // Every tool on the card, on or off, pinned with its hints: turning it on later takes only
    // this list (`enable`), as a connection's.
    states[package.id]?.reviewed = MCPServerConnection.pins(review)
    save()
    return package
  }

  /// A picked server skipped, or closed before it was added: its secrets leave the Keychain.
  func discardImport(_ draft: ImportDraft) {
    guard !packages.contains(where: { $0.id == draft.id }) else { return }
    if let connection = draft.connection { return discard(connection) }
    for name in draft.server.envNames { Self.saveSecret(nil, plugin: draft.id, name: name) }
  }
}
