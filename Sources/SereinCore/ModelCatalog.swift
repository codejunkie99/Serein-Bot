import Foundation

/// What the picker shows beside a model: from models.dev (MIT, bundled as Catalog/models-dev.json
/// with its license; THIRD_PARTY_NOTICES.md).
public struct ModelFacts: Codable, Equatable, Sendable {
  public var tools: Bool
  public var vision: Bool
  public var reasoning: Bool
  public var context: Int?
  /// US dollars per million tokens.
  public var input: Double?
  public var output: Double?
  public var released: String?
  public init(tools: Bool = true, vision: Bool = false, reasoning: Bool = false, context: Int? = nil,
              input: Double? = nil, output: Double? = nil, released: String? = nil) {
    self.tools = tools
    self.vision = vision
    self.reasoning = reasoning
    self.context = context
    self.input = input
    self.output = output
    self.released = released
  }
}

/// The models.dev catalog, trimmed to tool-capable text models. Read from the daily copy in
/// Serein's library (`refresh`) when it decodes, else from the bundled snapshot.
public struct ModelCatalog: Sendable {
  public struct Model: Sendable {
    public var name: String
    public var facts: ModelFacts
  }
  public struct Provider: Sendable {
    public var name: String
    public var api: String?
    public var doc: String?
    public var npm: String?
    public var models: [String: Model]
  }
  public var providers: [String: Provider]
  /// Where it came from: "bundled" or "library".
  public var source: String

  public static let empty = ModelCatalog(providers: [:], source: "none")
  static let maxProviders = 2_000
  static let maxModels = 5_000

