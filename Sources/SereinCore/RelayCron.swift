import Foundation

/// A five-field cron ("17 9 * * 1-5": minute, hour, day-of-month, month, day-of-week) in the
/// user's own timezone. A spoken schedule is reduced to one of these; this is the
/// smallest honest parser: `*`, lists (a,b), ranges (a-b), steps (* /n, a-b/n), names of
/// weekdays and months, and 0 and 7 both meaning Sunday. Everything here is pure, so it is
/// checked in SereinChecks.
public struct RelayCron: Equatable, Sendable {
  public let expression: String
  public let minutes: Set<Int>
  public let hours: Set<Int>
  /// nil: every value (a plain `*`).
  public let daysOfMonth: Set<Int>?
  public let months: Set<Int>?
  public let daysOfWeek: Set<Int>?

  public init?(parse expression: String) {
    let fields = expression.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    guard fields.count == 5 else { return nil }
    func set(_ field: String, low: Int, high: Int, names: [String: Int] = [:]) -> Set<Int>? {
      var values = Set<Int>()
      for part in field.split(separator: ",") {
        // step: "*/2", "*/5", "9-17/2"
        var body = Substring(part)
        var step = 1
        if let slash = part.firstIndex(of: "/") {
          body = part[..<slash]
          guard let parsed = Int(part[part.index(after: slash)...]), parsed >= 1 else { return nil }
          step = parsed
        }
        let range: (Int, Int)
        if body == "*" {
          range = (low, high)
        } else if let dash = body.firstIndex(of: "-") {
          guard let a = Int(body[..<dash]), let b = Int(body[body.index(after: dash)...]),
            a >= low, b <= high, a <= b
          else { return nil }
          range = (a, b)
        } else {
          guard let single = names[String(body)] ?? Int(body), single >= low, single <= high else {
            return nil
          }
          range = (single, single)
        }
        // Inclusive ranges by step, the way cron counts: 1-6/2 is 1,3,5.
        var value = range.0
        while value <= range.1 {
          values.insert(value)
          value += step
        }
      }
      return values.isEmpty ? nil : values
    }
    let weekdays = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
    let monthNames = [
      "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9,
      "oct": 10, "nov": 11, "dec": 12,
    ]
    guard
      let minutes = set(fields[0], low: 0, high: 59),
      let hours = set(fields[1], low: 0, high: 23)
    else { return nil }
    // A field that is only "*" is "every"; anything else restricts.
    let dom = fields[2] == "*" ? nil : set(fields[2], low: 1, high: 31)
    let month = fields[3] == "*" ? nil : set(fields[3], low: 1, high: 12, names: monthNames)
    let dow = fields[4] == "*" ? nil : set(fields[4], low: 0, high: 7, names: weekdays)
    if fields[2] != "*" && dom == nil { return nil }
    if fields[3] != "*" && month == nil { return nil }
    if fields[4] != "*" && dow == nil { return nil }
    // Cron counts Sunday 0 (7 also allowed); Calendar counts Sunday 1. Store Calendar values.
    self.init(
      expression: expression, minutes: minutes, hours: hours, daysOfMonth: dom, months: month,
      daysOfWeek: dow.map { set in Set(set.map { $0 == 0 || $0 == 7 ? 1 : $0 + 1 }) })
  }

  init(
    expression: String, minutes: Set<Int>, hours: Set<Int>, daysOfMonth: Set<Int>?,
    months: Set<Int>?, daysOfWeek: Set<Int>?
  ) {
    self.expression = expression
    self.minutes = minutes
    self.hours = hours
    self.daysOfMonth = daysOfMonth
    self.months = months
    self.daysOfWeek = daysOfWeek
  }

  /// Whether the day matches. Cron's rule: when both day-of-month and day-of-week are
  /// restricted, either matching counts.
  func dayMatches(_ day: Date, calendar: Calendar) -> Bool {
    let parts = calendar.dateComponents([.day, .month, .weekday], from: day)
    if let months, let m = parts.month, !months.contains(m) { return false }
    let domRestricted = daysOfMonth != nil
    let dowRestricted = daysOfWeek != nil
    let domOK = daysOfMonth.map { $0.contains(parts.day ?? -1) } ?? false
    let dowOK = daysOfWeek.map { $0.contains(parts.weekday ?? -1) } ?? false
    switch (domRestricted, dowRestricted) {
    case (true, true): return domOK || dowOK
    case (true, false): return domOK
    case (false, true): return dowOK
    case (false, false): return true
    }
  }

  /// The next time this schedule fires, strictly after `after`. Bounded: a year of days.
  public func next(after: Date, calendar: Calendar = .current) -> Date? {
    var day = calendar.startOfDay(for: after)
    let afterParts = calendar.dateComponents([.hour, .minute], from: after)
    for _ in 0..<367 {
      if dayMatches(day, calendar: calendar) {
        let sameDay = calendar.isDate(day, inSameDayAs: after)
        for hour in hours.sorted() {
          guard !sameDay || hour >= (afterParts.hour ?? -1) else { continue }
          for minute in minutes.sorted() {
            guard !sameDay || hour != afterParts.hour || minute > (afterParts.minute ?? -1) else {
              continue
            }
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = hour
            parts.minute = minute
            // Built from whole components, so a DST change inside the day reads as wall time.
            if let date = calendar.date(from: parts) { return date }
          }
        }
      }
      guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
      day = calendar.startOfDay(for: nextDay)
    }
    return nil
  }
}
