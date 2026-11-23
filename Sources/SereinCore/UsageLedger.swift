import Foundation

/// When a route's count starts over: every day, on one weekday, or on one day of the month (to
/// match the plan or the bill the user is watching).
public enum UsageReset: Equatable, Sendable, RawRepresentable {
  case daily
  /// Calendar weekday: 1 is Sunday, 7 is Saturday.
  case weekly(weekday: Int)
  /// 1 to 28, so every month has the day.
  case monthly(day: Int)

  public init?(rawValue: String) {
    if rawValue == "daily" {
      self = .daily
      return
    }
    let parts = rawValue.split(separator: "-").map(String.init)
    guard parts.count == 2, let n = Int(parts[1]) else { return nil }
    if parts[0] == "weekly", (1...7).contains(n) {
      self = .weekly(weekday: n)
    } else if parts[0] == "monthly", (1...28).contains(n) {
      self = .monthly(day: n)
    } else {
      return nil
    }
  }
  public var rawValue: String {
    switch self {
    case .daily: return "daily"
    case .weekly(let weekday): return "weekly-\(weekday)"
    case .monthly(let day): return "monthly-\(day)"
    }
  }
  /// Midnight of the day the current period began.
  public func start(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
    let today = calendar.startOfDay(for: date)
    switch self {
    case .daily: return today
    case .weekly(let weekday):
      let back = (calendar.component(.weekday, from: today) - weekday + 7) % 7
      return calendar.date(byAdding: .day, value: -back, to: today) ?? today
    case .monthly(let day):
      var parts = calendar.dateComponents([.year, .month], from: today)
      parts.day = day
      guard let this = calendar.date(from: parts) else { return today }
      return this <= today ? this : calendar.date(byAdding: .month, value: -1, to: this) ?? today
    }
  }
  /// "today", or "since Oct 22" for a period that began on an earlier day.
  public func period(at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
    let start = self.start(of: date, calendar: calendar)
    if calendar.isDate(start, inSameDayAs: date) { return "today" }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return "since " + formatter.string(from: start)
  }
}

