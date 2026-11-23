import Foundation

/// One list of everything Serein changed, newest first: its note changes (`RelayJournalEntry`),
/// its schedule changes (`RelayScheduleChange`) and its changes to the assistants
/// (`RelayOrchestrator.teamJournal`), each with the words before and after and whether Undo is
/// still safe. The person's own changes are left out: they are in Settings and the memory
/// journal. Pure, so `--verify-assistant-core` checks it. Undo itself stays on the paths that
/// already exist: the memory journal's for notes, the receipt's (`undoReceipt`) for the rest.
public enum AgentLedger {
  /// Which journal a row comes from, with the id of its entry there.
  public enum Source: Equatable, Hashable, Sendable {
    case note(UUID)
    case schedule(UUID)
    case team(UUID)
  }
  public struct Row: Equatable, Identifiable, Sendable {
    public var source: Source
    public var at: Date
    /// Who changed what, as one plain sentence.
    public var sentence: String
    /// The words before the change; nil when it added the thing.
    public var before: String?
    /// The words after it; nil when it removed the thing.
    public var after: String?
    /// Why Undo is off, as a sentence for the row; nil while Undo is safe.
    public var blocked: String?
    public var id: Source { source }
    public init(source: Source, at: Date, sentence: String, before: String?, after: String?, blocked: String?) {
      self.source = source
      self.at = at
      self.sentence = sentence
      self.before = before
      self.after = after
      self.blocked = blocked
    }
  }

  /// The person's own changes carry this actor, and are left out.
  public static let personActor = "user"
  /// An undo is journaled with this in front of the change's own words.
  static let undidPrefix = "Undid: "

  public static let changedSince = "Changed since, so it can’t be undone here."
  public static let teamChangedSince = "Changed since, or that assistant is on screen, so it can’t be undone here."
  public static let alreadyUndone = "Already undone."
  public static let alreadyGone = "Already gone, so there is nothing to undo."
  public static let alreadyBack = "Already back."
  public static let cannotUndo = "This kind of change can’t be undone here."

  /// Every change Serein made, newest first. `noteLive` gives the words a note holds now
  /// (`noteLive(_:notes:records:)`); `instructions` is the standing instructions now; `name` is
  /// the assistant whose notes these are.
  public static func rows(
    notes: [RelayJournalEntry], noteLive: (RelayJournalEntry) -> String?, instructions: String, name: String,
    schedules: [RelayScheduleChange], reminders: [RelayReminder], watches: [RelayWatch],
    teamJournal: [RelayJournalEntry], team: RelayTeam
  ) -> [Row] {
    var rows: [Row] = []
    for entry in notes where entry.actor != personActor && !entry.isTeam {
      rows.append(noteRow(entry, live: noteLive(entry), instructions: instructions, name: name))
    }
    for (i, change) in schedules.enumerated() where change.actor != personActor {
      let later: [RelayScheduleChange] = schedules[(i + 1)...].filter { $0.kind == change.kind && $0.itemID == change.itemID }
      rows.append(scheduleRow(change, next: later.first, reminders: reminders, watches: watches))
    }
    for (i, entry) in teamJournal.enumerated() where entry.actor != personActor && entry.isTeam {
      if let row = teamRow(entry, later: Array(teamJournal[(i + 1)...]), team: team) { rows.append(row) }
    }
    return rows.sorted { $0.at > $1.at }
  }

  /// The words a note holds now, as Undo would find them. A removed note counts as back when the
  /// store holds it live, listed or not; any other change must find the note in the list
  /// (`RelayJournal.undo` works on the list). The memory journal reads it the same way.
  public static func noteLive(_ entry: RelayJournalEntry, notes: [RelayNote], records: [String: MemoryRecord]) -> String? {
    if let listed = notes.first(where: { $0.id == entry.noteID }) { return listed.text }
    guard entry.action == .removed, let record = records[entry.noteID], record.archived == nil,
      record.review != .unreviewed
    else { return nil }
    return record.text
  }

