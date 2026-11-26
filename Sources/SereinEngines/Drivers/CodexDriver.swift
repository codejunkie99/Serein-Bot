import CryptoKit
import Darwin
import Foundation
import SereinCore

/// Codex through `codex app-server`: one warm process per thread, each thread started with
/// Serein's permissions profile and read back before any prompt. A shell turn that the person's
/// exec-policy rules could let out of the sandbox, a folder with its own Codex config, and the
/// person's own setup run fresh through `codex exec`, which can ignore both.
struct CodexDriver: Driver {
  static let floor = HarnessDriver.codexMinimumVersion
  static let profile = "serein_task"
  /// A loaded Mac can take minutes to start the server and its MCP servers; later calls are quick.
  static let startupDeadline: Duration = .seconds(180)
  static let callDeadline: Duration = .seconds(60)
  /// Codex's own limit for one MCP server's startup, after which it reports it failed.
  static let mcpStartupWait: Duration = .seconds(30)
  /// Codex shells get only Codex's core variables (PATH, HOME, TMPDIR, USER, SHELL), the locale
  /// and the thread's proxy (`ShellNetwork.environment`), with no network fence.
  func shellEnvironment(_ network: ShellNetwork.Plan?) -> [String] {
    var set = network.map { ShellNetwork.environment(port: $0.port, inherited: inherited) } ?? [:]
    set["LANG"] = inherited["LANG"]
    let pairs = set.sorted { $0.key < $1.key }.map { "\($0.key)=" + jsonString($0.value) }.joined(separator: ", ")
    return [
      "shell_environment_policy.inherit=\"core\"", "shell_environment_policy.set={\(pairs)}",
      "shell_environment_policy.ignore_default_excludes=false",
    ]
  }

  let cli = HarnessDriver.codex
  let routesOwnShells = true
  let cardWait: Duration = .seconds(900)
  /// Serein's own environment; checks pass their own CODEX_HOME.
  var inherited = ProcessInfo.processInfo.environment
  var home = NSHomeDirectory()
  /// Off only in the live check on a Mac whose own config.toml overrides Serein's, to reach the app server.
  var checkConfigLayers = true

  /// What one access means in Codex's terms.
  struct Plan: Equatable {
    var folder: URL?
    var writable: Bool
    var shell: Bool
    var approvalPolicy = "never"
    /// `codex exec` instead of the warm app server.
    var exec = false
    /// The person's own config, MCP servers and environment (their explicit choice).
    var ownSetup = false
  }

  /// What the access allows; `route` then picks the transport.
  func plan(_ request: TurnRequest) -> Plan {
    var plan: Plan
    switch request.access {
    case .answer, .web: plan = Plan(folder: nil, writable: false, shell: false)
    case .library(let folder): plan = Plan(folder: folder, writable: false, shell: true)
    case .ownSetup(let folder): plan = Plan(folder: folder, writable: false, shell: true, ownSetup: true)
    case .project(let folder, .review): plan = Plan(folder: folder, writable: false, shell: true)
    case .project(let folder, .edits): plan = Plan(folder: folder, writable: true, shell: false)
    case .project(let folder, .commands): plan = Plan(folder: folder, writable: true, shell: true, approvalPolicy: "on-request")
    case .project(let folder, .full), .task(let folder): plan = Plan(folder: folder, writable: true, shell: true)
    }
    if request.ownSetup { plan.ownSetup = true }
    return plan
  }

