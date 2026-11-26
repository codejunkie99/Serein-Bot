import Foundation

// Pure rules behind the personal-assistant screens: the paced reveal of a streaming reply, the
// assistant names inside a system line, what the message bar refuses, the order that ⌥⌘↑ and
// ⌥⌘↓ follow, the words under a name in the assistant list, a dashboard's summary and the
// details card's counts. The plan card's model is `PlanCard` (PlanCard.swift). The shell draws
// them; nothing here reads a file or a clock.

// MARK: - Paced reveal

/// A streaming reply arrives in bursts: nothing for a moment, then a sentence at once. Drawn as it
/// arrives, it reads as stuttering. Revealed at a steady pace a little behind what has arrived, it
/// reads as being written. The pace has a floor, so a slow stream still moves, and a catch-up
/// budget, so a big burst is worked off in well under a second.
///
/// It reveals a word at a time: a prefix ends at the end of the text or just before a space, and
/// while the stream goes on it stops short of the last word, which can be half sent, until the
/// text has not grown for `tailSettles` seconds.
///
/// Counts are in characters
/// (`Character`), so an emoji or an accented letter is never cut in two.
public enum PacedReveal {
  /// The slowest the reveal goes, so a trickle of text still moves.
  public static let minCharactersPerSecond: Double = 90
  /// While it streams: the longest a backlog takes to work off before the floor takes over.
  public static let catchUpSeconds: Double = 0.4
  /// After the stream ends: everything shows this long after, however much was left.
  public static let finishSeconds: Double = 0.3
  /// The longest run that counts as one word. Text with no spaces (Chinese, Japanese, a long link)
  /// past this shows a character at a time, not held whole.
  public static let longestWord = 24
  /// A tail that has not grown for this long is the end of the reply, not half a word.
  public static let tailSettles: Double = 0.25
  /// The most one step may count, so a stalled frame does not dump the backlog.
  public static let maxStepSeconds: Double = 0.05

  /// The number of characters of `text` to show after `elapsed` seconds, from `shown` now.
  /// `holdTail`: the last word may still be arriving (while it streams, until the text settles).
  /// `finishIn`: seconds left before everything must show, once the stream ended.
  public static func next(
    text: [Character], shown: Int, elapsed: Double, streaming: Bool, holdTail: Bool, finishIn: Double
  ) -> Int {
    let start: Int = min(max(shown, 0), text.count)
    let furthest: Int = revealLimit(text, holdTail: streaming && holdTail)
    if start >= furthest { return start }
    let backlog = Double(text.count - start)
    let budget: Double = streaming ? catchUpSeconds : max(finishIn, 0.001)
    let rate: Double = max(minCharactersPerSecond, backlog / budget)
    let stepped = Int((rate * max(elapsed, 0)).rounded(.up))
    let target: Int = min(furthest, start + max(1, stepped))
    // On to the end of the word the target falls in, unless it is too long to be one.
    let stop: Int = min(furthest, target + longestWord)
    var end: Int = target
    while end < stop && !text[end].isWhitespace { end += 1 }
    return end == stop && stop < furthest ? target : end
  }

  /// The furthest prefix that may show: all of it, or, while the tail may be half sent, up to the
  /// last space (no further back than `longestWord` characters).
  static func revealLimit(_ text: [Character], holdTail: Bool) -> Int {
    if !holdTail { return text.count }
    let earliest: Int = max(0, text.count - longestWord)
    var index: Int = text.count - 1
    while index >= earliest {
      if text[index].isWhitespace { return index }
      index -= 1
    }
    return earliest
  }
}

// MARK: - System lines

/// A system line ("You made Inbox Zero", "Messaged Planner and Scout") cut into words and the
/// assistant names in it, so the shell can draw each name after its face. A name counts only as a
/// whole word, and a longer name wins over a shorter one it starts with ("Inbox Zero 2" before
/// "Inbox Zero"). The words stay plain text.
public enum SystemLineParts {
  public enum Part: Equatable, Sendable {
    case words(String)
    case name(id: String, text: String)
  }

