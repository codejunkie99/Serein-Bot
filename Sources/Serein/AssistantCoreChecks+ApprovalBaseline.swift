#if DEBUG
import Foundation
import SereinCore

/// The labelled steps (`ApprovalCases`) through the door: which paying and password steps run
/// with nobody asked, and which payments no pay floor meets. Each list is exact, so a change
/// in either direction shows. The door's own table is `approvalDoor`.
/// How to rerun and read a failure: .claude/skills/proactive-safety/SKILL.md.
extension AssistantCoreChecks {
  static func approvalBaseline(_ check: Check) throws {
    let ids = Set(ApprovalCases.all.map(\.id))
    try check(
      ids.count == ApprovalCases.all.count
        && ApprovalCases.knownRunning.union(ApprovalCases.knownPayNotSeen).isSubset(of: ids),
      "Every labelled step has its own name, and every finding names a labelled step")
    let standings: [(String, ApprovalDoor.Standing)] = [
      ("Only risky steps", .person(.riskyOnly)), ("Allow all", .proactiveTask(present: true)),
      ("Allow all with nobody there", .proactiveTask(present: false)),
    ]
    for (name, standing) in standings {
      let running = ApprovalCases.running(at: standing)
      try check(
        running == ApprovalCases.knownRunning,
        "At \(name) a paying or password step runs by itself only where the findings list says so"
          + DoorTable.drift(now: running, listed: ApprovalCases.knownRunning))
    }
    try check(
      ApprovalCases.running(at: .person(.everyStep)).isEmpty,
      "At Every step no paying or password step runs by itself")
    let unseen = ApprovalCases.payNotSeen()
    try check(
      unseen == ApprovalCases.knownPayNotSeen,
      "A payment the door does not see as one is on the findings list"
        + DoorTable.drift(now: unseen, listed: ApprovalCases.knownPayNotSeen))
  }
}
#endif
