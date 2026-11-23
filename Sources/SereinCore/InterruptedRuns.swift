import Foundation

/// A run that was still working when Serein quit or crashed. Its thread offers Retry and Reply;
/// nothing restarts by itself.
public struct InterruptedRun: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var threadID: String
  public var title: String
  public var startedAt: Date
  public var stoppedAt: Date
  public init(id: String, threadID: String, title: String, startedAt: Date, stoppedAt: Date) {
    self.id = id
    self.threadID = threadID
    self.title = title
    self.startedAt = startedAt
    self.stoppedAt = stoppedAt
  }
}

public enum InterruptedRuns {
  public static let path = "sessions/interrupted.json"
  public static let summary = "Stopped when Serein quit."
  /// Keeps the file small; the oldest notes go first.
  public static let maxKept = 50

  /// Runs the log still shows as running that this process is not running.
  public static func detect(_ records: [RunRecord], live: Set<String>) -> [RunRecord] {
    records.filter { $0.outcome == .running && !live.contains($0.id) }
  }
  /// The record that closes an interrupted run in the log. It ends at its last sign of life.
  public static func stopped(_ record: RunRecord) -> RunRecord {
    var out = record
    out.outcome = .stopped
    out.endedAt = record.lastEventAt
    out.summary = summary
    return out
  }
  /// Closes interrupted runs in the run log and remembers them for their threads.
  /// Call once at launch, before any new run starts.
  @discardableResult
  public static func recover(library: Library, live: Set<String> = []) -> [InterruptedRun] {
    let found = detect(library.runs(), live: live)
    var kept = library.load([InterruptedRun].self, from: path) ?? []
    guard !found.isEmpty else { return kept }
    for record in found {
      try? library.appendRun(stopped(record))
      kept.removeAll { $0.id == record.id }
      kept.append(
        InterruptedRun(
          id: record.id, threadID: record.threadID, title: record.title,
          startedAt: record.startedAt, stoppedAt: record.lastEventAt))
    }
    kept = Array(kept.sorted { $0.stoppedAt < $1.stoppedAt }.suffix(maxKept))
    try? library.save(kept, to: path)
    return kept
  }
  /// Remembers runs that Serein stops because it is quitting. The caller stops them and the
  /// run log records them as stopped.
  @discardableResult
  public static func remember(_ records: [RunRecord], library: Library, at date: Date = Date())
    -> [InterruptedRun]
  {
    var kept = library.load([InterruptedRun].self, from: path) ?? []
    guard !records.isEmpty else { return kept }
    for record in records {
      kept.removeAll { $0.id == record.id }
      kept.append(
        InterruptedRun(
          id: record.id, threadID: record.threadID, title: record.title,
          startedAt: record.startedAt, stoppedAt: date))
    }
    kept = Array(kept.sorted { $0.stoppedAt < $1.stoppedAt }.suffix(maxKept))
    try? library.save(kept, to: path)
    return kept
  }
  /// The note a thread shows: its latest interrupted run, unless a newer run started since.
  public static func pending(
    thread: String, in list: [InterruptedRun], newerRunStarted: Bool
  ) -> InterruptedRun? {
    guard !newerRunStarted else { return nil }
    return list.filter { $0.threadID == thread }.max { $0.stoppedAt < $1.stoppedAt }
  }
  /// Forgets a thread's notes once the user retried, replied or dismissed.
  public static func resolve(thread: String, in list: [InterruptedRun]) -> [InterruptedRun] {
    list.filter { $0.threadID != thread }
  }
  /// The transcript to resend from: the interrupted reply and its request are dropped.
  public static func retryTranscript(_ roles: [String]) -> Int {
    var keep = roles.count
    if keep > 0, roles[keep - 1] == "assistant" { keep -= 1 }
    if keep > 0, roles[keep - 1] == "you" { keep -= 1 }
    return keep
  }
}