  /// `codex exec` where the app server could run outside Serein's settings: the person's own
  /// setup, exec-policy rules (the app server has no --ignore-rules, and an allow rule runs its
  /// command outside the sandbox), a project's own Codex config, or a user config that overrides
  /// Serein's (read once per Codex home; unknown counts until it is read). Touches the disk.
  func route(_ plan: Plan, executable: URL) -> Plan {
    var plan = plan
    let codexHome = CodexChecks.codexHome(environment: inherited, home: home)
    plan.exec = plan.ownSetup || (checkConfigLayers && CodexPreflight.shared.verdict(for: self, executable: executable)?.problem.isEmpty != true)
    if let folder = plan.folder, !plan.exec {
      plan.exec =
        (plan.shell && CodexChecks.rulesPresent(codexHome: codexHome, folder: folder, home: home))
        || CodexChecks.projectConfigPresent(folder: folder, home: home) != nil
    }
    // `codex exec` cannot answer an approval request.
    if plan.exec { plan.approvalPolicy = "never" }
    return plan
  }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    let planned = plan(request)
    // Own setup is read-only and has no browser; a writable level cannot run under it.
    if planned.ownSetup && planned.writable { throw EngineRefusal.cliCannot(request.access) }
    let plan = route(planned, executable: request.executable)
    var environment = CredentialEnv.child(
      .codex, executable: request.executable, person: request.environment, ownSetup: plan.ownSetup, inherited: inherited)
    if plan.exec { return execContract(request, plan: plan, environment: environment, network: network) }
    // thread/start fixes the profile and browser for the process's life, so they belong in its warm key.
    let thread = jsonString([
      profile(plan, folder: plan.folder ?? Self.emptyFolder, request: request, network: network),
      request.browser.map(browserConfig) ?? [:],
    ])
    var contract = LaunchContract(
      request, arguments: serverArguments(network), environment: environment,
      expectedMode: .reports(["approvalPolicy": plan.approvalPolicy, "activePermissionProfile.id": Self.profile]),
      network: network)
    contract.warmTags["codexThread"] = SHA256.hash(data: Data(thread.utf8)).map { String(format: "%02x", $0) }.joined()
    return contract
  }

  /// Codex drops root-level -c once the subcommand has its own, so every -c goes after app-server.
  func serverArguments(_ network: ShellNetwork.Plan?) -> [String] {
    let configs =
      [
        "approval_policy=\"on-request\"", "approvals_reviewer=\"user\"", "sandbox_mode=\"read-only\"",
        "web_search=\"disabled\"", "notify=[]",
      ] + shellEnvironment(network) + CodexParams.offConfigs()
    return ["app-server", "--listen", "stdio://"] + configs.flatMap { ["-c", $0] }
  }

  private func execContract(
    _ request: TurnRequest, plan: Plan, environment: [String: String], network: ShellNetwork.Plan
  ) -> LaunchContract {
    let folder = plan.folder ?? Self.emptyFolder
    var arguments = ["exec"] + (plan.ownSetup ? [] : ["--ignore-user-config", "--strict-config"])
    arguments += ["--ignore-rules", "--skip-git-repo-check", "--json", "--color", "never", "-C", folder.path]
    if request.access == .answer { arguments.append("--ephemeral") }
    if let schema = request.schema { arguments += ["--output-schema", Self.schemaFile(schema).path] }
    var configs = [
      "default_permissions=\"\(Self.profile)\"",
      "permissions.\(Self.profile)=" + AgentFileGuard.toml(profile(plan, folder: folder, request: request, network: network)),
      "approval_policy=\"never\"", "web_search=\"disabled\"", "notify=[]", "features.shell_tool=\(plan.shell)",
      "features.view_image=false", "features.skill_mcp_dependency_install=false",
    ] + shellEnvironment(network)
    if !plan.shell { configs.append("features.unified_exec=false") }
    if let effort = request.effort, !effort.isEmpty { configs.append("model_reasoning_effort=" + jsonString(effort)) }
    if plan.ownSetup {
      // The person's config.toml loads for their MCP servers; the sandbox stays Serein's.
      configs += ["sandbox_mode=\"read-only\"", "tools.web_search=false"] + CodexParams.offConfigs(OwnSetup.codexFeaturesOff)
    } else {
      configs += CodexParams.offConfigs()
      // --ignore-user-config also drops where requests go; only that comes back.
      let routing = checkConfigLayers ? CodexPreflight.shared.verdict(for: self, executable: request.executable)?.routing : nil
      configs += CodexRouting.arguments(routing ?? [:], picked: request.model ?? "")
      if let browser = request.browser {
        configs += browserConfig(browser).sorted { $0.key < $1.key }.map { "\($0.key)=\(AgentFileGuard.toml($0.value))" }
      }
    }
    for config in configs { arguments += ["-c", config] }
    if let model = request.model, !model.isEmpty { arguments += ["--model", model] }
    return LaunchContract(
      request, arguments: arguments, resumeArguments: request.resume.map { ["resume", $0, "-"] } ?? ["-"],
      environment: environment, expectedMode: .nothing(flagOnArgv: ["-c", "approval_policy=\"never\""]), network: network)
  }

  /// `--output-schema` takes a file: one per schema, named by its hash, so a contract stays the same.
  static func schemaFile(_ schema: String) -> URL {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in schema.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return FileManager.default.temporaryDirectory.appendingPathComponent("serein-codex-schemas", isDirectory: true)
      .appendingPathComponent(String(hash, radix: 16) + ".json")
  }

  /// The empty folder a turn with no folder works in, and exec's schema file, rewritten each time.
  func prepare(_ contract: LaunchContract, request: TurnRequest) throws {
    let fm = FileManager.default
    if request.access.folder == nil {
      try fm.createDirectory(at: Self.emptyFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    if contract.arguments.first == "exec", let schema = request.schema {
      let file = Self.schemaFile(schema)
      try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try Data(schema.utf8).write(to: file, options: .atomic)
    }
  }

  /// Serein's profile for one folder. Where the turn has a shell its network is open, through the thread's proxy.
  func profile(_ plan: Plan, folder: URL, request: TurnRequest, network: ShellNetwork.Plan) -> [String: Any] {
    var privateRoots: [URL] = []
    if case .library = request.access {} else {
      privateRoots = AgentFileGuard.sereinPrivateRoots(home: URL(fileURLWithPath: home), library: AgentAccess.defaultRoot)
    }
    var profile = AgentFileGuard.codexProfile(
      folder: folder, writable: plan.writable, attachments: request.attachments,
      executable: request.executable.path, privateRoots: privateRoots, openHome: request.opensHome, widened: request.widened)
    if plan.shell || request.opensHome { profile["network"] = ShellNetwork.codexNetwork }
    // The shell may write TMPDIR, never Serein's own files there: a planted AGENTS.md in the
    // empty folder or a changed schema would reach the next turn.
    if var files = profile["filesystem"] as? [String: Any] {
      for owned in [Self.emptyFolder, Self.schemaFile("").deletingLastPathComponent()] {
        let path = owned.resolvingSymlinksInPath().standardizedFileURL.path
        if files[path] == nil { files[path] = "read" }
      }
      profile["filesystem"] = files
    }
    return profile
  }

  /// Serein's browser server, approved per tool. A tool call may wait on a secure card for `cardWait`.
  func browserConfig(_ browser: BrowserServer) -> [String: Any] {
    let prefix = "mcp_servers.\(CodexParams.browserServer)."
    var config: [String: Any] = [
      prefix + "command": browser.command.path, prefix + "args": browser.arguments,
      prefix + "tool_timeout_sec": Int(cardWait.components.seconds),
    ]
    for tool in browser.tools {
      config[prefix + "tools.\(tool).approval_mode"] = "approve"
    }
    return config
  }

  /// The private, empty folder a turn with no folder works in.
  static var emptyFolder: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("serein-codex-empty", isDirectory: true)
  }

  // MARK: Open

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    // The argv decides, not a second look at the disk: the process already runs it.
    if contract.arguments.first == "exec" {
      switch ModeCheck.verify(contract.expectedMode, reported: [:], argv: contract.argv) {
      case .success(let mode):
        // The person chose their own setup; a config that keeps the app server out is news to them.
        let problem = checkConfigLayers && !plan(request).ownSetup
          ? CodexPreflight.shared.verdict(for: self, executable: request.executable)?.problem : nil
        return CodexExecSession(
          process, mode: mode, resume: request.resume, ephemeral: contract.arguments.contains("--ephemeral"),
          notice: problem?.isEmpty == false ? problem : nil)
      case .failure(let reason): throw reason
      }
    }
    var plan = plan(request)
    plan.approvalPolicy = Self.policy(contract.expectedMode) ?? plan.approvalPolicy
    let folder = plan.folder ?? Self.emptyFolder
    let rpc = JSONRPC(process)
    let thread = CodexThread(rpc: rpc, folder: folder.path)
    Task { for await message in rpc.incoming { await thread.receive(message) }; await thread.closed() }

    _ = try await Self.call(rpc, "initialize", CodexParams.initialize(version: "1"), Self.startupDeadline)
    try await rpc.notify("initialized", .object([:]))
    let read = try await Self.call(rpc, "config/read", ["cwd": folder.path, "includeLayers": true], Self.startupDeadline)
    if checkConfigLayers, let problem = CodexChecks.configProblem(read) {
      // The verdict that routed here is stale: the next turn runs exec until it is read again.
      CodexPreflight.shared.forget(self, executable: request.executable)
      throw StopReason.failed(problem)
    }

    // Every thread carries its own profile: one without falls back to the person's config.toml.
    var config = CodexParams.threadConfig(
      CodexRunSettings(
        cwd: folder.path, model: "", effort: request.effort ?? "", instructions: "", writable: plan.writable,
        shell: plan.shell, helperPath: "", helperArgs: [], tools: []),
      disable: CodexParams.configuredServers(read)
    ).filter { !$0.key.hasPrefix("mcp_servers.\(CodexParams.browserServer).") }
    if let browser = request.browser { config.merge(browserConfig(browser)) { _, mine in mine } }
    config["default_permissions"] = Self.profile
    let sent = profile(plan, folder: folder, request: request, network: contract.network)
    config["permissions.\(Self.profile)"] = sent
    // Never `sandbox`: Codex would take it over the profile.
    var params: [String: Any] = [
      "cwd": folder.path, "approvalPolicy": plan.approvalPolicy, "approvalsReviewer": "user",
      "developerInstructions": request.prompt.stable, "config": config,
    ]
    if let model = request.model, !model.isEmpty { params["model"] = model }
    // A pure answer leaves no thread on disk.
    if request.access == .answer { params["ephemeral"] = true }

    var rebuilt = false
    var started: Any
    if let resume = request.resume {
      do {
        started = try await Self.resume(rpc, id: resume, params)
      } catch let error as JSONRPCError where Self.resumeGone(error, id: resume) {
        rebuilt = true
        started = try await Self.call(rpc, "thread/start", params, Self.startupDeadline)
      } catch JSONRPCError.remote(_, let message) {
        throw StopReason.resumeFailed(message)
      }
    } else {
      started = try await Self.call(rpc, "thread/start", params, Self.startupDeadline)
    }

    let response = started as? [String: Any] ?? [:]
    guard let id = (response["thread"] as? [String: Any])?["id"] as? String else {
      throw StopReason.failed("The Codex server started no thread.")
    }
    let reported = [
      "approvalPolicy": response["approvalPolicy"] as? String,
      "activePermissionProfile.id": (response["activePermissionProfile"] as? [String: Any])?["id"] as? String,
    ].compactMapValues { $0 }
    let mode: VerifiedMode
    switch ModeCheck.verify(contract.expectedMode, reported: reported, argv: contract.argv) {
    case .success(let verified): mode = verified
    case .failure(let reason): throw reason
    }
    // Read back against the profile this thread was sent: Codex lists every root it writes.
    if let problem = CodexChecks.threadProblem(
      response, writable: plan.writable, approvalPolicy: plan.approvalPolicy, profile: Self.profile,
      opened: CodexChecks.profileWrites(sent))
    {
      throw StopReason.modeMismatch(name: "sandbox", expected: Self.profile, reported: problem)
    }
    let extra = CodexChecks.unexpectedServers(["data": try await Self.all(rpc, "mcpServerStatus/list", CodexParams.serverStatus(thread: id))])
    guard extra.isEmpty else {
      throw StopReason.failed("Codex has MCP servers Serein could not switch off: \(extra.joined(separator: ", ")).")
    }
    let features = try await Self.all(rpc, "experimentalFeature/list", ["threadId": id, "limit": 500])
    if let problem = CodexChecks.featureProblem(features, shell: plan.shell) { throw StopReason.failed(problem) }
    // Codex starts MCP servers alongside the thread and samples without waiting for them.
    if request.browser != nil { await thread.settled([CodexParams.browserServer], within: Self.mcpStartupWait) }
    await thread.opened(id: id, rebuilt: rebuilt)
    return CodexAppSession(mode: mode, rpc: rpc, thread: thread, approvalPolicy: plan.approvalPolicy)
  }

  static func policy(_ mode: ExpectedMode) -> String? {
    if case .reports(let values) = mode { return values["approvalPolicy"] }
    return nil
  }

  /// An archived thread is unarchived once and resumed.
  private static func resume(_ rpc: JSONRPC, id: String, _ params: [String: Any]) async throws -> Any {
    var params = params
    params["threadId"] = id
    params["excludeTurns"] = true
    do {
      return try await call(rpc, "thread/resume", params, startupDeadline)
    } catch JSONRPCError.remote(_, let message) where message.contains(id) && message.contains("is archived") {
      _ = try await call(rpc, "thread/unarchive", ["threadId": id], startupDeadline)
      return try await call(rpc, "thread/resume", params, startupDeadline)
    }
  }

  /// Codex no longer has the thread, or keeps it under another provider: a new one starts from
  /// `prompt.recovery`, or every later turn fails the same way.
  static func resumeGone(_ error: JSONRPCError, id: String) -> Bool {
    guard case .remote(let code, let message) = error else { return false }
    return (code == -32600 && message == "no rollout found for thread id \(id)")
      || (message.contains(id) && message.contains("is archived"))
      || (code == -32600 && message.range(of: #"your current provider is \S+\. Switch to"#, options: .regularExpression) != nil)
  }

  static func call(_ rpc: JSONRPC, _ method: String, _ params: [String: Any], _ deadline: Duration = callDeadline) async throws -> Any {
    try await rpc.request(method, JSON(params), deadline: deadline).any
  }

  /// Every page of a paginated list's `data`.
  static func all(_ rpc: JSONRPC, _ method: String, _ params: [String: Any]) async throws -> [[String: Any]] {
    var rows: [[String: Any]] = []
    var params = params
    for _ in 0..<50 {
      let page = try await call(rpc, method, params)
      rows += (page as? [String: Any])?["data"] as? [[String: Any]] ?? []
      guard let cursor = CodexChecks.nextCursor(page) else { return rows }
      params["cursor"] = cursor
    }
    return rows
  }

  // MARK: Probe

  func probe(executable: URL) async -> Readiness {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .missing }
    let environment = CredentialEnv.child(.codex, executable: executable, person: [:], inherited: inherited)
    func run(_ arguments: [String]) -> String? {
      CredentialEnv.output(executable, arguments, environment: environment, within: .seconds(15))?.text
    }
    guard let said = run(["--version"]),
      let range = said.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression)
    else { return .broken("codex --version printed no version.") }
    let version = String(said[range])
    if version.compare(Self.floor, options: .numeric) == .orderedAscending { return .needsUpdate(have: version, need: Self.floor) }
    let status = run(["login", "status"]) ?? ""
    guard status.contains("Logged in") else { return .needsSignIn(status.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if checkConfigLayers { await CodexPreflight.shared.check(self, executable: executable) }
    return .ready(version: version)
  }

  /// The person's config layers as a short-lived app server reads them. Unreadable counts as a problem.
  func readConfig(executable: URL) async -> CodexPreflight.Verdict {
    let fallback = CodexPreflight.Verdict(problem: "Codex runs through codex exec because the Codex server could not be checked.", routing: [:])
    try? FileManager.default.createDirectory(at: Self.emptyFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = serverArguments(nil)
    process.environment = CredentialEnv.child(.codex, executable: executable, person: [:], inherited: inherited)
    process.currentDirectoryURL = Self.emptyFolder
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    // Through the process host like every CLI: the MCP servers it starts end with its group.
    do {
      try ProcessGroup.configure(process)
      try process.run()
    } catch { return fallback }
    defer { ProcessGroup.terminate(process) }
    func send(_ message: [String: Any]) { try? input.fileHandleForWriting.write(contentsOf: Data((jsonString(message) + "\n").utf8)) }
    let timer = Task {
      try? await Task.sleep(for: .seconds(30))
      if process.isRunning { ProcessGroup.terminate(process) }
    }
    defer { timer.cancel() }
    send(["id": 1, "method": "initialize", "params": CodexParams.initialize(version: "1")])
    do {
      for try await line in output.fileHandleForReading.bytes.lines {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        switch message["id"] as? Int {
        case 1:
          send(["method": "initialized", "params": [String: Any]()])
          send(["id": 2, "method": "config/read", "params": ["includeLayers": true]])
        case 2:
          guard let read = message["result"] else { return fallback }
          return CodexPreflight.Verdict(problem: CodexChecks.configProblem(read) ?? "", routing: CodexRouting.routing(read))
        default: continue
        }
      }
    } catch {}
    return fallback
  }
}

// MARK: - Preflight

/// Each Codex install's verdict on the person's config layers, read once as Serein main does at
/// launch and again once config.toml changes. Unknown routes to exec and starts a read.
final class CodexPreflight: @unchecked Sendable {
  struct Verdict {
    /// Empty when the app server may run.
    var problem: String
    /// The config's `CodexRouting` keys, which exec re-applies.
    var routing: [String: Any]
  }

  static let shared = CodexPreflight()
  private let lock = NSLock()
  private var verdicts: [String: Verdict] = [:]
  private var reading: Set<String> = []

  private static func key(_ driver: CodexDriver, _ executable: URL) -> String {
    let codexHome = CodexChecks.codexHome(environment: driver.inherited, home: driver.home)
    var info = stat()
    let changed = stat(codexHome.appendingPathComponent("config.toml").path, &info) == 0
      ? "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" : ""
    return [executable.path, codexHome.path, changed].joined(separator: "\0")
  }

  /// nil until read.
  func verdict(for driver: CodexDriver, executable: URL) -> Verdict? {
    let key = Self.key(driver, executable)
    if let known = lock.withLock({ verdicts[key] }) { return known }
    Task { await check(driver, executable: executable) }
    return nil
  }

  func forget(_ driver: CodexDriver, executable: URL) {
    let key = Self.key(driver, executable)
    lock.withLock { _ = verdicts.removeValue(forKey: key) }
  }

  func check(_ driver: CodexDriver, executable: URL) async {
    let key = Self.key(driver, executable)
    guard lock.withLock({ verdicts[key] == nil && reading.insert(key).inserted }) else { return }
    let verdict = await driver.readConfig(executable: executable)
    lock.withLock {
      verdicts[key] = verdict
      reading.remove(key)
    }
  }
}

// MARK: - Failures

/// Codex's typed turn errors, as Serein's stop reasons. Raw text is kept.
enum CodexFailure {
  /// Codex's own words when OpenAI refuses its stored ChatGPT sign-in, or it holds none.
  static let signInRefused =
    #"workspace routing discovery unauthorized|access token could not be refreshed|authentication session could not be refreshed|ChatGPT login is required|auth data is not available|please (?:log out and )?sign in again|missing bearer or basic authentication"#

  /// Codex's `codexErrorInfo` names its own failure; the text classifies the rest. Raw text is kept.
  static func reason(_ message: String, info: JSON?) -> StopReason {
    let text = message.isEmpty ? "Codex ended the turn with an error." : String(message.prefix(400))
    // A unit variant comes as a string, one with data as `{ "<variant>": { "httpStatusCode": 401 } }`.
    let variant = info?.string ?? info?.object?.keys.first
    let status = info?.object?.values.first?["httpStatusCode"]?.number
    let fault = HarnessRetry.classify(.message(message))
    if variant == "contextWindowExceeded" { return .maxTokens }
    if variant == "usageLimitExceeded" || fault == .terminal(.quota) { return .usageLimit(message) }
    if variant == "unauthorized" || status == 401 || fault == .terminal(.auth)
      || message.range(of: signInRefused, options: [.regularExpression, .caseInsensitive]) != nil
    {
      return message.localizedCaseInsensitiveContains("api key") ? .keyFailure(text) : .signIn(text)
    }
    if fault == .terminal(.unknownModel) { return .modelRejected(text) }
    if status == nil, ["httpConnectionFailed", "responseStreamConnectionFailed"].contains(variant ?? "")
      || fault == .transient(.connectionReset) || fault == .transient(.timeout)
    {
      return .offline(text)
    }
    return .failed(text)
  }
}

// MARK: - App-server session

/// The warm thread's turn state. Notifications and turn/start both report through it, so the
/// accept and session events always come before the turn's first content.
actor CodexThread {
  struct Usage: Equatable {
    var input = 0, output = 0, cached = 0
    init() {}
    init(_ json: JSON?) {
      input = Int(json?["inputTokens"]?.number ?? 0)
      output = Int(json?["outputTokens"]?.number ?? 0)
      cached = Int(json?["cachedInputTokens"]?.number ?? 0)
    }
  }

  let events: AsyncStream<WireEvent>
  private let out: AsyncStream<WireEvent>.Continuation
  private let rpc: JSONRPC
  private let folder: String
  private(set) var id: String?
  private var rebuilt = false
  private var startup: [String: String] = [:]
  private var gone = false
  // One turn.
  private var inTurn = false
  private(set) var turn: String?
  private var announced = true
  private var spoke = false
  private var sawDelta = false
  private var paths: [String: [String]] = [:]
  private var total = Usage()
  private var baseline = Usage()
  private var lastError: (message: String, info: JSON?)?
  private var retryError: String?
  /// The last step Serein declined this turn: a turn that then fails ends `.declined` (R5).
  private var declinedStep: String?

  init(rpc: JSONRPC, folder: String) {
    self.rpc = rpc
    self.folder = folder
    (events, out) = AsyncStream<WireEvent>.makeStream()
  }

  func opened(id: String, rebuilt: Bool) {
    self.id = id
    self.rebuilt = rebuilt
  }

  /// The text the turn sends: the conversation pasted once if resume was refused.
  func begin(_ prompt: TurnPrompt) -> String {
    inTurn = true
    turn = nil
    announced = false
    spoke = false
    sawDelta = false
    lastError = nil
    retryError = nil
    declinedStep = nil
    baseline = total
    let message = rebuilt ? prompt.recovery ?? prompt.message : prompt.message
    return [prompt.volatile, message].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  func started(turn: String?) {
    if self.turn == nil { self.turn = turn }
    announce()
  }

  /// turn/start was refused: no turn runs.
  func refused() { inTurn = false }

  func closed() {
    gone = true
    out.finish()
  }

  func settled(_ names: [String], within: Duration) async {
    let deadline = ContinuousClock.now + within
    while !gone, ContinuousClock.now < deadline,
      !names.allSatisfy({ ["ready", "failed", "cancelled"].contains(startup[$0] ?? "") })
    {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private func announce() {
    guard !announced, let id else { return }
    announced = true
    out.yield(.accepted)
    out.yield(.session(id: id, rebuilt: rebuilt))
    rebuilt = false
  }

  func receive(_ message: JSONRPC.Incoming) async {
    switch message {
    case .request(let rpcID, let method, let params):
      await answer(rpcID, method, params)
    case .notification(let method, let params):
      notification(method, params)
    }
  }

  /// Serein never approves: what a level allows is already inside the profile. At Commands a
  /// request is declined and shown; an elicitation or question is declined.
  private func answer(_ rpcID: JSON, _ method: String, _ params: JSON) async {
    let id: CodexRPC.ID = rpcID.string.map { .string($0) } ?? .int(Int(rpcID.number ?? 0))
    let request = CodexServerRequest(id: id, method: method, params: params.any as? [String: Any] ?? [:])
    let answer = CodexApprovals.answer(request, paths: paths[request.item ?? ""] ?? [], folder: folder)
    if let result = answer.result {
      try? await rpc.respond(to: rpcID, result: JSON(result))
    } else {
      try? await rpc.respond(to: rpcID, errorCode: -32601, message: answer.error ?? "Not handled.")
    }
    for approval in answer.approvals {
      out.yield(.declined(PendingApprovalValue(id: approval.id, tool: approval.tool, target: approval.target)))
    }
    if let approval = answer.approvals.first { declinedStep = approval.target.isEmpty ? "a file change" : "a change to \(approval.target)" }
    if method == "item/commandExecution/requestApproval" {
      declinedStep = "the command \(String((request.command ?? "").prefix(120)))"
      out.yield(.declined(PendingApprovalValue(
        id: request.item ?? id.description, tool: "shell", target: String((request.command ?? "").prefix(120)))))
    }
  }

  private func notification(_ method: String, _ params: JSON) {
    if method == "mcpServer/startupStatus/updated" {
      if let name = params["name"]?.string, let status = params["status"]?.string { startup[name] = status }
      return
    }
    guard let id, params["threadId"]?.string == id else { return }
    if !inTurn {
      // A total reported between turns is what the thread carried in.
      if method == "thread/tokenUsage/updated" { total = Usage(params["tokenUsage"]?["total"]) }
      return
    }
    let eventTurn = method.hasPrefix("turn/") ? params["turn"]?["id"]?.string : params["turnId"]?.string
    if let turn, let eventTurn, eventTurn != turn { return }
    switch method {
    case "turn/started":
      started(turn: eventTurn)
    case "item/agentMessage/delta":
      announce()
      if let delta = params["delta"]?.string, !delta.isEmpty {
        sawDelta = true
        spoke = true
        out.yield(.text(delta))
      }
    case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
      announce()
      if let delta = params["delta"]?.string, !delta.isEmpty { out.yield(.thinking(delta)) }
    case "item/started":
      announce()
      itemStarted(params["item"] ?? .null)
    case "item/completed":
      announce()
      itemCompleted(params["item"] ?? .null)
    case "thread/tokenUsage/updated":
      total = Usage(params["tokenUsage"]?["total"])
    case "error":
      let error = params["error"] ?? params
      guard let text = error["message"]?.string, !text.isEmpty else { return }
      // Codex reports each of its own reconnects with willRetry.
      if params["willRetry"]?.bool == true { retryError = text } else { lastError = (text, error["codexErrorInfo"]) }
    case "turn/completed":
      announce()
      finish(params["turn"] ?? .null)
    default:
      return
    }
  }

  private func itemStarted(_ item: JSON) {
    let itemID = item["id"]?.string ?? UUID().uuidString
    switch item["type"]?.string {
    case "agentMessage":
      if spoke { out.yield(.newMessage) }
      sawDelta = false
    case "commandExecution":
      let command = Self.command(item)
      out.yield(.toolStarted(id: itemID, name: "shell", arguments: command, shellCommand: command))
    case "fileChange":
      let changed = item["changes"]?.array?.compactMap { $0["path"]?.string } ?? []
      paths[itemID] = changed
      out.yield(.toolStarted(id: itemID, name: "edit", arguments: changed.joined(separator: "\n"), shellCommand: nil))
    case "mcpToolCall":
      let arguments = item["arguments"].map { jsonString($0.any) } ?? ""
      out.yield(.toolStarted(id: itemID, name: item["tool"]?.string ?? "mcp", arguments: arguments, shellCommand: nil))
    case "webSearch":
      out.yield(.toolStarted(id: itemID, name: "web_search", arguments: item["query"]?.string ?? "", shellCommand: nil))
    default:
      return
    }
  }

  private func itemCompleted(_ item: JSON) {
    let itemID = item["id"]?.string ?? ""
    let status = item["status"]?.string
    let result: ToolResult = status == "failed" || status == "declined" ? .failed : .ok
    switch item["type"]?.string {
    case "agentMessage":
      if !sawDelta, let text = item["text"]?.string, !text.isEmpty {
        spoke = true
        out.yield(.text(text))
      }
      sawDelta = false
    case "fileChange":
      for approval in CodexApprovals.refused(CodexItem(item.any as? [String: Any] ?? [:]), folder: folder) {
        out.yield(.declined(PendingApprovalValue(id: approval.id, tool: approval.tool, target: approval.target)))
      }
      out.yield(.toolEnded(id: itemID, result: result))
    case "mcpToolCall":
      out.yield(.toolEnded(id: itemID, result: result))
    case "commandExecution", "webSearch":
      out.yield(.toolEnded(id: itemID, result: result))
    default:
      return
    }
  }

  private func finish(_ turn: JSON) {
    inTurn = false
    self.turn = nil
    if total != baseline {
      out.yield(.usage(
        input: max(0, total.input - baseline.input), output: max(0, total.output - baseline.output),
        cachedInput: max(0, total.cached - baseline.cached)))
    }
    baseline = total
    switch turn["status"]?.string {
    case "completed":
      out.yield(.turnDone(.endTurn))
    case "interrupted":
      out.yield(.turnDone(.stopped))
    default:
      let error = turn["error"]
      let message = error?["message"]?.string ?? lastError?.message ?? retryError ?? ""
      let reason = CodexFailure.reason(message, info: error?["codexErrorInfo"] ?? lastError?.info)
      if case .failed = reason, let declinedStep {
        out.yield(.turnDone(.declined(declinedStep)))
      } else {
        out.yield(.turnDone(reason))
      }
    }
  }

  static func command(_ item: JSON) -> String {
    item["command"]?.string ?? item["command"]?.array?.compactMap(\.string).joined(separator: " ") ?? ""
  }
}

final class CodexAppSession: EngineSession {
  let mode: VerifiedMode
  var wire: AsyncStream<WireEvent> { thread.events }
  private let rpc: JSONRPC
  private let thread: CodexThread
  private let approvalPolicy: String

  init(mode: VerifiedMode, rpc: JSONRPC, thread: CodexThread, approvalPolicy: String) {
    self.mode = mode
    self.rpc = rpc
    self.thread = thread
    self.approvalPolicy = approvalPolicy
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    let text = await thread.begin(prompt)
    guard let id = await thread.id else { throw StopReason.failed("The Codex thread is gone.") }
    var input: [[String: Any]] = [["type": "text", "text": text, "text_elements": [Any]()]]
    for image in request.images { input.append(["type": "localImage", "path": image.path]) }
    // No sandboxPolicy: the thread's profile holds.
    var params: [String: Any] = ["threadId": id, "input": input, "approvalPolicy": approvalPolicy, "approvalsReviewer": "user"]
    if let model = request.model, !model.isEmpty { params["model"] = model }
    if let effort = request.effort, !effort.isEmpty { params["effort"] = effort }
    if let schema = request.schema {
      guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) else {
        await thread.refused()
        throw StopReason.failed("The reply schema is not JSON.")
      }
      params["outputSchema"] = object
    }
    do {
      let started = try await rpc.request("turn/start", JSON(params), deadline: CodexDriver.startupDeadline)
      await thread.started(turn: started["turn"]?["id"]?.string)
    } catch JSONRPCError.closed {
      // The process exit reports why, with its stderr. turn/started may still be on its way in.
    } catch JSONRPCError.remote(_, let message) {
      await thread.refused()
      throw StopReason.failed(message)
    }
  }

  func steer(_ text: String) async -> SteerOutcome {
    guard let id = await thread.id, let turn = await thread.turn else { return .refused }
    do {
      _ = try await rpc.request("turn/steer", JSON(CodexParams.steer(thread: id, turn: turn, text: text)), deadline: .seconds(10))
      return .steered
    } catch JSONRPCError.remote {
      return .refused
    } catch {
      return .indeterminate
    }
  }
}
