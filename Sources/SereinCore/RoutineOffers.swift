import Foundation

/// A "Make it a routine?" card in a reply (board 13). Serein offers a routine after the person
/// asked for the same kind of thing at about the same time of day on three days; it never makes
/// one by itself. Only "Make it" makes it, through the same path as a typed routine.
public struct RoutineOffer: Codable, Equatable, Sendable, Identifiable {
  /// Stable for this offer.
  public var id: String
  /// "Make it a routine?"
  public var title: String
  /// "You asked about the weather on 3 mornings in a row. I can tell you the weather at 7:30 AM each day."
  public var detail: String
  /// "Every day at 7:30 AM"
  public var when: String
  /// "Tell you the weather"
  public var what: String
  public var state: State
  public enum State: String, Codable, Sendable { case open, made, declined }

  public init(id: String, title: String, detail: String, when: String, what: String, state: State = .open) {
    self.id = id
    self.title = title
    self.detail = detail
    self.when = when
    self.what = what
    self.state = state
  }
}

/// The pure rules behind routine offers. Only the person's own typed words count, as a kind of
/// request (`kind(of:)`) and a time: never the words themselves. An offer needs the same kind
/// in the same assistant's chat on `minDays` days in the last `lookBack`, at times of day that fit
/// in `spread` minutes, and no routine of that kind for that assistant yet. At most
/// `maxOpenPerAssistant` offer is open per assistant and `maxPerWeek` are made a week; "Not now"
/// blocks the same offer for `blockDays` days.
public enum RoutineOffers {
  public static let title = "Make it a routine?"
  public static let minDays = 3
  public static let lookBack: TimeInterval = 14 * 86_400
  /// The times of day of the requests fit in this many minutes.
  public static let spread = 90
  public static let maxOpenPerAssistant = 1
  public static let maxPerWeek = 2
  public static let blockDays = 30
  /// An offer nobody answered for this many days no longer counts as open.
  public static let lapseDays = 7
  /// The most requests the book keeps.
  public static let maxRequests = 400
  /// The routine runs at the earliest time of the requests, rounded down to this many minutes.
  static let roundTo = 15

  /// One kind of request worth a routine, by the words that name it.
  public struct Kind: Equatable, Sendable {
    public let id: String
    let words: [String]
    /// What the routine does, in the words of its card: "Tell you the weather".
    public let what: String
    /// What the person asked about: "the weather".
    public let about: String
  }
  public static let kinds: [Kind] = [
    Kind(id: "weather", words: ["weather", "forecast", "temperature", "rain", "raining"], what: "Tell you the weather", about: "the weather"),
    Kind(id: "news", words: ["news", "headlines"], what: "Tell you the news", about: "the news"),
    Kind(id: "email", words: ["email", "emails", "mail", "inbox", "unread"], what: "Sum up your new email", about: "your email"),
    Kind(
      id: "calendar", words: ["calendar", "agenda", "meetings", "meeting"], what: "Tell you what is on your calendar",
      about: "your calendar"),
    Kind(
      id: "markets", words: ["stocks", "stock", "market", "markets", "portfolio"], what: "Tell you how the markets are doing",
      about: "the markets"),
    Kind(id: "traffic", words: ["traffic", "commute"], what: "Tell you about the traffic", about: "the traffic"),
    Kind(id: "slack", words: ["slack"], what: "Sum up Slack", about: "Slack"),
  ]
  /// Words that make a message a request for a schedule, or about routines: it never counts.
  static let scheduleWords: [String] = [
    "every", "daily", "weekly", "remind", "reminder", "reminders", "routine", "routines", "each morning", "each day",
  ]

  /// The kind of request the person's own message is, or nil. A message that asks for a schedule
  /// or speaks of routines is none.
  public static func kind(of message: String) -> Kind? {
    let words = TypedConsent.normalized(message)
    guard !TypedConsent.contains(words, any: scheduleWords) else { return nil }
    return kinds.first { TypedConsent.contains(words, any: $0.words) }
  }
  /// The kind a routine's own words name, schedule words or not ("Check the weather every
  /// morning" is a weather routine).
  public static func routineKind(of text: String) -> Kind? {
    let words = TypedConsent.normalized(text)
    return kinds.first { TypedConsent.contains(words, any: $0.words) }
  }
  public static func kind(id: String) -> Kind? { kinds.first { $0.id == id } }

