import Foundation

/// An assistant whose AI app hit its usage limit continues on another AI app the person already
/// connected, and goes back to its own once that limit has reset.
public enum LimitFailover {
  /// Whether `to` may take over from `from` at its usage limit with nobody asked: another AI app
  /// that can answer now, on the person's plan or free. Never another sign-in to the same
  /// subscription: rotating accounts past a provider's usage limit breaks its terms and can get the
  /// accounts closed. Each AI app has one sign-in here, so that is the same AI app. A route that
  /// bills each use (the person's key) is a pay question, so it keeps its card.
  public static func allowed(from: ModelRoute, to: ModelRoute) -> Bool {
    to.provider != from.provider && to.installed && to.selectable && !billsEachUse(to)
  }
  public static func billsEachUse(_ route: ModelRoute) -> Bool { route.costClass == .yourKey }

  /// "Claude Code hit its usage limit, so Codex continued. Back to Claude Code after 3:40 PM."
  /// `back` is the AI app the assistant started on, which a second move keeps.
  public static func line(hit: String, continued: String, back: String, resetsAt: Date?, now: Date,
                          calendar: Calendar = .current, locale: Locale = .current) -> String {
    let when = resetsAt.map { "Back to \(back) after \(UsageLimit.when($0, now: now, calendar: calendar, locale: locale))." }
      ?? "Back to \(back) once its limit resets."
    return "\(hit) hit its usage limit, so \(continued) continued. \(when)"
  }
  public static func backLine(_ app: String) -> String { "\(app)'s usage limit has reset, so \(app) is back." }

  /// With no reset time named, the assistant tries its own AI app again no sooner than this.
  public static let unknownResetWait: TimeInterval = 60 * 60
}

/// The assistants on a backup because of a usage limit, one row each, kept across relaunches.
public struct LimitFailovers: Codable, Equatable, Sendable {
  public struct Row: Codable, Equatable, Sendable {
    public var profileID: String
    public var from: AssistantRoute
    public var to: AssistantRoute
    /// When `from`'s limit resets; nil when it named none (`LimitFailover.unknownResetWait`).
    public var resetsAt: Date?
    public var at: Date
    public init(profileID: String, from: AssistantRoute, to: AssistantRoute, resetsAt: Date?, at: Date) {
      self.profileID = profileID
      self.from = from
      self.to = to
      self.resetsAt = resetsAt
      self.at = at
    }
  }
  public enum Due: Equatable, Sendable {
    /// Not on a backup.
    case none
    /// On a backup until `from`'s limit resets.
    case wait
    /// Someone moved the assistant to another AI app since: the row is stale.
    case moved
    case back(Row)
  }
  public private(set) var rows: [Row] = []
  public init() {}

  public mutating func record(_ row: Row) {
    var row = row
    // A second failover keeps the AI app the assistant started on, so it still goes back there.
    if let earlier = rows.first(where: { $0.profileID == row.profileID }), earlier.to == row.from {
      row.from = earlier.from
      row.resetsAt = earlier.resetsAt
      row.at = earlier.at
    }
    // A reset already past when the limit refused names no time.
    if let reset = row.resetsAt, reset <= row.at { row.resetsAt = nil }
    rows = rows.filter { $0.profileID != row.profileID } + [row]
  }
  public mutating func forget(_ profileID: String) { rows.removeAll { $0.profileID == profileID } }

  /// Before a turn: whether the assistant goes back to its own AI app now. `current` is its route
  /// now; `limitedUntil` says until when an AI app's limit is still on, by provider id.
  public func due(_ profileID: String, current: AssistantRoute?, limitedUntil: (String) -> Date?, now: Date) -> Due {
    guard let row = rows.first(where: { $0.profileID == profileID }) else { return .none }
    guard current == row.to else { return .moved }
    let waitUntil = row.resetsAt ?? row.at.addingTimeInterval(LimitFailover.unknownResetWait)
    if waitUntil > now || limitedUntil(row.from.provider).map({ $0 > now }) == true { return .wait }
    return .back(row)
  }
}
