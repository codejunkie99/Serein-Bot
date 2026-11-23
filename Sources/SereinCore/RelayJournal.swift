import Foundation

/// One change to Relay's notes, recorded so the user can undo it: an append-only record that
/// keeps the prior words. The orchestrator diffs the notes around every change, so Relay's writes and the
/// user's both land here, and an undo is itself a recorded change — undoing an undo works. The
/// user's standing instructions (`RelayPersona.rules`) are journaled the same way, as one entry
/// per saved edit.
public struct RelayJournalEntry: Codable, Equatable, Identifiable, Sendable {
  public enum Action: String, Codable, Sendable { case added, refreshed, removed }
  /// What changed: a note, the standing instructions as a whole, or the roster of assistants and
  /// their teams (kept in relay/team-journal.json, shared by every assistant).
  public enum Kind: String, Codable, Sendable { case note, instruction, team }
  public var id: UUID
  /// nil for entries written before instructions were journaled: those are all notes.
  public var kind: Kind?
  public var at: Date
  /// Who changed it: "relay" (its remember/forget tools, or an instructions proposal the user
  /// allowed), "user", "learning" (a kept proposal),
  /// or "expiry" (a note past its time).
  public var actor: String
  public var action: Action
  public var noteID: String
  /// The note's words after the change.
  public var text: String
  public var quote: String?
  /// The words before it, for refreshed and removed notes.
  public var priorText: String?
  public var priorQuote: String?
  /// A team entry's roster before and after the change, so Undo can put it back.
  public var priorTeam: RelayTeam?
  public var nextTeam: RelayTeam?

  public init(
    id: UUID = UUID(), at: Date = Date(), actor: String, action: Action, noteID: String,
    text: String, quote: String? = nil, priorText: String? = nil, priorQuote: String? = nil, kind: Kind? = nil,
    priorTeam: RelayTeam? = nil, nextTeam: RelayTeam? = nil
  ) {
    self.id = id
    self.kind = kind
    self.at = at
    self.actor = actor
    self.action = action
    self.noteID = noteID
    self.text = text
    self.quote = quote
    self.priorText = priorText
    self.priorQuote = priorQuote
    self.priorTeam = priorTeam
    self.nextTeam = nextTeam
  }

  public var isInstruction: Bool { kind == .instruction }
  public var isTeam: Bool { kind == .team }
}

public enum RelayJournal {
  /// The journal keeps this many entries, oldest dropped first.
  public static let kept = 200
  /// The `noteID` every instruction entry carries; no note has it (note ids are UUIDs).
  public static let instructionsID = "instructions"

  /// The entry one saved edit of the standing instructions produces, or nil when the words did
  /// not change. Both sides are the sanitized rules, so whitespace alone is no change.
  public static func instructionEntry(actor: String, before: String, after: String, at: Date = Date())
    -> RelayJournalEntry?
  {
    guard before != after else { return nil }
    let action: RelayJournalEntry.Action = before.isEmpty ? .added : after.isEmpty ? .removed : .refreshed
    return RelayJournalEntry(
      at: at, actor: actor, action: action, noteID: instructionsID, text: after,
      priorText: before.isEmpty ? nil : before, kind: .instruction)
  }

  /// The instructions an undo of `entry` puts back: the words before it ("" when there were none).
  /// nil for a note entry, and nil when the instructions changed after it: putting older words
  /// back would silently drop the newer edits, so those are undone first.
  public static func undoneInstructions(_ entry: RelayJournalEntry, current: String) -> String? {
    guard entry.isInstruction, entry.text == current else { return nil }
    return entry.priorText ?? ""
  }

  /// The `noteID` every team entry carries.
  public static let teamID = "team"

  /// The entry one change to the roster produces (an assistant or a team created or deleted, a
  /// membership or a scope changed), with `summary` in plain words; nil when nothing changed.
  public static func teamEntry(actor: String, summary: String, before: RelayTeam, after: RelayTeam)
    -> RelayJournalEntry?
  {
    guard before != after else { return nil }
    let action: RelayJournalEntry.Action = after.profiles.count > before.profiles.count || after.teams.count > before.teams.count
      ? .added : after.profiles.count < before.profiles.count || after.teams.count < before.teams.count ? .removed : .refreshed
    return RelayJournalEntry(
      at: Date(), actor: actor, action: action, noteID: teamID, text: summary, kind: .team, priorTeam: before, nextTeam: after)
  }

  /// The roster an undo of `entry` puts back (`RelayTeam.undoing`), or nil when it cannot: not a
  /// team entry, or the roster changed after it (undo newer changes first).
  public static func undoneTeam(_ entry: RelayJournalEntry, current: RelayTeam) -> RelayTeam? {
    guard entry.isTeam, let before = entry.priorTeam, let after = entry.nextTeam else { return nil }
    return current.undoing(before: before, after: after)
  }

  /// The entries one change produces: the notes matched by id before and after it.
  public static func entries(actor: String, before: [RelayNote], after: [RelayNote], at: Date = Date())
    -> [RelayJournalEntry]
  {
    let before = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let after = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var entries: [RelayJournalEntry] = []
    for (id, note) in after {
      switch before[id] {
      case nil:
        entries.append(
          RelayJournalEntry(at: at, actor: actor, action: .added, noteID: id, text: note.text, quote: note.quote))
      case .some(let old):
        if old.text != note.text || old.quote != note.quote {
          entries.append(
            RelayJournalEntry(
              at: at, actor: actor, action: .refreshed, noteID: id, text: note.text, quote: note.quote,
              priorText: old.text, priorQuote: old.quote))
        }
      }
    }
    for (id, note) in before where after[id] == nil {
      entries.append(
        RelayJournalEntry(
          at: at, actor: actor, action: .removed, noteID: id, text: "", quote: nil,
          priorText: note.text, priorQuote: note.quote))
    }
    return entries
  }

  /// Applies one entry's reverse; true when it changed anything. An undo of an added note
  /// removes it, of a removed note restores it with its old words, of a refreshed note puts
  /// the old words back.
  @discardableResult
  public static func undo(_ entry: RelayJournalEntry, in notes: inout [RelayNote]) -> Bool {
    guard !entry.isInstruction, !entry.isTeam else { return false }
    switch entry.action {
    case .added:
      guard let i = notes.firstIndex(where: { $0.id == entry.noteID }) else { return false }
      notes.remove(at: i)
      return true
    case .removed:
      guard let priorText = entry.priorText, !notes.contains(where: { $0.id == entry.noteID }) else { return false }
      notes.append(RelayNote(id: entry.noteID, text: priorText, quote: entry.priorQuote, createdAt: entry.at))
      return true
    case .refreshed:
      guard let i = notes.firstIndex(where: { $0.id == entry.noteID }), let priorText = entry.priorText else {
        return false
      }
      notes[i].text = priorText
      notes[i].quote = entry.priorQuote
      return true
    }
  }

  /// The newest `kept` entries, oldest dropped first.
  public static func trimmed(_ entries: [RelayJournalEntry]) -> [RelayJournalEntry] {
    entries.count <= kept ? entries : Array(entries.suffix(kept))
  }
}
