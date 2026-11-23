import Foundation

/// The person's message to a Claude Code helper (a sub-thread). Claude Code cannot resume a helper
/// on its own, but the session that started it can reach it with SendMessage, so the words go to
/// that session with what to do: the person's own words, quoted whole, and nothing else.
public enum SubagentFollowUp {
  public static func message(_ words: String, to title: String, id: String) -> String {
    let agent = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
    let name = title.replacingOccurrences(of: "\n", with: " ").prefix(80)
    return "Pass this on to your subagent “\(name)” (agent id \(agent)) with SendMessage, then tell me what it answers:\n\n"
      + words.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
