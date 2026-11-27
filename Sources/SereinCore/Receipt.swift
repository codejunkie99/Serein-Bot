import Foundation

/// What a change that landed shows in the chat: one short line, at most one card, and a way back.
/// The host builds it from facts after the effect lands, so the model never claims "done" alone.
/// Words come from `ReceiptCopy`, whose templates `ReceiptCopy.lint` keeps plain.
public struct Receipt: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case reminder, routine, assistantMade, assistantChanged, assistantDeleted, assistantRestored
    case memorySaved, memoryForgot, memoryShared, hookMade, asked, connected, dashboardSaved, undone
    case hookRemoved, boardMoved, filled, paid
  }
  /// The one card a receipt may carry. At most `Receipt.maxRows` rows.
  public enum Card: Codable, Equatable, Sendable {
    /// A reminder, a link to copy, or a note (`bt-info`): a title, a second line and its action.
    case banner(title: String, detail: String, action: String?)
    /// A routine and whether it runs (`control-switch-desc`).
    case routine(title: String, detail: String, on: Bool)
    /// Short rows, such as memories (`card-notification`), newest first.
    case rows([Row])
    /// The 10-second toast after a removal (`bt-undo`).
    case toast(String)
  }
  public struct Row: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var when: String?
    public init(title: String, detail: String, when: String? = nil) {
      self.title = title
      self.detail = detail
      self.when = when
    }
  }
  public static let maxRows = 3
  public static let maxLine = 140

  public var kind: Kind
  public var line: String
  public var card: Card?
  public var undo: UndoToken?
  /// The id of the thing the receipt is about, for its card's action: a link's id for Copy link
  /// (the host reads the secret itself). Never a secret. nil for most receipts.
  public var item: String?

  /// Rows past `maxRows` are dropped here, so no receipt can hold a long list.
  public init(kind: Kind, line: String, card: Card? = nil, undo: UndoToken? = nil, item: String? = nil) {
    self.kind = kind
    self.line = line
    if case .rows(let rows)? = card, rows.count > Self.maxRows {
      self.card = .rows(Array(rows.prefix(Self.maxRows)))
    } else {
      self.card = card
    }
    self.undo = undo
    self.item = item
  }
}

/// The way back from one change. A removal's token lasts `removalWindow`; a made thing keeps
/// its token until the journal entry it names is gone.
public struct UndoToken: Codable, Equatable, Sendable {
  public static let removalWindow: TimeInterval = 10
  /// The journal entry to reverse.
  public var entry: String
  public var kind: Receipt.Kind
  /// nil: good while the journal keeps `entry`.
  public var expires: Date?
  public init(entry: String, kind: Receipt.Kind, expires: Date? = nil) {
    self.entry = entry
    self.kind = kind
    self.expires = expires
  }
  public static func removal(entry: String, kind: Receipt.Kind, now: Date = Date()) -> UndoToken {
    UndoToken(entry: entry, kind: kind, expires: now.addingTimeInterval(removalWindow))
  }
  public func isLive(now: Date = Date()) -> Bool { expires.map { now < $0 } ?? true }
}

/// The words of every receipt. One sentence that starts "Done.", "Okay." or "<Name> is ready.",
/// at most `Receipt.maxLine` characters, and never a feature word.
public enum ReceiptCopy {
  /// Words the person should never see in a receipt (lowercased, matched as whole words).
  public static let bannedWords: Set<String> = [
    "hook", "webhook", "cron", "sqlite", "mcp", "token", "json", "fts", "api", "endpoint", "payload",
    "scope", "provenance", "ledger", "schema", "regex", "uuid",
  ]
  static let openers = ["Done.", "Okay."]

