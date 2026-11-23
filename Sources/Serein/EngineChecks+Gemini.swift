#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

extension AssistantCoreChecks {
  static func geminiEngine(_ check: Check) throws {
    let driver = GeminiDriver()
    let rig = try ACPCheckRig(driver, name: "gemini")
    defer { try? rig.finish() }

    let full = try driver.contract(
      for: rig.request("hi", thread: "c", level: .full, model: "gemini-3-pro"), network: .open)
    try check(full.arguments == ["--yolo", "--acp", "-m", "gemini-3-pro"], "Gemini: Full launches `--yolo --acp` with the model on argv")
    let asks = try driver.contract(for: rig.request("hi", thread: "c", level: .commands), network: .open)
    try check(asks.arguments == ["--approval-mode", "default", "--acp"], "Gemini: below Full it asks and Serein's grant answers")

    try acpBehaviour(check, rig: rig, setsModel: false, modelRefusalEnds: false, stableInPrompt: true)
    try check(rig.log("config").isEmpty, "Gemini: the model is never set over the wire")
    try acpModeRefused(check, rig: rig, drop: "--approval-mode")
  }
}
#endif
