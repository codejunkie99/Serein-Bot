#if DEBUG
import Foundation
import SereinCore

/// A reply's citations tie to the claims they close (CitedAnswer), and every limit Serein knows
/// shows as a meter that warns near it (UsageMeter).
extension AssistantCoreChecks {
  static func citedUsage(_ check: Check) throws {
    let reply = """
      Heat wears a battery fastest [1]. Holding it near 80% helps [2]. Shallow top-ups are gentler \
      ([Cell notes](https://www.cells.example/depth)).

      - Keep it cool [1, 3].

      1. [How heat ages a battery](https://power.example/heat)
      2. Charge limits - https://charge.example/limits.
      [3]: https://care.example/storage
      """
    guard let cited = CitedAnswer(reply: reply) else { throw SereinError.invalid("FAIL: A reply with markers and a source list has citations") }
    try check(cited.sources.map(\.number) == [1, 2, 3, 4]
        && cited.source(1)?.title == "How heat ages a battery" && cited.source(2)?.url == "https://charge.example/limits"
        && cited.source(2)?.title == "Charge limits" && cited.source(3)?.title == nil
        && cited.source(4)?.host == "cells.example" && cited.source(4)?.title == "Cell notes",
      "Numbered list lines, [n]: lines and a citation link each name a page, numbered after the list")
    let paragraph = "Heat wears a battery fastest [1]. Holding it near 80% helps [2]. Shallow top-ups are gentler ([Cell notes](https://www.cells.example/depth))."
    let marked = cited.marked(paragraph)
    try check(marked == "Heat wears a battery fastest [1]. Holding it near 80% helps [2]. Shallow top-ups are gentler [4].",
      "A citation link becomes a plain marker for its page")
    let marks = cited.marks(in: marked)
    func words(_ range: Range<Int>, in text: String) -> String { String(Array(text)[range]) }
    try check(marks.map(\.number) == [1, 2, 4]
        && marks.map { words($0.claim, in: marked) } == ["Heat wears a battery fastest", "Holding it near 80% helps", "Shallow top-ups are gentler"]
        && marks.allSatisfy { words($0.marker, in: marked) == "[\($0.number)]" },
      "Each marker lights only the sentence it closes")
    let pair = cited.marked("Keep it cool [1, 3].")
    let grouped = cited.marks(in: pair)
    try check(pair == "Keep it cool [1][3]." && grouped.map(\.number) == [1, 3] && grouped[0].claim == grouped[1].claim
        && words(grouped[0].claim, in: pair) == "Keep it cool",
      "Markers side by side close the same claim")
    let split = cited.marks(in: "Heat is bad [1] and cold is fine [3].")
    try check(split.count == 2 && words(split[1].claim, in: "Heat is bad [1] and cold is fine [3].") == "and cold is fine",
      "A second marker in one sentence lights only the words after the first")
    try check(cited.marks(in: "[1]: https://power.example/heat").isEmpty && cited.marks(in: "See [9] later.").isEmpty,
      "A definition line and an unknown number are not citations")
    try check(cited.marked("Read [the guide](https://power.example/guide) first.") == "Read [the guide](https://power.example/guide) first.",
      "A link that is part of the sentence stays a link")
    try check(CitedAnswer(reply: "No sources here [1].") == nil
        && CitedAnswer(reply: "Read [the guide](https://power.example/guide).") == nil
        && CitedAnswer(reply: "A claim [1].\n\n1. [Script](javascript:alert(1)) see http") == nil
        && CitedAnswer(reply: "A claim ([x](file:///etc/passwd)).") == nil,
      "A reply cites nothing without an http or https page for a marker or a citation link")
    let numbered = CitedAnswer(reply: "A claim [2](https://one.example/a). Another [2](https://two.example/b).")
    try check(numbered?.sources.map(\.number) == [2, 3] && numbered?.marked("Another [2](https://two.example/b).") == "Another [3].",
      "A numbered link keeps its number unless another page already has it")

    var job = try ResearchJob(question: "Does heat age batteries?",
      sources: [ResearchJob.Source(url: "https://example.com/heat", question: "Heat"),
                ResearchJob.Source(url: "https://example.org/heat", question: "Heat too")],
      thread: "t", owner: "o", provider: "claude", model: "m", checksEnabled: false)
    job.sources[0].findings = [ResearchJob.Finding(answer: "Heat ages cells.", quote: "heat is the main cause of ageing")]
    let report = CitedAnswer(research: job)
    try check(report.claims.count == 1 && report.claims[0].citations.map(\.number) == [1]
        && report.claims[0].citations[0].quote == "heat is the main cause of ageing" && report.claims[0].outcome == nil
        && report.source(2)?.host == "example.org",
      "A research claim cites the page its quote was matched on, with the quote")

    let calendar = Calendar(identifier: .gregorian)
    func day(_ text: String) -> Date {
      let parts = text.split(separator: "-").compactMap { Int($0) }
      return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) ?? Date()
    }
    let now = day("2026-11-15")
    try check(UsageReset.monthly(day: 1).end(of: now, calendar: calendar) == calendar.startOfDay(for: day("2026-12-01"))
        && UsageReset.daily.end(of: now, calendar: calendar) == calendar.startOfDay(for: day("2026-11-16"))
        && UsageReset.weekly(weekday: 2).end(of: now, calendar: calendar) == calendar.startOfDay(for: day("2026-11-16")),
      "A period ends where the next one starts")
    var ledger = UsageLedger()
    ledger.add(route: "claude:opus", tokens: 420_000, reported: true, at: now, calendar: calendar)
    ledger.add(route: "codex:gpt", tokens: 520_000, reported: false, at: now, calendar: calendar)
    ledger.add(route: "local:small", tokens: 90_000, reported: true, at: now, calendar: calendar)
    let meters = ledger.meters(warnings: ["claude:opus": 500_000, "codex:gpt": 500_000, "local:small": 1_000_000, "none:x": 0],
      reset: .monthly(day: 1), at: now, calendar: calendar) { $0.uppercased() }
    try check(meters.map(\.id) == ["route:codex:gpt", "route:claude:opus", "route:local:small"]
        && meters.map(\.level) == [.reached, .near, .under] && meters[0].name == "CODEX:GPT"
        && meters[0].estimated && !meters[1].estimated && meters[1].left == 80_000,
      "Each route with a warning level is a meter, fullest first, and a route without one is not")
    try check(meters[1].line == "420k of 500k tokens" && meters[0].line == "~520k of 500k tokens"
        && meters[1].warning(at: now, calendar: calendar)?.hasPrefix("CLAUDE:OPUS is at 84% of its 500k tokens. Counts start over ") == true
        && meters[0].warning(at: now, calendar: calendar)?.hasPrefix("CODEX:GPT used ~520k of 500k tokens.") == true,
      "A meter warns in words from four fifths of its limit and past it")
    let start = calendar.startOfDay(for: day("2026-11-01"))
    let end = calendar.startOfDay(for: day("2026-12-01"))
    let onPace = UsageMeter(id: "a", name: "A", used: 350_000, limit: 500_000, start: start, end: end)
    let early = UsageMeter(id: "b", name: "B", used: 300_000, limit: 500_000, start: start, end: end)
    try check(onPace.level == .under && onPace.warning(at: now, calendar: calendar)?.hasPrefix("At this pace A reaches its 500k tokens") == true
        && early.pace(at: day("2026-11-03")) == nil && meters[2].warning(at: now, calendar: calendar) == nil,
      "A meter under its limit warns only when the pace so far passes it, and says nothing about pace early in the period")
    var reminder = RelayReminder(id: "r", text: "Morning brief", due: now, repeats: .daily, action: true)
    try check(reminder.meter(now: now, calendar: calendar) == nil, "A schedule without a weekly limit has no meter")
    reminder.weeklyTokens = 50_000
    reminder = reminder.counting(tokens: 41_000, now: now, calendar: calendar).reminder
    try check(reminder.meter(now: now, calendar: calendar).map { $0.used == 41_000 && $0.level == .near } == true,
      "A schedule's weekly limit is a meter over its week")
  }
}
#endif
