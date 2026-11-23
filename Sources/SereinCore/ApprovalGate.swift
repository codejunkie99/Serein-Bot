import Foundation

/// What an action does (its `Effect`), for every action path. A button word can only raise that
/// effect. Whether a step runs, shows a card or is blocked is `ApprovalDoor.answer`'s alone.
/// Mac run not verified.
public enum ApprovalGate {
  public enum Effect: String, Equatable, Sendable, CaseIterable {
    case read, scroll, navigate, click, type
    case submit, send, post, pay, merge, delete, access, install, settings, book, fill, change, unknown
    /// A file from this Mac put into a page's file field (BrowserModel.upload).
    case upload
    /// Things that leave Serein's computer (ComputerHost): a file kept from its Outbox, text put
    /// on this Mac's clipboard, and a file the person drops into it. Each always asks and is
    /// refused when nobody is there, like `upload`.
    case fileOut, clipboardOut, fileIn
    /// Starting Serein's computer on another company's servers under the person's own account
    /// (ComputerHost, HostedComputer): the first-use card says where it runs, what Serein sends
    /// there and that it may cost money. Always asks, never Autopilot, refused when nobody is there.
    case hostedStart
    /// The person's own computer over SSH (ComputerHost, OwnComputer): trusting a machine's host
    /// key on its fingerprint card, and installing Serein's helper in their home there on a card
    /// that lists every file. Always ask, never Autopilot, refused when nobody is there.
    case hostKey, ownInstall
    /// A folder on this Mac shared read-only with an assistant's computer, or no longer shared
    /// (ComputerHost.setSharedFolder): the card names the folder and what the assistant can read.
    /// Always asks, never Autopilot, refused when nobody is there.
    case sharedFolder
    /// Letting Serein's computer reach or use more (ComputerHost, ComputerAllowlist): turning its
    /// list of sites off, or adding a site while it is on, for Serein's proxy or for a hosted
    /// provider's own internet, and raising its memory cap. Always asks, never Autopilot, refused
    /// when nobody is there.
    case widening
  }

  /// Effects that wait for a person, even under Autopilot (`mustAsk`). A constant in release
  /// builds; only a debug build's review test can replace it (`Review`), to show its guard holds.
  private static let liveMustAsk: Set<Effect> = [
    .submit, .send, .post, .pay, .merge, .delete, .access, .install, .settings, .book, .fill, .change, .unknown,
    .upload, .fileOut, .clipboardOut, .fileIn, .hostedStart, .hostKey, .ownInstall, .sharedFolder, .widening,
  ]
  #if DEBUG
  public static var mustAsk: Set<Effect> { Review.mustAsk ?? liveMustAsk }
  #else
  public static let mustAsk = liveMustAsk
  #endif

  /// Return, Enter, and the keypad names (`submitKeys`): each submits, so it asks. A constant in
  /// release builds, like `mustAsk`.
  private static let liveSubmitKeys: Set<String> = ["return", "enter", "keypadenter", "kpenter", "numpadenter"]
  #if DEBUG
  public static var submitKeys: Set<String> { Review.submitKeys ?? liveSubmitKeys }
  #else
  public static let submitKeys = liveSubmitKeys
  #endif

  #if DEBUG
  /// Debug builds only: review tests (ApprovalReviewTests, PageReadingTests) replace one gate
  /// table to prove that its guard is what holds, then set it back to nil (the live table).
  /// Release builds have no such path: the tables are constants.
  @_spi(SereinReview)
  public enum Review {
    public static var mustAsk: Set<Effect>?
    public static var submitKeys: Set<String>?
    public static var labelRaises: [String: Effect]?
  }
  #endif

  /// Which page signals count. Turning one off is the dropped guard for that signal.
  /// Review tests see this. Production calls do not take a guards argument.
  @_spi(SereinReview)
  public struct PageGuards: Equatable, Sendable {
    public var card: Bool
    public var price: Bool
    public var payWords: Bool
    public var paymentForm: Bool
    public var unclassifiedClick: Bool
    public var access: Bool
    public var secret: Bool
    public init(
      card: Bool = true, price: Bool = true, payWords: Bool = true, paymentForm: Bool = true,
      unclassifiedClick: Bool = true, access: Bool = true, secret: Bool = true
    ) {
      self.card = card
      self.price = price
      self.payWords = payWords
      self.paymentForm = paymentForm
      self.unclassifiedClick = unclassifiedClick
      self.access = access
      self.secret = secret
    }
    public static let live = PageGuards()
  }

