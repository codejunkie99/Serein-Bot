#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// `acp-agents.json` in the data folder: a good entry reaches the driver lookup as a
/// `GenericACPDriver`, a bad one is refused with its reason and never drops the good ones.
extension AssistantCoreChecks {
  static func acpRegistry(_ check: Check) throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("acp-registry-\(UUID().uuidString)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let file = folder.appendingPathComponent(ACPAgentSpec.configFile)
    let builtIn = DriverRegistry.builtIn.map(\.cli)
    func lookup(_ drivers: [any Driver], _ cli: HarnessDriver) -> (any Driver)? { drivers.first { $0.cli == cli } }

    let none = DriverRegistry.drivers(loading: folder)
    try check(
      none.drivers.map(\.cli) == builtIn && none.refused.isEmpty && !none.drivers.contains { $0 is GenericACPDriver },
      "With no acp-agents.json the drivers are the built-in list, unchanged")
    if !fm.fileExists(atPath: AgentAccess.defaultRoot.appendingPathComponent(ACPAgentSpec.configFile).path) {
      try check(DriverRegistry.all.map(\.cli) == builtIn, "The app's registry is the built-in list when its data folder has no acp-agents.json")
    }

    try #"""
    [
      {"cli": "grok", "arguments": [], "cardWaitSeconds": 90},
      {"cli": "kimi", "arguments": ["acp"]},
      {"cli": "claude", "arguments": ["acp"]},
      {"cli": "gemini", "arguments": ["--experimental-acp", "--fast"], "cardWaitSeconds": 120,
       "model": "onArgv", "modelFlag": "--model", "steerMethod": "session/steer"},
      {"cli": "cursor", "arguments": ["acp"], "cardWaitSeconds": -5},
      {"cli": "opencode", "arguments": ["acp"], "cardwait": 5},
      {"cli": "gemini", "arguments": ["acp"]},
      {"cli": "cursor", "arguments": ["acp"], "cardWaitSeconds": 1e300},
      "grok"
    ]
    """#.write(to: file, atomically: true, encoding: .utf8)
    let loaded = DriverRegistry.drivers(loading: folder)
    let gemini = lookup(loaded.drivers, .gemini) as? GenericACPDriver
    try check(
      gemini?.spec == ACPAgentSpec(
        cli: .gemini, arguments: ["--experimental-acp", "--fast"], cardWait: .seconds(120),
        model: .onArgv, modelFlag: "--model", steerMethod: "session/steer"),
      "A valid acp-agents.json entry is found by the driver lookup as a GenericACPDriver with its own spec")
    let request = TurnRequest(
      thread: ThreadKey("acp-registry"), cli: .gemini, executable: URL(fileURLWithPath: "/usr/bin/true"),
      access: .answer, prompt: TurnPrompt(stable: "", volatile: "", message: "hi", recovery: nil),
      model: "gemini-3", effort: nil, resume: nil, browser: nil, taskID: "t")
    try check(
      try gemini?.contract(for: request, network: ShellNetwork.Plan(port: 0)).arguments
        == ["--experimental-acp", "--fast", "--model", "gemini-3"],
      "The configured agent launches with the arguments from its entry")
    try check(
      lookup(loaded.drivers, .grok) is GrokDriver && lookup(loaded.drivers, .cursor) is CursorDriver
        && lookup(loaded.drivers, .opencode) is OpenCodeDriver
        && loaded.drivers.map(\.cli).sorted { $0.rawValue < $1.rawValue } == builtIn.sorted { $0.rawValue < $1.rawValue },
      "A refused entry leaves its app on the built-in driver, and every app keeps exactly one driver")
    let expected: [(String, String)] = [
      ("entry 1 ", "arguments must be a list with at least one argument"),
      ("entry 2 ", "unknown cli \"kimi\""),
      ("entry 3 ", "Claude Code does not run over ACP"),
      ("entry 5 ", "cardWaitSeconds must be"),
      ("entry 6 ", "unknown field \"cardwait\""),
      ("entry 7 ", "gemini already has an entry above"),
      ("entry 8 ", "cardWaitSeconds must be"),
      ("entry 9 ", "not a JSON object"),
    ]
    try check(
      loaded.refused.count == expected.count
        && zip(loaded.refused, expected).allSatisfy { $0.contains($1.0) && $0.contains($1.1) },
      "Empty arguments, an unknown or non-ACP cli, bad durations, typos and repeats are each refused with a reason")

    try "{not json".write(to: file, atomically: true, encoding: .utf8)
    let broken = DriverRegistry.drivers(loading: folder)
    try check(
      broken.drivers.map(\.cli) == builtIn && broken.refused.count == 1 && broken.refused[0].contains("not a readable JSON list"),
      "An unreadable acp-agents.json is refused with a reason and the built-in drivers stay")
  }
}
#endif