/// Serein's own count of what each model route used: per local day and route (`ModelRoute.id`),
/// the turns Serein launched and their tokens. Tokens are what the CLI printed in its own
/// structured output when it did, else an estimate from Serein's own prompt and reply. Nothing
/// here comes from a provider's files, account page or network; no prompt or reply text is kept.
public struct UsageLedger: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    /// Local calendar day, "yyyy-MM-dd" (LocalUsageLedger.dayKey).
    public var day: String
    /// `ModelRoute.id`: harness instance and model ("" for totals kept before routes were counted).
    public var route: String
    public var calls: Int
    public var tokens: Int
    /// Turns whose tokens Serein estimated because the CLI reported none.
    public var estimated: Int
  }
  /// One route's period: a count is "reported by CLI" only when every turn in it was.
  public struct Summary: Equatable, Sendable {
    public var calls = 0
    public var tokens = 0
    public var estimated = 0
    public init() {}
    public var reported: Bool { calls > 0 && estimated == 0 }
    /// The picker's cell: "42 · 180k est." or "42 · 180k CLI"; "0 calls" before any turn.
    public var compact: String { calls > 0 ? "\(calls) · \(tokensTag)" : "0 calls" }
    /// The cell when the calls do not fit: "180k est." or "180k CLI".
    public var tokensTag: String { Self.short(tokens) + (reported ? " CLI" : " est.") }
    /// "~42 calls · ~180k tokens today (estimate)" or "… (reported by CLI)".
    public func line(period: String) -> String {
      guard calls > 0 else { return "No calls \(period)" }
      let mark = reported ? "" : "~"
      return "\(mark)\(calls) call\(calls == 1 ? "" : "s") · \(mark)\(Self.short(tokens)) tokens \(period)"
        + (reported ? " (reported by CLI)" : " (estimate)")
    }
    /// "840", "180k", "1.2M".
    public static func short(_ n: Int) -> String {
      if n < 1000 { return "\(n)" }
      if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
      return String(format: "%.1fM", Double(n) / 1_000_000)
    }
  }
  /// One day across every route (Settings › Usage).
  public struct Day: Equatable, Sendable {
    public var day: String
    public var date: Date
    public var calls: Int
    public var tokens: Int
  }

  public var schemaVersion = 1
  public private(set) var entries: [Entry] = []
  /// Long enough for a monthly period and the Usage page's two weeks.
  public static let keptDays = 62
  public init() {}

  /// The ledger key of a run's route: its harness instance and its model without Claude's
  /// long-context suffix, as the picker's rows name it (`ModelRoute.id`).
  public static func route(provider: String, model: String) -> String {
    provider + ":" + ClaudeModelID.split(model).base
  }
  /// The harness instance and model of a route key.
  public static func split(_ route: String) -> (provider: String, model: String) {
    guard let colon = route.firstIndex(of: ":") else { return (route, "") }
    return (String(route[..<colon]), String(route[route.index(after: colon)...]))
  }
  /// About four characters a token.
  public static func estimate(characters: Int) -> Int { (max(0, characters) + 3) / 4 }

  /// Adds turns to a route's day; days older than `keptDays` are dropped.
  public mutating func add(route: String, calls: Int = 1, tokens: Int, reported: Bool,
                           at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
    let key = LocalUsageLedger.dayKey(date, calendar: calendar)
    let calls = max(0, min(10_000, calls))
    let tokens = max(0, min(100_000_000, tokens))
    if let i = entries.firstIndex(where: { $0.day == key && $0.route == route }) {
      entries[i].calls = min(1_000_000, entries[i].calls + calls)
      entries[i].tokens = min(1_000_000_000_000, entries[i].tokens + tokens)
      if !reported { entries[i].estimated = min(entries[i].calls, entries[i].estimated + calls) }
    } else {
      entries.append(Entry(day: key, route: route, calls: calls, tokens: tokens, estimated: reported ? 0 : calls))
    }
    if let edge = calendar.date(byAdding: .day, value: -Self.keptDays, to: date) {
      let cutoff = LocalUsageLedger.dayKey(edge, calendar: calendar)
      entries.removeAll { $0.day < cutoff }
    }
  }

  /// A route's turns and tokens in the period `reset` names, up to today.
  public func summary(_ route: String, reset: UsageReset = .daily, at date: Date = Date(),
                      calendar: Calendar = .autoupdatingCurrent) -> Summary {
    let from = LocalUsageLedger.dayKey(reset.start(of: date, calendar: calendar), calendar: calendar)
    let to = LocalUsageLedger.dayKey(date, calendar: calendar)
    return entries.filter { $0.route == route && $0.day >= from && $0.day <= to }.reduce(into: Summary()) {
      $0.calls += $1.calls
      $0.tokens += $1.tokens
      $0.estimated += $1.estimated
    }
  }

  /// Totals per day across every route, oldest first, the last `count` days.
  public func days(_ count: Int, endingAt date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [Day] {
    (0..<max(0, min(Self.keptDays, count))).reversed().compactMap { offset -> Day? in
      guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
      let key = LocalUsageLedger.dayKey(day, calendar: calendar)
      let rows = entries.filter { $0.day == key }
      return Day(day: key, date: day, calls: rows.reduce(0) { $0 + $1.calls }, tokens: rows.reduce(0) { $0 + $1.tokens })
    }
  }

  /// Routes with turns in the kept days, sorted.
  public var routes: [String] { Array(Set(entries.map(\.route).filter { !$0.isEmpty })).sorted() }

  public var isValid: Bool {
    schemaVersion == 1 && entries.count <= 20_000
      && entries.allSatisfy {
        $0.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
          && $0.route.count <= 400 && $0.calls >= 0 && $0.tokens >= 0 && (0...$0.calls).contains($0.estimated)
      }
  }
}
