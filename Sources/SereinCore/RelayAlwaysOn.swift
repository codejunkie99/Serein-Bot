import Foundation

/// Notifications during quiet hours (`RelayProactive.quiet`). An ask and a reminder the person set
/// go out at once; every other post waits, merged per chat, for one summary at the brief hour.
public enum RelayOutbox {
  public enum Kind: Sendable {
    /// An approval waiting, a question, "needs you": the person must answer it.
    case ask
    /// A reminder the person set, firing at its own time.
    case reminder
    /// Anything else: a finish, an update, a pause.
    case update
  }
  public static func holds(_ kind: Kind, hour: Int) -> Bool { kind == .update && RelayProactive.quiet(hour) }
  /// A newer post replaces an older one of its kind in the same chat. Reminders never replace
  /// each other: each is one the person set.
  public static func identifier(_ kind: Kind, thread: String) -> String {
    switch kind {
    case .ask: return "serein.ask." + thread
    case .update: return "serein.run." + thread
    case .reminder: return "serein.reminder." + UUID().uuidString
    }
  }
  public static func heldID(thread: String) -> String { "serein.held." + thread }
  public static let summaryTitle = "While you were away"
  static let maxLines = 4
  static let maxBody = 400
  /// The held summary's body with one more post: a repeat moves to the end, the last four stay.
  public static func merged(_ existing: String?, title: String, body: String) -> String {
    let line = (title + ": " + body).components(separatedBy: .newlines).joined(separator: " ")
    var lines = (existing ?? "").components(separatedBy: "\n").filter { !$0.isEmpty && $0 != line }
    lines.append(line)
    return String(lines.suffix(maxLines).joined(separator: "\n").prefix(maxBody))
  }
  /// When held posts are delivered: the next brief hour.
  public static func summaryTime(after now: Date, calendar: Calendar = .current) -> Date {
    RelayUnattended.nextMorning(after: now, hour: RelayProactive.briefHour, calendar: calendar)
  }
}

/// A one-time check-in a run nobody watches sets for itself ("check back on the reply tomorrow").
/// It carries the person's words that led to it (`RelayReminder.source`), never its own text, as
/// its authority (`UnattendedAuthority`).
public enum RelayFollowUp {
  public static let minLead: TimeInterval = 600
  public static let maxLead: TimeInterval = 14 * 86_400
  public static let maxOpen = 3
  public static func open(_ reminders: [RelayReminder]) -> Int { reminders.filter { $0.selfSet == true }.count }
  /// Why this follow-up cannot be set; nil when it can.
  public static func refusal(
    repeats: RelayReminder.Repeat, cron: String?, due: Date, now: Date, setThisRun: Int, open: Int
  ) -> String? {
    if repeats != .none || cron != nil { return "A follow-up you set yourself runs once: leave repeat and cron out." }
    if due < now.addingTimeInterval(minLead) { return "A follow-up must be at least 10 minutes ahead." }
    if due > now.addingTimeInterval(maxLead) { return "A follow-up must be within 14 days." }
    if setThisRun >= 1 { return "One follow-up per run: this run already set one." }
    if open >= maxOpen { return "Three follow-ups you set are already waiting. Let one run or ask the person." }
    return nil
  }
}

