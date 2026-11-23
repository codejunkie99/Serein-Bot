import Foundation

/// One question Relay puts to the user, shown as a small form in the panel until it is answered or
/// `RelayAsk.timeout` passes: with `choices` the user picks one, without they type. Everything here
/// is pure, so it is checked in SereinChecks.
public struct RelayQuestion: Codable, Equatable, Sendable {
  public var id: String
  public var label: String
  public var choices: [String]
  /// The columns Relay proposes before a long collection into a table. When set, the user
  /// renames, adds or drops columns and presses Collect; the answer is `RelayAsk.columnsAnswer`.
  public var columns: [String]?
  public init(id: String, label: String, choices: [String] = [], columns: [String]? = nil) {
    self.id = id
    self.label = label
    self.choices = choices
    self.columns = columns
  }
}

public enum RelayAsk {
  public static let maxQuestions = 4
  static let idBudget = 40
  static let labelBudget = 160
  static let choiceBudget = 60
  public static let maxColumns = 12
  static let columnBudget = 40
  /// How long the panel waits before telling Relay nobody answered: a secure card's life, so a
  /// card in a call the CLI lets wait that long never closes first. A call that stops sooner
  /// cuts it (`CallWindow`).
  public static let timeout: TimeInterval = SecureCard.life
  /// What the run hears when nobody watches it: it asks nobody and waits for nothing, and its
  /// question reaches the person through the reply mark (`RelayUnattended.interpret`, the Board's
  /// Waiting on you), not a form nobody would see.
  public static let unattendedNote =
    "Nobody is watching this run, so nothing was asked and no answer will come. Finish what you can without it, then end your reply with \(RelayUnattended.inputMark) followed by your question."
  /// The tool's result without a form in a run nobody watches; nil when someone may answer.
  public static func unattended(_ unattended: Bool) -> [String: Any]? {
    unattended ? ["asked": false, "note": unattendedNote] : nil
  }

  /// Reads the tool call: a title and one to four well-formed questions. The user reads the
  /// labels. Serein mints each id; an id on the tool call is ignored.
  public static func parse(
    _ a: [String: Any], mint: () -> String = { UUID().uuidString }
  ) throws -> (title: String, questions: [RelayQuestion]) {
    guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty, title.count <= labelBudget
    else { throw SereinError.invalid("title is required (under \(labelBudget) characters)") }
    guard let raw = a["questions"] as? [[String: Any]], !raw.isEmpty else {
      throw SereinError.invalid("questions is required")
    }
    guard raw.count <= maxQuestions else {
      throw SereinError.invalid("Ask at most \(maxQuestions) questions at once.")
    }
    var questions: [RelayQuestion] = []
    var seen = Set<String>()
    for item in raw {
      // Using the model's id here keeps the id the model chose.
      let id = mint().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, id.count <= idBudget, seen.insert(id).inserted
      else { throw SereinError.invalid("Every question needs a short, unique id.") }
      _ = item["id"]
      guard let label = (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !label.isEmpty, label.count <= labelBudget
      else { throw SereinError.invalid("Every question needs a label the user reads.") }
      let choices = ((item["choices"] as? [String]) ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        .prefix(8).map { String($0.prefix(choiceBudget)) }
      let columns = (item["columns"] as? [String]).map(Self.columns)
      if let columns, columns.isEmpty { throw SereinError.invalid("columns needs at least one column name.") }
      questions.append(RelayQuestion(id: id, label: String(label.prefix(labelBudget)),
        choices: columns == nil ? choices : [], columns: columns))
    }
    return (title, questions)
  }

  /// Column names as a table header can hold them: no pipe or line break, trimmed, short, at most
  /// `maxColumns`, empty ones dropped.
  public static func columns(_ raw: [String]) -> [String] {
    raw.map {
      String($0.components(separatedBy: CharacterSet(charactersIn: "|").union(.newlines)).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces).prefix(columnBudget))
    }.filter { !$0.isEmpty }.prefix(maxColumns).map { $0 }
  }

  /// The columns the user kept, as one answer: their names joined by “ | ”, ready to be a header.
  public static func columnsAnswer(_ columns: [String]) -> String {
    Self.columns(columns).joined(separator: " | ")
  }

  /// How a form shows in the chat. One question: quick replies (up to five short choices, as
  /// pills), a list (longer choices or a detail, as rows), a typed answer, or the columns editor.
  /// Several questions: one step at a time.
  public enum Style: Equatable, Sendable { case quickReplies, list, typed, columns, steps }
  /// The longest choice that still reads as a pill, and the most pills.
  static let pillLength = 28
  static let maxPills = 5
  public static func style(_ questions: [RelayQuestion]) -> Style {
    guard questions.count == 1, let only = questions.first else { return .steps }
    return style(of: only)
  }
  /// The answer control one question gets, in a form or in one step of it.
  public static func style(of question: RelayQuestion) -> Style {
    if question.columns != nil { return .columns }
    if question.choices.isEmpty { return .typed }
    let short = question.choices.allSatisfy { $0.count <= pillLength && split($0).detail == nil }
    return short && question.choices.count <= maxPills ? .quickReplies : .list
  }
  /// A choice's words and its detail, written after “ — ” (“TAP 8:05 — direct, $380”).
  public static func split(_ choice: String) -> (title: String, detail: String?) {
    guard let range = choice.range(of: " — ") else { return (choice, nil) }
    let title = choice[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    let detail = choice[range.upperBound...].trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty, !detail.isEmpty else { return (choice, nil) }
    return (title, detail)
  }
  /// One question a person can answer by typing in the composer: alone in its form, and not
  /// a columns question.
  public static func composerAnswers(_ questions: [RelayQuestion]) -> Bool {
    questions.count == 1 && questions.first?.columns == nil
  }
  /// What the person's reply bubble says once they answered: the answer alone for one question,
  /// else each answered question's label and answer on its own line; “Skipped” with none.
  public static func summary(_ questions: [RelayQuestion], _ answers: [String: String]) -> String {
    func answer(_ question: RelayQuestion) -> String? {
      guard let text = answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
      return question.columns == nil ? split(text).title : text
    }
    if questions.count == 1, let only = questions.first { return answer(only) ?? "Skipped" }
    let lines = questions.compactMap { question in answer(question).map { "\(question.label): \($0)" } }
    return lines.isEmpty ? "Skipped" : lines.joined(separator: "\n")
  }

  /// The answers back to Relay, keyed by question id; empty answers are omitted.
  public static func result(_ answers: [String: String]) -> [String: Any] {
    [
      "answers": answers.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
    ]
  }
}

/// The life of an unanswered approval: the user is reminded once while it waits, and an approval
/// nobody answers for a day closes itself as declined — a step Relay asked for exactly this once
/// never waits forever. Pure, so it is checked in SereinChecks.
public enum RelayApproval {
  /// Remind the user after this long unanswered.
  public static let remindAfter: TimeInterval = 4 * 3600
  /// Decline automatically after this long unanswered.
  public static let declineAfter: TimeInterval = 24 * 3600

  public enum Duty { case none, remind, decline }

  public static func duty(askedAt: Date, remindedAt: Date?, now: Date) -> Duty {
    let waited = now.timeIntervalSince(askedAt)
    if waited >= declineAfter { return .decline }
    if waited >= remindAfter, remindedAt.map { now.timeIntervalSince($0) >= remindAfter } ?? true {
      return .remind
    }
    return .none
  }
}
