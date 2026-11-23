#if DEBUG
import Foundation
import SereinCore

/// Where a row sits in the Agents list (AgentListOrder.swift). Synthetic data only.
extension AssistantCoreChecks {
  static func agentListOrder(_ check: Check) throws {
    typealias O = AgentListOrder
    struct Row: Equatable {
      let id: String
      var names: [String] { [id] }
      var aliases: [String] = []
      var when = Date(timeIntervalSince1970: 0)
      var all: [String] { names + aliases }
    }
    func ids(_ rows: [Row]) -> [String] { rows.map(\.id) }
    let rows = [Row(id: "a"), Row(id: "b"), Row(id: "c")]

    try check(ids(O.arranged(rows, known: [], keys: \.all)) == ["a", "b", "c"],
      "With nothing remembered, rows stay in the order given")
    try check(ids(O.arranged(rows, known: ["c", "a", "b"], keys: \.all)) == ["c", "a", "b"],
      "Remembered rows keep their remembered order")
    try check(ids(O.arranged(rows.reversed(), known: ["a", "b", "c"], keys: \.all)) == ["a", "b", "c"],
      "A change in the order given moves nothing (a click, a new message, a status)")
    try check(ids(O.arranged(rows, known: ["b", "c"], keys: \.all)) == ["a", "b", "c"],
      "A new row goes first and the rest hold still")
    try check(ids(O.arranged(rows, known: ["a", "b", "c"], pinned: ["c"], keys: \.all)) == ["c", "a", "b"],
      "A pinned row leads")
    try check(ids(O.arranged(rows, known: ["a", "b", "c"], pinned: ["c", "b"], keys: \.all)) == ["c", "b", "a"],
      "Pinned rows go in pin order")

    // A session that becomes a chat when it is opened.
    let opened = [Row(id: "chat-1", aliases: ["codex:s1"]), Row(id: "codex:s2")]
    try check(ids(O.arranged(opened, known: ["codex:s2", "codex:s1"], keys: \.all)) == ["codex:s2", "chat-1"],
      "A session opened as a chat keeps the session's place")
    let known = O.remembering(opened, known: ["codex:s2", "codex:s1"], keys: \.all)
    try check(known == ["codex:s2", "codex:s1", "chat-1"], "Its new name is remembered beside its old one")
    let relinked = [Row(id: "chat-1", aliases: ["codex:copy"]), Row(id: "codex:s2")]
    try check(ids(O.arranged(relinked, known: known, keys: \.all)) == ["codex:s2", "chat-1"],
      "A chat that follows a copy of its session keeps its place")

    try check(O.remembering(rows, known: [], keys: \.all) == ["a", "b", "c"], "The first look is remembered as shown")
    try check(O.remembering([Row(id: "new"), Row(id: "a")], known: ["a", "gone"], keys: \.all) == ["new", "a", "gone"],
      "A new row goes to the front and a name no longer listed keeps its place")
    try check(O.remembering(rows, known: ["a", "b", "c"], keys: \.all) == ["a", "b", "c"], "Nothing new changes nothing")
    try check(ids(O.arranged([Row(id: "gone"), Row(id: "a")], known: ["a", "gone"], keys: \.all)) == ["a", "gone"],
      "A session that comes back returns to its place")
    let long = (0..<O.limit).map(String.init)
    let capped = O.remembering([Row(id: "new")], known: long, keys: \.all)
    try check(capped.count == O.limit && capped.first == "new" && !capped.contains(long[long.count - 1]),
      "The remembered names stay within the limit, dropping the far end")

    let many = (0..<6).map { Row(id: "\($0)") }
    try check(ids(O.visible(many, limit: 2, keep: { $0.id == "4" })) == ["0", "1", "4"],
      "A project's later row shows when it asks to, in its own place")
    try check(ids(O.visible(many, limit: 2, keep: { _ in false })) == ["0", "1"], "A project otherwise shows its first rows")

    let t = Date(timeIntervalSince1970: 100)
    let dated = [Row(id: "old", when: t), Row(id: "new", when: t.addingTimeInterval(9)), Row(id: "tie", when: t)]
    try check(ids(O.recent(dated, when: \.when)) == ["new", "old", "tie"],
      "Recents goes newest first, and rows with the same time keep their order")
    try check(ids(O.held([Row(id: "new"), Row(id: "b"), Row(id: "a")], hold: ["a", "b"], keys: \.all)) == ["a", "b", "new"],
      "A held list keeps its rows, and a row that appears goes after them")

    // A helper's own transcript is all sidechain lines (SubagentTranscriptView reads it).
    let helperLine = Data(#"{"type":"user","isSidechain":true,"message":{"role":"user","content":"Find the copy"}}"#.utf8)
    try check(LinkedHistory.claude(helperLine).messages.isEmpty, "A session's transcript leaves helper lines out")
    try check(LinkedHistory.claude(helperLine, helper: true).messages.map(\.text) == ["Find the copy"],
      "A helper's own transcript keeps them")
    try check(ExternalSubagent(id: "a", title: "t", state: nil, updatedAt: t).log == nil, "A sub-thread may have no file to open")
  }
}
#endif
