import Foundation

/// One rule for changes an assistant makes to Serein itself (reminders, routines, memory,
/// assistants, links): the person's own typed words approve the change they name; an assistant
/// can only propose; deleting and widening always ask. Sending, buying, deleting data and page
/// actions are not here: `ApprovalGate` keeps deciding those, unchanged.
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
    case makeAssistant
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

  static let noOneHere = "Nobody is here to approve that. Ask the person in their chat."
  static let onlyThePerson = "Only the person can do that. Propose it to them instead."
  static let tooDeep = "An assistant that was asked cannot ask another one."

  /// The verdict for one change. `wordsNameIt`: the person's message names this change
  /// (`TypedConsent.names`). Where it matters and is false, the person gets a card.
  public static func decide(_ change: Change, turn: Turn, wordsNameIt: Bool) -> Verdict {
    switch (change, turn) {
    case (.schedule(signIns: true), .person): return .ask
    case (.schedule, .person), (.memory, .person), (.ownChange, .person), (.undo, .person): return .apply
    case (.shareMemory, .person), (.makeLink, .person): return wordsNameIt ? .apply : .ask
    case (.makeAssistant, .person): return wordsNameIt && TypedConsent.makeAssistant ? .apply : .ask
    case (.makeAssistant, .assistant): return .ask
    case (.widen, .person): return .ask
    case (.board, .person): return wordsNameIt ? .apply : .ask
    case (.deleteAssistant, .person), (.deleteAssistant, .assistant): return .ask
    case (.ask, .person), (.ask, .unattended): return .apply
    case (.ask, .assistant): return .refuse(tooDeep)
    case (_, .unattended): return .refuse(noOneHere)
    case (_, .assistant): return .refuse(onlyThePerson)
    }
  }
}

/// Whether the person's own message names a change. It reads only verbs it knows: a message it
/// cannot read gives a card, so a miss costs one tap and never a wrong apply.
public enum TypedConsent {
  /// Whether a typed "make an assistant" counts as the approval (owner's decision, 2026-10-29).
  public static let makeAssistant = true

  public static func names(_ change: Admission.Change, in message: String) -> Bool {
    let words = normalized(message)
    switch change {
    case .makeAssistant:
      return contains(words, any: ["make", "create", "add", "new", "set up", "build"])
        && contains(words, any: ["assistant", "bot", "helper", "agent"])
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
