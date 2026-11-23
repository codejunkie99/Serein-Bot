import Foundation

/// One allowance against one limit for Settings › Usage: what a source counted this period, the
/// limit Serein knows for it, and when the period starts over. Today's sources are a model
/// route's tokens against the warning level set for it, and a schedule's week against its
/// weekly limit. A paid plan carries no AI credit.
public struct UsageMeter: Equatable, Sendable, Identifiable {
  public enum Level: Equatable, Sendable { case under, near, reached }
  public var id: String
  public var name: String
  public var used: Int
  public var limit: Int
  /// Some of `used` is Serein's estimate, not the AI app's own count.
  public var estimated: Bool
  public var start: Date
  /// When the next period begins.
  public var end: Date
  /// Four fifths, as for a schedule near its weekly limit (AgentsOverview.nearLimit).
  public static let nearShare = 0.8

  public init(id: String, name: String, used: Int, limit: Int, estimated: Bool = false,
              start: Date, end: Date) {
    self.id = id; self.name = name; self.used = max(0, used); self.limit = max(1, limit)
    self.estimated = estimated; self.start = start; self.end = end
  }

  public var share: Double { Double(used) / Double(limit) }
  public var left: Int { max(0, limit - used) }
  public var level: Level { share >= 1 ? .reached : share >= Self.nearShare ? .near : .under }

  /// What the period will have used by its end at the pace so far; nil in its first fifth,
  /// when the pace says little, and once it is over.
  public func pace(at now: Date) -> Int? {
    let whole = end.timeIntervalSince(start)
    let gone = now.timeIntervalSince(start)
    guard whole > 0, gone >= whole / 5, gone < whole else { return nil }
    return Int((Double(used) * whole / gone).rounded())
  }

  /// "~180k of 500k tokens"; "~" marks an estimate.
  public var line: String {
    let mark = estimated ? "~" : ""
    return "\(mark)\(UsageLedger.Summary.short(used)) of \(UsageLedger.Summary.short(limit)) tokens"
  }

  /// Said near or past the limit, or when the pace so far passes it before the period ends:
  /// "Opus is at 84% of its 500k tokens. Counts start over Dec 1." nil otherwise.
  public func warning(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> String? {
    let cap = "\(UsageLedger.Summary.short(limit)) tokens"
    let again = "Counts start over \(resets(at: now, calendar: calendar))."
    switch level {
    case .reached: return "\(name) used \(line). \(again)"
    case .near: return "\(name) is at \(used * 100 / limit)% of its \(cap). \(again)"
    case .under:
      guard let pace = pace(at: now), pace >= limit else { return nil }
      return "At this pace \(name) reaches its \(cap) before counts start over \(resets(at: now, calendar: calendar))."
    }
  }

  /// "320k left · counts start over Dec 1".
  public func rest(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    "\(UsageLedger.Summary.short(left)) left · counts start over \(resets(at: now, calendar: calendar))"
  }

  /// "tomorrow", or the day as "Dec 1".
  func resets(at now: Date, calendar: Calendar) -> String {
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
      calendar.isDate(end, inSameDayAs: tomorrow)
    {
      return "tomorrow"
    }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter.string(from: end)
  }
}

extension UsageReset {
  /// Midnight of the day the next period begins.
  public func end(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
    let start = self.start(of: date, calendar: calendar)
    switch self {
    case .daily: return calendar.date(byAdding: .day, value: 1, to: start) ?? start
    case .weekly: return calendar.date(byAdding: .day, value: 7, to: start) ?? start
    case .monthly: return calendar.date(byAdding: .month, value: 1, to: start) ?? start
    }
  }
}

extension UsageLedger {
  /// A meter for each route with a warning level, fullest first. `name` turns a route key into
  /// the words the person knows it by.
  public func meters(warnings: [String: Int], reset: UsageReset, at date: Date = Date(),
                     calendar: Calendar = .autoupdatingCurrent, name: (String) -> String = { $0 }) -> [UsageMeter] {
    let start = reset.start(of: date, calendar: calendar)
    let end = reset.end(of: date, calendar: calendar)
    return warnings.filter { $0.value > 0 }.map { route, limit in
      let summary = self.summary(route, reset: reset, at: date, calendar: calendar)
      return UsageMeter(id: "route:" + route, name: name(route), used: summary.tokens, limit: limit,
                        estimated: summary.calls > 0 && !summary.reported, start: start, end: end)
    }.sorted { $0.share != $1.share ? $0.share > $1.share : $0.id < $1.id }
  }
}

extension RelayReminder {
  /// This week against its weekly token limit; nil without one.
  public func meter(now: Date, calendar: Calendar = .current) -> UsageMeter? {
    guard let limit = weeklyTokens, limit > 0 else { return nil }
    return UsageMeter(id: "schedule:" + id, name: text, used: tokensThisWeek(now: now, calendar: calendar), limit: limit,
                      start: Self.weekStart(of: now, calendar: calendar), end: Self.nextWeek(after: now, calendar: calendar))
  }
}
