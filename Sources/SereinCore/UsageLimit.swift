import Foundation

/// An AI app said its usage limit is reached, and when it resets if it said so. Read only from
/// that app's own answer (its stream event, its error text, or an API route's HTTP 429 headers),
/// never guessed: with no time it names, `resetsAt` is nil and Serein offers Continue now and
/// another AI app only. Everything here is pure, so SereinChecks covers it. The answer is
/// untrusted: only the first `textLimit` characters are read, and only a reset after now and
/// within `horizon` counts.
public struct UsageLimit: Equatable, Sendable {
  /// When the app said the limit resets; nil when it named no usable time.
  public var resetsAt: Date?
  public init(resetsAt: Date?) { self.resetsAt = resetsAt }

  /// The most of an answer read for a limit.
  public static let textLimit = 4000
  /// A reset further out than this is not believed (no app's window is longer than a week).
  public static let horizon: TimeInterval = 7 * 24 * 60 * 60

  /// `date` when it is after `now` and within the horizon, else nil.
  static func bounded(_ date: Date?, now: Date) -> Date? {
    guard let date, date > now, date.timeIntervalSince(now) <= horizon else { return nil }
    return date
  }

  // MARK: reading the answer

  /// Claude Code's stream event for a refused request: `rate_limit_event` whose
  /// `rate_limit_info.status` is `rejected`, with `resetsAt` (Unix time; read as milliseconds
  /// when it is that large). A rejection that needs credits bought names no reset that waiting
  /// would reach, so it carries none.
  public static func claudeEvent(_ event: [String: Any], now: Date) -> UsageLimit? {
    guard event["type"] as? String == "rate_limit_event", let info = event["rate_limit_info"] as? [String: Any],
      info["status"] as? String == "rejected"
    else { return nil }
    guard info["errorCode"] as? String != "credits_required", let raw = (info["resetsAt"] as? NSNumber)?.doubleValue
    else { return UsageLimit(resetsAt: nil) }
    let seconds = raw > 100_000_000_000 ? raw / 1000 : raw
    return UsageLimit(resetsAt: bounded(Date(timeIntervalSince1970: seconds), now: now))
  }

