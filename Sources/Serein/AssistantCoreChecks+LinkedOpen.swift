#if DEBUG
import Foundation
import SereinCore

extension AssistantCoreChecks {
  static func linkedOpen(_ check: Check) throws {
    let lines = [
      #"{"type":"permission-mode","permissionMode":"default","sessionId":"s1"}"#,
      #"{"type":"system","subtype":"local_command","content":"/model","cwd":"/Users/me/sargassum","sessionId":"s1"}"#,
      #"{"type":"last-prompt","lastPrompt":"","sessionId":"s1"}"#,
    ]
    let empty = LinkedHistory.claude(Data(lines.joined(separator: "\n").utf8))
    try check(empty.cwd == "/Users/me/sargassum" && empty.messages.isEmpty,
      "A Claude Code chat with no messages yet still opens in the folder its other lines name")
  }
}
#endif
