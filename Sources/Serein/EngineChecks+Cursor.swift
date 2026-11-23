#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

extension AssistantCoreChecks {
  static func cursorEngine(_ check: Check) throws {
    let driver = CursorDriver()
    let rig = try ACPCheckRig(driver, name: "cursor-agent")
    defer { try? rig.finish() }

    let full = try driver.contract(for: rig.request("hi", thread: "c", level: .full), network: .open)
    try check(full.arguments == ["--force", "--sandbox", "disabled", "--approve-mcps", "acp"], "Cursor: Full launches `--force` before `acp`")
    let asks = try driver.contract(for: rig.request("hi", thread: "c", level: .commands), network: .open)
    try check(asks.arguments == ["--sandbox", "disabled", "--approve-mcps", "acp"], "Cursor: below Full it asks and Serein's grant answers")
    let guardLines = full.sandboxProfile?.split(separator: "\n") ?? []
    try check(guardLines.contains { $0.contains("(deny file-read*") && $0.contains("/.ssh\"") && !$0.contains("/.cursor\"") }
      && guardLines.last?.hasPrefix("(allow file-read* (literal") == true && guardLines.last?.hasSuffix("/Library/Keychains/login.keychain-db\"))") == true,
      "Cursor: the file guard closes other sign-ins but leaves its own home open and the login keychain readable")

    try acpBehaviour(check, rig: rig, setsModel: true, modelRefusalEnds: true, stableInPrompt: true)
    try check(rig.log("init").contains(#""parameterizedModelPicker": true"#), "Cursor: initialize asks for the full model picker")
    try acpModeRefused(check, rig: rig, drop: "--sandbox")
    let noLoad = try ACPCheckRig(driver, name: "cursor-agent", noLoad: true)
    defer { try? noLoad.finish() }
    try acpNoLoad(check, rig: noLoad)
  }
}
#endif
