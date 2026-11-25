
import Foundation
import SereinCore
import UniformTypeIdentifiers

/// How one ACP CLI differs from the others. Each ACP driver builds its own; nothing in this file
/// names a CLI.
struct ACPDialect: Sendable {
  enum ModelSetting: Sendable, Equatable {
    case setModel
    /// `session/set_config_option` with this config id.
    case configOption(String)
    /// The driver put it on argv; a new model is a new process.
    case onArgv
  }

  var cli: HarnessDriver
  /// Added to `clientCapabilities` as `_meta`.
  var clientMeta: JSON? = nil
  var model: ModelSetting = .setModel
  /// The config option the effort goes to, sent after the model whose levels it belongs to.
  var effortOption: String? = nil
  /// The CLI accepts every model id it lists, so its refusal is real and ends the turn. Otherwise
  /// the CLI's own default stands.
  var modelRefusalEndsTurn = false
  /// The stable prompt reaches the CLI through its own system-prompt channel, so the first prompt
  /// of a fresh session leaves it out.
  var stableElsewhere = false
  /// Refines a permission request's kind from the CLI's own metadata (`params` is untrusted).
  var permissionKind: (@Sendable (HarnessPermissionRequest, [String: Any]) -> HarnessPermissionRequest.Kind)? = nil
  /// The CLI's own notification method that carries `retry_state` updates.
  var extensionUpdates: String? = nil
  /// Optional ACP notification method used for mid-turn steering (or nil when advertised dynamically).
  var steerMethod: String? = nil
  /// Fallback mid-turn steer by cancelling the current turn and handing text back for the next turn.
  var supportsCancelResumeSteer: Bool = false
}

/// One ACP agent process after its handshake: one session, reused by every turn while warm.
final class ACPSession: EngineSession {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  /// Whether this ACP session accepts mid-turn steering (via steer method or cancel-and-resume).
  var steers: Bool { supportsSteer }
  private let supportsSteer: Bool
  private let link: ACPLink

  private init(mode: VerifiedMode, link: ACPLink, supportsSteer: Bool) {
    self.mode = mode
    self.link = link
    self.supportsSteer = supportsSteer
    wire = link.wire
  }

  /// Initialize, then load or start the session, set its model, and read the mode back. Throws a
  /// `StopReason` to refuse.
  static func open(
    _ process: EngineProcess, contract: LaunchContract, request: TurnRequest, dialect: ACPDialect
  ) async throws -> ACPSession {
    let link = ACPLink(rpc: JSONRPC(process), dialect: dialect, request: request)
    await link.start()
    do {
      try await link.handshake()
    } catch JSONRPCError.closed {
      throw StopReason.failed("\(dialect.cli.displayName) quit while starting.")
    }
    let advertisedSteer = await link.advertisesSteer
    let canSteer = dialect.steerMethod != nil || dialect.supportsCancelResumeSteer || advertisedSteer
    switch ModeCheck.verify(contract.expectedMode, reported: await link.reported, argv: contract.argv) {
    case .success(let mode): return ACPSession(mode: mode, link: link, supportsSteer: canSteer)
    case .failure(let reason): throw reason
    }
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    await link.prompt(prompt, request: request)
  }

  func steer(_ text: String) async -> SteerOutcome { await link.steer(text) }

  func cancel() async { await link.cancel() }
}

