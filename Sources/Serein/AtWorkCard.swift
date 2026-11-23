import SereinCore
import SwiftUI

/// Running clocks and the final 60-second fade need ticks. Once only static waiting or
/// expired tasks remain, the finite sequence ends; a changed run installs a new schedule.
struct AtWorkTimelineSchedule: TimelineSchedule {
  var items: [AtWorkList.Item]
  func entries(from startDate: Date, mode: Mode) -> Entries {
    let active = items.contains { $0.outcome == .running }
    let expiry = items.filter { $0.outcome != .running && !AtWorkList.needsUser($0.outcome) }
      .map { ($0.endedAt ?? $0.startedAt).addingTimeInterval(AtWorkList.linger) }.max()
    return Entries(nextDate: startDate, until: active ? nil : max(startDate, expiry ?? startDate))
  }
  struct Entries: Sequence, IteratorProtocol {
    var nextDate: Date?
    var until: Date?
    mutating func next() -> Date? {
      guard let date = nextDate else { return nil }
      if let until {
        nextDate = date >= until ? nil : Swift.min(date.addingTimeInterval(1), until)
      } else {
        nextDate = date.addingTimeInterval(1)
      }
      return date
    }
  }
}

extension AgentRun {
  var atWorkItem: AtWorkList.Item {
    AtWorkList.Item(id: id, outcome: record.outcome, startedAt: record.startedAt, endedAt: record.endedAt)
  }
  /// The second line of an At work row.
  /// While running, the same Now line as the task panel (`RunDisplay`).
  func atWorkPhase(_ browser: BrowserModel?) -> String {
    switch record.outcome {
    case .running: return display(board: boardInfo(browser)).line ?? phase
    case .waiting: return summary?.question ?? record.summary ?? outcomeText
    case .stuck: return "Could not finish"
    case .done: return "Done"
    case .stopped: return "Stopped"
    }
  }
}
