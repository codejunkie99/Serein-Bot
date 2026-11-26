import Foundation

/// A password, a one-time code, card details or an API key a task needs, on a page or in a Mac
/// app. Serein asks the person in a secure card in the chat and fills the field itself; the task's
/// call answers only the result. The value never reaches the model, a tool argument or result, a
/// log or a record. Pure, so it is checked.
public enum SecureCard {
  public enum Kind: String, Sendable, CaseIterable { case password, code, card, key }
  public enum Result: String, Sendable, CaseIterable {
    case filled, declined, pageChanged = "page changed"
  }
  /// One part of a card form, read from the page's fields.
  public enum Part: String, Sendable, CaseIterable { case number, expiry, cvc, holder }

  /// How long a card holds its task's call. Past it the card stays open and the turn parks.
  public static let life: TimeInterval = 540
  /// Kept from the call's wait for the fill and the page read after the person's submit.
  public static let fillReserve: TimeInterval = 20
  /// The server's answer wait from the call's start once a card holds it (`CallClock.hold`).
  public static let heldWait: TimeInterval = 570
  /// Both ends of the socket: the helper cannot know a card is up.
  public static let socketTimeout: Int = 590
  /// Every CLI's MCP tool timeout: Codex `tool_timeout_sec`, OpenCode `timeout`, Claude `MCP_TOOL_TIMEOUT`.
  public static let cliLimit: TimeInterval = 600

  /// The field as the live page shows it, read when the card would rise and again before the fill.
  public struct Field: Equatable, Sendable {
    /// PageKit's `secureKind`, a name in `fieldKinds`; nil when the field is not secret.
    public var kind: String?
    public var autocomplete: String
    /// scheme://host[:port] of the frame that holds the field, and of the tab's top page.
    public var frameOrigin: String
    public var topOrigin: String
    /// Where the field's form sends; nil without a form.
    public var formOrigin: String?
    /// The tab's page loaded over HTTPS with a certificate the system trusts.
    public var trusted: Bool
    public init(
      kind: String?, autocomplete: String, frameOrigin: String, topOrigin: String, formOrigin: String?,
      trusted: Bool
    ) {
      self.kind = kind
      self.autocomplete = autocomplete
      self.frameOrigin = frameOrigin
      self.topOrigin = topOrigin
      self.formOrigin = formOrigin
      self.trusted = trusted
    }
  }

  public enum Admission: Equatable, Sendable {
    case card(Kind)
    case refused(String)
  }

  public static let notSecret = "secure_card is for a password, one-time code or card field. Use type for this field."
  /// R13: a field no card fills goes to the person, who types it in the tab; the task goes on.
  static let personTypes =
    " Routes: call person_step with kind check on this tab, so the person does it there, and carry on with every other part; or reach the same result another way."
  public static let captcha =
    "This field is part of a verification check, which is the user's. Open a takeover card for this tab with ask_person_takeover, then keep working on the rest of the task."
  public static let newPassword =
    "This field sets a new password, which changes the user's account, so Serein does not fill it." + personTypes
  /// A pay press with no secure card or person_step yes before it (R1).
  public static let payOnCard =
    "This press pays. Route: call person_step with kind pay on this button. Serein presses it when the person named this site in their own words (or asks them first), and says why when it cannot; or carry on with the parts that need no payment."
  public static let notSecure =
    "This page is not on a trusted secure connection, so Serein asked nothing and filled nothing." + personTypes
  public static let otherSite = "This form sends to another site, so Serein asked nothing and filled nothing." + personTypes
  public static let framed =
    "This field is in a frame from another site, so Serein asked nothing and filled nothing." + personTypes

  /// Every kind of secret field and what Serein does with it: a card of one kind, or a fixed
  /// refusal. Names are PageKit's `secureKind` on a page and `ComputerHold.PersonOnly` in a Mac app.
  public static let fieldKinds: [String: Admission] = [
    "password": .card(.password), "code": .card(.code), "card": .card(.card), "payment": .card(.card),
    "key": .card(.key), "captcha": .refused(captcha), "passkey": .refused(ComputerHold.PersonOnly.passkey.line),
  ]

  /// Whether a card may rise for `field`. Every refusal is a fixed line with no page text.
  /// `loopback`: a check's local fixture (http://127.0.0.1 or localhost) counts as secure.
  public static func admit(_ field: Field, loopback: Bool = false) -> Admission {
    guard let admission = field.kind.flatMap({ fieldKinds[$0] }) else { return .refused(notSecret) }
    guard case .card(let kind) = admission else { return admission }
    if field.autocomplete.lowercased().split(separator: " ").contains("new-password") { return .refused(newPassword) }
    guard field.trusted || (loopback && isLoopback(field.topOrigin) && isLoopback(field.frameOrigin)) else {
      return .refused(notSecure)
    }
    if let form = field.formOrigin, form != field.frameOrigin { return .refused(otherSite) }
    if field.frameOrigin != field.topOrigin {
      // A card field in a payment provider's own frame is how most checkouts take a card.
      guard kind == .card, let host = URL(string: field.frameOrigin)?.host, isPaymentHost(host) else {
        return .refused(framed)
      }
    }
    return .card(kind)
  }