  /// One request the person typed: its kind, the assistant whose chat it was, and when.
  public struct Request: Codable, Equatable, Sendable {
    public var kind: String
    public var owner: String
    public var at: Date
    public init(kind: String, owner: String, at: Date) {
      self.kind = kind
      self.owner = owner
      self.at = at
    }
  }

  /// When the person asks: how many days, the earliest time of day (minutes after midnight),
  /// whether they skipped a weekend in between, and whether the days were in a row.
  public struct Pattern: Equatable, Sendable {
    public var days: Int
    public var minute: Int
    public var weekdaysOnly: Bool
    public var inARow: Bool
  }

  /// The requests of `kind` in `owner`'s chat in the last `lookBack`, on at least `minDays`
  /// different days, whose times of day fit in `spread` minutes. The group with the most days
  /// wins. nil when there is none.
  public static func pattern(_ requests: [Request], kind: String, owner: String, now: Date, calendar: Calendar) -> Pattern? {
    var points: [(day: Date, minute: Int)] = []
    for request in requests where request.kind == kind && request.owner == owner {
      let age: TimeInterval = now.timeIntervalSince(request.at)
      guard age >= 0, age <= lookBack else { continue }
      let parts = calendar.dateComponents([.hour, .minute], from: request.at)
      let minute: Int = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
      points.append((day: calendar.startOfDay(for: request.at), minute: minute))
    }
    let sorted = points.sorted { $0.minute < $1.minute }
    var best: [(day: Date, minute: Int)] = []
    var bestDays = 0
    for i in sorted.indices {
      let start: Int = sorted[i].minute
      let group = sorted[i...].filter { $0.minute - start <= spread }
      let days: Int = Set(group.map { $0.day }).count
      if days > bestDays {
        best = Array(group)
        bestDays = days
      }
    }
    guard bestDays >= minDays, let first = best.first else { return nil }
    let days: [Date] = Set(best.map { $0.day }).sorted()
    var inARow = true
    for (a, b) in zip(days, days.dropFirst()) where calendar.dateComponents([.day], from: a, to: b).day != 1 {
      inARow = false
    }
    var weekdaysOnly = false
    if let start = days.first, let end = days.last, !days.contains(where: { calendar.isDateInWeekend($0) }) {
      // Only weekdays, with a weekend in between that had none: it is a weekday habit.
      var day = start
      while day <= end {
        if calendar.isDateInWeekend(day) { weekdaysOnly = true }
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
    }
    return Pattern(days: bestDays, minute: first.minute, weekdaysOnly: weekdaysOnly, inARow: inARow)
  }

  /// The routine an offer makes: whose, at what time, on which days, and its words. Kept with
  /// the offer; the card shows only `RoutineOffer`.
  public struct Plan: Codable, Equatable, Sendable {
    public var kind: String
    public var owner: String
    public var hour: Int
    public var minute: Int
    public var weekdays: Bool
    /// The routine's words, as its card and receipt read them: "Tell you the weather".
    public var what: String
    public var repeats: RelayReminder.Repeat { weekdays ? .weekdays : .daily }

    /// The first run after `now`: the plan's time today or later, on a weekday when it runs on
    /// weekdays.
    public func firstDue(after now: Date, calendar: Calendar) -> Date? {
      let wanted = DateComponents(hour: hour, minute: minute)
      var next: Date? = calendar.nextDate(after: now, matching: wanted, matchingPolicy: .nextTime)
      var tries = 0
      while weekdays, let found = next, calendar.isDateInWeekend(found), tries < 7 {
        next = calendar.nextDate(after: found, matching: wanted, matchingPolicy: .nextTime)
        tries += 1
      }
      return next
    }
  }

  /// The plan for `pattern`: the earliest time, rounded down to `roundTo` minutes.
  public static func plan(_ kind: Kind, pattern: Pattern, owner: String) -> Plan {
    let rounded: Int = (pattern.minute / roundTo) * roundTo
    return Plan(
      kind: kind.id, owner: owner, hour: rounded / 60, minute: rounded % 60, weekdays: pattern.weekdaysOnly,
      what: kind.what)
  }

  /// The card's words (board 13). `twelveHour`: the Mac shows times as "7:30 AM".
  public static func offer(_ plan: Plan, pattern: Pattern, kind: Kind, id: String, twelveHour: Bool) -> RoutineOffer {
    let time: String = clock(hour: plan.hour, minute: plan.minute, twelveHour: twelveHour)
    let when: String = (plan.weekdays ? "Every weekday at " : "Every day at ") + time
    let row: String = pattern.inARow ? " in a row" : ""
    let each: String = plan.weekdays ? "each weekday" : "each day"
    let doing: String = ReceiptCopy.lowercasedFirst(kind.what)
    let detail: String =
      "You asked about \(kind.about) on \(pattern.days) \(partOfDay(pattern.minute))\(row). I can \(doing) at \(time) \(each)."
    return RoutineOffer(id: id, title: title, detail: detail, when: when, what: kind.what, state: .open)
  }

  /// "mornings", "afternoons", "evenings" or "nights", for a time of day in minutes.
  static func partOfDay(_ minute: Int) -> String {
    let hour: Int = minute / 60
    if hour >= 5 && hour < 12 { return "mornings" }
    if hour >= 12 && hour < 17 { return "afternoons" }
    if hour >= 17 && hour < 22 { return "evenings" }
    return "nights"
  }

  /// "7:30 AM" on a 12-hour Mac, "7:30" on a 24-hour one.
  public static func clock(hour: Int, minute: Int, twelveHour: Bool) -> String {
    guard twelveHour else { return String(format: "%d:%02d", hour, minute) }
    let shown: Int = hour % 12 == 0 ? 12 : hour % 12
    return String(format: "%d:%02d", shown, minute) + (hour < 12 ? " AM" : " PM")
  }

  /// Why no offer is made now.
  public enum Refusal: Equatable, Sendable {
    /// That assistant has an open offer already.
    case openForAssistant
    /// Two offers were made in the last week.
    case weekFull
    /// The person said "Not now" to this offer in the last `blockDays` days.
    case blocked
    /// This offer is open, or was made, already.
    case offeredAlready
  }

  /// What Serein keeps about offers (relay/routine-offers.json): the kinds and times of the
  /// person's requests of the last `lookBack` (never their words), each offer with its plan and
  /// chat, and the "Not now" blocks.
  public struct Book: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
      public var offer: RoutineOffer
      public var plan: Plan
      /// The chat whose reply carries the card.
      public var chat: String
      public var at: Date
      public init(offer: RoutineOffer, plan: Plan, chat: String, at: Date) {
        self.offer = offer
        self.plan = plan
        self.chat = chat
        self.at = at
      }
    }
    public struct Block: Codable, Equatable, Sendable {
      public var kind: String
      public var owner: String
      public var until: Date
    }
    public var requests: [Request] = []
    public var entries: [Entry] = []
    public var blocks: [Block] = []
    public init() {}

