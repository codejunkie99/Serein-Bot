import Foundation

/// What a schedule costs, in the tokens the AI app reported for its runs (RunRecord.tokens): a
/// count for the current week, an optional weekly limit whose pause stops only this schedule and
/// lifts on its own when the next week begins, and the estimate its creation card shows before
/// anything runs. Everything here is pure, so it is checked in ScheduleCostChecks.
extension RelayReminder {
  /// The weekly limits Settings offers.
  public static let weeklyTokenChoices = [25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
  /// What a weekly limit may be set to.
  public static let weeklyTokenRange = 1_000...100_000_000
  /// The most runs a week the estimate counts (a cron firing every minute).
  static let countedRuns = 10_080

  /// Midnight on the first day of the week `date` falls in, in the person's calendar.
  public static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
  }
  /// When the next week begins: when a schedule its weekly limit paused runs again.
  public static func nextWeek(after date: Date, calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart(of: date, calendar: calendar)) ?? date
  }

  /// Tokens its runs used this week; 0 once a new week began.
  public func tokensThisWeek(now: Date, calendar: Calendar = .current) -> Int {
    guard let weekStart, weekStart == Self.weekStart(of: now, calendar: calendar) else { return 0 }
    return weekTokens ?? 0
  }
  /// This week's runs used up its weekly limit.
  public func overWeeklyLimit(now: Date, calendar: Calendar = .current) -> Bool {
    weeklyTokens.map { tokensThisWeek(now: now, calendar: calendar) >= $0 } ?? false
  }

  /// One run's tokens counted toward its week, a new week starting the count over. The run that
  /// brings the week to its limit pauses the schedule until the next week; `paused` is true when
  /// this run did. A schedule already paused only counts.
  public func counting(tokens: Int, now: Date, calendar: Calendar = .current) -> (reminder: RelayReminder, paused: Bool) {
    guard tokens > 0 else { return (self, false) }
    var copy = self
    let start = Self.weekStart(of: now, calendar: calendar)
    if copy.weekStart != start {
      copy.weekStart = start
      copy.weekTokens = nil
    }
    copy.weekTokens = min(1_000_000_000_000, (copy.weekTokens ?? 0) + tokens)
    guard copy.paused != true, copy.overWeeklyLimit(now: now, calendar: calendar) else { return (copy, false) }
    return (copy.pausingForCost(), true)
  }
  /// Paused by its weekly limit, which Agents at work and Settings name with when it runs again.
  public func pausingForCost() -> RelayReminder {
    var copy = self
    copy.paused = true
    copy.pausedByCost = true
    return copy
  }
  /// Lifts the pause its weekly limit made once the week's count is under the limit again (a new
  /// week, a higher limit or none): it runs from its next time. A schedule that also used up its
  /// run limit or whose goal ended stays paused for the person. nil when nothing changes.
  public func liftingCostPause(now: Date, calendar: Calendar = .current) -> RelayReminder? {
    guard pausedByCost == true, paused == true, !overWeeklyLimit(now: now, calendar: calendar) else { return nil }
    var copy = self
    copy.pausedByCost = nil
    guard !limitReached, !goalEnded else { return copy }
    copy.paused = nil
    if copy.due <= now, let next = copy.next(after: now, calendar: calendar) { copy.due = next }
    return copy
  }
  /// The same schedule with a new weekly limit (nil removes it). A schedule the old limit paused
  /// runs again when the new one is above this week's count.
  public func limitingWeek(to tokens: Int?, now: Date, calendar: Calendar = .current) throws -> RelayReminder {
    if let tokens, !Self.weeklyTokenRange.contains(tokens) {
      throw SereinError.invalid("A weekly token limit is 1,000 to 100,000,000 tokens.")
    }
    var copy = self
    copy.weeklyTokens = tokens
    return copy.liftingCostPause(now: now, calendar: calendar) ?? copy
  }

  /// About how many times it runs in a week: 7 for daily, 5 for weekdays, 1 for weekly or once,
  /// and for a cron its runs in the seven days from its next one.
  public func runsPerWeek(calendar: Calendar = .current) -> Int {
    switch repeats {
    case .none, .weekly: return 1
    case .daily: return 7
    case .weekdays: return 5
    case .cron:
      guard let cron, let schedule = RelayCron(parse: cron) else { return 1 }
      // A minute before, so the run at its next time counts.
      var at = due.addingTimeInterval(-60)
      let end = at.addingTimeInterval(7 * 86_400)
      var count = 0
      while count < Self.countedRuns, let next = schedule.next(after: at, calendar: calendar), next <= end {
        count += 1
        at = next
      }
      return max(1, count)
    }
  }
  /// What one run is likely to use before this schedule has run: the average over every
  /// schedule's runs that reported tokens, else `fallback` (an average turn on its AI app); nil
  /// when neither is known.
  public static func typicalRunTokens(in reminders: [RelayReminder], fallback: Int?) -> Int? {
    let counted = reminders.flatMap { $0.history ?? [] }.compactMap(\.tokens).filter { $0 > 0 }
    guard !counted.isEmpty else { return fallback.flatMap { $0 > 0 ? $0 : nil } }
    return counted.reduce(0, +) / counted.count
  }
  /// Tokens a week at `perRun` a run.
  public func weeklyEstimate(perRun: Int, calendar: Calendar = .current) -> Int {
    perRun * runsPerWeek(calendar: calendar)
  }
  /// The creation card's estimate: "About 7 runs a week at about 6k tokens each, about 42k tokens
  /// a week." Without a token figure it gives the runs alone; nil for a one-time request with none.
  public func estimateLine(perRun: Int?, calendar: Calendar = .current) -> String? {
    let short = UsageLedger.Summary.short
    if repeats == .none { return perRun.map { "One run, likely about \(short($0)) tokens." } }
    let runs = runsPerWeek(calendar: calendar)
    let count = runs == 1 ? "About 1 run a week" : "About \(runs.formatted()) runs a week"
    guard let perRun else { return "\(count). Settings shows what each run uses after the first." }
    // The week from the figure the line shows, so the two read as one sum.
    let shown = perRun < 1000 ? perRun : Int((Double(perRun) / 1000).rounded()) * 1000
    return "\(count) at about \(short(perRun)) tokens each, about \(short(shown * runs)) tokens a week."
  }
  /// Its limit in words: "50k tokens a week", or "none".
  public var weeklyLimitTitle: String {
    weeklyTokens.map { "\(UsageLedger.Summary.short($0)) tokens a week" } ?? "none"
  }
}

