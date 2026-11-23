import Foundation

/// Relay's reply marks (a check-in's NOTHING, a schedule's NOTHING NEW and NEEDS INPUT:, a goal's
/// NEW:, NOTE: and MET:), read in one place. NOTHING NEW and a goal's fields ignore case;
/// NOTHING and NEEDS INPUT: count only in upper case, so the same words in prose never do.
/// Whitespace and sentence marks (.!。！) around a whole-reply mark are ignored. Each prompt
/// keeps its own wording.
public enum RelayMarks {
  private static let ends = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！"))
  /// Text as a mark compares: whitespace and sentence marks trimmed from both ends, upper-cased.
  public static func normalized(_ text: String) -> String { text.trimmingCharacters(in: ends).uppercased() }
  /// The whole reply is `mark` and nothing else ("nothing new." reads as NOTHING NEW).
  public static func isOnly(_ mark: String, _ text: String) -> Bool { normalized(text) == mark }
  /// The whole reply is exactly `mark` as written (upper case): surrounding whitespace and
  /// trailing .!。！ are ignored, case is not.
  public static func isExactly(_ mark: String, _ text: String) -> Bool {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = t.last, ".!。！".contains(last) { t.removeLast() }
    return t.trimmingCharacters(in: .whitespacesAndNewlines) == mark
  }
  /// What follows `mark` at the start of a line, trimmed; nil when the line does not start with it.
  public static func field(_ mark: String, in line: String) -> String? {
    guard line.uppercased().hasPrefix(mark) else { return nil }
    return String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
  }
  /// What follows `mark`, written exactly (upper case), anywhere in the reply, trimmed; nil when
  /// the reply does not carry it.
  public static func after(_ mark: String, in text: String) -> String? {
    guard let range = text.range(of: mark) else { return nil }
    return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// How a scheduled request behaves when nobody is watching (a RelayReminder with action). The
/// reply decides whether the user hears anything; repeated failures pause the schedule instead
/// of erroring forever; a request reached too late is listed as missed (RelayMissedRun) rather
/// than run. The reply marks NOTHING NEW and NEEDS INPUT say which; a schedule that keeps failing
/// is paused, and a missed window is never replayed by itself unless its schedule runs late. Everything here is pure, so it is
/// checked in SereinChecks.
public enum RelayUnattended {
  public enum Outcome: Equatable, Sendable {
    /// "NOTHING NEW": the request ran, nothing worth telling the user; the activity keeps it.
    case quiet
    /// Worth a notification now.
    case report(String)
    /// Relay cannot continue without the user: the question waits in the panel.
    case needsInput(String)
  }
  public static let quietMark = "NOTHING NEW"
  public static let inputMark = "NEEDS INPUT:"
  /// The prompt's fixed first words and the start of its instructions (RelayAutomatic reads both).
  public static let promptLead = "Scheduled request you set up earlier"
  public static let instructionsLead = "Carry it out with your tools now"
  /// Failures in a row before a schedule pauses.
  public static let failureLimit = 10
  /// A scheduled request reached later than this was missed: it is listed (RelayMissedRun), not
  /// run, unless its schedule runs late.
  public static let staleGrace: TimeInterval = 600

  /// The turn prompt for one scheduled request. It carries the protocol with it, so the reply
  /// can be judged without the rest of the conversation.
  /// `last`: what the schedule's last run reported, so this one does not say it again.
  public static func prompt(text: String, repeats: RelayReminder.Repeat, now: String, last: String? = nil) -> String {
    let base = """
      \(promptLead)\(repeats == .none ? "" : " (repeats \(repeats.rawValue))"). The time now is \(now).
      \(text)
      \(instructionsLead), then report in one to three sentences. \(acting) If nothing came of it, reply exactly \(quietMark). Only when you are truly blocked on something only the user has (a password or code, a payment, or a choice with no safe default that cannot be undone), reply starting with \(inputMark) followed by one short question.
      """
    let earlier = (last ?? "").components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !earlier.isEmpty else { return base }
    return base + "\nLast time you reported: \(String(earlier.prefix(lastLimit))) Do not repeat this unless something changed."
  }
  public static let lastLimit = 400
  /// What a run nobody watches may do (UnattendedAuthority, RelayDeferred, RelayFollowUp).
  public static let acting =
    "Do what this request asks, including the actions it names, without stopping to ask first. Serein holds any other action, and any payment, sign-in or deletion, on a card for the person's OK: then end with \(inputMark) and what waits. If something is still pending, you may set one follow-up for yourself with reminder_create (once, 10 minutes to 14 days ahead), such as checking back on a reply tomorrow."

  /// Judges an unattended run's reply. A request for help outranks "nothing new"; anything
  /// else is worth reporting.
  public static func interpret(reply: String, failed: Bool) -> Outcome {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if failed {
      return .report(trimmed.isEmpty ? "A scheduled request could not finish." : String(trimmed.prefix(400)))
    }
    if let question = RelayMarks.after(inputMark, in: trimmed) {
      return .needsInput(question.isEmpty ? trimmed : String(question.prefix(400)))
    }
    if RelayMarks.isOnly(quietMark, trimmed) { return .quiet }
    return .report(trimmed.isEmpty ? "A scheduled request finished." : String(trimmed.prefix(400)))
  }

  public static func shouldPause(failures: Int) -> Bool { failures >= failureLimit }

  public static func staleAction(due: Date, now: Date) -> Bool { now.timeIntervalSince(due) > staleGrace }

  /// The next morning hour in the user's calendar; today when it has not passed yet.
  public static func nextMorning(after: Date, hour: Int = 9, calendar: Calendar = .current) -> Date {
    let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: after) ?? after
    guard today > after else { return calendar.date(byAdding: .day, value: 1, to: today) ?? after }
    return today
  }
}

/// The daily morning briefing: the one proactive nudge Serein ships, off by default. It is an
/// ordinary daily scheduled request with a fixed id, so the unattended protocol and
/// the review surfaces apply to it. A scheduled run never uses Autopilot.
public enum RelayBriefing {
  public static let reminderID = "serein.relay.briefing"
  public static let text =
    "Morning briefing: check today's Calendar events (mac_script), Reminders due today, Serein's reminders for the rest of today (reminder_list), and any delegated runs working or finished overnight (agent_status). Report what matters in a few sentences."

  /// One approval card still open, for the brief's “Waiting on you”: the task that asked, where,
  /// and what a yes would do. Read only: the card is the one place it is answered.
  public struct Waiting: Equatable, Sendable {
    public var task: String
    /// The site or Mac app, when known.
    public var place: String?
    /// `ApprovalGate.askLine` of the step, or the card's own title.
    public var action: String
    /// The open card, for Go to card in Serein's chat.
    public var cardID: UUID?
    public init(task: String, place: String? = nil, action: String, cardID: UUID? = nil) {
      self.task = task
      self.place = place
      self.action = action
      self.cardID = cardID
    }
    /// One redacted line. Titles can quote a web page, so each part is flattened to one line.
    public var line: String {
      func flat(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
      }
      let site = flat(place ?? "")
      return AgentPrivacy.redact(flat(task) + (site.isEmpty ? "" : " on " + site) + ": " + flat(action), limit: 240)
    }
  }
  public static let waitingTitle = "Waiting on you"
  public static let nothingWaiting = "Nothing waiting on you"
  /// The “Waiting on you” section the brief repeats word for word at its top.
  public static func waiting(_ items: [Waiting]) -> String {
    ([waitingTitle] + (items.isEmpty ? [nothingWaiting] : items.map { "- " + $0.line })).joined(separator: "\n")
  }
}