  public static func reminder(at time: String, text: String) -> Receipt {
    Receipt(kind: .reminder, line: "Done. I will remind you at \(time).", card: .banner(title: time, detail: text, action: "Undo"))
  }
  public static func routine(when: String, what: String, on: Bool = true) -> Receipt {
    Receipt(kind: .routine, line: "Okay. \(when) I will \(lowercasedFirst(what)).", card: .routine(title: when, detail: what, on: on))
  }
  public static func made(name: String, job: String, entry: String) -> Receipt {
    Receipt(kind: .assistantMade, line: "\(name) is ready. \(job)", undo: UndoToken(entry: entry, kind: .assistantMade))
  }
  public static func changed(name: String, what: String, entry: String) -> Receipt {
    Receipt(kind: .assistantChanged, line: "Done. \(name) \(what).", undo: UndoToken(entry: entry, kind: .assistantChanged))
  }
  public static func deleted(name: String, entry: String, now: Date = Date()) -> Receipt {
    Receipt(
      kind: .assistantDeleted, line: "Done. \(name) is deleted. Its chats stay in History.",
      card: .toast("\(name) deleted"), undo: .removal(entry: entry, kind: .assistantDeleted, now: now))
  }
  public static func restored(name: String) -> Receipt {
    Receipt(kind: .assistantRestored, line: "\(name) is ready. Everything is back.")
  }
  public static func remembered(_ text: String, sharedWithAll: Bool, entry: String) -> Receipt {
    let whose = sharedWithAll ? "Every assistant can use it." : "Only this assistant uses it."
    return Receipt(kind: .memorySaved, line: "Done. I will remember that. \(whose)", undo: UndoToken(entry: entry, kind: .memorySaved))
  }
  /// A rule the person set (`Rules`): in force from the next turn on, with Undo. `whom` is
  /// `MemoryTools.whom` of its scope.
  public static func ruleSet(whom: String, entry: String) -> Receipt {
    Receipt(kind: .memorySaved, line: "Done. \(whom) will follow that rule from now on.", undo: UndoToken(entry: entry, kind: .memorySaved))
  }
  public static func forgot(entry: String) -> Receipt {
    Receipt(kind: .memoryForgot, line: "Done. I forgot it.", undo: .removal(entry: entry, kind: .memoryForgot))
  }
  public static func shared(with whom: String, entry: String) -> Receipt {
    Receipt(kind: .memoryShared, line: "Done. \(whom) can use it now.", undo: UndoToken(entry: entry, kind: .memoryShared))
  }
  public static func linkMade(for name: String, title: String) -> Receipt {
    Receipt(
      kind: .hookMade, line: "Done. When \(title) calls the link, I wake \(name). The link works on this Mac.",
      card: .banner(title: title, detail: "Wakes \(name)", action: "Copy link"))
  }
  /// After a link was removed (SPEC 5.3): it starts nothing from now on, and Undo puts it back
  /// for `UndoToken.removalWindow` seconds.
  public static func linkRemoved(title: String, entry: String, now: Date = Date()) -> Receipt {
    Receipt(
      kind: .hookRemoved, line: "Done. I removed the link from \(title).",
      undo: .removal(entry: entry, kind: .hookRemoved, now: now))
  }
  /// A Board card an assistant moved (`board_update`). The title may come from a page or mail, so
  /// it is clipped and quoted, never read as words of Serein's own.
  public static func boardMoved(title: String, to column: String, entry: String) -> Receipt {
    let short = title.count > 60 ? String(title.prefix(59)) + "…" : title
    return Receipt(
      kind: .boardMoved, line: "Done. “\(short)” is in \(column) now.", undo: UndoToken(entry: entry, kind: .boardMoved))
  }
  public static func connected(app: String) -> Receipt {
    Receipt(kind: .connected, line: "Done. \(app) is connected.")
  }
  /// A dashboard in the chat. It changes only when the person asks for an update, so the line
  /// says that, not that it updates by itself.
  public static func dashboard(title: String) -> Receipt {
    Receipt(kind: .dashboardSaved, line: "Done. \(title) is ready. Ask me any time to update it.")
  }
  /// The one-time move to Allow all (`AllowAllMigration`), with Undo back to the level before.
  public static func allowAll(entry: String) -> Receipt {
    Receipt(
      kind: .assistantChanged, line: "Done. Serein now runs everything without asking. To change it, say “ask me before …”.",
      card: .banner(title: ApprovalLevel.proactive.title, detail: "It fills what you saved on its own site and pays only sites you named.", action: "Undo"),
      undo: UndoToken(entry: entry, kind: .assistantChanged))
  }
  public static func undone() -> Receipt { Receipt(kind: .undone, line: "Done. It is back the way it was.") }