/// The ACP conversation, on its own actor so the incoming loop and a turn never race.
private actor ACPLink {
  nonisolated let wire: AsyncStream<WireEvent>
  private let events: AsyncStream<WireEvent>.Continuation
  private let rpc: JSONRPC
  private let dialect: ACPDialect
  private let request: TurnRequest
  private let grant: HarnessGrant
  private let folder: URL
  private let isTask: Bool

  private var sessionID: String?
  private var loadSession = false
  private var acceptsImages = false
  private(set) var advertisesSteer = false
  /// A new session: the stable prompt still has to lead its first prompt.
  private var fresh = true
  /// `resume` was asked for and not loaded, so the first prompt carries `prompt.recovery`.
  private var rebuilt = false
  /// Set until this turn announced its session: whether it replaced a refused resume.
  private var announce: Bool?
  /// `available_commands_update` per session id; load may announce before its response.
  private var advertised: [String: [SlashCommand]] = [:]
  private var promptSent = false
  private var accepted = false
  private var textSinceTool = false
  private var toolSinceText = false
  /// Incoming messages handled, against `JSONRPC.yielded`, so a turn ends after its last update.
  private var handled = 0
  private var drainWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  /// The CLI said how full its context is this turn; otherwise Serein estimates.
  private var contextReported = false
  private var estimatedTokens = 0
  /// The session's config options as the CLI reported them (OpenCode's `mode` is its agent).
  private(set) var reported: [String: String] = [:]
  /// What `choose` last set, so a warm session follows a changed picker.
  private var chosen: [String?] = []
  /// This turn: Serein asked the CLI to stop.
  private var stopAsked = false
  /// This turn: the last tool Serein refused, the CLI's model retries, and why Serein gave up on them.
  private var refused: String?
  private var retries = 0
  private var gaveUp: String?
  /// Model retries Serein waits through before it ends the turn: Grok 1.0.88 sends its fourth
  /// about 12 s in and keeps backing off for minutes.
  static let retryLimit = 4

  init(rpc: JSONRPC, dialect: ACPDialect, request: TurnRequest) {
    self.rpc = rpc
    self.dialect = dialect
    self.request = request
    grant = ACPGrant.of(request)
    folder = request.access.folder ?? ACPGrant.emptyFolder
    if case .task = request.access { isTask = true } else { isTask = false }
    (wire, events) = AsyncStream<WireEvent>.makeStream()
  }

  func start() {
    Task { await self.listen() }
  }

  // MARK: Handshake

  func handshake() async throws {
    var capabilities: [String: JSON] = [
      "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false),
    ]
    if let meta = dialect.clientMeta { capabilities["_meta"] = meta }
    let initialized = try await call("initialize", .object([
      "protocolVersion": .number(1),
      "clientCapabilities": .object(capabilities),
      "clientInfo": .object(["name": .string("serein"), "title": .string("Serein"), "version": .string("1")]),
    ]))
    let agent = initialized["agentCapabilities"]
    loadSession = agent?["loadSession"]?.bool == true
    acceptsImages = agent?["promptCapabilities"]?["image"]?.bool == true
    advertisesSteer = agent?["steer"]?.bool == true
    // Never `authenticate`: Cursor answers it by opening its sign-in page in the browser. A
    // signed-out CLI says so at session/new instead.
    let mcp = Self.mcpServers(request)
    if let resume = request.scopedResume {
      if loadSession {
        do {
          // A long history replays before the answer comes.
          let loaded = try await call("session/load", .object([
            "sessionId": .string(resume), "cwd": .string(folder.path), "mcpServers": mcp,
          ]), deadline: .seconds(180))
          read(session: loaded)
          sessionID = resume
          fresh = false
        } catch let reason as StopReason {
          // A session the CLI no longer has, or any other refusal, starts a new one below.
          if case .signIn = reason { throw reason }
        }
      }
      rebuilt = sessionID == nil
    }
    if sessionID == nil {
      let created = try await call("session/new", .object(["cwd": .string(folder.path), "mcpServers": mcp]))
      guard let id = created["sessionId"]?.string, !id.isEmpty else {
        throw StopReason.failed("\(dialect.cli.displayName) did not start a session.")
      }
      sessionID = id
      read(session: created)
    }
    if dialect.cli == .opencode, reported["mode"] != "build", let sessionID {
      // Older ACP peers acknowledge set_mode but omit configOptions from session/new, and a
      // session can open in another agent (the person's default, or the one it was left in).
      _ = try await call("session/set_mode", .object(["sessionId": .string(sessionID), "modeId": .string("build")]))
      reported["mode"] = "build"
    }
    try await choose(model: request.model, effort: request.effort)
  }

  private func read(session: JSON) {
    if let mode = session["modes"]?["currentModeId"]?.string { reported["mode"] = mode }
    read(options: session["configOptions"])
  }

  private func read(options: JSON?) {
    for option in options?.array ?? [] {
      if let id = option["id"]?.string, let value = option["currentValue"]?.string { reported[id] = value }
    }
  }

  /// The model first, then the effort that belongs to it. No model keeps the CLI's own default.
  private func choose(model: String?, effort: String?) async throws {
    chosen = [model, effort]
    guard let sessionID, let model, !model.isEmpty else { return }
    let (method, params): (String, JSON)
    switch dialect.model {
    case .onArgv:
      return
    case .setModel:
      (method, params) = ("session/set_model", .object(["sessionId": .string(sessionID), "modelId": .string(model)]))
    case .configOption(let id):
      (method, params) = (
        "session/set_config_option",
        .object(["sessionId": .string(sessionID), "configId": .string(id), "value": .string(model)])
      )
    }
    do {
      _ = try await rpc.request(method, params, deadline: .seconds(30))
    } catch JSONRPCError.remote(let code, let message) {
      if HarnessParse.acpNeedsSignIn(code: code, message: message, driver: dialect.cli) {
        throw StopReason.signIn(dialect.cli.signedOutReason ?? message)
      }
      // -32601: this version has no setter, so its own default stands.
      if dialect.modelRefusalEndsTurn, code != -32601 { throw StopReason.modelRejected(String(message.prefix(1_500))) }
    } catch JSONRPCError.timedOut {
      if dialect.modelRefusalEndsTurn { throw StopReason.failed("\(dialect.cli.displayName) did not answer \(method).") }
    }
    if let option = dialect.effortOption, let effort, !effort.isEmpty {
      _ = try? await call("session/set_config_option", .object([
        "sessionId": .string(sessionID), "configId": .string(option), "value": .string(effort),
      ]))
    }
  }

  // MARK: Turn

  func prompt(_ prompt: TurnPrompt, request: TurnRequest) async {
    guard let sessionID else {
      events.yield(.turnDone(.failed("\(dialect.cli.displayName) has no session.")))
      return
    }
    if chosen != [request.model, request.effort] {
      do {
        try await choose(model: request.model, effort: request.effort)
      } catch {
        events.yield(.turnDone(error as? StopReason ?? .failed(String(describing: error))))
        return
      }
    }
    let blocks: [JSON]
    if let command = prompt.command {
      // Announcements may follow the load response: wait for them, never for a model. A session
      // command runs only on a resumed session that advertised it now, never as plain text.
      for _ in 0..<20 where advertised[sessionID] == nil { try? await Task.sleep(for: .milliseconds(50)) }
      guard !fresh, SlashCommands.nativeACPNames.contains(command),
        advertised[sessionID]?.contains(where: { $0.nativeName == command }) == true
      else {
        events.yield(.turnDone(.failed("\(dialect.cli.displayName) did not advertise /\(command) for the resumed session.")))
        return
      }
      blocks = [Self.text("/" + command)]
    } else {
      guard request.images.isEmpty || acceptsImages else {
        events.yield(.turnDone(.failed(
          "This \(dialect.cli.displayName) version does not take images. Update it or send the message without one.")))
        return
      }
      do {
        blocks = [Self.text(compose(prompt, schema: request.schema))] + (try request.images.map(Self.image))
      } catch {
        events.yield(.turnDone(.failed("Could not read the image: \(error.localizedDescription)")))
        return
      }
    }
    estimatedTokens += Self.characters(blocks) / 4
    fresh = false
    announce = rebuilt
    rebuilt = false
    promptSent = true
    accepted = false
    textSinceTool = false
    toolSinceText = false
    contextReported = false
    stopAsked = false
    refused = nil
    retries = 0
    gaveUp = nil
    if let commands = advertised[sessionID] { events.yield(.commands(commands)) }
    let outcome: Result<JSON, StopReason>
    do {
      // The stuck watch covers silence; the deadline only frees a dead request.
      outcome = .success(try await call(
        "session/prompt", .object(["sessionId": .string(sessionID), "prompt": .array(blocks)]),
        deadline: .seconds(86_400)))
    } catch let reason as StopReason {
      outcome = .failure(reason)
    } catch {
      // The process closed: its exit ends the turn.
      promptSent = false
      return
    }
    await drain()
    promptSent = false
    switch outcome {
    case .failure(.failed(let message)):
      // The machine reads the CLI's own words: usage limit, key, model, offline.
      events.yield(.failed(message))
    case .failure(let reason):
      events.yield(.turnDone(reason))
    case .success(let result):
      acknowledge()
      report(usage: result["usage"] ?? result["_meta"])
      if !contextReported, estimatedTokens > 0 {
        events.yield(.context(used: estimatedTokens, size: nil, estimated: true))
      }
      let reason = Self.stopReason(result["stopReason"]?.string)
      if reason == .stopped, !stopAsked, let gaveUp {
        events.yield(.failed(gaveUp))
      } else if reason == .stopped, !stopAsked, let refused {
        // Grok ends the whole prompt `cancelled` when one ask is refused; nobody pressed Stop.
        events.yield(.turnDone(.declined(refused)))
      } else {
        events.yield(.turnDone(reason))
      }
    }
  }

  /// Stop: the CLI is asked to end its own tools, and gets a moment to answer the prompt before
  /// its input closes.
  func cancel() async {
    guard promptSent, let sessionID else { return }
    stopAsked = true
    try? await rpc.notify("session/cancel", .object(["sessionId": .string(sessionID)]))
    for _ in 0..<100 where promptSent { try? await Task.sleep(for: .milliseconds(20)) }
  }

  /// Steer the running turn when the agent or dialect supports a steer notification, or cancel the
  /// in-flight turn and hand the text back so the caller runs it cleanly on the warm session.
  func steer(_ text: String) async -> SteerOutcome {
    guard promptSent, let sessionID else { return .handedBack(text) }
    if let method = dialect.steerMethod ?? (advertisesSteer ? "session/steer" : nil) {
      do {
        try await rpc.notify(method, .object(["sessionId": .string(sessionID), "prompt": .array([Self.text(text)])]))
        return .steered
      } catch {
        return .handedBack(text)
      }
    }
    if dialect.supportsCancelResumeSteer {
      await cancel()
      return .handedBack(text)
    }
    return .handedBack(text)
  }

  /// A fresh session's first prompt leads with the stable part, unless the CLI took it on its
  /// own channel; a session that replaced a refused resume gets the conversation (`recovery`).
  private func compose(_ prompt: TurnPrompt, schema: String?) -> String {
    let message = rebuilt ? prompt.recovery ?? prompt.message : prompt.message
    let stable = fresh && !dialect.stableElsewhere ? prompt.stable : ""
    // ACP has no output schema: a pure-answer caller's schema rides in the message.
    let schema = schema.map { "Reply with only JSON that matches this JSON Schema, and nothing else:\n" + $0 } ?? ""
    return [stable, prompt.volatile, message, schema].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// Some CLIs count cache reads inside `inputTokens`, OpenCode beside it: beside when the total
  /// (if given) covers both.
  private func report(usage: JSON?) {
    let input = usage?["inputTokens"]?.number, output = usage?["outputTokens"]?.number
    guard input != nil || output != nil else { return }
    let read = usage?["cachedReadTokens"]?.number.flatMap { $0 > 0 ? $0 : nil }
    let inputCount = input ?? 0, outputCount = output ?? 0
    var cached: Double?
    var total = inputCount
    if let read {
      let beside = (usage?["totalTokens"]?.number).map { $0 >= inputCount + outputCount + read } ?? true
      total = beside ? inputCount + read : inputCount
      cached = beside ? read : min(read, inputCount)
    }
    events.yield(.usage(input: Int(total), output: Int(outputCount), cachedInput: cached.map { Int($0) }))
  }

  /// `session/prompt` stop reasons. `max_turn_requests` is a cut-short turn too.
  static func stopReason(_ reason: String?) -> StopReason {
    switch reason {
    case "max_tokens", "max_turn_requests": return .maxTokens
    case "cancelled": return .stopped
    case "refusal": return .refusal
    default: return .endTurn
    }
  }

  // MARK: Incoming

  private func listen() async {
    for await message in rpc.incoming {
      switch message {
      case .request(let id, let method, let params):
        if method == "session/request_permission" {
          try? await rpc.respond(to: id, result: answerPermission(params))
        } else {
          // No file system, terminal or other client capability is offered.
          try? await rpc.respond(to: id, errorCode: -32601, message: "Not supported by Serein")
        }
      case .notification(let method, let params):
        if method == "session/update" { update(params) }
        if method == dialect.extensionUpdates, params["update"]?["sessionUpdate"]?.string == "retry_state" { await retrying(params) }
      }
      handled += 1
      let ready = drainWaiters.filter { $0.0 <= handled }
      drainWaiters.removeAll { $0.0 <= handled }
      for (_, waiter) in ready { waiter.resume() }
    }
    for (_, waiter) in drainWaiters { waiter.resume() }
    drainWaiters = []
    events.finish()
  }

  /// Waits until every message the CLI sent before the prompt's result has been handled.
  private func drain() async {
    let target = await rpc.yielded
    guard handled < target else { return }
    await withCheckedContinuation { drainWaiters.append((target, $0)) }
  }

  private func update(_ params: JSON) {
    guard let session = params["sessionId"]?.string, let update = params["update"] else { return }
    let kind = update["sessionUpdate"]?.string ?? ""
    if kind == "available_commands_update" {
      // Kept for a few sessions: load announces them for the session it is about to return.
      guard session.count <= 200, let raw = Self.any(update) as? [String: Any],
        advertised.count < 8 || advertised[session] != nil
      else { return }
      advertised[session] = SlashCommands.advertised(raw, driver: dialect.cli) ?? []
      if session == sessionID, promptSent, let commands = advertised[session] { events.yield(.commands(commands)) }
      return
    }
    // Load replays history; none of it is this turn.
    guard session == sessionID, promptSent, params["_meta"]?["isReplay"]?.bool != true else { return }
    switch kind {
    case "agent_message_chunk":
      guard update["content"]?["type"]?.string == "text", let text = update["content"]?["text"]?.string, !text.isEmpty
      else { return }
      acknowledge()
      if toolSinceText, textSinceTool { events.yield(.newMessage) }
      toolSinceText = false
      textSinceTool = true
      estimatedTokens += text.count / 4
      events.yield(.text(text))
    case "agent_thought_chunk":
      acknowledge()
      if let text = update["content"]?["text"]?.string, !text.isEmpty { events.yield(.thinking(text)) }
    case "tool_call":
      acknowledge()
      toolSinceText = true
      let id = update["toolCallId"]?.string ?? UUID().uuidString
      let input = update["rawInput"]
      let shell = update["kind"]?.string == "execute" ? input?["command"]?.string : nil
      events.yield(.toolStarted(
        // OpenCode's `name` is the tool ("shell"); its `title` describes the call ("ls").
        id: id, name: String((update["name"]?.string ?? update["title"]?.string ?? update["kind"]?.string ?? "tool").prefix(120)),
        arguments: input.map(Self.canonical) ?? "", shellCommand: shell))
      toolEnded(id, status: update["status"]?.string)
    case "tool_call_update":
      acknowledge()
      guard let id = update["toolCallId"]?.string else { return }
      toolEnded(id, status: update["status"]?.string)
    case "usage_update":
      // `used` and `size` flat or under `usage`.
      if let used = (update["used"] ?? update["usage"]?["used"])?.number, used > 0 {
        contextReported = true
        estimatedTokens = Int(used)
        events.yield(.context(
          used: Int(used), size: (update["size"] ?? update["usage"]?["size"])?.number.map { Int($0) }, estimated: false))
      }
    default:
      return
    }
  }

  /// The CLI is retrying its model. Each try is shown; after `retryLimit` the turn ends with the
  /// CLI's own reason instead of waiting out its backoff.
  private func retrying(_ params: JSON) async {
    guard params["sessionId"]?.string == sessionID, promptSent, let sessionID, gaveUp == nil else { return }
    acknowledge()
    retries += 1
    let why = String((params["update"]?["reason"]?.string ?? "no reason given").prefix(600))
    events.yield(.notice("\(dialect.cli.displayName) is retrying its model (\(retries)): \(why)"))
    guard retries >= Self.retryLimit else { return }
    gaveUp = "\(dialect.cli.displayName) could not reach its model after \(retries) tries: \(why)"
    try? await rpc.notify("session/cancel", .object(["sessionId": .string(sessionID)]))
  }

  private func toolEnded(_ id: String, status: String?) {
    switch status {
    case "completed": events.yield(.toolEnded(id: id, result: .ok))
    case "failed": events.yield(.toolEnded(id: id, result: .failed))
    default: return
    }
  }

  /// The CLI started on the prompt: from here a replay could run a tool twice. The session is
  /// announced only now, as the machine counts it as started too.
  private func acknowledge() {
    guard promptSent, !accepted else { return }
    accepted = true
    events.yield(.accepted)
    if let sessionID, let rebuilt = announce {
      announce = nil
      events.yield(.session(id: sessionID, rebuilt: rebuilt))
    }
  }

  /// Serein's grant decides, and the answer is picked by option kind, never by position: allow
  /// once, never always, so nothing persists in the CLI. No matching option answers `cancelled`.
  private func answerPermission(_ params: JSON) -> JSON {
    let cancelled: JSON = .object(["outcome": .object(["outcome": .string("cancelled")])])
    guard promptSent, params["sessionId"]?.string == sessionID, let raw = Self.any(params) as? [String: Any],
      let parsed = ACPMessages.permissionRequest(raw)
    else { return cancelled }
    var asked = parsed.request
    if let refine = dialect.permissionKind { asked.kind = refine(asked, raw) }
    let answer = HarnessApprovals.decide(asked, grant: grant, folder: folder.path)
    if !answer.allow { refused = asked.title }
    if let approval = answer.approval, !isTask {
      events.yield(.declined(PendingApprovalValue(id: approval.id, tool: approval.tool, target: approval.target)))
    } else {
      events.yield(.permissionAnswered(allowed: answer.allow))
    }
    guard let option = HarnessApprovals.acpOption(parsed.options, allow: answer.allow) else { return cancelled }
    return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])])
  }

  // MARK: Helpers

  /// One request. A remote error comes back as a `StopReason`: sign-in when the CLI asks for it,
  /// else `.failed` with its own words, which the machine classifies.
  private func call(_ method: String, _ params: JSON, deadline: Duration = .seconds(30)) async throws -> JSON {
    do {
      return try await rpc.request(method, params, deadline: deadline)
    } catch JSONRPCError.remote(let code, let message) {
      if HarnessParse.acpNeedsSignIn(code: code, message: message, driver: dialect.cli) {
        throw StopReason.signIn(dialect.cli.signedOutReason ?? message)
      }
      throw StopReason.failed(String(message.prefix(1_500)))
    } catch JSONRPCError.timedOut(let method) {
      throw StopReason.failed("\(dialect.cli.displayName) did not answer \(method).")
    }
  }

  /// The browser server, unless the person's own setup runs (their MCP servers, not Serein's).
  static func mcpServers(_ request: TurnRequest) -> JSON {
    guard let browser = request.browser, !ACPGrant.ownSetup(request) else { return .array([]) }
    return .array([.object([
      "name": .string("serein_browser"), "command": .string(browser.command.path),
      "args": .array(browser.arguments.map(JSON.string)), "env": .array([]),
    ])])
  }

  static func text(_ text: String) -> JSON { .object(["type": .string("text"), "text": .string(text)]) }

  static func image(_ url: URL) throws -> JSON {
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
    return .object([
      "type": .string("image"), "mimeType": .string(mime), "data": .string(try Data(contentsOf: url).base64EncodedString()),
    ])
  }

  static func characters(_ blocks: [JSON]) -> Int {
    blocks.reduce(0) { $0 + ($1["text"]?.string?.count ?? 0) }
  }

  static func canonical(_ json: JSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  static func any(_ json: JSON) -> Any? {
    (try? JSONEncoder().encode(json)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
  }
}

/// Serein's access in the terms the shared permission rules use.
enum ACPGrant {
  static func of(_ request: TurnRequest) -> HarnessGrant {
    var grant = access(request)
    grant.level = request.level
    return grant
  }
  private static func access(_ request: TurnRequest) -> HarnessGrant {
    let own = ownSetup(request)
    switch request.access {
    case .answer: return HarnessGrant(mode: "answer", edits: false, permission: .supervised, ownSetup: own)
    case .web: return HarnessGrant(mode: "research", edits: false, permission: .supervised, ownSetup: own)
    case .library: return HarnessGrant(mode: "library", edits: false, permission: .supervised, ownSetup: own)
    case .ownSetup: return HarnessGrant(mode: "project", edits: false, permission: .supervised, ownSetup: true)
    case .task: return HarnessGrant(mode: "project", edits: true, permission: .fullAccess, ownSetup: own)
    case .project(_, let level):
      switch level {
      case .review: return HarnessGrant(mode: "project", edits: false, permission: .supervised, ownSetup: own)
      case .edits: return HarnessGrant(mode: "project", edits: true, permission: .autoAcceptEdits, ownSetup: own)
      case .commands: return HarnessGrant(mode: "project", edits: true, permission: .auto, ownSetup: own)
      case .full: return HarnessGrant(mode: "project", edits: true, permission: .fullAccess, ownSetup: own)
      }
    }
  }

  /// Full: the CLI asks nothing.
  static func full(_ request: TurnRequest) -> Bool { of(request).permission == .fullAccess }

  /// The person chose their own setup for this turn.
  static func ownSetup(_ request: TurnRequest) -> Bool {
    if case .ownSetup = request.access { return true }
    return request.ownSetup
  }

  /// ACP needs an absolute cwd; a turn with no folder gets a private empty one.
  static let emptyFolder: URL = {
    let folder = AgentAccess.defaultRoot.appendingPathComponent("engine-empty", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
  }()

  /// The environment an ACP CLI starts with: the person's own under their own setup (their keys
  /// reach their MCP servers), else Serein's with every provider key stripped; the person's
  /// variables and Keychain key for the CLI either way.
  static func environment(_ request: TurnRequest, own: [String: String] = [:]) -> [String: String] {
    CredentialEnv.child(request.cli, executable: request.executable, person: request.environment, own: own, ownSetup: ownSetup(request))
  }

}

/// `--version` for a probe. Sign-in shows at `session/new`, which a probe does not start.
enum ACPProbe {
  static func readiness(_ executable: URL, _ arguments: [String] = ["--version"]) async -> Readiness {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .missing }
    let environment = CredentialEnv.child(nil, executable: executable, person: [:])
    guard let said = CredentialEnv.output(executable, arguments, environment: environment, within: .seconds(10), folder: ACPGrant.emptyFolder)
    else { return .broken("\(executable.lastPathComponent) did not start or did not answer in time.") }
    let text = said.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard said.status == 0, let version = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else {
      return .broken(String(text.prefix(300)))
    }
    return .ready(version: String(text[version]))
  }
}
