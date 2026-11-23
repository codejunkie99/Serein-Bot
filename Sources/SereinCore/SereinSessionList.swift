import Foundation

/// The sessions and tasks at work on this Mac, as the right panel's Tasks tab reads them.
/// Display only, as sessions outside Serein always are. Pure, so AssistantCoreChecks checks it.
public enum SereinSessionList {
  public struct Entry: Equatable, Identifiable, Sendable {
    public enum State: Int, Equatable, Sendable { case needsYou, working, finished }
    public var id: String
    /// The session's id outside Serein, or the task's thread.
    public var sourceID: String
    public var title: String
    /// The app and folder of a session outside Serein; nil for Serein's own tasks.
    public var place: String?
    /// Only what its section's heading does not already say.
    public var detail: String?
    public var state: State
    public var outside: Bool
    /// A task of Serein's whose run failed: it waits on the person as `needsYou` does.
    public var failed: Bool = false
    var when: Date
  }

  /// A finished task stays listed this long.
  public static let finishedLinger: TimeInterval = 3600

  /// Everything at work: what needs the person first, then what is working, then what just finished.
  /// `followed` maps a session to the Serein chat that follows it: it stays out only while that
  /// chat is listed as a task, so a session that chat once continued is never lost. A session
  /// sitting open is not at work.
  public static func entries(
    tasks: [SereinTrayList.Item], outside: [ExternalSession], followed: [String: String] = [:], now: Date
  ) -> [Entry] {
    let own = tasks.compactMap { taskEntry($0, now: now) }
    let listed = Set(own.map(\.sourceID))
    let others = outside.filter { session in
      followed[session.id].map { !listed.contains($0) } ?? true
    }.compactMap(sessionEntry)
    return (own + others).sorted {
      $0.state != $1.state ? $0.state.rawValue < $1.state.rawValue : ($0.when != $1.when ? $0.when > $1.when : $0.id < $1.id)
    }
  }

  /// The words for them: “1 needs you · 3 working”. Nil with nothing at work.
  public static func summary(_ entries: [Entry]) -> String? {
    func count(_ state: Entry.State) -> Int { entries.filter { $0.state == state }.count }
    let needs = count(.needsYou), working = count(.working), finished = count(.finished)
    var parts: [String] = []
    if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
    if working > 0 { parts.append("\(working) working") }
    if finished > 0 { parts.append("\(finished) finished") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func taskEntry(_ item: SereinTrayList.Item, now: Date) -> Entry? {
    let state: Entry.State
    var detail: String?
    var failed = false
    switch item.outcome {
    case .running: state = .working
    case .waiting: state = .needsYou
    case .stuck:
      // It asks for the person for as long as a finish stays listed, not for the tray's whole day.
      if let ended = item.endedAt, now.timeIntervalSince(ended) >= finishedLinger { return nil }
      state = .needsYou
      detail = "Could not finish"
      failed = true
    case .done:
      guard let ended = item.endedAt, now.timeIntervalSince(ended) < finishedLinger else { return nil }
      state = .finished
    default: return nil
    }
    return Entry(
      id: "task." + item.id, sourceID: item.id, title: item.title, place: nil, detail: detail, state: state, outside: false,
      failed: failed, when: item.endedAt ?? item.startedAt)
  }

  private static func sessionEntry(_ session: ExternalSession) -> Entry? {
    let state: Entry.State
    switch session.state {
    case .running: state = .working
    case .needsUser: state = .needsYou
    case .open: return nil
    }
    let app = session.driver.displayName
    let folder = SessionStatusWords.place(session.cwd, home: NSHomeDirectory())
    return Entry(
      id: "outside." + session.id, sourceID: session.id, title: session.title.isEmpty ? app : session.title,
      place: app + (folder.map { " in " + $0 } ?? ""), detail: nil, state: state, outside: true, when: session.updatedAt)
  }
}
