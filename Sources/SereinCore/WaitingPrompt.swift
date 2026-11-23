import Foundation

/// What an app outside Serein is waiting on, read from its own window (never from a model), so the
/// person can answer it on Serein's card and Serein presses the same answer in that app. Two shapes:
/// a terminal's numbered list (Claude Code's and Codex's CLI prompts) and a window's answer buttons.
/// Its words are untrusted screen text: shown to the person as text, never sent to a model.
public struct WaitingPrompt: Equatable, Sendable {
  public struct Choice: Equatable, Sendable, Identifiable {
    /// The app's own words for this answer.
    public let label: String
    /// Window prompts: the control's ref in the read, pressed through Accessibility.
    public let ref: String?
    /// Terminal prompts: the list position from 0; the marker moves there with arrows, then Return.
    public let index: Int?
    public var id: String { ref ?? "\(index ?? -1):\(label)" }
    public init(label: String, ref: String? = nil, index: Int? = nil) {
      self.label = label; self.ref = ref; self.index = index
    }
  }
  /// `transcript`: read from the session's own transcript; shown only, answered in the app.
  public enum Kind: String, Sendable { case terminal, window, transcript }
  public let kind: Kind
  /// The question as the app words it.
  public let question: String
  /// What it would do, when shown under the question: a command, a file, a diff's first lines.
  public let detail: String?
  public let choices: [Choice]
  /// Terminal prompts: the list position the marker is on now.
  public let selected: Int?
  public init(kind: Kind, question: String, detail: String?, choices: [Choice], selected: Int? = nil) {
    self.kind = kind; self.question = question; self.detail = detail; self.choices = choices; self.selected = selected
  }

  /// The same question with the same answers: what the person saw is what Serein would answer.
  public func sameAsked(_ other: WaitingPrompt) -> Bool {
    kind == other.kind && question == other.question && detail == other.detail
      && choices.map(\.label) == other.choices.map(\.label)
  }

  /// Terminal prompts: the arrow keys that move the marker from where it is to `choice` (Return is
  /// pressed separately, only after the marker is seen there). Nil without a visible marker: where
  /// the arrows would land is then unknown, so Serein does not answer.
  public func moves(to choice: Choice) -> [String]? {
    guard kind == .terminal, let target = choice.index, let from = selected else { return nil }
    let step = target >= from ? "Down" : "Up"
    return Array(repeating: step, count: abs(target - from))
  }
}

public enum WaitingPromptReader {
  /// The most text a card shows of a question or its detail.
  public static let questionLimit = 280
  public static let detailLimit = 400
  /// How far back from the list a terminal question is looked for, in lines.
  static let lookBack = 14

  // MARK: terminal

