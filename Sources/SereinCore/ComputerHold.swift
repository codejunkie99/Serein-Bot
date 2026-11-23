import Foundation

/// Who holds a computer's screen, and the steps only the person may do on a screen Serein works.
/// The view opens watch-first; one Take control and one Hand back move the hold, and the hold
/// ends by itself when the person leaves it. Pure, so it is checked (`AssistantCoreChecks.computerHold`).
public enum ComputerHold {
  /// The person's hold ends this long after their last input on the screen.
  public static let afterLastInput: TimeInterval = 5 * 60
  /// Or this long after the last view of the screen closed.
  public static let afterViewClosed: TimeInterval = 2 * 60

  /// Who may act on the screen now. Only `assistant` lets the assistant's calls through.
  public enum Holder: Equatable, Sendable {
    case assistant
    /// Take control was pressed while a step was in flight: the hold passes when it ends.
    case pending
    case person
  }
  public enum Event: Equatable, Sendable {
    case takeOver(stepInFlight: Bool)
    case stepEnded
    case handBack
    /// `lapse` found the hold ran out.
    case lapsed
  }

  public static func next(_ holder: Holder, _ event: Event) -> Holder {
    switch (holder, event) {
    case (.assistant, .takeOver(let inFlight)): return inFlight ? .pending : .person
    case (.pending, .stepEnded): return .person
    case (_, .handBack): return .assistant
    case (.person, .lapsed): return .assistant
    default: return holder
    }
  }

  /// Why a hold ended by itself.
  public enum Lapse: Equatable, Sendable {
    case idle, closed
    /// The person's line in the chat.
    public var line: String {
      switch self {
      case .idle: return "Serein's computer went back to the assistant after 5 minutes with no input from you"
      case .closed: return "Serein's computer went back to the assistant 2 minutes after you closed its view"
      }
    }
  }

  /// Whether the person's hold has run out. `viewClosedAt` is nil while a view of the screen shows.
  public static func lapse(lastInput: Date, viewClosedAt: Date?, now: Date) -> Lapse? {
    if now.timeIntervalSince(lastInput) >= afterLastInput { return .idle }
    if let closed = viewClosedAt, now.timeIntervalSince(closed) >= afterViewClosed { return .closed }
    return nil
  }

  /// A step that is the person's own: Serein hands it over with a plain line and never tries it.
  public enum PersonOnly: String, Equatable, Sendable, CaseIterable {
    case password, payment, code, captcha, passkey
    public var line: String {
      switch self {
      case .password: return "This step is yours: it asks for a password."
      case .payment: return "This step is yours: it asks for card details."
      case .code: return "This step is yours: it asks for a sign-in code."
      case .captcha: return "This step is yours: it checks that a person is there."
      case .passkey: return "This step is yours: it needs your passkey or security key."
      }
    }
  }

  private static let passkey = "passkey|use (a |your )?security key"
  private static let payment = "card.?(number|no\\b)|credit.?card|debit.?card|cvv|cvc|cvn|card.?security|security.?code|expir(y|ation).?date|name on card"
  private static let code =
    "one.?time|verification.?code|\\botp\\b|2fa|two.?factor|\\bmfa\\b|auth(entication)?.?code|sign.?in.?code|login.?code|"
    + SensitiveFields.recovery
  private static let password = "password|passwd|passcode|passphrase|(^|[^a-z])pin([^a-z]|$)"

  /// The person-only kind of a step from its kind (click, type, key, scroll) and its target's role
  /// and label, or nil. A secret field, a CAPTCHA or a passkey is the person's whatever the step;
  /// card details, codes and passwords are theirs to type.
  public static func personOnly(kind: String, role: String?, label: String?) -> PersonOnly? {
    let role = role?.lowercased() ?? ""
    if role.contains("secure") || role.contains("password") { return .password }
    let words = label ?? ""
    func has(_ pattern: String) -> Bool {
      words.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    if has(BotCheck.names) { return .captcha }
    if has(passkey) { return .passkey }
    guard kind == "type" else { return nil }
    if has(payment) { return .payment }
    if has(code) { return .code }
    if has(password) { return .password }
    return nil
  }
}
