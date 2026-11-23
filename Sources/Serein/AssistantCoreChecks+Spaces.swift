#if DEBUG
import Foundation
import SereinCore

/// Routines as the chat lists them (SereinCore/RoutineRules.swift): rows, Fix places and day line.
extension AssistantCoreChecks {
  static func spaces(_ check: Check) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    // Wednesday 4 November 2026, 8:30 in the morning (UTC).
    let now = Date(timeIntervalSince1970: 1_793_781_000)
    let nine: Date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now

    // Automations' rows.
    func routine(_ text: String = "Summarise my inbox", due: Date? = nil, repeats: RelayReminder.Repeat = .weekdays,
                 cron: String? = nil) -> RelayReminder {
      RelayReminder(id: text, text: text, due: due ?? nine, repeats: repeats, action: true, cron: cron)
    }
    let inbox = RoutineList.row(routine(), queued: false, missed: false, calendar: calendar)
    try check(inbox.schedule == "Every weekday at 9:00" && inbox.on && inbox.fix == nil && !inbox.watch && !inbox.failing,
              "A healthy routine reads its schedule as a sentence, is on and has no Fix")
    var held = routine()
    held.paused = true
    try check(!RoutineList.row(held, queued: false, missed: false).on, "A paused routine's switch is off")
    var failing = routine()
    failing.history = [RelayReminder.Run(at: now.addingTimeInterval(-7200), outcome: "failed", thread: "c1"),
                       RelayReminder.Run(at: now.addingTimeInterval(-3600), outcome: "failed", result: "Mail did not answer", thread: "c2")]
    let failed = RoutineList.row(failing, queued: false, missed: false)
    try check(failed.status == .needsYou && failed.problem == "Failed 2 times in a row: Mail did not answer"
                && failed.fix == .chat("c2") && failed.failing,
              "Two failed runs need you, and Fix opens the chat of the last one")
    var recovered = routine()
    recovered.failures = 2
    recovered.history = [RelayReminder.Run(at: now, outcome: "failed"), RelayReminder.Run(at: now, outcome: "done")]
    try check(RoutineList.row(recovered, queued: false, missed: false).problem == nil,
              "The problem line comes from recent runs, not the stored count")
    var asking = routine()
    asking.history = [RelayReminder.Run(at: now, outcome: "needs you", thread: "c3")]
    let asked = RoutineList.row(asking, queued: false, missed: false)
    try check(asked.fix == .chat("c3") && !asked.failing, "A question waiting is fixed in its chat, and is no failure")
    try check(RoutineList.row(routine(), queued: false, missed: true).fix == .serein, "A missed run is fixed in Serein's chat")
    var overspent = routine()
    overspent.paused = true
    overspent.pausedByCost = true
    try check(RoutineList.row(overspent, queued: false, missed: false).fix == .settings, "A token pause is fixed in Settings")

    var lamp = RelayWatch(id: "lamp", name: "Desk lamp price", kind: .url, source: "https://example.com", minutes: 60, lastCheckedAt: now)
    lamp.history = [RelayReminder.Run(at: now, outcome: "failed"), RelayReminder.Run(at: now, outcome: "failed", result: "Timed out")]
    let broken = RoutineList.row(lamp, now: now)
    try check(broken.schedule == "When the page changes" && broken.watch && broken.status == .needsYou
                && broken.problem == "Failed 2 times in a row: Timed out" && broken.fix == .settings && broken.failing,
              "A page watch that failed twice needs you and is fixed in Settings")
    var quiet = RelayWatch(id: "mail", name: "Mail from Maya", kind: .script, source: "", minutes: 15, failures: 3)
    quiet.history = [RelayReminder.Run(at: now, outcome: "failed"), RelayReminder.Run(at: now, outcome: "changed")]
    let fine = RoutineList.row(quiet, now: now)
    try check(fine.schedule == "When its answer changes" && fine.problem == nil && fine.status == .on,
              "A watch whose last check worked has no problem, whatever the stored count says")
    var updated = RelayWatch(id: "upd", name: "Tickets", kind: .url, source: "https://example.com", minutes: 15)
    updated.pausedByUpdate = true
    let paused = RoutineList.row(updated, now: now)
    try check(paused.problem == "Paused by the update. Resume it to check again." && !paused.failing, "An update pause is no failure")
    try check(RoutineList.row(RelayWatch(id: "off", name: "Off", kind: .url, source: "", minutes: 15, paused: true), now: now).status == .paused,
              "A watch the person paused is paused")

    // The day line: what ran since midnight, and what is due before it ends.
    var hourly = routine("Check the queue", due: nine, repeats: .cron, cron: "0 * * * *")
    hourly.history = [RelayReminder.Run(at: now.addingTimeInterval(-90 * 60), outcome: "done"),
                      RelayReminder.Run(at: now.addingTimeInterval(-10 * 3600), outcome: "failed")]
    let marks = RoutineList.day([hourly], now: now, calendar: calendar)
    try check(marks.filter { $0.outcome != nil }.map(\.outcome) == ["done"], "Only today's runs show, with their outcome")
    try check(marks.filter { $0.outcome == nil }.count == 15 && marks.allSatisfy { $0.outcome != nil || $0.at > now },
              "Every hourly slot from 9:00 to 23:00 is still to come")
    try check(marks.map(\.at) == marks.map(\.at).sorted(), "Marks are in time order")
    var stopped = hourly
    stopped.paused = true
    try check(RoutineList.day([stopped], now: now, calendar: calendar).allSatisfy { $0.outcome != nil },
              "A paused routine shows what it ran, and nothing later")
    let often = routine("Watch the queue", due: now.addingTimeInterval(15 * 60), repeats: .cron, cron: "*/15 * * * *")
    try check(RoutineList.day([often], now: now, calendar: calendar).count == RoutineList.laterCap,
              "A routine every few minutes marks the line at most 24 times")
  }
}
#endif
