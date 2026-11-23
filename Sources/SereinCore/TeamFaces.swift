import Foundation

/// Which members' pictures a team shows in its stack: the lead first, then the rest in the team's
/// order, up to `limit`, with a count of the others. Pure, so AssistantCoreChecks checks it.
public enum TeamFaces {
  public static let limit = 3

  public struct Stack: Equatable, Sendable {
    public var ids: [String]
    public var more: Int
    public init(ids: [String], more: Int) {
      self.ids = ids
      self.more = more
    }
  }

  /// `known` is the roster: a member no longer on it is neither drawn nor counted.
  public static func stack(_ group: AssistantGroup, known: Set<String>, limit: Int = limit) -> Stack {
    let members = ordered(group, known: known)
    return Stack(ids: Array(members.prefix(limit)), more: max(0, members.count - limit))
  }

  /// Every member still on the roster, the lead first.
  public static func ordered(_ group: AssistantGroup, known: Set<String>) -> [String] {
    var seen = Set<String>()
    let members = group.memberIDs.filter { known.contains($0) && seen.insert($0).inserted }
    guard let lead = group.leadID, members.contains(lead) else { return members }
    return [lead] + members.filter { $0 != lead }
  }
}
