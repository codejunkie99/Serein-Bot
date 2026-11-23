import SereinCore
import SwiftUI

/// The app side of `RunDisplay`: gathers a run's CLI activity and its newest browser step so the
/// header pill, the Now line, the transcript placeholder and the At work row read one state.
extension AgentRun {
  /// `board`: the run's agent tab board record when the caller already has it.
  @MainActor func display(board: AgentTabBoard.RunInfo? = nil) -> RunDisplay.State {
    let last = board?.steps.last
    let replying = transcript.last.map { $0.role == "assistant" && !$0.text.isEmpty } ?? false
    return RunDisplay.resolve(
      RunDisplay.Input(
        active: isActive, outcome: isActive ? nil : record.outcome.rawValue,
        cliNow: now, cliNowAt: nowAt,
        lastStep: last.map { RunDisplay.Step(tool: $0.tool, label: $0.label, time: $0.time) },
        phase: phase, finishReported: reportedOutcome != nil, replying: replying))
  }
  /// The board record for this run, by its capability task.
  @MainActor func boardInfo(_ browser: BrowserModel?) -> AgentTabBoard.RunInfo? {
    guard let browser else { return nil }
    if let info = browser.agentTabs.runs[taskID] { return info }
    return browser.agentTabs.runs.values.filter { $0.threadID == spec.threadID && $0.startedAt >= record.startedAt }
      .max { $0.startedAt < $1.startedAt }
  }
  /// Browser activity comes from this live run's tabs, rather than its destination or
  /// permissions: a project agent may browse too, and a read-pages grant alone is idle.
  @MainActor func isWorkingInBrowser(_ browser: BrowserModel) -> Bool {
    guard isActive else { return false }
    if let task = browser.tasks[taskID], !task.finished && !task.tabs.isEmpty { return true }
    return browser.agentTabs.entries.contains { entry in
      guard let info = browser.agentTabs.runs[entry.taskID], !info.ended else { return false }
      return entry.taskID == taskID || (info.threadID == spec.threadID && info.startedAt >= record.startedAt)
    }
  }
}

extension AgentModel {
  /// What an empty assistant message in this thread stands for, from the same state as the
  /// task panel's header.
  func replyPlaceholder(browser: BrowserModel?) -> String {
    guard let run = hub.latest(for: conversationID) else { return running ? "Working…" : "No reply." }
    return run.display(board: run.boardInfo(browser)).placeholder
  }
}
