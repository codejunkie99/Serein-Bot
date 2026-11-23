import AppKit
import Combine
import Foundation
import SereinCore
import SereinEngines

/// The person's provider connections (ProviderTable rows they connected): saved in
/// `agents/providers.json`, each key in its own Keychain item, every key scrubbed from transcripts
/// and logs (FilledValues) when it is saved or first read, before any run gets it. The one place a
/// connection turns into a CLI's config or environment (ProviderRun).
@MainActor final class ProviderStore: ObservableObject {
  static let shared = ProviderStore()
  @Published private(set) var connections = ProviderConnections()
  @Published private(set) var catalog = ModelCatalog.empty
  /// Local servers found answering on their port at the last `probeLocal`.
  @Published private(set) var running: Set<String> = []
  /// Why a saved Local model is still where it was, and its model ids: the reason a saved route on
  /// one of them shows (`unmovedNote`). Nil once it moved or when there is none.
  @Published private(set) var unmoved: (note: String, models: [String])?
  private var library: Library?
  /// Full address checks (the name resolved off the main thread) by connection id, as each checks
  /// with or without a key: the refusal, or nil for a pass. A run gets a connection only while it
  /// has a verdict; `recheck` renews them every minute, when the network comes back and when the
  /// Mac wakes, and a run that finds one older than `verdictLife` uses it and starts a check. A
  /// name not found leaves no verdict. `generation` drops a check that a
  /// newer one (a connect, a later recheck) has overtaken.
  private var verdicts: [String: (refused: String?, at: Date)] = [:]
  private var generation: [String: Int] = [:]
  private static let verdictLife: TimeInterval = 180
  /// The launch work of the last `configure` (migration, first check, catalog), and its minute loop.
  private(set) var setup: Task<Void, Never>?
  private var loop: Task<Void, Never>?
  private var networkWatch: AnyCancellable?

  nonisolated static var bundledCatalog: URL? { Bundle.assets.url(forResource: "models-dev", withExtension: "json", subdirectory: "Catalog") }

