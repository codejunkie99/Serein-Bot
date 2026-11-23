import Foundation
import SereinCore

/// The routine run rules (`RoutineRuns`, SereinCore/RoutineRules.swift) applied to Serein's live
/// schedules and alerts: one retry for a run that took no step, the one failure line in the run's
/// chat, the watch wake cap and the check-in quiet window. A retry queues like Run now, so it runs
/// under the same unattended rules, cards and grants as the run it repeats.
extension RelayOrchestrator {
  /// A routine run failed. True when one retry is queued (the caller records nothing yet); false
  /// when the failure is final, after posting its one line into `thread`. A run that took any step
  /// (a tool call, a page step, an approval card, a receipt) is never retried: it may have acted.
  func routineFailed(_ reminder: RelayReminder, run: AgentRun?, failure: String, thread: String) -> Bool {
    guard let live = reminders.first(where: { $0.id == reminder.id }), live.action else { return false }
    let acted: Bool = run.map {
      !$0.steps.isEmpty || !$0.behaviorOperations.isEmpty || !$0.behaviorApprovals.isEmpty
        || desk.facts[thread]?.receipts.isEmpty == false
    } ?? false
    guard RoutineRuns.mayRetry(live, acted: acted), !state.paused, live.paused != true else {
      deliver(receipt: nil, line: RoutineRuns.failureLine(live, failure: failure), into: thread)
      return false
    }
    let delay: TimeInterval = RoutineRuns.retryDelay(after: failure)
    updateReminders { list in
      guard let i = list.firstIndex(where: { $0.id == live.id }) else { return }
      let run = RelayReminder.Run(outcome: RoutineRuns.retried, result: String(failure.prefix(200)), thread: thread)
      list[i].history = Array(((list[i].history ?? []) + [run]).suffix(10))
    }
    note("Scheduled request \(Self.short(live.text)) failed; trying once more in \(Int(delay)) seconds", .auto)
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      // Stopped, paused or deleted meanwhile: nothing runs again.
      guard let self, !self.state.paused, let current = self.reminders.first(where: { $0.id == live.id }),
        current.paused != true
      else { return }
      self.queueWork(
        ScheduledTurn(reminder: current, initiator: .scheduled, profileID: current.profileID), kind: .schedule,
        key: "retry:\(current.id):" + UUID().uuidString)
    }
    return true
  }

  /// An alert's change may start an AI turn: under `RoutineRuns.wakeLimit` in the last 24 hours.
  /// True counts the wake; false leaves the change in the alert's history only.
  func watchMayWake(_ id: String, now: Date = Date()) -> Bool {
    guard let watch = watches.first(where: { $0.id == id }) else { return false }
    guard watch.mayWake(now: now) else {
      updateWatches { list in
        guard let i = list.firstIndex(where: { $0.id == id }), let last = list[i].history?.indices.last else { return }
        list[i].history?[last].result = "Changed. Not reported: it already woke Serein \(RoutineRuns.wakeLimit) times today."
      }
      return false
    }
    updateWatches { list in
      if let i = list.firstIndex(where: { $0.id == id }) { list[i] = list[i].waking(now: now) }
    }
    return true
  }

  /// The person wrote in `thread` in the last 20 minutes, so a check-in there waits.
  func personWroteRecently(in thread: String, now: Date = Date()) -> Bool {
    let last = agent.conversations.first { $0.id == thread }?.messages
      .last { ($0.role == "you" || $0.role == "user") && RelayAutomatic.kind(of: $0.text) == nil }?.sentAt
    return RelayProactive.checkInWaits(lastWrote: last, now: now)
  }
}
