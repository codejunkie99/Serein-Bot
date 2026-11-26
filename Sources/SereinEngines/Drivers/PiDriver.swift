import CryptoKit
import Foundation
import SereinCore

/// Pi and Oh My Pi over `--mode rpc`: one JSON frame a line each way. Pi never asks before a
/// tool runs, so the tool list on argv is the whole policy.
struct PiDriver: Driver {
  /// `.pi` or `.ohMyPi`; both speak the same RPC.
  let cli: HarnessDriver
  /// The stable prompt is written here, named by its hash. A Serein private root: the file guard
  /// closes it to every CLI it runs, so no agent can rewrite the file, and Pi may read its own.
  var files = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Serein/pi", isDirectory: true)
  /// Serein's browser extension, read from the app's own resources as main loads it.
  var browserExtension = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Serein_Serein.bundle")) }?
    .url(forResource: "PiBrowser", withExtension: "js")
  /// Pi's sessions folder; nil reads Pi's own (its agent folder, `PI_CODING_AGENT_DIR` or `~/.pi/agent`).
  var sessionsFolder: URL? = nil
  var steerWait: Duration = .seconds(20)
  /// Pi 0.55.3 says it retries a failed turn only after that turn's `agent_end`.
  var retryGrace: Duration = .seconds(1)
  var handshakeWait: Duration = .seconds(30)

  /// Pi has no tool timeout: an extension tool held a 600 s call open (grounding/live-tests.md).
  var cardWait: Duration { .seconds(600) }
  var promptAddition: String {
    "You have read, bash, edit and write. Use bash for search (rg, find), builds and tests. Make the changes yourself and check them with bash before you report. Do not ask for confirmation."
  }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    let own = Self.ownSetup(request)
    let isolation =
      cli == .ohMyPi
      ? ["--no-extensions", "--no-skills", "--no-lsp", "--no-title", "--no-context-files"]
      // Pi below 0.67.4 ignores an unknown flag, so --no-context-files is safe on every version.
      : ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files"]
    var arguments = ["--mode", "rpc"] + isolation.filter { !own || $0 != "--no-extensions" }
    var environment = Self.environment(request.executable, person: request.environment)

