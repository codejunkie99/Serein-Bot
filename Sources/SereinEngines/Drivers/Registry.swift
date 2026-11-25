import Foundation
import OSLog
import SereinCore

/// Every CLI driver. Add one line per driver file in this folder.
enum DriverRegistry {
  static let builtIn: [any Driver] = [
    ClaudeDriver(),
    CodexDriver(),
    PiDriver(cli: .pi), PiDriver(cli: .ohMyPi),
    CursorDriver(),
    GrokDriver(),
    GeminiDriver(),
    OpenCodeDriver(),
  ]

  /// The built-ins, with each ACP agent in the data folder's `acp-agents.json` in place of its
  /// app's built-in driver. Read once per launch; refused entries go to the log.
  static let all: [any Driver] = {
    let loaded = drivers(loading: AgentAccess.defaultRoot)
    let log = Logger(subsystem: "app.serein", category: "drivers")
    for reason in loaded.refused { log.error("\(reason, privacy: .public)") }
    return loaded.drivers
  }()

  static func drivers(loading folder: URL) -> (drivers: [any Driver], refused: [String]) {
    let (specs, refused) = ACPAgentSpec.load(from: folder)
    let configured: [any Driver] = specs.map { GenericACPDriver($0) }
    return (configured + builtIn.filter { driver in !specs.contains { $0.cli == driver.cli } }, refused)
  }
}
