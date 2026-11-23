import Foundation

/// Changing a schedule after it was made: the person's edits in Settings › Serein, applied at
/// once, and Serein's own (reminder_update), applied only after a card shows the old and new
/// values. Every change is recorded with the item as it was (RelayScheduleChange), so it can be
/// undone. Everything here is pure, so it is checked in SereinChecks.
extension RelayReminder {
  /// The outcome a timed run records when it came due while the last one was still going.
  public static let skipped = "skipped"
  /// The outcome a run records when it could not run in time: the AI app's usage limit stopped it
  /// and its schedule does not let it wait for the reset (UsageLimit.plan). Like a skipped run it
  /// lands only in the history.
  public static let missed = "missed"
  /// The “every N minutes” choices the editor offers; each divides the hour, so the cron is exact.
  public static let minuteChoices = [15, 20, 30]

  /// Skip is the default: a run that comes due while the last is still going is recorded, not queued.
  public var skipsWhileBusy: Bool { skipIfBusy != false }
  /// The run limit is used up; the schedule is paused until the person resumes it or changes the limit.
  public var limitReached: Bool { limit.map { (runs ?? 0) >= $0 } ?? false }

  /// “Every N minutes”, written as the cron `*/N * * * *`; nil for any other schedule.
  public var everyMinutes: Int? {
    guard repeats == .cron, let cron else { return nil }
    let fields = cron.split(separator: " ")
    guard fields.count == 5, fields[0].hasPrefix("*/"), fields.dropFirst().allSatisfy({ $0 == "*" }) else { return nil }
    return Int(fields[0].dropFirst(2))
  }
  public static func cron(everyMinutes minutes: Int) -> String { "*/\(minutes) * * * *" }

  /// How it repeats, in a few words: “Weekdays”, “Every 15 minutes”, “Custom (17 9 * * 1-5)”.
  public var scheduleTitle: String {
    if let minutes = everyMinutes { return "Every \(minutes) minutes" }
    switch repeats {
    case .none: return "Once"
    case .daily: return "Daily"
    case .weekdays: return "Weekdays"
    case .weekly: return "Weekly"
    case .cron: return "Custom (\(cron ?? ""))"
    }
  }

  /// The same schedule with new words, timing, run limit and overlap rule. The next run is worked
  /// out from the new timing so the list and the clock agree: a cron runs at its next match, a
  /// repeating time already past moves to its next occurrence, a one-time run must be ahead. A
  /// changed limit counts from now, and starts again a schedule the old limit stopped (an ended
  /// goal stays ended).
  public func editing(
    text: String, due: Date, repeats: Repeat, cron: String?, limit: Int?, skipIfBusy: Bool, now: Date,
    calendar: Calendar = .current
  ) throws -> RelayReminder {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty, words.count <= 600 else {
      throw SereinError.invalid("The words are required (under 600 characters).")
    }
    if let limit, !(1...1000).contains(limit) { throw SereinError.invalid("Stop after takes 1 to 1000 runs.") }
    if goal != nil, repeats == .none { throw SereinError.invalid("A goal checks again and again. Pick how often.") }
    var copy = self
    copy.text = words
    copy.repeats = repeats
    copy.cron = nil
    copy.due = due
    switch repeats {
    case .cron:
      guard let raw = cron?.trimmingCharacters(in: .whitespaces), let schedule = RelayCron(parse: raw),
        let next = schedule.next(after: now, calendar: calendar)
      else {
        throw SereinError.invalid(
          "A custom schedule is a five-field cron such as 17 9 * * 1-5 (minute hour day-of-month month day-of-week).")
      }
      // A goal's checks run unattended for up to a year: under an hour apart that is thousands of runs.
      if goal != nil, let after = schedule.next(after: next, calendar: calendar), after.timeIntervalSince(next) < 3600 {
        throw SereinError.invalid("A goal checks at most once an hour. Pick a schedule whose runs are an hour or more apart.")
      }
      copy.cron = schedule.expression
      copy.due = next
    case .none:
      guard due > now.addingTimeInterval(-60) else { throw SereinError.invalid("That time has passed. Pick a later one.") }
    case .daily, .weekly, .weekdays:
      if repeats == .weekdays, calendar.isDateInWeekend(copy.due), let next = copy.next(after: copy.due, calendar: calendar) {
        copy.due = next
      }
      if copy.due <= now, let next = copy.next(after: now, calendar: calendar) { copy.due = next }
    }
    copy.skipIfBusy = skipIfBusy ? nil : false
    if limit != self.limit {
      copy.limit = limit
      copy.runs = nil
      if limitReached, copy.paused == true, !goalEnded { copy.paused = nil }
    }
    return copy
  }

