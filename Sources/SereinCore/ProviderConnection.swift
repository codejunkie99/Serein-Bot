import Foundation

/// A provider the person connected: the table row, its filled address and the models it lists.
/// Saved in `agents/providers.json`; the key is only in Keychain (ProviderStore).
public struct ProviderConnection: Codable, Equatable, Identifiable, Sendable {
  /// The table row's id (ProviderEntry.id): one connection per row.
  public var id: String
  public var name: String
  public var wire: ProviderWire
  public var baseURL: String
  public var catalogID: String?
  public var keyless: Bool
  public var models: [String]
  public var enabled: Bool
  /// The old Local model's switches, carried by its migration (nil: OpenCode's defaults): false
  /// tools turns tool calls off for every model, `images` lets pictures in or keeps them out.
  public var tools: Bool?
  public var images: Bool?
  /// The connection the old Local model moved into: a bare model id a saved route carries runs here
  /// and nowhere else (ProviderRun.connection).
  public var localModel: Bool?
  /// Explicit opt-in for direct Chat Completions on this connection.
  public var directHTTP: Bool?
  public init(entry: ProviderEntry, baseURL: String, models: [String], enabled: Bool = true) {
    id = entry.id
    name = entry.name
    wire = entry.wire
    self.baseURL = baseURL
    catalogID = entry.catalogID
    keyless = entry.keyless
    self.models = models
    self.enabled = enabled
  }
  /// The OpenCode provider id (also the prefix of the connection's models in any harness's list)
  /// and the variable its key rides in. Only ASCII letters, digits and dashes, so neither can carry
  /// a config template; ProviderStore.connect refuses a second row that maps to the same names.
  public var openCodeID: String { "serein-" + id.lowercased().map { Self.plain($0) ? String($0) : "-" }.joined() }
  public var keyVariable: String {
    "SEREIN_" + id.uppercased().map { Self.plain($0) ? String($0) : "_" }.joined() + "_API_KEY"
  }
  private static func plain(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
  /// Official Anthropic takes its key as ANTHROPIC_API_KEY; any other Anthropic-compatible address
  /// as a bearer token beside its base URL.
  public var isOfficialAnthropic: Bool { URL(string: baseURL)?.host == "api.anthropic.com" }
}

public struct ProviderConnections: Codable, Equatable, Sendable {
  public static let path = "agents/providers.json"
  public var connections: [ProviderConnection] = []
  /// Local rows the person removed: the probe never connects them again (ProviderStore.probeLocal).
  public var removed: [String]? = nil
  public init(connections: [ProviderConnection] = []) { self.connections = connections }
}

/// Why a live model list failed. Raw errors never surface: they can echo the address or the key.
public enum ProviderListFailure: Error, Equatable, Sendable {
  case refused(String)
  case rejected(Int)
  case unreachable
  case unexpected(Int?)
  public var message: String {
    switch self {
    case .refused(let why): return why
    case .rejected(let status): return "The provider refused the key (\(status)). Check it and try again."
    case .unreachable: return "The provider could not be reached."
    case .unexpected(let status): return "The provider answered in a way Serein does not read\(status.map { " (\($0))" } ?? "")."
    }
  }
}

public enum ProviderAPI {
  /// The provider's own model list: GET {base}/models, or Anthropic's /v1/models. 8 s, no
  /// redirects, no cookies. The address passes `ProviderAddress.check` first, so the key never goes
  /// where it may not.
  public static func listModels(baseURL: String, wire: ProviderWire, key: String?, place: ProviderAddress.Place = .thisMac) async throws -> [String] {
    if let refused = await Task.detached(operation: { ProviderAddress.check(baseURL, place: place, keyless: key?.isEmpty ?? true) }).value {
      throw ProviderListFailure.refused(refused)
    }
    guard let request = modelsRequest(baseURL: baseURL, wire: wire, key: key, timeout: 8) else {
      throw ProviderListFailure.refused("Enter the full address.")
    }
    let data: Data
    let response: URLResponse
    do { (data, response) = try await EphemeralHTTP.session(resourceTimeout: 8).data(for: request) } catch {
      throw ProviderListFailure.unreachable
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 || status == 403 { throw ProviderListFailure.rejected(status) }
    guard (200..<300).contains(status) else { throw ProviderListFailure.unexpected(status) }
    guard let ids = modelIDs(data) else { throw ProviderListFailure.unexpected(nil) }
    return ids
  }

  static func modelsRequest(baseURL: String, wire: ProviderWire, key: String?, timeout: TimeInterval) -> URLRequest? {
    var base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    if wire == .anthropic, base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
    guard let url = URL(string: base + (wire == .anthropic ? "/v1/models?limit=1000" : "/models")) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    if let key, !key.isEmpty {
      request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
      if wire == .anthropic { request.setValue(key, forHTTPHeaderField: "x-api-key") }
    }
    if wire == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
    return request
  }

  /// Ids from `data` or `models`, each row's `id` or `name`; `models/` stripped, plain text only,
  /// duplicates dropped, at most 2,000. Nil when the body is not that JSON.
  static func modelIDs(_ data: Data) -> [String]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = (root["data"] ?? root["models"]) as? [[String: Any]]
    else { return nil }
    var seen = Set<String>()
    return rows.compactMap { row -> String? in
      guard var id = (row["id"] ?? row["name"]) as? String else { return nil }
      if id.hasPrefix("models/") { id.removeFirst(7) }
      return ModelCatalog.plain(id) && seen.insert(id).inserted ? id : nil
    }.prefix(2_000).map { $0 }
  }

