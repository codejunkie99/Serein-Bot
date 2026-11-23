import Foundation

/// How many tool calls one turn may make before Serein stops it, the way Stop does, keeping what
/// came back. A runaway loop would otherwise run until a time limit, or forever in a project
/// with edits. The count is the turn's own (`RunRecord.toolCount`), so Resume, a new turn,
/// starts with the whole budget again.
public enum StepBudget {
  public enum Kind: String, CaseIterable, Sendable {
    /// A turn the person started: their message, a task they opened.
    case person
    /// A turn nobody watches: a routine, a watch, a goal check, a reminder, a webhook.
    case unattended
    /// A run another assistant started for Serein (`agent_start`), or a hand-off.
    case helper
  }

  /// The one table of limits.
  public static let limits: [Kind: Int] = [.person: 200, .unattended: 60, .helper: 60]

  public static func limit(_ kind: Kind) -> Int { limits[kind] ?? 60 }

  /// Which budget a run gets. `unattended`: nobody is there to answer for its task right now
  /// (`BrowserModel.isUnattended(task:)`), which covers Serein's own scheduled turns.
  public static func kind(initiator: AgentHistoryRun.Initiator?, relay: Bool, unattended: Bool) -> Kind {
    if unattended || initiator?.isUnattended == true { return .unattended }
    // Serein's own chat turn; any other run with no initiator was started by the person.
    if relay || initiator == nil { return .person }
    switch initiator {
    case .delegated, .handoff: return .helper
    // Another assistant speaking first in its own chat: nobody asked for it.
    default: return .unattended
    }
  }

  /// Whether the call just counted goes past the budget. A card waiting on the person holds the
  /// count, so a step is never cut in the middle of an ask; the next call after the answer stops it.
  public static func over(steps: Int, kind: Kind, asking: Bool) -> Bool {
    !asking && steps > limit(kind)
  }

  /// The one line the turn ends with.
  public static func line(_ limit: Int) -> String { "Stopped after \(limit) steps." }
}
