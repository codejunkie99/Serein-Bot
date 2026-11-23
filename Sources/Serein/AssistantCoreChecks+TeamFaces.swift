#if DEBUG
import Foundation
import SereinCore

/// The picture stack of a team chat and its sidebar row (TeamFaces.swift). Synthetic data only.
extension AssistantCoreChecks {
  static func teamFaces(_ check: Check) throws {
    func group(_ members: [String], lead: String? = nil) -> AssistantGroup {
      AssistantGroup(name: "Trip planner", memberIDs: members, leadID: lead)
    }
    let roster: Set<String> = ["a", "b", "c", "d", "e"]

    try check(TeamFaces.stack(group(["a", "b"]), known: roster) == .init(ids: ["a", "b"], more: 0),
      "A small team shows everyone, in the team's order")
    try check(TeamFaces.stack(group(["a", "b", "c"], lead: "c"), known: roster).ids == ["c", "a", "b"],
      "The lead's picture comes first")
    try check(TeamFaces.stack(group(["a", "b", "c", "d", "e"]), known: roster) == .init(ids: ["a", "b", "c"], more: 2),
      "A large team shows three pictures and counts the rest")
    try check(TeamFaces.stack(group(["a", "b", "c", "d"], lead: "d"), known: roster) == .init(ids: ["d", "a", "b"], more: 1),
      "A lead past the limit still shows")
    try check(TeamFaces.stack(group(["a", "gone", "b"]), known: roster) == .init(ids: ["a", "b"], more: 0),
      "A member no longer on the roster is neither drawn nor counted")
    try check(TeamFaces.stack(group(["a", "b"], lead: "gone"), known: roster).ids == ["a", "b"],
      "A lead who left the team changes nothing")
    try check(TeamFaces.stack(group(["a", "a", "b"]), known: roster) == .init(ids: ["a", "b"], more: 0),
      "A member listed twice shows once")
    try check(TeamFaces.stack(group([]), known: roster) == .init(ids: [], more: 0), "An empty team has an empty stack")
    try check(TeamFaces.stack(group(["a", "b", "c"], lead: "c"), known: roster, limit: 2) == .init(ids: ["c", "a"], more: 1),
      "A smaller stack still leads with the lead")
    try check(TeamFaces.ordered(group(["a", "b", "c", "d"], lead: "c"), known: roster) == ["c", "a", "b", "d"],
      "The members list leads with the lead and keeps everyone")
  }
}
#endif
