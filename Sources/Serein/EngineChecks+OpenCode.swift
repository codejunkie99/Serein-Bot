#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

extension AssistantCoreChecks {
  static func openCodeEngine(_ check: Check) throws {
    let driver = OpenCodeDriver()
    let rig = try ACPCheckRig(driver, name: "opencode")
    defer { try? rig.finish() }

    func config(_ contract: LaunchContract) -> [String: Any] {
      let text = contract.environment["OPENCODE_CONFIG_CONTENT"] ?? ""
      return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    let full = try driver.contract(for: rig.request("hi", thread: "c", level: .full), network: .open)
    let fullPermission = config(full)["permission"] as? [String: Any] ?? [:]
    try check(full.arguments == ["acp"] && full.expectedMode == .reports(["mode": "build"]),
      "OpenCode: launches `acp` and reads back the build agent")
    try check(fullPermission["*"] as? String == "allow" && fullPermission["webfetch"] as? String == "deny"
      && fullPermission["external_directory"] as? String == "deny",
      "OpenCode: Full allows every tool but keeps the folder and web denies, so it never asks")
    try check(((config(full)["agent"] as? [String: Any])?["build"] as? [String: Any])?["prompt"] as? String == "STABLE-RULES",
      "OpenCode: the stable prompt rides in its config, not in a message")
    // OpenCode 2.2.4 reads OPENCODE_CONFIG_DIR instead of ~/.config/opencode, and no repo config
    // with OPENCODE_DISABLE_PROJECT_CONFIG: `opencode debug config` then lists neither one's MCP servers.
    let folder = OpenCodeDriver.configFolder
    let personal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode").path
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #"{"mcp":{"planted":{"type":"local","command":["/usr/bin/true"]}}}"#.write(
      to: folder.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
    try driver.prepare(full, request: rig.request("hi", thread: "c", level: .full))
    let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["unreadable"]
    try check(full.environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1" && full.environment["OPENCODE_CONFIG_DIR"] == folder.path
      && !folder.path.hasPrefix(personal) && left.isEmpty && config(full)["mcp"] == nil,
      "OpenCode: the person's and the repo's config never load, and Serein's own config folder starts empty, so no MCP server of theirs starts")
    let asks = try driver.contract(for: rig.request("hi", thread: "c", level: .review), network: .open)
    try check((config(asks)["permission"] as? [String: Any]).map { $0["*"] == nil } == true, "OpenCode: below Full there is no blanket allow")

    try acpBehaviour(check, rig: rig, setsModel: true, modelRefusalEnds: false, stableInPrompt: false)
    try check(rig.log("config").contains("session/set_config_option model"), "OpenCode: the model is set as its `model` option")
    let (allowed, _) = try rig.turn(rig.request("SHELLCALL", thread: "shell"))
    let (refused, _) = try rig.turn(rig.request("SHELLCALL", thread: "shell", level: .review))
    try check(allowed.contains(.permissionAnswered(allowed: true)) && refused.contains(.permissionAnswered(allowed: false))
      && !refused.contains { if case .declined = $0 { return true } else { return false } },
      "OpenCode: a command allowed once and one refused outside Project-mode edits both reach the history")
    try check(allowed.contains(.toolStarted(id: "t-sh", name: "shell", detail: "ls")),
      "OpenCode: a tool is named by its `name`, so a shell call titled \"ls\" is a command, not a read")
    try acpModeRefused(check, rig: rig, field: "mode", label: "another agent reported as the mode refuses the launch") {
      $0.expectedMode = .reports(["mode": "plan"])
    }
  }
}
#endif
