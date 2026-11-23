#if DEBUG
import Foundation
import SereinCore

/// What launch loads only when it is needed: the dictation model, and the event log read once.
extension AssistantCoreChecks {
  static func lazyLoadLaunch(_ check: Check) throws {
    try check(
      SpeechEngine.warmsAtLaunch(wakeWords: true) && !SpeechEngine.warmsAtLaunch(wakeWords: false),
      "The dictation model loads at launch only while wake words are on; otherwise the first dictation loads it")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-lazy-launch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    func run() -> AgentHistoryRun {
      AgentHistoryRun(id: UUID(), threadID: UUID().uuidString, projectID: nil,
        harness: .codex, harnessVersion: nil, model: "synthetic", mode: .answer,
        permission: .supervised, grants: .init())
    }
    /// A log of five events: `ended` started and ended, `working` started and used a tool, `started` only started.
    func fixture(_ name: String) throws -> (library: Library, ended: AgentHistoryRun, working: AgentHistoryRun, started: AgentHistoryRun) {
      let library = try Library(root: folder.appendingPathComponent(name))
      let store = try AgentHistoryStore(library: library)
      let (ended, working, started) = (run(), run(), run())
      try store.record(run: ended, kind: .runStarted)
      try store.record(run: working, kind: .runStarted)
      try store.record(run: ended, kind: .runEnded, outcome: .done)
      try store.record(run: started, kind: .runStarted)
      try store.record(run: working, kind: .toolReported, source: .harness, tool: .other)
      return (library, ended, working, started)
    }

    let plain = try fixture("plain")
    let reopened = try AgentHistoryStore(library: plain.library)
    try reopened.recoverInterruptedRuns()
    let recovered = try reopened.archive().events
    try check(
      recovered.map(\.sequence) == Array(1...7)
        && recovered.suffix(2).map(\.run.id) == [plain.started.id, plain.working.id]
        && recovered.suffix(2).allSatisfy { $0.kind == .interrupted && $0.outcome == .stopped }
        && !recovered.contains { $0.run.id == plain.ended.id && $0.kind == .interrupted },
      "Reopening the log marks each unfinished run interrupted once, in log order, and leaves a finished run alone")
    try reopened.recoverInterruptedRuns()
    try reopened.checkIntegrity()
    try check(try reopened.archive().events.count == 7, "A second recovery finds nothing left to mark, and the log stays whole")
    try check(
      try AgentHistoryStore(library: plain.library).archive().events.map(\.id) == recovered.map(\.id),
      "A later launch reads back the same log")

    // A run that ends between opening and recovery is not marked: the opening scan is dropped on any write.
    let late = try fixture("late")
    let store = try AgentHistoryStore(library: late.library)
    try store.record(run: late.working, kind: .runEnded, outcome: .done)
    try store.recoverInterruptedRuns()
    let events = try store.archive().events
    try check(
      events.count == 7 && events.last?.run.id == late.started.id && events.last?.kind == .interrupted
        && !events.contains { $0.run.id == late.working.id && $0.kind == .interrupted },
      "Recovery after a write reads the log again, so a run that just ended is not marked interrupted")
  }
}
#endif
