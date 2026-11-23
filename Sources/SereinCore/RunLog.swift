import Foundation

/// One agent run, appended to `sessions/runs.jsonl` at start, on progress and at the end.
/// The file is append-only; the latest record for an id wins.
public struct RunRecord: Codable, Identifiable, Equatable {
  public enum Outcome: String, Codable, Sendable {
    case running, done, waiting, stuck, stopped
    /// Hand-written: a record from an earlier version that says "needs_user", "failed", "refused",
    /// "parked" or anything unknown is stuck (DESIGN), so an old line never drops a run and never
    /// shows as a waiting ghost row.
    public init(from decoder: any Decoder) throws {
      self = Outcome(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .stuck
    }
    /// The finish tool's outcome word. The old needs_user is refused, so the model picks done or stuck
    /// instead of leaving a waiting run with no card open.
    public init?(reported word: String) {
      switch word {
      case "done": self = .done
      case "waiting": self = .waiting
      case "stuck", "failed": self = .stuck
      default: return nil
      }
    }
  }
  public var id: String
  public var threadID: String
  public var provider: String
  public var model: String
  public var effort: String
  public var mode: String
  public var projectID: String?
  public var projectName: String?
  public var title: String
  public var startedAt: Date
  public var endedAt: Date?
  public var outcome: Outcome
  public var summary: String?
  /// The failure reason or input question, kept separately from the short list summary.
  /// Optional so records written by earlier versions still load.
  public var attentionDetail: String?
  public var toolCount: Int
  public var lastEventAt: Date
  /// Tokens the run used, when the CLI reports them (Codex app server, `codex exec`, Claude Code).
  public var tokens: Int?
  /// How much of the model's context the run had used when it was last written (its result
  /// line's meter); nil where its route reports no size that can be estimated, and in older records.
  public var context: ContextMeter?
  /// The task's stop counts (R5, R34); nil in older records.
  public var tried: Tried?
  /// The decision section's version the run was launched with (U4); nil in older records.
  public var promptVersion: String?
  public init(
    id: String = UUID().uuidString, threadID: String, provider: String, model: String = "",
    effort: String = "", mode: String, projectID: String? = nil, projectName: String? = nil,
    title: String, startedAt: Date = Date()
  ) {
    self.id = id
    self.threadID = threadID
    self.provider = provider
    self.model = model
    self.effort = effort
    self.mode = mode
    self.projectID = projectID
    self.projectName = projectName
    self.title = String(title.prefix(200))
    self.startedAt = startedAt
    self.outcome = .running
    self.toolCount = 0
    self.lastEventAt = startedAt
  }
}

extension Library {
  public static let runLogPath = "sessions/runs.jsonl"
  public func appendRun(_ record: RunRecord) throws { try append(record, to: Library.runLogPath) }
  /// Latest record per run id, newest first.
  public func runs() -> [RunRecord] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let text = try? String(contentsOf: root.appendingPathComponent(Library.runLogPath))
    else { return [] }
    var latest: [String: RunRecord] = [:]
    for line in text.split(separator: "\n") {
      if let r = try? decoder.decode(RunRecord.self, from: Data(line.utf8)) { latest[r.id] = r }
    }
    return latest.values.sorted { $0.startedAt > $1.startedAt }
  }
  public func runs(on day: Date, calendar: Calendar = .current) -> [RunRecord] {
    runs().filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
  }
}
