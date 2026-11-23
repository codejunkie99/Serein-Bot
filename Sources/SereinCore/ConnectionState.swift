import Foundation

/// The one plain state a connection shows, wherever it shows: an app's MCP server in Settings ›
/// Connections, a tile in Connect apps, a Composio account. Pure, so checked in AssistantCoreChecks.
///
/// Rules:
/// - Only a passing test turns a connection on. Turning on starts a test (`testing`); the test is
///   the server's own tool list, never a call that sends, writes or deletes. Only `testPassed`
///   reaches `working`.
/// - A failed test leaves it saved and needing attention, with the reason.
/// - A connection brought in by import arrives off, and turns on only through a test.
public enum ConnectionState: Equatable, Sendable {
  case notSetUp
  case testing
  case working
  case needsAttention(reason: String)
  case off

  public enum Event: Equatable, Sendable {
    /// The person set it up: its first test runs.
    case added
    /// It came in by import: off until the person turns it on.
    case imported
    case turnOn
    case testPassed
    case testFailed(reason: String)
    /// Something went wrong while it was on or off: signed out, its tools changed.
    case problem(reason: String)
    case turnOff
    case removed
  }
  public enum Action: CaseIterable, Sendable { case setUp, turnOn, turnOff, review, remove }

  /// The next state. An event that does not fit changes nothing, so a test result that comes
  /// after the person turned it off does not turn it on.
  public func next(_ event: Event) -> ConnectionState {
    switch (self, event) {
    case (.notSetUp, .added): return .testing
    case (.notSetUp, .imported): return .off
    case (_, .turnOn) where allows(.turnOn): return .testing
    case (.testing, .testPassed): return .working
    case (.testing, .testFailed(let reason)): return .needsAttention(reason: Self.plain(reason))
    case (.notSetUp, .problem), (.testing, .problem): return self
    case (_, .problem(let reason)): return .needsAttention(reason: Self.plain(reason))
    case (_, .turnOff) where allows(.turnOff): return .off
    case (_, .removed) where self != .notSetUp: return .notSetUp
    default: return self
    }
  }

  /// Which state allows which action. Nothing waits on a running test.
  public func allows(_ action: Action) -> Bool {
    switch (self, action) {
    case (.notSetUp, .setUp): return true
    case (.off, .turnOn), (.needsAttention, .turnOn): return true
    case (.working, .turnOff), (.needsAttention, .turnOff): return true
    case (.working, .review), (.off, .review), (.needsAttention, .review): return true
    case (.working, .remove), (.off, .remove), (.needsAttention, .remove): return true
    default: return false
    }
  }

  /// The state from what is kept for an added connection: a test running, a problem, on.
  public static func of(on: Bool, testing: Bool, problem: String?) -> ConnectionState {
    if testing { return .testing }
    if let problem { return .needsAttention(reason: plain(problem)) }
    return on ? .working : .off
  }

  public var title: String {
    switch self {
    case .notSetUp: return "Not set up"
    case .testing: return "Testing"
    case .working: return "Working"
    case .needsAttention: return "Needs attention"
    case .off: return "Off"
    }
  }
  /// The title, with the reason when it needs attention.
  public var line: String {
    if case .needsAttention(let reason) = self { return "\(title): \(reason)" }
    return title
  }
  public var needsAttention: Bool {
    if case .needsAttention = self { return true }
    return false
  }

  public static let unknownReason = "Something went wrong. Try again."
  /// A reason as one plain line of at most 140 characters, without hidden characters or
  /// anything that looks like a secret.
  static func plain(_ raw: String) -> String {
    let line = AgentPrivacy.redact(ConnectLink.oneLine(raw), limit: 140).trimmingCharacters(in: .whitespaces)
    return line.isEmpty ? unknownReason : line
  }
}
