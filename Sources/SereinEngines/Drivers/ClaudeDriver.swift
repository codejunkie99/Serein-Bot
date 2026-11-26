import CryptoKit
import Darwin
import Foundation
import SereinCore
import UniformTypeIdentifiers

/// Claude Code over stream-json stdin: one process per thread serves many turns. Its mode is read
/// back with the `initialize` control request before any prompt goes in.
struct ClaudeDriver: Driver {
  let cli = HarnessDriver.claude
  let routesOwnShells = true
  /// Claude holds one MCP call open for `MCP_TOOL_TIMEOUT`, set a minute past this: 600 s,
  /// the secure card's bound (arena/SECURE-CARD.md).
  let cardWait: Duration = .seconds(540)
  var promptAddition: String {
    "Use several tool calls in one step whenever they do not depend on each other. Use Edit for small changes and Write only for new files or full rewrites. Run Bash for builds and tests yourself; do not ask the user to run them. If a tool is not on your list, use one that is to reach the same result rather than stopping. Keep going until the task is done; a turn that ends with work left in scope is a failure."
  }
  /// Serein's own launch files: settings, system prompt and the shell runtime. Never ~/.claude.
  let root: URL
  /// How long the CLI gets to answer at start: its start-up request, and each probe command.
  var handshakeWait: Duration = .seconds(30)

  init(root: URL = URL(fileURLWithPath: "/private/tmp/serein-claude-\(getuid())", isDirectory: true)) {
    // Another user can make the fixed folder first and keep it until a reboot: then a fresh private one.
    self.root = (try? Self.ownedDirectory(root)) != nil ? root : (try? AgentFileGuard.makeRuntimeDirectory()) ?? root
  }

