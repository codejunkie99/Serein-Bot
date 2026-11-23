#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// Every harness Serein drives follows Claude Code's built-ins table: commands only in a project
/// with edits on under Auto or Full access, reads only in a project or the library, edits only in
/// a project with edits on. Harnesses that read without asking and have no switch for it get no
/// task at all.
extension AssistantCoreChecks {
  /// What ClaudeDriver lets Claude Code run unasked for `access`: `--allowedTools` and the
  /// settings' allow rules, each by tool name. Offered-but-denied tools (Review's Edit) are not in it.
  private static func claudeAllows(_ access: Access) throws -> [String] {
    let request = TurnRequest(
      thread: ThreadKey("builtins"), cli: .claude, executable: URL(fileURLWithPath: "/usr/bin/true"), access: access,
      prompt: TurnPrompt(stable: "", volatile: "", message: "", recovery: nil), model: nil, effort: nil, resume: nil,
      browser: nil, taskID: "builtins")
    let driver = ClaudeDriver(root: FileManager.default.temporaryDirectory.appendingPathComponent("serein-builtins"))
    let contract = try driver.contract(for: request, network: .open)
    try driver.prepare(contract, request: request)
    let args = contract.argv
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    // The settings go in a launch file (prepare); its allow rules hold the scoped file tools.
    let settings = value("--settings").flatMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: $0))) } as? [String: Any]
    let rules = (settings?["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
    return (value("--allowedTools") ?? "").split(separator: ",").map(String.init) + rules.map { String($0.prefix { $0 != "(" }) }
  }

  static func harnessBuiltIns(_ check: Check) throws {
    let folder = "/synthetic/builtins"
    let tasks: [String: TaskMode] = [
      "answer": .answer, "library": .library, "anywhere": .anywhere, "research": .research, "page": .page, "project": .project,
    ]
    for mode in HarnessPolicy.concreteModes {
      for edits in [false, true] {
        for permission in RunPermissionMode.allCases {
          let g = HarnessGrant(mode: mode, edits: edits, permission: permission)
          let shell = mode == "project" && edits && (permission == .auto || permission == .fullAccess)
          let reads = mode == "project" || mode == "library"
          let writes = mode == "project" && edits
          let label = "\(mode), edits \(edits), \(permission.rawValue)"

          let access = AgentModel.engineAccess(mode: tasks[mode]!, grant: g, initiator: nil, folder: URL(fileURLWithPath: folder))
          let claude = try claudeAllows(access)
          try check(
            claude.contains("Bash") == shell && claude.contains("Read") == reads && claude.contains("Edit") == writes,
            "Claude Code built-ins follow the table (\(label))")

          // Pi never asks, so the tool list PiDriver puts on argv for the turn's access is the whole policy.
          let pi = PiDriver.tools(access)
          try check(
            pi.contains("bash") == shell && pi.contains("read") == reads && pi.contains("edit") == writes
              && pi.contains("write") == writes,
            "Pi built-ins follow the table (\(label))")

          // OpenCode: what its config allows outright stays inside the table; the rest is asked
          // and answered by HarnessApprovals below.
          let open = HarnessPermissions.openCodeConfigPermission(g)
          try check(
            (open["bash"] != "allow" || shell) && (open["read"] == "allow") == reads
              && (open["edit"] != "allow" || writes) && open["webfetch"] == "deny" && open["websearch"] == "deny",
            "OpenCode's config allows nothing beyond the table (\(label))")

          // ACP harnesses (Cursor) and OpenCode ask; Serein answers by the same table.
          func allows(_ kind: HarnessPermissionRequest.Kind) -> Bool {
            HarnessApprovals.decide(
              HarnessPermissionRequest(id: "builtins", kind: kind, title: "check", paths: [folder + "/notes.txt"]),
              grant: g, folder: folder
            ).allow
          }
          try check(
            allows(.execute) == shell && allows(.read) == reads && allows(.edit) == writes && !allows(.fetch),
            "Asked commands, reads and edits are answered by the table (\(label))")
        }
      }
    }

    // Grok and Gemini stay offered for web, page, answer and Mac tasks with their own
    // setup on (the user's choice, kept on 2026-11-15), and never for file tasks.
    for driver in [HarnessDriver.grok, .gemini] {
      func allowed(_ mode: String) -> Bool {
        HarnessPolicy.verdict(
          driver: driver, capabilities: .base(driver), mode: mode, edits: mode == "project", permission: .supervised
        ).allowed
      }
      try check(
        allowed("research") && allowed("page") && allowed("answer") && allowed("anywhere")
          && !allowed("project") && !allowed("library"),
        "\(driver.displayName) is offered for web, page, answer and Mac tasks, never file tasks")
    }
    // Pi keeps web tasks, stays out of Anywhere, and thinks for Serein in its own turns.
    func pi(_ mode: String, relay: Bool = false) -> Bool {
      HarnessPolicy.verdict(
        driver: .pi, capabilities: .base(.pi), mode: mode, edits: false, permission: .supervised, relay: relay
      ).allowed
    }
    try check(pi("research") && !pi("anywhere") && pi("anywhere", relay: true), "Pi keeps web tasks, has no Anywhere task, and thinks for Serein")
    // OpenCode runs under the file guard at every level (EngineChecks+ACPGuard).
    func openCode(_ mode: String, edits: Bool) -> Bool {
      HarnessPolicy.verdict(
        driver: .opencode, capabilities: .base(.opencode), mode: mode, edits: edits, permission: .supervised
      ).allowed
    }
    try check(
      openCode("project", edits: true) && openCode("project", edits: false) && openCode("library", edits: false),
      "OpenCode takes Project and Library tasks under its file guard")
    try check(
      HarnessPolicy.verdict(
        driver: .claude, capabilities: .base(.claude), mode: "research", edits: false, permission: .fullAccess
      ).allowed,
      "A project permission never refuses a task outside a project")

    // Pi gets exactly the browser tools the turn lists, as its extension names them, and none without a browser.
    let piDriver = PiDriver(cli: .pi, files: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("serein-pi-builtins"))
    func piBrowserList(_ browser: BrowserServer?) throws -> String? {
      let request = TurnRequest(
        thread: ThreadKey("builtins"), cli: .pi, executable: URL(fileURLWithPath: "/usr/bin/true"), access: .web,
        prompt: TurnPrompt(stable: "", volatile: "", message: "", recovery: nil), model: nil, effort: nil, resume: nil,
        browser: browser, taskID: "builtins")
      let arguments = try piDriver.contract(for: request, network: .open).arguments
      return arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] }
    }
    let relayNames = ToolSchema.offered(["/synthetic/capability.json", "--relay"]).compactMap { $0["name"] as? String } + ["notes__add"]
    try check(
      try piBrowserList(BrowserServer(command: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], tools: relayNames))
        == relayNames.map { "serein_browser_" + $0 }.joined(separator: ",") && (try piBrowserList(nil)) == nil,
      "Pi gets every browser tool the turn lists and none without a browser")
  }
}
#endif