  /// Problems with one receipt line: empty if it is plain. The checks run every template through this.
  public static func lint(_ line: String, name: String? = nil) -> [String] {
    var problems: [String] = []
    if line.count > Receipt.maxLine { problems.append("longer than \(Receipt.maxLine) characters") }
    let opens = openers.contains { line.hasPrefix($0) } || (name.map { line.hasPrefix("\($0) is ready.") } ?? false)
    if !opens { problems.append("does not start with Done., Okay. or <Name> is ready.") }
    let words = Set(line.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    for word in bannedWords.intersection(words).sorted() { problems.append("uses the feature word \"\(word)\"") }
    return problems
  }
  static func lowercasedFirst(_ s: String) -> String {
    guard let first = s.first else { return s }
    return first.lowercased() + s.dropFirst()
  }
}

/// The failure line of a turn (SPEC 2.4's failure table), in plain words. The model never reads
/// it. The reason an AI app or the system gave goes through `plainReason` first: one plain
/// sentence, or nothing.
public enum TurnFailure {
  /// The longest reason kept.
  public static let maxReason = 160
  /// Marks of developer text: a reason that holds one is left out.
  static let developerMarks: [String] = [
    "{", "}", "[", "]", "<", ">", "/", "\\", "=", "_", "`", "://", "0x", "error domain", "nserror", "code ",
    "exception", "traceback", "stack", "stderr", "stdout", "exit code", "exited", "null", "nil", "undefined", "errno",
  ]

  /// The AI app returned an error, or the turn could not start: "{Name} could not answer.
  /// {Plain reason}." Without a plain reason, the first sentence alone. When `app` refused its
  /// own key (`KeyFailure`), the reason names that app: "OpenCode's key has expired."
  public static func couldNotAnswer(_ name: String, reason raw: String?, app: String? = nil) -> String {
    let who: String = AskPolicy.oneLine(name)
    if let app, let failure = KeyFailure.of(raw) { return "\(who) could not answer. \(failure.reason(app: AskPolicy.oneLine(app)))" }
    guard let reason = plainReason(raw) else { return "\(who) could not answer." }
    return "\(who) could not answer. \(reason)"
  }
  /// Nothing came for `minutes`: "{Name} stopped answering. Nothing came for 1 minute, so I ended
  /// this turn. Ask again."
  public static func stoppedAnswering(_ name: String, minutes: Int) -> String {
    let who: String = AskPolicy.oneLine(name)
    let count: Int = max(minutes, 1)
    let span: String = count == 1 ? "1 minute" : "\(count) minutes"
    return "\(who) stopped answering. Nothing came for \(span), so I ended this turn. Ask again."
  }
  /// The turn ended with no reason: "{Name} stopped without saying why."
  public static func stoppedWithoutWhy(_ name: String) -> String {
    "\(AskPolicy.oneLine(name)) stopped without saying why."
  }

  /// One plain sentence from an error's words, or nil: the first line and its first sentence, at
  /// most `maxReason` characters, with a capital first letter and an end mark. nil when it is
  /// empty, holds developer text (`developerMarks`, a number of three or more digits, a feature
  /// word of `ReceiptCopy.bannedWords`) or anything `AgentPrivacy.redact` would hide.
  public static func plainReason(_ raw: String?) -> String? {
    let text: String = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let line: String = text.components(separatedBy: .newlines).first ?? text
    var sentence: String = line
    if let end = line.range(of: ". ") { sentence = String(line[..<end.lowerBound]) + "." }
    sentence = sentence.trimmingCharacters(in: .whitespaces)
    guard sentence.count >= 3, sentence.count <= maxReason else { return nil }
    let lower: String = sentence.lowercased()
    for mark in developerMarks where lower.contains(mark) { return nil }
    if lower.range(of: "[0-9]{3,}", options: .regularExpression) != nil { return nil }
    let words: Set<String> = Set(lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    guard ReceiptCopy.bannedWords.isDisjoint(with: words) else { return nil }
    guard AgentPrivacy.redact(sentence) == sentence else { return nil }
    if let last = sentence.last, !".!?".contains(last) { sentence += "." }
    guard let first = sentence.first else { return nil }
    return first.uppercased() + sentence.dropFirst()
  }
}
