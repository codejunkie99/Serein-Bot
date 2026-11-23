#if DEBUG
import Foundation
import SereinCore

/// A task Serein delegates starts on its own (RelayToolHost.startPermission) and then keeps the level
/// saved on its thread (sendPermission); the assistant never names a level.
extension AssistantCoreChecks {
  static func delegatedAccess(_ check: Check) throws {
    func level(_ saved: RunPermissionMode?, edits: Bool = true, confirmed: Bool = true) -> RunPermissionMode {
      RelayToolHost.sendPermission(saved: saved?.rawValue, edits: edits, fullAccessConfirmed: confirmed)
    }
    try check(
      RunPermissionMode.allCases.allSatisfy { level($0) == $0 },
      "New instructions to a delegated project task keep the level the person saved on its thread")
    try check(
      level(nil) == .supervised && RelayToolHost.sendPermission(saved: "made-up", edits: true, fullAccessConfirmed: true) == .supervised,
      "A delegated thread with no level the person chose works Supervised")
    try check(
      level(.fullAccess, confirmed: false) == .supervised && level(.auto, confirmed: false) == .auto,
      "Full access never results without the project's one-time confirmation")
    try check(
      RunPermissionMode.allCases.allSatisfy { level($0, edits: false) == .supervised },
      "A task approved to only read stays Supervised, whatever its thread says")
    try check(
      RelayToolHost.startPermission(edits: true, fullAccessConfirmed: true) == .fullAccess
        && RelayToolHost.startPermission(edits: true, fullAccessConfirmed: false) == .auto,
      "A new delegated project task works on its own: Full access once confirmed for the project, else Auto")
    try check(
      RelayToolHost.startPermission(edits: false, fullAccessConfirmed: true) == .supervised,
      "A delegated task started read-only stays Supervised")
    let start = RelayTools.tools.first { $0["name"] as? String == "agent_start" }
    let send = RelayTools.tools.first { $0["name"] as? String == "agent_send" }
    let named = [start, send].compactMap { (($0?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys }
      .joined().filter { ["permission", "access", "level", "full_access"].contains($0) }
    try check(start != nil && send != nil && named.isEmpty, "agent_start and agent_send have no argument that sets a task's level")
  }
}
#endif
