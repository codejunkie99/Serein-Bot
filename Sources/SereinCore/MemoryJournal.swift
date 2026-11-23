import Foundation

/// The words of the memory journal: one plain sentence for each change to an assistant's notes
/// (`RelayJournalEntry`), why an Undo is no longer safe, and the gauge's one line. Pure, so
/// `--verify-assistant-core` checks it. The journal's data and its Undo are `RelayJournal`.
public enum MemoryJournal {
  /// The journal shows a search field once it lists more than this many changes.
  public static let searchAbove = 6
  /// `RelayJournalEntry.actor` for a note that left for the archive: its end date passed, or
  /// the notes were full (`MemoryFill.Reason`).
  public static let endedActor = "expiry"
  public static let fullActor = "archive"

  /// The note a sentence names: its words on one line, cut short, secrets redacted.
  static func topic(_ text: String) -> String {
    let line = AgentPrivacy.redact(text).split(whereSeparator: \.isNewline).joined(separator: " ")
    return "“" + (line.count > 60 ? String(line.prefix(60)) + "…" : line) + "”"
  }

  /// One change as a plain sentence: who changed which note. `name` is the assistant's name.
  public static func sentence(_ entry: RelayJournalEntry, name: String) -> String {
    let note = topic(entry.action == .removed ? (entry.priorText ?? "") : entry.text)
    if entry.actor == endedActor { return note + " reached its end date and moved to the archive." }
    if entry.actor == fullActor { return note + " moved to the archive to make room." }
    let lead: String
    switch (entry.action, entry.actor) {
    case (.added, "user"): lead = "You added"
    case (.added, "learning"): lead = name + " learned"
    case (.added, _): lead = name + " remembered"
    case (.refreshed, "user"): lead = "You changed"
    case (.refreshed, _): lead = name + " updated"
    case (.removed, "user"): lead = "You forgot"
    case (.removed, "tidy"): lead = name + " tidied away"
    case (.removed, _): lead = name + " forgot"
    }
    return lead + " " + note + "."
  }

  /// A few words in place of Undo when undoing `entry` is no longer safe, or nil when it is.
  /// `live` is the words the note holds now, nil when no live note has its id. Undoing a change
  /// after a newer one would silently drop the newer words; a removed secret is never put back.
  public static func undoBlock(_ entry: RelayJournalEntry, live: String?) -> String? {
    if entry.isInstruction || entry.isTeam { return "Can’t undo" }
    switch entry.action {
    case .added:
      guard let live else { return "Already gone" }
      return live == entry.text ? nil : "Changed since"
    case .refreshed:
      guard let live else { return "Already gone" }
      guard entry.priorText != nil else { return "Can’t undo" }
      return live == entry.text ? nil : "Changed since"
    case .removed:
      guard let prior = entry.priorText, AgentPrivacy.redact(prior) == prior else { return "Can’t undo" }
      return live == nil ? nil : "Already back"
    }
  }

  /// Whether a change matches what the person typed in the journal's search field.
  public static func matches(_ entry: RelayJournalEntry, query: String) -> Bool {
    let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !wanted.isEmpty else { return true }
    return [entry.text, entry.priorText ?? "", entry.quote ?? "", entry.priorQuote ?? ""]
      .contains { $0.lowercased().contains(wanted) }
  }

  /// The source chip of a note: the chat that taught it when there is one, else where the words
  /// came from.
  public static func source(_ record: MemoryRecord) -> String {
    if record.chat != nil { return "From a chat" }
    switch record.provenance.source {
    case .person: return "You said this"
    case .assistant: return "Learned"
    case .page: return "From a page"
    case .mail: return "From mail"
    case .app: return "From an app"
    case .handoff: return "From a hand-off"
    case .imported: return "Imported"
    case .migrated: return "Earlier notes"
    }
  }

  /// The gauge's one short line. The detail is `gaugeInfo`, behind the info button.
  public static func gauge(_ usage: MemoryFill.Usage) -> String {
    usage.warns ? "Notes \(usage.percent)% full. The oldest archive next." : "Notes \(usage.percent)% full"
  }
  public static let gaugeInfo =
    "Each assistant keeps up to \(MemoryFill.maxLines) lines or \(MemoryFill.maxBytes.formatted()) bytes of notes. Past that, the oldest notes move to the archive, and so does a note past its end date. Nothing is deleted: Undo on the journal line brings a note back. Health facts never move for room."
}
