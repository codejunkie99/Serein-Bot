#if DEBUG
import Foundation
import SereinCore

/// History pasted into a launch argument or a first prompt has one cap on every path (RunContext).
extension AssistantCoreChecks {
  static func pastedHistory(_ check: Check) throws {
    let turns = (0..<200).map { (role: $0.isMultiple(of: 2) ? "you" : "assistant", text: "Turn \($0) " + String(repeating: "z", count: 990)) }
    let pasted = RunContext.previousConversation(turns)
    try check(
      RunContext.ongoingBudget == 60_000 && pasted.contains("Turn 199 ") && !pasted.contains("Turn 0 ")
        && pasted.count < RunContext.ongoingBudget + 2_000,
      "A long chat pastes about 60,000 characters of history on every path, newest kept and oldest dropped first")
    try check(
      pasted.hasPrefix("This is an ongoing conversation; only its most recent part follows."),
      "Capped history starts with a line saying earlier messages were left out")
    let few = RunContext.previousConversation(Array(turns.suffix(3)))
    try check(
      few.hasPrefix("<untrusted_previous_conversation>") && few.contains("Turn 197 ") && few.contains("Turn 199 "),
      "A short chat's history goes in whole, with no note")
    try check(RunContext.previousConversation([]).isEmpty, "A chat with no earlier turns pastes nothing")
  }
}
#endif