  /// Words that can raise an effect (`labelRaises`). They never lower one. Empty, a payment form
  /// still asks. A constant in release builds, like `mustAsk`.
  private static let liveLabelRaises: [String: Effect] = [
    "merge": .merge,
    "send": .send, "reply": .send, "share": .send,
    "post": .post, "publish": .post, "tweet": .post,
    "pay": .pay, "purchase": .pay, "buy": .pay, "donate": .pay, "checkout": .pay, "check out": .pay,
    "subscribe": .pay, "transfer": .pay, "upgrade": .pay, "tip": .pay,
    // "Order history" opens a list. These place the order.
    "place order": .pay, "place your order": .pay, "order now": .pay, "complete order": .pay,
    "confirm order": .pay, "submit order": .pay, "reorder": .pay, "order again": .pay,
    "delete": .delete, "remove": .delete, "trash": .delete, "erase": .delete, "discard": .delete,
    "install": .install, "uninstall": .install,
    "sign out": .access, "log out": .access, "logout": .access,
    "book": .book,
    "fill": .fill,
    // Agreeing to every cookie or term is never routine: it asks under Autopilot and in scheduled runs.
    "accept all": .access, "allow all": .access, "agree": .access, "accept cookies": .access, "allow cookies": .access,
  ]
  #if DEBUG
  public static var labelRaises: [String: Effect] { Review.labelRaises ?? liveLabelRaises }
  #else
  public static let labelRaises = liveLabelRaises
  #endif

  /// Whole labels of the choice in a cookie, consent, survey or newsletter overlay that shares the
  /// least. A click is rated a plain click only when PageKit calls the control private and its whole
  /// label is on this list (`privateConsent`): a word inside a longer label ("Close account") never
  /// counts. Page text alone never lowers anything.
  static let privateConsentLabels: Set<String> = [
    "reject", "reject all", "reject cookies", "reject all cookies", "reject non-essential", "reject non-essential cookies",
    "reject optional cookies", "reject additional cookies", "decline", "decline all", "decline cookies",
    "decline all cookies", "decline optional cookies", "refuse", "refuse all", "refuse cookies", "deny", "deny all",
    "disagree", "essential only", "only essential", "essential cookies only", "only essential cookies",
    "use essential cookies only", "necessary only", "only necessary", "necessary cookies only",
    "only necessary cookies", "use necessary cookies only", "required only", "only required",
    "strictly necessary only", "strictly necessary cookies only", "continue without accepting",
    "continue without agreeing", "do not accept", "do not consent", "accept only essential cookies",
    "accept only necessary cookies", "allow only necessary cookies", "allow necessary only", "accept necessary only",
    "close", "dismiss", "no thanks", "no, thanks", "not now", "maybe later", "\u{d7}", "\u{2715}", "\u{2716}", "x",
  ]

  public struct GateAction: Equatable, Sendable {
    public var kind: String
    public var label: String?
    public var app: String?
    public var role: String?
    public var key: String?
    public var text: String?
    public var effect: Effect?
    public var passwordForm: String = ""
    public var formSubmits: Bool
    public var formTarget: String?
    public var nearbyAmount: Bool
    public var elementID: String
    public var pageVersion: String
    public var site: String?
    public init(
      kind: String, label: String? = nil, app: String? = nil, role: String? = nil, key: String? = nil,
      text: String? = nil, effect: Effect? = nil, formSubmits: Bool = false, formTarget: String? = nil,
      nearbyAmount: Bool = false, elementID: String = "", pageVersion: String = "", site: String? = nil
    ) {
      self.kind = kind
      self.label = label
      self.app = app
      self.role = role
      self.key = key
      self.text = text
      self.effect = effect
      self.formSubmits = formSubmits
      self.formTarget = formTarget
      self.nearbyAmount = nearbyAmount
      self.elementID = elementID
      self.pageVersion = pageVersion
      self.site = site
    }
  }

  public struct ActionIntent: Equatable, Sendable {
    public var id: String
    public var passwordForm: String = ""
    public var elementID: String
    public var pageVersion: String
    public var effect: Effect
  }

  public enum HumanAnswer: Equatable, Sendable { case yes, no, timeout, error }

  /// Return, Enter, and keypad Enter submit in every app.
  public static func returnSubmits(app: String, role: String?, key: String) -> Bool {
    _ = app
    _ = role
    return isSubmitKey(key)
  }

