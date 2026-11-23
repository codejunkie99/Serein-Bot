import Foundation

/// The host's side of a reminder or routine that a tool asks for: the time sum, the guard, the
/// assistant it belongs to and the receipt. Pure, so `--verify-assistant-core` checks it.
public enum ScheduleRequest {
  /// Routines that act and are on now: action schedules that repeat and are not paused. `except`
  /// leaves out the one being changed.
  public static func actionRoutinesOn(_ reminders: [RelayReminder], except id: String? = nil) -> Int {
    reminders.filter { $0.action && $0.repeats != .none && $0.paused != true && $0.id != id }.count
  }

  /// Why a schedule may not be saved, or nil. A cron is checked over its whole cycle
  /// (`ScheduleGuard.check`); the other repeats are a day or more apart, so only the count holds
  /// for them. The 15-minute floor holds for a routine that acts, on or paused; the count of
  /// routines that act only for one that is on (`on`).
  public static func refusal(
    repeats: RelayReminder.Repeat, cron: String?, acts: Bool, on: Bool = true, actionRoutinesOn: Int
  ) -> ScheduleGuard.Refusal? {
    if repeats == .cron {
      guard let cron else { return .unreadable }
      return ScheduleGuard.check(cron: cron, acts: acts, actionRoutinesOn: on ? actionRoutinesOn : 0)
    }
    if acts, on, repeats != .none, actionRoutinesOn >= ScheduleGuard.maxActionRoutines { return .tooMany }
    return nil
  }

  /// When a request first comes due: `inMinutes` from `now` (the host does the sum, never the
  /// model), else the time `at` names. nil when neither gives a time.
  public static func firstDue(at: String?, inMinutes: Int?, now: Date = Date()) -> Result<Date, ScheduleGuard.Refusal>? {
    if let minutes = inMinutes { return ScheduleGuard.time(inMinutes: minutes, now: now) }
    guard let at, let date = RelayReminder.parse(at.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return .success(date)
  }

  /// Words by which the person's own message names a schedule: a reminder, a repeat, a time or a
  /// change to one. A request Serein carries out applies only when the words name one (`Admission`'s
  /// rule of one); a miss costs one tap on the card, never a wrong apply.
  static let schedulePhrases: [String] = [
    "remind", "reminder", "reminders", "every", "each day", "each week", "daily", "hourly", "weekly", "monthly",
    "weekday", "weekdays", "weekend", "weekends", "tomorrow", "tonight", "today", "later", "morning", "afternoon",
    "evening", "night", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks", "schedule",
    "scheduled", "routine", "routines", "noon", "midnight", "pm", "pause", "resume", "snooze", "reschedule",
    "postpone", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
  ]
  /// Words that name a goal Serein tracks over days.
  static let goalPhrases: [String] = [
    "track", "keep checking", "keep an eye", "let me know", "tell me when", "find me", "watch for", "look out for",
    "look for", "goal",
  ]

  /// Whether the person's own message names a schedule: one of `schedulePhrases`, or a clock time
  /// ("at 8", "by 9", "8:30").
  public static func namesSchedule(_ message: String) -> Bool {
    let words = TypedConsent.normalized(message)
    if TypedConsent.contains(words, any: schedulePhrases) { return true }
    if words.range(of: " (at|by|from|until|before|after|around) [0-9]", options: .regularExpression) != nil { return true }
    return words.range(of: " [0-9]{1,2} [0-9]{2} ", options: .regularExpression) != nil
  }

  /// Whether the person's own message names a goal to track, or a schedule.
  public static func namesGoal(_ message: String) -> Bool {
    namesSchedule(message) || TypedConsent.contains(TypedConsent.normalized(message), any: goalPhrases)
  }

  /// Whether the person's own words name `name`, as whole words in any case ("Inbox Zero, check
  /// my mail" names Inbox Zero). An empty name is never named.
  public static func wordsName(_ name: String, in message: String) -> Bool {
    let wanted = TypedConsent.normalized(name).trimmingCharacters(in: .whitespaces)
    guard !wanted.isEmpty else { return false }
    return TypedConsent.normalized(message).contains(" " + wanted + " ")
  }

  /// The receipt for a schedule that was just saved. A one-time reminder gets the reminder
  /// banner; anything that repeats, and any request Serein carries out, gets the routine card,
  /// in `ScheduleWords`. `owner` is the name of the assistant whose routine it is, when that is
  /// not the one that answers. The line stays within `Receipt.maxLine`; the card keeps the whole
  /// text, and `item` holds the schedule's id for the card's switch.
  public static func receipt(
    for reminder: RelayReminder, owner: String? = nil, now: Date = Date(), calendar: Calendar = .current
  ) -> Receipt {
    let text = reminder.text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    if reminder.repeats == .none, !reminder.action {
      return ReceiptCopy.reminder(at: clock(reminder.due, now: now, calendar: calendar), text: text)
    }
    let when: String
    if reminder.repeats == .none {
      when = day(reminder.due, now: now, calendar: calendar)
    } else {
      when = ScheduleWords.words(reminder.repeats, at: reminder.due, cron: reminder.cron, calendar: calendar)
    }
    let what = reminder.action ? text : "Remind you: " + text
    let on = reminder.paused != true
    let speaker = owner.map { $0 + " will " } ?? "I will "
    let room = Receipt.maxLine - ("Okay. " + when + " " + speaker + ".").count
    var receipt = ReceiptCopy.routine(when: when, what: clipped(what, to: room), on: on)
    if owner != nil {
      receipt.line = "Okay. " + when + " " + speaker + ReceiptCopy.lowercasedFirst(clipped(what, to: room)) + "."
    }
    receipt.card = .routine(title: when, detail: what, on: on)
    // The card's switch acts on this schedule by its id (`setRoutineOn` in the app).
    receipt.item = reminder.id
    return receipt
  }

  /// A routine's line when an app it needs is not connected yet (board 13): "… Connect Slack
  /// first, then it runs." The line stays as it is when the words would pass `Receipt.maxLine`.
  public static func connectFirst(_ line: String, app: String) -> String {
    let longer: String = line + " Connect \(app) first, then it runs."
    return longer.count <= Receipt.maxLine ? longer : line
  }

  /// "3:45 PM", "9:00 AM tomorrow" or "3:45 PM on Oct 30", for the reminder banner.
  static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
    let time = formatter(calendar, date: .none, time: .short).string(from: date)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
      return time + " tomorrow"
    }
    return time + " on " + formatter(calendar, date: .medium, time: .none).string(from: date)
  }

  /// "Today at 3:45 PM", "Tomorrow at 9:00 AM" or "On Oct 30 at 3:45 PM", for a one-time request.
  static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
    let time = formatter(calendar, date: .none, time: .short).string(from: date)
    if calendar.isDate(date, inSameDayAs: now) { return "Today at " + time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
      return "Tomorrow at " + time
    }
    return "On " + formatter(calendar, date: .medium, time: .none).string(from: date) + " at " + time
  }

  static func formatter(_ calendar: Calendar, date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = calendar.locale ?? Locale.current
    formatter.dateStyle = date
    formatter.timeStyle = time
    return formatter
  }

  /// `text` cut to `limit` characters, with "…" when it was cut.
  static func clipped(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    guard limit > 1 else { return "…" }
    return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }
}

