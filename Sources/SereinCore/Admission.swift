import Foundation

/// One rule for changes an assistant makes to Serein itself (reminders, routines, memory, links):
/// in the person's own turn their typed words approve the change they name, and deleting and
/// widening show a card below Allow all. A turn the person did not start (another assistant's,
/// a schedule's, a link's) applies every change with its receipt and Undo, since nobody is there
/// to press a card (owner, 2026-11-26: "No permissions required"). Making assistants and teams
/// is `Staffing`'s, which never asks. Sending, buying, deleting data and page actions are not
/// here: `ApprovalGate` keeps deciding those, unchanged.
public enum Admission {
  /// Who started the turn that asks for the change.
  public enum Turn: Equatable, Sendable {
    /// The person typed (or pasted) a message, and this turn answers it.
    case person
    /// Another assistant asked (a light ask or a hand-off): no person is reading this turn.
    case assistant
    /// A schedule, a watch or a link delivery: nobody is there.
    case unattended
  }
  public enum Change: Equatable, Sendable {
    /// A reminder or a routine. `signIns`: it would use the person's kept sign-ins when it runs.
    case schedule(signIns: Bool)
    /// A note kept or forgotten for this assistant only.
    case memory
    /// Pausing, renaming, narrowing what it may use, or rewriting its own job.
    case ownChange
    /// Moving a note so more assistants can read it.
    case shareMemory
    /// A link another app calls to wake an assistant.
    case makeLink
    /// Letting an assistant use more places or apps.
    case widen
    case deleteAssistant
    /// A read-only question to other assistants.
    case ask
    case undo
    /// Moving one of the person's own Board cards to another column (`board_update`).
    case board
  }
  public enum Verdict: Equatable, Sendable {
    /// Do it now, then show the receipt with Undo.
    case apply
    /// Show a card; nothing happens until the person presses its button.
    case ask
    /// Say no, with a reason the turn can repeat.
    case refuse(String)
  }

  /// The verdict for one change. `wordsNameIt`: the person's message names this change
  /// (`TypedConsent.names`). Where it matters and is false, the person gets a card.
  public static func decide(_ change: Change, turn: Turn, wordsNameIt: Bool) -> Verdict {
    guard turn == .person else { return .apply }
    switch change {
    case .schedule(signIns: true), .widen, .deleteAssistant: return .ask
    case .schedule, .memory, .ownChange, .undo, .ask: return .apply
    case .shareMemory, .makeLink, .board: return wordsNameIt ? .apply : .ask
    }
  }
}

/// Whether the person's own message names a change. It reads only verbs it knows: a message it
/// cannot read gives a card, so a miss costs one tap and never a wrong apply.
public enum TypedConsent {
  public static func names(_ change: Admission.Change, in message: String) -> Bool {
    let words = normalized(message)
    switch change {
    case .shareMemory:
      return contains(words, any: ["share", "tell everyone", "let everyone", "all assistants", "every assistant", "the team"])
    case .makeLink:
      return contains(words, any: ["link", "address", "url", "when", "whenever"])
        && contains(words, any: ["calls", "call", "opens", "sends", "posts", "tells", "notify", "wake"])
    case .deleteAssistant:
      return contains(words, any: ["delete", "remove", "get rid of"])
    case .widen:
      return contains(words, any: ["let", "allow", "give", "can use"])
    case .board:
      return contains(words, any: ["move", "mark", "done", "finish", "finished", "complete", "completed", "tick off", "check off", "cross off"])
    case .schedule, .memory, .ownChange, .ask, .undo:
      return true
    }
  }
  /// Lowercased words joined by single spaces, so phrases match on word boundaries.
  static func normalized(_ s: String) -> String {
    " " + s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
  }
  static func contains(_ words: String, any phrases: [String]) -> Bool {
    phrases.contains { words.contains(" " + $0 + " ") }
  }
}