  /// A field in a Mac app, read through Accessibility when the card would rise and again before the fill.
  public struct MacField: Equatable, Sendable {
    /// `macKind` of the field; nil when it is not one a card fills.
    public var kind: Kind?
    /// The process that owns the field now.
    public var app: MacApp
    public var appName: String
    /// The field is its app's focused element.
    public var focused: Bool
    public init(kind: Kind?, app: MacApp, appName: String, focused: Bool) {
      self.kind = kind
      self.app = app
      self.appName = appName
      self.focused = focused
    }
  }
  /// A running Mac app by bundle identifier and process: a quit and relaunch is another app.
  public struct MacApp: Equatable, Sendable {
    public var bundleID: String
    public var pid: Int32
    public init(bundleID: String, pid: Int32) {
      self.bundleID = bundleID
      self.pid = pid
    }
  }

  public static let macAppRefused =
    "This step is the user's: this app holds passwords or signs in to the Mac itself, so Serein asked nothing and filled nothing."
  public static let otherApp =
    "That field is in another app than the one this task observed, so Serein asked nothing and filled nothing. Observe the app again."
  public static let notFocused =
    "That field lost focus, so Serein asked nothing and filled nothing. Observe the app again."
  /// Apps that ask for the Mac's own password or Touch ID, by name or bundle identifier in lower case.
  public static let systemSignIn: Set<String> = [
    "securityagent", "com.apple.securityagent", "coreautha", "com.apple.coreautha", "loginwindow", "com.apple.loginwindow",
  ]