  /// Paused by the person or Serein's card: it replaces a weekly limit's pause, so the next week
  /// does not lift it.
  public func pausing() -> RelayReminder {
    var copy = self
    copy.paused = true
    copy.pausedByCost = nil
    return copy
  }
  /// Resumed by the person: the failure streak clears, a used-up limit counts again from zero (a
  /// weekly token limit too: its week's count starts over), an ended goal starts again with its
  /// quiet streak cleared, and a next run that passed while paused moves to the next one rather
  /// than running late.
  public func resumed(now: Date, calendar: Calendar = .current) -> RelayReminder {
    var copy = self
    if limitReached { copy.runs = nil }
    if pausedByCost == true || overWeeklyLimit(now: now, calendar: calendar) {
      copy.weekTokens = nil
      copy.weekStart = nil
    }
    copy.pausedByCost = nil
    copy.goal?.ended = nil
    copy.goal?.quiet = nil
    copy.paused = nil
    copy.pausedByUpdate = nil
    copy.failures = nil
    if copy.due <= now, let next = copy.next(after: now, calendar: calendar) { copy.due = next }
    return copy
  }
  /// This earlier copy put back over `current`, keeping what happened since (the runs, their
  /// outcomes, the failure streak, the runs counted toward the same limit, the week's tokens, a
  /// goal's checks and findings); a next run that passed meanwhile moves to the next one.
  public func restored(over current: RelayReminder?, now: Date, calendar: Calendar = .current) -> RelayReminder {
    var copy = self
    if let current {
      copy.history = current.history
      copy.failures = current.failures
      copy.lastResult = current.lastResult
      copy.weekTokens = current.weekTokens
      copy.weekStart = current.weekStart
      if let live = current.goal, copy.goal != nil {
        copy.goal?.checks = live.checks
        copy.goal?.quiet = live.quiet
        copy.goal?.findings = live.findings
        copy.goal?.seen = live.seen
        // A check ended it (met, or its quiet limit) since that copy; undoing an older edit
        // never starts it checking again.
        if let ended = live.ended, ended.hasPrefix("Met:") || ended.hasPrefix("Nothing new in") {
          copy.goal?.ended = ended
          copy.paused = true
        }
      }
      if copy.limit == current.limit {
        copy.runs = current.runs
        if copy.limitReached { copy.paused = true }
      }
    }
    // A weekly limit's pause put back while the week is no longer over the limit (Undo of a
    // Resume) stays paused for the person instead of lifting at the next tick.
    if copy.pausedByCost == true, !copy.overWeeklyLimit(now: now, calendar: calendar) { copy.pausedByCost = nil }
    if copy.due <= now, let next = copy.next(after: now, calendar: calendar) { copy.due = next }
    return copy
  }