  /// A harness's error text, read with that harness's own patterns only (`harness`; nil, or a
  /// harness without known patterns, reads nothing):
  /// - Claude Code: “You've hit your session limit · resets 3:45pm”, “… weekly limit · resets Mon
  ///   12:00am”, “… weekly limit · resets Nov 18 at 1pm (America/Chicago)”, the Opus and Sonnet
  ///   limits, and “your session limit resets 3:45pm”. The time is the named time zone's clock
  ///   time, or this Mac's when none is named, next coming.
  /// - Codex: “You've hit your usage limit. … Try again at 3:15 PM.” (today) or “… Try again at
  ///   Oct 28th, 2026 3:15 PM.”
  /// - Every other CLI passes its model provider's words on: a usage limit is what
  ///   `HarnessRetry` reads as one, and its reset is the delay the provider named (`retryAfter`).
  public static func text(_ output: String, harness: HarnessDriver?, now: Date, calendar: Calendar = .current)
    -> UsageLimit?
  {
    let text = String(output.prefix(textLimit)).replacingOccurrences(of: "\u{2019}", with: "'")
    switch harness {
    case .claude?:
      guard match(#"hit your (?:session|weekly|opus|sonnet) limit"#, text) != nil
        || match(#"your (?:session|weekly|opus|sonnet) limit resets"#, text) != nil
      else { return nil }
      return UsageLimit(resetsAt: claudeReset(text, now: now, calendar: calendar))
    case .codex?:
      guard match(#"hit your usage limit"#, text) != nil else { return nil }
      return UsageLimit(resetsAt: codexReset(text, now: now, calendar: calendar))
    case nil:
      return nil
    default:
      guard HarnessRetry.classify(.message(text)) == .terminal(.quota) else { return nil }
      return UsageLimit(resetsAt: retryAfter(text, now: now))
    }
  }

  /// The delay a model provider named in its error words, as a time: Google's “Please retry in
  /// 23.5s.”, Gemini CLI's “Suggested retry after 23s.” and “Your quota will reset after 10m.”,
  /// OpenAI's “Please try again in 6m0s.”, Pi's “Try again in ~143 min.”, and Oh My Pi's
  /// “Provider requested 8580000ms wait” and “retry-after-ms=8580000”. The longest one wins, since
  /// every limit has reset by then. Words with no number (“try again later”) name nothing.
  public static func retryAfter(_ output: String, now: Date) -> Date? {
    let text = String(output.prefix(textLimit))
    var waits: [TimeInterval] = []
    for raw in captures(#"\b(?:retry|try again|resets?) (?:in|after) ~?((?:\d+(?:\.\d+)?(?:ms|h|m|s))+)\b"#, text) {
      if let seconds = duration(raw.lowercased()) { waits.append(seconds) }
    }
    for raw in captures(#"\btry again in ~?(\d+) min(?:ute)?s?\b"#, text) { waits.append((Double(raw) ?? 0) * 60) }
    for raw in captures(#"\b(?:requested|requires) (\d+) ?ms wait\b|\bretry-after-ms=(\d+)\b"#, text) {
      waits.append((Double(raw) ?? 0) / 1000)
    }
    return bounded(waits.max().map { now.addingTimeInterval($0) }, now: now)
  }

  /// An API route's refusal: HTTP 429 only, with its reset from `Retry-After` (seconds or an HTTP
  /// date), `anthropic-ratelimit-*-reset` (RFC 3339) or `x-ratelimit-reset-*` (a duration such
  /// as “6m0s”). The latest of them is when every limit has reset. `header` looks a name up
  /// without regard to case, as `HTTPURLResponse.value(forHTTPHeaderField:)` does.
  public static func http(status: Int, header: (String) -> String?, now: Date) -> UsageLimit? {
    guard status == 429 else { return nil }
    var names: [String] = ["retry-after"]
    for limit in ["requests", "tokens", "input-tokens", "output-tokens"] { names.append("anthropic-ratelimit-\(limit)-reset") }
    for limit in ["requests", "tokens"] { names.append("x-ratelimit-reset-\(limit)") }
    var values: [String: String] = [:]
    for name in names {
      if let raw = header(name)?.prefix(200).trimmingCharacters(in: .whitespaces), !raw.isEmpty { values[name] = raw }
    }
    func value(_ name: String) -> String? { values[name] }
    var times: [Date] = []
    if let retry = value("retry-after") {
      if let seconds = Int(retry), seconds >= 0 {
        times.append(now.addingTimeInterval(TimeInterval(seconds)))
      } else if let date = httpDate(retry) {
        times.append(date)
      }
    }
    for name in ["requests", "tokens", "input-tokens", "output-tokens"] {
      if let raw = value("anthropic-ratelimit-\(name)-reset"), let date = rfc3339(raw) { times.append(date) }
    }
    for name in ["requests", "tokens"] {
      if let raw = value("x-ratelimit-reset-\(name)"), let seconds = duration(raw) {
        times.append(now.addingTimeInterval(seconds))
      }
    }
    return UsageLimit(resetsAt: bounded(times.max(), now: now))
  }

  /// What an API route's refusal says, in Serein's words.
  public static func endpointRefusal(_ limit: UsageLimit, now: Date, calendar: Calendar = .current,
                                     locale: Locale = .current) -> String {
    guard let at = limit.resetsAt else { return "The model endpoint's usage limit was reached. Try again later." }
    return "The model endpoint's usage limit was reached. It resets at \(when(at, now: now, calendar: calendar, locale: locale))."
  }

  // MARK: holding the turn

  /// Who started a turn the limit stopped, as far as holding it goes.
  public enum Origin: Equatable, Sendable {
    /// A message in Serein's chat: the person's, or a paired app's.
    case message
    /// A scheduled request: when this run was due, and whether its schedule says to run late
    /// (`RelayReminder.runLate`).
    case scheduled(due: Date, runLate: Bool)
    /// A webhook, an alert, or a turn Serein started itself: never held.
    case unattended
  }
  /// What becomes of the turn.
  public enum Plan: Equatable, Sendable {
    /// Held in Serein's chat. `waits`: Serein sends it once by itself at the reset time.
    case hold(waits: Bool)
    /// A scheduled run that cannot wait: recorded as missed, with why.
    case missed(String)
    /// Not held: it fails as any failed turn does.
    case fail
  }
  /// `retried`: the turn was already sent again from a hold (Continue now, another AI app, or the
  /// reset time), so it is never sent by itself again. A scheduled run waits only when its
  /// schedule allows it to run that late (`lateRunAllowed`).
  public static func plan(_ origin: Origin, limit: UsageLimit, retried: Bool, app: String, now: Date,
                          calendar: Calendar = .current, locale: Locale = .current) -> Plan {
    switch origin {
    case .unattended:
      return .fail
    case .message:
      return .hold(waits: !retried && limit.resetsAt != nil)
    case .scheduled(let due, let runLate):
      if retried { return .missed("\(app) reached its usage limit again.") }
      guard let reset = limit.resetsAt else { return .missed("\(app) reached its usage limit and named no reset time.") }
      guard lateRunAllowed(due: due, runLate: runLate, reset: reset) else {
        return .missed("\(app)'s usage limit resets at \(when(reset, now: now, calendar: calendar, locale: locale)), too late for this run.")
      }
      return .hold(waits: true)
    }
  }
  /// A schedule's own late-run rule, the one a run missed while the Mac slept follows
  /// (`RelayMissedRun.isMissed`): it runs late when its schedule says to run late, or when the
  /// reset comes within `RelayUnattended.staleGrace` of when it was due.
  public static func lateRunAllowed(due: Date, runLate: Bool, reset: Date) -> Bool {
    runLate || !RelayUnattended.staleAction(due: due, now: reset)
  }

  // MARK: copy

  /// The chip under a held message.
  public static let chip = "Usage limit reached"
  /// Serein's line under a held turn. `again`: it was sent again and met the limit again.
  public static func line(app: String, resetsAt: Date?, waits: Bool, again: Bool, now: Date,
                          calendar: Calendar = .current, locale: Locale = .current) -> String {
    if let at = resetsAt, at > now {
      let time = when(at, now: now, calendar: calendar, locale: locale)
      return waits ? "\(app)'s limit resets at \(time). Serein will continue then." : "\(app)'s limit resets at \(time)."
    }
    if resetsAt != nil { return "\(app)'s limit has reset." }
    return again ? "\(app) reached its usage limit again." : "\(app) reached its usage limit."
  }
  /// A clock time (“14:20”, or “2:20 PM” by the Mac's settings), with the day when it is not today.
  public static func when(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
    let format = DateFormatter()
    format.locale = locale
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    if calendar.isDate(date, inSameDayAs: now) {
      format.dateStyle = .none
      format.timeStyle = .short
    } else {
      format.setLocalizedDateFormatFromTemplate("EEEjmm")
    }
    return format.string(from: date)
  }

  // MARK: parsing

  /// The first match of `pattern` (case-insensitive) in `text`, as its capture groups (the whole
  /// match first; an absent group is empty).
  static func match(_ pattern: String, _ text: String) -> [String]? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<found.numberOfRanges).map { index in
      Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
  }
  /// The first non-empty capture group of every match of `pattern` (case-insensitive) in `text`.
  static func captures(_ pattern: String, _ text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { found in
      (1..<found.numberOfRanges).lazy.compactMap { Range(found.range(at: $0), in: text).map { String(text[$0]) } }.first
    }
  }
  /// “resets 3:45pm” or “resets Mon 12:00am”: the next such clock time on this Mac.
  /// “resets Nov 18 at 1pm (America/Chicago)”, “resets Nov 18, 1:30pm” or “resets 3:45pm
  /// (Europe/Paris)”: the time zone in brackets when it is a known one, else this Mac's.
  static func claudeReset(_ text: String, now: Date, calendar: Calendar) -> Date? {
    let clock = #"(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\b(?:\s*\(([A-Za-z_]+(?:/[A-Za-z0-9_+-]+)*)\))?"#
    let months = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"
    let dated = #"\bresets\s+("# + months + #")[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?"# + clock
    let weekly = #"\bresets\s+(?:(mon|tue|wed|thu|fri|sat|sun)[a-z]*\s+)?"# + clock
    var wanted = DateComponents()
    let time: ArraySlice<String>
    if let parts = match(dated, text) {
      let index = months.split(separator: "|").firstIndex(of: Substring(parts[1].lowercased()))
      guard let index, let day = Int(parts[2]), (1...31).contains(day) else { return nil }
      wanted.month = index + 1
      wanted.day = day
      time = parts[3...]
    } else if let parts = match(weekly, text) {
      if !parts[1].isEmpty {
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        guard let index = days.firstIndex(of: parts[1].lowercased()) else { return nil }
        wanted.weekday = index + 1
      }
      time = parts[2...]
    } else {
      return nil
    }
    let fields = Array(time)
    guard let hour = Int(fields[0]), (1...12).contains(hour) else { return nil }
    let minute = fields[1].isEmpty ? 0 : Int(fields[1]) ?? 60
    guard minute < 60 else { return nil }
    wanted.hour = hour % 12 + (fields[2].lowercased() == "p" ? 12 : 0)
    wanted.minute = minute
    wanted.second = 0
    var zoned = calendar
    if !fields[3].isEmpty, let zone = TimeZone(identifier: fields[3]) { zoned.timeZone = zone }
    // A minute's slack, so “resets 3:45pm” read at 3:45:20pm is not taken for tomorrow.
    let next = zoned.nextDate(after: now.addingTimeInterval(-60), matching: wanted, matchingPolicy: .nextTime)
    return bounded(next, now: now)
  }
  /// “Try again at 3:15 PM.” (today on this Mac) or “Try again at Oct 28th, 2026 3:15 PM.”
  static func codexReset(_ text: String, now: Date, calendar: Calendar) -> Date? {
    guard let parts = match(#"try again at ([A-Za-z0-9 ,:]{4,40}?)\s*\.(?=\s|$|")"#, text) else { return nil }
    let words = parts[1].replacingOccurrences(of: #"(\d)(?:st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.calendar = calendar
    format.timeZone = calendar.timeZone
    format.dateFormat = "MMM d, yyyy h:mm a"
    if let date = format.date(from: words) { return bounded(date, now: now) }
    format.dateFormat = "h:mm a"
    guard let time = format.date(from: words) else { return nil }
    let clock = calendar.dateComponents([.hour, .minute], from: time)
    var today = calendar.dateComponents([.year, .month, .day], from: now)
    today.hour = clock.hour
    today.minute = clock.minute
    return bounded(calendar.date(from: today), now: now)
  }
  static func httpDate(_ text: String) -> Date? {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "GMT")
    format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return format.date(from: text)
  }
  static func rfc3339(_ text: String) -> Date? {
    let format = ISO8601DateFormatter()
    if let date = format.date(from: text) { return date }
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format.date(from: text)
  }
  /// “1s”, “6m0s”, “1h2m3s”, “20ms”: nil for anything else.
  static func duration(_ text: String) -> TimeInterval? {
    guard text.count <= 40, text.range(of: #"^(?:\d+(?:\.\d+)?(?:ms|h|m|s))+$"#, options: .regularExpression) != nil,
      let expression = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(ms|h|m|s)"#)
    else { return nil }
    var total: TimeInterval = 0
    for found in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let number = Range(found.range(at: 1), in: text).flatMap({ Double(text[$0]) }),
        let unit = Range(found.range(at: 2), in: text).map({ String(text[$0]) })
      else { return nil }
      total += number * (["ms": 0.001, "s": 1, "m": 60, "h": 3600][unit] ?? 0)
    }
    return total
  }
}