  /// A numbered list at the end of a terminal's text, with a question above it: "Do you want to
  /// proceed?" then "❯ 1. Yes", "  2. Yes, and don't ask again …", "  3. No, and tell Claude …".
  /// Only the last screenful counts, so an old answered prompt higher up is never read.
  public static func terminal(_ text: String) -> WaitingPrompt? {
    let lines = text.components(separatedBy: .newlines).suffix(60).map(clean)
    // The list: the last run of numbered lines, at most a few blank, border or key-help lines from
    // the end. An option may have a line or two under it (AskUserQuestion's descriptions).
    var options: [(label: String, marked: Bool, number: Int)] = []
    var end = lines.count - 1
    while end >= 0, isFiller(lines[end]) || isHint(lines[end]) { end -= 1 }
    var line = end
    var loose = 0
    while line >= 0 {
      if let option = numbered(lines[line]) {
        options.insert((option.label, option.marked, option.number), at: 0)
        loose = 0
      } else if isFiller(lines[line]) || (loose < 2 && !options.isEmpty && !lines[line].contains("?")) {
        if !isFiller(lines[line]) { loose += 1 }
      } else {
        break
      }
      line -= 1
    }
    // Lines read past the first option belong above the list.
    line += loose
    while line + 1 < lines.count, numbered(lines[line + 1]) == nil { line += 1 }
    guard options.count >= 2, options.count <= 9 else { return nil }
    // Numbers must run 1, 2, 3… in order, or this is ordinary output that happens to be numbered.
    guard options.map(\.number) == Array(1...options.count) else { return nil }
    // The question: the nearest line above that asks something, up to its question mark; the rest
    // of that sentence and the lines down to the list say what it would do.
    let above = Array(lines[max(0, line - lookBack)...max(0, line)].reversed())
    guard let questionAt = above.firstIndex(where: { $0.contains("?") }) else { return nil }
    let asked = above[questionAt]
    let mark = asked.lastIndex(of: "?")!
    let question = String(asked[...mark])
    var context = Array(above[..<questionAt].reversed().filter { !isFiller($0) })
    // The rest of the asking sentence runs on into the next line: one line again.
    let after = asked[asked.index(after: mark)...].trimmingCharacters(in: .whitespaces)
    if !after.isEmpty {
      if context.isEmpty { context = [after] } else { context[0] = after + " " + context[0] }
    }
    if context.isEmpty {
      // Claude Code's permission box puts the command above the question, up to its top edge.
      var upward: [String] = []
      var at = (line - questionAt) - 1
      // A box's top edge or a rule across the screen ends the prompt; older output lies above it.
      while at >= 0, upward.count < 4, !lines[at].hasPrefix("╭"), !lines[at].hasPrefix("┌"), !isRule(lines[at]) {
        if !isFiller(lines[at]), !isTabHeader(lines[at]) { upward.insert(lines[at], at: 0) }
        at -= 1
      }
      context = upward
    }
    let detail = context.isEmpty ? nil : String(context.joined(separator: "\n").prefix(detailLimit))
    // "Type something." and "Chat about this" open a text box in the app rather than answering:
    // they stay in the count (the arrows pass them) but are not offered on the card.
    let choices = options.enumerated().compactMap { position, option -> WaitingPrompt.Choice? in
      opensText(option.label) ? nil : WaitingPrompt.Choice(label: option.label, index: position)
    }
    guard !choices.isEmpty else { return nil }
    let selected = options.firstIndex(where: \.marked)
    return WaitingPrompt(
      kind: .terminal, question: String(question.prefix(questionLimit)), detail: detail, choices: choices, selected: selected)
  }

  static func opensText(_ label: String) -> Bool {
    let lower = label.lowercased()
    return lower.hasPrefix("type something") || lower.hasPrefix("chat about this") || lower.hasPrefix("other")
  }

  /// "❯ 1. Yes", "  2. No (esc)", "› 1. Yes, proceed (y)": the number, its words, and whether the
  /// marker is on it. Shortcut hints in brackets stay: they are the app's words.
  static func numbered(_ raw: String) -> (number: Int, label: String, marked: Bool)? {
    var line = Substring(raw.trimmingCharacters(in: .whitespaces))
    var marked = false
    if let first = line.first, markers.contains(first) {
      marked = true
      line = line.dropFirst().drop(while: { $0 == " " })
    }
    guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
      let number = Int(line[..<dot]), number >= 1, number <= 9 else { return nil }
    let label = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty, label.count <= 160 else { return nil }
    return (number, label, marked)
  }
  static let markers: Set<Character> = ["❯", "›", ">", "▸", "→", "●"]

