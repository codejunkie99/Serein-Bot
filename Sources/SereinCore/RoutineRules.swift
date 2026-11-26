import Foundation

/// The routines list in Automations: each routine and watch as its name, its schedule as a
/// sentence, what needs the person first, and at most one problem line on one that is broken or
/// waiting. Pure, so `--verify-assistant-core` checks it.
public enum RoutineList {
  /// The order rows sort in: what needs the person, then what runs, then what is paused, then the rest.
  public enum Status: Int, Comparable, Sendable {
    case needsYou, running, paused, on, done
    public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
      switch self {
      case .needsYou: return "Needs you"
      case .running: return "Running"
      case .on: return "On"
      case .paused: return "Paused"
      case .done: return "Done"
      }
    }
  }
  /// Where the one Fix button goes: the chat its run waits or failed in, Serein's chat (a missed
  /// run's card), or Settings › Serein (a limit, an update pause, a failure with no chat).
  public enum Fix: Equatable, Sendable {
    case chat(String), serein, settings
  }
  public struct Row: Equatable, Identifiable, Sendable {
    public var id: String
    public var sentence: String
    public var status: Status
    /// One line on what is wrong or waiting; nil unless the routine needs the person.
    public var problem: String?
    public var next: Date
    public var name: String
    /// When it runs, as a sentence: “Every weekday at 9:00”, “When the page changes”.
    public var schedule: String = ""
    /// Its on switch: off while paused or done.
    public var on: Bool = true
    /// Set exactly when `problem` is.
    public var fix: Fix? = nil
    /// A watch (`RelayWatch`) and not a timed routine.
    public var watch = false
    /// What needs the person is its failing runs (Waiting on you shows it in the danger colour).
    public var failing = false
  }
  /// Delete turns into its confirm for this long, then reverts.
  public static let confirmSeconds: TimeInterval = 4
  /// Failures in a row that make a routine need the person.
  public static let failuresToFlag = 2

  /// “Every weekday at 9:00, summarise my inbox”: when, then what, on one line.
  public static func sentence(_ reminder: RelayReminder, calendar: Calendar = .current) -> String {
    let when = ScheduleWords.words(reminder.repeats, at: reminder.due, cron: reminder.cron, calendar: calendar)
    let what = reminder.id == RelayBriefing.reminderID ? "send the morning brief" : lowered(flat(reminder.text))
    return when + ", " + (what.count > 120 ? String(what.prefix(119)) + "…" : what)
  }
  /// `queued`: its run waits in the queue or is going. `missed`: a missed run of it is listed.
  public static func row(_ reminder: RelayReminder, queued: Bool, missed: Bool, calendar: Calendar = .current) -> Row {
    let status: Status
    let need = Self.need(reminder, missed: missed)
    if reminder.goalEnded || (reminder.limitReached && reminder.paused == true) {
      status = .done
    } else if need != nil {
      status = .needsYou
    } else if queued {
      status = .running
    } else if reminder.paused == true {
      status = .paused
    } else {
      status = .on
    }
    let flagged = status == .needsYou ? need : nil
    return Row(id: reminder.id, sentence: sentence(reminder, calendar: calendar), status: status,
               problem: flagged?.line, next: reminder.due, name: flat(reminder.text),
               schedule: ScheduleWords.words(reminder.repeats, at: reminder.due, cron: reminder.cron, calendar: calendar),
               on: reminder.paused != true && status != .done, fix: flagged?.fix, failing: flagged?.failing ?? false)
  }
  /// A watch as a row: it runs when what it reads changes. Two failed checks in a row, or the
  /// update's pause, need the person; both are fixed in Settings › Serein, where watches live.
  public static func row(_ watch: RelayWatch, now: Date) -> Row {
    let failed = streak(watch.history) ?? watch.failures ?? 0
    let why = watch.history?.last(where: { $0.outcome == "failed" })?.result.map(flat).flatMap { $0.isEmpty ? nil : $0 }
    let problem: String?
    if watch.pausedByUpdate == true {
      problem = "Paused by the update. Resume it to check again."
    } else if failed >= failuresToFlag {
      problem = clip("Failed \(failed) times in a row" + (why.map { ": " + $0 } ?? "."))
    } else {
      problem = nil
    }
    let status: Status = problem != nil ? .needsYou : watch.paused == true ? .paused : .on
    return Row(id: watch.id, sentence: flat(watch.name), status: status, problem: problem,
               next: (watch.lastCheckedAt ?? now).addingTimeInterval(watch.gap), name: flat(watch.name),
               schedule: watch.kind == .url ? "When the page changes" : "When its answer changes",
               on: watch.paused != true, fix: problem == nil ? nil : .settings, watch: true,
               failing: watch.pausedByUpdate != true && failed >= failuresToFlag)
  }
  /// What waits on the person, the most pressing first; nil when nothing does.
  static func problem(_ reminder: RelayReminder, missed: Bool) -> String? { need(reminder, missed: missed)?.line }
  /// The problem line and where it is fixed. Failures are read from its recent runs; the stored
  /// count stands in only for a routine that has no runs listed yet.
  static func need(_ reminder: RelayReminder, missed: Bool) -> (line: String, fix: Fix, failing: Bool)? {
    let failures = reminder.failures ?? 0
    let failed = streak(reminder.history) ?? failures
    let last = reminder.history?.last
    let why = (last?.outcome == "failed" ? last?.result : nil).map(flat).flatMap { $0.isEmpty ? nil : $0 }
      ?? reminder.lastResult.map(flat).flatMap { $0.isEmpty ? nil : $0 }
    let failedIn: Fix = reminder.history?.last(where: { $0.outcome == "failed" })?.thread.map(Fix.chat) ?? .settings
    if last?.outcome == "needs you" { return ("It is waiting on your answer in its chat.", last?.thread.map(Fix.chat) ?? .serein, false) }
    if reminder.paused == true, RelayUnattended.shouldPause(failures: failures) {
      return (clip("Paused after \(failures) failures" + (why.map { ": " + $0 } ?? ".")), failedIn, true)
    }
    // Paused by the person: it waits for them on purpose, so an older failure streak is no problem.
    if failed >= failuresToFlag, reminder.paused != true {
      return (clip("Failed \(failed) times in a row" + (why.map { ": " + $0 } ?? ".")), failedIn, true)
    }
    if missed { return ("A run was missed while your Mac was asleep.", .serein, false) }
    if reminder.pausedByCost == true { return ("Paused for the week: it used its token limit.", .settings, false) }
    if reminder.pausedByUpdate == true { return ("Paused by the update. Resume it to run again.", .settings, false) }
    return nil
  }
  /// Failed runs in a row at the end of `runs` (a retried run counts: it failed too); nil with no runs.
  static func streak(_ runs: [RelayReminder.Run]?) -> Int? {
    guard let runs, !runs.isEmpty else { return nil }
    return runs.reversed().prefix { $0.outcome == "failed" || $0.outcome == RoutineRuns.retried }.count
  }
  static func clip(_ line: String) -> String { line.count > 140 ? String(line.prefix(139)) + "…" : line }
  /// Needs you, running, paused, on, done; then the next run; then the name.
  public static func sorted(_ rows: [Row]) -> [Row] {
    rows.sorted { a, b in
      if a.status != b.status { return a.status < b.status }
      if a.next != b.next { return a.next < b.next }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }
  /// One run on Automations' day line: one that ran earlier today, with its outcome, or one
  /// due later today (no outcome yet).
  public struct Mark: Equatable, Identifiable, Sendable {
    public var id: String
    public var routineID: String
    public var name: String
    public var at: Date
    /// “done”, “failed”, “needs you”…; nil for a run still to come.
    public var outcome: String?
  }
  /// Runs due later today at most, per routine: an every-few-minutes routine marks the line enough.
  // shortcut: 24 later marks per routine, a day line wider than 24 slots would want them merged into bands.
  public static let laterCap = 24
  /// Today's runs around now, in time order: what ran since midnight (from each routine's runs)
  /// and what is due before the day ends (paused and ended routines run nothing later).
  public static func day(_ reminders: [RelayReminder], now: Date, calendar: Calendar = .current) -> [Mark] {
    let start = calendar.startOfDay(for: now)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
    var marks: [Mark] = []
    for reminder in reminders {
      let name = flat(reminder.text)
      for (index, run) in (reminder.history ?? []).enumerated() where run.at >= start && run.at <= now {
        marks.append(Mark(id: "\(reminder.id)#ran\(index)", routineID: reminder.id, name: name, at: run.at, outcome: run.outcome))
      }
      guard reminder.paused != true, !reminder.goalEnded, !reminder.limitReached else { continue }
      var slot: Date? = reminder.due > now ? reminder.due : reminder.next(after: now, calendar: calendar)
      var count = 0
      while let at = slot, at < end, count < laterCap {
        marks.append(Mark(id: "\(reminder.id)#due\(count)", routineID: reminder.id, name: name, at: at, outcome: nil))
        count += 1
        slot = reminder.next(after: at, calendar: calendar)
      }
    }
    return marks.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
  }
  static func flat(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
  }
  /// “Summarise my inbox” reads “summarise my inbox” after the comma; “I”, “NASA” and “iPhone” stay.
  static func lowered(_ text: String) -> String {
    let word = text.prefix { !$0.isWhitespace }
    guard word.count > 1, word.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
    return text.prefix(1).lowercased() + text.dropFirst()
  }
}