  /// `background`: the daily catalog refresh and the local probe start too (not in checks,
  /// previews or the `--probe-providers` diagnostic).
  func configure(library: Library, background: Bool = !RunMode.automated) {
    // A preview's connections are its seed's (installPreview).
    guard self.library?.root != library.root, !RunMode.previewing else { return }
    self.library = library
    setup?.cancel()
    loop?.cancel()
    networkWatch = nil
    verdicts = [:]
    unmoved = nil
    connections = library.load(ProviderConnections.self, from: ProviderConnections.path) ?? ProviderConnections()
    let root = library.root
    setup = Task {
      await self.migrateLocalModel(library)
      await self.recheck()
      self.catalog = await Task.detached(priority: .utility) { ModelCatalog.load(root: root, bundled: Self.bundledCatalog) }.value
      guard background, !Task.isCancelled else { return }
      self.loop = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60_000_000_000); await self.recheck() } }
      // The minute loop does not run while the Mac sleeps, so waking checks at once.
      self.networkWatch = NetworkMonitor.shared.$online.removeDuplicates().dropFirst().filter { $0 }.map { _ in () }
        .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).map { _ in () })
        .sink { [weak self] _ in Task { await self?.recheck() } }
      // shortcut: models.dev is fetched directly (EphemeralHTTP); Serein has no app-side proxy yet.
      if await ModelCatalog.refresh(root: root) {
        self.catalog = await Task.detached(priority: .utility) { ModelCatalog.load(root: root, bundled: Self.bundledCatalog) }.value
      }
      await self.probeLocal(connect: true)
    }
  }

  /// Checks every enabled connection's address in full, together, off the main thread.
  func recheck() async {
    let targets = enabled.map { c -> (id: String, address: String, keyless: Bool, generation: Int) in
      generation[c.id, default: 0] += 1
      return (c.id, c.baseURL, c.keyless, generation[c.id]!)
    }
    await withTaskGroup(of: (String, Int, String?, Bool).self) { group in
      for t in targets {
        group.addTask {
          let checked = ProviderAddress.checkFound(t.address, place: .thisMac, keyless: t.keyless)
          return (t.id, t.generation, checked.refused, checked.found)
        }
      }
      for await (id, made, refused, found) in group where generation[id] == made {
        verdicts[id] = found ? (refused, Date()) : nil
      }
    }
  }
  /// A verdict for `id` that no check started earlier may replace.
  private func settle(_ id: String, refused: String?) {
    generation[id, default: 0] += 1
    verdicts[id] = (refused, Date())
  }

  var enabled: [ProviderConnection] { connections.connections.filter(\.enabled) }
  func connection(_ id: String) -> ProviderConnection? { connections.connections.first { $0.id == id } }

  // MARK: Keys

  /// Distinct per library, as the harness key's, so checks and previews never touch a real key.
  private func keyItem(_ id: String) -> KeychainItem {
    KeychainItem(service: "local.serein.provider-key", account: "\(library?.root.path ?? "unconfigured")#\(id)")
  }
  private static func scrub(_ key: String, _ id: String) { FilledValues.shared.add(key, task: "provider-key:" + id) }
  /// The key a run sends; the placeholder for a keyless local server.
  private func key(_ c: ProviderConnection) -> String? {
    if c.keyless { return ProviderRun.keylessValue }
    guard let key = keyItem(c.id).read() else { return nil }
    Self.scrub(key, c.id)
    return key
  }

  // MARK: Connect

  /// Checks the address, lists the provider's models with the key (the catalog's when it lists
  /// none), then saves the key in Keychain and the connection in the library.
  @discardableResult
  func connect(_ entry: ProviderEntry, fields: [ProviderField: String] = [:], key: String, directHTTP: Bool? = nil, modelID: String? = nil) async throws -> ProviderConnection {
    guard let library else { throw SereinError.invalid("Serein's library is unavailable.") }
    guard var address = entry.address(fields) else { throw SereinError.invalid("Fill in every field with letters, digits, dots or dashes.") }
    // Claude Code adds /v1 itself.
    if entry.wire == .anthropic, address.hasSuffix("/v1") { address.removeLast(3) }
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard entry.keyless || !key.isEmpty else { throw SereinError.invalid("Enter the key.") }
    let named = ProviderConnection(entry: entry, baseURL: address, models: [])
    guard !connections.connections.contains(where: { $0.id != entry.id && ($0.openCodeID == named.openCodeID || $0.keyVariable == named.keyVariable) })
    else { throw SereinError.invalid("Another connection already uses this provider's name. Remove it first.") }
    guard !key.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 } == true }), !key.contains("://") else {
      throw SereinError.invalid("That does not look like a key.")
    }
    var models: [String] = []
    if entry.lists {
      do { models = try await ProviderAPI.listModels(baseURL: address, wire: entry.wire, key: entry.keyless ? nil : key) } catch let failure as ProviderListFailure {
        throw SereinError.invalid(failure.message)
      }
    } else if let refused = await Task.detached(operation: { ProviderAddress.check(address, place: .thisMac, keyless: entry.keyless) }).value {
      throw SereinError.invalid(refused)
    }
    if models.isEmpty { models = catalog.modelIDs(entry.catalogID) }
    if let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
      guard ModelCatalog.plain(model) else { throw SereinError.invalid("Enter a valid model ID.") }
      if !models.contains(model) { models.append(model) }
    }
    var connection = ProviderConnection(entry: entry, baseURL: address, models: models)
    // A refresh of the same server keeps what the Local model moved in with.
    if let before = self.connection(entry.id), ProviderAddress.same(before.baseURL, address) {
      connection.directHTTP = before.directHTTP
      (connection.tools, connection.images, connection.localModel) = (before.tools, before.images, before.localModel)
    }
    if let directHTTP { connection.directHTTP = entry.wire == .openai && directHTTP }
    else if self.connection(entry.id) == nil { connection.directHTTP = entry.wire == .openai }
    let previous = connections
    let oldKey = entry.keyless ? nil : keyItem(entry.id).read()
    if !entry.keyless {
      guard keyItem(entry.id).replace(with: key) else { throw SereinError.invalid("Could not save the key in Keychain.") }
      Self.scrub(key, entry.id)
    }
    connections.connections.removeAll { $0.id == entry.id }
    connections.connections.append(connection)
    connections.removed?.removeAll { $0 == entry.id }
    do { try save(library) } catch {
      connections = previous
      if !entry.keyless, !keyItem(entry.id).replace(with: oldKey) {
        throw SereinError.invalid("Could not restore the provider key. Reconnect this account.")
      }
      throw error
    }
    settle(entry.id, refused: nil)
    return connection
  }

  /// Re-list the saved address with its own credential. A concurrent edit or removal wins.
  func refreshModels(_ saved: ProviderConnection) async throws {
    guard let library, connection(saved.id) == saved,
      let entry = ProviderTable.all(catalog).first(where: { $0.id == saved.id }) else {
      throw SereinError.invalid("The provider connection changed.")
    }
    var models: [String] = []
    if entry.lists {
      guard let credential = key(saved) else { throw SereinError.invalid("Reconnect this provider to restore its key.") }
      do {
        models = try await ProviderAPI.listModels(baseURL: saved.baseURL, wire: saved.wire, key: saved.keyless ? nil : credential)
      } catch let failure as ProviderListFailure { throw SereinError.invalid(failure.message) }
    }
    if models.isEmpty { models = catalog.modelIDs(saved.catalogID) }
    // Saved IDs can be manual deployment names, migrated IDs, or still referenced in chats.
    let updated = Array(Set(saved.models + models)).sorted()
    guard self.library?.root == library.root, let index = connections.connections.firstIndex(of: saved) else {
      throw SereinError.invalid("The provider connection changed.")
    }
    connections.connections[index].models = updated
    do { try save(library) } catch { connections.connections[index] = saved; throw error }
  }

  func remove(_ id: String) throws {
    let previous = connections
    let oldKey = keyItem(id).read()
    guard keyItem(id).replace(with: nil) else { throw SereinError.invalid("Could not remove the key from Keychain.") }
    connections.connections.removeAll { $0.id == id }
    generation[id, default: 0] += 1
    verdicts[id] = nil
    if ProviderTable.entries.contains(where: { $0.id == id && $0.localPort != nil }), connections.removed?.contains(id) != true {
      connections.removed = (connections.removed ?? []) + [id]
    }
    do { if let library { try save(library) } } catch {
      connections = previous
      if let oldKey, !keyItem(id).replace(with: oldKey) {
        throw SereinError.invalid("Could not restore the provider key. Reconnect this account.")
      }
      throw error
    }
  }

  /// Turns a connection off or on; its key and models stay. On, it is checked again before a run.
  func setEnabled(_ id: String, _ on: Bool) throws {
    guard let library, let i = connections.connections.firstIndex(where: { $0.id == id }) else { return }
    let before = connections.connections[i].enabled
    connections.connections[i].enabled = on
    do { try save(library) } catch { connections.connections[i].enabled = before; throw error }
    if on { Task { await recheck() } }
  }

  private func save(_ library: Library) throws {
    try FileManager.default.createDirectory(at: library.root.appendingPathComponent("agents"), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try library.save(connections, to: ProviderConnections.path)
    let registry = HarnessRegistry.shared
    Task { await registry.refresh(.opencode, force: true) }
    registry.objectWillChange.send()
  }

  /// Probes every local row's fixed port; with `connect`, a keyless server found running and not
  /// yet connected is connected (its own list, no key).
  func probeLocal(connect: Bool) async {
    let local = ProviderTable.entries.filter { $0.localPort != nil }
    var found = Set<String>()
    await withTaskGroup(of: (String, Bool).self) { group in
      for entry in local { group.addTask { (entry.id, await ProviderAPI.probe(port: entry.localPort!)) } }
      for await (id, up) in group where up { found.insert(id) }
    }
    running = found
    guard connect else { return }
    // One server is connected once, whichever row or spelling (localhost, 127.0.0.1, ::1) has it.
    for entry in local where entry.keyless && found.contains(entry.id) && connection(entry.id) == nil
      && connections.removed?.contains(entry.id) != true
      && !connections.connections.contains(where: { ProviderAddress.server($0.baseURL) == ProviderAddress.server(entry.baseURL) }) {
      _ = try? await self.connect(entry, key: "")
    }
  }

  // MARK: What a run gets

  /// What a turn on `driver` with the listed `model` gets from the table: the id the CLI takes and
  /// that model's connection alone, its key only. Nil when the model is no connection's (the
  /// harness's own sign-in and variables). Throws while the address has no fresh full check.
  func directConnection(_ driver: HarnessDriver?, model: String?) -> ProviderConnection? {
    guard driver == .opencode, let model,
      let c = ProviderRun.connection(forModel: model, wire: .openai, in: enabled),
      c.directHTTP == true else { return nil }
    return c
  }

  private func directRoute(_ c: ProviderConnection, key: String) -> DirectHTTPRoute {
    DirectHTTPRoute(connection: c, key: key) { @MainActor [weak self] in self?.connection(c.id) == c }
  }

  func testDirectHTTP(_ c: ProviderConnection, model: String) async throws {
    guard c.enabled, c.directHTTP == true, connection(c.id) == c, c.models.contains(model),
      let key = key(c) else { throw SereinError.invalid("Select a connected model first.") }
    var request = TurnRequest(thread: ThreadKey("provider-check:" + UUID().uuidString), cli: .opencode,
      executable: Bundle.main.executableURL!, access: .answer,
      prompt: TurnPrompt(stable: "", volatile: "", message: "Reply with OK.", recovery: nil),
      model: model, effort: nil, resume: nil, browser: nil, taskID: "")
    request.directHTTP = directRoute(c, key: key)
    do { _ = try await Engines.shared.ask(request) }
    catch StopReason.failed(let message) { throw SereinError.invalid(message) }
  }

  func setDirectHTTP(_ id: String, enabled: Bool) throws {
    guard let library, let i = connections.connections.firstIndex(where: { $0.id == id && $0.wire == .openai }) else { return }
    let old = connections.connections[i].directHTTP
    connections.connections[i].directHTTP = enabled
    do { try save(library) } catch { connections.connections[i].directHTTP = old; throw error }
  }

  func run(_ driver: HarnessDriver, model: String?) throws -> (model: String, environment: [String: String], direct: DirectHTTPRoute?)? {
    let wire: ProviderWire
    switch driver {
    case .opencode: wire = .openai
    case .claude: wire = .anthropic
    default: return nil
    }
    guard let model, let c = ProviderRun.connection(forModel: model, wire: wire, in: enabled) else { return nil }
    guard let verdict = verdicts[c.id] else {
      Task { await recheck() }
      throw SereinError.invalid("Serein is checking \(c.name)'s address. Send again in a moment.")
    }
    if Date().timeIntervalSince(verdict.at) >= Self.verdictLife {
      Task { await recheck() }
      // An old pass is only trusted over TLS. A plain http name can resolve elsewhere on a new network.
      if !c.baseURL.lowercased().hasPrefix("https://") {
        throw SereinError.invalid("Serein is checking \(c.name)'s address. Send again in a moment.")
      }
    }
    if let refused = verdict.refused { throw SereinError.invalid("\(c.name): \(refused)") }
    guard let key = key(c) else { throw SereinError.invalid("\(c.name)'s key is not in Keychain. Connect it again.") }
    if c.directHTTP == true, wire == .openai {
      let prefix = c.openCodeID + "/"
      let nativeID = model.hasPrefix(prefix) ? String(model.dropFirst(prefix.count)) : model
      return (nativeID, [:], directRoute(c, key: key))
    }
    if wire == .anthropic { return (ProviderRun.cliModel(model, of: c), ProviderRun.claudeEnvironment(c, key: key), nil) }
    guard let config = ProviderRun.openCodeConfig([c]) else { return nil }
    return (ProviderRun.cliModel(model, of: c), ["OPENCODE_CONFIG_CONTENT": config, c.keyVariable: key], nil)
  }
  /// OpenCode's probe: every connection's block, no key. It lists the declared models without one.
  func openCodeProbeEnvironment() -> [String: String] {
    ProviderRun.openCodeConfig(enabled).map { ["OPENCODE_CONFIG_CONTENT": $0] } ?? [:]
  }
  /// Why a saved Local model route on `model` gets no connection: its Local model was not moved.
  func unmovedNote(model: String) -> String? {
    unmoved.flatMap { $0.models.contains(model) ? $0.note : nil }
  }
  /// The Anthropic-wire connections' models for Claude Code's list, beside its own.
  var claudeModels: [HarnessModel] {
    enabled.filter { $0.wire == .anthropic }.flatMap { c in c.models.map { HarnessModel(id: c.openCodeID + "/" + $0, name: $0) } }
  }

  /// Catalog facts and a one-line blurb on a model OpenCode lists for a connection.
  func decorate(_ models: [HarnessModel], driver: HarnessDriver) -> [HarnessModel] {
    models.map { model in
      var model = model
      guard driver == .claude || driver == .opencode,
        let c = ProviderRun.connection(forModel: model.id, wire: driver == .claude ? .anthropic : .openai, in: enabled)
      else { return model }
      let id = String(model.id.drop { $0 != "/" }.dropFirst())
      model.subProvider = c.name
      model.facts = catalog.facts(provider: c.catalogID, model: id)
      if model.blurb.isEmpty { model.blurb = model.facts.map(Self.blurb) ?? c.name }
      return model
    }
  }
  static func blurb(_ f: ModelFacts) -> String {
    var parts: [String] = []
    if let context = f.context { parts.append(context >= 1_000_000 ? "\(context / 1_000_000)M context" : "\(context / 1_000)K context") }
    if f.vision { parts.append("pictures") }
    if f.reasoning { parts.append("reasoning") }
    if let input = f.input, let output = f.output { parts.append(String(format: "$%.2f / $%.2f per M", input, output)) }
    return parts.joined(separator: " · ")
  }

  // MARK: Previews

  /// UI previews (`--ui-providers <seed>`, default `mixed`): fixed connections, no Keychain, no
  /// file, no network. `none`: nothing connected. `local`: Ollama found running and connected,
  /// LM Studio running but not connected. `mixed`: `local` plus OpenRouter with a key and an
  /// Anthropic-compatible endpoint for Claude Code.
  func installPreview(_ seed: String) {
    func row(_ id: String) -> ProviderEntry { ProviderTable.entries.first { $0.id == id }! }
    let ollama = ProviderConnection(entry: row("ollama"), baseURL: row("ollama").baseURL, models: ["llama3.2", "qwen3-coder:30b"])
    let openrouter = ProviderConnection(entry: row("openrouter"), baseURL: row("openrouter").baseURL,
                                        models: ["anthropic/claude-sonnet-4.5", "openai/gpt-5", "deepseek/deepseek-chat-v3.1"])
    let anthropic = ProviderConnection(entry: row("custom-anthropic"), baseURL: "https://anthropic-proxy.example.com", models: ["preview-sonnet"])
    switch seed {
    case "none": connections = ProviderConnections(); running = []
    case "local": connections = ProviderConnections(connections: [ollama]); running = ["ollama", "lmstudio"]
    default: connections = ProviderConnections(connections: [ollama, openrouter, anthropic]); running = ["ollama", "lmstudio"]
    }
    catalog = ModelCatalog.load(root: URL(fileURLWithPath: "/nonexistent"), bundled: Self.bundledCatalog)
  }
  /// What OpenCode would list for the previewed connections (its probe never runs in a preview).
  var previewOpenCodeModels: [HarnessModel] {
    enabled.filter { $0.wire == .openai }.flatMap { c in c.models.map { HarnessModel(id: c.openCodeID + "/" + $0, name: $0) } }
  }

  // MARK: Moves from before the table

  /// The single Local model (agents/local-model.json, key `local.serein.inference`) becomes a
  /// connection in the local section, run through OpenCode, enabled as it was, with its tools and
  /// images switches. The old file and key go only once the connection is saved; an address the
  /// full check refuses, a key Keychain would not give, or a row already connected to another
  /// server leaves both where they were, says why on its saved routes (`unmoved`) and is tried
  /// again at the next launch.
  private func migrateLocalModel(_ library: Library) async {
    let file = library.root.appendingPathComponent("agents/local-model.json")
    guard let old = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { return }
    let models = ([old["model"] as? String ?? ""] + (old["models"] as? [String] ?? [])).filter { !$0.isEmpty }
    // The Local model's own rule: an empty path means /v1.
    let typed = (old["endpoint"] as? String ?? "http://127.0.0.1:11434/v1").trimmingCharacters(in: .whitespaces)
    var parts = URLComponents(string: typed)
    let path = parts?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
    parts?.path = path.isEmpty ? "/v1" : "/" + path
    guard let parts, let endpoint = parts.string else {
      unmoved = ("Your Local model was not moved: its address is not valid.", models)
      return
    }
    // Host and port only: a saved address may carry a user name or a query.
    let shown = parts.host.map { host in parts.port.map { "\(host):\($0)" } ?? host } ?? "its address"
    func keep(_ why: String) { unmoved = ("Your Local model at \(shown) was not moved: \(why)", models) }
    let oldKey = KeychainItem(service: "local.serein.inference", account: library.root.path)
    let key = oldKey.read() ?? ""
    guard !key.isEmpty || !oldKey.mayExist else { return keep("Serein could not read its key from Keychain.") }
    if let refused = await Task.detached(operation: { ProviderAddress.check(endpoint, place: .thisMac, keyless: key.isEmpty) }).value {
      return keep(refused)
    }
    let entry = ProviderTable.entries.first { $0.localPort != nil && ProviderAddress.same($0.baseURL, endpoint) }
      ?? ProviderTable.entries.first { $0.id == "custom-openai" }!
    let fresh = connection(entry.id) == nil
    var c = connection(entry.id) ?? ProviderConnection(entry: entry, baseURL: endpoint, models: [], enabled: old["enabled"] as? Bool == true)
    // Another server on that row keeps its key; the Local model's stays too.
    guard fresh || ProviderAddress.same(c.baseURL, endpoint) else { return keep("\(entry.name) is already connected to another address.") }
    for model in models where !c.models.contains(model) { c.models.append(model) }
    (c.tools, c.images, c.localModel) = (c.tools ?? (old["tools"] as? Bool), c.images ?? (old["images"] as? Bool), true)
    if fresh {
      c.keyless = key.isEmpty
      if !key.isEmpty {
        guard keyItem(entry.id).replace(with: key) else { return keep("Serein could not save its key in Keychain.") }
        Self.scrub(key, entry.id)
      }
    }
    let before = connections
    connections.connections.removeAll { $0.id == entry.id }
    connections.connections.append(c)
    do { try save(library) } catch {
      connections = before
      return keep("Serein could not save the connection.")
    }
    unmoved = nil
    oldKey.replace(with: nil)
    try? FileManager.default.removeItem(at: file)
  }
}
