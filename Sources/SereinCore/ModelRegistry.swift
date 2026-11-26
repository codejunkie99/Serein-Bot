import Foundation

/// Every route the person's connected AI apps offer, with what Serein has seen of the usage each
/// provider has left. Hidden: never shown to the person. Rows are the model list's own
/// `ModelRoute`s; the only new state is `UsageTally`.
public struct ModelRegistry: Equatable, Sendable {
  /// What a provider has left, by its own count only. A plan signed in through its CLI (Claude,
  /// Codex) publishes no count, so it stays `unknown` until it refuses.
  public enum Remaining: Equatable, Sendable {
    case unknown
    /// The share left, 0 to 1: OpenRouter's key, or a response's rate-limit headers.
    case fraction(Double)
    /// It refused at its usage limit, until this time.
    case limited(until: Date)
  }
  public struct Row: Equatable, Sendable {
    /// The engine (`route.provider`), the model id, capabilities and who pays.
    public var route: ModelRoute
    /// Who serves the model and counts its usage: the provider connection the model belongs to
    /// ("openrouter"), else the engine itself.
    public var provider: String
    public var remaining: Remaining
    /// Tokens the provider's own reports counted for Serein in the last `UsageTally.spendLife`.
    public var tokens5h: Int
    /// The same, for this model alone (`UsageTally.modelKey`).
    public var modelTokens5h: Int
    public init(route: ModelRoute, provider: String, remaining: Remaining, tokens5h: Int = 0, modelTokens5h: Int = 0) {
      self.route = route
      self.provider = provider
      self.remaining = remaining
      self.tokens5h = tokens5h
      self.modelTokens5h = modelTokens5h
    }
    /// The share left that orders a pick: its provider's own count, or all of it while nothing
    /// said otherwise (a plan publishes no count until it refuses).
    var left: Double {
      if case .fraction(let share) = remaining { return share }
      return 1
    }
  }
  public struct Need: Equatable, Sendable {
    public var tools: Bool
    public var vision: Bool
    public init(tools: Bool = false, vision: Bool = false) {
      self.tools = tools
      self.vision = vision
    }
  }
  /// Seats run as delegated runs, and at most three of those work at once (`agent_start`).
  public static let widthCap = 3
  /// Different providers are the point of side-by-side seats, and two spread one plan's usage.
  public static let perProvider = 2

  public var rows: [Row]
  public init(rows: [Row]) { self.rows = rows }

  /// `routes` as rows at `now`. `provider` names who counts a route's usage. `limited` and
  /// `failed` are the orchestrator's engines by id, until when: a limited engine's routes read as
  /// limited, and a failed engine's routes cannot answer now, as a signed-out one cannot.
  public static func build(routes: [ModelRoute], provider: (ModelRoute) -> String, tally: UsageTally,
                           limited: [String: Date], failed: [String: Date], now: Date) -> ModelRegistry {
    ModelRegistry(rows: routes.map { route in
      var route = route
      if route.reason == nil, let until = failed[route.provider], until > now { route.reason = "It failed a turn just now." }
      let who = provider(route)
      var remaining = tally.remaining(who, now: now)
      if let until = limited[route.provider], until > now {
        if case .limited(let counted) = remaining { remaining = .limited(until: max(counted, until)) } else { remaining = .limited(until: until) }
      }
      return Row(route: route, provider: who, remaining: remaining, tokens5h: tally.tokens(who, now: now),
                 modelTokens5h: tally.tokens(UsageTally.modelKey(who, route.model), now: now))
    })
  }

  /// Up to `width` routes (at most `widthCap`) for seats that run side by side, never one route
  /// twice. It keeps routes that can answer now, meet `need`, and are neither limited nor out of
  /// usage; orders them free, then a plan, then a route that bills each use, then most usage left,
  /// then fewest tokens spent lately by the provider and then by the model, keeping the rows'
  /// order otherwise; and takes one route per provider before a second from any, and at most
  /// `perProvider` from one. Fewer usable routes than asked returns fewer.
  public func pick(need: Need, width: Int) -> [ModelRoute] {
    let wanted = min(max(width, 0), Self.widthCap)
    let ordered = rows.filter { $0.usable(need) }.enumerated().sorted {
      let (a, b) = ($0.element, $1.element)
      return (Self.costRank(a.route), -a.left, a.tokens5h, a.modelTokens5h, $0.offset)
        < (Self.costRank(b.route), -b.left, b.tokens5h, b.modelTokens5h, $1.offset)
    }.map(\.element)
    var picked: [Row] = []
    var providers: Set<String> = []
    for row in ordered where picked.count < wanted && providers.insert(row.provider).inserted { picked.append(row) }
    for row in ordered where picked.count < wanted && !picked.contains(where: { $0.route.id == row.route.id })
      && picked.filter({ $0.provider == row.provider }).count < Self.perProvider { picked.append(row) }
    return picked.map(\.route)
  }

  /// `ModelFallback.elsewhere`'s order: free, then a plan, then the person's key.
  static func costRank(_ route: ModelRoute) -> Int {
    if LimitFailover.billsEachUse(route) { return 2 }
    return route.costClass == .free ? 0 : 1
  }
}

