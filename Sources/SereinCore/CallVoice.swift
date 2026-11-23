import Foundation

/// What Serein says and hears in a voice call: short progress lines, each approval question read
/// aloud, and spoken answers to the card on screen. A spoken answer is another way to press that
/// card's button, never a new approval: “decline” always works, “allow” only for a
/// voice-eligible effect (`ApprovalGate.voiceEligible`), and only after a read-back and a second
/// “yes”. Every line Serein speaks is built from its own wording; quoted text (page labels,
/// typed text, search words) is dropped, so a web page cannot speak through Serein.
public enum CallVoice {
  /// Speech recognised during, or this soon after, Serein's own speech is ignored: the speakers'
  /// tail must not reach the microphone as an answer.
  public static let echoGuard: TimeInterval = 0.5
  /// How long a read-back waits for its “yes”. Silence counts as no; the card keeps waiting.
  public static let readBackWindow: TimeInterval = 20
  /// At most one progress line this often, and only for a step this recent.
  public static let progressGap: TimeInterval = 8
  public static let progressWords = 6
  /// Longer utterances are talk, not an answer: a sentence that happens to hold “yes” answers nothing.
  public static let answerWords = 4

  public static let prompt = "Say allow or decline."
  public static let needsClick = "This one needs a click."
  public static let declineOnly = "Say decline, or click to allow it."
  public static let notAllowed = "Not allowed. It still waits for you."
  public static let allowed = "Allowed."
  public static let declined = "Declined."

  public enum Heard: Equatable, Sendable { case allow, decline, yes, other }

  /// One short utterance read as an answer. Any negative word declines (“don't allow” is a no);
  /// “allow” and “yes” are kept apart, so a bare “yes” never allows without a read-back.
  public static func heard(_ text: String) -> Heard {
    let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
      .split { !$0.isLetter && $0 != "'" }.map(String.init)
    guard !words.isEmpty, words.count <= answerWords else { return .other }
    let set = Set(words)
    if !set.isDisjoint(with: ["decline", "deny", "no", "not", "don't", "dont", "never"]) { return .decline }
    if set.contains("allow") { return .allow }
    if !set.isDisjoint(with: ["yes", "yeah", "yep", "confirm"]) { return .yes }
    return .other
  }

  /// What a spoken answer does to the current card.
  public enum Reply: Equatable, Sendable {
    /// The card's own answer, `.yes` or `.no`.
    case answer(ApprovalGate.HumanAnswer)
    /// Read the step back and wait for “yes”.
    case readBack
    /// Say this; the card keeps waiting.
    case say(String)
    /// Nothing is said; the card keeps waiting.
    case ignore
  }

  /// `awaitingYes`: a read-back for this card was spoken and has not lapsed. `allowable`: voice
  /// answers are on and the card's effect is voice-eligible, judged again at the “yes”.
  public static func reply(to heard: Heard, awaitingYes: Bool, allowable: Bool, enabled: Bool) -> Reply {
    if heard == .decline { return .answer(.no) }
    if awaitingYes { return heard == .yes && allowable ? .answer(.yes) : .say(notAllowed) }
    guard heard == .allow else { return .say(allowable ? prompt : declineOnly) }
    if !enabled { return .ignore }
    return allowable ? .readBack : .say(needsClick)
  }

  /// Voice answers are on and the card names a voice-eligible effect.
  public static func allowable(_ effect: ApprovalGate.Effect?, enabled: Bool) -> Bool {
    guard enabled, let effect else { return false }
    return ApprovalGate.voiceEligible(effect)
  }

  /// The question read aloud when a card appears in a call: Serein's own title, without quotes.
  public static func question(title: String, allowable: Bool) -> String {
    // Fewer than three words left after the cut ("Allow") would sound like a confirmation.
    let asked = plain(title, words: 8).flatMap { $0.split(separator: " ").count >= 3 ? $0 : nil } ?? "Serein needs your answer"
    return asked + ". " + (allowable ? prompt : declineOnly)
  }

  /// The read-back before a spoken allow counts: the step and the site, never the page's words.
  public static func readBack(effect: ApprovalGate.Effect, site: String?) -> String {
    let doing: String
    switch effect {
    case .click: doing = "clicking"
    case .type: doing = "typing"
    case .scroll: doing = "scrolling"
    case .navigate: doing = "going to another page"
    default: doing = "this step"
    }
    let host = site.flatMap { plain($0, words: 1) }.map { " on " + String($0.prefix(40)) } ?? ""
    return "Allow \(doing)\(host)? Say yes to allow it."
  }

  /// Words Serein's own step labels use (AgentStep.label, RunNow); a progress line stops at the
  /// first other word, so a name, path, key or direction an agent chose is never read out.
  static let stepWords: Set<String> = ["a", "an", "and", "at", "back", "bottom", "built", "checked", "clicked", "closed", "command", "down", "edited", "element", "files", "filled", "finished", "for", "helper", "its", "looked", "mac", "new", "number", "of", "offers", "on", "opened", "option", "over", "page", "part", "picked", "picture", "plan", "pointed", "pressed", "project", "proposed", "ran", "read", "saved", "script", "scrolled", "searched", "sign-in", "started", "tab", "tabs", "task", "tests", "the", "this", "to", "took", "tool", "top", "typed", "up", "updated", "used", "waited", "web", "went", "wrote", "you", "your"]

  /// A progress line from a step's label (`AgentStep.label`, a run's activity): quoted text and
  /// code dropped, at most `progressWords` words, up to the first word not in `stepWords`.
  /// Nil when nothing is left to say.
  public static func progress(_ label: String) -> String? {
    guard let line = plain(label, words: progressWords) else { return nil }
    let kept = line.split(separator: " ").prefix { stepWords.contains($0.lowercased()) }
    return kept.isEmpty ? nil : kept.joined(separator: " ")
  }

  /// Serein's wording only: cut at the first opening quote or backtick (a quote inside quoted
  /// text cannot reopen Serein's wording), then caps the words.
  static func plain(_ text: String, words limit: Int) -> String? {
    var line = text
    if let r = line.range(of: #"(^|\s)[“‘"'`]"#, options: .regularExpression) { line = String(line[..<r.lowerBound]) }
    let words = line.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…")) }
      .filter { !$0.isEmpty }
    guard !words.isEmpty else { return nil }
    return words.prefix(limit).joined(separator: " ")
  }
}
