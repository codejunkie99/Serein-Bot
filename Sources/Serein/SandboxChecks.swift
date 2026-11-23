#if DEBUG
import Foundation
import SereinCore
import WebKit

/// `--verify-sandbox-helper`: under the Grok, Gemini CLI and Pi sandbox
/// (AgentFileGuard.ownSetupProfile, which also closes cfprefsd), Serein's browser helper still
/// lists the task's tabs and reads a page, and each installed harness still starts (ACP initialize
/// for Grok and Gemini CLI, --version for Pi). No window and no model call. The page comes
/// from SEREIN_FIXTURE_URL, so run it with scripts/verify.py's fixture server and proxy.
@MainActor func checkSandboxHelper() async throws {
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("FAIL: " + label) }
    print("PASS: " + label)
    fflush(stdout)
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("serein-sandbox-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  // The task works on its own copy of the current page, loaded again through the fixture proxy,
  // so the page comes from scripts/verify.py's fixture server.
  guard let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] else {
    throw SereinError.invalid("FAIL: Set SEREIN_FIXTURE_URL to scripts/verify.py's fixture server.")
  }
  let tab = browser.newTab()
  try tab.navigate(base + "form")
  for _ in 0..<100 where tab.title != "Form fixture" { try await Task.sleep(nanoseconds: 50_000_000) }
  let task = try browser.beginTask(isolated: false, allowActions: false, includeCurrent: true)
  defer { browser.endTask(task.capability.task) }
  for _ in 0..<100 where task.tabs.first?.title != "Form fixture" { try await Task.sleep(nanoseconds: 50_000_000) }
  let home = FileManager.default.homeDirectoryForCurrentUser
  let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("serein-browser-mcp").path
  let workspace = root.appendingPathComponent("Anywhere")
  try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  let profile = { (driver: HarnessDriver) in
    AgentFileGuard.ownSetupProfile(home: home, driver: driver, library: root, workspace: workspace)
  }

  // The helper as a harness's child: MCP over stdio, off the main actor so the browser can answer it.
  let file = task.file.path
  let (tabs, page) = try await Task.detached {
    let mcp = try StdioPeer("/usr/bin/sandbox-exec", ["-p", profile(.grok), helper, file], cwd: workspace)
    defer { mcp.stop() }
    _ = try mcp.call(1, "initialize", [
      "protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any],
      "clientInfo": ["name": "sandbox-check", "version": "1"],
    ])
    mcp.notify("notifications/initialized")
    let tabs = StdioPeer.text(try mcp.call(2, "tools/call", ["name": "tabs", "arguments": [:] as [String: Any]]))
    let id = tabs.firstMatch(of: #/"tab"\s*:\s*"([^"]+)"/#).map { String($0.1) } ?? ""
    let page = StdioPeer.text(try mcp.call(3, "tools/call", ["name": "read", "arguments": ["tab": id]]))
    return (tabs, page)
  }.value
  try check(tabs.contains("Form fixture"), "Under the sandbox the browser helper lists the task's tabs"
    + (tabs.contains("Form fixture") ? "" : " (got \(tabs.prefix(300)))"))
  try check(page.contains("Contact"), "Under the sandbox the browser helper reads a page"
    + (page.contains("Contact") ? "" : " (got \(page.prefix(300)))"))

  // Each installed harness starts under its own profile.
  let acp: [String: Any] = ["protocolVersion": 1, "clientCapabilities": [:] as [String: Any]]
  var starts: [(HarnessDriver, String, [String])] = [
    (HarnessDriver.grok, home.appendingPathComponent(".grok/bin/grok").path,
     HarnessPermissions.grokFlags(HarnessGrant(mode: "research", edits: false, permission: .supervised))
       + ["--disable-web-search", "agent", "--no-leader", "stdio"]),
  ]
  // Gemini CLI's ACP switch depends on its version: read from its help, as the probe does.
  let gemini = HarnessRegistry.locate(.gemini, override: nil, shellPath: nil) ?? ""
  if FileManager.default.isExecutableFile(atPath: gemini) {
    let help = try await Task.detached { try StdioPeer.run(gemini, ["--help"]) }.value.1
    if let args = HarnessParse.geminiACPArguments(help) { starts.append((.gemini, gemini, args)) }
  }
  for (driver, executable, args) in starts where FileManager.default.isExecutableFile(atPath: executable) {
    let sandbox = profile(driver)
    let reply = try await Task.detached {
      let peer = try StdioPeer("/usr/bin/sandbox-exec", ["-p", sandbox, executable] + args, cwd: workspace)
      defer { peer.stop() }
      return try peer.call(1, "initialize", acp)
    }.value
    try check(reply["result"] is [String: Any], "\(driver.rawValue) starts under the sandbox and answers ACP initialize")
  }
  let pi = "/opt/homebrew/bin/pi"
  if FileManager.default.isExecutableFile(atPath: pi) {
    let sandbox = profile(.pi)
    let (status, out) = try await Task.detached { try StdioPeer.run("/usr/bin/sandbox-exec", ["-p", sandbox, pi, "--version"]) }.value
    try check(status == 0 && !out.isEmpty, "pi starts under the sandbox")
  }
}

/// A child process spoken to in newline-delimited JSON-RPC (MCP, ACP). ponytail: a read blocks
/// until the child writes; the caller's timeout (the check runner's) covers a child that hangs.
final class StdioPeer: @unchecked Sendable {
  let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private var buffer = Data()
  init(_ executable: String, _ arguments: [String], cwd: URL) throws {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
  }
  func stop() { if process.isRunning { process.terminate() } }
  func notify(_ method: String) {
    send(["jsonrpc": "2.0", "method": method])
  }
  /// The response to this request; requests and notifications from the child in between are skipped.
  func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
    send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    while true {
      while let newline = buffer.firstIndex(of: 10) {
        let line = buffer[..<newline]
        buffer.removeSubrange(...newline)
        if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          message["method"] == nil, message["id"] as? Int == id
        { return message }
      }
      let chunk = output.fileHandleForReading.availableData
      guard !chunk.isEmpty else { throw SereinError.invalid("FAIL: \(method): the process ended without an answer") }
      buffer.append(chunk)
    }
  }
  private func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    input.fileHandleForWriting.write(data + Data([10]))
  }
  /// The text of an MCP tool result.
  static func text(_ response: [String: Any]) -> String {
    let content = (response["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
  }
  static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
#endif