    var tools = Self.tools(request.access)
    // Own setup loads the person's extensions, which act through Pi's tools with no question asked.
    if own, tools.contains("edit") { throw EngineRefusal.cliCannot(request.access) }
    // Every run Serein serves gets its tools through the extension (R31); the helper gates each call itself.
    if let browser = request.browser, !own {
      // Pi has no MCP: Serein's extension starts the browser helper and registers its tools.
      // `--no-extensions` still loads an explicit `--extension`.
      guard let script = browserExtension else { throw EngineRefusal.notReady(.broken("Serein's Pi browser extension is missing.")) }
      environment["SEREIN_BROWSER_MCP"] = String(
        decoding: try JSONEncoder().encode([browser.command.path] + browser.arguments), as: UTF8.self)
      arguments += ["--extension", script.path]
      tools += browser.tools.map { "serein_browser_" + $0 }
    }
    // Pi 1.x runs only the tools named; 0.x drops names it does not know and keeps extension tools.
    let toolFlag = ["--no-tools"] + (tools.isEmpty ? [] : ["--tools", tools.joined(separator: ",")])
    arguments += toolFlag
    let prompt = promptFile(request.prompt.stable)
    arguments += ["--append-system-prompt", prompt.path]
    if let model = request.model, !model.isEmpty { arguments += ["--model", model] }
    if let effort = request.effort, !effort.isEmpty { arguments += ["--thinking", effort] }
    var contract = LaunchContract(
      request, arguments: arguments, environment: environment, expectedMode: .nothing(flagOnArgv: toolFlag), network: network)
    let promptPaths = [prompt.path, AgentFileGuard.physicalPath(prompt.path)].map { "(literal \(jsonString($0)))" }.joined(separator: " ")
    contract.sandboxProfile = LaunchContract.fileGuard(request) + "(allow file-read* \(promptPaths))\n"
    return contract
  }

  /// Rewritten before every spawn: a file already there is never trusted.
  func prepare(_ contract: LaunchContract, request: TurnRequest) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: files, withIntermediateDirectories: true)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.path)
    let file = promptFile(request.prompt.stable)
    try Data(request.prompt.stable.utf8).write(to: file, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    let mode: VerifiedMode
    switch ModeCheck.verify(contract.expectedMode, reported: [:], argv: contract.argv) {
    case .success(let verified): mode = verified
    case .failure(let reason): throw reason
    }
    let session = PiSession(process, mode: mode, steerWait: steerWait, retryGrace: retryGrace)
    await session.start()
    do {
      try await session.handshake(
        resume: request.scopedResume, sessions: sessions(contract.environment), model: request.model, wait: handshakeWait)
    } catch let reason as StopReason {
      throw reason
    } catch {
      // Pi exits at start when no provider is signed in; its stderr says so. One still up after
      // the wait would never exit on its own.
      await StopLadder.run(stopLadder, on: process.hosted, sleep: { try? await Task.sleep(for: $0) })
      let exit = await process.hosted.exited()
      let text = exit.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.contains("No models available") { throw StopReason.signIn(text) }
      throw StopReason.failed(text.isEmpty ? "\(cli.displayName) did not answer: \(error)" : text)
    }
    return session
  }

  func probe(executable: URL) async -> Readiness {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .missing }
    let environment = Self.environment(executable, person: [:])
    func run(_ arguments: [String]) -> String? {
      CredentialEnv.output(executable, arguments, environment: environment, within: .seconds(8))?.text
    }
    guard let version = run(["--version"]) else { return .broken("\(cli.displayName) did not start.") }
    guard let number = version.firstMatch(of: #/\d+\.\d+\.\d+/#).map({ String($0.output) }) else { return .broken(version) }
    if let models = run(["--list-models"]), models.contains("No models available") {
      return .needsSignIn(models.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return .ready(version: number)
  }

  // MARK: Rules

  private func sessions(_ environment: [String: String]) -> URL {
    if let sessionsFolder { return sessionsFolder }
    let name = cli == .ohMyPi ? "omp" : "pi"
    let agent = environment[name.uppercased() + "_CODING_AGENT_DIR"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(name)/agent")
    return agent.appendingPathComponent("sessions")
  }

  /// A regular `.jsonl` file inside `folder` once every link on the way is resolved; a link
  /// itself is no session.
  static func isSession(_ path: String, in folder: URL) -> Bool {
    let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
    let real = AgentFileGuard.physicalPath(path)
    return path.hasPrefix("/") && type == .typeRegular && real.hasSuffix(".jsonl")
      && real.hasPrefix(AgentFileGuard.physicalPath(folder.path) + "/")
  }

  /// Explicit own-setup turns load the person's own Pi extensions; everything else stays Serein's.
  static func ownSetup(_ request: TurnRequest) -> Bool {
    if case .ownSetup = request.access { return true }
    return request.ownSetup
  }

  /// Pi's built-in tools for each access. Pi never asks, so `commands` gets bash like `full`.
  static func tools(_ access: Access) -> [String] {
    let read = ["read", "grep", "find", "ls"]
    switch access {
    case .answer, .web: return []
    case .library, .ownSetup: return read
    case .project(_, let level):
      switch level {
      case .review: return read
      case .edits: return read + ["edit", "write"]
      case .commands, .full: return read + ["edit", "write", "bash"]
      }
    case .task: return read + ["edit", "write", "bash"]
    }
  }

  /// Named by the text's hash, so the path is the same for the same text (the warm key) and a
  /// second writer writes the same bytes.
  private func promptFile(_ text: String) -> URL {
    files.appendingPathComponent(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() + ".md")
  }

  /// Pi is a Node script: `node` sits beside it, and the executable's folder leads PATH.
  private static func environment(_ executable: URL, person: [String: String]) -> [String: String] {
    CredentialEnv.child(.pi, executable: executable, person: person, own: ["PI_SKIP_VERSION_CHECK": "1"])
  }
}

/// One Pi process. Frames come in on one reader task; replies go to the waiter of their id.
actor PiSession: EngineSession {
  nonisolated let mode: VerifiedMode
  nonisolated let wire: AsyncStream<WireEvent>

  private struct Reply: Sendable {
    var success: Bool
    var data: JSON?
    var error: String?
  }

  private enum CallError: Error {
    /// The frame never reached Pi.
    case notSent
    /// Sent, with no answer: it may have been taken.
    case noAnswer
  }

  private let process: EngineProcess
  private let events: AsyncStream<WireEvent>.Continuation
  private let steerWait: Duration
  private let retryGrace: Duration
  private var waiters: [String: CheckedContinuation<Reply, Error>] = [:]
  private var nextID = 0
  private var closed = false
  private var chunks = PiChunks()
  private var sessionFile: String?
  /// The resume did not load, so the next message carries the recovery text.
  private var rebuilt = false
  private var compacting = false
  private var promptID: String?
  private var compactionWaiters: [CheckedContinuation<Void, Never>] = []

  // One turn.
  private var turnOpen = false
  private var stopReason: String?
  private var errorText: String?
  private var spoke = false
  private var usage: (input: Int, output: Int, cached: Int)?
  /// A failed end Pi may still retry; it goes out after `retryGrace` unless a retry starts.
  private var heldFailure: String?
  private var holdTimer: Task<Void, Never>?

  init(_ process: EngineProcess, mode: VerifiedMode, steerWait: Duration, retryGrace: Duration) {
    self.process = process
    self.mode = mode
    self.steerWait = steerWait
    self.retryGrace = retryGrace
    (wire, events) = AsyncStream<WireEvent>.makeStream()
  }

  func start() {
    Task {
      for await line in process.lines { self.receive(line) }
      self.closeWire()
    }
  }

  /// Opens the session: the resume, then Pi's state, which also proves it is up.
  func handshake(resume: String?, sessions: URL, model: String?, wait: Duration) async throws {
    // Oh My Pi moves to RPC v2 (chunked frames); Pi answers an unknown command with no id.
    try? process.send(line: Data(#"{"id":"negotiate","type":"negotiate_protocol","protocolVersion":2}"#.utf8))
    if let resume {
      // A missing file would open as a new, empty session, so it is no resume.
      if PiDriver.isSession(resume, in: sessions),
        let reply = try? await call("switch_session", ["sessionPath": .string(resume)], wait: wait),
        reply.success, reply.data?["cancelled"]?.bool != true
      {
        rebuilt = false
      } else {
        rebuilt = true
      }
    }
    let state = try await call("get_state", wait: wait)
    guard state.success else { throw StopReason.failed(state.error ?? "Pi did not report its state.") }
    sessionFile = state.data?["sessionFile"]?.string ?? state.data?["sessionId"]?.string
    if resume != nil, !rebuilt, (state.data?["messageCount"]?.number ?? 0) == 0 { rebuilt = true }
    let running = Self.modelID(state.data?["model"])
    if let model, !model.isEmpty, let slash = model.firstIndex(of: "/") {
      // An ID-only echo cannot establish which provider owns a namespaced selection, and a Pi
      // running another model is asked for this one before the turn is refused.
      let result = try await call("set_model", ["provider": .string(String(model[..<slash])),
        "modelId": .string(String(model[model.index(after: slash)...]))], wait: wait)
      guard result.success else { throw StopReason.modelRejected(result.error ?? "Pi refused the selected model.") }
    } else if let model, !model.isEmpty, running.map({ !($0 == model || $0.hasSuffix("/" + model)) }) ?? (resume != nil) {
      throw StopReason.modelRejected("Pi did not take the model \(model); it runs \(running ?? "none").")
    }
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    // Pi refuses a prompt while it compacts after the last turn.
    while compacting && !closed { await withCheckedContinuation { compactionWaiters.append($0) } }
    let body = rebuilt ? prompt.recovery ?? prompt.message : prompt.message
    var fields: [String: JSON] = ["message": .string([prompt.volatile, body].filter { !$0.isEmpty }.joined(separator: "\n\n"))]
    let images = try request.images.map(Self.image)
    if !images.isEmpty { fields["images"] = .array(images) }
    beginTurn()
    // Taken as the answer is read: Pi streams the turn right behind it, so this cannot wait for `call` to resume.
    promptID = "serein-\(nextID + 1)"
    do {
      _ = try await call("prompt", fields, wait: .seconds(120))
    } catch {
      promptID = nil
      turnOpen = false
      // Pi died before answering: its exit, with stderr, types the failure and decides the replay.
      if closed { return }
      throw error
    }
  }

  /// Pi 0.55.3 answers a prompt's id at once and, when it then refuses the prompt, answers the
  /// same id again with the error, in either order; the id is watched until the agent starts.
  private func took(_ reply: Reply) {
    guard turnOpen else {
      promptID = nil
      return
    }
    if reply.success {
      events.yield(.accepted)
      if let sessionFile { events.yield(.session(id: sessionFile, rebuilt: rebuilt)) }
      rebuilt = false
    } else {
      promptID = nil
      endTurn(Self.refusal(reply.error ?? "Pi refused the message."))
    }
  }

  /// Pi's own words for a prompt it cannot send with no provider signed in (agent-session.js).
  static func refusal(_ text: String) -> WireEvent {
    ["No API key found", "Authentication failed", "No model selected"].contains(where: text.hasPrefix) ? .turnDone(.signIn(text)) : .failed(text)
  }

  /// Pi takes the words after the running tool ends and skips the tools still queued. A plain
  /// prompt mid-turn is dropped, so mid-turn words always go as a steer (`steers` stays true).
  func steer(_ text: String) async -> SteerOutcome {
    guard !closed else { return .refused }
    do {
      return try await call("steer", ["message": .string(text)], wait: steerWait).success ? .steered : .refused
    } catch CallError.notSent {
      return .refused
    } catch {
      return .indeterminate
    }
  }

  // MARK: Wire

  private func call(_ type: String, _ fields: [String: JSON] = [:], wait: Duration) async throws -> Reply {
    guard !closed else { throw CallError.notSent }
    nextID += 1
    let id = "serein-\(nextID)"
    var frame = fields
    frame["type"] = .string(type)
    frame["id"] = .string(id)
    do { try process.send(line: try JSONEncoder().encode(JSON.object(frame))) } catch { throw CallError.notSent }
    return try await withCheckedThrowingContinuation { waiter in
      waiters[id] = waiter
      Task {
        try? await Task.sleep(for: wait)
        self.answer(id, with: .failure(CallError.noAnswer))
      }
    }
  }

  private func answer(_ id: String, with result: Result<Reply, Error>) {
    waiters.removeValue(forKey: id)?.resume(with: result)
  }

  private func receive(_ line: Data) {
    guard var frame = try? JSONDecoder().decode(JSON.self, from: line), case .object = frame else { return }
    if frame["type"]?.string == "rpc_chunk" {
      guard let whole = chunks.accept(frame) else { return }
      frame = whole
    }
    handle(frame)
  }

  private func handle(_ frame: JSON) {
    switch frame["type"]?.string ?? "" {
    case "response":
      guard let id = frame["id"]?.string else { return }
      let reply = Reply(success: frame["success"]?.bool == true, data: frame["data"], error: frame["error"]?.string)
      if id == promptID { took(reply) }
      answer(id, with: .success(reply))
    case "extension_ui_request":
      // An own-setup extension asking the person: Serein never answers yes for them.
      guard let id = frame["id"]?.string, ["select", "confirm", "input", "editor"].contains(frame["method"]?.string ?? "") else { return }
      try? process.send(line: try JSONEncoder().encode(JSON.object(["type": .string("extension_ui_response"), "id": .string(id), "cancelled": .bool(true)])))
      if turnOpen {
        events.yield(.declined(PendingApprovalValue(id: id, tool: frame["title"]?.string ?? "pi", target: frame["message"]?.string ?? "")))
      }
    case "auto_compaction_start", "compaction_start":
      compacting = true
      holdTimer?.cancel()
    case "auto_compaction_end", "compaction_end":
      compacting = false
      resumeCompactionWaiters()
      if heldFailure != nil, frame["willRetry"]?.bool != true { armHold() }
    case "auto_retry_start":
      holdTimer?.cancel()
    case "auto_retry_end":
      if frame["success"]?.bool == false { endTurn(.failed(frame["finalError"]?.string ?? heldFailure ?? "Pi's retries failed.")) }
    default:
      guard turnOpen else { return }
      turnEvent(frame)
    }
  }

  private func turnEvent(_ frame: JSON) {
    let message = frame["message"]
    switch frame["type"]?.string ?? "" {
    case "agent_start":
      promptID = nil
      // A retry runs as a new agent loop: the failure before it is void.
      heldFailure = nil
      holdTimer?.cancel()
      stopReason = nil
      errorText = nil
    case "message_start":
      if message?["role"]?.string == "assistant", spoke { events.yield(.newMessage) }
    case "message_update":
      let update = frame["assistantMessageEvent"]
      guard let delta = update?["delta"]?.string else { return }
      switch update?["type"]?.string {
      case "text_delta":
        spoke = true
        events.yield(.text(delta))
      case "thinking_delta": events.yield(.thinking(delta))
      default: break
      }
    case "message_end":
      guard message?["role"]?.string == "assistant", let used = message?["usage"] else { return }
      let now = usage ?? (0, 0, 0)
      usage = (
        now.input + Int(used["input"]?.number ?? 0), now.output + Int(used["output"]?.number ?? 0),
        now.cached + Int(used["cacheRead"]?.number ?? 0)
      )
    case "tool_execution_start":
      let id = frame["toolCallId"]?.string ?? UUID().uuidString
      let name = frame["toolName"]?.string ?? "tool"
      let arguments = (try? Self.canonical.encode(frame["args"] ?? .null)).map { String(decoding: $0, as: UTF8.self) } ?? ""
      events.yield(.toolStarted(id: id, name: name, arguments: arguments, shellCommand: name == "bash" ? frame["args"]?["command"]?.string : nil))
    case "tool_execution_end":
      guard let id = frame["toolCallId"]?.string else { return }
      events.yield(.toolEnded(id: id, result: frame["isError"]?.bool == true ? .failed : .ok))
    case "turn_end":
      // toolUse: Pi runs the tool and goes on; a later turn_end carries the outcome.
      let reason = message?["stopReason"]?.string
      guard reason != "toolUse" else { return }
      stopReason = reason
      errorText = message?["errorMessage"]?.string
    case "agent_end":
      // Pi 1.x sets willRetry before its own retry; Oh My Pi sets isTerminal false while it has more to do.
      if frame["willRetry"]?.bool == true || frame["isTerminal"]?.bool == false { return }
      if stopReason == nil, let last = frame["messages"]?.array?.last(where: { $0["role"]?.string == "assistant" }) {
        stopReason = last["stopReason"]?.string
        errorText = last["errorMessage"]?.string
      }
      finishTurn()
    case "agent_settled":
      finishTurn()
    default:
      break
    }
  }

  private func finishTurn() {
    guard heldFailure == nil else { return }
    switch stopReason {
    case "error":
      heldFailure = errorText ?? "Pi stopped with an error."
      armHold()
    case "length": endTurn(.turnDone(.maxTokens))
    case "aborted": endTurn(.turnDone(.stopped))
    default: endTurn(.turnDone(.endTurn))
    }
  }

  private func armHold() {
    holdTimer?.cancel()
    let grace = retryGrace
    holdTimer = Task {
      try? await Task.sleep(for: grace)
      guard !Task.isCancelled else { return }
      self.holdDue()
    }
  }

  private func holdDue() {
    if let heldFailure, !compacting { endTurn(.failed(heldFailure)) }
  }

  private func beginTurn() {
    turnOpen = true
    stopReason = nil
    errorText = nil
    spoke = false
    usage = nil
    heldFailure = nil
    holdTimer?.cancel()
  }

  private func endTurn(_ event: WireEvent) {
    guard turnOpen else { return }
    turnOpen = false
    heldFailure = nil
    holdTimer?.cancel()
    if let usage { events.yield(.usage(input: usage.input, output: usage.output, cachedInput: usage.cached)) }
    events.yield(event)
  }

  private func closeWire() {
    closed = true
    holdTimer?.cancel()
    for id in Array(waiters.keys) { answer(id, with: .failure(CallError.noAnswer)) }
    resumeCompactionWaiters()
    events.finish()
  }

  private func resumeCompactionWaiters() {
    let waiting = compactionWaiters
    compactionWaiters = []
    for waiter in waiting { waiter.resume() }
  }

  // MARK: Values

  private static let canonical: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// `provider/id`, as Pi names a model on argv.
  static func modelID(_ model: JSON?) -> String? {
    if let text = model?.string, !text.isEmpty { return text }
    guard let id = model?["id"]?.string, !id.isEmpty else { return nil }
    guard let provider = model?["provider"]?.string, !provider.isEmpty else { return id }
    return "\(provider)/\(id)"
  }

  /// Pi's prompt frame carries each image as base64.
  private static func image(_ file: URL) throws -> JSON {
    let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
    return .object([
      "type": .string("image"), "data": .string(try Data(contentsOf: file).base64EncodedString()),
      "mimeType": .string(types[file.pathExtension.lowercased()] ?? "image/png"),
    ])
  }
}

/// Oh My Pi's RPC v2 splits a frame over 1 MiB into base64 `rpc_chunk` pieces: `chunkId`,
/// `count` and `byteLength` per frame, a sequential `index`, `data` per piece. Any mismatch drops
/// the whole sequence.
struct PiChunks {
  static let maxBytes = 64 * 1024 * 1024
  static let maxPiece = 256 * 1024
  private var chunkID: String?
  private var count = 0
  private var byteLength = 0
  private var parts = Data()
  private var received = 0

  mutating func accept(_ frame: JSON) -> JSON? {
    guard let id = frame["chunkId"]?.string, !id.isEmpty, let encoded = frame["data"]?.string, !encoded.isEmpty,
      encoded.count <= (Self.maxPiece + 2) / 3 * 4,
      let index = frame["index"]?.number.map(Int.init), let count = frame["count"]?.number.map(Int.init),
      let byteLength = frame["byteLength"]?.number.map(Int.init),
      index >= 0, count >= 2, count <= Self.maxBytes / Self.maxPiece, index < count,
      byteLength >= 0, byteLength <= Self.maxBytes
    else { return reset() }
    if id != chunkID {
      guard index == 0 else { return reset() }
      chunkID = id
      self.count = count
      self.byteLength = byteLength
      parts = Data()
      received = 0
    } else if count != self.count || byteLength != self.byteLength {
      return reset()
    }
    // An empty piece would let a sequence grow without nearing `byteLength`.
    guard let piece = Data(base64Encoded: encoded), index == received, !piece.isEmpty, piece.count <= Self.maxPiece,
      parts.count + piece.count <= self.byteLength
    else { return reset() }
    parts.append(piece)
    received += 1
    guard received == self.count else { return nil }
    let whole = parts.count == self.byteLength ? parts : nil
    _ = reset()
    guard let whole, let decoded = try? JSONDecoder().decode(JSON.self, from: whole), case .object = decoded else { return nil }
    return decoded
  }

  private mutating func reset() -> JSON? {
    chunkID = nil
    count = 0
    byteLength = 0
    parts = Data()
    received = 0
    return nil
  }
}
