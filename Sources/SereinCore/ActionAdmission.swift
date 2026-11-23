import Foundation

/// Facts read from the live control. They can raise an effect. A caller's lower claim does not win.
public struct ActionAdmission: Equatable, Sendable {
  public var connected: Bool
  public var bind: String
  public var label: String
  public var submits: Bool
  public var formTarget: String?
  public var nearbyAmount: Bool
  public var secret: Bool
  /// The page reading, when this action came from a document. Absent for Mac and for a caller
  /// that has not read the page.
  public var reading: PageSnapshot

  public static let page = ActionAdmission(
    connected: true, bind: "page", label: "", submits: false, formTarget: nil, nearbyAmount: false, secret: false)
  public static let disconnected = ActionAdmission(
    connected: false, bind: "", label: "", submits: false, formTarget: nil, nearbyAmount: false, secret: false)

  public static let needsPerson = "This action needs a person to approve it in Serein."
  public static let declined = "The user declined this action. " + ApprovalLife.noRetry
  public static let pageChanged = "The page changed before Serein could do that, so nothing was pressed."
  /// A press that ran and moved the page on (a link, a submit) before Serein could read it back.
  public static let pressedThenMoved =
    "Pressed. The page moved on before Serein could read back what that did, so it is not reported as done. Read the page before doing anything else, and do not press it again."
  public static let effectChanged = "The control changed before Serein could press it, so the earlier yes was thrown out."

  public init(
    connected: Bool, bind: String, label: String, submits: Bool, formTarget: String?, nearbyAmount: Bool,
    secret: Bool, reading: PageSnapshot = .absent
  ) {
    self.connected = connected
    self.bind = bind
    self.label = label
    self.submits = submits
    self.formTarget = formTarget
    self.nearbyAmount = nearbyAmount
    self.secret = secret
    self.reading = reading
  }

  /// What to tell the person when the press does not run.
  /// A timeout or an error needs a person. An explicit no is a decline.
  /// A yes that no longer matches is a changed page, or a changed effect.
  public static func blocked(
    answer: ApprovalGate.HumanAnswer, decision: RelayAutonomy.Decision, effectChanged: Bool
  ) -> String {
    switch answer {
    case .timeout, .error: return needsPerson
    case .no:
      return decision == .refuse
        ? "This step is yours: that field holds a password, card or code."
        : declined
    case .yes:
      return effectChanged ? Self.effectChanged : pageChanged
    }
  }

  /// The action the gate will judge. A live reading replaces the caller's label and can only raise
  /// the form target. `labelRaises` empty still leaves a payment form as pay.
  public static func action(
    name: String, arguments: [String: Any], site: String?, pageVersion: String, live: ActionAdmission?
  ) -> ApprovalGate.GateAction {
    var gate = ApprovalGate.webAction(name: name, arguments: arguments, site: site, pageVersion: pageVersion)
    guard let live else { return gate }
    if live.reading.present {
      // The page's own words and fields. A caller's pays flag, form target or label is not a payment.
      if live.reading.secret { gate.role = "AXSecureTextField" }
      gate.label = live.reading.label
      gate.passwordForm = live.reading.passwordForm
      gate.formSubmits = live.reading.submits
      gate.formTarget = nil
      gate.nearbyAmount = false
      gate.effect = nil
      if !live.reading.bind.isEmpty { gate.elementID = live.reading.bind }
      else if !live.bind.isEmpty { gate.elementID = live.bind }
      gate.effect = ApprovalGate.rate(gate, reading: live.reading)
      return gate
    }
    if live.secret { gate.role = "AXSecureTextField" }
    // The control's own words. A caller's label cannot calm a payment or invent a safe name.
    gate.label = live.label
    if live.submits { gate.formSubmits = true }
    gate.formTarget = strongerForm(live.formTarget, gate.formTarget)
    if live.nearbyAmount { gate.nearbyAmount = true }
    if !live.bind.isEmpty { gate.elementID = live.bind }
    // No page reading. The same classifier still runs: a click with no real effect asks.
    gate.effect = ApprovalGate.rate(gate, reading: .absent)
    return gate
  }

