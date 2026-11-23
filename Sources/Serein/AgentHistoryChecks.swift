#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// Harmless processes and synthetic metadata only; no provider request or private browsing.
  @MainActor static func agentBehaviorHistory(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    guard let store = browser.behaviorHistory else { throw SereinError.invalid("History store missing") }
    let hub = agent.hub
    func launch() throws -> (AgentRun, Capability) {
      let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
      let spec = RunSpec(threadID: UUID().uuidString, provider: .codex, executable: "/bin/sleep",
                         model: "PRIVATE_MODEL_CANARY", effort: "low", mode: .research,
                         projectID: nil, projectName: nil, title: "PRIVATE_PROMPT_CANARY", scope: "",
                         autoRouting: false, grants: RunGrants(), limits: .init(hard: 60, idle: 60))
      do {
        let run = try hub.start(spec, task: task, arguments: ["60"], folder: browser.library.root,
                                prompt: "", transcript: [])
        return (run, task.capability)
      } catch { browser.endTask(task.capability.task); throw error }
    }
    func call(_ cap: Capability, _ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
      try await browser.handle(["task": cap.task, "token": cap.token, "name": name, "arguments": arguments])
    }
    let (a, capA) = try launch()
    let (b, capB) = try launch()
    defer { hub.stop(a); hub.stop(b); hub.dismiss(a); hub.dismiss(b) }
    let before = try store.archive().events.count
    let forged = Capability(socket: capA.socket, task: capA.task)
    do { _ = try await call(forged, "list_tabs"); throw SereinError.invalid("Forged capability accepted") }
    catch { try check(error.localizedDescription.contains("expired") && (try store.archive().events.count) == before,
                      "Unauthenticated calls cannot forge another agent's history") }
    _ = try await call(capA, "list_tabs")
    let eventsA = try store.archive().events.filter { $0.run.id.uuidString == a.id }
    let request = eventsA.last { $0.kind == .toolRequested }
    let returned = eventsA.last { $0.kind == .toolReturned }
    try check(request?.tool == .tabs && request?.operationID == returned?.operationID,
              "Browser history links authenticated requests and host returns")
    do {
      _ = try await call(capA, "fill", ["tab": "PRIVATE_TAB_CANARY", "ref": "PRIVATE_REF_CANARY", "text": "PRIVATE_TEXT_CANARY"])
      throw SereinError.invalid("Read-only typing accepted")
    } catch {
      let failed = try store.archive().events.last { $0.run.id.uuidString == a.id && $0.kind == .toolFailed }
      try check(failed?.tool == .typeText && failed?.source == .host,
                "Refused browser actions remain in durable history without their payload")
    }
    a.setGrant(.act, true, browser: browser, agent: nil)
    a.setGrant(.edits, true, browser: browser, agent: nil)
    let grants = try store.archive().events.filter { $0.run.id.uuidString == a.id && $0.kind == .grantChanged }
    try check(grants.contains { $0.grant == .actions && $0.effect == .currentRun }
              && grants.contains { $0.grant == .edits && $0.effect == .nextTurn }
              && a.behaviorContext?.grants.edits == false && !a.ranWith(.edits),
              "History separates active browser grants from changes intended for the next turn")
    // A task's switches change the composer only while the task's thread is open in it.
    let composerMac = agent.allowMacActions
    a.setGrant(.mac, !composerMac, browser: browser, agent: agent)
    a.setGrant(.mac, composerMac, browser: browser, agent: agent)
    try check(agent.conversationID != a.spec.threadID && agent.allowMacActions == composerMac
              && !a.canSetNext(.act, agent: agent) && !a.canSetNext(.mac, agent: agent)
              && a.canSetNext(.signIns, agent: agent) && !a.canSetNext(.edits, agent: agent),
              "A task's switches leave another thread's composer alone")
    try check(!a.canSwitch(.pages, agent: agent)
              && a.canSwitch(.edits, agent: agent) == (a.isActive && a.spec.grants.projectName != nil)
              && TaskPermissions.chip(.edits, on: true).on == false,
              "Read pages has no switch, and Project edits has none outside a project")
    // Claude's split waits for a new message's first text: a last message with none keeps the answer.
    a.transcript.append(AgentMessage(role: "assistant", text: ""))
    a.messageStarted = true
    a.noteText("Checking the form.")
    a.messageStarted = true
    a.noteText("All fields are set.")
    a.messageStarted = true
    a.noteText("")
    try check(a.transcript.last?.text == "All fields are set." && a.commentary == "Checking the form.",
              "An empty last Claude message leaves the answer in place")
    a.reportBehaviorAssistantTools([
      "type": "assistant", "message": ["content": [
        ["type": "tool_use", "id": "first-private-call", "name": "Read", "input": ["file_path": "/PRIVATE_FILE_CANARY"]],
        ["type": "tool_use", "id": "second-private-call", "name": "Bash", "input": ["command": "PRIVATE_COMMAND_CANARY"]]
      ]]
    ])
    a.track(.init(tool: "read", now: "PRIVATE_FILE_CANARY", done: "PRIVATE_FILE_CANARY"), id: "first-private-call")
    a.failStep("first-private-call", "PRIVATE_ERROR_CANARY")
    a.failStep("first-private-call", "PRIVATE_ERROR_CANARY")
    let reported = try store.archive().events.filter { $0.run.id.uuidString == a.id && $0.source == .harness }
    try check(reported.filter { $0.kind == .toolReported }.count == 2
              && reported.filter { $0.kind == .toolFailureReported }.count == 1,
              "All tools in a harness message are recorded once with failures marked as reports")
    _ = try await call(capB, "finish", ["outcome": "waiting", "summary": "PRIVATE_SUMMARY_CANARY"])
    let finish = try store.archive().events.last { $0.run.id.uuidString == b.id && $0.kind == .outcomeReported }
    try check(finish?.source == .agent && finish?.outcome == .waiting,
              "Agent finish claims stay distinguishable from host observations")
    hub.stop(a); hub.stop(b)
    let reopened = try AgentHistoryStore(library: browser.library)
    let archive = try reopened.archive()
    let stops = archive.events.filter { [a.id, b.id].contains($0.run.id.uuidString) && $0.kind == .capabilityRevoked }
    try check(reopened.issuerID == store.issuerID && stops.count == 2 && browser.tasks[capA.task] == nil,
              "Actor identity, actions and revocation survive reopening the history store")
    let json = String(decoding: try archive.encoded(), as: UTF8.self)
    try check(!json.contains("PRIVATE_") && !json.contains(capA.token) && !json.contains(capB.token),
              "Portable history excludes prompt, model, field, file, command and capability canaries")

    // Force a recording failure. The action must not run, and Stop must still revoke access.
    let (c, capC) = try launch()
    defer { hub.stop(c); hub.dismiss(c) }
    let beforeClear = try store.archive()
    do {
      try browser.clearBehaviorHistory()
      throw SereinError.invalid("History was cleared during an active task")
    } catch {
      try check(error.localizedDescription.contains("Stop active tasks") && (try store.archive().events) == beforeClear.events
                  && store.issuerID == beforeClear.issuerID
                  && browser.tasks[capC.task] != nil,
                "Clear history refuses an active task without losing records or revoking its capability")
    }
    let log = browser.library.root.appendingPathComponent("agent-history/events.jsonl")
    let original = try Data(contentsOf: log)
    let outside = browser.library.root.appendingPathComponent("history-write-canary")
    try Data().write(to: outside)
    try FileManager.default.removeItem(at: log)
    try FileManager.default.createSymbolicLink(at: log, withDestinationURL: outside)
    defer {
      try? FileManager.default.removeItem(at: log)
      try? original.write(to: log, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
      browser.behaviorHistory = try? AgentHistoryStore(library: browser.library)
      browser.behaviorHistoryIssue = nil
      try? FileManager.default.removeItem(at: outside)
    }
    do {
      _ = try await call(capC, "open_tab", ["url": "https://example.com/"])
      throw SereinError.invalid("Tool ran without history")
    } catch {
      hub.stop(c)
      try check(error.localizedDescription.contains("not run") && browser.tasks[capC.task] == nil
                && !browser.agentTabs.entries.contains { $0.taskID == capC.task }
                && browser.behaviorHistoryIssue != nil && (try Data(contentsOf: outside)).isEmpty,
                "Recording failure blocks a browser action while Stop still revokes its capability")
    }
    return results
  }
}
#endif