/// How one routine run behaves when it fails, overlaps or was missed. Pure, so
/// `--verify-assistant-core` checks it. A retry and a catch-up are ordinary unattended runs: they
/// queue like a timed run and keep every ask, gate and grant check.
public enum RoutineRuns {
  /// The history outcome of a failed run that is tried again; the retry's own failure is final.
  public static let retried = "retried"
  public static let retryDelay: TimeInterval = 15
  public static let rateLimitDelay: TimeInterval = 60
  /// A run missed in this window (the Mac asleep, Serein closed) runs once on wake or launch.
  public static let catchUpWindow: TimeInterval = 12 * 3600

  /// 1 minute when the failure reads as a rate limit, else 15 seconds.
  public static func retryDelay(after failure: String) -> TimeInterval {
    let words = failure.lowercased()
    let limited = ["rate limit", "rate_limit", "ratelimit", "429", "too many requests", "overloaded"]
      .contains { words.contains($0) }
    return limited ? rateLimitDelay : retryDelay
  }
  /// One automatic retry, only for a run that took no step: one that may have sent, written,
  /// clicked or changed anything is never run again by itself.
  public static func mayRetry(_ reminder: RelayReminder, acted: Bool) -> Bool {
    !acted && reminder.history?.last?.outcome != retried
  }
  /// The one line the run's chat gets when it failed; it says when a retry already ran.
  public static func failureLine(_ reminder: RelayReminder, failure: String) -> String {
    let name = RelayMissedRun(reminder: reminder).name
    let why = RoutineList.flat(failure)
    let after = reminder.history?.last?.outcome == retried ? " after one automatic retry" : ""
    let reason = why.isEmpty ? "." : ": " + (why.count > 160 ? String(why.prefix(159)) + "…" : why)
    return "“\(name)” failed\(after)" + reason
  }
  /// The brief's failure line. The brief is Serein speaking first, so its failure stays in the
  /// brief's history and is not posted to the chat; a line an earlier version posted is hidden.
  public static func isBriefFailure(_ line: String) -> Bool {
    line.hasPrefix("“\(RelayMissedRun.briefName)” failed")
  }
  /// A missed run that runs now instead of being listed: missed while the Mac slept or Serein was
  /// closed, with a time it should have run in the last 12 hours. One run, however many slots it
  /// missed. A run missed while Stop Everything held Serein stays listed for the person.
  public static func catchesUp(_ reminder: RelayReminder, now: Date, stoppedAt: Date?, calendar: Calendar = .current)
    -> Bool
  {
    guard RelayMissedRun.isMissed(reminder, now: now) else { return false }
    if let stoppedAt, reminder.due >= stoppedAt { return false }
    let start = now.addingTimeInterval(-catchUpWindow)
    if reminder.due > start { return true }
    return reminder.next(after: start, calendar: calendar).map { $0 <= now } ?? false
  }

  /// The gap after `quiet` checks in a row with nothing new: 15 minutes, doubling up to 4 hours,
  /// never shorter than the check's own interval. A change starts it over.
  public static func backoff(quiet: Int, base: TimeInterval) -> TimeInterval {
    let grown = min(900 * pow(2, Double(min(max(quiet, 0), 10))), maxBackoff)
    return max(base, grown)
  }
  public static let maxBackoff: TimeInterval = 4 * 3600
  /// AI turns one watch may start in any 24 hours.
  public static let wakeLimit = 24
}

extension RelayProactive {
  /// A check-in waits while the person wrote in that chat in the last 20 minutes.
  public static let checkInQuiet: TimeInterval = 20 * 60
  public static func checkInWaits(lastWrote: Date?, now: Date) -> Bool {
    lastWrote.map { now.timeIntervalSince($0) < checkInQuiet } ?? false
  }
}