  public static func isSubmitKey(_ key: String) -> Bool {
    let (base, _) = MacKey.judged(key)
    return submitKeys.contains(base)
  }

  /// Mail's Send (Shift-Cmd-D), and Cmd-Return or Cmd-Enter, which send in Outlook, Gmail, Slack
  /// and most mail and chat apps. Each is judged as sending in every app, whatever it does there.
  public static func sendsMessage(_ key: String) -> Bool {
    guard let pressed = MacKey.parse(key), pressed.command else { return false }
    return [MacKey.named["return"], MacKey.named["keypadenter"]].contains(pressed.code)
      || (pressed.shift && pressed.code == MacKey.letters["d"])
  }

  /// The effect after form, key, amount and raise-only words.
  /// A payment form is pay even when the label is Confirm and the word list is empty.
  public static func resolved(_ action: GateAction) -> Effect {
    resolved(action, honorPayment: true)
  }

  /// `honorPayment` false is the dropped guard: a payment form is only a submit.
  @_spi(SereinReview)
  public static func resolved(_ action: GateAction, honorPayment: Bool) -> Effect {
    var effect = structural(action, honorPayment: honorPayment)
    if let raised = raisedEffect(in: action.label ?? ""), rank(raised) > rank(effect) { effect = raised }
    // A Mac element has no page reading. Its own label is all that shows a price or a card field.
    if honorPayment, let label = action.label, !["scroll", "read", "hover"].contains(action.kind),
      hasPrice(label) || (action.kind == "type" && cardMarkers.contains(where: label.lowercased().contains))
    {
      effect = .pay
    }
    return effect
  }

  /// Rates a click from a page reading. A card field in any frame, a price in any currency or
  /// number format, or pay / buy / confirm order on the label or nearby text is a payment.
  /// A click with none of those, and no other effect, asks. It does not run on its own.
  /// Words only raise.
  public static func rate(_ action: GateAction, reading: PageSnapshot) -> Effect {
    rate(action, reading: reading, guards: .live)
  }

  /// Turning a guard off is how a review shows that signal was load-bearing.
  @_spi(SereinReview)
  public static func rate(_ action: GateAction, reading: PageSnapshot, guards: PageGuards) -> Effect {
    var effect = structural(action, honorPayment: guards.paymentForm)
    // A scroll, a read or a hover does not become a payment because the page shows a price.
    // A click, a key, a type or a select does.
    let words = [action.label, reading.label, reading.nearbyText].compactMap { $0 }.joined(separator: " ")
    if !["scroll", "read", "hover"].contains(action.kind) {
      if guards.paymentForm && isPaymentForm(reading) { effect = higher(effect, .pay) }
      if guards.card && hasCard(reading) { effect = higher(effect, .pay) }
      if guards.price && hasPrice(reading.pageText + "\n" + reading.nearbyText + "\n" + (action.label ?? "")) {
        effect = higher(effect, .pay)
      }
      if guards.payWords && paymentWords(words) { effect = higher(effect, .pay) }
      if guards.access && accessGrant(words) { effect = higher(effect, .access) }
      // Submitting a form on a page with a password field signs in.
      if guards.access && reading.submits && reading.fields.contains(where: { $0.type.lowercased() == "password" }) {
        effect = higher(effect, .access)
      }
      // An overlay's accept choice ("OK", "Got it") agrees to everything, whatever its words.
      if reading.consent == "accept" { effect = higher(effect, .access) }
    }
    if let raised = raisedEffect(in: action.label ?? reading.label) {
      if raised == .pay {
        if guards.payWords { effect = higher(effect, raised) }
      } else if rank(raised) > rank(effect) {
        effect = raised
      }
    }
    if action.kind == "click", guards.unclassifiedClick, rank(effect) <= rank(.click),
      !benignNumberControl(action.label), !privateConsent(action.label, reading: reading)
    {
      effect = .unknown
    }
    return effect
  }

  /// The effect of pressing the control one page reading names.
  public static func judge(_ reading: PageSnapshot) -> Effect {
    judge(reading, guards: .live)
  }

  /// The same judgment with one page signal turned off, for a review test.
  @_spi(SereinReview)
  public static func judge(_ reading: PageSnapshot, guards: PageGuards) -> Effect {
    let secret = guards.secret && reading.secret
    let action = GateAction(
      kind: "click", label: reading.label, role: secret ? "AXSecureTextField" : nil,
      formSubmits: reading.submits, elementID: reading.bind, pageVersion: "page")
    return rate(action, reading: reading, guards: guards)
  }