  /// Payment outranks merge, which outranks a message, which outranks a plain submit.
  /// The lower of the two targets is dropped.
  static func strongerForm(_ live: String?, _ claimed: String?) -> String? {
    func rank(_ target: String?) -> Int {
      switch target {
      case "payment": return 4
      case "merge": return 3
      case "message": return 2
      case "submit": return 1
      default: return 0
      }
    }
    let liveRank = rank(live)
    let claimedRank = rank(claimed)
    if liveRank == 0 && claimedRank == 0 { return nil }
    return liveRank >= claimedRank ? live : claimed
  }

  /// Autopilot on a benign effect is a yes from the gate. Anything else needs an explicit yes.
  /// A missing answer is an error, and an error is not a yes.
  /// A timed-out wait is a no.
  public enum AskTimeout {
    public static func settle(answered: Bool?, timedOut: Bool) -> ApprovalGate.HumanAnswer {
      settle(answered: answered, timedOut: timedOut, timeoutMeansNo: true)
    }

    /// `timeoutMeansNo` false is the dropped guard: a timed-out wait becomes a yes.
    @_spi(SereinReview)
    public static func settle(answered: Bool?, timedOut: Bool, timeoutMeansNo: Bool) -> ApprovalGate.HumanAnswer {
      if let answered { return answered ? .yes : .no }
      if timedOut { return timeoutMeansNo ? .timeout : .yes }
      return .error
    }
  }

  /// What the approval sheet says, and whether the effect could be read from the page.
  public struct Readback: Equatable, Sendable {
    public var effect: ApprovalGate.Effect
    public var target: String
    public var amount: String
    public var recipient: String
    public var summary: String
    public var readable: Bool
  }

  public static func readback(effect: ApprovalGate.Effect, label: String, reading: PageSnapshot) -> Readback {
    let target = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let blob = reading.nearbyText + "\n" + reading.pageText
    let amount = firstMatch(blob, #"[$€£¥₹]\s*\d[\d.,]*|\b(?:usd|eur|gbp|inr|rs\.?)\s*\d[\d.,]*|\b\d[\d.,]*\s*(?:usd|eur|gbp)"#)
    let recipient = firstMatch(blob, #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#)
    let consequential = effect == .pay || effect == .send || effect == .delete
    let readable = !consequential || !target.isEmpty
    var lines = [ApprovalGate.askLine(effect)]
    if !target.isEmpty { lines.append("Target: \(target)") }
    if effect == .pay { lines.append(amount.isEmpty ? "Amount: not shown on the page" : "Amount: \(amount)") }
    if effect == .send { lines.append(recipient.isEmpty ? "Recipient: not shown on the page" : "Recipient: \(recipient)") }
    if effect == .delete, !target.isEmpty { lines.append("This removes: \(target)") }
    return Readback(
      effect: effect, target: target, amount: amount, recipient: recipient,
      summary: lines.joined(separator: "\n"), readable: readable)
  }

  /// After the press, a pay, send or delete that can no longer be read is not reported as done.
  public static func readBackHolds(_ before: Readback, live: PageSnapshot) -> Bool {
    guard before.readable, live.connected else { return false }
    if before.effect != .pay && before.effect != .send && before.effect != .delete { return true }
    if before.target.isEmpty { return false }
    let blob = (live.label + "\n" + live.nearbyText + "\n" + live.pageText).lowercased()
    return blob.contains(before.target.lowercased()) || live.bind == before.target
  }

  private static func firstMatch(_ text: String, _ pattern: String) -> String {
    guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return "" }
    return String(text[range])
  }

  public static func answer(decision: RelayAutonomy.Decision, confirmed: Bool?) -> ApprovalGate.HumanAnswer {
    switch decision {
    case .refuse: return .no
    case .auto: return .yes
    case .ask:
      guard let confirmed else { return .error }
      return confirmed ? .yes : .no
    }
  }
}
