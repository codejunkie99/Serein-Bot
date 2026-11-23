#if DEBUG
import Foundation
import SereinCore

/// Routine offers (SereinCore/RoutineOffers.swift): the kind of a request, the pattern of three
/// days at about the same time, the card's words, the caps and blocks, and the words that stop
/// suggestions.
extension AssistantCoreChecks {
  static func routineOffers(_ check: Check) throws {
    typealias R = RoutineOffers
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    // Wednesday 4 November 2026, 8:30 in the morning.
    let now = Date(timeIntervalSince1970: 1_793_781_000)
    let today: Date = calendar.startOfDay(for: now)
    func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
      let day: Date = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
      return day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }
    func asked(_ days: [(Int, Int, Int)], owner: String = "scout", kind: String = "weather") -> [R.Request] {
      days.map { R.Request(kind: kind, owner: owner, at: at($0.0, $0.1, $0.2)) }
    }

    // The kind of a request.
    try check(R.kind(of: "What is the weather today?")?.id == "weather", "A question about the weather is a weather request")
    try check(R.kind(of: "Any news this morning?")?.id == "news", "A question about the news is a news request")
    try check(R.kind(of: "Check my inbox")?.id == "email", "Checking the inbox is an email request")
    try check(R.kind(of: "Make me a sandwich") == nil, "Other words are no kind")
    try check(R.kind(of: "Tell me the weather every morning") == nil, "A request for a schedule never counts")
    try check(R.kind(of: "Stop suggesting routines") == nil, "Words about routines never count")
    try check(R.routineKind(of: "Check the weather every morning")?.id == "weather", "A routine's words name its kind")

    // The pattern: three days, about the same time.
    let row = asked([(2, 7, 42), (1, 7, 51), (0, 8, 5)])
    guard let pattern = R.pattern(row, kind: "weather", owner: "scout", now: now, calendar: calendar) else {
      try check(false, "Three mornings in a row make a pattern")
      return
    }
    let earliest: Int = 7 * 60 + 42
    try check(pattern.days == 3 && pattern.minute == earliest && pattern.inARow && !pattern.weekdaysOnly,
              "The pattern has 3 days, starts at the earliest time and is in a row")
    try check(R.pattern(asked([(1, 7, 42), (0, 8, 5)]), kind: "weather", owner: "scout", now: now, calendar: calendar) == nil,
              "Two days are not enough")
    try check(R.pattern(asked([(0, 7, 0), (0, 7, 30), (0, 8, 0)]), kind: "weather", owner: "scout", now: now, calendar: calendar) == nil,
              "Three times on one day are one day")
    try check(R.pattern(asked([(2, 7, 0), (1, 9, 0), (0, 11, 0)]), kind: "weather", owner: "scout", now: now, calendar: calendar) == nil,
              "Times more than 90 minutes apart do not count")
    try check(R.pattern(asked([(16, 7, 40), (15, 7, 45), (0, 7, 50)]), kind: "weather", owner: "scout", now: now, calendar: calendar) == nil,
              "Requests older than 14 days do not count")
    try check(R.pattern(row, kind: "weather", owner: "planner", now: now, calendar: calendar) == nil,
              "Another assistant's chat does not count")
    try check(R.pattern(row, kind: "news", owner: "scout", now: now, calendar: calendar) == nil, "Another kind does not count")
    let workdays = asked([(5, 7, 40), (2, 7, 45), (1, 7, 50)])
    let weekdays = R.pattern(workdays, kind: "weather", owner: "scout", now: now, calendar: calendar)
    try check(weekdays?.weekdaysOnly == true && weekdays?.inARow == false, "Friday, Monday and Tuesday with no weekend make a weekday habit")

