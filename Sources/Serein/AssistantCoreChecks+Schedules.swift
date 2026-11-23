#if DEBUG
import Foundation
import SereinCore

/// The day line over Settings › Your reminders (SereinCore/ScheduleDay.swift): which runs are on it
/// and in what order.
extension AssistantCoreChecks {
  static func affectSchedules(_ check: Check) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    // Wednesday 4 November 2026, 8:30 in the morning (UTC).
    let now = Date(timeIntervalSince1970: 1_793_781_000)
    func marks(_ reminders: [RelayReminder]) -> [RoutineList.Mark] { ScheduleDay.marks(reminders, now: now, calendar: calendar) }

    var hourly = RelayReminder(id: "tidy", text: "Tidy\nDownloads", due: now.addingTimeInterval(30 * 60), repeats: .cron,
                               action: true, cron: "0 * * * *")
    hourly.history = [RelayReminder.Run(at: now.addingTimeInterval(-7 * 3600), outcome: "done"),
                      RelayReminder.Run(at: now.addingTimeInterval(-2 * 3600), outcome: "failed")]
    let line = marks([hourly])
    try check(line.filter { $0.outcome != nil }.map(\.outcome) == ["failed"],
              "A run more than six hours ago is off the line; one two hours ago is on it with its outcome")
    try check(line.filter { $0.outcome == nil }.count == 6 && line.allSatisfy { $0.outcome != nil || $0.at > now },
              "An hourly routine at 8:30 marks 9:00 to 14:00, and every mark still to come is after now")
    try check(line.map(\.at) == line.map(\.at).sorted() && line.allSatisfy { $0.name == "Tidy Downloads" },
              "Marks are in time order, each named on one line")

    var paused = hourly
    paused.paused = true
    try check(marks([paused]).count == 1 && marks([paused]).first?.outcome == "failed",
              "A paused routine shows what it ran, and nothing later")

    let late = RelayReminder(id: "late", text: "Late", due: now.addingTimeInterval(7 * 3600))
    let dentist = RelayReminder(id: "dentist", text: "Call the dentist", due: now.addingTimeInterval(90 * 60))
    let numbers = RelayReminder(id: "numbers", text: "Post the numbers", due: now.addingTimeInterval(5 * 3600), repeats: .weekly,
                                action: true, profileID: "ops")
    let card = RelayReminder(id: TodoBoard.reminderID("trip"), text: "Plan the trip", due: now.addingTimeInterval(3600))
    let mixed = marks([late, numbers, card, dentist])
    try check(mixed.map(\.routineID) == ["dentist", "numbers"],
              "A plain reminder and an assistant's schedule are on the line; a run past six hours and a To do card's reminder are not")
    try check(ScheduleDay.next(mixed)?.routineID == "dentist" && ScheduleDay.next(marks([paused])) == nil,
              "The next run is the first still to come; none once everything has run")
  }
}
#endif
