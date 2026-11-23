import Foundation

/// The day line over Settings › Your reminders: the hours around now on one line, each run of a
/// reminder, routine, goal or assistant's schedule a mark at its time. Check-ins have no set time
/// (they wait for a quiet moment), so they are not on it. Pure, so `--verify-assistant-core` checks it.
public enum ScheduleDay {
  /// Hours the line shows on each side of now.
  public static let reach: TimeInterval = 6 * 3600
  public static func span(now: Date) -> ClosedRange<Date> {
    now.addingTimeInterval(-reach)...now.addingTimeInterval(reach)
  }
  /// The runs in the span around now, in time order: what ran by now (from each schedule's runs, with its
  /// outcome) and what is still due (paused, ended and used-up schedules run nothing more). A To do
  /// card's reminder stays off it, since only the board changes that one.
  public static func marks(
    _ reminders: [RelayReminder], now: Date, calendar: Calendar = .current
  ) -> [RoutineList.Mark] {
    let span: ClosedRange<Date> = Self.span(now: now)
    var marks: [RoutineList.Mark] = []
    for reminder in reminders where !TodoBoard.isReminder(reminder.id) {
      let name = RoutineList.flat(reminder.text)
      for (index, run) in (reminder.history ?? []).enumerated() where span.contains(run.at) && run.at <= now {
        marks.append(RoutineList.Mark(id: "\(reminder.id)#ran\(index)", routineID: reminder.id, name: name, at: run.at,
                                      outcome: run.outcome))
      }
      guard reminder.paused != true, !reminder.goalEnded, !reminder.limitReached else { continue }
      var slot: Date? = reminder.due > now ? reminder.due : reminder.next(after: now, calendar: calendar)
      var count = 0
      while let at = slot, at <= span.upperBound, count < RoutineList.laterCap {
        marks.append(RoutineList.Mark(id: "\(reminder.id)#due\(count)", routineID: reminder.id, name: name, at: at,
                                      outcome: nil))
        count += 1
        slot = reminder.next(after: at, calendar: calendar)
      }
    }
    return marks.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
  }
  /// The first run still to come, for the line under the marks.
  public static func next(_ marks: [RoutineList.Mark]) -> RoutineList.Mark? { marks.first { $0.outcome == nil } }
}