  public static func split(_ line: String, names: [(id: String, name: String)]) -> [Part] {
    let text: [Character] = Array(line)
    let usable = names.filter { !$0.name.isEmpty }.sorted { $0.name.count > $1.name.count }
    let candidates: [(id: String, chars: [Character])] = usable.map { ($0.id, Array($0.name)) }
    var parts: [Part] = []
    var words: [Character] = []
    var index = 0
    while index < text.count {
      var found: (id: String, length: Int)? = nil
      if index == 0 || !isWordCharacter(text[index - 1]) {
        for candidate in candidates where matches(text, at: index, candidate.chars) {
          found = (candidate.id, candidate.chars.count)
          break
        }
      }
      if let found {
        if !words.isEmpty {
          parts.append(.words(String(words)))
          words = []
        }
        let end: Int = index + found.length
        parts.append(.name(id: found.id, text: String(text[index..<end])))
        index = end
      } else {
        words.append(text[index])
        index += 1
      }
    }
    if !words.isEmpty { parts.append(.words(String(words))) }
    return parts
  }

  static func matches(_ text: [Character], at index: Int, _ name: [Character]) -> Bool {
    guard index + name.count <= text.count else { return false }
    for offset in 0..<name.count where text[index + offset] != name[offset] {
      return false
    }
    let after: Int = index + name.count
    return after == text.count || !isWordCharacter(text[after])
  }
  static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }
}

// MARK: - The message bar

