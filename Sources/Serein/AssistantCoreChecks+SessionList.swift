#if DEBUG
import Foundation
import SereinCore

/// The list behind the right panel's Tasks tab (SereinSessionList.swift): what is at work and how
/// it is counted. Synthetic data only.
extension AssistantCoreChecks {
  static func sessionList(_ check: Check) throws {
    typealias L = SereinSessionList
    let now = Date(timeIntervalSince1970: 3_000_000)
    func outside(_ id: String, _ state: ExternalSession.State) -> ExternalSession {
      ExternalSession(id: id, driver: .codex, title: "Title " + id, cwd: "/work/" + id, state: state, updatedAt: now)
    }
    func task(_ id: String, _ outcome: RunRecord.Outcome, endedAgo: TimeInterval? = nil) -> SereinTrayList.Item {
      SereinTrayList.Item(
        id: id, title: "Task " + id, outcome: outcome, startedAt: now.addingTimeInterval(-7200),
        endedAt: endedAgo.map { now.addingTimeInterval(-$0) }, serein: false)
    }

    let mixed = L.entries(
      tasks: [task("done", .done, endedAgo: 60), task("run", .running), task("ask", .waiting)],
      outside: [outside("busy", .running), outside("waits", .needsUser), outside("idle", .open)], now: now)
    try check(mixed.map(\.state) == [.needsYou, .needsYou, .working, .working, .finished],
      "What needs the person leads, then what is working, then what just finished")
    try check(!mixed.contains { $0.id.hasSuffix("idle") }, "A session sitting open is not at work")
    try check(L.summary(mixed) == "2 need you · 2 working · 1 finished", "Each kind is counted in words")
    try check(L.summary(L.entries(tasks: [task("ask", .waiting)], outside: [], now: now)) == "1 needs you",
      "One session reads in the singular")
    try check(L.summary([]) == nil, "With nothing at work there are no words")

    let session = mixed.first { $0.id == "outside.waits" }
    try check(session?.outside == true && session?.place == "Codex in waits" && session?.detail == nil,
      "A session names its app and folder, and leaves its state to its section")
    try check(mixed.first { $0.id == "task.ask" }?.outside == false && mixed.first { $0.id == "task.ask" }?.place == nil,
      "A task of Serein's own has no outside place")

    try check(L.entries(tasks: [task("chat", .running)], outside: [outside("mine", .running), outside("free", .running)],
      followed: ["mine": "chat"], now: now).map(\.sourceID).sorted() == ["chat", "free"],
      "A session whose Serein chat is listed as a task is not listed twice")
    try check(L.entries(tasks: [], outside: [outside("mine", .needsUser)], followed: ["mine": "chat"], now: now)
      .map(\.sourceID) == ["mine"], "A session a chat once continued still shows when that chat is not at work")
    try check(L.entries(tasks: [task("old", .done, endedAgo: 2 * L.finishedLinger), task("stopped", .stopped, endedAgo: 10)],
      outside: [], now: now).isEmpty, "An old finish or a stopped task leaves the list")
    let failed = L.entries(tasks: [task("bad", .stuck, endedAgo: 10)], outside: [], now: now)
    try check(failed.first?.state == .needsYou && failed.first?.detail == "Could not finish", "A failed task needs the person")
    try check(L.entries(tasks: [task("stale", .stuck, endedAgo: 2 * L.finishedLinger)], outside: [], now: now).isEmpty,
      "An old failure stops asking for the person")
    let crowd = L.entries(tasks: [], outside: (0..<12).map { outside("s\($0)", .running) }, now: now)
    try check(crowd.count == 12 && L.summary(crowd) == "12 working", "Everything at work is listed and counted")
  }
}
#endif