extension RelayWatch {
  /// What one change costs on average: a check reads without a model, and only a change starts a
  /// turn, whose tokens land on the run that recorded the change. nil before any reported some.
  public var averageTokens: Int? {
    let counted = (history ?? []).compactMap(\.tokens).filter { $0 > 0 }
    return counted.isEmpty ? nil : counted.reduce(0, +) / counted.count
  }
}

extension UsageReset {
  /// `weekly` tokens as a whole-percent share of `level` tokens per period of this reset (a day is
  /// a seventh of a week, a month 30.44 days).
  public func share(weekly: Int, of level: Int) -> Int {
    guard level > 0 else { return 0 }
    let perPeriod: Double
    switch self {
    case .daily: perPeriod = Double(weekly) / 7
    case .weekly: perPeriod = Double(weekly)
    case .monthly: perPeriod = Double(weekly) * 30.44 / 7
    }
    return Int((perPeriod / Double(level) * 100).rounded())
  }
  /// "a day", "a week", "a month".
  public var each: String {
    switch self {
    case .daily: return "a day"
    case .weekly: return "a week"
    case .monthly: return "a month"
    }
  }
}

extension UsageLedger {
  /// What one turn on `route` used on average over the kept days; nil before any.
  public func averageTokens(_ route: String) -> Int? {
    let rows = entries.filter { $0.route == route }
    let calls = rows.reduce(0) { $0 + $1.calls }
    return calls > 0 ? rows.reduce(0) { $0 + $1.tokens } / calls : nil
  }
}
