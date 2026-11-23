import Foundation

/// Limits for routines (scheduled requests an assistant runs by itself) and the plain words that
/// describe a schedule. Pure: the host calls it before it saves a schedule.
public enum ScheduleGuard {
  /// The shortest repeat an action may have, in minutes.
  public static let floorMinutes = 15
  /// At most this many routines that act may be on at once (reminders that only show do not count).
  public static let maxActionRoutines = 20
  /// "in N minutes" runs once, between 1 minute and one week from now.
  public static let inMinutesRange = 1...10_080

  public enum Refusal: Error, Equatable, Sendable {
    case tooOften(minutes: Int)
    case tooMany
    case outOfRange
    case unreadable
    public var words: String {
      switch self {
      case .tooOften(let minutes):
        return "Every \(minutes) minute\(minutes == 1 ? "" : "s") is too often. The fastest is every \(ScheduleGuard.floorMinutes) minutes."
      case .tooMany:
        return "\(ScheduleGuard.maxActionRoutines) routines already run on their own. Stop one first."
      case .outOfRange:
        return "Pick a time between 1 minute and 1 week from now."
      case .unreadable:
        return "I could not read that schedule. Try “every weekday at 8” or “every 30 minutes”."
      }
    }
  }

  /// The smallest gap between two runs of `cron`, in minutes, over a whole day and the wrap to the
  /// next day. A day filter can only make the real gap longer, so this is a safe lower bound.
  public static func smallestGap(_ cron: RelayCron) -> Int {
    var times: [Int] = []
    for hour in cron.hours.sorted() {
      for minute in cron.minutes.sorted() { times.append(hour * 60 + minute) }
    }
    guard let first = times.first, let last = times.last else { return Int.max }
    var gap = 1440 - last + first
    for (a, b) in zip(times, times.dropFirst()) { gap = min(gap, b - a) }
    return gap
  }

  /// nil when a repeating action may be saved; otherwise why not. `actionRoutinesOn` counts the
  /// routines that act and are on now, not counting the one being changed.
  public static func check(cron expression: String, acts: Bool, actionRoutinesOn: Int) -> Refusal? {
    guard let cron = RelayCron(parse: expression) else { return .unreadable }
    if acts {
      let gap = smallestGap(cron)
      if gap < floorMinutes { return .tooOften(minutes: gap) }
      if actionRoutinesOn >= maxActionRoutines { return .tooMany }
    }
    return nil
  }

  /// When "in `minutes` minutes" falls, or a refusal. The host does every time sum; the model never does.
  public static func time(inMinutes minutes: Int, now: Date = Date()) -> Result<Date, Refusal> {
    guard inMinutesRange.contains(minutes) else { return .failure(.outOfRange) }
    return .success(now.addingTimeInterval(TimeInterval(minutes * 60)))
  }

  /// A five-field cron for "every N minutes", or nil when N cannot repeat evenly in an hour.
  public static func cron(everyMinutes minutes: Int) -> String? {
    guard minutes >= 1, minutes < 60, 60 % minutes == 0 else {
      if minutes >= 60, minutes % 60 == 0, minutes / 60 <= 12, 24 % (minutes / 60) == 0 { return "0 */\(minutes / 60) * * *" }
      return nil
    }
    return "*/\(minutes) * * * *"
  }
}

/// A schedule in plain words for cards and receipts. The person never sees a cron.
public enum ScheduleWords {
  public static func words(_ rule: RelayReminder.Repeat, at time: Date, cron: String?, calendar: Calendar = .current) -> String {
    let clock = clockTime(time, calendar: calendar)
    switch rule {
    case .none: return "Once at \(clock)"
    case .daily: return "Every day at \(clock)"
    case .weekdays: return "Every weekday at \(clock)"
    case .weekly:
      let day = calendar.weekdaySymbols[calendar.component(.weekday, from: time) - 1]
      return "Every \(day) at \(clock)"
    case .cron:
      guard let expression = cron, let parsed = RelayCron(parse: expression) else { return "On a custom schedule" }
      return words(parsed, calendar: calendar)
    }
  }

  /// Words for the cron shapes people say; anything else is "On a custom schedule".
  public static func words(_ cron: RelayCron, calendar: Calendar = .current) -> String {
    let everyDay = cron.daysOfMonth == nil && cron.months == nil && cron.daysOfWeek == nil
    // RelayCron stores Calendar weekdays (Sunday 1, Monday 2 … Saturday 7).
    let weekdays = cron.daysOfMonth == nil && cron.months == nil && cron.daysOfWeek == Set(2...6)
    let allHours = cron.hours == Set(0...23)
    if everyDay && allHours, let step = evenStep(cron.minutes, period: 60), step < 60 {
      return step == 1 ? "Every minute" : "Every \(step) minutes"
    }
    if everyDay && cron.minutes == [0], let step = evenStep(cron.hours, period: 24), step < 24 {
      return step == 1 ? "Every hour" : "Every \(step) hours"
    }
    guard cron.hours.count == 1, cron.minutes.count == 1, let hour = cron.hours.first, let minute = cron.minutes.first else {
      return "On a custom schedule"
    }
    let clock = String(format: "%d:%02d", hour, minute)
    if everyDay { return "Every day at \(clock)" }
    if weekdays { return "Every weekday at \(clock)" }
    if cron.daysOfMonth == nil, cron.months == nil, let days = cron.daysOfWeek, days.count == 1, let day = days.first {
      return "Every \(calendar.weekdaySymbols[(day - 1 + 7) % 7]) at \(clock)"
    }
    return "On a custom schedule"
  }

  /// The step when `values` are 0, s, 2s… covering the whole period evenly; otherwise nil.
  static func evenStep(_ values: Set<Int>, period: Int) -> Int? {
    let sorted = values.sorted()
    guard sorted.count >= 1, let first = sorted.first, first == 0 else { return nil }
    let step = sorted.count == 1 ? period : sorted[1] - sorted[0]
    guard step >= 1, period % step == 0, sorted == Array(stride(from: 0, to: period, by: step)) else { return nil }
    return step
  }
  static func clockTime(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }
}
