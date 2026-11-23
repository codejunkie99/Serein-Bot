import Foundation
import SereinCore

/// A schedule's cost in words, for its creation card, Agents at work and Settings › Serein. The
/// numbers are the tokens the AI app reported for its runs (RelayCost.swift); a schedule that has
/// not run yet is estimated from every schedule's runs, else an average turn on the AI app.
extension RelayOrchestrator {
  /// What a new or edited schedule will likely use, before it runs: “About 7 runs a week at about
  /// 6k tokens each, about 42k tokens a week.”, with its share of the warn level Settings › Usage
  /// keeps for the AI app it runs on, when there is one. nil when there is nothing to go on.
  func costEstimate(_ reminder: RelayReminder) -> String? {
    // Scheduled turns run on the active assistant's engine (drainScheduled).
    let engine = assistantEngine(team.active)
    let route = UsageLedger.route(provider: engine.provider.rawValue, model: engine.model)
    let usage = RouteUsage.shared
    let perRun = reminder.averageTokens
      ?? RelayReminder.typicalRunTokens(in: reminders, fallback: usage.ledger.averageTokens(route))
    guard var line = reminder.estimateLine(perRun: perRun) else { return nil }
    if let perRun, reminder.repeats != .none, let level = usage.warnings[route], level > 0 {
      let share = usage.reset.share(weekly: reminder.weeklyEstimate(perRun: perRun), of: level)
      if share >= 1 {
        line += " That is about \(share)% of the \(UsageLedger.Summary.short(level)) tokens \(usage.reset.each) you set for \(RouteUsage.name(route)) in Settings › Usage."
      }
    }
    return line
  }

  /// This week's count, with its limit: “27k of 50k this week”, “27k this week”; nil before a run
  /// this week reported tokens.
  static func weekLine(_ reminder: RelayReminder, now: Date = Date()) -> String? {
    let used = reminder.tokensThisWeek(now: now)
    guard used > 0 || reminder.weeklyTokens != nil else { return nil }
    let short = UsageLedger.Summary.short
    return reminder.weeklyTokens.map { "\(short(used)) of \(short($0)) this week" } ?? "\(short(used)) this week"
  }
  /// Why its weekly limit paused it and when it runs again: “Paused until Monday: it used 52k of
  /// its 50k tokens this week.”
  static func costPauseLine(_ reminder: RelayReminder, now: Date = Date()) -> String {
    let short = UsageLedger.Summary.short
    let again = RelayReminder.nextWeek(after: now).formatted(.dateTime.weekday(.wide))
    let used = short(reminder.tokensThisWeek(now: now))
    return "Paused until \(again): it used \(used) of its \(reminder.weeklyTokens.map(short) ?? "") tokens this week."
  }
}