  /// Effects that never run without a person: a file leaving this Mac (`upload`), and anything
  /// crossing the line between Serein's computer and this Mac, and a computer started on another
  /// company's servers, trusting or installing on the person's own machine, a folder of this Mac
  /// shared with a computer, and widening what a computer may reach. No standing grant covers them.
  public static let personOnly: Set<Effect> = [
    .upload, .fileOut, .clipboardOut, .fileIn, .hostedStart, .hostKey, .ownInstall, .sharedFolder, .widening,
  ]

  /// The effect a Mac step has.
  public static func effect(of step: RelayAutonomy.MacStep) -> Effect { resolved(gateAction(step)) }
  static func gateAction(_ step: RelayAutonomy.MacStep) -> GateAction {
    GateAction(kind: step.kind, label: step.label, app: step.app, role: step.role, key: step.key, text: step.text)
  }

  /// A plugin's own risk can raise the effect and cannot lower it.
  /// Using the declared risk in place of a higher effect lets a read-rated send run.
  /// Nil means the tool named no risk, and the call is refused.
  public static func pluginEffect(
    name: String, declared: PluginManifest.Risk?, effect structural: Effect? = nil
  ) -> Effect? {
    guard let declared else { return nil }
    var effect = structural ?? .unknown
    let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    if let raised = raisedEffect(in: words.joined(separator: " ")), rank(raised) > rank(effect) {
      effect = raised
    }
    // "charge_card", "create_invoice_payment": it moves money unless its first word only reads.
    if let first = words.first, !ConnectedApps.readVerbs.contains(first), words.contains(where: moneyWords.contains) {
      effect = .pay
    }
    let fromDeclared: Effect
    switch declared {
    case .read: fromDeclared = .read
    case .write: fromDeclared = .change
    case .send: fromDeclared = .send
    case .delete: fromDeclared = .delete
    case .pay: fromDeclared = .pay
    }
    if rank(fromDeclared) > rank(effect) { effect = fromDeclared }
    return effect
  }

  public static func askLine(_ effect: Effect) -> String {
    switch effect {
    case .pay: return "This may pay for something."
    case .send: return "This may send a message."
    case .post: return "This may post it."
    case .merge: return "This may merge something."
    case .delete: return "This may delete something."
    case .access: return "This may change who has access."
    case .install: return "This may install or remove something."
    case .settings: return "This changes a setting."
    case .submit: return "This may submit a form."
    case .fill: return "This may fill in saved information."
    case .book: return "This may book something."
    case .upload: return "This sends a file from your Mac to the site."
    case .fileOut: return "This copies a file from Serein's computer to your Downloads folder."
    case .clipboardOut: return "This puts text from Serein's computer on your clipboard."
    case .fileIn: return "This puts a file from your Mac into Serein's computer."
    case .hostedStart: return "This starts Serein's computer on another company's servers, under your account."
    case .hostKey: return "This trusts a machine's identity, so Serein may connect to it over SSH."
    case .ownInstall: return "This installs Serein's helper on your own machine, in your home folder there."
    case .sharedFolder: return "This changes which folder on your Mac an assistant's computer can read."
    case .widening: return "This lets Serein's computer reach or use more than it does now."
    case .change, .unknown: return "This may change something. Check it before you allow it."
    case .read, .scroll, .navigate, .click, .type: return "Check this before you allow it."
    }
  }

  /// Effects a spoken “allow” may answer in a call (after a read-back and a second yes): only the
  /// lowest-rank page steps that do not wait for a person by themselves. Every other effect, and
  /// a card that names none, needs a click.
  public static func voiceEligible(_ effect: Effect) -> Bool {
    switch effect {
    case .click, .navigate, .scroll, .type: return !mustAsk.contains(effect)
    default: return false
    }
  }