  static let mode = ["permissionMode": "dontAsk"]
  /// CLAUDE_CODE_SUBPROCESS_ENV_SCRUB (AgentFileGuard) makes the CLI start in `default` whatever the flag says.
  /// With `--permission-prompts none` that denies every would-be prompt, the same floor as `dontAsk`.
  static let expectedMode = ExpectedMode.reportsAnyOf(["permissionMode": ["dontAsk", "default"]])

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    let launch = try ClaudeLaunch(request, network: network, root: root, cardWait: cardWait)
    // In the arguments, not the resume: a warm process holds the original, so a fork starts its own.
    let fork = request.forkSession && request.resume != nil ? ["--fork-session"] : []
    return LaunchContract(
      request, arguments: launch.arguments + fork, resumeArguments: request.resume.map { ["--resume", $0] } ?? [],
      environment: launch.environment, expectedMode: Self.expectedMode, network: network)
  }

  func prepare(_ contract: LaunchContract, request: TurnRequest) throws {
    let launch = try ClaudeLaunch(request, network: contract.network, root: root, cardWait: cardWait)
    try Self.ownedDirectory(root)
    try Self.ownedDirectory(launch.directory)
    for (url, data) in launch.files {
      try data.write(to: url, options: .atomic)
      guard chmod(url.path, 0o600) == 0 else { throw SereinError.invalid("Could not protect \(url.path).") }
    }
    // Its startup profile is written last, so a runtime that has it is whole and is never refilled.
    if let runtime = launch.runtime, !FileManager.default.fileExists(atPath: runtime.appendingPathComponent("shell/startup.sb").path) {
      try Self.ownedDirectory(runtime)
      do { try AgentFileGuard.fillClaudeRuntimeDirectory(runtime) } catch {
        try? FileManager.default.removeItem(at: runtime)
        throw error
      }
    }
    let current = Set(launch.paths)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: launch.directory.path)) ?? [] {
      let path = launch.directory.appendingPathComponent(name).path
      if !current.contains(path), !LaunchFilesInUse.contains(path) { try? FileManager.default.removeItem(atPath: path) }
    }
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    let paths = try ClaudeLaunch(request, network: contract.network, root: root, cardWait: cardWait).paths
    LaunchFilesInUse.hold(paths)
    Task {
      _ = await process.hosted.exited()
      while process.hosted.groupAlive { try? await Task.sleep(for: .milliseconds(500)) }
      LaunchFilesInUse.release(paths)
    }
    let reader = ClaudeReader(
      process, folder: request.access.folder?.path, structured: request.schema != nil, resuming: !contract.resumeArguments.isEmpty)
    try process.send(line: Self.line(["type": "control_request", "request_id": ClaudeReader.initID, "request": ["subtype": "initialize"]]))
    let reported = try await reader.initialized(within: handshakeWait)
    switch ModeCheck.verify(contract.expectedMode, reported: reported, argv: contract.argv) {
    case .success(let mode): return ClaudeSession(mode: mode, reader: reader, process: process)
    case .failure(let reason): throw reason
    }
  }

  func probe(executable: URL) async -> Readiness {
    let environment = Self.environment(ownSetup: false, cardWait: cardWait, executable: executable)
    func output(_ arguments: [String]) -> String? {
      CredentialEnv.output(executable, arguments, environment: environment, within: handshakeWait, quietErrors: true)?.text
    }
    guard let printed = output(["--version"]), let version = HarnessParse.version(printed) else {
      return .broken("Claude Code did not report its version.")
    }
    if let need = cli.minimumCLIVersion, HarnessParse.isOlder(version, than: need) { return .needsUpdate(have: version, need: need) }
    if HarnessParse.claudeAuth(output(["auth", "status"]) ?? "").signedIn == false {
      return .needsSignIn("Claude Code is signed out.")
    }
    return .ready(version: version)
  }

  /// The same environment for probes and turns, so a probe never sees a sign-in the turn strips.
  /// `person`: the request's `environment`; a probe has none.
  /// `providerTurn`: every routing variable from the app's environment goes, own setup's too,
  /// and only `person`'s (the connection's, HarnessRegistry.prepare) stay.
  static func environment(
    ownSetup: Bool, cardWait: Duration, executable: URL, person: [String: String] = [:], providerTurn: Bool = false
  ) -> [String: String] {
    var own = HarnessDriver.claude.quietEnvironment
    own["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1"
    own["CLAUDE_CODE_DISABLE_CRON"] = "1"
    own["MCP_TOOL_TIMEOUT"] = String((cardWait + .seconds(60)).components.seconds * 1_000)
    var environment = CredentialEnv.child(.claude, executable: executable, person: person, own: own)
    environment["CLAUDE_CODE_ENTRYPOINT"] = nil
    if ownSetup { environment = OwnSetup.environment(environment) }
    guard providerTurn else { return environment }
    return environment.filter { !ProviderRun.routesClaude($0.key) }.merging(person.filter { ProviderRun.routesClaude($0.key) }) { _, table in table }
  }

  static func line(_ object: [String: Any]) -> Data { Data(jsonString(object).utf8) }

  /// A stdin user message. Images go inline as base64 blocks; `uuid` comes back on its replay.
  static func userMessage(_ text: String, images: [URL] = [], uuid: String) throws -> Data {
    var content: [[String: Any]] = try images.map { image in
      [
        "type": "image",
        "source": [
          "type": "base64", "media_type": UTType(filenameExtension: image.pathExtension)?.preferredMIMEType ?? "image/png",
          "data": try Data(contentsOf: image).base64EncodedString(),
        ],
      ]
    }
    if !text.isEmpty { content.append(["type": "text", "text": text]) }
    return line(["type": "user", "uuid": uuid, "message": ["role": "user", "content": content]])
  }

  /// The volatile prompt part as a reminder in the message: in a process's first message, and
  /// again only when it changed, so the launched system prompt is the stable part alone and a
  /// warm process keeps its cached prefix. `had` is what the process last got; nil for none.
  static func withVolatileNote(_ text: String, volatile: String, had: String?) -> String {
    let part = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
    let body: String
    if had == volatile || (had == nil && part.isEmpty) { return text }
    if part.isEmpty {
      body = "The notes that were in your instructions when this session started no longer apply."
    } else if had == nil {
      body = "This part of your instructions changes between turns, so it comes here instead of in the system prompt. It replaces any earlier copy:\n\n" + part
    } else {
      body = "This part of your instructions changed since this session started. It replaces the earlier copy:\n\n" + part
    }
    let note = "<system-reminder>\n\(body)\n</system-reminder>"
    return text.isEmpty ? note : note + "\n\n" + text
  }

  private static func ownedDirectory(_ url: URL) throws {
    if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw SereinError.invalid("Could not create \(url.path).") }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
      throw SereinError.invalid("\(url.path) is not a private Serein folder.")
    }
  }

}