    /// Keeps one request, and forgets what is older than `lookBack`.
    public mutating func record(_ request: Request, now: Date) {
      requests.append(request)
      trim(now: now)
    }
    /// Drops requests older than `lookBack` (at most `maxRequests` stay), blocks that ended, and
    /// offers older than `blockDays`.
    public mutating func trim(now: Date) {
      requests = requests.filter { now.timeIntervalSince($0.at) <= RoutineOffers.lookBack }
      if requests.count > RoutineOffers.maxRequests { requests.removeFirst(requests.count - RoutineOffers.maxRequests) }
      blocks = blocks.filter { $0.until > now }
      let keep: TimeInterval = TimeInterval(RoutineOffers.blockDays) * 86_400
      entries = entries.filter { now.timeIntervalSince($0.at) <= keep }
    }
    public func entry(_ id: String) -> Entry? { entries.first { $0.offer.id == id } }
    /// Open and not lapsed.
    func isOpen(_ entry: Entry, now: Date) -> Bool {
      entry.offer.state == .open && now.timeIntervalSince(entry.at) < TimeInterval(RoutineOffers.lapseDays) * 86_400
    }

    /// Why no offer of `kind` for `owner` may be made now, or nil.
    public func refusal(kind: String, owner: String, now: Date) -> Refusal? {
      if blocks.contains(where: { $0.kind == kind && $0.owner == owner && $0.until > now }) { return .blocked }
      let same = entries.filter { $0.plan.kind == kind && $0.plan.owner == owner }
      if same.contains(where: { isOpen($0, now: now) || $0.offer.state == .made }) { return .offeredAlready }
      let open: Int = entries.filter { $0.plan.owner == owner && isOpen($0, now: now) }.count
      if open >= RoutineOffers.maxOpenPerAssistant { return .openForAssistant }
      let week: Int = entries.filter { now.timeIntervalSince($0.at) < 7 * 86_400 }.count
      if week >= RoutineOffers.maxPerWeek { return .weekFull }
      return nil
    }