  /// Box borders, rules and empty lines a TUI draws around a prompt.
  static func isFiller(_ line: String) -> Bool {
    line.isEmpty || line.allSatisfy { "─━═│┃║╭╮╰╯┌┐└┘├┤-_=|+ ".contains($0) }
  }
  /// A rule drawn across the screen ("────…").
  static func isRule(_ line: String) -> Bool {
    line.count >= 12 && line.allSatisfy { "─━═-".contains($0) }
  }
  /// AskUserQuestion's tab header above the question ("☐ File", "☒ Done").
  static func isTabHeader(_ line: String) -> Bool {
    line.hasPrefix("☐") || line.hasPrefix("☒") || line.hasPrefix("✔")
  }
  /// The key help a TUI prints under its list ("Esc to cancel · Tab to add notes").
  static func isHint(_ line: String) -> Bool {
    let lower = line.lowercased()
    return (lower.contains("esc") || lower.contains("enter") || lower.contains("tab to")) && numbered(line) == nil
      && !line.hasSuffix("?")
  }
  /// A terminal line without its box edges and padding.
  static func clean(_ line: String) -> String {
    line.trimmingCharacters(in: CharacterSet(charactersIn: "│┃║|").union(.whitespaces))
  }

  // MARK: window

  /// One control in a window's read: its role, words and ref, in reading order.
  public struct Control: Equatable, Sendable {
    public let role: String
    public let label: String
    public let ref: String?
    public init(role: String, label: String, ref: String?) { self.role = role; self.label = label; self.ref = ref }
  }

  /// A question followed by answer buttons (Allow / Deny, Yes / No, Approve / Reject…): at least
  /// two answer buttons near each other, and a line that asks something before them.
  public static func window(_ controls: [Control]) -> WaitingPrompt? {
    let buttons = controls.enumerated().filter { $0.element.role == "AXButton" && isAnswer($0.element.label) }
    guard buttons.count >= 2, buttons.count <= 6 else { return nil }
    // The answers belong together: no more than a few controls apart.
    let first = buttons[0].offset, last = buttons[buttons.count - 1].offset
    guard last - first <= buttons.count * 3 else { return nil }
    // At least one way to say yes and one to say no, or this is a toolbar.
    let words = buttons.map { $0.element.label.lowercased() }
    guard words.contains(where: isYes), words.contains(where: isNo) else { return nil }
    let before = controls[max(0, first - 12)..<first].reversed()
    guard let asking = before.first(where: { isText($0.role) && $0.label.hasSuffix("?") }) else { return nil }
    // The text between the question and its buttons, else the few lines of text just above it.
    var detailLines = Array(before.prefix(while: { $0 != asking }).filter { isText($0.role) && !$0.label.isEmpty }.reversed())
    if detailLines.isEmpty {
      detailLines = Array(before.drop(while: { $0 != asking }).dropFirst()
        .prefix(while: { isText($0.role) }).prefix(3).filter { !$0.label.isEmpty }.reversed())
    }
    let detail = detailLines.isEmpty ? nil : String(detailLines.map(\.label).joined(separator: "\n").prefix(detailLimit))
    return WaitingPrompt(
      kind: .window, question: String(asking.label.prefix(questionLimit)), detail: detail,
      choices: buttons.map { WaitingPrompt.Choice(label: $0.element.label, ref: $0.element.ref) })
  }

  static func isText(_ role: String) -> Bool { ["AXStaticText", "AXHeading", "AXTextArea"].contains(role) }
  static let yesWords = ["allow", "always", "approve", "yes", "accept", "run", "continue", "proceed", "confirm"]
  static let noWords = ["deny", "reject", "no", "decline", "don't allow", "cancel", "skip", "stop"]
  /// A whole first word (or phrase): "No" and "No, thanks" count, "Notify" and "Running" do not.
  static func starts(_ label: String, with word: String) -> Bool {
    guard label.hasPrefix(word) else { return false }
    let rest = label.dropFirst(word.count)
    return rest.isEmpty || rest.first.map { !$0.isLetter && !$0.isNumber } == true
  }
  static func isYes(_ label: String) -> Bool { yesWords.contains { starts(label, with: $0) } }
  static func isNo(_ label: String) -> Bool { noWords.contains { starts(label, with: $0) } }
  static func isAnswer(_ label: String) -> Bool {
    let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
    return !lower.isEmpty && lower.count <= 40 && (isYes(lower) || isNo(lower))
  }
}
