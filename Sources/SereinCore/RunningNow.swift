import Foundation

/// What is at work, in names, in the pill at the top of the chat: the person sees it without
/// opening the panel. Names, never a number on a badge (the owner's rule).
/// Pure, so AssistantCoreChecks checks it.
public enum RunningNow {
  /// "Reply to Maya needs you", or with nothing waiting "Inbox triage and Flight check running":
  /// the pill says one thing, and what needs the person comes before what runs. Nil with nothing
  /// waiting or at work: what finished is the away card's.
  public static func lead(_ entries: [SereinSessionList.Entry]) -> String? {
    let needs: [String] = entries.filter { $0.state == .needsYou }.map(\.title)
    if !needs.isEmpty { return names(needs) + (needs.count == 1 ? " needs you" : " need you") }
    let working: [String] = entries.filter { $0.state == .working }.map(\.title)
    return working.isEmpty ? nil : names(working) + " running"
  }

  /// The hover peek: every name, under its state, one state a line.
  public static func peek(_ entries: [SereinSessionList.Entry]) -> String? {
    let needs: [String] = entries.filter { $0.state == .needsYou }.map(\.title)
    let working: [String] = entries.filter { $0.state == .working }.map(\.title)
    var lines: [String] = []
    if !needs.isEmpty { lines.append("Needs you: " + needs.joined(separator: ", ")) }
    if !working.isEmpty { lines.append("Running: " + working.joined(separator: ", ")) }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  /// "A", "A and B", "A, B and 3 more": the pill stays short; the peek has the rest.
  static func names(_ titles: [String]) -> String {
    switch titles.count {
    case 0: return ""
    case 1: return titles[0]
    case 2: return titles[0] + " and " + titles[1]
    default: return titles[0] + ", " + titles[1] + " and \(titles.count - 2) more"
    }
  }
}
