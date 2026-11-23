import Foundation

/// The day Serein first saw each model in each harness's list, so a model a provider adds later
/// shows as New for two weeks. A harness's first list is the baseline:
/// nothing in it is new. So is every model of a provider a router (OpenCode, Pi) connects later:
/// those models are not new, only new to this Mac. An empty list (signed out, a failed probe)
/// changes nothing. Model ids are never removed, so a model that comes back is not new again.
public struct ModelWatch: Codable, Equatable, Sendable {
  public static let path = "agents/model-watch.json"
  public static let newFor: TimeInterval = 14 * 24 * 3600
  /// Harness → model id → first seen.
  public private(set) var firstSeen: [String: [String: Date]] = [:]
  public init() {}

  /// Records a harness's current list and returns the ids that arrived since the last one.
  public mutating func record(_ harness: String, ids: [String], now: Date) -> [String] {
    var unique = Set<String>()
    let ids = ids.filter { !$0.isEmpty && unique.insert($0).inserted }
    guard !ids.isEmpty else { return [] }
    let known = firstSeen[harness]
    var seen = known ?? [:]
    let groups = Set(seen.keys.map(Self.group))
    var arrived: [String] = []
    for id in ids where seen[id] == nil {
      if known == nil || !groups.contains(Self.group(id)) {
        seen[id] = .distantPast
      } else {
        seen[id] = now
        arrived.append(id)
      }
    }
    firstSeen[harness] = seen
    return arrived
  }

  public func isNew(_ harness: String, _ id: String, now: Date) -> Bool {
    guard let first = firstSeen[harness]?[id] else { return false }
    return now.timeIntervalSince(first) < Self.newFor
  }

  /// The upstream provider of a router's "provider/model" id; "" for a plain id.
  static func group(_ id: String) -> String {
    id.contains("/") ? String(id.prefix { $0 != "/" }) : ""
  }
}

/// What a harness keeps on this Mac about its models, read without starting it: the file that
/// lists its models (read for model ids only, so a rewrite with the same models is no change),
/// and the file where its own update check records the newest release. nil where it keeps none.
public enum ModelSources {
  public static func files(_ driver: HarnessDriver, environment: [String: String], home: String)
    -> (models: String?, latest: String?)
  {
    func folder(_ variable: String, _ fallback: String) -> String {
      environment[variable].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallback
    }
    switch driver {
    case .codex:
      let codex = CodexChecks.codexHome(environment: environment, home: home)
      return (codex.appendingPathComponent("models_cache.json").path, codex.appendingPathComponent("version.json").path)
    case .grok: return (home + "/.grok/models_cache.json", home + "/.grok/version.json")
    case .opencode: return (folder("XDG_CACHE_HOME", home + "/.cache") + "/opencode/models.json", nil)
    case .pi: return (folder("PI_CODING_AGENT_DIR", home + "/.pi/agent") + "/models-store.json", nil)
    // Gemini CLI keeps its files under ~/.gemini; Serein reads no model or sign-in file there.
    case .claude, .cursor, .ohMyPi, .gemini: return (nil, nil)
    }
  }
  /// The file an app rewrites when it signs in or out, wherever that happens: a change re-checks
  /// it so Settings and the picker update on screen. Only its size and date are read, never its
  /// contents. nil for an app whose sign-in lives elsewhere (Keychain, its own app).
  public static func signInFile(_ driver: HarnessDriver, environment: [String: String], home: String) -> String? {
    func folder(_ variable: String, _ fallback: String) -> String {
      environment[variable].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallback
    }
    switch driver {
    case .opencode: return folder("XDG_DATA_HOME", home + "/.local/share") + "/opencode/auth.json"
    case .grok: return folder("GROK_HOME", home + "/.grok") + "/auth.json"
    case .claude, .codex, .cursor, .pi, .ohMyPi, .gemini: return nil
    }
  }
  /// Codex: `{"models": [{"slug"}]}`. Grok: `{"models": {id: …}}`. OpenCode (models.dev):
  /// `{provider: {"models": {id: …}}}` as "provider/id".
  public static func ids(_ driver: HarnessDriver, _ data: Data) -> [String] {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    switch driver {
    case .codex: return ((json["models"] as? [[String: Any]]) ?? []).compactMap { $0["slug"] as? String }.sorted()
    case .grok: return ((json["models"] as? [String: Any]) ?? [:]).keys.sorted()
    // Pi: `{provider: {"models": [{"id"}], "etag", "checkedAt"}}`.
    case .pi:
      return json.flatMap { provider, value -> [String] in
        let models = (value as? [String: Any])?["models"]
        let ids = (models as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? (models as? [String: Any]).map { Array($0.keys) } ?? []
        return ids.map { provider + "/" + $0 }
      }.sorted()
    case .opencode:
      return json.flatMap { provider, value in
        (((value as? [String: Any])?["models"] as? [String: Any]) ?? [:]).keys.map { provider + "/" + $0 }
      }.sorted()
    default: return []
    }
  }
  /// Codex: `{"latest_version"}`. Grok: `{"version", "stable_version"}`.
  public static func latest(_ driver: HarnessDriver, _ data: Data) -> String? {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let raw: Any? =
      switch driver {
      case .codex: json["latest_version"]
      case .grok: json["stable_version"] as? String ?? json["version"]
      default: nil
      }
    return (raw as? String).flatMap(HarnessParse.version)
  }
}