    // The plan and the card's words.
    guard let weather = R.kind(id: "weather") else {
      try check(false, "The weather kind is known")
      return
    }
    let plan = R.plan(weather, pattern: pattern, owner: "scout")
    try check(plan.hour == 7 && plan.minute == 30 && plan.repeats == .daily && plan.what == "Tell you the weather",
              "The routine runs every day at 7:30, before the earliest request")
    let offer = R.offer(plan, pattern: pattern, kind: weather, id: "o1", twelveHour: true)
    try check(offer.title == "Make it a routine?" && offer.when == "Every day at 7:30 AM" && offer.what == "Tell you the weather"
                && offer.state == .open, "The card reads as board 13")
    try check(
      offer.detail == "You asked about the weather on 3 mornings in a row. I can tell you the weather at 7:30 AM each day.",
      "The card says why and when")
    try check(ReceiptCopy.lint("Okay. " + offer.when + " I will tell you the weather.").isEmpty, "The words are plain")
    if let habit = weekdays {
      let workPlan = R.plan(weather, pattern: habit, owner: "scout")
      let workOffer = R.offer(workPlan, pattern: habit, kind: weather, id: "o2", twelveHour: false)
      try check(workPlan.repeats == .weekdays && workOffer.when == "Every weekday at 7:30", "A weekday habit makes a weekday routine")
      // Saturday 7 November, 9:00: the first run is Monday at 7:30.
      let saturday = Date(timeIntervalSince1970: 1_794_042_000)
      try check(workPlan.firstDue(after: saturday, calendar: calendar) == Date(timeIntervalSince1970: 1_794_209_400),
                "A weekday routine's first run skips the weekend")
    }
    try check(R.clock(hour: 19, minute: 5, twelveHour: true) == "7:05 PM" && R.clock(hour: 0, minute: 0, twelveHour: true) == "12:00 AM"
                && R.clock(hour: 7, minute: 30, twelveHour: false) == "7:30", "Times read as the Mac shows them")
    let coded = try JSONEncoder().encode(offer)
    try check(try JSONDecoder().decode(RoutineOffer.self, from: coded) == offer, "An offer reads back the same after it is saved")

    // The book: caps, blocks and what is already a routine.
    var book = R.Book()
    for request in row { book.record(request, now: now) }
    book.record(R.Request(kind: "weather", owner: "scout", at: at(15, 7, 40)), now: now)
    try check(book.requests.count == 3, "The book forgets requests older than 14 days")
    let found = R.next(book: book, kind: weather, owner: "scout", existing: [], actionRoutinesOn: 0, now: now, calendar: calendar)
    try check(found?.plan == plan, "The third request makes an offer")
    try check(R.next(book: book, kind: weather, owner: "scout", existing: ["Check the weather every morning"], actionRoutinesOn: 0,
                     now: now, calendar: calendar) == nil, "No offer when that assistant has such a routine")
    try check(R.next(book: book, kind: weather, owner: "scout", existing: [], actionRoutinesOn: ScheduleGuard.maxActionRoutines,
                     now: now, calendar: calendar) == nil, "No offer when 20 routines run already")
    book.add(R.Book.Entry(offer: offer, plan: plan, chat: "chat-scout", at: now))
    try check(book.refusal(kind: "weather", owner: "scout", now: now) == .offeredAlready, "The same offer is not made twice")
    try check(book.refusal(kind: "news", owner: "scout", now: now) == .openForAssistant, "One open offer per assistant")
    try check(book.refusal(kind: "news", owner: "planner", now: now) == nil, "Another assistant may get one")
    var newsPlan = plan
    newsPlan.kind = "news"
    newsPlan.owner = "planner"
    book.add(R.Book.Entry(offer: offer, plan: newsPlan, chat: "chat-planner", at: now))
    try check(book.refusal(kind: "traffic", owner: "writer", now: now) == .weekFull, "At most 2 offers a week")
    var answered = R.Book()
    answered.add(R.Book.Entry(offer: offer, plan: plan, chat: "chat-scout", at: now))
    try check(answered.answer("o1", .declined, now: now), "Not now answers an open offer")
    try check(!answered.answer("o1", .made, now: now), "An answered offer takes no second answer")
    try check(answered.refusal(kind: "weather", owner: "scout", now: now.addingTimeInterval(86_400)) == .blocked,
              "Not now blocks the same offer")
    try check(answered.refusal(kind: "weather", owner: "scout", now: now.addingTimeInterval(31 * 86_400)) == nil,
              "The block ends after 30 days")

    // The words that stop suggestions.
    try check(R.stopsSuggestions("Stop suggesting routines") && R.stopsSuggestions("Please stop suggesting routines.")
                && R.stopsSuggestions("don't suggest routines please"), "Typed words stop suggestions")
    try check(!R.stopsSuggestions("Why do you stop suggesting routines?") && !R.stopsSuggestions("stop"),
              "Only the whole message stops them")
    try check(ReceiptCopy.lint(R.stoppedLine).isEmpty, "The receipt after it is plain")
  }
}
#endif
