import Foundation

/// A message Serein wrote to itself to start a turn nobody typed: a check-in, the brief, a run
/// that needs attention, a scheduled request, a goal check, an alert's change or a webhook. Each
/// is recognised by the fixed first words of its own template. The chat shows a short line saying
/// what started the turn and why, never the prompt, and note learning leaves it out: it is not the
/// person's words, and parts of it (a webhook's body, a watched page, a goal's findings) are
/// untrusted. Everything here is pure, so it is checked in AutomaticTurnChecks.
public enum RelayAutomatic {
  public enum Kind: String, Equatable, Sendable { case checkIn, brief, attention, scheduled, goal, alert, webhook, macAccess }

  /// What started the turn this message opened; nil for anything the person wrote.
  public static func kind(of text: String) -> Kind? {
    if RelayProactive.isOwnPrompt(text) {
      let body = text.dropFirst(RelayProactive.marker.count)
      if body.hasPrefix("Morning brief") { return .brief }
      if body.hasPrefix("Something in Serein needs attention") { return .attention }
      return .checkIn
    }
    if text.hasPrefix(RelayUnattended.promptLead) {
      // The 9:00 brief is a scheduled request with fixed words.
      return words(scheduled: text) == RelayBriefing.text ? .brief : .scheduled
    }
    if text.hasPrefix(RelayGoal.promptLead) { return .goal }
    if text.hasPrefix(RelayWatch.changeLead) { return .alert }
    if text.hasPrefix(RelayHook.promptLead) { return .webhook }
    if text.hasPrefix(MacAccessWait.followUp) { return .macAccess }
    return nil
  }

  /// Whether the chat shows the turn's line. A check-in, the brief and “needs attention” are
  /// Serein speaking first, so its message comes in on its own, as a text would. The rest name the
  /// person's own request, alert or goal, or an outside sender whose words are untrusted, and keep it.
  public static func showsLine(_ kind: Kind) -> Bool {
    switch kind {
    case .checkIn, .brief, .attention: return false
    case .scheduled, .goal, .alert, .webhook, .macAccess: return true
    }
  }

  /// The line the chat shows in the prompt's place: what started the turn, in the person's terms
  /// (“Your scheduled request: “Check my inbox””). nil for the person's own messages.
  public static func label(_ text: String) -> String? {
    guard let kind = kind(of: text) else { return nil }
    switch kind {
    case .brief: return "Daily brief"
    case .attention: return "Serein noticed something"
    case .checkIn: return "Serein checked in"
    case .scheduled: return "Your scheduled request" + quoted(words(scheduled: text))
    case .goal: return "Checking your goal" + quoted(field("The goal: ", in: text))
    case .alert: return "Your alert" + quoted(between(RelayWatch.changeLead, "” changed.", in: text)) + " changed"
    case .webhook: return "A webhook arrived" + (between("Source: ", ".\n", in: text).map { " from \(String($0.prefix(60)))" } ?? "")
    case .macAccess: return MacAccessWait.line
    }
  }

  /// Why the person is seeing it, for the line's help and VoiceOver: what of theirs set it off and
  /// where it is changed.
  public static func why(_ kind: Kind) -> String {
    switch kind {
    case .checkIn: return "You let Serein speak first. Change how often in Settings › Serein."
    case .brief: return "You turned on the daily brief. Turn it off in Settings › Serein."
    case .attention: return "A task needed you or could not finish, and you let Serein speak first."
    case .scheduled: return "You scheduled this request. Change or pause it in Settings › Serein."
    case .goal: return "You asked Serein to track this goal. Change or end it in Settings › Serein."
    case .alert: return "You asked Serein to tell you when this changes. Change it in Settings › Serein."
    case .webhook: return "A webhook you set up was called. Manage webhooks in Settings › Serein."
    case .macAccess: return "You let Serein use your Mac in System Settings › Accessibility, so it carried on."
    }
  }

  /// A reply with nothing to show: a check-in's NOTHING, or NOTHING NEW from a scheduled request
  /// or a goal check (whose progress note may follow). Its run is kept in the schedule's history.
  public static func isQuiet(reply: String) -> Bool {
    if RelayProactive.isNothing(reply) { return true }
    let first = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? reply
    return RelayMarks.isOnly(RelayUnattended.quietMark, first)
  }

  /// What note learning may read: a turn Serein started itself, its prompt and Serein's replies
  /// to it, is left out. It is not the person's words, and a reply may restate untrusted text.
  /// `role` is "assistant" for Serein; anything else is the person or a prompt.
  public static func personTurns<Message>(_ messages: [Message], role: (Message) -> String, text: (Message) -> String) -> [Message] {
    var kept: [Message] = []
    var automatic = false
    for message in messages {
      if role(message) != "assistant" {
        automatic = kind(of: text(message)) != nil
        if automatic { continue }
      } else if automatic {
        continue
      }
      kept.append(message)
    }
    return kept
  }

  /// A scheduled request's own words: the lines between the template's first line and its
  /// instructions.
  static func words(scheduled text: String) -> String? {
    let lines = text.components(separatedBy: "\n")
    guard lines.count > 2 else { return nil }
    let body = lines.dropFirst().prefix { !$0.hasPrefix(RelayUnattended.instructionsLead) }
    let words = body.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return words.isEmpty ? nil : words
  }
  private static func field(_ lead: String, in text: String) -> String? {
    text.components(separatedBy: "\n").first { $0.hasPrefix(lead) }.map { String($0.dropFirst(lead.count)) }
  }
  private static func between(_ start: String, _ end: String, in text: String) -> String? {
    guard let from = text.range(of: start), let to = text.range(of: end, range: from.upperBound..<text.endIndex) else { return nil }
    let found = String(text[from.upperBound..<to.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    return found.isEmpty ? nil : found
  }
  /// ` “words”`, at most 80 characters of them; "" without words.
  private static func quoted(_ words: String?) -> String {
    guard let words, !words.isEmpty else { return "" }
    let short = words.count > 80 ? String(words.prefix(79)) + "…" : words
    return " “\(short)”"
  }
}