/// Whether the person's own words cover one action in a run nobody watches. Only the words the
/// person typed or approved on a card count: never a page, a mail, a tool's output or the model.
/// Unsure is no: the gate then asks (a deferred card, `RelayDeferred`).
public enum UnattendedAuthority {
  /// Effects their words never stand in for: money, sign-ins and access, deleting, installs,
  /// settings and an action nobody could classify.
  public static let alwaysAsks: Set<ApprovalGate.Effect> = [.pay, .access, .delete, .install, .settings, .unknown]
  /// Prose is context, not a structured authorization. In particular, a verb and an app or
  /// address cannot bind a recipient, body, account, or distinguish a quoted/negated command.
  /// Only passive observations may inherit authority from prose. All input and consequential
  /// steps use the existing explicit approval path (including exact one-time deferred grants).
  static let passive: Set<ApprovalGate.Effect> = [.read, .scroll]
  /// On a website the words name, a plain click and a key that moves around the page may go
  /// ahead too (`covers(request:effect:site:)`). Never typing, and never in a Mac app.
  static let onNamedSite: Set<ApprovalGate.Effect> = [.click, .navigate]
  public static func covers(request: String?, effect: ApprovalGate.Effect, targets: [String]) -> Bool {
    guard let request, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return passive.contains(effect)
  }
  /// A Mac app or other place: reading only, whatever the words name.
  public static func covers(request: String?, effect: ApprovalGate.Effect, place: String?) -> Bool {
    guard let place, !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return covers(request: request, effect: effect, targets: [place])
  }
  /// A step on a web page whose host is `site`. Beyond reading, a plain click or a key move is
  /// covered when the words name that site (`host(_:namedIn:)`).
  public static func covers(request: String?, effect: ApprovalGate.Effect, site: String?) -> Bool {
    guard let site, !site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard onNamedSite.contains(effect) else { return covers(request: request, effect: effect, targets: [site]) }
    guard let request, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return host(site, namedIn: words(request)) == true
  }
  /// A key moves around the page unless it lands on a control that holds a value: a field, a
  /// list, a slider, a stepper, a switch or a choice. There an arrow or Space changes what the
  /// control holds (PageKit steps a number or range field itself), and a page can save that at
  /// once, so such a key is never a key move the words cover. A control not read is no.
  public static func keyMoves(on control: PageSnapshot) -> Bool {
    guard control.present, control.connected else { return false }
    if ["input", "textarea", "select"].contains(control.tag) || control.editable { return false }
    let roles = control.role.split(whereSeparator: \.isWhitespace).map(String.init)
    return !roles.contains(where: valueRoles.contains)
  }
  static let valueRoles: Set<String> = [
    "textbox", "searchbox", "combobox", "listbox", "option", "slider", "spinbutton", "switch",
    "checkbox", "radio", "radiogroup", "menuitemcheckbox", "menuitemradio",
  ]
  static func words(_ text: String) -> Set<String> {
    Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
  }
  /// A site is named by its main domain label alone ("etsy" in orders.etsy.com), so a word
  /// tucked into another domain ("evil-etsy.com", "etsy.attacker.example") never names it.
  /// nil: not a host.
  static func host(_ site: String, namedIn said: Set<String>) -> Bool? {
    let host = (URL(string: site)?.host ?? site).lowercased()
    let labels = host.split(separator: ".").map(String.init).filter { $0 != "www" }
    guard labels.count >= 2 else { return nil }
    let main = labels[labels.count - 2]
    return main.allSatisfy { $0.isLetter || $0.isNumber } && said.contains(main)
  }

}

/// An ask from a run nobody watches. The run does not wait: the card stays in the dock, a
/// `proposal` row in the work ledger holds the exact action, and Allow queues a turn in the same
/// chat that carries out that action once (`Grant`).
public enum RelayDeferred {
  /// The action exactly as the card showed it: its words, the exact arguments or script (`more`),
  /// and where it acts. Callers build the card from the tool's name and arguments.
  public struct Action: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var more: String?
    public var app: String?
    public var site: String?
    public var effect: String?
    public var thread: String
    public init(title: String, detail: String, more: String?, app: String?, site: String?, effect: String?, thread: String) {
      self.title = title
      self.detail = detail
      self.more = more
      self.app = app
      self.site = site
      self.effect = effect
      self.thread = thread
    }
  }
  /// The ledger row's payload.
  public struct Ask: Codable, Equatable, Sendable {
    public var action: Action
    /// The assistant whose chat the resume turn runs in; nil is the person's own.
    public var owner: String?
    public var askedAt: Date
    public init(action: Action, owner: String?, askedAt: Date) {
      self.action = action
      self.owner = owner
      self.askedAt = askedAt
    }
    public func payload() -> String? {
      (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func decoded(_ payload: String) -> Ask? {
      try? JSONDecoder().decode(Ask.self, from: Data(payload.utf8))
    }
  }
  /// One yes for one exact action in one chat, used once, gone after a day.
  public struct Grant: Equatable, Sendable {
    public let action: Action
    public let until: Date
    public init(action: Action, at: Date) {
      self.action = action
      self.until = at.addingTimeInterval(lifetime)
    }
  }
  public static let lifetime: TimeInterval = 86_400
  /// Takes the grant that matches `action` exactly, if one is live; spent and expired ones go.
  public static func consume(_ action: Action, from grants: inout [Grant], now: Date) -> Bool {
    grants.removeAll { $0.until <= now }
    guard let index = grants.firstIndex(where: { $0.action == action }) else { return false }
    grants.remove(at: index)
    return true
  }
  /// The ask a `proposal` row holds, when its card should come back after a relaunch: one whose
  /// one-time yes could still live. It grants nothing: the rebuilt card still waits for Allow.
  public static func restored(_ payload: String, now: Date) -> Ask? {
    guard let ask = Ask.decoded(payload), now.timeIntervalSince(ask.askedAt) < lifetime else { return nil }
    return ask
  }
  public static func key(_ id: UUID) -> String { "proposal:" + id.uuidString }
  public static let resumePrefix = "serein.resume."
  public static func isResume(_ reminderID: String) -> Bool { reminderID.hasPrefix(resumePrefix) }
  /// The resume turn's request. It carries no authority of its own: every step but the granted
  /// one asks again.
  public static func resumeText(_ action: Action) -> String {
    let what = (action.title + (action.detail.isEmpty ? "" : " (" + action.detail + ")"))
      .components(separatedBy: .newlines).joined(separator: " ")
    return "Earlier you asked the person on a card: “\(String(what.prefix(300)))”. They allowed it. Do exactly that step now, once, with the same arguments, and nothing else. Then report what happened."
  }
}