  /// What a change does, one line per field that differs (“Next run: Oct 27, 9:00 AM → …”), for
  /// the card Serein's own edit shows before anything changes.
  public static func changeLines(from old: RelayReminder, to new: RelayReminder) -> String {
    func when(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    func stop(_ r: RelayReminder) -> String { r.limit.map { "after \($0) runs" } ?? "never" }
    func onOff(_ on: Bool) -> String { on ? "on" : "off" }
    var lines: [String] = []
    if old.text != new.text {
      lines.append("Words: “\(String(old.text.prefix(200)))” → “\(String(new.text.prefix(200)))”")
    }
    if old.due != new.due { lines.append("Next run: \(when(old.due)) → \(when(new.due))") }
    if old.scheduleTitle != new.scheduleTitle { lines.append("Repeats: \(old.scheduleTitle) → \(new.scheduleTitle)") }
    if old.limit != new.limit { lines.append("Stop: \(stop(old)) → \(stop(new))") }
    if old.weeklyTokens != new.weeklyTokens {
      lines.append("Weekly token limit: \(old.weeklyLimitTitle) → \(new.weeklyLimitTitle)")
    }
    if old.skipsWhileBusy != new.skipsWhileBusy {
      lines.append("Skip a run while the last is going: \(onOff(old.skipsWhileBusy)) → \(onOff(new.skipsWhileBusy))")
    }
    if (old.paused == true) != (new.paused == true) {
      lines.append("Paused: \(old.paused == true ? "yes" : "no") → \(new.paused == true ? "yes" : "no")")
    }
    if let before = old.goal, let after = new.goal {
      func quiet(_ g: RelayGoal) -> String { g.quietLimit.map { "after \($0) quiet checks" } ?? "never" }
      if before.note != after.note {
        lines.append("Progress note: “\(String((before.note ?? "").prefix(200)))” → “\(String((after.note ?? "").prefix(200)))”")
      }
      if before.ends != after.ends {
        lines.append("Ends: \(before.ends.formatted(date: .abbreviated, time: .omitted)) → \(after.ends.formatted(date: .abbreviated, time: .omitted))")
      }
      if before.quietLimit != after.quietLimit { lines.append("End when quiet: \(quiet(before)) → \(quiet(after))") }
      if before.ended != after.ended { lines.append("Ended: \(before.ended ?? "no") → \(after.ended ?? "no")") }
    }
    return lines.joined(separator: "\n")
  }
}

extension RelayReminder.Run {
  /// The outcome as History reads it: finished, nothing new, needed you, failed, skipped, changed.
  public var title: String {
    switch outcome {
    case "done": return "finished"
    case "needs you": return "needed you"
    default: return outcome
    }
  }
}

extension RelayWatch {
  /// The same watch with a new name, read or interval. A new read starts over: its first check
  /// learns the starting answer, so the change itself never fires the alert.
  public func editing(name: String, source: String, minutes: Int) throws -> RelayWatch {
    let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName.count <= 80 else {
      throw SereinError.invalid("The name is required (under 80 characters).")
    }
    let newSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard RelayWatch.validSource(kind: kind, source: newSource) else {
      throw SereinError.invalid(
        kind == .script
          ? "The read must be a read-only AppleScript over Calendar, Reminders, Notes or Finder (getting names, counts or titles)."
          : "The page must be a public address, https://…")
    }
    var copy = self
    copy.name = newName
    copy.minutes = RelayWatch.clamped(minutes: minutes)
    if newSource != self.source {
      copy.source = newSource
      copy.fingerprint = nil
      copy.lastAnswer = nil
      copy.lastCheckedAt = nil
    }
    return copy
  }
  public func pausing() -> RelayWatch {
    var copy = self
    copy.paused = true
    return copy
  }
  public func resumed() -> RelayWatch {
    var copy = self
    copy.paused = nil
    copy.pausedByUpdate = nil
    copy.failures = nil
    return copy
  }
  /// This earlier copy put back over `current`, keeping its checks since; the last answer stays
  /// when the read is the same, so the undo itself never fires the alert.
  public func restored(over current: RelayWatch?) -> RelayWatch {
    var copy = self
    guard let current else { return copy }
    copy.history = current.history
    copy.failures = current.failures
    copy.lastCheckedAt = current.lastCheckedAt
    if current.source == source {
      copy.fingerprint = current.fingerprint
      copy.lastAnswer = current.lastAnswer
    }
    return copy
  }
}

/// One change to a reminder, a scheduled request or an alert, with the item as it was before, so
/// Settings can undo it. An undo is itself a change, so undoing an undo works.
public struct RelayScheduleChange: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case reminder, watch }
  public var id: UUID
  public var at: Date
  /// "user" (Settings) or "relay" (a tool, after the card where one is needed).
  public var actor: String
  /// What changed, in a few words: “Paused “Water the plants””.
  public var summary: String
  public var kind: Kind
  public var itemID: String
  /// The item before the change; both nil when the change added it.
  public var reminder: RelayReminder?
  public var watch: RelayWatch?
  public init(
    id: UUID = UUID(), at: Date = Date(), actor: String, summary: String, kind: Kind, itemID: String,
    reminder: RelayReminder? = nil, watch: RelayWatch? = nil
  ) {
    self.id = id
    self.at = at
    self.actor = actor
    self.summary = summary
    self.kind = kind
    self.itemID = itemID
    self.reminder = reminder
    self.watch = watch
  }
  /// The log keeps this many changes, oldest dropped first.
  public static let kept = 50
  public static func trimmed(_ changes: [RelayScheduleChange]) -> [RelayScheduleChange] {
    changes.count <= kept ? changes : Array(changes.suffix(kept))
  }
}
