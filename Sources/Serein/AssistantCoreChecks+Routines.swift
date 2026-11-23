#if DEBUG
import Foundation
import SereinCore

/// Routines (SereinCore/RoutineRules.swift): the list's sentences, statuses and order; one retry,
/// its delay and the failure line; the 12-hour catch-up; the back-off and wake cap of alerts and
/// goals; the check-in quiet window.
extension AssistantCoreChecks {
  static func routines(_ check: Check) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    // Wednesday 4 November 2026, 8:30 in the morning (UTC).
    let now = Date(timeIntervalSince1970: 1_793_781_000)
    let nine: Date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
    func routine(_ text: String = "Summarise my inbox", due: Date? = nil, repeats: RelayReminder.Repeat = .weekdays,
                 cron: String? = nil) -> RelayReminder {
      RelayReminder(id: text, text: text, due: due ?? nine, repeats: repeats, action: true, cron: cron)
    }

    // One plain sentence.
    let inbox = routine()
    try check(RoutineList.sentence(inbox, calendar: calendar) == "Every weekday at 9:00, summarise my inbox",
              "A routine reads as when, then what")
    try check(RoutineList.sentence(routine("I need the weather"), calendar: calendar).hasSuffix(", I need the weather"),
              "“I” keeps its capital")
    try check(RoutineList.sentence(routine("NASA news"), calendar: calendar).hasSuffix(", NASA news"), "A word in capitals stays")
    let brief = RelayReminder(id: RelayBriefing.reminderID, text: RelayBriefing.text, due: nine, repeats: .daily, action: true)
    try check(RoutineList.sentence(brief, calendar: calendar) == "Every day at 9:00, send the morning brief",
              "The brief reads as the brief, not its instructions")
    try check(RoutineList.sentence(routine(String(repeating: "a", count: 300)), calendar: calendar).count < 160,
              "A long request is clipped")

    // Status and the one problem line.
    try check(RoutineList.row(inbox, queued: false, missed: false).status == .on, "A routine waiting for its time is on")
    try check(RoutineList.row(inbox, queued: true, missed: false).status == .running, "A queued routine is running")
    var failing = inbox
    failing.failures = 2
    failing.lastResult = "The page did not load."
    let failed = RoutineList.row(failing, queued: false, missed: false)
    try check(failed.status == .needsYou && failed.problem == "Failed 2 times in a row: The page did not load.",
              "Two failures in a row need the person, with one line saying why")
    var once = inbox
    once.failures = 1
    try check(RoutineList.row(once, queued: false, missed: false).problem == nil, "One failure is not a problem yet")
    var held = failing
    held.paused = true
    try check(RoutineList.row(held, queued: false, missed: false).status == .paused, "A routine the person paused is paused")
    var stopped = failing
    stopped.failures = RelayUnattended.failureLimit
    stopped.paused = true
    try check(RoutineList.row(stopped, queued: false, missed: false).problem?.hasPrefix("Paused after 10 failures") == true,
              "The failure pause needs the person")
    var asking = inbox
    asking.history = [RelayReminder.Run(at: now, outcome: "needs you", result: "Which folder?")]
    try check(RoutineList.row(asking, queued: false, missed: false).status == .needsYou, "A question waiting needs the person")
    try check(RoutineList.row(inbox, queued: false, missed: true).status == .needsYou, "A listed missed run needs the person")
    var overspent = inbox
    overspent.paused = true
    overspent.pausedByCost = true
    try check(RoutineList.row(overspent, queued: false, missed: false).status == .needsYou, "A week's token pause needs the person")
    var ended = inbox
    ended.goal = RelayGoal(ends: now.addingTimeInterval(86_400))
    ended = ended.ending("Met: found one")
    try check(RoutineList.row(ended, queued: false, missed: false).status == .done, "An ended goal is done")

    // The order: needs you, running, paused, on, done; then the next run; then the name.
    let later = routine("Water the plants", due: nine.addingTimeInterval(3600))
    let early = routine("Back up photos", due: nine)
    let order = RoutineList.sorted([
      RoutineList.row(ended, queued: false, missed: false), RoutineList.row(held, queued: false, missed: false),
      RoutineList.row(later, queued: false, missed: false), RoutineList.row(early, queued: false, missed: false),
      RoutineList.row(failing, queued: false, missed: false), RoutineList.row(routine("Tidy downloads"), queued: true, missed: false),
    ]).map(\.status)
    try check(order == [.needsYou, .running, .paused, .on, .on, .done], "Rows sort needs you, running, paused, on, then done")
    let byTime = RoutineList.sorted([RoutineList.row(later, queued: false, missed: false), RoutineList.row(early, queued: false, missed: false)])
    try check(byTime.first?.name == "Back up photos", "Same status: the next run first")
    try check(RoutineList.confirmSeconds == 4, "Delete confirms in place for 4 seconds")

