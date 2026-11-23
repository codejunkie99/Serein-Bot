#if DEBUG
import Foundation
import SereinCore

/// Contracts built in checks name no live proxy: port 9 (discard) answers nothing.
extension ShellNetwork.Plan {
  static let open = ShellNetwork.Plan(port: 9)
}

/// The task-shell network is open through the thread's proxy (owner, 2026-11-18). The guard is wired in `engineShellGuard`.
extension AssistantCoreChecks {
  static func shellNetwork(_ check: Check) throws {
    try check(
      AgentFileGuard.toml(ShellNetwork.codexNetwork)
        == #"{ "enabled" = true }"#,
      "Codex's shell network is on; its shells get the proxy through the shell environment policy")
  }
}
#endif
