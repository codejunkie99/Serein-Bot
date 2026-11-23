#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// What a schedule costs: each run keeps the tokens its AI app reported, a routine's average
  /// counts only runs that reported some, and a schedule saved before runs kept tokens still loads.
  @MainActor static func scheduleCost() throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw SereinError.invalid("FAIL: " + message) }
      results.append("PASS: " + message)
    }
    var reminder = RelayReminder(id: "cost-fixture", text: "Check my inbox", due: Date(), repeats: .daily, action: true)
    try check(reminder.averageTokens == nil, "A routine with no runs has no cost yet")
    reminder.history = [
      RelayReminder.Run(outcome: "done", tokens: 9_000),
      RelayReminder.Run(outcome: RelayReminder.skipped),
      RelayReminder.Run(outcome: "nothing new", tokens: 3_000),
      RelayReminder.Run(outcome: RelayReminder.missed, tokens: 0),
    ]
    try check(reminder.averageTokens == 6_000,
      "A routine's cost per run averages only the runs that reported tokens (skipped and missed runs used none)")
    let older = #"{"at":0,"outcome":"done","result":"Fine","thread":"t1"}"#
    let decoded = try? JSONDecoder().decode(RelayReminder.Run.self, from: Data(older.utf8))
    try check(decoded?.outcome == "done" && decoded?.thread == "t1" && decoded?.tokens == nil,
      "A run saved before runs kept tokens still loads, with no tokens")
    try check(UsageLedger.Summary.short(9_000) == "9k" && UsageLedger.Summary.short(1_340_000) == "1.3M",
      "Token counts read as in Settings › Usage (9k, 1.3M)")
    try weeklyLimit(check)
    try estimate(check)
    return results
  }

  /// A weekly token limit pauses only its own schedule, the next week lifts it, and the person's
  /// own changes (a new limit, Resume, Undo) behave as for the run limit.
  @MainActor private static func weeklyLimit(_ check: (Bool, String) throws -> Void) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    let wednesday = Date(timeIntervalSince1970: 1_793_188_800)  // Wed 28 Oct 2026, 12:00 UTC
    let monday = Date(timeIntervalSince1970: 1_792_972_800)  // Mon 26 Oct 2026, 00:00 UTC
    let nextMonday = monday.addingTimeInterval(7 * 86_400)
    try check(RelayReminder.weekStart(of: wednesday, calendar: calendar) == monday
      && RelayReminder.nextWeek(after: wednesday, calendar: calendar) == nextMonday,
      "A schedule's week starts on the first day of the person's week")

    var brief = RelayReminder(id: "brief", text: "Morning brief", due: wednesday.addingTimeInterval(3600), repeats: .daily, action: true)
    var counted = brief.counting(tokens: 30_000, now: wednesday, calendar: calendar)
    try check(!counted.paused && counted.reminder.tokensThisWeek(now: wednesday, calendar: calendar) == 30_000
      && counted.reminder.paused == nil, "Without a limit a run's tokens only count toward its week")
    counted = counted.reminder.counting(tokens: 0, now: wednesday, calendar: calendar)
    try check(counted.reminder.weekTokens == 30_000, "A run that reported no tokens adds nothing")
    try check(counted.reminder.tokensThisWeek(now: nextMonday, calendar: calendar) == 0
      && counted.reminder.counting(tokens: 5_000, now: nextMonday, calendar: calendar).reminder.weekTokens == 5_000,
      "A new week starts the count over")

    brief = try brief.limitingWeek(to: 50_000, now: wednesday, calendar: calendar)
    counted = brief.counting(tokens: 30_000, now: wednesday, calendar: calendar)
    try check(!counted.paused && counted.reminder.paused == nil, "Under its weekly limit a schedule keeps running")
    counted = counted.reminder.counting(tokens: 22_000, now: wednesday, calendar: calendar)
    try check(counted.paused && counted.reminder.paused == true && counted.reminder.pausedByCost == true
      && counted.reminder.overWeeklyLimit(now: wednesday, calendar: calendar),
      "The run that brings the week to its limit pauses that schedule, marked as the weekly limit's pause")
    let paused = counted.reminder
    let again = paused.counting(tokens: 4_000, now: wednesday, calendar: calendar)
    try check(!again.paused && again.reminder.weekTokens == 56_000,
      "A schedule already paused only counts a late run's tokens")
    try check(paused.liftingCostPause(now: wednesday.addingTimeInterval(86_400), calendar: calendar) == nil,
      "The pause holds for the rest of the week")
    let lifted = paused.liftingCostPause(now: nextMonday.addingTimeInterval(3600), calendar: calendar)
    try check(lifted?.paused == nil && lifted?.pausedByCost == nil
      && (lifted?.due ?? .distantPast) > nextMonday.addingTimeInterval(3600),
      "The next week lifts the pause on its own, from its next time rather than late")

    var stopped = paused
    stopped.limit = 3
    stopped.runs = 3
    let held = stopped.liftingCostPause(now: nextMonday, calendar: calendar)
    try check(held?.paused == true && held?.pausedByCost == nil,
      "A schedule that also used up its run limit stays paused for the person after the week")

    let raised = try paused.limitingWeek(to: 100_000, now: wednesday, calendar: calendar)
    try check(raised.paused == nil && raised.pausedByCost == nil && raised.weeklyTokens == 100_000,
      "Raising the limit above the week's count lets it run again")
    let lowered = try paused.limitingWeek(to: 25_000, now: wednesday, calendar: calendar)
    try check(lowered.paused == true && lowered.pausedByCost == true, "A limit still under the week's count keeps it paused")
    let removed = try paused.limitingWeek(to: nil, now: wednesday, calendar: calendar)
    try check(removed.paused == nil && removed.weeklyTokens == nil, "Removing the limit lets it run again")
    var refused = false
    do { _ = try brief.limitingWeek(to: 10, now: wednesday, calendar: calendar) } catch { refused = true }
    try check(refused, "A weekly limit under 1,000 tokens is refused")

    let resumed = paused.resumed(now: wednesday, calendar: calendar)
    try check(resumed.paused == nil && resumed.pausedByCost == nil
      && resumed.tokensThisWeek(now: wednesday, calendar: calendar) == 0 && !resumed.overWeeklyLimit(now: wednesday, calendar: calendar),
      "Resume runs it again and starts its week's count over")
    let unpaused = { () -> RelayReminder in var r = paused; r.paused = nil; r.pausedByCost = nil; return r }()
    try check(unpaused.overWeeklyLimit(now: wednesday, calendar: calendar),
      "A schedule over its limit without the pause (a lowered limit, an undo) reads as over, so the clock pauses it before it runs")

    let pausedByHand = paused.pausing()
    try check(pausedByHand.paused == true && pausedByHand.pausedByCost == nil
      && pausedByHand.liftingCostPause(now: nextMonday, calendar: calendar) == nil,
      "Pausing it by hand replaces the weekly limit's pause, so the next week does not lift it")
    let undoResume = paused.restored(over: resumed, now: wednesday, calendar: calendar)
    try check(undoResume.paused == true && undoResume.pausedByCost == nil,
      "Undoing a Resume puts it back paused for the person, not lifted at the next tick")
    let undone = brief.restored(over: paused, now: wednesday, calendar: calendar)
    try check(undone.weekTokens == paused.weekTokens && undone.weekStart == paused.weekStart,
      "Undo keeps the tokens its runs used this week")
    let lines = RelayReminder.changeLines(from: brief, to: try brief.limitingWeek(to: nil, now: wednesday, calendar: calendar))
    try check(lines.contains("Weekly token limit: 50k tokens a week → none"),
      "Serein's own change to the limit shows on its card as old and new")

    let older = #"{"id":"old","text":"Water the plants","due":0,"repeats":"daily","action":true}"#
    let decoded = try? JSONDecoder().decode(RelayReminder.self, from: Data(older.utf8))
    try check(decoded?.weeklyTokens == nil && decoded?.pausedByCost == nil && decoded?.text == "Water the plants",
      "A schedule saved before weekly limits still loads, with no limit")
    // reminder_list reads the real clock, so this one is counted on it.
    let live = try RelayReminder(text: "Check my inbox", due: Date().addingTimeInterval(3600), repeats: .daily, action: true)
      .limitingWeek(to: 50_000, now: Date()).counting(tokens: 60_000, now: Date()).reminder
    let json = RelayToolHost.reminder(live)
    try check(json["weekly_tokens"] as? Int == 50_000 && json["tokens_this_week"] as? Int != nil
      && json["paused_by_weekly_tokens"] as? Bool == true,
      "reminder_list tells Serein a schedule's weekly limit, its week's tokens and the pause")
  }

  /// The estimate a schedule's creation card shows before anything runs.
  private static func estimate(_ check: (Bool, String) throws -> Void) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let due = Date(timeIntervalSince1970: 1_793_188_800)
    func schedule(_ repeats: RelayReminder.Repeat, _ cron: String? = nil) -> RelayReminder {
      RelayReminder(text: "Check", due: due, repeats: repeats, action: true, cron: cron)
    }
    try check(schedule(.daily).runsPerWeek(calendar: calendar) == 7 && schedule(.weekdays).runsPerWeek(calendar: calendar) == 5
      && schedule(.weekly).runsPerWeek(calendar: calendar) == 1,
      "Daily runs 7 times a week, weekdays 5, weekly once")
    try check(schedule(.cron, "*/30 * * * *").runsPerWeek(calendar: calendar) == 336
      && schedule(.cron, "0 9 * * 1-5").runsPerWeek(calendar: calendar) == 5,
      "A custom schedule counts its runs in a week (every 30 minutes is 336)")
    try check(schedule(.cron, "* * * * *").runsPerWeek(calendar: calendar) == 10_080,
      "Every minute counts as 10,080 runs a week, the most it counts")
    var ran = schedule(.daily)
    ran.history = [RelayReminder.Run(outcome: "done", tokens: 8_000), RelayReminder.Run(outcome: "done", tokens: 4_000)]
    try check(RelayReminder.typicalRunTokens(in: [ran, schedule(.weekly)], fallback: 50_000) == 6_000,
      "Before a schedule runs, its estimate uses what every schedule's runs used")
    try check(RelayReminder.typicalRunTokens(in: [schedule(.weekly)], fallback: 7_000) == 7_000
      && RelayReminder.typicalRunTokens(in: [], fallback: nil) == nil,
      "With no runs yet it uses an average turn on the AI app, and says nothing without one")
    try check(schedule(.daily).estimateLine(perRun: 6_000, calendar: calendar)
      == "About 7 runs a week at about 6k tokens each, about 42k tokens a week.",
      "The creation card estimates a week's tokens")
    try check(schedule(.weekdays).estimateLine(perRun: 2_750, calendar: calendar)
      == "About 5 runs a week at about 3k tokens each, about 15k tokens a week.",
      "The week's figure is the sum of the figures the line shows")
    try check(schedule(.cron, "*/30 * * * *").estimateLine(perRun: 6_000, calendar: calendar)
      == "About 336 runs a week at about 6k tokens each, about 2.0M tokens a week.",
      "A frequent schedule's estimate shows how fast it adds up")
    try check(schedule(.daily).estimateLine(perRun: nil, calendar: calendar)?.hasPrefix("About 7 runs a week.") == true
      && schedule(.none).estimateLine(perRun: nil, calendar: calendar) == nil,
      "Without a figure the card gives the runs alone, and nothing for a one-time request")
    try check(UsageReset.weekly(weekday: 2).share(weekly: 42_000, of: 500_000) == 8
      && UsageReset.daily.share(weekly: 42_000, of: 100_000) == 6
      && UsageReset.monthly(day: 1).share(weekly: 42_000, of: 1_000_000) == 18,
      "The estimate's share of a Settings › Usage warn level follows that level's period")
    var alert = RelayWatch(name: "Price", kind: .url, source: "https://example.com/price", minutes: 60)
    alert.history = [RelayReminder.Run(outcome: "nothing new"), RelayReminder.Run(outcome: "changed", tokens: 2_400),
                     RelayReminder.Run(outcome: "nothing new")]
    try check(alert.averageTokens == 2_400 && RelayWatch(name: "Quiet", kind: .url, source: "https://example.com", minutes: 60).averageTokens == nil,
      "An alert's cost is what its changes used; its checks read without a model")
    var ledger = UsageLedger()
    ledger.add(route: "claude:opus", calls: 4, tokens: 40_000, reported: true)
    try check(ledger.averageTokens("claude:opus") == 10_000 && ledger.averageTokens("codex:gpt") == nil,
      "An average turn on an AI app comes from Serein's own usage count")
  }
}
#endif
