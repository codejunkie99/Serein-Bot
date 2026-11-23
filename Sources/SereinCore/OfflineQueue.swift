import Foundation

/// A task the user sent while Serein could not reach the network or the agent CLI.
/// It holds the user's own words and choices, never page content.
public struct PendingTask: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var threadID: String
  public var prompt: String
  public var provider: String
  public var mode: String
  public var projectID: String?
  public var model: String
  public var effort: String
  public var allowActions: Bool
  public var allowProjectEdits: Bool
  public var createdAt: Date
  /// Set when the task is a failed turn kept for later, so a resend replaces that turn.
  public var replacesFailedTurn: Bool?
  /// Plan mode as it was when the task was held; nil (older files) means off.
  public var plan: Bool?
  public init(
    id: String = UUID().uuidString, threadID: String, prompt: String, provider: String,
    mode: String, projectID: String? = nil, model: String = "", effort: String = "medium",
    allowActions: Bool = false, allowProjectEdits: Bool = false, createdAt: Date = Date(),
    replacesFailedTurn: Bool? = nil, plan: Bool? = nil
  ) {
    self.id = id
    self.threadID = threadID
    self.prompt = prompt
    self.provider = provider
    self.mode = mode
    self.projectID = projectID
    self.model = model
    self.effort = effort
    self.allowActions = allowActions
    self.allowProjectEdits = allowProjectEdits
    self.createdAt = createdAt
    self.replacesFailedTurn = replacesFailedTurn
    self.plan = plan
  }
}

/// Tasks waiting for a connection, saved under the library (owner-only file) so they survive a quit.
public struct OfflineQueue: Codable, Equatable, Sendable {
  public static let path = "sessions/offline-tasks.json"
  public static let maxTasks = 20
  public private(set) var tasks: [PendingTask] = []
  public init() {}

  @discardableResult
  public mutating func add(_ task: PendingTask) -> Bool {
    let text = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, tasks.count < Self.maxTasks else { return false }
    var copy = task
    copy.prompt = text
    tasks.append(copy)
    return true
  }
  public mutating func cancel(_ id: String) { tasks.removeAll { $0.id == id } }
  /// Moves a task to another thread, when the user sends it from there.
  public mutating func retarget(_ id: String, thread: String) {
    if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].threadID = thread }
  }
  /// The oldest task first, so a reconnect sends in the order the user wrote them.
  public var next: PendingTask? { tasks.min { $0.createdAt < $1.createdAt } }
  public mutating func take(_ id: String) -> PendingTask? {
    guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
    return tasks.remove(at: i)
  }

  public static func load(from library: Library) -> OfflineQueue {
    library.load(OfflineQueue.self, from: path) ?? OfflineQueue()
  }
  public func save(to library: Library) throws { try library.save(self, to: Self.path) }
}

public enum SendGate: Equatable, Sendable {
  case sendNow, holdOffline

  /// A task goes out now only when the network is up. A missing or signed-out CLI is a setup
  /// problem and keeps its own error rather than waiting.
  public static func decide(online: Bool) -> SendGate { online ? .sendNow : .holdOffline }

  /// True when a failed run's error reads like a lost connection, so retrying later may work.
  public static func looksOffline(_ error: String?) -> Bool {
    guard let text = error?.lowercased(), !text.isEmpty else { return false }
    let markers = [
      "enotfound", "econnrefused", "econnreset", "etimedout", "enetunreach", "network is unreachable",
      "network connection", "internet connection", "offline", "could not resolve host",
      "failed to connect", "unable to connect", "connection refused", "connection reset",
      "dns error", "error sending request",
    ]
    return markers.contains { text.contains($0) }
  }
}
