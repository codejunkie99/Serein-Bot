import Foundation

/// How long a run may last. `hard` is a wall-clock ceiling (nil means none);
/// `idle` stops a run whose CLI has printed nothing for that long.
public struct RunLimits: Equatable {
  public var hard: TimeInterval?
  public var idle: TimeInterval
  public init(hard: TimeInterval?, idle: TimeInterval) {
    self.hard = hard
    self.idle = idle
  }
  /// `mode` is a run-log mode key: answer, library, anywhere, research, page or project.
  public static func forMode(_ mode: String, projectEdits: Bool) -> RunLimits {
    switch mode {
    case "answer", "library": return RunLimits(hard: 15 * 60, idle: 5 * 60)
    case "project":
      // Edits can take a long time (builds, tests). Rely on the inactivity watchdog instead.
      return projectEdits
        ? RunLimits(hard: nil, idle: 15 * 60) : RunLimits(hard: 60 * 60, idle: 10 * 60)
    // Page, research and Anywhere tasks answer in seconds between steps; a model call that has
    // not come back in three minutes is not coming back.
    default: return RunLimits(hard: 30 * 60, idle: 3 * 60)
    }
  }
  public enum Breach: Equatable { case hard(minutes: Int), idle(minutes: Int) }
  public func breach(startedAt: Date, lastEventAt: Date, now: Date = Date()) -> Breach? {
    if let hard, now.timeIntervalSince(startedAt) >= hard { return .hard(minutes: Int(hard / 60)) }
    if now.timeIntervalSince(lastEventAt) >= idle { return .idle(minutes: Int(idle / 60)) }
    return nil
  }
}

/// Grouping for "What your agents did today".
public struct RunGroup: Identifiable, Equatable {
  public var id: String
  public var name: String
  public var runs: [RunRecord]
}
extension RunRecord {
  /// A record still marked running with no live process behind it was cut off (quit or crash).
  public func effectiveOutcome(live: Set<String>) -> Outcome {
    outcome == .running && !live.contains(id) ? .stopped : outcome
  }
}
public enum RunDay {
  /// Groups by project (records without a project share one group), newest activity first.
  public static func group(_ records: [RunRecord], otherName: String = "Questions and the web")
    -> [RunGroup]
  {
    var groups: [String: RunGroup] = [:]
    for r in records {
      let key = r.projectID ?? ""
      let name = r.projectID == nil ? otherName : (r.projectName ?? "Project")
      groups[key, default: RunGroup(id: key, name: name, runs: [])].runs.append(r)
    }
    func latest(_ g: RunGroup) -> Date { g.runs.map(\.lastEventAt).max() ?? .distantPast }
    return groups.values.map { g in
      var g = g
      g.runs.sort { $0.startedAt > $1.startedAt }
      return g
    }.sorted { latest($0) > latest($1) }
  }
}

/// Earlier turns pasted into a prompt when no native session can be resumed.
public enum RunContext {
  /// How much of a conversation a fresh session reads, newest first, in characters. Every path
  /// pastes it into a launch argument or a first prompt, so one cap keeps each under the same size.
  public static let ongoingBudget = 60_000
  /// Each replayed message is clipped to this many characters.
  public static let clip = 6000
  /// Wraps prior turns in an untrusted block; a tag inside the text cannot end or forge a block.
  /// Only the newest turns that fit the `budget` go in, oldest first, under a line saying older
  /// ones were left out; the newest always does.
  public static func previousConversation(_ turns: [(role: String, text: String)], budget: Int = ongoingBudget) -> String {
    var used = 0
    var start = turns.count
    for index in turns.indices.reversed() {
      let size = min(turns[index].text.count, clip) + turns[index].role.count + 4
      guard used + size <= budget || start == turns.count else { break }
      used += size
      start = index
    }
    let kept = turns[start...]
    guard !kept.isEmpty else { return "" }
    let body = kept.map { "\($0.role): \(AgentPrivacy.redact($0.text, limit: clip))" }.joined(separator: "\n\n")
    let block = UntrustedText.wrap("previous_conversation", body)
    guard start > 0 else { return block }
    return "This is an ongoing conversation; only its most recent part follows. Your saved notes keep what lasts.\n" + block
  }
}
