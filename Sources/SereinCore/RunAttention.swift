import Foundation

/// The explanation behind an attention state, shared by live tasks and saved run records.
/// Host failures remain separate from the assistant's transcript.
public enum RunAttention {
  public static func detail(
    outcome: RunRecord.Outcome, error: String? = nil, question: String? = nil,
    reported: String? = nil, saved: String? = nil, summary: String? = nil, response: String? = nil
  ) -> String? {
    guard outcome == .stuck || outcome == .waiting else { return nil }
    let candidates = [outcome == .stuck ? error : nil, question, reported, saved, summary, response]
    for candidate in candidates {
      guard let candidate else { continue }
      let text = AgentPrivacy.redact(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { return text }
    }
    return outcome == .stuck
      ? "The task failed without an error message. Try again to request a new run."
      : "This task needs your input, but no question was recorded. Reply below to ask what is needed."
  }
}
