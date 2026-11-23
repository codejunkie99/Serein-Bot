import AppKit
import Foundation
import SereinCore
import SwiftUI

/// Whether the installed Codex CLI speaks the app server protocol Serein needs (probed once per
/// executable by generating its JSON schema; no model call), and whether the user's Codex config
/// lets Serein run it as it runs `codex exec`.
enum CodexAppServerProbe {
  @MainActor private static var results: [String: Bool] = [:]
  @MainActor private static var inFlight = Set<String>()

  /// True when runs may use the app server. `SEREIN_CODEX_EXEC=1` always uses `codex exec`.
  @MainActor static func usable(_ executable: String) -> Bool {
    if ProcessInfo.processInfo.environment["SEREIN_CODEX_EXEC"] == "1" { return false }
    guard results[executable] == true, let server = CodexAppServer.existing(executable) else {
      return false
    }
    return server.verified && server.refusal == nil
  }

  /// True once the probe and its config read have finished (either way), so a run knows the
  /// routing keys are in hand. False while they are still being read.
  @MainActor static func settled(_ executable: String) -> Bool {
    guard let known = results[executable] else { return false }
    guard known, let server = CodexAppServer.existing(executable) else { return true }
    return server.verified || server.refusal != nil
  }

  /// The CLI at this path changed: the next probe checks it again.
  @MainActor static func forget(_ executable: String) { results[executable] = nil }

  @MainActor static func probe(_ executable: String) async -> Bool {
    if let known = results[executable] { return known }
    guard !inFlight.contains(executable) else { return false }
    inFlight.insert(executable)
    defer { inFlight.remove(executable) }
    let supported = await Task.detached(priority: .utility) { check(executable) }.value
    results[executable] = supported
    if supported { await CodexAppServer.shared(executable).preflight() }
    return supported
  }

  nonisolated private static func check(_ executable: String) -> Bool {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("serein-codex-schema-" + UUID().uuidString)
    defer { try? fm.removeItem(at: dir) }
    guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
      return false
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = ["app-server", "generate-json-schema", "--out", dir.path]
    child.environment = CodexAppServer.environment(executable)
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch { return false }
    let deadline = Date().addingTimeInterval(15)
    while child.isRunning && Date() < deadline { usleep(50_000) }
    if child.isRunning {
      child.terminate()
      return false
    }
    guard child.terminationStatus == 0 else { return false }
    func methods(_ name: String) -> Set<String> {
      guard let data = fm.contents(atPath: dir.appendingPathComponent(name).path) else { return [] }
      return CodexChecks.methods(schema: data)
    }
    return CodexChecks.supports(
      requests: methods("ClientRequest.json"), notifications: methods("ServerNotification.json"),
      serverRequests: methods("ServerRequest.json"))
  }
}

/// Models the Codex app server lists (`model/list`).
@MainActor final class CodexCatalog: ObservableObject {
  static let shared = CodexCatalog()
  /// Codex's own model cache until its server lists the live models.
  @Published private(set) var models: [ModelChoice] = ModelSources.files(
    .codex, environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory()
  ).models.flatMap { FileManager.default.contents(atPath: $0) }.map(CodexModels.cached) ?? []
  /// Routing keys from the user's config, re-applied on the exec path (CodexRouting).
  private(set) var routing: [String: Any] = [:]
  func setRouting(_ routing: [String: Any]) { self.routing = routing }
  func update(_ models: [ModelChoice]) {
    self.models = models
    HarnessRegistry.shared.noteModels(.codex)
  }
}

/// One long-lived `codex app-server` per executable for this Serein session. Each run gets its
/// own thread (resumed per turn with that run's browser capability) and is unloaded after it.
/// The user's Codex config keeps Serein's turns off the server (see `refuse`).

