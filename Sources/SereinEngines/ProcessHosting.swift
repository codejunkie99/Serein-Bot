import Darwin
import Foundation

/// Starts a CLI. The real host goes through serein-process-host; checks pass a fake.
protocol ProcessHosting: Sendable {
  func spawn(_ contract: LaunchContract) throws -> any HostedProcess
}

/// One started CLI and the group it leads.
protocol HostedProcess: AnyObject, Sendable {
  /// Taken at spawn, so a stop never has to look it up after the leader has exited.
  var pgid: pid_t { get }
  /// stdout as it arrives; finishes when the CLI closes it.
  var output: AsyncStream<Data> { get }
  func write(_ data: Data) throws
  func closeInput()
  func signalGroup(_ signal: Int32)
  /// True while any process of the group runs.
  var groupAlive: Bool { get }
  /// Resolves once the leader exits. Its stderr tail rides along for the failure message.
  func exited() async -> ProcessExit
}

struct ProcessExit: Sendable, Equatable {
  var status: Int32
  var signaled: Bool
  var stderr: String
}
