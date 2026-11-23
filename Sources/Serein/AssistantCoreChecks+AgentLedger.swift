#if DEBUG
import Foundation
import SereinCore

/// What Serein changed (AgentLedger.swift): one list over the notes, schedules and assistants,
/// newest first, with before and after, and Undo only while it is safe.
extension AssistantCoreChecks {
  static func agentLedger(_ check: Check) throws {
    let now = Date()
    let seats = RelayJournalEntry(at: now.addingTimeInterval(-60), actor: "relay", action: .added, noteID: "n1", text: "Window seat")
    let mine = RelayJournalEntry(at: now.addingTimeInterval(-30), actor: "user", action: .added, noteID: "n3", text: "Mine")
    let dentist = RelayJournalEntry(at: now.addingTimeInterval(-300), actor: "relay", action: .refreshed, noteID: "n2",
                                    text: "Tuesdays", priorText: "Mondays")
    let notes: [RelayNote] = [RelayNote(id: "n1", text: "Window seat"), RelayNote(id: "n2", text: "Thursdays"),
                              RelayNote(id: "n3", text: "Mine")]

    let plants = RelayReminder(id: "r1", text: "Water the plants", due: now.addingTimeInterval(3_600), repeats: .daily)
    var paused = plants
    paused.paused = true
    let pause = RelayScheduleChange(at: now.addingTimeInterval(-200), actor: "relay", summary: "Paused “Water the plants”",
                                    kind: .reminder, itemID: "r1", reminder: plants)
    let undid = RelayScheduleChange(at: now.addingTimeInterval(-100), actor: "user", summary: "Undid: Paused “Water the plants”",
                                    kind: .reminder, itemID: "r1", reminder: paused)
    let edit = RelayScheduleChange(at: now.addingTimeInterval(-100), actor: "user", summary: "Changed “Water the plants”",
                                   kind: .reminder, itemID: "r1", reminder: paused)

    let main = RelayProfile(id: RelayTeam.mainID, name: "Serein")
    let before = RelayTeam(profiles: [main], activeID: RelayTeam.mainID)
    let after = RelayTeam(profiles: [main, RelayProfile(id: "scout", name: "Scout")], activeID: RelayTeam.mainID)
    let made = RelayJournalEntry(at: now.addingTimeInterval(-400), actor: "relay", action: .added, noteID: RelayJournal.teamID,
                                 text: "Made assistant Scout", kind: .team, priorTeam: before, nextTeam: after)

    func rows(schedules: [RelayScheduleChange], reminders: [RelayReminder], team: RelayTeam) -> [AgentLedger.Row] {
      AgentLedger.rows(
        notes: [dentist, seats, mine], noteLive: { AgentLedger.noteLive($0, notes: notes, records: [:]) }, instructions: "",
        name: "Serein", schedules: schedules, reminders: reminders, watches: [], teamJournal: [made], team: team)
    }
    let all = rows(schedules: [pause], reminders: [paused], team: after)
    try check(all.map(\.source) == [.note(seats.id), .schedule(pause.id), .note(dentist.id), .team(made.id)],
              "Notes, schedules and assistants are one list, newest first, and the person's own change is left out")

    let seatRow = all.first { $0.source == .note(seats.id) }
    let dentistRow = all.first { $0.source == .note(dentist.id) }
    try check(seatRow?.blocked == nil && seatRow?.before == nil && seatRow?.after == "Window seat",
              "A note Serein added and nobody changed since shows its words and offers Undo")
    try check(dentistRow?.before == "Mondays" && dentistRow?.after == "Tuesdays" && dentistRow?.blocked == AgentLedger.changedSince,
              "A note changed since shows before and after and says on the row why it can't be undone")

    let pauseRow = all.first { $0.source == .schedule(pause.id) }
    try check(pauseRow?.blocked == nil && pauseRow?.before == RoutineList.sentence(plants)
                && pauseRow?.after == RoutineList.sentence(plants) + " (paused)"
                && pauseRow?.sentence == "Serein paused “Water the plants”.",
              "A schedule change with nothing after it shows the schedule then and now, and offers Undo")
    let undone = rows(schedules: [pause, undid], reminders: [plants], team: after).first { $0.source == .schedule(pause.id) }
    let edited = rows(schedules: [pause, edit], reminders: [plants], team: after).first { $0.source == .schedule(pause.id) }
    try check(undone?.blocked == AgentLedger.alreadyUndone && edited?.blocked == AgentLedger.changedSince
                && edited?.after == RoutineList.sentence(plants) + " (paused)",
              "A schedule changed again is off for Undo, saying whether it was undone or changed since; its after is the next change's before")
    try check(!rows(schedules: [pause, undid], reminders: [plants], team: after).contains { $0.source == .schedule(undid.id) },
              "The person's own Undo is not a row of what Serein changed")

    let teamRow = all.first { $0.source == .team(made.id) }
    try check(teamRow?.blocked == nil && teamRow?.before == nil && teamRow?.after == "Scout"
                && teamRow?.sentence == "Serein made assistant Scout.",
              "A new assistant shows by name and offers Undo while the roster can go back")
    var changed = after
    changed.profiles[1].paused = true
    let moved = rows(schedules: [], reminders: [], team: changed).first { $0.source == .team(made.id) }
    try check(moved?.blocked == AgentLedger.teamChangedSince, "An assistant changed since is off for Undo, with the reason on the row")

    try check(AgentLedger.noteBlock("Already gone") == AgentLedger.alreadyGone && AgentLedger.noteBlock("Already back") == AgentLedger.alreadyBack
                && AgentLedger.noteBlock("Can’t undo") == AgentLedger.cannotUndo && AgentLedger.noteBlock(nil) == nil,
              "Every reason the memory journal gives becomes a sentence on the row")
  }
}
#endif
