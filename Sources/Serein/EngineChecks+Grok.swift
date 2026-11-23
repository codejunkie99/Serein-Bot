#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

extension AssistantCoreChecks {
  static func grokEngine(_ check: Check) throws {
    let driver = GrokDriver()
    let rig = try ACPCheckRig(driver, name: "grok")
    defer { try? rig.finish() }

    let full = try driver.contract(for: rig.request("hi", thread: "c", level: .full), network: .open)
    try check(full.arguments.first == "--always-approve" && full.argv.suffix(3) == ["agent", "--no-leader", "stdio"],
      "Grok: Full launches `--always-approve ... agent --no-leader stdio`")
    try check(full.arguments.contains("--sandbox") && full.arguments[full.arguments.firstIndex(of: "--sandbox")! + 1] == "off",
      "Grok: its own sandbox is off under Serein's file guard")
    try check(full.environment["XAI_API_KEY"] == nil, "Grok: no xAI key in its env, so the subscription is used")
    try check(full.sandboxProfile != nil, "Grok: Serein's file guard holds it")
    let asks = try driver.contract(for: rig.request("hi", thread: "c", level: .commands), network: .open)
    try check(asks.argv.starts(with: ["--permission-mode", "acceptEdits"]), "Grok: below Full its mode flag leads")

    let again = try driver.contract(for: rig.request("hi", thread: "c", level: .full), network: .open)
    try check(again.warmKey == full.warmKey, "Grok: the same request gives the same warm key, file guard included")
    try acpBehaviour(check, rig: rig, setsModel: true, modelRefusalEnds: false, stableInPrompt: true)
    try check(rig.log("config").contains("session/set_config_option reasoning_effort") == false,
      "Grok: no effort asked, none set")
    try acpModeRefused(check, rig: rig, drop: "--permission-mode")
    let noLoad = try ACPCheckRig(driver, name: "grok", noLoad: true)
    defer { try? noLoad.finish() }
    try acpNoLoad(check, rig: noLoad)
  }
}
#endif