    // One retry.
    try check(RoutineRuns.retryDelay(after: "HTTP 429 Too Many Requests") == 60, "A rate limit retries after a minute")
    try check(RoutineRuns.retryDelay(after: "The network connection was lost.") == 15, "Any other failure retries after 15 seconds")
    try check(RoutineRuns.mayRetry(inbox, acted: false), "A run that took no step may retry once")
    try check(!RoutineRuns.mayRetry(inbox, acted: true), "A run that took a step never retries by itself")
    var retrying = inbox
    retrying.history = [RelayReminder.Run(at: now, outcome: RoutineRuns.retried)]
    try check(!RoutineRuns.mayRetry(retrying, acted: false), "The retry's own failure is final")
    try check(RoutineRuns.failureLine(retrying, failure: "Timed out.") == "“Summarise my inbox” failed after one automatic retry: Timed out.",
              "The failure line says a retry ran")
    try check(RoutineRuns.failureLine(inbox, failure: "") == "“Summarise my inbox” failed.", "A failure with no words ends plainly")

    // Missed runs from the last 12 hours run once.
    let wake = nine.addingTimeInterval(3 * 3600)
    try check(RoutineRuns.catchesUp(routine(repeats: .daily), now: wake, stoppedAt: nil, calendar: calendar),
              "A daily run missed 3 hours ago runs on wake")
    try check(!RoutineRuns.catchesUp(routine(repeats: .daily), now: nine.addingTimeInterval(20 * 3600), stoppedAt: nil, calendar: calendar),
              "A daily run missed 20 hours ago stays listed")
    let hourly = routine("Check the queue", due: nine, repeats: .cron, cron: "0 * * * *")
    try check(RoutineRuns.catchesUp(hourly, now: nine.addingTimeInterval(20 * 3600), stoppedAt: nil, calendar: calendar),
              "An hourly run with a slot in the last 12 hours runs once")
    try check(!RoutineRuns.catchesUp(routine(repeats: .daily), now: wake, stoppedAt: nine.addingTimeInterval(-60), calendar: calendar),
              "A run missed while Stop Everything held Serein stays listed")
    try check(!RoutineRuns.catchesUp(routine(repeats: .daily), now: nine.addingTimeInterval(120), stoppedAt: nil, calendar: calendar),
              "A run only a little late is no catch-up: it runs as usual")
    let advanced = routine(repeats: .daily).next(after: wake, calendar: calendar)
    try check(advanced == nine.addingTimeInterval(86_400), "After the catch-up the schedule moves to its next time, not every missed slot")

    // Back-off and the wake cap.
    try check(RoutineRuns.backoff(quiet: 0, base: 900) == 900, "A fresh alert checks at its own interval")
    try check(RoutineRuns.backoff(quiet: 1, base: 900) == 1800 && RoutineRuns.backoff(quiet: 3, base: 900) == 7200,
              "Each quiet check doubles the gap")
    try check(RoutineRuns.backoff(quiet: 9, base: 900) == 4 * 3600, "The gap stops at 4 hours")
    try check(RoutineRuns.backoff(quiet: 1, base: 3600) == 3600, "The gap is never shorter than the alert's own interval")
    var watch = RelayWatch(name: "Tickets", kind: .url, source: "https://example.com", minutes: 15, lastCheckedAt: now)
    watch.history = [RelayReminder.Run(at: now, outcome: "changed"), RelayReminder.Run(at: now, outcome: "nothing new"),
                     RelayReminder.Run(at: now, outcome: "nothing new")]
    try check(watch.quiet == 2, "Two unchanged checks after a change make a quiet run of 2")
    try check(!watch.due(now: now.addingTimeInterval(40 * 60)) && watch.due(now: now.addingTimeInterval(61 * 60)),
              "After 2 quiet checks the next one waits an hour")
    watch.history?.append(RelayReminder.Run(at: now, outcome: "changed"))
    try check(watch.due(now: now.addingTimeInterval(15 * 60)), "A change starts the back-off over")
    var woken = watch
    for minute in 0..<RoutineRuns.wakeLimit { woken = woken.waking(now: now.addingTimeInterval(TimeInterval(minute * 60))) }
    try check(!woken.mayWake(now: now.addingTimeInterval(3600)), "The 25th wake in 24 hours does not wake the AI")
    try check(woken.mayWake(now: now.addingTimeInterval(86_400 + 3600)), "A day later the alert may wake it again")
    try check(woken.waking(now: now.addingTimeInterval(2 * 86_400)).wakes?.count == 1, "Wakes older than a day are dropped")
    var goal = routine("A road bike under 600", repeats: .cron, cron: "0 * * * *")
    goal.goal = RelayGoal(ends: now.addingTimeInterval(30 * 86_400))
    try check(goal.next(after: nine, calendar: calendar) == nine.addingTimeInterval(3600), "A goal with no quiet checks keeps its slots")
    goal.goal?.quiet = 4
    try check(goal.next(after: nine, calendar: calendar) == nine.addingTimeInterval(4 * 3600), "After 4 quiet checks a goal waits 4 hours")

    // Check-ins wait while the person writes.
    try check(RelayProactive.checkInWaits(lastWrote: now.addingTimeInterval(-10 * 60), now: now), "Wrote 10 minutes ago: the check-in waits")
    try check(!RelayProactive.checkInWaits(lastWrote: now.addingTimeInterval(-25 * 60), now: now), "Wrote 25 minutes ago: it may go")
    try check(!RelayProactive.checkInWaits(lastWrote: nil, now: now), "Nothing written: it may go")
  }
}
#endif
