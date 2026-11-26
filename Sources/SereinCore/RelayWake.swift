import Foundation

/// Settings › General › Keep the Mac awake while tasks run: what the one idle-sleep assertion is
/// held for. Pure, so it is checked in SereinChecks; `MacAwake` (Serein) holds the assertion.
public enum KeepAwake {
  /// A scheduled run this close holds the Mac awake, so idle sleep never lands just before it.
  public static let lead: TimeInterval = 120
  /// The reason macOS lists for the assertion (`pmset -g assertions`).
  public static let reason = "Serein is running a task or has a scheduled run due within two minutes"

  /// Scheduled requests that will run on their own within `lead`: not paused, and not one that is
  /// listed as missed instead of run. None while Stop Everything holds every request.
  public static func dueSoon(_ reminders: [RelayReminder], now: Date, paused: Bool) -> Int {
    guard !paused else { return 0 }
    return reminders.filter {
      $0.action && $0.paused != true && $0.due <= now.addingTimeInterval(lead) && !RelayMissedRun.isMissed($0, now: now)
    }.count
  }
  /// What the assertion is held for: tasks running (Serein's reply counted once), detached jobs
  /// running in a computer on this Mac (Docker or the built-in one, which idle sleep would
  /// suspend), scheduled turns waiting for Serein to be free, and requests due within the lead.
  /// Zero releases it.
  public static func tasks(running: Int, queued: Int, reminders: [RelayReminder], now: Date, paused: Bool, jobs: Int = 0)
    -> Int
  {
    running + jobs + queued + dueSoon(reminders, now: now, paused: paused)
  }
  /// The menu bar and Settings line while the assertion is held; nil when it is not.
  public static func line(_ tasks: Int) -> String? {
    tasks > 0 ? "Keeping your Mac awake for \(tasks) task\(tasks == 1 ? "" : "s")" : nil
  }
}

/// A scheduled request that came due while the Mac slept, Serein was closed or stopped, or the AI
/// app's usage limit held it. It is listed once per schedule in Serein's chat with Run now and
/// Skip, and never runs by itself unless its schedule says to run late (`RelayReminder.runLate`).
/// Pure, so it is checked in SereinChecks.
public struct RelayMissedRun: Equatable, Identifiable, Sendable {
  /// Why the run did not happen, for the card's words.
  public enum Why: String, Codable, Sendable {
    /// The Mac slept or Serein was closed (or restarted) when it came due.
    case asleep
    /// Stop Everything held every request when it came due.
    case stopped
    /// The AI app's usage limit held it until after its time.
    case usageLimit
    /// It had started when Serein quit or stopped, so nobody knows what it did: the work ledger
    /// marked it missed at the next launch (`WorkLedger.recoverAfterLaunch`). It never runs again
    /// by itself; Run now starts a new run.
    case interrupted
  }
  /// The schedule as it came due. A one-time request has left the list by then, so Run now runs
  /// this copy.
  public let reminder: RelayReminder
  public let why: Why
  public init(reminder: RelayReminder, why: Why = .asleep) {
    self.reminder = reminder
    self.why = why
  }
  /// The schedule's id: one entry per schedule.
  public var id: String { reminder.id }
  /// “Missed while your Mac was asleep”, or the stop's or the usage limit's words.
  public var title: String {
    switch why {
    case .asleep: return "Missed while your Mac was asleep"
    case .stopped: return "Missed while Serein was stopped"
    case .usageLimit: return "Missed because of the AI app's usage limit"
    case .interrupted: return "Stopped when Serein closed, and did not run again"
    }
  }
  /// “Morning brief” for the daily brief (its words are the model's instructions); otherwise the
  /// request's words, on one line and clipped.
  public static let briefName = "Morning brief"
  public var name: String {
    if reminder.id == RelayBriefing.reminderID { return Self.briefName }
    let text = reminder.text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return text.count > 60 ? String(text.prefix(59)) + "…" : text
  }
  /// “Missed while your Mac was asleep: Morning brief”.
  public var line: String { title + ": " + name }

  /// A request reached later than the grace (`RelayUnattended.staleGrace`) was missed: it is
  /// listed, not run, unless its schedule runs late.
  public static func isMissed(_ reminder: RelayReminder, now: Date) -> Bool {
    reminder.action && reminder.runLate != true && RelayUnattended.staleAction(due: reminder.due, now: now)
  }
  /// `list` with this request added, whatever the time: a schedule already listed keeps its
  /// entry, so a schedule missed on several wakes shows one line. A plain reminder is never added.
  public static func adding(_ reminder: RelayReminder, why: Why, to list: [RelayMissedRun]) -> [RelayMissedRun] {
    guard reminder.action, !list.contains(where: { $0.id == reminder.id }) else { return list }
    return list + [RelayMissedRun(reminder: reminder, why: why)]
  }
  /// `list` with each missed request of `fired` (`isMissed`) added once.
  public static func listing(_ fired: [RelayReminder], in list: [RelayMissedRun], now: Date, why: Why = .asleep)
    -> [RelayMissedRun]
  {
    fired.filter { isMissed($0, now: now) }.reduce(list) { adding($1, why: why, to: $0) }
  }

  /// What relay/missed.json keeps: the schedule's id and the time it missed, and the whole copy
  /// only for a one-time request, whose other copy left reminders.json when it came due.
  public struct Saved: Codable, Equatable, Sendable {
    public var id: String
    public var due: Date
    public var why: Why
    public var once: RelayReminder?
    public init(id: String, due: Date, why: Why, once: RelayReminder? = nil) {
      self.id = id
      self.due = due
      self.why = why
      self.once = once
    }
  }
  public var saved: Saved {
    Saved(id: id, due: reminder.due, why: why, once: reminder.repeats == .none ? reminder : nil)
  }
  /// The list again at launch: a one-time request from its copy, a repeating one from the live
  /// schedule at the time it missed. A repeating schedule deleted meanwhile is dropped.
  public static func restored(_ saved: [Saved], reminders: [RelayReminder]) -> [RelayMissedRun] {
    saved.compactMap { entry in
      if let once = entry.once { return RelayMissedRun(reminder: once, why: entry.why) }
      guard var live = reminders.first(where: { $0.id == entry.id }) else { return nil }
      live.due = entry.due
      return RelayMissedRun(reminder: live, why: entry.why)
    }
  }
}
