
import Darwin
import Foundation

/// One rung of ending a CLI. The MCP servers and tools a CLI starts stay behind unless the whole
/// group is signalled, so the signal rungs always go to the group.
enum StopStep: Sendable, Equatable {
  case closeInput
  case wait(Duration)
  case termGroup
  case killGroup
}

typealias Sleep = @Sendable (Duration) async -> Void

enum StopLadder {
  /// End of input first, as a close does, then TERM and KILL to the group.
  static let standard: [StopStep] = [.closeInput, .wait(.milliseconds(500)), .termGroup, .wait(.milliseconds(1_500)), .killGroup]

  /// Stops early once the group is gone, so a CLI that leaves on end of input is never signalled.
  static func run(_ steps: [StopStep], on process: any HostedProcess, sleep: Sleep) async {
    for step in steps {
      if step != .closeInput, !process.groupAlive { return }
      switch step {
      case .closeInput: process.closeInput()
      case .wait(let duration): await sleep(duration)
      case .termGroup: process.signalGroup(SIGTERM)
      case .killGroup: process.signalGroup(SIGKILL)
      }
    }
  }
}