/// What the message bar refuses before a message leaves (SPEC.md 2.4, T7): words that hold a key
/// go to the key field, never to a model.
public enum ComposerGuard {
  public static let keyRefusal = "That looks like a key. Paste it in the key field instead."
  /// The send that did not reach the chat.
  public static let notSent = "That did not send. Your words are back in the box."
  /// Under the message box when a key was caught: the box offers a secure field or removing it.
  public static let keyNote = "That looks like a key, so it was not sent."
  static let keyShapes: [NSRegularExpression] = [
    #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#,
    #"(?<![A-Za-z0-9])"# + AgentPrivacy.keyShapes,
    #"eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
    #"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{20,}"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }
  /// True when the words hold something shaped like a key or a private key.
  public static func looksLikeKey(_ text: String) -> Bool { !keys(in: text).isEmpty }
  /// Each key in the words, in order, with keys two shapes both match joined into one.
  public static func keys(in text: String) -> [Range<String.Index>] {
    let range = NSRange(text.startIndex..., in: text)
    let found = keyShapes.flatMap { $0.matches(in: text, range: range) }.compactMap { Range($0.range, in: text) }
    var joined: [Range<String.Index>] = []
    for key in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = joined.last, key.lowerBound <= last.upperBound {
        joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, key.upperBound)
      } else {
        joined.append(key)
      }
    }
    return joined
  }
  /// The first key in the words as the person would paste it into a key field: a bearer token without its word.
  public static func firstKey(in text: String) -> String? {
    keys(in: text).first.map { String(text[$0]).replacingOccurrences(of: #"(?i)^bearer\s+"#, with: "", options: .regularExpression) }
  }
  /// The words with every key taken out and runs of spaces closed up.
  public static func withoutKeys(_ text: String) -> String {
    var words = text
    for key in keys(in: text).reversed() { words.removeSubrange(key) }
    return words.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// What becomes of the words a person sends from one of Serein's message boxes: the window's
/// composer, the dock's box and the ⌥Space bar. Each box asks `MessagePlan.of` and does what it
/// says, so a check one box makes is never missing from another.
public enum MessagePlan: Equatable, Sendable {
  /// A saved shortcut's `/name` only fills the box with its words; the person sends them.
  case fill(String)
  /// Nothing leaves and the words stay in the box, with this said beside it.
  case refuse(String)
  /// One question waits: the words answer it, as the person's reply.
  case answer(String)
  /// The words go to Serein.
  case send(String)

  /// Why the words were refused, when they were.
  public var refusal: String? {
    if case .refuse(let why) = self { return why }
    return nil
  }

  /// `typed` is the box's words, trimmed. `mentionRefusal` says why a mention of another
  /// assistant cannot go now, when it cannot; `questionWaits`, that one question this box may
  /// answer is up.
  public static func of(
    _ typed: String, hasAttachments: Bool, shortcuts: [PromptShortcut], mentionRefusal: String?, questionWaits: Bool
  ) -> MessagePlan {
    if let words = PromptShortcuts.expansion(of: typed, in: shortcuts) { return .fill(words) }
    // `//name` sends "/name" as it is written.
    let literal = typed.hasPrefix("//") && PromptShortcuts.expansion(of: String(typed.dropFirst()), in: shortcuts) != nil
    let words = literal ? String(typed.dropFirst()) : typed
    // A key goes to the key field, never to a model (T7). It is said before a mention's wait,
    // which passes; a key never does.
    if ComposerGuard.looksLikeKey(words) { return .refuse(ComposerGuard.keyRefusal) }
    if let mentionRefusal { return .refuse(mentionRefusal) }
    if questionWaits, !hasAttachments, !words.isEmpty { return .answer(words) }
    return .send(words)
  }
}

// MARK: - Switching

/// The order ⌥⌘↑ and ⌥⌘↓ (and ↑ ↓ in the list) follow: the order of the assistant list.
public enum AssistantSwitchOrder {
  /// The main assistant first, then each id once, in the order given.
  public static func order(main: String?, shown: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for id in [main].compactMap({ $0 }) + shown where seen.insert(id).inserted {
      out.append(id)
    }
    return out
  }
  /// The assistant `step` places from `current` (−1 is up, +1 is down); nil at either end, for a
  /// step of 0, or when `current` is not in the list.
  public static func neighbour(of current: String, step: Int, in order: [String]) -> String? {
    guard step != 0, let index = order.firstIndex(of: current) else { return nil }
    let next: Int = index + (step < 0 ? -1 : 1)
    guard order.indices.contains(next) else { return nil }
    return order[next]
  }
  /// The assistants to load ahead: the one before and the one after `current`.
  public static func around(_ current: String, in order: [String]) -> [String] {
    [neighbour(of: current, step: -1, in: order), neighbour(of: current, step: 1, in: order)].compactMap { $0 }
  }
}

// MARK: - The words under a name

/// The status words under an assistant's name in the list (SPEC.md 2.2), first match wins: "Needs
/// you" while a card waits; "1 thing for you" while held actions wait; the live step while it
/// works ("Working" when there is none); "Answering {Name}" while another assistant's light ask
/// runs on it; "Could not finish {routine}" after a routine's run failed, until a good run;
/// "Paused"; "Stopped" while Stop everything holds it; then its next routine ("Checks at 8:00
/// AM"); then its job; else "Ready", which VoiceOver reads and the row leaves off (`isIdle`). An
/// unread reply keeps the words: the row's accent dot says it. Each line is cut to `maxLine`
/// characters.
public struct AssistantRowWords: Equatable, Sendable {
  public enum Tone: String, Sendable { case working, needsYou, failed, faint, quiet }
  public var text: String
  public var tone: Tone
  public init(text: String, tone: Tone) {
    self.text = text
    self.tone = tone
  }
  public static let maxLine = 28
  static let idleWords = "Ready"
  /// Nothing to say: the row shows only the name.
  public var isIdle: Bool { tone == .quiet && text == Self.idleWords }

  /// `held`: actions an unattended run saved for the person to approve. `failed`: the routine
  /// whose last run failed. `stopped`: Stop everything holds it, and it is not paused by itself.
  public static func of(
    status: SereinStatus, phase: String?, nextRun: String?, job: String?, answering: String? = nil,
    held: Int = 0, failed: String? = nil, stopped: Bool = false
  ) -> AssistantRowWords {
    if status == .needsYou { return AssistantRowWords(text: "Needs you", tone: .needsYou) }
    if held > 0 { return AssistantRowWords(text: heldWords(held), tone: .needsYou) }
    if !status.spins, let asker = oneLine(answering) {
      return AssistantRowWords(text: oneLine(AskLines.answering(asker)) ?? "Answering", tone: .working)
    }
    if !status.spins, let routine = oneLine(failed, limit: Int.max) {
      let words: String = oneLine("Could not finish " + routine) ?? "Could not finish"
      return AssistantRowWords(text: words, tone: .failed)
    }
    switch status {
    case .needsYou: return AssistantRowWords(text: "Needs you", tone: .needsYou)
    case .replying, .working:
      let live: String = oneLine(phase) ?? "Working"
      return AssistantRowWords(text: live, tone: .working)
    case .paused: return AssistantRowWords(text: stopped ? "Stopped" : "Paused", tone: .faint)
    case .notConnected: return AssistantRowWords(text: "Not connected", tone: .quiet)
    case .offline: return AssistantRowWords(text: "Offline", tone: .quiet)
    case .ready, .unread:
      if let next = oneLine(nextRun) { return AssistantRowWords(text: next, tone: .quiet) }
      if let job = oneLine(job) { return AssistantRowWords(text: job, tone: .quiet) }
      return AssistantRowWords(text: idleWords, tone: .quiet)
    }
  }
  /// "1 thing for you", "3 things for you".
  public static func heldWords(_ count: Int) -> String { count == 1 ? "1 thing for you" : "\(count) things for you" }
  /// The first line, trimmed, at most `limit` characters (the last one an ellipsis when cut);
  /// nil when nothing is left.
  static func oneLine(_ raw: String?, limit: Int = maxLine) -> String? {
    guard let raw else { return nil }
    let first: Substring = raw.split(whereSeparator: { $0.isNewline }).first ?? ""
    let line: String = first.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return nil }
    return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
  }

  /// A routine's next run as the row says it, in the calendar's own clock (receipts say "3:45 PM"
  /// too): "Checks at 8:00 AM" today, "Checks tomorrow at 8:00 AM", "Checks Mon at 8:00 AM" within
  /// the week, else "Checks 14 Nov".
  public static func checks(next: Date, now: Date, calendar: Calendar) -> String {
    let parts: DateComponents = calendar.dateComponents([.weekday, .day, .month], from: next)
    let time: String = clock(next, calendar: calendar)
    let startNow: Date = calendar.startOfDay(for: now)
    let startNext: Date = calendar.startOfDay(for: next)
    let days: Int = calendar.dateComponents([.day], from: startNow, to: startNext).day ?? 0
    if days <= 0 { return "Checks at \(time)" }
    if days == 1 { return "Checks tomorrow at \(time)" }
    if days < 7 {
      let symbols: [String] = calendar.shortWeekdaySymbols
      let index: Int = (parts.weekday ?? 1) - 1
      let day: String = symbols.indices.contains(index) ? symbols[index] : ""
      return "Checks \(day) at \(time)"
    }
    let months: [String] = calendar.shortMonthSymbols
    let monthIndex: Int = (parts.month ?? 1) - 1
    let month: String = months.indices.contains(monthIndex) ? months[monthIndex] : ""
    return "Checks \(parts.day ?? 1) \(month)"
  }
  /// The time alone, short, in the calendar's locale and time zone: "8:00 AM", or "08:00" where
  /// the clock has 24 hours.
  static func clock(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = calendar.locale ?? Locale.current
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

/// One line under an assistant's name in the sidebar: what its chat waits on ("Waiting for you:
/// {question}"), else its newest turn ("You: …", "Sent 2 PDFs", "Ran 4 steps", a reply's words).
/// Sealed: `of` is the only way to make one and `plain` the only way words get in, so no raw
/// page, file, tool or card text reaches a row. Draw `text` verbatim: it is plain text.
public struct AssistantRowPreview: Equatable, Sendable {
  public let text: String
  /// "Waiting for you: …", drawn in the needs-you tone.
  public let waiting: Bool
  private init(text: String, waiting: Bool) {
    self.text = text
    self.waiting = waiting
  }
  /// The longest line, in characters, the last one an ellipsis when cut.
  public static let limit = 120
  static let ask = "Waiting for you: "

  /// `waiting`: the words of the first card waiting on the person. `lines`: the chat's newest
  /// lines, oldest first (`chatLines`). `replying`: its newest reply still streams, so it is
  /// skipped. nil when nothing has words.
  public static func of(waiting: String?, lines: [AssistantRowRules.ChatLine], replying: Bool) -> AssistantRowPreview? {
    // A card with no words still waits: the row says so, so the dot and the line agree.
    if let waiting { return AssistantRowPreview(text: plain(waiting, room: limit - ask.count).map { ask + $0 } ?? "Waiting for you", waiting: true) }
    var newest = Array(lines.reversed())
    if replying, let last = newest.first, last.who != nil, last.who != "You" { newest.removeFirst() }
    for line in newest {
      let prefix = line.who == "You" ? "You: " : ""
      if let words = plain(line.words, room: limit - prefix.count) { return AssistantRowPreview(text: prefix + words, waiting: false) }
    }
    return nil
  }

  /// The one door from untrusted words to a preview: hidden and direction characters out of the
  /// whole text, `AgentPrivacy.redact` (filled secure-card values, card numbers, keys, passwords,
  /// URL secrets) on all of it, one line, then clipped to `room`. Nothing is cut before redaction,
  /// so no secret is left as a prefix the scrubber cannot match. It redacts before joining the
  /// lines (a filled value keeps its own line breaks) and again after (digits split over lines).
  /// The raw text is redacted first too, so a filled value holding a hidden character still matches.
  static func plain(_ raw: String?, room: Int) -> String? {
    guard let raw else { return nil }
    let visible = AgentPrivacy.redact(raw).replacingOccurrences(of: UntrustedText.hidden, with: "", options: .regularExpression)
    let line = AgentPrivacy.redact(AgentPrivacy.redact(visible).split(whereSeparator: \.isWhitespace).joined(separator: " "))
    guard !line.isEmpty else { return nil }
    return line.count > room ? AgentPrivacy.clipped(line, limit: room - 1) + "…" : line
  }

  /// A person's message that carried only attachments, by its chips' names: "Sent a PDF",
  /// "Sent 2 PDFs", "Sent a file", "Sent 3 files". Only the count and the ".pdf" ending are read.
  public static func sent(_ names: [String]) -> String {
    let pdfs = names.allSatisfy { $0.lowercased().hasSuffix(".pdf") }
    if names.count == 1 { return pdfs ? "Sent a PDF" : "Sent a file" }
    return "Sent \(names.count) " + (pdfs ? "PDFs" : "files")
  }
  /// A reply that only ran tools: "Ran 1 step", "Ran 4 steps".
  public static func ran(_ steps: Int) -> String { steps == 1 ? "Ran 1 step" : "Ran \(steps) steps" }
}

// MARK: - The dashboard card

public enum DashboardSummary {
  /// The closed card's one line: the stat, then the first two rows ("Lowest fare £174, Hotels 4,
  /// Budget left £144"), at most `maxLine` characters.
  public static let maxLine = 80
  public static func line(_ spec: DashboardSpec) -> String {
    var parts: [String] = ["\(spec.stat.label) \(spec.stat.value)"]
    for row in spec.rows.prefix(2) { parts.append("\(row.label) \(row.value)") }
    let joined: String = parts.joined(separator: ", ")
    return joined.count > maxLine ? String(joined.prefix(maxLine - 1)) + "…" : joined
  }
  /// "Updated just now", "Updated 2 minutes ago", "Updated 3 hours ago", "Updated on 14 Nov".
  public static func updated(_ date: Date, now: Date, calendar: Calendar) -> String {
    let seconds: Int = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "Updated just now" }
    let minutes: Int = seconds / 60
    if minutes < 60 { return minutes == 1 ? "Updated 1 minute ago" : "Updated \(minutes) minutes ago" }
    let hours: Int = minutes / 60
    if hours < 24 { return hours == 1 ? "Updated 1 hour ago" : "Updated \(hours) hours ago" }
    let parts: DateComponents = calendar.dateComponents([.day, .month], from: date)
    let months: [String] = calendar.shortMonthSymbols
    let index: Int = (parts.month ?? 1) - 1
    let month: String = months.indices.contains(index) ? months[index] : ""
    return "Updated on \(parts.day ?? 1) \(month)"
  }
}

// MARK: - The details card

/// The counts on an assistant's details card (SPEC.md 2.3). Each count is a chip: it posts the
/// person's words, and Serein answers them.
public enum AssistantCardCounts {
  /// The places that are apps (Mail, Messages, Calendar, Contacts, connected apps, Serein's
  /// computer), not the web or the files.
  public static let appPlaces: Set<AssistantPlace> = [.mail, .messages, .calendar, .contacts, .connectedApps, .computer]
  public static func apps(_ places: Set<AssistantPlace>) -> Int { places.intersection(appPlaces).count }
  /// The Mac's own apps among the places, in a fixed order, for their logos.
  public static func macApps(_ places: Set<AssistantPlace>) -> [AssistantPlace] {
    [AssistantPlace.mail, .messages, .calendar, .contacts].filter { places.contains($0) }
  }
  /// The words a count's chip posts.
  public static let routinesWords = "What runs on its own?"
  public static let remembersWords = "What do you remember?"
  public static let appsWords = "What can you use?"
  /// "1 Routine", "2 Routines": the word after the number.
  public static func label(_ count: Int, one: String, many: String) -> String { count == 1 ? one : many }
  /// The most app logos the card shows; the rest read "+n".
  public static let maxLogos = 5
}
