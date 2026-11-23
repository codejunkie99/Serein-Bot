#if DEBUG
import Foundation
import SereinCore

/// The launch sweep ends only process groups Serein itself started (ProcessGroupRecord).
extension AssistantCoreChecks {
  static func launchSweep(_ check: Check) throws {
    typealias Member = ProcessGroupRecord.Member
    typealias Live = ProcessGroupRecord.Live
    let leader = Member(pid: 4100, started: 1_700_000_000_000_001)
    let child = Member(pid: 4107, started: 1_700_000_000_500_000)
    let group = ProcessGroupRecord.Group(pgid: 4100, members: [leader, child])
    func ours(_ table: [Int32: Live]) -> Bool { ProcessGroupRecord.isOurs(group, live: { table[$0] }) }

    try check(
      ours([4100: Live(started: leader.started, pgid: 4100)])
        && ours([4107: Live(started: child.started, pgid: 4100)]),
      "A recorded group is ended while its leader runs, or while a member it started runs on after the leader exited")
    try check(
      !ours([4100: Live(started: leader.started + 1, pgid: 4100)])
        && !ours([4107: Live(started: 1_800_000_000_000_000, pgid: 4100)]),
      "A pid that a later process reuses, after a reboot or a long gap, is never ended: its start time differs")
    try check(
      !ours([4107: Live(started: child.started, pgid: 4200)]) && !ours([:])
        && !ProcessGroupRecord.isOurs(
          ProcessGroupRecord.Group(pgid: 1, members: [Member(pid: 1, started: 5)]),
          live: { _ in Live(started: 5, pgid: 1) }),
      "A member that left the group, a group with nothing left, and launchd's group are never ended")

    let record = ProcessGroupRecord(owner: Member(pid: 900, started: 42), groups: [group])
    try check(
      record.ownerRuns(live: { $0 == 900 ? Live(started: 42, pgid: 900) : nil })
        && !record.ownerRuns(live: { $0 == 900 ? Live(started: 43, pgid: 900) : nil })
        && !record.ownerRuns(live: { _ in nil }),
      "The groups of a Serein that still runs are left alone; a dead owner's pid reused by another app is not mistaken for it")
    let data = try JSONEncoder().encode(record)
    try check(
      (try? JSONDecoder().decode(ProcessGroupRecord.self, from: data)) == record,
      "The record reads back as written")
  }
}
#endif