/// Everything one Claude launch is, derived purely from the request. Files are named by their
/// content's digest, which puts the content on argv (the warm key), and a file a running process
/// was started with is never rewritten.
private struct ClaudeLaunch {
  /// The shell runtime holds only its own path and the running Serein's helper, so one per thread
  /// per Serein run is never refilled, and the next run copies its own helper.
  private static let run = UUID().uuidString.prefix(8).lowercased()
  let directory: URL
  let runtime: URL?
  let files: [(URL, Data)]
  let arguments: [String]
  let environment: [String: String]

  var paths: [String] { files.map(\.0.path) + (runtime.map { [$0.path] } ?? []) }

  init(_ request: TurnRequest, network: ShellNetwork.Plan, root: URL, cardWait: Duration) throws {
    let access = request.access
    var ownSetup = request.ownSetup
    let read = ["Read", "Glob", "Grep"], edit = ["Edit", "Write"]
    let allowed: [String]
    var offered: [String]
    switch access {
    case .answer, .web: allowed = []
    case .library: allowed = read
    case .ownSetup:
      ownSetup = true
      allowed = read
    case .project(_, .review): allowed = read
    case .project(_, .edits): allowed = read + edit
    case .project(_, .commands), .project(_, .full), .task: allowed = read + edit + ["Bash"]
    }
    offered = allowed
    // A Review turn is offered edits it may not make: each one comes back as a denial, and with
    // it the edit-approval card.
    if case .project(_, .review) = access, !ownSetup { offered += edit }
    // Own setup loads the person's allow rules, so it never carries edits, a shell or the browser.
    if ownSetup, allowed.contains("Edit") || access == .web { throw EngineRefusal.cliCannot(access) }
    let commands = allowed.contains("Bash")

    directory = root.appendingPathComponent(Self.digest(Data(request.thread.id.utf8)), isDirectory: true)
    runtime = commands ? directory.appendingPathComponent("runtime-" + Self.run, isDirectory: true) : nil
    let prompt = Data(request.prompt.stable.utf8)
    let promptFile = directory.appendingPathComponent("system-prompt-\(Self.digest(prompt)).md")
    let browser = ownSetup ? nil : request.browser
    let servers: [String: Any] = browser.map { ["serein_browser": ["command": $0.command.path, "args": $0.arguments]] } ?? [:]

    var args = [
      "--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages",
      "--input-format", "stream-json", "--replay-user-messages",
      "--mcp-config", jsonString(["mcpServers": servers]), "--no-chrome",
      "--settings", jsonString(["disableAllHooks": true]), "--disable-slash-commands",
    ]
    args += ownSetup ? ["--setting-sources", "user"] : ["--restricted", "--strict-mcp-config", "--setting-sources", ""]
    args += [
      "--permission-mode", ClaudeDriver.mode["permissionMode"]!, "--permission-prompts", "none",
      "--append-system-prompt-file", promptFile.path, "--system-prompt-snapshot", "off",
      "--tools", offered.joined(separator: ","),
      "--allowedTools", ((browser == nil ? [] : ["mcp__serein_browser"]) + allowed).joined(separator: ","),
    ]
    if let model = request.model, !model.isEmpty { args += ["--model", model] }
    if let effort = request.effort, !effort.isEmpty { args += ["--effort", effort] }
    if let schema = request.schema { args += ["--json-schema", schema] }

    let home = FileManager.default.homeDirectoryForCurrentUser
    var privateRoots: [URL] = []
    if case .library = access {} else { privateRoots = AgentFileGuard.sereinPrivateRoots(home: home, library: AgentAccess.defaultRoot) }
    if ownSetup { privateRoots += OwnSetup.sereinPaths(home: home, library: nil).map { URL(fileURLWithPath: $0) } }
    // Allow all opens home as a root of its own; the protected folders and private roots stay denied.
    let folders = (access.folder.map { [$0] } ?? []) + (request.opensHome ? [home] : []) + request.widened
    args = AgentFileGuard.claudeArguments(
      args, folders: folders, commands: commands, runtimeDirectory: runtime, privateRoots: privateRoots)

    if !request.attachments.isEmpty {
      if let i = args.firstIndex(of: "--tools"), !offered.contains("Read") { args[i + 1] = (offered + ["Read"]).joined(separator: ",") }
      args += request.attachments.map { "--add-dir=" + $0.path }
    }

    guard let s = args.firstIndex(of: "--settings").map({ $0 + 1 }),
      var settings = (try? JSONSerialization.jsonObject(with: Data(args[s].utf8))) as? [String: Any]
    else { throw SereinError.invalid("Claude settings went missing from its launch.") }
    if commands, var sandbox = settings["sandbox"] as? [String: Any] {
      // A bare `*` WebFetch allow opens every host to sandboxed shells (Claude 2.1.186+, per its
      // sandboxing docs). WebFetch itself is never offered.
      var permissions = settings["permissions"] as? [String: Any] ?? [:]
      permissions["allow"] = (permissions["allow"] as? [String] ?? []) + ["WebFetch(domain:*)"]
      settings["permissions"] = permissions
      // Without this the model could ask for a command outside the sandbox (dangerouslyDisableSandbox).
      sandbox["allowUnsandboxedCommands"] = false
      var proxied = sandbox["network"] as? [String: Any] ?? [:]
      proxied.merge(ShellNetwork.claudeNetwork(port: network.port)) { _, port in port }
      sandbox["network"] = proxied
      settings["sandbox"] = sandbox
    }
    // Attached files are read-only roots of their own, outside the folder's edit rules, with the
    // same secret denies. In settings, as the folder's are: the CLI splits a tool list at spaces and commas.
    let attached = Set(request.attachments.flatMap { [AgentFileGuard.claudePhysicalPath($0), $0.standardizedFileURL.path] }).sorted()
    if !attached.isEmpty {
      var permissions = settings["permissions"] as? [String: Any] ?? [:]
      permissions["allow"] = (permissions["allow"] as? [String] ?? []) + attached.map { "Read(/\($0)/**)" }
      permissions["deny"] = (permissions["deny"] as? [String] ?? [])
        + attached.flatMap { root in AgentFileGuard.secretGlobs.map { "Read(/\(root)/\($0))" } }
      settings["permissions"] = permissions
    }
    let settingsData = Data(jsonString(settings).utf8)
    let settingsFile = directory.appendingPathComponent("settings-\(Self.digest(settingsData)).json")
    args[s] = settingsFile.path
    arguments = args
    files = [(settingsFile, settingsData), (promptFile, prompt)]
    environment = ClaudeDriver.environment(
      ownSetup: ownSetup, cardWait: cardWait, executable: request.executable, person: request.environment,
      providerTurn: request.providerTurn)
  }

  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined() }
}

