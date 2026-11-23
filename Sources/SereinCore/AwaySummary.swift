import Foundation

/// The card at the Unread line when the person comes back after Serein worked: how long they were
/// away, then what needs them, what could not finish and what finished, in that order. Built from
/// the Tasks tab's list (`SereinSessionList`), so each line opens the same item the tab does.
/// Pure, so AssistantCoreChecks checks it.
public enum AwaySummary {
  public enum Kind: Int, CaseIterable, Sendable {
    case needsYou, failed, done
    /// Each state is named in words, never by colour alone.
    public var title: String {
      switch self {
      case .needsYou: return "Needs you"
      case .failed: return "Didn't finish"
      case .done: return "Done"
      }
    }
  }

  public struct Group: Equatable, Sendable {
    public let kind: Kind
    public let entries: [SereinSessionList.Entry]
  }

  /// What waits on the person counts however long it has waited; a failure or a finish counts only
  /// if it ended while they were away (at or after `since`). Nil `since` counts them all. Empty
  /// groups are left out, so nothing to say is no card. The list keeps a finish for an hour
  /// (`SereinSessionList.finishedLinger`), so a longer absence shows only the last hour's.
  public static func groups(_ entries: [SereinSessionList.Entry], since: Date?) -> [Group] {
    Kind.allCases.compactMap { kind in
      let rows: [SereinSessionList.Entry] = entries.filter { entry in
        guard Self.kind(of: entry) == kind else { return false }
        guard kind != .needsYou, let since else { return true }
        return entry.when >= since
      }
      return rows.isEmpty ? nil : Group(kind: kind, entries: rows)
    }
  }

  static func kind(of entry: SereinSessionList.Entry) -> Kind? {
    switch entry.state {
    case .needsYou: return entry.failed ? .failed : .needsYou
    case .finished: return .done
    case .working: return nil
    }
  }

  /// How long the person was away: "25 min", "2 h 14 min", "3 days". Nil under a minute.
  public static func awayWords(from since: Date, to back: Date) -> String? {
    let minutes = Int(back.timeIntervalSince(since) / 60)
    guard minutes >= 1 else { return nil }
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60, rest = minutes % 60
    if hours < 24 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min" }
    let days = hours / 24
    return days == 1 ? "1 day" : "\(days) days"
  }
}
