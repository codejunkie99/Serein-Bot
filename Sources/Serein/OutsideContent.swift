import SereinCore

/// Whether a thread has taken in outside content: web pages, mail, messages, an app's answer.
/// Shared by every connection that sends a run's words to a third party (connected apps, and
/// MCP servers by address): a run's first call to one it has not used yet asks after such
/// content, even for a read, and is refused unattended. Kept per thread and never cleared,
/// because a warm or resumed session still holds earlier turns' content in its context.
extension BrowserModel {
  /// After each tool result, and each failure (BrowserModel.handle): every tool but
  /// `ConnectedApps.trustedTools`, whether or not a connection is on yet.
  func noteOutsideContent(task id: String, tool raw: String) {
    guard !ConnectedApps.trustedTools.contains(raw) else { return }
    noteOutsideContent(thread: threadID(forTask: id) ?? id)
  }
  /// Marks a thread; saved at once, since a relaunched chat resumes with that content.
  func noteOutsideContent(thread: String) {
    guard !thread.isEmpty, !outsideThreads.contains(thread) else { return }
    outsideThreads = OutsideThreads.kept(outsideThreads + [thread])
    OutsideThreads.save(outsideThreads)
  }
  /// The thread took in outside content in any of its turns, this launch or an earlier one. While
  /// the saved marks cannot be read (GateSettings), every thread counts as having taken some.
  func outsideContent(thread: String) -> Bool { GateSettings.shared.unreadable || outsideThreads.contains(thread) }
}

/// The marked thread ids in GateSettings (`serein.outsideThreads`): ids only, the newest 500.
/// Taking an id away would drop the ask, so they live with the other gate values; checks and
/// previews keep theirs in memory (GateSettings is not opened then).
enum OutsideThreads {
  static let key = "serein.outsideThreads"
  static let limit = 500
  static func load() -> [String] { kept(GateSettings.shared.stringArray(forKey: key) ?? []) }
  static func save(_ ids: [String]) { GateSettings.shared.set(kept(ids), forKey: key) }
  /// Short, non-empty ids, each once, the newest `limit`.
  static func kept(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    let clean = ids.reversed().filter { !$0.isEmpty && $0.count <= 200 && seen.insert($0).inserted }
    return Array(clean.prefix(limit).reversed())
  }
}