/// Launch files a process of this Serein was started with, held until its group is gone, so a
/// later launch of the thread never removes them.
private enum LaunchFilesInUse {
  private static let lock = NSLock()
  private static var holds: [String: Int] = [:]

  static func hold(_ paths: [String]) { lock.withLock { for path in paths { holds[path, default: 0] += 1 } } }
  static func release(_ paths: [String]) {
    lock.withLock {
      for path in paths { holds[path] = holds[path].flatMap { $0 > 1 ? $0 - 1 : nil } }
    }
  }
  static func contains(_ path: String) -> Bool { lock.withLock { holds[path] != nil } }
}

private final class ClaudeSession: EngineSession {
  let mode: VerifiedMode
  private let reader: ClaudeReader
  private let process: EngineProcess

  init(mode: VerifiedMode, reader: ClaudeReader, process: EngineProcess) {
    self.mode = mode
    self.reader = reader
    self.process = process
  }

  var wire: AsyncStream<WireEvent> { reader.wire }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    let uuid = UUID().uuidString.lowercased()
    let text = reader.begin(uuid, message: prompt.message, volatile: prompt.volatile)
    try process.send(line: ClaudeDriver.userMessage(text, images: request.images, uuid: uuid))
  }

  func steer(_ text: String) async -> SteerOutcome {
    let uuid = UUID().uuidString.lowercased()
    return await reader.steer(uuid, text) { try process.send(line: ClaudeDriver.userMessage(text, uuid: uuid)) }
  }
}