@MainActor final class CodexAppServer {
  private static var servers: [String: CodexAppServer] = [:]
  private static var quitObserver: NSObjectProtocol?
  static func shared(_ executable: String) -> CodexAppServer {
    if let server = servers[executable] { return server }
    // A write to a server that just exited must fail with EPIPE, not end Serein.
    signal(SIGPIPE, SIG_IGN)
    let server = CodexAppServer(executable: executable)
    servers[executable] = server
    if quitObserver == nil {
      quitObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { _ in MainActor.assumeIsolated { CodexAppServer.shutdownAll() } }
    }
    return server
  }
  static func existing(_ executable: String) -> CodexAppServer? { servers[executable] }
  static func shutdownAll() { for server in servers.values { server.terminate() } }

  nonisolated static func environment(_ executable: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = [
      URL(fileURLWithPath: executable).deletingLastPathComponent().path, "/opt/homebrew/bin",
      "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin",
    ].joined(separator: ":")
    env.removeValue(forKey: "CLAUDECODE")
    env.removeValue(forKey: "CODEX_THREAD_ID")
    return env
  }

  let executable: String
  /// Set when a safety check failed: Codex runs use `codex exec` for the rest of the session.
  private(set) var refusal: String?
  /// The user's config layers were read and allow the app server.
  private(set) var verified = false
  private var process: Process?
  private var input: FileHandle?
  private var starting: Task<Void, Error>?
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
  private let diagnostics = TextBox()
  /// Every method Serein sent, newest last (bounded); the smoke check reads it.
  private(set) var sentMethods: [String] = []
  /// A server with no turn and no request waiting stops after this long without a message, and
  /// the next turn starts it again. It holds about 190 MB; a start takes about a second.
  static var idleLimit: TimeInterval = 300
  private var lastMessage = Date()
  private var idleWatch: Task<Void, Never>?

  private init(executable: String) { self.executable = executable }

  var isRunning: Bool { process?.isRunning == true && input != nil }

  func refuse(_ reason: String) {
    refusal = reason
  }

  /// Reads the effective config layers once; any override `codex exec --ignore-user-config`
  /// would have dropped sends Codex to exec, with the reason shown in Settings › AI apps.
  func preflight() async {
    do {
      try await ensureStarted()
      let read = try await request("config/read", ["includeLayers": true])
      CodexCatalog.shared.setRouting(CodexRouting.routing(read))
      if let problem = CodexChecks.configProblem(read) {
        refuse(problem)
      } else {
        verified = true
      }
    } catch {
      refuse("Codex runs through codex exec because the Codex server could not be checked.")
    }
  }

  func ensureStarted() async throws {
    if let starting {
      try await starting.value
      return
    }
    if isRunning { return }
    let task = Task { @MainActor in try await self.launch() }
    starting = task
    do {
      try await task.value
      starting = nil
    } catch {
      starting = nil
      terminate()
      throw error
    }
  }

