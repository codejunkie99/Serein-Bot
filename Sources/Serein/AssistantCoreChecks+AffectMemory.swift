#if DEBUG
import Foundation
import SereinCore

/// The Memory page's notes (`MemoryPanel`): Serein's own list wins over a stale read, paused notes
/// stay listed, groups go from the page's own notes to every assistant's, and each note says
/// where it came from.
extension AssistantCoreChecks {
  static func affectMemory(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func record(
      _ id: String, _ text: String, owner: String = "main", scope: MemoryScope = .assistant("main"),
      from source: MemorySource = .person, reference: String? = nil, on: Bool = true, used: Date? = nil
    ) -> MemoryRecord {
      MemoryRecord(
        id: id, text: text, owner: owner, scope: scope, provenance: MemoryProvenance(source: source, reference: reference),
        createdAt: now, enabled: on, review: .confirmed, personal: false, lastUsed: used)
    }
    let learned = record("a", "Standup at 9:30", from: .assistant, used: now)
    let shared = record("b", "Goes by Sam", scope: .person)
    let paused = record("c", "Gym on Tuesdays", on: false)
    let othersPaused = record("d", "Not this page's", owner: "scout", scope: .assistant("scout"), on: false)
    let forgotten = record("e", "Forgotten a moment ago")
    let records = [learned, shared, paused, othersPaused, forgotten]

    try check(MemoryPanel.rows(live: nil, records: records, owner: "main") == records, "Another assistant's page lists its records as read")

    let live = [
      RelayNote(id: "a", text: "Standup at 10:00", createdAt: now), RelayNote(id: "b", text: "Goes by Sam", createdAt: now),
      RelayNote(id: "new", text: "Just put back by Undo", createdAt: now),
    ]
    let rows = MemoryPanel.rows(live: live, records: records, owner: "main")
    try check(rows.map(\.id) == ["a", "b", "new", "c"], "The live list leads, a forgotten note leaves at once, and only this page's paused note follows")
    try check(
      rows[0].text == "Standup at 10:00" && rows[0].provenance.source == .assistant && rows[0].lastUsed == now,
      "An edit shows its new words at once and keeps where the note came from and when it was used")
    try check(
      rows[2].scope == .assistant("main") && rows[2].provenance.source == .person && rows[2].lastUsed == nil,
      "A note the store does not hold yet stands in as the person's own, private, never used")

    let team = RelayTeam(
      profiles: [RelayProfile(id: "main", name: "Serein"), RelayProfile(id: "scout", name: "Scout")], activeID: "main")
    let mixed = [shared, record("f", "Scout's", owner: "scout", scope: .assistant("scout")), learned, paused, learned]
    let groups = MemoryPanel.groups(mixed, owner: "main")
    try check(
      groups.map(\.scope) == [.assistant("main"), .assistant("scout"), .person]
        && groups[0].records.map(\.id) == ["a", "c"],
      "Groups go from the page's own notes to another assistant's to every assistant's, in order, a repeat shown once")
    try check(
      MemoryPanel.title(.assistant("main"), owner: "main", in: team) == "Only Serein"
        && MemoryPanel.title(.person, owner: "main", in: team) == "Every assistant",
      "A group's caption says who reads its notes")
    try check(
      MemoryPanel.origin(shared, names: ["main": "Serein"]) == "You said this"
        && MemoryPanel.origin(learned, names: ["main": "Serein"]) == "Serein learned this"
        && MemoryPanel.origin(record("g", "Hall", from: .page, reference: "https://venue.example.invalid/hall?x=1"), names: [:])
          == "From a web page (venue.example.invalid)",
      "Each note says where it came from, a page by its host only")
    try check(
      (try? MemoryPanel.edit("  Vegetarian  ")) == "Vegetarian" && (try? MemoryPanel.edit("   ")) == nil
        && (try? MemoryPanel.edit(String(repeating: "a", count: MemoryRecord.maxText + 1))) == nil,
      "An edit in place is trimmed, and empty or too long words are refused as the store refuses them")
  }
}
#endif