/// Reads one Claude process's stdout for its whole life.
private final class ClaudeReader: @unchecked Sendable {
  static let initID = "serein-init"
  let wire: AsyncStream<WireEvent>
  private let events: AsyncStream<WireEvent>.Continuation
  private let process: EngineProcess
  private let folder: String?
  private let structured: Bool
  private let resuming: Bool
  private let lock = NSLock()
  // Guarded by `lock`.
  private var initResult: Result<[String: String], StopReason>?
  private var initWaiter: CheckedContinuation<[String: String], any Error>?
  private var turn: String?
  /// Steers written and not yet taken in by a model call (no replay seen), each with its waiter.
  private var steers: [String: (text: String, taken: CheckedContinuation<SteerOutcome, Never>)] = [:]
  private var ended = false
  private var streamed = false
  /// A main-agent message with text ended: the next text is a new message (`EngineEvent.newMessage`).
  private var spokeBefore = false
  /// The text of an api-error frame in this turn ("Not logged in · Please run /login").
  private var apiError: String?
  /// A result held while a steered message still runs; the later result settles the turn.
  private var held: (input: Int, output: Int, cached: Int)?
  /// The volatile part this process last got; nil for none yet, or compacted away.
  private var volatile: String?

  init(_ process: EngineProcess, folder: String?, structured: Bool, resuming: Bool) {
    self.process = process
    self.folder = folder
    self.structured = structured
    self.resuming = resuming
    (wire, events) = AsyncStream<WireEvent>.makeStream()
    Task {
      for await line in process.lines { self.handle(line) }
      self.handBackSteers()
      self.settleInit(.failure(.failed("Claude Code ended before it answered its start-up request.")))
      self.events.finish()
    }
  }

  /// `permissionMode` as the CLI reports it, before any prompt.
  func initialized(within wait: Duration) async throws -> [String: String] {
    Task { [weak self] in
      try? await Task.sleep(for: wait)
      self?.settleInit(.failure(.failed("Claude Code did not answer its start-up request.")))
    }
    return try await withCheckedThrowingContinuation { continuation in
      let known: Result<[String: String], StopReason>? = lock.withLock {
        if initResult == nil { initWaiter = continuation }
        return initResult
      }
      if let known { continuation.resume(with: known) }
    }
  }

  func begin(_ uuid: String, message: String, volatile next: String) -> String {
    lock.withLock {
      turn = uuid
      streamed = false
      spokeBefore = false
      apiError = nil
      defer { volatile = next }
      return ClaudeDriver.withVolatileNote(message, volatile: next, had: volatile)
    }
  }

