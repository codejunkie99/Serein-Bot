import Foundation

/// One assistant's Memory page (affectUI Memory Panel with Agent / Memory): its notes grouped by
/// who may read them, each with where it came from. Pure; the page reads the records and writes
/// every change through the existing paths (`updateNotes` and the store).
public enum MemoryPanel {
  public struct Group: Equatable, Sendable {
    public let scope: MemoryScope
    public let records: [MemoryRecord]
  }

  /// The notes the page lists. For the assistant you talk to, `live` is Serein's own list
  /// (`RelayOrchestrator.notes`, newest first), which changes the moment Forget, an edit or the
  /// journal's Undo runs, before the store has the change: each note takes its record from
  /// `records` by id with the live words, and a note the store does not hold yet stands in as the
  /// person's own. The live list never holds a paused note, so `owner`'s paused ones follow from
  /// `records`. With no `live` list, `records` as read.
  public static func rows(live: [RelayNote]?, records: [MemoryRecord], owner: String) -> [MemoryRecord] {
    guard let live else { return records }
    let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let listed: [MemoryRecord] = live.map { note in
      guard let record = byID[note.id] else {
        return MemoryRecord(
          id: note.id, text: note.text, quote: note.quote, owner: owner, scope: .assistant(owner),
          provenance: MemoryProvenance(source: .person), createdAt: note.createdAt, expires: note.expires,
          review: .confirmed, personal: true)
      }
      guard record.text != note.text, let edited = try? record.edited(MemoryEdit(text: note.text)) else { return record }
      return edited
    }
    let shown = Set(live.map(\.id))
    return listed + records.filter { !$0.enabled && $0.owner == owner && !shown.contains($0.id) }
  }

  /// `rows` by who may read them: `owner`'s own first, then another assistant's, each team in the
  /// order met, then every assistant. Order within a group is kept; a repeated id shows once.
  public static func groups(_ rows: [MemoryRecord], owner: String) -> [Group] {
    var seen = Set<String>()
    var order: [MemoryScope] = []
    var byScope: [MemoryScope: [MemoryRecord]] = [:]
    for record in rows where seen.insert(record.id).inserted {
      if byScope[record.scope] == nil { order.append(record.scope) }
      byScope[record.scope, default: []].append(record)
    }
    func rank(_ scope: MemoryScope) -> Int {
      switch scope {
      case .assistant(let id): return id == owner ? 0 : 1
      case .team: return 2
      case .person: return 3
      }
    }
    let ranked = order.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
    return ranked.map { Group(scope: $0.element, records: byScope[$0.element] ?? []) }
  }

  /// A group's caption: "Only Planner" for the page's own notes, else who reads them ("The Trip
  /// team", "Every assistant").
  public static func title(_ scope: MemoryScope, owner: String, in team: RelayTeam) -> String {
    let whom: String = MemoryTools.whom(scope, in: team)
    return scope == .assistant(owner) ? "Only " + whom : whom
  }

  /// Where a note came from, in the person's words: "You said this", "Planner learned this",
  /// "From a web page (example.com)". The chat it was made in is the page's own link.
  public static func origin(_ record: MemoryRecord, names: [String: String]) -> String {
    let provenance = record.provenance
    switch provenance.source {
    case .person: return "You said this"
    case .assistant: return (names[record.owner].map { MemoryPrompt.plain($0) } ?? "An assistant") + " learned this"
    case .page: return "From a web page" + (provenance.reference.map { " (" + MemoryPrompt.plain($0) + ")" } ?? "")
    case .mail: return "From your mail"
    case .app: return "From a connected app"
    case .handoff: return "From another assistant’s report"
    case .imported: return "Imported text"
    case .migrated: return "From earlier notes"
    }
  }

  /// The words of an edit in place, trimmed, or the error the person reads: the same rule as a
  /// note the store saves (`MemoryRecord.cleanText`).
  public static func edit(_ raw: String) throws -> String { try MemoryRecord.cleanText(raw) }
}
