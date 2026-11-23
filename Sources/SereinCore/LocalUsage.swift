import Foundation

/// Identities exist only in memory to avoid double-counting repeated completion updates.
public struct LocalDownloadCounter {
  private var seen: Set<UUID>
  public init(alreadyComplete: Set<UUID> = []) { seen = alreadyComplete }
  public mutating func completed(id: UUID, isPrivate: Bool, enabled: Bool) -> Bool {
    guard seen.insert(id).inserted else { return false }
    return !isPrivate && enabled
  }
}

public struct UsageActivityClock {
  private var previous: TimeInterval?
  private var wasEligible = false
  private var pendingSeconds: TimeInterval = 0
  public init() {}
  public mutating func sample(at now: TimeInterval, eligible: Bool) -> Int {
    if let previous, wasEligible, eligible {
      let elapsed = now - previous
      if elapsed > 0, elapsed <= 20 { pendingSeconds += elapsed }
    }
    previous = now
    wasEligible = eligible
    let seconds = Int(pendingSeconds)
    pendingSeconds -= Double(seconds)
    return seconds
  }
}

public struct LocalUsageDay: Codable, Identifiable, Equatable {
  public var id: String
  public var activeSeconds: Int = 0
  public var sessions: Int = 0
  public var downloads: Int = 0
  public var downloadBytes: Int64 = 0
  public init(id: String) { self.id = id }
}

/// Daily aggregates only. No user IDs, file names, URLs or browsing/task records.
public struct LocalUsageLedger: Codable {
  public var schemaVersion = 1
  public var startedAt: Date
  public private(set) var days: [LocalUsageDay] = []
  public init(startedAt: Date = Date()) { self.startedAt = startedAt }

  public static func dayKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  private mutating func update(at date: Date, calendar: Calendar, change: (inout LocalUsageDay) -> Void) {
    let key = Self.dayKey(date, calendar: calendar)
    if !days.contains(where: { $0.id == key }) { days.append(LocalUsageDay(id: key)) }
    if let index = days.firstIndex(where: { $0.id == key }) { change(&days[index]) }
    let cutoff = Self.dayKey(calendar.date(byAdding: .day, value: -364, to: date)!, calendar: calendar)
    days.removeAll { $0.id < cutoff }
    days.sort { $0.id < $1.id }
  }

  public mutating func recordActivity(seconds: Int, endingAt date: Date,
                                    newSession: Bool = false, calendar: Calendar = .autoupdatingCurrent) {
    guard seconds > 0, seconds <= 20 else { return }
    let endDate = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    var cursor = endDate.addingTimeInterval(-Double(seconds))
    while cursor < endDate {
      let midnight = calendar.dateInterval(of: .day, for: cursor)!.end
      let end = min(midnight, endDate)
      let amount = Int(end.timeIntervalSince(cursor).rounded())
      update(at: cursor, calendar: calendar) { $0.activeSeconds = min(90_000, $0.activeSeconds + amount) }
      cursor = end
    }
    if newSession { update(at: date, calendar: calendar) { $0.sessions = min(100_000, $0.sessions + 1) } }
  }

  public mutating func recordDownload(bytes: Int64, at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
    update(at: date, calendar: calendar) {
      $0.downloads = min(100_000, $0.downloads + 1)
      $0.downloadBytes = min(1_000_000_000_000_000, $0.downloadBytes + max(0, min(10_000_000_000_000, bytes)))
    }
  }

  public func series(days count: Int, endingAt date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [LocalUsageDay] {
    (0..<max(0, min(365, count))).reversed().map { offset in
      let key = Self.dayKey(calendar.date(byAdding: .day, value: -offset, to: date)!, calendar: calendar)
      return days.first { $0.id == key } ?? LocalUsageDay(id: key)
    }
  }

  public var isValid: Bool {
    schemaVersion == 1 && days.count <= 365 && Set(days.map(\.id)).count == days.count
      && days.allSatisfy {
        $0.id.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
          && (0...90_000).contains($0.activeSeconds) && (0...100_000).contains($0.sessions)
          && (0...100_000).contains($0.downloads) && (0...1_000_000_000_000_000).contains($0.downloadBytes)
      }
  }

  public func insights(at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [String] {
    let month = LocalUsageSummary(rows: series(days: 30, endingAt: date, calendar: calendar))
    guard month.activeDays > 0 else {
      return ["Usage appears after you spend a few seconds in Serein. Private, idle and background time are excluded.",
              "Completed downloads will be counted from now on; earlier downloads are not backfilled."]
    }
    var lines = ["You used Serein on \(month.activeDays) of the last 30 days (\(Int((Double(month.activeDays) / 30 * 100).rounded()))%). Days before tracking began have no records."]
    let yesterday = calendar.date(byAdding: .day, value: -1, to: date)!
    let baselineStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -14, to: date)!)
    if startedAt <= baselineStart {
      let weeks = series(days: 14, endingAt: yesterday, calendar: calendar)
      let previous = LocalUsageSummary(rows: Array(weeks.prefix(7)))
      let current = LocalUsageSummary(rows: Array(weeks.suffix(7)))
      if previous.activeSeconds > 0 {
        let change = Int((Double(current.activeSeconds - previous.activeSeconds) / Double(previous.activeSeconds) * 100).rounded())
        let direction = change >= 0 ? "up" : "down"
        lines.append("Active time is \(direction) \(abs(change))% over the last 7 completed days versus the previous 7.")
      } else { lines.append("The previous week has no active time recorded, so a growth percentage is not available.") }
    } else { lines.append("Weekly comparison will appear after 14 complete days of tracking.") }
    if let peak = month.rows.filter({ $0.activeSeconds > 0 }).max(by: { $0.activeSeconds < $1.activeSeconds }) {
      lines.append("Most active day: \(peak.id), with \(peak.activeSeconds / 60) active minutes.")
    }
    return lines
  }
}

public struct LocalUsageSummary {
  public let rows: [LocalUsageDay]
  public var activeSeconds: Int { rows.reduce(0) { $0 + $1.activeSeconds } }
  public var sessions: Int { rows.reduce(0) { $0 + $1.sessions } }
  public var downloads: Int { rows.reduce(0) { $0 + $1.downloads } }
  public var downloadBytes: Int64 { rows.reduce(0) { $0 + $1.downloadBytes } }
  public var activeDays: Int { rows.filter { $0.activeSeconds > 0 }.count }
  public var activeUsers: Int { activeDays > 0 ? 1 : 0 }
  public var minutesPerSession: Double? { sessions > 0 ? Double(activeSeconds) / 60 / Double(sessions) : nil }
  public init(rows: [LocalUsageDay]) { self.rows = rows }
}
