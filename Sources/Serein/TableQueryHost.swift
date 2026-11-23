import Foundation
import SereinCore

/// table_query: questions about a CSV, TSV or .xlsx the person attached to this turn's message
/// (TableFile, TableQuery). Only a table this turn was sent with (`AgentRun.documents`, in its own
/// folder, deleted when the run ends), and only the bytes it had when staged (its digest). It is a
/// read of the person's own file and adds no ApprovalGate effect: like `read` and `downloads` it
/// runs without a card, and nothing it does is a write (nothing is saved, sent or fetched). The
/// answer is the file's untrusted content, redacted and fenced (TableQueryAnswer.reply, off the
/// main actor), and is recorded so a reply's table naming the file is checked against it
/// (CollectedPages.noteFile, CollectedTableCard).
extension BrowserModel {
  static let tableNotAttached =
    "table_query reads only a CSV, TSV or .xlsx file the user attached to this message. Name it exactly as listed under Documents the user attached."

  func tableQuery(task id: String, arguments a: [String: Any]) async throws -> [String: Any] {
    guard let run = agentTabs.hub?.runs.first(where: { $0.taskID == id && $0.isActive }), let folder = run.attachments
    else { throw SereinError.invalid(Self.tableNotAttached) }
    let tables = run.documents.filter { TableFile.isTable($0.name) }
    let asked = (a["file"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = asked.isEmpty && tables.count == 1 ? tables[0].name : asked
    // The staged copy itself: a plain name in this turn's folder, a regular file and not a link,
    // the path the run holds, and the digest taken at staging.
    guard let document = tables.first(where: { $0.name == name }), let digest = document.digest,
      let file = TurnAttachments.document(
        named: name, in: folder, root: ComposerContext.attachmentRoot, limit: TurnAttachments.limit(forName: name)),
      file.standardizedFileURL.path == URL(fileURLWithPath: document.path).standardizedFileURL.path
    else {
      if asked.isEmpty && tables.count > 1 {
        throw SereinError.invalid("Name the file: " + tables.map(\.name).joined(separator: ", ") + ".")
      }
      throw SereinError.invalid(Self.tableNotAttached)
    }
    let query = try TableQuery(arguments: a)
    let asks: Bool = TableQuery.queryFields.contains { a[$0] != nil }
    let sheetName: String = (a["sheet"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let path: String = file.path
    // The read, digest check, parse, query and rendering all run off the main actor; the copy
    // lives in memory for this call only.
    let reply: TableQueryAnswer.Reply = try await Task.detached(priority: .userInitiated) {
      try TableQueryAnswer.reply(path: path, digest: digest, name: name, query: query, asks: asks, sheet: sheetName)
    }.value
    var answer: [String: Any] = ["file": name, "untrusted": true, "result": reply.fenced]
    if let matched = reply.matched { answer["rows_matched"] = matched }
    if let shown = reply.shown { answer["rows_shown"] = shown }
    if let sheets = reply.sheets { answer["sheets"] = sheets }
    if let note = reply.note { answer["note"] = note }
    // The same rows the agent sees, for the card's word-for-word check of a reply's table.
    let owner: String = agentTabs.runs[id]?.threadID ?? id
    CollectedPages.noteFile(name, rows: reply.evidence, owner: owner, digest: digest)
    return answer
  }
}