  /// A Mac script's code, lowercased, with every string literal blanked so words inside them
  /// never count. It honours AppleScript's \" escape: a string that hides a quote cannot swallow
  /// the code after it. The gate and the card both judge this text, so they never disagree.
  public static func scriptCode(_ source: String) -> String {
    source.lowercased().replacingOccurrences(
      of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
  }

  /// The effect of a Mac script. Words inside quotes are not the script.
  public static func scriptEffect(source: String) -> Effect {
    let code = scriptCode(source)
    var effect = verbEffect(code)
    if let raised = raisedEffect(in: code), rank(raised) > rank(effect) { effect = raised }
    // A script that presses, types or changes something does it to what its strings name: the
    // button "Buy", a '#place-order' selector, a password sheet. There the strings raise too.
    guard effect != .read else { return effect }
    let whole = source.lowercased().replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
    if scriptActs.contains(where: { containsWord(code, $0) }), let raised = raisedEffect(in: whole),
      rank(raised) > rank(effect)
    {
      effect = raised
    }
    if rank(effect) < rank(.access), scriptAsksPassword(source) { effect = .access }
    return effect
  }
  /// A script that asks for a password, or types into a password sheet.
  static func scriptAsksPassword(_ source: String) -> Bool {
    let whole = source.lowercased().replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
    return ["administrator privileges", "hidden answer", "securityagent", "password", "passcode"].contains(where: whole.contains)
  }

  /// Settings changes, access grants and update installs ask. A read of settings does not.
  public static func settingsEffect(tool: String, action: String = "") -> Effect {
    switch tool {
    case "settings_get": return .read
    case "update": return action == "check" ? .read : .install
    case "settings_set": return .settings
    case "agent_sign_in": return .access
    // A prompt shortcut whose words schedule or watch: it asks, as a request for later does.
    case "shortcut_save": return AgentWrite.requestEffect()
    default: return .unknown
    }
  }

  public static func webAction(name: String, arguments: [String: Any], site: String?, pageVersion: String) -> GateAction {
    let label = (arguments["name"] as? String) ?? (arguments["label"] as? String)
    var action = GateAction(
      kind: name, label: label, key: arguments["key"] as? String, text: arguments["text"] as? String,
      formSubmits: arguments["submits"] as? Bool ?? false,
      formTarget: arguments["formTarget"] as? String,
      nearbyAmount: arguments["nearbyAmount"] as? Bool ?? false,
      elementID: arguments["ref"] as? String ?? "", pageVersion: pageVersion, site: site)
    if arguments["press_enter"] as? Bool == true { action.effect = .submit }
    if arguments["pays"] as? Bool == true { action.formSubmits = true; action.formTarget = "payment" }
    return action
  }

  /// Written down before the action runs. The id comes from `mint`.
  public static func record(_ action: GateAction, effect: Effect, mint: () -> String) -> ActionIntent {
    ActionIntent(id: mint(), passwordForm: action.passwordForm, elementID: action.elementID, pageVersion: action.pageVersion, effect: effect)
  }

  /// One pending ask per element, page version and effect.
  public static func mergePending(_ pending: [ActionIntent], _ next: ActionIntent) -> [ActionIntent] {
    if let index = pending.firstIndex(where: {
      $0.elementID == next.elementID && $0.pageVersion == next.pageVersion && $0.effect == next.effect
    }) {
      var copy = pending
      copy[index] = next
      return copy
    }
    return pending + [next]
  }

  public enum PressCheck: Equatable, Sendable { case proceed, effectChanged, refused }

  /// Only an explicit yes, for this element, this page version and this effect, may run.
  /// A timeout or an error is a no. A different element or version is a no.
  /// A different effect is a no here; the caller asks again instead of pressing.
  /// `liveEffect` is the classification of the control as it is now, not the one that was approved.
  public static func beforeInput(
    intent: ActionIntent, answer: HumanAnswer, liveElement: String, liveVersion: String, liveEffect: Effect
  ) -> Bool {
    pressCheck(
      intent: intent, answer: answer, liveElement: liveElement, liveVersion: liveVersion,
      liveEffect: liveEffect) == .proceed
  }

  /// The same check with a comparison turned off, so a review can show it was load-bearing.
  @_spi(SereinReview)
  public static func beforeInput(
    intent: ActionIntent, answer: HumanAnswer, liveElement: String, liveVersion: String,
    liveEffect: Effect, compareEffect: Bool, honorAnswer: Bool, compareElement: Bool
  ) -> Bool {
    pressCheck(
      intent: intent, answer: answer, liveElement: liveElement, liveVersion: liveVersion,
      liveEffect: liveEffect, compareEffect: compareEffect, honorAnswer: honorAnswer,
      compareElement: compareElement) == .proceed
  }

  /// The same check as `beforeInput`, split so an effect change can ask again
  /// and an element or version change is refused.
  public static func pressCheck(
    intent: ActionIntent, answer: HumanAnswer, liveElement: String, liveVersion: String, liveEffect: Effect
  ) -> PressCheck {
    pressCheck(
      intent: intent, answer: answer, liveElement: liveElement, liveVersion: liveVersion,
      liveEffect: liveEffect, compareEffect: true, honorAnswer: true, compareElement: true)
  }

  @_spi(SereinReview)
  public static func pressCheck(
    intent: ActionIntent, answer: HumanAnswer, liveElement: String, liveVersion: String,
    liveEffect: Effect, compareEffect: Bool, honorAnswer: Bool, compareElement: Bool
  ) -> PressCheck {
    if honorAnswer, answer != .yes { return .refused }
    if compareElement, intent.elementID != liveElement { return .refused }
    if intent.pageVersion != liveVersion { return .refused }
    if compareEffect, liveEffect != intent.effect { return .effectChanged }
    return .proceed
  }

  /// Identity of a Mac control, from a fresh read. Label and value are part of it.
  public static func controlToken(role: String, label: String, value: String, window: String, ref: String) -> String {
    [role, label, value, window, ref].joined(separator: "\u{1f}")
  }

  /// The running app a script is about to touch. A second call is a second look.
  public static func processStamp(bundleID: String, pid: Int32) -> String {
    "\(bundleID)|\(pid)"
  }

  /// The plugin tool as it is declared now. A risk change is a different tool.
  public static func pluginStamp(name: String, risk: String) -> String {
    "\(name)|\(risk)"
  }

  /// A file field in a payment form: card fields in the field's own document, a form that speaks
  /// of paying, or the field's own frame (`frameAddress`, its address and host) served by a
  /// payment provider. Uploads there are refused.
  public static func paymentField(_ reading: PageSnapshot, frameAddress: String?) -> Bool {
    if reading.fields.contains(where: isCard) { return true }
    let blob = reading.formBlob.lowercased()
    if paymentTerms.contains(where: { containsWord(blob, $0) }) { return true }
    guard let frameAddress, !frameAddress.isEmpty else { return false }
    return isPaymentFrame(PageSnapshot.Frame(src: frameAddress, title: "", name: "", id: ""))
  }

  /// Words that make a form or a request path a payment.
  static let paymentTerms = ["pay", "payment", "checkout", "billing", "purchase"]
  /// Payment providers, by a piece of their address.
  static let paymentProviders = ["stripe", "paypal", "braintree", "checkout.com", "adyen", "squareup"]

  /// A request Serein builds itself (`service_request`). GET and HEAD read. Anything else changes
  /// something, deletes for DELETE, and pays when it goes to a payment provider or its path names
  /// paying or a charge.
  public static func requestEffect(method: String, host: String, path: String) -> Effect {
    let verb = method.uppercased()
    if verb == "GET" || verb == "HEAD" { return .read }
    let words = path.lowercased().split(whereSeparator: { !$0.isLetter }).map { $0.hasSuffix("s") ? String($0.dropLast()) : String($0) }
    let host = host.lowercased()
    if paymentProviders.contains(where: { host.contains($0) }) || words.contains(where: { paymentTerms.contains($0) || $0 == "charge" }) {
      return .pay
    }
    return verb == "DELETE" ? .delete : .change
  }

  /// Form, key and amount, before button words. Payment is included only while `honorPayment` is set.
  private static func structural(_ action: GateAction, honorPayment: Bool) -> Effect {
    var effect = action.effect ?? base(action)
    if action.formSubmits {
      switch action.formTarget {
      case "payment": effect = higher(effect, honorPayment ? .pay : .submit)
      case "message": effect = higher(effect, .send)
      case "merge": effect = higher(effect, .merge)
      default: effect = higher(effect, .submit)
      }
    }
    if action.nearbyAmount, honorPayment { effect = higher(effect, .pay) }
    if action.kind == "key", let key = action.key, isSubmitKey(key) { effect = higher(effect, .submit) }
    if action.kind == "key", let key = action.key, sendsMessage(key) { effect = higher(effect, .send) }
    if action.kind == "type", let text = action.text, text.contains(where: \.isNewline) {
      effect = higher(effect, .submit)
    }
    return effect
  }

  private static func hasCard(_ reading: PageSnapshot) -> Bool {
    reading.fields.contains(where: isCard) || reading.frames.contains(where: isPaymentFrame)
  }

  private static func isCard(_ field: PageSnapshot.Field) -> Bool {
    let autocomplete = field.autocomplete.lowercased()
    let tokens = autocomplete.split { $0 == " " || $0 == "\t" }
    if tokens.contains(where: { $0.hasPrefix("cc-") }) { return true }
    let blob = "\(field.name) \(field.id) \(field.label) \(autocomplete)".lowercased()
    return cardMarkers.contains { blob.contains($0) }
  }

  private static let cardMarkers = [
    "cardnumber", "card number", "card-number", "card_number", "cc-number", "ccnumber",
    "cvv", "cvc", "cvc2", "credit card",
  ]

  private static func isPaymentFrame(_ frame: PageSnapshot.Frame) -> Bool {
    let blob = "\(frame.src) \(frame.title) \(frame.name) \(frame.id)".lowercased()
    if paymentProviders.contains(where: { blob.contains($0) }) { return true }
    if blob.contains("card"),
      blob.contains("payment") || blob.contains("element") || blob.contains("frame") || blob.contains("checkout")
    {
      return true
    }
    return false
  }

  /// A number is a price only with a currency marker, or beside a buy, pay, checkout or place-order control.
  /// A bare number does not raise. Missing a price never lowers a card or a password.
  static func hasPrice(_ text: String) -> Bool {
    currencyAmount(text) || priceBesidePurchase(text)
  }

  static let symbolPrice = #"[$€£¥₹₩₽₺₫₴₱฿₪₦]\s*\d|\d\s*[$€£¥₹₩₽₺₫₴₱฿₪₦]"#

  static func pricedAcrossRows(_ first: String, _ second: String) -> Bool {
    guard first.contains(where: \.isNumber) || second.contains(where: \.isNumber) else { return false }
    return currencyAmount(first + " " + second)
  }

  private static func currencyAmount(_ text: String) -> Bool {
    // TRY is also an English verb. In prose require the ISO spelling. A standalone
    // amount and currency label can still use lowercase like the other ISO codes.
    if text.range(of: #"\bTRY\s*\d|\b\d[\d.,]*\s*TRY\b"#, options: .regularExpression) != nil ||
       text.range(of: #"^\s*(?:try\s*\d[\d.,]*|\d[\d.,]*\s*try)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return true
    }
    let lower = text.lowercased()
    let patterns = [
      symbolPrice,
      #"\b(?:usd|eur|gbp|inr|jpy|cad|aud|chf|cny|krw|rub|vnd|uah|rs\.?|rp\.?|kr\.?|zł)\s*\d"#,
      #"\b\d[\d.,]*\s*(?:usd|eur|gbp|inr|jpy|cad|aud|chf|cny|krw|rub|vnd|uah|kr|zł)\b"#,
    ]
    return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
  }

  private static func priceBesidePurchase(_ text: String) -> Bool {
    let lower = text.lowercased()
    let verbs = ["place order", "checkout", "check out", "pay", "buy"]
    guard verbs.contains(where: { containsWord(lower, $0) }) else { return false }
    return lower.range(of: #"\d"#, options: .regularExpression) != nil
  }

  /// Page numbers and quantity steppers are not buys. A price beside them still raises in `hasPrice`.
  static func benignNumberControl(_ label: String?) -> Bool {
    guard let raw = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return false }
    if raw.range(of: #"^(page\s+)?\d+$"#, options: .regularExpression) != nil { return true }
    if raw.range(of: #"^[+\-−]$"#, options: .regularExpression) != nil { return true }
    return raw == "quantity" || raw == "qty"
  }

  /// A press that only moves about a page or edits what it holds, by its whole label: a page
  /// number or quantity stepper (`benignNumberControl`), an overlay's least-sharing choice
  /// (`privateConsentLabels`), a delete word alone (`labelRaises`), or one of `movesOnly`. Serein's
  /// computer has no page reading, so on a window that may pay these are its presses that run.
  static func commitsNothing(_ label: String) -> Bool {
    let raw = label.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: " .!:<>\u{2039}\u{203a}\u{ab}\u{bb}\u{2190}\u{2192}").union(.whitespacesAndNewlines))
    return benignNumberControl(raw) || privateConsentLabels.contains(raw) || movesOnly.contains(raw) || labelRaises[raw] == .delete
  }
  static let movesOnly: Set<String> = [
    "back", "go back", "previous", "cancel", "edit", "apply coupon", "apply code", "show details", "hide details",
    "view details", "details", "increase quantity", "decrease quantity",
  ]

  /// Reject all, essential only, a survey's close: a click on it shares the least, so it is a plain
  /// click, not an unclassified one. PageKit's kind must say so, and its whole label is on this list.
  private static func privateConsent(_ label: String?, reading: PageSnapshot) -> Bool {
    guard reading.present, reading.consent == "private",
      let raw = label?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !raw.isEmpty, raw.count <= 60
    else { return false }
    return privateConsentLabels.contains(raw.trimmingCharacters(in: CharacterSet(charactersIn: ".!")))
  }

  private static func paymentWords(_ text: String) -> Bool {
    let lower = text.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return containsWord(lower, "pay") || containsWord(lower, "buy") || containsWord(lower, "confirm order")
  }

  private static func accessGrant(_ text: String) -> Bool {
    let lower = text.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return containsWord(lower, "grant access") || containsWord(lower, "allow access")
      || containsWord(lower, "sign out") || containsWord(lower, "log out") || containsWord(lower, "logout")
  }

  private static func isPaymentForm(_ reading: PageSnapshot) -> Bool {
    guard reading.submits else { return false }
    let blob = reading.formBlob.lowercased()
    return paymentTerms.contains { containsWord(blob, $0) }
  }

  private static func base(_ action: GateAction) -> Effect {
    switch action.kind {
    case "scroll": return .scroll
    case "read", "hover": return .read
    case "type": return .type
    case "select": return .change
    // A Mac element's own actions (background mac_act): ranked above the unknown they had.
    case "confirm": return .submit
    case "increment", "decrement": return .change
    case "click":
      let label = action.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return label.isEmpty ? .unknown : .click
    case "key":
      guard let key = action.key else { return .unknown }
      if sendsMessage(key) { return .send }
      if isSubmitKey(key) { return .submit }
      let (name, modified) = MacKey.judged(key)
      if modified && ["delete", "backspace"].contains(name) { return .delete }
      if modified && ["q", "w"].contains(name) { return .access }
      return .navigate
    default: return .unknown
    }
  }

  private static let scriptActs = [
    "click", "keystroke", "key code", "perform", "do shell script", "do script", "do javascript", "run script",
  ]
  /// Nouns that mean a tool moves money ("create charge", "send payout"), where no verb says so.
  static let moneyWords: Set<String> = ["charge", "charges", "payment", "payments", "payout", "payouts"]

  private static func verbEffect(_ code: String) -> Effect {
    let writes = ["make", "set", "move", "empty", "quit", "close", "eject", "duplicate",
                  "restart", "shut down", "shutdown", "log out", "logout", "sleep"]
    // A script that presses, types or runs other code acts through it. Its own words do not say what it does.
    if scriptActs.contains(where: { containsWord(code, $0) }) { return .unknown }
    if writes.contains(where: { containsWord(code, $0) }) { return .change }
    if ["get", "count"].contains(where: { containsWord(code, $0) }) { return .read }
    return .unknown
  }

  static func raisedEffect(in text: String) -> Effect? {
    let lower = text.lowercased()
    var best: Effect?
    for (word, effect) in labelRaises {
      guard containsWord(lower, word) else { continue }
      if best == nil || rank(effect) > rank(best!) { best = effect }
    }
    return best
  }

  private static func higher(_ current: Effect, _ next: Effect) -> Effect {
    rank(next) > rank(current) ? next : current
  }

  private static func rank(_ effect: Effect) -> Int {
    switch effect {
    case .read: return 0
    case .scroll, .navigate, .click, .type: return 1
    case .unknown: return 2
    case .change, .fill, .book: return 3
    case .submit, .post, .send: return 4
    case .delete, .merge: return 5
    case .access, .settings, .install, .upload, .fileOut, .clipboardOut, .fileIn, .hostedStart, .hostKey, .ownInstall,
      .sharedFolder, .widening:
      return 6
    case .pay: return 7
    }
  }

  static func containsWord(_ text: String, _ word: String) -> Bool {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
    return text.range(of: pattern, options: .regularExpression) != nil
  }
}

/// Tools that touch the page. Scroll is one of them. Screenshot stays allowed when the others are off.
public enum WebsiteActions {
  public static let gated = ["click", "type", "select", "key", "hover", "screenshot", "do", "scroll", "upload", "click_point", "secure_card"]
  public static func blockedWhenOff(_ name: String) -> Bool {
    gated.contains(name) && name != "screenshot"
  }
}

/// Agent writes that schedule later work or store text the model will see again.
public enum AgentWrite {
  public static func memoryEffect() -> ApprovalGate.Effect { .change }
  public static func watchEffect() -> ApprovalGate.Effect { .change }
  /// A request for later (reminder_create with action): it runs a turn with nobody watching.
  public static func requestEffect() -> ApprovalGate.Effect { .change }
}
