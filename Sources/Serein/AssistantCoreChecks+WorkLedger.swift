#if DEBUG
import Foundation
import SQLite3
import SereinCore

/// Unit 7: the work ledger. Every check runs on a new file in a temporary folder.
extension AssistantCoreChecks {
  /// Counts winners across threads for the race check.
  private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() {
      lock.lock()
      value += 1
      lock.unlock()
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  /// Runs SQL on the file through a second connection, as a stray writer would. The result
  /// code tells whether the file took it.
  private static func rawExec(_ url: URL, _ sql: String) -> Int32 {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
      if let handle { sqlite3_close(handle) }
      return SQLITE_CANTOPEN
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 2000)
    return sqlite3_exec(db, sql, nil, nil, nil)
  }

  private static func rawText(_ url: URL, _ sql: String) -> String? {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
      if let handle { sqlite3_close(handle) }
      return nil
    }
    defer { sqlite3_close(db) }
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let stmt = prepared else {
      sqlite3_finalize(prepared)
      return nil
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
  }

  static func ledger(_ check: Check) throws {
    typealias L = WorkLedger

    // The moves, as a graph.
    let pairs: Set<String> = Set(L.Transition.allCases.map { "\($0.from.rawValue)>\($0.to.rawValue)" })
    let expected: Set<String> = [
      "queued>started", "started>finished", "started>failed", "queued>missed", "queued>dropped", "started>missed",
    ]
    try check(pairs == expected, "The six moves are the only moves")
    try check(L.Transition.allCases.allSatisfy { $0.to != .queued }, "No move ends in queued")
    try check(!L.reachable(from: .started).contains(.queued), "No path leads from started back to queued")
    let afterQueued: Set<L.State> = [.started, .finished, .failed, .missed, .dropped]
    try check(L.reachable(from: .queued) == afterQueued, "Every other state is reachable from queued")
    let finals: [L.State] = [.finished, .failed, .missed, .dropped]
    try check(finals.allSatisfy { $0.isFinal }, "Finished, failed, missed and dropped are final")
    try check(!L.State.queued.isFinal && !L.State.started.isFinal, "Queued and started are not final")
    try check(L.scheduleKey(id: "r1", due: Date(timeIntervalSince1970: 1_800_003_600.9)) == "sched:r1:1800003600", "A schedule key is sched:<id>:<due in seconds>")

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("serein-ledger-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("relay/work.sqlite")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let scheduleDue = t0.addingTimeInterval(3_600)
    let scheduleKey = L.scheduleKey(id: "r1", due: scheduleDue)
    var crashedID: Int64 = 0
    var waitingID: Int64 = 0
    var scheduleID: Int64 = 0

    do {
      let ledger = try L(url: url)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let mode = (attributes[.posixPermissions] as? Int) ?? 0
      try check(mode == 0o600, "The ledger file is owner-only")
      try check(rawText(url, "PRAGMA journal_mode")?.lowercased() == "wal", "The ledger file is in WAL mode")

      // Enqueue is unique on kind and key.
      let first = try ledger.enqueue(.link, owner: "release", dedupeKey: "h1:id:abc", payload: "Body one", now: t0)
      try check(first.isNew && first.row.state == .queued && first.row.attempts == 0, "A new delivery is queued with no attempts")
      try check(first.row.owner == "release" && first.row.kind == .link, "A row keeps its owner and kind")
      let again = try ledger.enqueue(.link, owner: "release", dedupeKey: "h1:id:abc", payload: "Body two", now: t0.addingTimeInterval(5))
      try check(!again.isNew && again.row.id == first.row.id, "A repeat returns the row that is there")
      try check(again.row.payload == "Body one" && again.row.created == first.row.created, "A repeat writes nothing")
      let otherKind = try ledger.enqueue(.ask, owner: "release", dedupeKey: "h1:id:abc", payload: "Question", now: t0)
      try check(otherKind.isNew && otherKind.row.id != first.row.id, "The same key of another kind is its own row")

      // Each move applies once, and only from its start state.
      let id = first.row.id
      let finishedEarly = try ledger.move(id, .finish, now: t0)
      try check(!finishedEarly, "A queued row cannot finish before it starts")
      let started = try ledger.move(id, .start, now: t0.addingTimeInterval(1))
      try check(started, "A queued row starts")
      let startedRow = try ledger.row(id: id)
      try check(startedRow?.state == .started && startedRow?.attempts == 1, "A start adds one attempt")
      try check(startedRow?.started == t0.addingTimeInterval(1), "A start keeps its time")
      let startedTwice = try ledger.move(id, .start, now: t0)
      try check(!startedTwice, "A started row cannot start again")
      let missQueued = try ledger.move(id, .miss, now: t0)
      let dropStarted = try ledger.move(id, .drop, now: t0)
      try check(!missQueued && !dropStarted, "Miss and drop apply only to a queued row")
      let finished = try ledger.move(id, .finish, now: t0.addingTimeInterval(2), note: "Done")
      try check(finished, "A started row finishes")
      let failAfter = try ledger.move(id, .fail, now: t0)
      let interruptAfter = try ledger.move(id, .interrupt, now: t0)
      let finishAgain = try ledger.move(id, .finish, now: t0)
      try check(!failAfter && !interruptAfter && !finishAgain, "Nothing moves a finished row")
      let finishedRow = try ledger.row(id: id)
      try check(finishedRow?.ended == t0.addingTimeInterval(2) && finishedRow?.note == "Done", "An end keeps its time and note")
      let unknown = try ledger.move(999_999, .start, now: t0)
      try check(!unknown, "A move on a row that is not there does not apply")

      let failing = try ledger.enqueue(.ask, owner: "scout", dedupeKey: "ask:fail", payload: "Q", now: t0)
      _ = try ledger.move(failing.row.id, .start, now: t0)
      let failedMove = try ledger.move(failing.row.id, .fail, now: t0, note: "It stopped")
      try check(failedMove, "A started row can fail")
      let dropping = try ledger.enqueue(.proposal, owner: "scout", dedupeKey: "proposal:fare", payload: "Fare watcher", now: t0)
      let droppedMove = try ledger.move(dropping.row.id, .drop, now: t0)
      let startDropped = try ledger.move(dropping.row.id, .start, now: t0)
      try check(droppedMove && !startDropped, "A dropped row never starts")
      let late = try ledger.enqueue(.schedule, owner: "planner", dedupeKey: "sched:late:1", payload: "Late", now: t0)
      let missedMove = try ledger.move(late.row.id, .miss, now: t0, note: "The Mac was asleep")
      try check(missedMove, "A queued row can be missed")

      // The file itself refuses a move back to queued.
      let stray = try ledger.enqueue(.ask, owner: "scout", dedupeKey: "ask:stray", payload: "Q", now: t0)
      _ = try ledger.move(stray.row.id, .start, now: t0)
      let back = rawExec(url, "UPDATE work SET state = 'queued' WHERE id = \(stray.row.id)")
      try check(back != SQLITE_OK, "The file refuses started back to queued from any writer")
      let strayRow = try ledger.row(id: stray.row.id)
      try check(strayRow?.state == .started, "The refused write changed nothing")
      let revive = rawExec(url, "UPDATE work SET state = 'started' WHERE id = \(id)")
      try check(revive != SQLITE_OK, "The file refuses a move out of a final state")
      let bornStarted = rawExec(
        url, "INSERT INTO work(kind, owner, dedupe, payload, state, created, due) VALUES('ask', 'x', 'raw', '', 'started', 0, 0)")
      try check(bornStarted != SQLITE_OK, "The file refuses a new row that is not queued")
      let badKind = rawExec(
        url, "INSERT INTO work(kind, owner, dedupe, payload, state, created, due) VALUES('other', 'x', 'raw', '', 'queued', 0, 0)")
      try check(badKind != SQLITE_OK, "The file refuses a kind it does not know")

      // Two callers cannot both start one row.
      let race = try ledger.enqueue(.ask, owner: "scout", dedupeKey: "ask:race", payload: "Q", now: t0)
      let raceID = race.row.id
      let winners = Tally()
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        if (try? ledger.move(raceID, .start, now: t0)) == true { winners.add() }
      }
      try check(winners.count == 1, "Of eight callers at once, one starts the row")
      _ = try ledger.move(raceID, .finish, now: t0)

      // Next queued rows for an owner.
      _ = try ledger.enqueue(.schedule, owner: "planner", dedupeKey: "sched:b:2", payload: "B", due: t0.addingTimeInterval(120), now: t0)
      _ = try ledger.enqueue(.schedule, owner: "planner", dedupeKey: "sched:a:1", payload: "A", due: t0.addingTimeInterval(60), now: t0)
      _ = try ledger.enqueue(.schedule, owner: "scout", dedupeKey: "sched:c:1", payload: "C", due: t0, now: t0)
      let next = try ledger.queued(owner: "planner", limit: 10)
      try check(next.map(\.payload) == ["A", "B"], "Queued rows for an owner come in due order")
      let capped = try ledger.queued(owner: "planner", limit: 1)
      try check(capped.count == 1, "A list keeps to its limit")
      let everyone = try ledger.queued(limit: 50)
      let hasScout = everyone.contains { $0.owner == "scout" }
      let hasPlanner = everyone.contains { $0.owner == "planner" }
      try check(hasScout && hasPlanner, "No owner gives every owner's rows")
      try check(everyone.allSatisfy { $0.state == .queued }, "The queue lists only queued rows")

      // A crash: one run started, one waits, and one schedule is enqueued before its due time moves.
      let crashed = try ledger.enqueue(.schedule, owner: "planner", dedupeKey: L.scheduleKey(id: "r2", due: t0), payload: "Sort mail", now: t0)
      _ = try ledger.move(crashed.row.id, .start, now: t0)
      crashedID = crashed.row.id
      waitingID = try ledger.enqueue(.link, owner: "release", dedupeKey: "h1:id:wait", payload: "Body", now: t0).row.id
      let scheduled = try ledger.enqueue(.schedule, owner: "planner", dedupeKey: scheduleKey, payload: "Clear inbox", due: scheduleDue, now: t0)
      try check(scheduled.isNew, "A due schedule writes its occurrence first")
      scheduleID = scheduled.row.id

      // Bounds.
      var refusedPayload = false
      do {
        _ = try ledger.enqueue(.link, owner: "release", dedupeKey: "big", payload: String(repeating: "a", count: L.maxPayload + 1))
      } catch { refusedPayload = true }
      try check(refusedPayload, "A payload over the limit is refused")
      var refusedKey = false
      do { _ = try ledger.enqueue(.link, owner: "release", dedupeKey: "", payload: "x") } catch { refusedKey = true }
      try check(refusedKey, "An empty key is refused")
      var refusedOwner = false
      do { _ = try ledger.enqueue(.link, owner: " ", dedupeKey: "k", payload: "x") } catch { refusedOwner = true }
      try check(refusedOwner, "Work with no owner is refused")
      let withNul = try ledger.enqueue(.link, owner: "release", dedupeKey: "h1:id:nul", payload: "a\u{0}b", now: t0)
      try check(withNul.row.payload == "a\u{0}b", "A payload keeps all of its text")
    }  // The ledger closes here, as in a crash after the last write.

    let t1 = t0.addingTimeInterval(7_200)
    let ledger = try L(url: url)
    let lost = try ledger.recoverAfterLaunch(now: t1)
    try check(lost.contains { $0.id == crashedID }, "After a crash the started run is listed")
    try check(lost.allSatisfy { $0.state == .missed && $0.note == L.interruptedNote }, "After a crash every started row is missed")
    let crashedRow = try ledger.row(id: crashedID)
    try check(crashedRow?.ended == t1, "A missed run keeps the recovery time")
    let waitingRow = try ledger.row(id: waitingID)
    try check(waitingRow?.state == .queued, "A queued row stays queued after a crash")
    let secondRecovery = try ledger.recoverAfterLaunch(now: t1)
    try check(secondRecovery.isEmpty, "Recovery a second time changes nothing")
    let queueAfter = try ledger.queued(limit: 200)
    try check(!queueAfter.contains { $0.id == crashedID }, "A missed run never queues again")
    let replay = try ledger.enqueue(.schedule, owner: "planner", dedupeKey: L.scheduleKey(id: "r2", due: t0), payload: "Sort mail", now: t1)
    try check(!replay.isNew && replay.row.state == .missed, "Enqueueing a missed run again does not queue it")

    // The schedule's due time did not move before the crash, so it comes due again.
    let repeatSchedule = try ledger.enqueue(.schedule, owner: "planner", dedupeKey: scheduleKey, payload: "Clear inbox", due: scheduleDue, now: t1)
    try check(!repeatSchedule.isNew && repeatSchedule.row.id == scheduleID, "A crash between enqueue and the next due time repeats safely")
    let plannerQueue = try ledger.queued(owner: "planner", limit: 50)
    try check(plannerQueue.filter { $0.dedupeKey == scheduleKey }.count == 1, "The occurrence is queued once")

    // The Missed card.
    let missedNow = try ledger.missed(limit: 50)
    try check(missedNow.contains { $0.id == crashedID }, "The Missed card lists the crashed run")
    try check(missedNow.allSatisfy { $0.state == .missed && $0.cleared == nil }, "The Missed card lists only missed rows")
    let cleared = try ledger.clearMissed(crashedID, now: t1)
    let clearedTwice = try ledger.clearMissed(crashedID, now: t1)
    try check(cleared && !clearedTwice, "A missed row clears once")
    let missedAfter = try ledger.missed(limit: 50)
    try check(!missedAfter.contains { $0.id == crashedID }, "A cleared row leaves the Missed card")
    let clearQueued = try ledger.clearMissed(waitingID, now: t1)
    try check(!clearQueued, "Only a missed row can be cleared")

    // Pruning keeps 30 days.
    let old = t1.addingTimeInterval(-31 * 86_400)
    let recent = t1.addingTimeInterval(-86_400)
    let oldDone = try ledger.enqueue(.ask, owner: "scout", dedupeKey: "ask:old", payload: "Q", now: old)
    _ = try ledger.move(oldDone.row.id, .start, now: old)
    _ = try ledger.move(oldDone.row.id, .finish, now: old)
    let newDone = try ledger.enqueue(.ask, owner: "scout", dedupeKey: "ask:new", payload: "Q", now: recent)
    _ = try ledger.move(newDone.row.id, .start, now: recent)
    _ = try ledger.move(newDone.row.id, .finish, now: recent)
    let oldMissed = try ledger.enqueue(.schedule, owner: "scout", dedupeKey: "sched:old:1", payload: "Q", now: old)
    _ = try ledger.move(oldMissed.row.id, .miss, now: old)
    let oldQueued = try ledger.enqueue(.schedule, owner: "scout", dedupeKey: "sched:old:2", payload: "Q", now: old)
    let removed = try ledger.prune(now: t1)
    try check(removed >= 1, "Pruning removes old ended rows")
    let oldDoneRow = try ledger.row(id: oldDone.row.id)
    try check(oldDoneRow == nil, "A finished row older than 30 days is removed")
    let newDoneRow = try ledger.row(id: newDone.row.id)
    try check(newDoneRow != nil, "A finished row from yesterday stays")
    let oldMissedRow = try ledger.row(id: oldMissed.row.id)
    try check(oldMissedRow != nil, "A missed row that is not cleared stays")
    let oldQueuedRow = try ledger.row(id: oldQueued.row.id)
    try check(oldQueuedRow?.state == .queued, "A queued row is never pruned")
  }
}
#endif
