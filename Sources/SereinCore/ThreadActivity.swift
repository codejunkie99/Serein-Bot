import Foundation

/// When a thread last had a message added. Opening, switching to or re-saving a thread does not
/// change it, so clearing "the last hour" never removes old threads the user only looked at.
public enum ThreadActivity {
  /// A short fingerprint of a transcript's end: its length and last message.
  public struct Tail: Equatable {
    public var count: Int
    public var last: String?
    public init(count: Int, lastID: String?, lastText: String?) {
      self.count = count
      self.last = lastID.map { $0 + "|" + (lastText ?? "") }
    }
  }
  /// The new `lastMessageAt` for a save. `previous` nil means the record did not exist yet.
  /// Unchanged messages keep the stored time; records without one (older versions) stay nil,
  /// which time-range clearing treats as old.
  public static func lastMessageAt(
    stored: Date?, previous: Tail?, current: Tail, now: Date = Date()
  ) -> Date? {
    guard let previous else { return current.count > 0 ? now : nil }
    return previous == current ? stored : now
  }
  /// Whether a thread falls inside a clearing range. Threads with no known message time are
  /// only cleared by "All time".
  public static func inRange(
    _ lastMessageAt: Date?, range: ClearRange, now: Date = Date(), calendar: Calendar = .current
  ) -> Bool {
    guard let date = lastMessageAt else { return range == .allTime }
    return range.contains(date, now: now, calendar: calendar)
  }
}

extension QueuePolicy {
  /// Plan mode for a held, queued or offline message: the stricter of what it was saved with
  /// and the thread's setting now. Turning "Plan first" on always applies to waiting messages.
  public static func plan(stored: Bool?, threadPlan: Bool) -> Bool {
    (stored ?? false) || threadPlan
  }
}

extension ClearRange {
  /// True when any part of the day `key` ("yyyy-MM-dd") falls inside the range. Unknown keys
  /// count as inside only for "All time".
  public func touches(dayKey key: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard let start = start(now: now, calendar: calendar) else { return true }
    // Day keys are Gregorian (Library.dayKey), also when the user's calendar is not.
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = calendar.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    guard let day = f.date(from: key),
      let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
    else { return false }
    return end > start
  }
}

extension Library {
  /// Clears a range of history: removes matching visits, and in every day file the range
  /// touches also removes lines that cannot be read (their time is unknown, so they go).
  /// Returns the removed visits and the keys of the days touched.
  @discardableResult
  public func removeVisits(
    in range: ClearRange, now: Date = Date(), calendar: Calendar = .current
  ) throws -> (removed: [Visit], days: Set<String>) {
    try rewriteHistory(
      touches: { range.touches(dayKey: $0, now: now, calendar: calendar) },
      removes: { visit, touched in visit.map { range.contains($0.date, now: now, calendar: calendar) } ?? touched })
  }
}