  /// The card a Mac `type` step into a field with this role and label gets (`fieldKinds` by
  /// `ComputerHold.personOnly`), or nil. A password needs a field that hides its text, so its
  /// value is never read back; a hidden field labelled for a card or a code is that kind.
  public static func macKind(role: String?, label: String?) -> Kind? {
    let hidden = role?.lowercased().contains("secure") == true
    let byLabel = ComputerHold.personOnly(kind: "type", role: nil, label: label)
    let only = hidden && (byLabel == nil || byLabel == .password) ? ComputerHold.PersonOnly.password : byLabel
    guard let only, case .card(let kind)? = fieldKinds[only.rawValue], kind != .password || hidden else { return nil }
    return kind
  }
  /// The one part a Mac card field takes, from its label.
  public static func macPart(label: String) -> Part {
    func has(_ pattern: String) -> Bool { label.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    if has("cvc|cvv|cvn|csc|security.?code") { return .cvc }
    if has("expir|mm.?/.?yy") { return .expiry }
    if has("name|holder") { return .holder }
    return .number
  }

  /// Whether a card may rise for, or fill, a Mac field. `task` is the app the task observed.
  public static func admit(mac field: MacField, task: MacApp) -> Admission {
    let name = field.appName.lowercased().trimmingCharacters(in: .whitespaces)
    if RelayAutonomy.holdsSecrets(app: name, bundleID: field.app.bundleID)
      || systemSignIn.contains(name) || systemSignIn.contains(field.app.bundleID.lowercased())
    {
      return .refused(macAppRefused)
    }
    guard let kind = field.kind else { return .refused(notSecret) }
    guard field.app == task, !task.bundleID.isEmpty else { return .refused(otherApp) }
    guard field.focused else { return .refused(notFocused) }
    return .card(kind)
  }

  public static func isPaymentHost(_ host: String) -> Bool {
    let host = host.lowercased()
    return LocalExecution.paymentHosts.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  static func isLoopback(_ origin: String) -> Bool {
    guard let url = URL(string: origin), ["http", "https"].contains(url.scheme ?? "") else { return false }
    return ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
  }

  /// What the person typed, as the page fill takes it: a password or code under `value`, a card's
  /// parts under their names. Nil when it is not one (blank, a card number that fails its check,
  /// an expiry that is not MM/YY, a code that is not 3 or 4 digits).
  public static func values(_ kind: Kind, parts: [Part], _ entry: SecretEntry) -> [String: String]? {
    switch kind {
    case .password, .code, .key:
      let value = kind == .password ? entry.key : entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, value.count <= 512, !value.contains(where: \.isNewline) else { return nil }
      return ["value": value]
    case .card:
      var out: [String: String] = [:]
      for part in parts.isEmpty ? [.number, .expiry, .cvc] : parts {
        switch part {
        case .number:
          let digits = entry.number.filter { !$0.isWhitespace && $0 != "-" }
          guard (13...19).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
            HandBack.containsCardNumber(digits)
          else { return nil }
          out["number"] = digits
        case .expiry:
          guard let expiry = SecretVault.expiry(entry.expiry) else { return nil }
          out["expiry"] = expiry
        case .cvc:
          let cvc = entry.cvc.trimmingCharacters(in: .whitespaces)
          guard (3...4).contains(cvc.count), cvc.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
          out["cvc"] = cvc
        case .holder:
          let holder = entry.holder.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !holder.isEmpty, holder.count <= 80, !holder.contains(where: \.isNewline) else { return nil }
          out["holder"] = holder
        }
      }
      return out
    }
  }

  /// The card's title, naming the site the value goes to. `amount` is the page's own for a card.
  public static func title(_ kind: Kind, host: String, amount: String?) -> String {
    switch kind {
    case .password: return "Sign in to \(host)"
    case .code: return "Enter the code for \(host)"
    case .card: return amount.map { "Pay \($0) on \(host)" } ?? "Pay on \(host)"
    case .key: return "Enter the key for \(host)"
    }
  }
  /// A read's note when it lists a secure field.
  public static let readNote =
    "Elements marked secure take secure_card: Serein asks the user and fills them, and the call returns at once. Any other password, card, code, key or file field is the user's: call person_step with kind check on this tab and carry on."
  /// The line beside the buttons.
  public static let line = "Serein fills it on the page. The AI never sees it."
  /// A Mac observe's note when it lists a field a card fills.
  public static let macNote =
    "Controls marked secure take a type step with any text: Serein asks the user in a secure card and fills the field itself. Your text is dropped."
  public static let macLine = "Serein fills it in the app. The AI never sees it."
  /// A Mac card's answer when its field changed before the fill.
  public static let macChanged = "The field changed or lost focus, so nothing was filled. Observe the app again."
  /// What a declined card's field says, and why the card would not take an entry.
  public static func refusal(_ kind: Kind) -> String {
    switch kind {
    case .password: return "Type the password."
    case .code: return "Type the code."
    case .card: return "Check the card details."
    case .key: return "Paste the key."
    }
  }

  /// The run's summary while its card waits after the turn ended.
  public static func parkSummary(host: String) -> String { "Waiting on a secure card for \(host)" }
  /// The one turn sent when a parked card is answered. `tab` is nil for a Mac app's field.
  public static func followUp(_ result: Result, host: String, tab: String?) -> String {
    guard let tab else {
      switch result {
      case .filled: return "I answered the secure card for \(host): filled. Observe \(host) again, then carry on with the task."
      case .declined: return "I declined the secure card for \(host). Do not ask again: take another route."
      case .pageChanged: return "The secure card for \(host) could not fill: the field changed. Observe \(host) again and carry on."
      }
    }
    switch result {
    case .filled:
      return "I answered the secure card for \(host): filled. If tab \(tab) is among your tabs, read it again before you act; if not, open the page again. Then carry on with the task."
    case .declined:
      return "I declined the secure card for \(host). Do not ask again: take another route."
    case .pageChanged:
      return "The secure card for \(host) could not fill: the page changed. Open the page again and carry on with the task."
    }
  }

  /// The one press a filled card covers: on the same tab and page, a click or Enter that signs in,
  /// submits or (for a card) pays the amount the card showed. A password, code or key pass covers only
  /// a press in the filled field's own form, so a cookie banner or Log out never takes it.
  public struct Pass: Equatable, Sendable {
    public let tab: String
    public let pageVersion: String
    public let kind: Kind
    public let amount: String?
    /// The one control a person_step pay yes covers; nil for a secure card fill, whose pass the first
    /// sign-in, submit or pay press uses up.
    public let ref: String?
    /// The field a password, code or key card filled; a press counts only inside its form.
    public let field: String?
    public init(tab: String, pageVersion: String, kind: Kind, amount: String?, ref: String? = nil, field: String? = nil) {
      self.tab = tab
      self.pageVersion = pageVersion
      self.kind = kind
      self.amount = amount
      self.ref = ref
      self.field = field
    }
    /// Whether this pass answers a press with `effect` on `tab` at `pageVersion`, whose readback
    /// reads `amount`. `inForm`: the press is in `field`'s form (read from the page). A pass never answers
    /// a refusal, a step the site rule holds, or any other effect.
    public func covers(
      effect: ApprovalGate.Effect, tool: String, key: String?, tab: String, pageVersion: String, amount: String,
      ref: String? = nil, inForm: Bool = false
    ) -> Bool {
      guard tab == self.tab, pageVersion == self.pageVersion else { return false }
      if let own = self.ref, own != ref { return false }
      if field != nil, !inForm { return false }
      guard tool == "click" || (tool == "key" && key?.lowercased() == "enter") else { return false }
      switch kind {
      case .password, .code, .key: return [.access, .submit].contains(effect)
      case .card: return effect == .pay && !amount.isEmpty && amount == self.amount
      }
    }
    /// Whether a press of `effect` uses this pass up, covered or not: for a card the first pay press,
    /// for a password, code or key the first sign-in or submit press in the field's form. A checkbox or
    /// scroll leaves it, and so does a cookie accept (outside the form, or for a card not a pay press).
    public func usedUp(effect: ApprovalGate.Effect, tool: String, key: String?, inForm: Bool = false) -> Bool {
      guard tool == "click" || (tool == "key" && key?.lowercased() == "enter") else { return false }
      if field != nil, !inForm { return false }
      return kind == .card ? effect == .pay : [.access, .submit].contains(effect)
    }
  }
}