  /// Whether a server answers on this Mac's port: 2xx, 401 or 403 to its model list within
  /// 700 ms. The body is not read.
  public static func probe(port: Int) async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return false }
    guard let (_, response) = try? await EphemeralHTTP.session(resourceTimeout: 0.7).data(for: URLRequest(url: url, timeoutInterval: 0.7)),
      let status = (response as? HTTPURLResponse)?.statusCode
    else { return false }
    return (200..<300).contains(status) || status == 401 || status == 403
  }
}

/// The one owner of how a connection reaches a CLI: what OpenCode's config and Claude Code's
/// environment get. Pure, so the diagnostic prints exactly what a run gets.
public enum ProviderRun {
  /// What a keyless local server gets as its key, so OpenCode always has a bearer value.
  public static let keylessValue = "serein-local"

  /// OpenCode's `provider` block (the legacy shape 2.2.4 still reads and migrates). The key is
  /// named by its variable, never written here: this text rides in OPENCODE_CONFIG_CONTENT.
  public static func openCodeProviders(_ connections: [ProviderConnection], place: ProviderAddress.Place = .thisMac) -> [String: Any] {
    var block: [String: Any] = [:]
    for c in connections where c.enabled && c.wire == .openai && ProviderAddress.syntax(c.baseURL, place: place, keyless: c.keyless) == nil
      && ModelCatalog.plain(c.baseURL) {
      let models = c.models.filter(ModelCatalog.plain)
      guard !models.isEmpty else { continue }
      block[c.openCodeID] = [
        "name": c.name, "npm": "@ai-sdk/openai-compatible", "env": [c.keyVariable],
        "options": ["baseURL": c.baseURL],
        "models": Dictionary(uniqueKeysWithValues: models.map { id -> (String, [String: Any]) in
          var model: [String: Any] = ["name": id]
          // OpenCode 2.2.4's model fields (its config schema): tool_call and attachment, both booleans.
          if c.tools == false { model["tool_call"] = false }
          if let images = c.images { model["attachment"] = images }
          return (id, model)
        }),
      ]
    }
    return block
  }
  public static func openCodeConfig(_ connections: [ProviderConnection], place: ProviderAddress.Place = .thisMac) -> String? {
    let block = openCodeProviders(connections, place: place)
    guard !block.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["provider": block], options: [.sortedKeys]) else {
      return nil
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// Claude Code's variables for a turn on one of `connection`'s models. Every other Claude Code
  /// turn keeps the person's own sign-in and variables.
  public static func claudeEnvironment(_ connection: ProviderConnection, key: String) -> [String: String] {
    [connection.isOfficialAnthropic ? "ANTHROPIC_API_KEY" : "ANTHROPIC_AUTH_TOKEN": key, "ANTHROPIC_BASE_URL": connection.baseURL]
  }
  /// The variables that choose where Claude Code sends a turn and with what sign-in. A turn on a
  /// connection's model gets none of them but the connection's own (TurnRequest.providerTurn).
  public static func routesClaude(_ name: String) -> Bool {
    name.hasPrefix("ANTHROPIC_") || name.hasPrefix("CLAUDE_CODE_USE_") || name.hasPrefix("AWS_")
  }

  /// The enabled connection on `wire` a listed model id belongs to: `serein-<row>/<model>`, or for
  /// OpenCode a bare id the Local model saved before the table, on the connection it moved into
  /// only (OpenCode's own ids always carry a provider). Nil for a harness's own model.
  public static func connection(forModel id: String, wire: ProviderWire, in connections: [ProviderConnection]) -> ProviderConnection? {
    let candidates = connections.filter {
      $0.enabled && $0.wire == wire && ProviderAddress.syntax($0.baseURL, place: .thisMac, keyless: $0.keyless) == nil
    }
    if let slash = id.firstIndex(of: "/"), id[..<slash].hasPrefix("serein-"),
      let owner = connections.first(where: { $0.openCodeID == id[..<slash] }) {
      return candidates.first { $0.id == owner.id }
    }
    return wire == .openai ? candidates.first { $0.localModel == true && $0.models.contains(id) } : nil
  }
  /// The model id the CLI takes: OpenCode the prefixed id, Claude Code the provider's own.
  public static func cliModel(_ id: String, of connection: ProviderConnection) -> String {
    let prefix = connection.openCodeID + "/"
    let own = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    return connection.wire == .openai ? prefix + own : own
  }
}