/// One run Serein does by itself, as a row of the work ledger holds it (`WorkLedger.Row.payload`):
/// the request as it came due, what started it and whose it is. The copy leaves out the run
/// history, and, when it is still too long, a goal's findings, so it fits `WorkLedger.maxPayload`.
public struct QueuedRun: Codable, Equatable, Sendable {
  public var reminder: RelayReminder
  public var initiator: AgentHistoryRun.Initiator
  /// The assistant whose run it is; nil is the person's own.
  public var profileID: String?
  /// Queued again from a usage-limit hold.
  public var retried: Bool?

  public init(reminder: RelayReminder, initiator: AgentHistoryRun.Initiator, profileID: String?, retried: Bool) {
    self.reminder = reminder
    self.initiator = initiator
    self.profileID = profileID
    self.retried = retried ? true : nil
  }

  /// The ledger's owner field: the assistant's id, or "person" for the person's own.
  public static let personsOwn = "person"
  public var owner: String { profileID ?? Self.personsOwn }

  /// The text the ledger keeps, or nil when even the short copy is too long.
  public func payload() -> String? {
    var copy = self
    copy.reminder.history = nil
    copy.reminder.lastResult = nil
    if let text = Self.encoded(copy), text.unicodeScalars.count <= WorkLedger.maxPayload { return text }
    copy.reminder.goal?.findings = nil
    copy.reminder.goal?.seen = nil
    copy.reminder.goal?.note = nil
    guard let text = Self.encoded(copy), text.unicodeScalars.count <= WorkLedger.maxPayload else { return nil }
    return text
  }

  /// The run a payload holds; nil for one this build cannot read.
  public static func decoded(_ payload: String) -> QueuedRun? {
    try? JSONDecoder().decode(QueuedRun.self, from: Data(payload.utf8))
  }

  static func encoded(_ run: QueuedRun) -> String? {
    guard let data = try? JSONEncoder().encode(run) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
