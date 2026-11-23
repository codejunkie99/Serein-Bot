#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// Two concurrent runs backed by a harmless long-running process (no provider involved).
  /// Stopping run A must revoke A's capability while B's capability keeps working.
  @MainActor static func concurrentRuns(browser: BrowserModel, agent: AgentModel) async throws
    -> [String]
  {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let hub = agent.hub
    func launch(_ name: String) throws -> AgentRun {
      let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
      let spec = RunSpec(
        threadID: "check-" + name, provider: .codex, executable: "/bin/sleep", model: "",
        effort: "low", mode: .research, projectID: nil, projectName: nil, title: "Check " + name,
        scope: "", autoRouting: false, grants: RunGrants(),
        limits: RunLimits(hard: 120, idle: 120))
      do {
        return try hub.start(
          spec, task: task, arguments: ["60"], folder: browser.library.root, prompt: "",
          transcript: [])
      } catch {
        browser.endTask(task.capability.task)
        throw error
      }
    }
    func listTabs(_ run: AgentRun) async throws -> [String: Any] {
      guard let cap = browser.tasks[run.taskID]?.capability else {
        throw SereinError.invalid("Invalid or expired browser capability")
      }
      return try await browser.handle([
        "task": cap.task, "token": cap.token, "name": "list_tabs", "arguments": [:],
      ])
    }
    let a = try launch("A")
    let b = try launch("B")
    let capA = browser.tasks[a.taskID]?.capability
    try check(hub.active.count >= 2 && a.taskID != b.taskID, "Two agent runs active at once")
    hub.stop(a)
    do {
      guard let capA else { throw SereinError.invalid("missing capability") }
      _ = try await browser.handle([
        "task": capA.task, "token": capA.token, "name": "list_tabs", "arguments": [:],
      ])
      throw SereinError.invalid("Stopped run's capability accepted")
    } catch {
      try check(
        error.localizedDescription.contains("expired") && a.record.outcome == .stopped,
        "Stopping run A revokes A's capability")
    }
    let stillValid = try await listTabs(b)
    try check(
      stillValid["tabs"] != nil && b.isActive, "Run B keeps its capability while A is stopped")
    hub.stop(b)
    try check(browser.tasks[b.taskID] == nil, "Run B revoked when it stops")
    let logged = browser.library.runs().filter { [a.id, b.id].contains($0.id) }
    try check(
      logged.count == 2 && logged.allSatisfy { $0.outcome == .stopped },
      "Run log records both runs with their outcome")
    hub.dismiss(a)
    hub.dismiss(b)
    return results
  }
}
#endif