  /// Words count as read only once a model call takes them in (their replay). A process that
  /// ends first, as Stop ends it, never read them: they go back to be sent as the next turn.
  func steer(_ uuid: String, _ text: String, send: () throws -> Void) async -> SteerOutcome {
    await withCheckedContinuation { continuation in
      let gone = lock.withLock {
        if !ended { steers[uuid] = (text, continuation) }
        return ended
      }
      if gone { return continuation.resume(returning: .handedBack(text)) }
      do { try send() } catch {
        lock.withLock { steers.removeValue(forKey: uuid) }?.taken.resume(returning: .indeterminate)
      }
    }
  }

  private func handBackSteers() {
    let left = lock.withLock {
      ended = true
      defer { steers = [:] }
      return Array(steers.values)
    }
    for steer in left { steer.taken.resume(returning: .handedBack(steer.text)) }
  }

  private func settleInit(_ result: Result<[String: String], StopReason>) {
    let waiter: CheckedContinuation<[String: String], any Error>? = lock.withLock {
      guard initResult == nil else { return nil }
      initResult = result
      defer { initWaiter = nil }
      return initWaiter
    }
    waiter?.resume(with: result)
  }

  private func handle(_ line: Data) {
    guard let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
    if frame["type"] as? String == "control_response" {
      let response = frame["response"] as? [String: Any] ?? [:]
      guard response["request_id"] as? String == Self.initID else { return }
      if response["subtype"] as? String == "error" {
        settleInit(.failure(.failed("Claude Code refused its start-up request: \(response["error"] as? String ?? "no reason given")")))
      } else {
        let body = response["response"] as? [String: Any] ?? [:]
        settleInit(.success((body["current_permission_mode"] as? String).map { ["permissionMode": $0] } ?? [:]))
      }
      return
    }
    // A --resume Claude no longer has ends with an error result before the start-up answer.
    if frame["type"] as? String == "result", lock.withLock({ initResult == nil }) {
      settleInit(.failure(resuming ? .resumeFailed(Self.errorText(frame)) : .failed(Self.errorText(frame))))
      return
    }
    let (out, retire) = lock.withLock { read(frame) }
    for event in out { events.yield(event) }
    // A signed-out process stays signed out: end it, so the next turn starts a fresh one.
    if retire { process.closeInput() }
  }