extension ModelRegistry.Row {
  func usable(_ need: ModelRegistry.Need) -> Bool {
    guard route.installed, route.selectable, !need.tools || route.caps.contains(.tools),
      !need.vision || route.caps.contains(.vision) else { return false }
    switch remaining {
    case .unknown: return true
    case .fraction(let left): return left > 0
    case .limited: return false
    }
  }
}

/// What real signals said about each provider's usage, by `ModelRegistry.Row.provider`: its own
/// count of what is left, its last refusal, and the tokens its reports counted. Kept in `relay/usage-tally.json`, updated when a
/// turn ends (a refusal included), never on a timer.
public struct UsageTally: Codable, Equatable, Sendable {
  public struct Count: Codable, Equatable, Sendable {
    public var share: Double
    public var at: Date
  }
  public struct Spend: Codable, Equatable, Sendable {
    public var tokens: Int
    public var at: Date
  }
  public struct Entry: Codable, Equatable, Sendable {
    public var left: Count?
    public var spent: [Spend] = []
    public var limitedUntil: Date?
    /// When the last read of the provider's own count started (`claimRead`).
    public var readAt: Date?
  }
  public private(set) var entries: [String: Entry] = [:]
  public init() {}

  /// Rate-limit headers count per-minute windows and the key read comes at most this often, so an
  /// older count says nothing.
  public static let countLife: TimeInterval = 10 * 60
  public static let readEvery: TimeInterval = 10 * 60
  /// A plan's shortest usage window.
  public static let spendLife: TimeInterval = 5 * 60 * 60

  public mutating func noteLeft(_ provider: String, _ share: Double, at: Date) {
    guard share.isFinite else { return }
    entries[provider, default: Entry()].left = Count(share: min(max(share, 0), 1), at: at)
  }
  /// Tokens a turn's own report counted (a CLI's usage, ACP `usage_update`); older spends drop.
  public mutating func noteSpent(_ provider: String, _ tokens: Int, at: Date) {
    guard tokens > 0 else { return }
    var entry = entries[provider, default: Entry()]
    entry.spent = entry.spent.filter { at.timeIntervalSince($0.at) < Self.spendLife } + [Spend(tokens: tokens, at: at)]
    entries[provider] = entry
  }
  /// The key one model's spend is kept under, beside its provider's (`noteSpent`).
  public static func modelKey(_ provider: String, _ model: String) -> String { provider + "|" + model }
  public func tokens(_ provider: String, now: Date) -> Int {
    (entries[provider]?.spent ?? []).filter { $0.at <= now && now.timeIntervalSince($0.at) < Self.spendLife }.reduce(0) { $0 + $1.tokens }
  }
  /// A refusal at the limit; with no reset named, it counts for `LimitFailover.unknownResetWait`.
  public mutating func noteLimited(_ provider: String, _ limit: UsageLimit, at: Date) {
    entries[provider, default: Entry()].limitedUntil = limit.resetsAt ?? at.addingTimeInterval(LimitFailover.unknownResetWait)
  }
  /// True, and the read stamped, when the provider's own count was last read `readEvery` ago or never.
  public mutating func claimRead(_ provider: String, now: Date) -> Bool {
    if let at = entries[provider]?.readAt, now.timeIntervalSince(at) < Self.readEvery { return false }
    entries[provider, default: Entry()].readAt = now
    return true
  }
  public func remaining(_ provider: String, now: Date) -> ModelRegistry.Remaining {
    guard let entry = entries[provider] else { return .unknown }
    if let until = entry.limitedUntil, until > now { return .limited(until: until) }
    if let left = entry.left, left.at <= now, now.timeIntervalSince(left.at) < Self.countLife { return .fraction(left.share) }
    return .unknown
  }

  // MARK: reading the provider's own count

  /// OpenRouter's `GET /api/v1/key`: `limit_remaining` over `limit`. Nil for a key with no limit,
  /// or a body that is not that JSON.
  public static func openRouterKey(_ body: Data) -> Double? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let data = root["data"] as? [String: Any],
      let limit = (data["limit"] as? NSNumber)?.doubleValue, limit > 0,
      let left = (data["limit_remaining"] as? NSNumber)?.doubleValue
    else { return nil }
    return min(max(left / limit, 0), 1)
  }
  /// The smallest share left that a response's rate-limit headers name: `x-ratelimit-remaining`
  /// (bare, `-requests`, `-tokens`) over the matching `x-ratelimit-limit`, and
  /// `anthropic-ratelimit-*-remaining` over `-limit`. Nil when no pair is there. `header` looks a
  /// name up without regard to case, as `HTTPURLResponse.value(forHTTPHeaderField:)` does.
  public static func headerLeft(_ header: (String) -> String?) -> Double? {
    var pairs = ["", "-requests", "-tokens"].map { ("x-ratelimit-remaining" + $0, "x-ratelimit-limit" + $0) }
    pairs += ["requests", "tokens", "input-tokens", "output-tokens"].map {
      ("anthropic-ratelimit-\($0)-remaining", "anthropic-ratelimit-\($0)-limit")
    }
    func number(_ name: String) -> Double? {
      header(name).flatMap { Double($0.prefix(40).trimmingCharacters(in: .whitespaces)) }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    return pairs.compactMap { left, whole -> Double? in
      guard let left = number(left), let whole = number(whole), whole > 0 else { return nil }
      return min(left / whole, 1)
    }.min()
  }
}
