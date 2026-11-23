import Foundation

/// One card on the person's To do board (History › To do). Its title and notes may come from a
/// page or mail an assistant read (`todo_propose`): they are words to show, never instructions.
/// Only the person's Start sends them anywhere, on the Start a task card.
public struct TodoCard: Codable, Equatable, Identifiable, Sendable {
  public enum Column: String, Codable, CaseIterable, Identifiable, Sendable {
    case next, doing, waiting, done
    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .next: return "Next"
      case .doing: return "Doing"
      case .waiting: return "Waiting"
      case .done: return "Done"
      }
    }
  }
  public var id: String
  public var title: String
  public var notes: String?
  /// Only reminds the person (a plain reminder, `TodoBoard.reminder`); it never starts anything.
  public var deadline: Date?
  /// The assistant it is for (`RelayProfile.id`); nil is nobody in particular. Assigning one
  /// starts nothing.
  public var assistantID: String?
  public var column: Column
  /// The task its last Start began (a thread id), for the link to it.
  public var taskID: String?
  /// Proposed in a chat that had read the person's mail, messages or Mac apps: a task started
  /// from it carries the same personal-read mark.
  public var personal: Bool?
  public var goal: PersonalGoal? = nil
  public var createdAt: Date
  public init(
    id: String = UUID().uuidString, title: String, notes: String? = nil, deadline: Date? = nil,
    assistantID: String? = nil, column: Column = .next, taskID: String? = nil, personal: Bool? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.deadline = deadline
    self.assistantID = assistantID
    self.column = column
    self.taskID = taskID
    self.personal = personal
    self.createdAt = createdAt
  }
}

/// The board's rules, pure so SereinChecks can reach them. The cards are kept whole in the
/// Library's `todo.json` (0600), which no harness can read.
public enum TodoBoard {
  public static let path = "todo.json"
  public static let titleLimit = 200
  public static let notesLimit = 2_000
  public static let maxCards = 500
  /// The most reminders Serein keeps (reminder_create's limit): a deadline past it does not remind.
  public static let reminderLimit = 200
  public static let full = "To do holds \(maxCards) cards. Delete some done ones first."

  /// A title as kept: one line, without control, format or direction characters
  /// (`SafeFileName.hidden`), runs of space as one, at most `titleLimit` characters.
  public static func cleanTitle(_ text: String) -> String {
    var kept = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        kept.append(" ")
      } else if !SafeFileName.hidden(scalar) {
        kept.append(scalar)
      }
    }
    let words: [Substring] = String(kept).split(separator: " ")
    let line: String = words.joined(separator: " ")
    return String(line.prefix(titleLimit))
  }
  /// Notes as kept: their lines, without other hidden characters, trimmed, at most `notesLimit`
  /// characters; nil when nothing is left.
  public static func cleanNotes(_ text: String?) -> String? {
    guard let text else { return nil }
    var kept = String.UnicodeScalarView()
    for scalar in text.unicodeScalars where scalar == "\n" || !SafeFileName.hidden(scalar) { kept.append(scalar) }
    let clean = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : String(clean.prefix(notesLimit))
  }

  /// The exact words Start sends: the title, then the notes.
  public static func prompt(_ card: TodoCard) -> String {
    [card.title, card.notes].compactMap { $0 }.joined(separator: "\n\n")
  }

  /// The id of the reminder a card's deadline makes.
  public static func reminderID(_ cardID: String) -> String { "todo-" + cardID }
  /// A reminder that belongs to a To do card: only the board changes it, and no assistant lists it.
  public static func isReminder(_ id: String) -> Bool { id.hasPrefix("todo-") }
  /// The plain reminder for a card's deadline (a note shown to the person, never a request):
  /// nil without a deadline, once the card is done, or when the deadline has passed.
  public static func reminder(for card: TodoCard, now: Date) -> RelayReminder? {
    guard let deadline = card.deadline, card.column != .done, deadline > now else { return nil }
    return RelayReminder(id: reminderID(card.id), text: "To do: " + card.title, due: deadline, action: false)
  }

  /// Start's yes: the card moves to Doing, linked to the task it began.
  public static func started(_ cards: [TodoCard], card id: String, task: String) -> [TodoCard] {
    cards.map { card in
      guard card.id == id else { return card }
      var moved = card
      moved.column = .doing
      moved.taskID = task
      return moved
    }
  }
  /// A task ended (finished, failed, stopped or waiting for the person): its card leaves Doing
  /// for Waiting, where the person marks it done. A card moved by hand to Next or Doing has no
  /// task any more (`TodoBook.move`), so it stays where it is.
  public static func taskEnded(_ cards: [TodoCard], task: String) -> [TodoCard] {
    cards.map { card in
      guard card.column == .doing, card.taskID == task else { return card }
      var moved = card
      moved.column = .waiting
      return moved
    }
  }
  /// At launch no task is running, so every card still in Doing with a task waits for the person.
  public static func relaunched(_ cards: [TodoCard]) -> [TodoCard] {
    cards.map { card in
      guard card.column == .doing, card.taskID != nil else { return card }
      var moved = card
      moved.column = .waiting
      return moved
    }
  }

  /// The Add / Decline card for an assistant's proposal. The title is quoted as the page or mail
  /// wrote it; the notes go behind “Show the notes”.
  public static func proposal(_ card: TodoCard, assistant: String?) -> (title: String, detail: String) {
    var lines = ["It goes in Next. Adding it starts nothing: you start it yourself, and Start asks you first."]
    if let deadline = card.deadline {
      lines.append("Deadline: \(deadline.formatted(date: .abbreviated, time: .shortened)). Serein only reminds you then.")
    }
    if let assistant { lines.append("For \(assistant). Assigning it starts nothing.") }
    lines.append("Its words may come from a page or mail; they are kept as text.")
    return ("Add to To do: “\(card.title)”?", lines.joined(separator: "\n"))
  }
}
