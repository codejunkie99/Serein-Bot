#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// Claude Code's file guard (`AgentFileGuard.claudeArguments`, which ClaudeDriver applies) closes
  /// every protected folder to reads, and Serein's own data to reads, edits and the shell.
  @MainActor static func fileGuard(browser: BrowserModel) async throws -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var failures: [String] = []
    // A Project task in the home folder with edits and commands, as AgentModel.send builds it:
    // Serein's own data gets Read and Edit denies (folder and exact path, both spellings), and the
    // shell can neither read nor write it.
    let roots = AgentFileGuard.sereinPrivateRoots(home: home, library: browser.library.root)
    let tools = "Read,Glob,Grep,Edit,Write,Bash"
    let project = AgentFileGuard.claudeArguments(
      ["--print", "--tools", tools, "--allowedTools", "mcp__serein_browser," + tools, "--settings", "{\"disableAllHooks\":true}"],
      folders: [home], commands: true, runtimeDirectory: URL(fileURLWithPath: "/private/tmp/serein-cli-check"), privateRoots: roots)
    let settings = project.firstIndex(of: "--settings").flatMap { i in
      (try? JSONSerialization.jsonObject(with: Data(project[i + 1].utf8))) as? [String: Any]
    } ?? [:]
    let deny = Set((settings["permissions"] as? [String: Any])?["deny"] as? [String] ?? [])
    let filesystem = (settings["sandbox"] as? [String: Any])?["filesystem"] as? [String: Any] ?? [:]
    let denyRead = Set(filesystem["denyRead"] as? [String] ?? [])
    let denyWrite = Set(filesystem["denyWrite"] as? [String] ?? [])
    for path in AgentFileGuard.protectedPaths(home: home) where !deny.contains("Read(/\(path)/**)") {
      failures.append("protected folder \(path)")
    }
    for root in roots {
      for path in Set([AgentFileGuard.claudePhysicalPath(root), root.standardizedFileURL.path]) {
        let rules = ["Read", "Edit"].flatMap { ["\($0)(/\(path)/**)", "\($0)(/\(path))"] }
        if !rules.allSatisfy(deny.contains) || !denyRead.contains(path) || !denyWrite.contains(path) {
          failures.append("project in the home folder: \(path)")
        }
      }
    }
    if !failures.isEmpty {
      throw SereinError.invalid(
        "FAIL: Claude Read deny list is incomplete for " + failures.joined(separator: ", "))
    }
    // One line, as verify.py counts the PASS lines.
    return [
      "PASS: Claude Read deny list covers mail, messages, browser data, SSH keys and keychains in every mode, and Serein's own data for reads, edits and the shell"
    ]
  }
}
#endif