    public mutating func add(_ entry: Entry) { entries.append(entry) }

    /// The person's answer on the card: "Make it" (`.made`) or "Not now" (`.declined`, which
    /// blocks the same offer for `blockDays` days). False when there is no such open offer.
    @discardableResult public mutating func answer(_ id: String, _ state: RoutineOffer.State, now: Date) -> Bool {
      guard let i = entries.firstIndex(where: { $0.offer.id == id }), entries[i].offer.state == .open else { return false }
      entries[i].offer.state = state
      if state == .declined {
        let until: Date = now.addingTimeInterval(TimeInterval(RoutineOffers.blockDays) * 86_400)
        blocks.append(Block(kind: entries[i].plan.kind, owner: entries[i].plan.owner, until: until))
      }
      return true
    }
  }

  /// The offer to make after the person's request of `kind` in `owner`'s chat, or nil: a
  /// pattern, no routine of that kind for that assistant yet (`existing`: the words of its
  /// routines that act), room under `ScheduleGuard`'s count, and no refusal by the book.
  public static func next(
    book: Book, kind: Kind, owner: String, existing: [String], actionRoutinesOn: Int, now: Date, calendar: Calendar
  ) -> (plan: Plan, pattern: Pattern)? {
    guard actionRoutinesOn < ScheduleGuard.maxActionRoutines else { return nil }
    guard !existing.contains(where: { routineKind(of: $0)?.id == kind.id }) else { return nil }
    guard book.refusal(kind: kind.id, owner: owner, now: now) == nil else { return nil }
    guard let found = pattern(book.requests, kind: kind.id, owner: owner, now: now, calendar: calendar) else { return nil }
    let made = plan(kind, pattern: found, owner: owner)
    guard ScheduleGuard.check(cron: "\(made.minute) \(made.hour) * * *", acts: true, actionRoutinesOn: actionRoutinesOn) == nil else {
      return nil
    }
    return (plan: made, pattern: found)
  }

  /// The whole message turns suggestions off: "stop suggesting routines" and the like.
  static let stopPhrases: [String] = [
    "stop suggesting routines", "stop offering routines", "do not suggest routines", "don t suggest routines",
    "no more routine suggestions", "stop routine suggestions", "turn off routine suggestions",
  ]
  public static func stopsSuggestions(_ message: String) -> Bool {
    var words = TypedConsent.normalized(message)
    if words.hasSuffix(" please ") { words = String(words.dropLast(7)) }
    if words.hasPrefix(" please ") { words = String(words.dropFirst(7)) }
    return stopPhrases.contains { words == " " + $0 + " " }
  }
  /// The receipt line when the person's words turned suggestions off (SPEC 2.4, a setting by words).
  public static let stoppedLine = "Okay. I will not suggest routines."
}
