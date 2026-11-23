#if DEBUG
import Foundation
import SereinCore

/// `--verify-linked-codex`: a real Codex chat that a Serein thread follows, with no window. The
/// other app is `codex exec` with the user's own Codex setup and two one-word requests (two small
/// model calls). The chat opens with its history in its folder; a later turn from the other app
/// shows up with no call from this check; that app's process counts as holding the chat; a send
/// then goes to Codex's own copy, which keeps the history. Both chats are archived at the end.
@MainActor func checkLinkedCodex() async throws {
  let fm = FileManager.default
  guard let path = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"],
    path.hasPrefix(fm.temporaryDirectory.path) || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"),
    (try? fm.contentsOfDirectory(atPath: path)) == [".serein-linked-check"]
  else { throw SereinError.invalid("Use a fresh temporary library that holds only .serein-linked-check.") }
  guard let codex = AgentModel.locate("codex") else { throw SereinError.invalid("Codex is not installed.") }
  func report(_ line: String) { print(line); fflush(stdout) }
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("FAIL: " + label) }
    report("PASS: " + label)
  }
  func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
    return condition()
  }
  let root = URL(fileURLWithPath: path)
  let folder = root.appendingPathComponent("linked-folder").resolvingSymlinksInPath()
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  browser.projects.append(Project(name: "linked-folder", path: folder.path, source: .added))
  let agent = AgentModel(browser: browser, discoverProviders: false)
  agent.pin(.codex, executable: codex)

  /// `codex exec` as another app would run it. Returns the chat id at its first event and the
  /// process, which ends with the turn.
  /// A run started through a shell that exits at once: launchd adopts it, so it is not one of
  /// Serein's own processes (which Serein leaves out), as with a real other app.
  struct OtherRun {
    var pid: pid_t
    var output: URL
    var running: Bool { kill(pid, 0) == 0 }
    var events: [[String: Any]] {
      ((try? String(contentsOf: output, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    }
    var completed: Bool { events.contains { $0["type"] as? String == "turn.completed" } }
  }
  func otherApp(_ arguments: [String]) async throws -> (String, OtherRun) {
    let output = root.appendingPathComponent("other-\(UUID().uuidString).jsonl")
    let command = ([codex, "exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "-C", folder.path] + arguments)
      .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "\(command) > '\(output.path)' 2>/dev/null < /dev/null & echo $!"]
    shell.environment = CodexAppServer.environment(codex)
    let pipe = Pipe()
    shell.standardOutput = pipe
    try shell.run()
    shell.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw SereinError.invalid("codex exec did not start.")
    }
    let run = OtherRun(pid: pid, output: output)
    var id: String?
    _ = await until(60) {
      id = run.events.first { $0["type"] as? String == "thread.started" }?["thread_id"] as? String
      return id != nil || !run.running
    }
    guard let id else { throw SereinError.invalid("codex exec started no chat.") }
    return (id, run)
  }
  func finished(_ run: OtherRun) async -> Bool { await until(180) { !run.running } && run.completed }

  // 1. The other app's chat opens with its history, in the folder it ran in.
  let (id, first) = try await otherApp(["Reply with the single word ready."])
  var copy: String?
  func archive() async {
    for thread in [id] + (copy.map { [$0] } ?? []) {
      _ = try? await CodexAppServer.shared(codex).request("thread/archive", ["threadId": thread])
    }
  }
  func linkedSteps() async throws {
  try check(await finished(first), "The other app finished its first turn")
  agent.openLinked(SessionLink(driver: HarnessDriver.codex.rawValue, nativeID: id))
  let opened = await until(20) { agent.link?.nativeID == id && agent.messages.count >= 2 }
  try check(
    opened && agent.nativeSessionID == id && agent.mode == .project
      && browser.projects.first { $0.id == agent.projectID }?.path == folder.path
      && agent.messages.first?.text == "Reply with the single word ready."
      && agent.messages.last?.role == "assistant" && agent.messages.last?.text.lowercased().contains("ready") == true,
    "A Codex chat opens as a Serein thread with its history, in its folder")
  try check(
    agent.conversations.first { $0.link?.nativeID == id }?.scope == AgentModel.adoptScope(.codex)
      && !agent.allowProjectEdits && !agent.allowActions,
    "The thread keeps the native chat for its first send and starts read-only")
  let shown = agent.messages.count

  let file = try await LinkedSessionMonitor.read(id, executable: codex).path
  try check(file.map { fm.fileExists(atPath: $0) } == true, "Codex names the chat's file, and it exists")

  // 2. A turn the other app adds shows up by itself, and its process holds the chat.
  let (_, second) = try await otherApp(["resume", id, "Reply with the single word again."])
  let executables: [HarnessDriver: String] = [.codex: codex]
  // Found by the open file alone: a Codex process that is not an app server.
  var byFile = false
  var readWorking = false
  while second.running {
    if !byFile {
      byFile = await Task.detached {
        HarnessProcessDiscovery.snapshot(executables: executables).contains {
          !$0.arguments.contains("app-server") && !$0.executable.contains("/ChatGPT.app/")
            && LinkedSessionMonitor.holds($0, file: file, executables: executables)
        }
      }.value
    }
    // Codex's own answer, apart from the watch's timing: does a read show the turn as running?
    if !readWorking, let now = try? await LinkedSessionMonitor.read(id, executable: codex) { readWorking = now.working }
    try? await Task.sleep(nanoseconds: 200_000_000)
  }
  try check(await finished(second), "The other app finished its second turn")
  let followed = await until(10) {
    agent.messages.count >= shown + 2 && agent.messages.last?.text.lowercased().contains("again") == true
  }
  try check(followed, "A turn from the other app shows in the thread with no refresh from Serein")
  // The thread's "working" line comes from the session's log (ExternalSessionStore), not this read.
  report("NOTE: during the other app's turn, Codex's read showed it running: \(readWorking ? "yes" : "no")")
  try check(byFile, "A Codex process with the chat's file open counts as holding the chat")

  // 3. A send while another Codex process may hold the chat goes to Codex's own copy.
  let before = agent.messages.map(\.text)
  if await LinkedSessionMonitor.heldElsewhere(path: file, executables: executables) {
    let go = await agent.linked.prepareSend(SessionLink(driver: HarnessDriver.codex.rawValue, nativeID: id), executable: codex, cwd: folder.path)
    copy = agent.link?.nativeID
    try check(
      go && copy != nil && copy != id && agent.nativeSessionID == copy,
      "A send goes on in a Codex copy while another app may hold the chat (error: \(agent.error ?? "none"))")
    let copied = try await LinkedSessionMonitor.read(copy!, executable: codex).messages.map(\.text)
    try check(copied == before, "The copy keeps the whole chat")
  } else {
    report("NOTE: no Codex process outside Serein holds the chat now, so a send keeps the same chat")
    try check(await agent.linked.prepareSend(SessionLink(driver: HarnessDriver.codex.rawValue, nativeID: id), executable: codex, cwd: folder.path) && agent.link?.nativeID == id,
      "With no other holder, a send keeps the same chat")
  }
  }

  do {
    try await linkedSteps()
    await archive()
  } catch {
    await archive()
    throw error
  }
}

/// `--verify-linked-claude`: a real Claude Code chat that a Serein thread follows, with no window.
/// The other app is `claude -p` started outside Serein, with two one-word requests; Serein then
/// sends one on the same chat and one on a copy (four small model calls in all). The test chats'
/// transcripts are removed at the end; they live in the project folder of the temporary folder.
@MainActor func checkLinkedClaude() async throws {
  let fm = FileManager.default
  guard let path = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"],
    path.hasPrefix(fm.temporaryDirectory.path) || path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"),
    (try? fm.contentsOfDirectory(atPath: path)) == [".serein-linked-check"]
  else { throw SereinError.invalid("Use a fresh temporary library that holds only .serein-linked-check.") }
  guard let claude = AgentModel.locate("claude") else { throw SereinError.invalid("Claude Code is not installed.") }
  func report(_ line: String) { print(line); fflush(stdout) }
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("FAIL: " + label) }
    report("PASS: " + label)
  }
  func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 200_000_000) }
    return condition()
  }
  let root = URL(fileURLWithPath: path)
  let folder = root.appendingPathComponent("linked-folder").resolvingSymlinksInPath()
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  let browser = try BrowserModel(root: root)
  defer { browser.shutdown() }
  browser.projects.append(Project(name: "linked-folder", path: folder.path, source: .added))
  browser.saveProjects()
  let agent = AgentModel(browser: browser, discoverProviders: false)
  agent.pin(.claude, executable: claude)
  // Serein runs Claude Code in a project only once it knows the CLI's version (no model call).
  HarnessRegistry.shared.probesEnabled = true
  await HarnessRegistry.shared.refresh(.claude, includeDisabled: true, force: true)

  /// `claude -p` from a shell that exits at once, so it is not one of Serein's processes.
  func otherApp(_ arguments: [String]) async throws -> String {
    let output = root.appendingPathComponent("other-\(UUID().uuidString).json")
    let command = ([claude, "-p", "--output-format", "json"] + arguments)
      .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "cd '\(folder.path)' && \(command) > '\(output.path)' 2>/dev/null < /dev/null & echo $!"]
    let pipe = Pipe()
    shell.standardOutput = pipe
    try shell.run()
    shell.waitUntilExit()
    guard let pid = pid_t(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SereinError.invalid("claude -p did not start.") }
    _ = await until(180) { kill(pid, 0) != 0 }
    // Claude Code 2.1.301 prints a JSON array of events; older versions print one object.
    let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    guard let range = text.range(of: #""session_id"\s*:\s*"([0-9a-f-]{36})""#, options: .regularExpression),
      let id = text[range].split(separator: "\"").last.map(String.init)
    else { throw SereinError.invalid("claude -p gave no session id.") }
    return id
  }
  func transcript(_ file: String?) -> String { file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "" }

  // 1. The other app's chat opens with its history, in the folder it ran in.
  let id = try await otherApp(["Reply with the single word ready."])
  let file = LinkedSessionMonitor.claudeTranscript(id)
  defer {
    // Only the transcript folder of this check's own temporary folder is removed.
    if let file {
      let dir = URL(fileURLWithPath: file).deletingLastPathComponent()
      // It is the folder for this check's temporary folder: named for it, and its transcript ran there.
      if dir.lastPathComponent.hasSuffix("-linked-folder"),
        dir.deletingLastPathComponent().path == NSHomeDirectory() + "/.claude/projects",
        transcript(file).contains("\"cwd\":\"\(folder.path)\"")
      { try? fm.removeItem(at: dir) }
    }
  }
  try check(file != nil, "The other app's chat has its transcript in Claude Code's projects folder")
  agent.openLinked(SessionLink(driver: HarnessDriver.claude.rawValue, nativeID: id, file: file))
  let opened = await until(20) { agent.link?.nativeID == id && agent.messages.count >= 2 }
  try check(
    opened && agent.provider == .claude && agent.nativeSessionID == id && agent.mode == .project
      && browser.projects.first { $0.id == agent.projectID }?.path == folder.path
      && agent.messages.first?.text == "Reply with the single word ready."
      && agent.messages.last?.text.lowercased().contains("ready") == true && agent.link?.file == file,
    "A Claude Code chat opens as a Serein thread with its history, in its folder")
  let shown = agent.messages.count

  // 2. A turn the other app adds shows up by itself.
  let resumed = try await otherApp(["--resume", id, "Reply with the single word again."])
  report("NOTE: claude -p --resume kept the chat's id: \(resumed == id ? "yes" : "no, it reported \(resumed)")")
  let followed = await until(15) {
    agent.messages.count >= shown + 2 && agent.messages.last?.text.lowercased().contains("again") == true
  }
  try check(followed, "A turn from the other app shows in the thread with no refresh from Serein")

  // 3. Who holds a chat: Claude Code's own list of open sessions.
  let environment = HarnessRegistry.shared.environment(.claude, executable: claude)
  let listed = HarnessProbe.runSync(claude, ["agents", "--json"], environment: environment, timeout: 8).output
  let open = listed.range(of: "[").flatMap {
    try? JSONSerialization.jsonObject(with: Data(listed[$0.lowerBound...].utf8)) as? [[String: Any]]
  }?.first { $0["state"] as? String != "done" }?["sessionId"] as? String
  if let open {
    try check(await LinkedSessionMonitor.claudeHeld(open, executable: claude, environment: environment, cwd: nil),
      "A chat that Claude Code lists as open counts as held")
  } else {
    report("NOTE: Claude Code lists no open session now, so the held case was not checked")
  }
  try check(!(await LinkedSessionMonitor.claudeHeld(id, executable: claude, environment: environment, cwd: folder.path)),
    "A chat that no Claude Code holds is not held")

  // 4. A Serein send continues the same chat; the other app's file gets the turn.
  agent.allowProjectEdits = false
  agent.draft = "Reply with the single word third."
  agent.send()
  let third = await until(240) { !agent.running && agent.messages.last?.text.lowercased().contains("third") == true }
  try check(
    third && agent.nativeSessionID == id && agent.link?.nativeID == id && transcript(file).contains("single word third"),
    "A send from Serein continues the same Claude Code chat (error: \(agent.error ?? "none"))")

  // 5. When another app holds the chat, the send goes on in a copy and the original is unchanged.
  agent.forkLinkedNext = true
  agent.draft = "Reply with the single word fourth."
  agent.send(linkChecked: true)
  let fourth = await until(240) { !agent.running && agent.messages.last?.text.lowercased().contains("fourth") == true }
  let copy = agent.link
  try check(
    fourth && copy?.nativeID != id && agent.nativeSessionID == copy?.nativeID && !agent.forkLinkedNext
      && transcript(copy?.file).contains("single word fourth") && transcript(copy?.file).contains("single word third")
      && !transcript(file).contains("single word fourth"),
    "A send to a held chat goes on in a Claude Code copy, and the original is unchanged (error: \(agent.error ?? "none"))")
}
#endif