  static func noteRow(_ entry: RelayJournalEntry, live: String?, instructions: String, name: String) -> Row {
    let before: String? = entry.priorText.map(AgentPrivacy.redact)
    let after: String? = entry.action == .removed ? nil : AgentPrivacy.redact(entry.text)
    if entry.isInstruction {
      let blocked: String? = RelayJournal.undoneInstructions(entry, current: instructions) == nil ? changedSince : nil
      return Row(source: .note(entry.id), at: entry.at, sentence: "\(name) changed its standing instructions.",
                 before: before, after: after, blocked: blocked)
    }
    return Row(source: .note(entry.id), at: entry.at, sentence: MemoryJournal.sentence(entry, name: name),
               before: before, after: after, blocked: noteBlock(MemoryJournal.undoBlock(entry, live: live)))
  }

  /// The memory journal's few words as a sentence for the row.
  public static func noteBlock(_ words: String?) -> String? {
    switch words {
    case nil: return nil
    case "Changed since": return changedSince
    case "Already gone": return alreadyGone
    case "Already back": return alreadyBack
    default: return cannotUndo
    }
  }

  /// After a change comes the next change to the same item (its words before are this one's
  /// after), or else the item as it is now. Undo is safe only while no change came after it.
  static func scheduleRow(
    _ change: RelayScheduleChange, next: RelayScheduleChange?, reminders: [RelayReminder], watches: [RelayWatch]
  ) -> Row {
    let after: String?
    if let next {
      after = words(next)
    } else if change.kind == .reminder {
      after = reminders.first { $0.id == change.itemID }.map(words)
    } else {
      after = watches.first { $0.id == change.itemID }.map(words)
    }
    let blocked: String? = next.map { $0.summary == undidPrefix + change.summary ? alreadyUndone : changedSince }
    return Row(source: .schedule(change.id), at: change.at, sentence: "Serein " + lowercasedFirst(change.summary) + ".",
               before: words(change), after: after, blocked: blocked)
  }

  /// The words of the item before `change`: nil when the change added it.
  static func words(_ change: RelayScheduleChange) -> String? {
    change.kind == .reminder ? change.reminder.map(words) : change.watch.map(words)
  }
  static func words(_ reminder: RelayReminder) -> String {
    RoutineList.sentence(reminder) + (reminder.paused == true ? " (paused)" : "")
  }
  static func words(_ watch: RelayWatch) -> String {
    "\(watch.name), every \(watch.minutes) min" + (watch.paused == true ? " (paused)" : "")
  }

  /// Undo is safe while the roster can still go back the way the receipt's Undo takes it
  /// (`RelayTeam.undoingChange`). nil for an entry with no roster before and after.
  static func teamRow(_ entry: RelayJournalEntry, later: [RelayJournalEntry], team: RelayTeam) -> Row? {
    guard let prior = entry.priorTeam, let next = entry.nextTeam else { return nil }
    var blocked: String?
    if team.undoingChange(before: prior, after: next) == nil {
      blocked = later.contains { $0.text == undidPrefix + entry.text } ? alreadyUndone : teamChangedSince
    }
    var (before, after) = (words(prior, against: next), words(next, against: prior))
    // A change to a colour or a picture reads the same both sides: the sentence says it alone.
    if before == after { (before, after) = (nil, nil) }
    return Row(source: .team(entry.id), at: entry.at, sentence: "Serein " + lowercasedFirst(entry.text) + ".",
               before: before, after: after, blocked: blocked)
  }

  /// The assistants and teams of `roster` that differ in `other`, as names; nil when none.
  static func words(_ roster: RelayTeam, against other: RelayTeam) -> String? {
    let profiles: [String] = roster.profiles.filter { profile in other.profiles.first { $0.id == profile.id } != profile }
      .map { $0.name + ($0.isPaused ? " (paused)" : "") }
    let groups: [String] = roster.teams.filter { group in other.teams.first { $0.id == group.id } != group }
      .map { "Team " + $0.name }
    let all: [String] = profiles + groups
    return all.isEmpty ? nil : all.joined(separator: ", ")
  }

  static func lowercasedFirst(_ s: String) -> String {
    guard let first = s.first else { return s }
    return first.lowercased() + s.dropFirst()
  }
}