  /// One stdout frame as wire events. Called under `lock`.
  private func read(_ frame: [String: Any]) -> ([WireEvent], retire: Bool) {
    // A subagent's own frames: its prose would interleave with the chat's.
    let child = frame["parent_tool_use_id"] as? String != nil
    switch frame["type"] as? String {
    case "system":
      switch frame["subtype"] as? String {
      case "init":
        var out: [WireEvent] = [.modeReported((frame["permissionMode"] as? String).map { ["permissionMode": $0] } ?? [:])]
        if let id = frame["session_id"] as? String { out.append(.session(id: id, rebuilt: false)) }
        return (out, false)
      case "compact_boundary" where !child:
        // Only the system prompt survives a compaction, so the next turn sends the volatile part again.
        volatile = nil
        return ([], false)
      default: return ([], false)
      }
    case "rate_limit_event":
      return (UsageLimit.claudeEvent(frame, now: Date()).map { [.limitReached($0)] } ?? [], false)
    case "stream_event":
      guard !child, let event = frame["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
        let delta = event["delta"] as? [String: Any]
      else { return ([], false) }
      if delta["type"] as? String == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
        streamed = true
        return (say(text), false)
      }
      if delta["type"] as? String == "thinking_delta", let text = delta["thinking"] as? String, !text.isEmpty {
        return ([.thinking(text)], false)
      }
      return ([], false)
    case "assistant":
      guard !child else { return ([], false) }
      let content = (frame["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
      let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
      if frame["error"] is String || frame["is_api_error_message"] as? Bool == true {
        apiError = text.isEmpty ? frame["error"] as? String : text
        return ([], false)
      }
      var out: [WireEvent] = []
      if !text.isEmpty {
        // A block that never streamed (an older CLI, a non-streaming path) still shows.
        if !streamed { out += say(text) }
        spokeBefore = true
      }
      streamed = false
      for block in content where block["type"] as? String == "tool_use" {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
        let input = block["input"] as? [String: Any] ?? [:]
        out.append(.toolStarted(id: id, name: name, arguments: jsonString(input), shellCommand: name == "Bash" ? input["command"] as? String : nil))
      }
      return (out, false)
    case "user":
      if frame["isReplay"] as? Bool == true {
        // --replay-user-messages: a model call took this stdin message in.
        guard let uuid = frame["uuid"] as? String else { return ([], false) }
        steers.removeValue(forKey: uuid)?.taken.resume(returning: .steered)
        return (uuid == turn ? [.accepted] : [], false)
      }
      guard !child else { return ([], false) }
      let content = (frame["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
      return (content.compactMap { block in
        guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
        return WireEvent.toolEnded(id: id, result: block["is_error"] as? Bool == true ? .failed : .ok)
      }, false)
    case "result":
      // A background task's synthetic completion is not the turn's result.
      if (frame["origin"] as? [String: Any])?["kind"] as? String == "task-notification" { return ([], false) }
      return result(frame)
    default:
      return ([], false)
    }
  }

  /// Text, marked as a new message when an earlier message of this turn already spoke. Called under `lock`.
  private func say(_ text: String) -> [WireEvent] {
    defer { spokeBefore = false }
    return (spokeBefore ? [.newMessage] : []) + [.text(text)]
  }

  private func result(_ frame: [String: Any]) -> ([WireEvent], retire: Bool) {
    let usage = frame["usage"] as? [String: Any] ?? [:]
    func count(_ key: String) -> Int { usage[key] as? Int ?? 0 }
    // result.usage is per turn in a streaming-input session; input counts the cached prefix too.
    let cached = count("cache_read_input_tokens") + (held?.cached ?? 0)
    let input = count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens") + (held?.input ?? 0)
    let output = count("output_tokens") + (held?.output ?? 0)
    // queued_turn_count can say 0 for a steer written but not yet queued, so a pending steer holds too.
    if frame["queued_turn_count"] as? Int ?? 0 > 0 || !steers.isEmpty {
      held = (input, output, cached)
      return ([], false)
    }
    held = nil
    defer {
      turn = nil
      apiError = nil
      streamed = false
    }
    var out: [WireEvent] = ApprovalEvents.parse(frame, folder: folder).map {
      .declined(PendingApprovalValue(id: $0.id, tool: $0.tool, target: $0.target))
    }
    out.append(.usage(input: input, output: output, cachedInput: cached))
    if frame["is_error"] as? Bool == true || apiError != nil {
      let text = apiError ?? Self.errorText(frame)
      out.append(.failed(text))
      return (out, HarnessRetry.classify(.message(text)) == .terminal(.auth))
    }
    if structured, let answer = frame["structured_output"] {
      out += [.newMessage, .text(jsonString(answer))]
    }
    out.append(.turnDone(Self.stopReason(frame["stop_reason"] as? String)))
    return (out, false)
  }

  static func stopReason(_ raw: String?) -> StopReason {
    switch raw {
    case "max_tokens", "model_context_window_exceeded": return .maxTokens
    case "refusal": return .refusal
    default: return .endTurn
    }
  }

  /// An error result's `errors`, else its text, else its kind; never the synthetic "stop_sequence".
  static func errorText(_ frame: [String: Any]) -> String {
    let errors = (frame["errors"] as? [String] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if !errors.isEmpty { return errors.joined(separator: "; ") }
    if let text = frame["result"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
    let kind = (frame["subtype"] as? String).flatMap { $0 == "success" ? nil : $0 } ?? frame["terminal_reason"] as? String ?? "unknown"
    return "Claude Code ended the turn with an error (\(kind))."
  }
}