  private func launch() async throws {
    let child = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = CodexParams.serverArguments()
    child.currentDirectoryURL = FileManager.default.temporaryDirectory
    // The person's Keychain key for Codex, when saved (HarnessRegistry.keyEnvironment).
    child.environment = Self.environment(executable).merging(HarnessRegistry.shared.keyEnvironment(.codex)) { _, key in key }
    child.standardOutput = stdout
    child.standardError = stderr
    child.standardInput = stdin
    // Its own process group: quitting Serein, or a server that stops answering, ends the server
    // and everything it spawned.
    try ProcessGroup.configure(child)
    let box = diagnostics
    stderr.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      if !d.isEmpty { box.append(String(decoding: d, as: UTF8.self)) }
    }
    child.terminationHandler = { [weak self] ended in
      DispatchQueue.main.async { self?.exited(ended) }
    }
    do { try child.run() } catch {
      throw SereinError.invalid("The Codex server could not be started.")
    }
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process = child
    input = stdin.fileHandleForWriting
    lastMessage = Date()
    idleWatch?.cancel()
    idleWatch = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(min(30, Self.idleLimit / 2) * 1_000_000_000))
        guard let self, !Task.isCancelled, self.process === child else { return }
        if self.pending.isEmpty,
          Date().timeIntervalSince(self.lastMessage) > Self.idleLimit
        {
          // Let go of it at once: a turn that starts in this moment gets a new server, not a
          // pipe to one that is exiting.
          self.process = nil
          self.input = nil
          ProcessGroup.terminate(child)
          return
        }
      }
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var buffer = Data()
      // availableData returns as soon as anything arrives; read(upToCount:) waits for a full buffer.
      while case let data = stdout.fileHandleForReading.availableData, !data.isEmpty {
        buffer.append(data)
        while let i = buffer.firstIndex(of: 10) {
          let line = String(decoding: buffer.prefix(upTo: i), as: UTF8.self)
          buffer.removeSubrange(...i)
          DispatchQueue.main.async { self?.handle(line) }
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }
      }
      stderr.fileHandleForReading.readabilityHandler = nil
    }
    _ = try await request("initialize", CodexParams.initialize(version: "1"), timeout: 30)
    write(CodexRPC.notification(method: "initialized"))
    Task { @MainActor [weak self] in await self?.listModels() }
  }

  /// Every page of `model/list`; a failed page keeps the list as it was.
  private func listModels() async {
    var models: [Any] = []
    var cursor: String?
    var cursors = Set<String>()
    repeat {
      var params: [String: Any] = ["limit": 100]
      if let cursor { params["cursor"] = cursor }
      guard let page = try? await request("model/list", params) else { return }
      models += (page as? [String: Any])?["data"] as? [Any] ?? []
      cursor = CodexChecks.nextCursor(page)
    } while cursor.map { cursors.insert($0).inserted } == true
    CodexCatalog.shared.update(CodexModels.choices(["data": models]))
  }

  /// Codex's CLI or its model cache changed on disk. An idle server starts again now, so the new
  /// CLI lists the new models; a busy one is asked for its list, and the idle stop after its
  /// turns brings the rest.
  func reload() {
    if pending.isEmpty {
      if let process {
        self.process = nil
        input = nil
        ProcessGroup.terminate(process)
      }
      Task { try? await ensureStarted() }
    } else if isRunning {
      Task { await listModels() }
    }
  }

  func terminate() {
    if let process, process.isRunning { ProcessGroup.terminate(process) }
  }

  private func exited(_ ended: Process) {
    guard ended === process else { return }
    process = nil
    input = nil
    let failures = pending
    pending = [:]
    for (_, c) in failures {
      c.resume(throwing: SereinError.invalid("The Codex server stopped. Try again."))
    }
  }

  /// Drops a line the server can no longer read; a broken pipe is reported by `exited`.
  @discardableResult private func write(_ line: String) -> Bool {
    guard let input else { return false }
    do {
      try input.write(contentsOf: Data((line + "\n").utf8))
      return true
    } catch { return false }
  }

  func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws
    -> Any
  {
    guard let input else { throw SereinError.invalid("The Codex server is not running.") }
    lastMessage = Date()
    let id = nextID
    nextID += 1
    sentMethods.append(method)
    if sentMethods.count > 400 { sentMethods.removeFirst(sentMethods.count - 400) }
    let line = CodexRPC.request(id: id, method: method, params: params) + "\n"
    return try await withCheckedThrowingContinuation { c in
      pending[id] = c
      do { try input.write(contentsOf: Data(line.utf8)) } catch {
        pending[id] = nil
        c.resume(throwing: SereinError.invalid("The Codex server refused a request."))
        return
      }
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        self?.pending.removeValue(forKey: id)?.resume(
          throwing: SereinError.invalid(
            "Codex did not answer within \(Int(timeout)) seconds. Try again."))
      }
    }
  }

  /// Every page of a paginated list result's `data`.
  func requestAll(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30)
    async throws -> [[String: Any]]
  {
    var all: [[String: Any]] = []
    var cursor: String?
    for _ in 0..<50 {
      var p = params
      if let cursor { p["cursor"] = cursor }
      let page = try await request(method, p, timeout: timeout)
      all += (page as? [String: Any])?["data"] as? [[String: Any]] ?? []
      cursor = CodexChecks.nextCursor(page)
      if cursor == nil { return all }
    }
    throw SereinError.invalid("The Codex server returned too many pages.")
  }

  private func handle(_ line: String) {
    lastMessage = Date()
    guard let message = CodexRPC.decode(line) else { return }
    switch message {
    case .response(let id, let result):
      if case .int(let n) = id { pending.removeValue(forKey: n)?.resume(returning: result) }
    case .failure(let id, _, let text):
      if case .int(let n)? = id {
        pending.removeValue(forKey: n)?.resume(throwing: SereinError.invalid(text))
      }
    case .notification:
      break
    case .request(let id, let method, let params):
      let request = CodexServerRequest(id: id, method: method, params: params)
      let answer = CodexApprovals.answer(request, folder: nil)
      if let result = answer.result {
        write(CodexRPC.response(id: id, result: result))
      } else {
        write(CodexRPC.error(id: id, code: -32601, message: answer.error ?? "Not supported."))
      }
    }
  }

  /// "Continue in a copy": a native fork of `thread`, unloaded at once. Returns the copy's id.
  /// `checkConfig` false: a config that keeps Serein's turns on `codex exec` still gets a copy.
  /// Each turn checks the config again before it uses the copy (CodexDriver).
  func fork(thread: String, cwd: String?, checkConfig: Bool = true) async throws -> String {
    try await ensureStarted()
    let read = try await request(
      "config/read", (cwd.map { ["cwd": $0] } ?? [:]).merging(["includeLayers": true]) { a, _ in a })
    if checkConfig, let problem = CodexChecks.configProblem(read) { throw SereinError.invalid(problem) }
    let response = try await request(
      "thread/fork",
      CodexParams.threadFork(id: thread, cwd: cwd, disable: CodexParams.configuredServers(read)))
    guard let id = ((response as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
    else { throw SereinError.invalid("The Codex server started no thread.") }
    _ = try? await request("thread/unsubscribe", ["threadId": id])
    if let problem = CodexChecks.threadProblem(response, writable: false) {
      throw SereinError.invalid(problem)
    }
    return id
  }
}

extension ComposerFlow {
  /// "Continue in a copy" with Codex's own fork: the copy keeps the whole thread, not a summary.
  /// Calls `fallback` when the fork is unavailable or fails.
  static func codexNativeCopy(
    agent: AgentModel, browser: BrowserModel, fallback: @escaping @MainActor () -> Void
  ) -> Bool {
    guard agent.provider == .codex, let source = agent.nativeSessionID,
      let executable = agent.available[.codex], CodexAppServerProbe.usable(executable)
    else { return false }
    agent.saveConversation()
    let original = agent.conversations.first { $0.id == agent.conversationID }
    let messages = agent.messages
    let mode = agent.mode
    let projectID = agent.projectID
    let cwd = mode == .project ? browser.projects.first { $0.id == projectID }?.path : nil
    let model = agent.model
    let effort = agent.effort
    Task { @MainActor in
      do {
        let id = try await CodexAppServer.shared(executable).fork(thread: source, cwd: cwd)
        var copy = Conversation(
          id: UUID().uuidString, title: original?.title ?? "Copy", messages: messages,
          provider: .codex, mode: mode, projectID: projectID, remoteID: id,
          // The original's scope: the copy keeps the native fork while its access is the same.
          scope: original?.scope ?? "",
          updatedAt: Date(), autoRouting: false, model: model, effort: effort,
          lastMessageAt: Date())
        // The forked session holds what the original read, as marked now (after the fork).
        copy.readPersonal = agent.inheritedPersonal(agent.conversations.first { $0.id == original?.id })
        agent.conversations.insert(copy, at: 0)
        try? browser.library.save(agent.conversations, to: "sessions/threads.json")
        agent.openConversation(copy)
        ToastCenter.shared.show("Continued in a copy. The original thread is unchanged.")
      } catch {
        fallback()
      }
    }
    return true
  }
}