  /// models.dev's own shape. A row that is not a tool-capable text model, has an id that is not
  /// plain text, or goes past the caps is dropped: the file comes from the internet.
  public static func decode(_ data: Data, source: String) -> ModelCatalog? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var providers: [String: Provider] = [:]
    for (id, value) in root.sorted(by: { $0.key < $1.key }) where providers.count < maxProviders && plain(id) {
      guard let row = value as? [String: Any], let name = row["name"] as? String, plain(name) else { continue }
      var models: [String: Model] = [:]
      for (modelID, raw) in (row["models"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key })
      where models.count < maxModels && plain(modelID) {
        guard let m = raw as? [String: Any], m["tool_call"] as? Bool == true, m["status"] as? String != "deprecated",
          ((m["modalities"] as? [String: Any])?["input"] as? [String] ?? ["text"]).contains("text")
        else { continue }
        let cost = m["cost"] as? [String: Any]
        let input = (m["modalities"] as? [String: Any])?["input"] as? [String] ?? []
        let facts = ModelFacts(
          tools: true, vision: m["attachment"] as? Bool == true || input.contains("image"), reasoning: m["reasoning"] as? Bool == true,
          context: ((m["limit"] as? [String: Any])?["context"] as? NSNumber)?.intValue,
          input: (cost?["input"] as? NSNumber)?.doubleValue, output: (cost?["output"] as? NSNumber)?.doubleValue,
          released: (m["release_date"] as? String).flatMap { plain($0) ? $0 : nil })
        models[modelID] = Model(name: (m["name"] as? String).flatMap { plain($0) ? $0 : nil } ?? modelID, facts: facts)
      }
      guard !models.isEmpty else { continue }
      let api = (row["api"] as? String).flatMap { plain($0) ? $0 : nil }
      providers[id] = Provider(name: name, api: api, doc: (row["doc"] as? String).flatMap { plain($0) ? $0 : nil },
                               npm: row["npm"] as? String, models: models)
    }
    return providers.isEmpty ? nil : ModelCatalog(providers: providers, source: source)
  }
  /// No braces or `$` (a template or variable would expand in a CLI's config), no control
  /// characters, a sane length.
  public static func plain(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 256 && !text.contains { "{}$".contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }
  }

  public func facts(provider: String?, model: String) -> ModelFacts? {
    guard let provider else { return nil }
    let models = providers[provider]?.models
    return (models?[model] ?? models?[model.split(separator: "/").last.map(String.init) ?? model])?.facts
  }
  /// The provider's models, newest first: the stand-in when its own list says nothing.
  public func modelIDs(_ provider: String?) -> [String] {
    guard let models = provider.flatMap({ providers[$0]?.models }) else { return [] }
    return models.sorted { ($0.value.facts.released ?? "", $1.key) > ($1.value.facts.released ?? "", $0.key) }.map(\.key)
  }
  public var modelCount: Int { providers.values.reduce(0) { $0 + $1.models.count } }

  // MARK: Daily refresh

  public static let source = URL(string: "https://models.dev/api.json")!
  static let maxBytes = 20 << 20
  static let refreshEvery: TimeInterval = 24 * 3600
  public static func file(_ root: URL) -> URL { root.appendingPathComponent("providers/models-dev.json") }
  static func tagFile(_ root: URL) -> URL { root.appendingPathComponent("providers/models-dev.etag") }

  /// The library's copy when it decodes, else the bundled snapshot.
  public static func load(root: URL, bundled: URL?) -> ModelCatalog {
    if let data = try? Data(contentsOf: file(root)), let catalog = decode(data, source: "library") { return catalog }
    if let bundled, let data = try? Data(contentsOf: bundled), let catalog = decode(data, source: "bundled") { return catalog }
    return .empty
  }

  /// Fetches models.dev at most once a day (ETag, 10 s, 20 MB cap, no cookies or redirects) and
  /// keeps the trimmed result in the library. True when a new copy was written. Sends nothing but
  /// the request itself: no key, no account.
  @discardableResult
  public static func refresh(root: URL, now: Date = Date()) async -> Bool {
    let target = file(root)
    let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    if let modified, now.timeIntervalSince(modified) < refreshEvery { return false }
    var request = URLRequest(url: source, timeoutInterval: 10)
    request.setValue("Serein", forHTTPHeaderField: "User-Agent")
    if modified != nil, let tag = try? String(contentsOf: tagFile(root), encoding: .utf8) {
      request.setValue(tag, forHTTPHeaderField: "If-None-Match")
    }
    guard let (bytes, response) = try? await EphemeralHTTP.session(resourceTimeout: 10).bytes(for: request),
      let http = response as? HTTPURLResponse
    else { return false }
    if http.statusCode == 304 {
      try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
      return false
    }
    guard http.statusCode == 200, http.expectedContentLength <= Int64(maxBytes) else { return false }
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count > maxBytes { return false }
      }
    } catch { return false }
    guard let catalog = decode(data, source: "library") else { return false }
    do {
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try catalog.encoded().write(to: target, options: .atomic)
      try? (http.value(forHTTPHeaderField: "ETag") ?? "").write(to: tagFile(root), atomically: true, encoding: .utf8)
      return true
    } catch { return false }
  }

  /// The trimmed catalog in models.dev's shape, so `decode` reads it back.
  public func encoded() throws -> Data {
    var root: [String: Any] = [:]
    for (id, p) in providers {
      var models: [String: Any] = [:]
      for (modelID, m) in p.models {
        var row: [String: Any] = [
          "name": m.name, "tool_call": true, "attachment": m.facts.vision, "reasoning": m.facts.reasoning,
          "modalities": ["input": m.facts.vision ? ["text", "image"] : ["text"]],
        ]
        if let context = m.facts.context { row["limit"] = ["context": context] }
        var cost: [String: Any] = [:]
        cost["input"] = m.facts.input
        cost["output"] = m.facts.output
        if !cost.isEmpty { row["cost"] = cost }
        row["release_date"] = m.facts.released
        models[modelID] = row
      }
      var row: [String: Any] = ["name": p.name, "models": models]
      row["api"] = p.api
      row["doc"] = p.doc
      row["npm"] = p.npm
      root[id] = row
    }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }
}
