import AppKit
import os
import SereinCore
import SwiftUI

/// Follows the open thread's linked chat. Codex's own `thread/read` gives a Codex chat's history
/// (Codex reads every version of its store); Claude Code, Pi, Oh My Pi and Grok chats are read
/// from their files, an OpenCode chat from its database. A kqueue source on the file the harness
/// appends to (OpenCode: its write-ahead log) says when to read again: 0.4 s after the
/// last write, at most 1.5 s after the first. Nothing polls; a thread that is not open is read
/// again when it opens or when Serein becomes active.
@MainActor final class LinkedSessionMonitor: ObservableObject {
  /// The chat's last turn is still running in another app.
  @Published private(set) var working = false
  /// Why the chat could not be read; shown under the thread.
  @Published private(set) var problem: String?
  /// Only the newest part of a long chat is shown.
  @Published private(set) var omitsEarlier = false
  /// The folder the chat ran in, from its last read.
  @Published private(set) var folder: String?
  /// The thread whose message the harness's own CLI is answering now (`reply`).
  @Published private(set) var replyThread: String?
  /// When the reply above began, for the working row's time.
  @Published private(set) var replyStarted: Date?
  /// When the chat's file last changed, from the last read.
  @Published private(set) var lastWrite: Date?
  /// The model the chat last used, from the last read; a reply names another only when the
  /// person chose another in Serein.
  private(set) var chatModel: String?
  private var replyProcess: Process?
  private var replyName = ""
  /// Why the watchdog ended the reply, shown in place of the CLI's own exit.
  private var replyLimit: String?
  private weak var agent: AgentModel?
  private var watched: String?
  private var transcriptPath: String?
  /// The followed chat file as last read; a write is read from where that read ended.
  private var chatTail = AppendedTail()
  private var source: DispatchSourceFileSystemObject?
  private var flush: Task<Void, Never>?
  private var firstChange: Date?
  private var reading = false
  private var again = false
  private var checking = false
  private var observer: NSObjectProtocol?
  private var quitObserver: NSObjectProtocol?
  private let readOverride: (@MainActor (SessionLink) async throws -> LinkedHistory)?

  init(agent: AgentModel, read: (@MainActor (SessionLink) async throws -> LinkedHistory)? = nil) {
    self.agent = agent
    self.readOverride = read
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    // A reply's CLI and the commands it started end with Serein, as with Stop.
    quitObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.endReplyForQuit() } }
  }
  /// Stop's SIGKILL comes 2 s later (ProcessGroup.terminate) and never runs once Serein has
  /// exited, so on quit Serein waits up to 1 s for the group, then kills what is left.
  private func endReplyForQuit() {
    guard let replyProcess else { return }
    let pid = replyProcess.processIdentifier
    ProcessGroup.terminate(replyProcess)
    // ponytail: blocks the main thread for up to 1 s, only while Serein quits.
    if pid > 1, !ProcessGroup.waitForExit(pid, timeout: 1) { _ = kill(-pid, SIGKILL) }
  }

  /// Starts, moves or stops the watch after the open thread changed.
  func follow() {
    flush?.cancel()
    firstChange = nil
    transcriptPath = nil
    chatTail = AppendedTail()
    watch(nil)
    working = false
    problem = nil
    omitsEarlier = false
    folder = nil
    chatModel = agent?.model
    // A copy that the next message makes: the thread shows the chat as it was until then.
    guard let link = agent?.link, link.forkNext != true else { return watch(nil) }
    refresh()
  }

  func refresh() {
    guard let agent, let link = agent.link, link.forkNext != true, !CommandLine.arguments.contains("--ui-preview") else { return }
    if reading {
      again = true
      return
    }
    // Serein's own turn shows its own stream; the chat is read again when the turn ends.
    if agent.hub.run(for: agent.conversationID)?.isActive == true { return }
    let executable = agent.available[.codex] ?? HarnessRegistry.shared.executable(.codex)
    reading = true
    let thread = agent.conversationID
    Task { @MainActor in
      do {
        let history: LinkedHistory
        if let readOverride { history = try await readOverride(link) }
        else { history = try await Self.read(link, codex: executable, tail: chatTail) }
        if let agent = self.agent, agent.conversationID == thread, agent.link == link {
          // The request shows at once; the CLI's record replaces it once it holds it.
          if replyThread == thread && history.messages.count < agent.messages.count {
            reading = false
            return
          }
          problem = nil
          working = history.working
          omitsEarlier = history.omitsEarlier
          folder = history.cwd
          // The picker follows the chat's own model until the person chooses another.
          if let model = history.model, model != chatModel {
            if agent.model.isEmpty || agent.model == chatModel { agent.model = model }
            chatModel = model
          }
          lastWrite = history.path.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
          transcriptPath = history.path
          watch(history.path)
          agent.showLinked(history)
        }
      } catch {
        if self.agent?.conversationID == thread, self.agent?.link == link {
          problem = "Serein could not read this chat from \(link.name). \(error.localizedDescription)"
          // A delayed or atomically replaced transcript must wake the reader when it appears.
          watch(link.file ?? transcriptPath)
        }
      }
      reading = false
      if again {
        again = false
        refresh()
      }
    }
  }

  /// `tail`: the follower's kept copy of the chat file, so a re-read takes only new lines.
  static func read(_ link: SessionLink, codex executable: String?, tail: AppendedTail? = nil) async throws -> LinkedHistory {
    switch link.driver {
    case HarnessDriver.codex.rawValue:
      // Its own session file first: a long chat Codex takes too long to send whole still opens.
      if let file = await Task.detached(priority: .userInitiated, operation: { codexRollout(link.nativeID) }).value {
        var history = try await readTail(file, tail: tail) { LinkedHistory.codexRollout($0, omitsEarlier: $1) }
        if history.cwd == nil, let head = SessionIndex.readHead(URL(fileURLWithPath: file)) {
          history.cwd = LinkedHistory.codexRollout(Data(head.prefix { $0 != 10 })).cwd
        }
        return history
      }
      guard let executable else { throw SereinError.invalid("Codex is not connected.") }
      return try await read(link.nativeID, executable: executable)
    case HarnessDriver.claude.rawValue:
      guard let file = link.file ?? claudeTranscript(link.nativeID) else {
        throw SereinError.invalid("Its transcript is no longer on this Mac.")
      }
      return try await readTail(file, tail: tail) { LinkedHistory.claude($0, omitsEarlier: $1) }
    case HarnessDriver.pi.rawValue, HarnessDriver.ohMyPi.rawValue:
      guard let file = link.file else { throw SereinError.invalid("Its session file is no longer on this Mac.") }
      var history = try await readTail(file, tail: tail) { LinkedHistory.pi($0, omitsEarlier: $1) }
      // A long chat read from its tail has lost its header, which names the folder.
      if history.cwd == nil, let head = SessionIndex.readHead(URL(fileURLWithPath: file)) {
        history.cwd = LinkedHistory.pi(head.prefix { $0 != 10 }).cwd
      }
      return history
    case HarnessDriver.grok.rawValue:
      guard let file = link.file else { throw SereinError.invalid("Its chat history is no longer on this Mac.") }
      var history = try await readTail(file, tail: tail) { LinkedHistory.grok($0, omitsEarlier: $1) }
      let summary = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("summary.json")
      history.cwd = (FileManager.default.contents(atPath: summary.path)
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["info"] as? [String: Any])?["cwd"] as? String
        ?? LinkedHistory.grokFolder(file)
      return history
    case HarnessDriver.opencode.rawValue:
      guard let db = link.file else { throw SereinError.invalid("Its database is no longer on this Mac.") }
      let id = link.nativeID
      return try await Task.detached(priority: .userInitiated) {
        guard var history = LinkedHistory.opencode(db: db, id: id) else {
          throw SereinError.invalid("The app no longer has this chat.")
        }
        // It writes to a write-ahead log; when there is none, the folder shows a new one.
        let wal = db + "-wal"
        history.path = FileManager.default.fileExists(atPath: wal) ? wal : (db as NSString).deletingLastPathComponent
        return history
      }.value
    case HarnessDriver.cursor.rawValue:
      guard let file = link.file else { throw SereinError.invalid("Its transcript is no longer on this Mac.") }
      var history = try await readTail(file, tail: tail) { LinkedHistory.cursor($0, omitsEarlier: $1) }
      // A transcript does not name its folder; discovery matched it to one.
      history.cwd = SessionHistoryStore.shared.history.sessions
        .first { $0.provider == link.driver && $0.id == link.nativeID && !$0.cwd.isEmpty }?.cwd
      return history
    default: throw SereinError.invalid("Serein cannot follow chats from this agent yet.")
    }
  }

  /// Sends `prompt` on the linked chat through the harness's own CLI, in the chat's folder, as if
  /// typed there (HarnessCommands.reply), with the person's own `pictures`. The CLI writes the
  /// turn to its own store, and the watch shows it; `context` (attached page items, rendered as for
  /// Serein's own runs) goes before the words. The request shows at once; Stop ends the CLI
  /// and everything it started; `done` runs when it has ended. False, with the reason in
  /// `agent.error`, when nothing was sent. One reply runs at a time.
  /// As for Codex and Claude Code, the message goes on in a copy when the app may hold the chat
  /// (or after "Continue in a copy"), where the CLI can make one (HarnessCommands.copies); the
  /// thread then follows the copy. Cursor cannot copy, so a toast says what happens.
  @discardableResult
  func reply(
    _ prompt: String, context: String = "", link: SessionLink, executable: String, folder: String?, model: String? = nil,
    pictures: [String] = [], done: @escaping @MainActor () -> Void = {}
  ) -> Bool {
    guard let agent else { return false }
    guard replyThread == nil else {
      agent.error = "Serein is still sending a message to \(replyName) in another thread. Send this one when it ends."
      return false
    }
    let model = model == chatModel ? nil : model
    guard let driver = HarnessDriver(rawValue: link.driver),
      HarnessCommands.reply(driver, id: link.nativeID, file: link.file, prompt: context + prompt, model: model, pictures: pictures) != nil
    else {
      agent.error = "Serein cannot send to this \(link.name) chat."
      return false
    }
    let thread = agent.conversationID
    replyThread = thread
    replyName = link.name
    replyStarted = Date()
    withAnimation(LinkedMotion.arrive) { agent.messages.append(AgentMessage(role: "you", text: prompt)) }
    agent.syncSelection()
    Task { @MainActor in
      var link = link
      var fork: String?
      let held = await Self.held(driver, cwd: folder)
      if held || link.forkNext == true {
        if HarnessCommands.copies(driver) {
          if driver == .pi || driver == .ohMyPi, let file = link.file {
            // Pi's copy is a file: it exists before the message, and the thread follows it now.
            do {
              let copy = try Self.forkPi(file, driver: driver)
              agent.relinkLinked(thread, to: copy.id, file: copy.file)
              link = link.moved(to: copy.id, file: copy.file)
            } catch {
              agent.error = "Serein could not make a copy of this \(link.name) chat. \(error.localizedDescription)"
              finishReply()
              return done()
            }
          } else {
            fork = driver == .grok ? UUID().uuidString.lowercased() : ""
          }
          if held { ToastCenter.shared.show("\(link.name) may still have this chat open, so Serein goes on in a copy. The original chat is unchanged.") }
        } else if held {
          ToastCenter.shared.show("\(link.name) also has this chat open in another window. That window shows this message after you open the chat there again.")
        }
      }
      guard replyThread == thread,
        let command = HarnessCommands.reply(
          driver, id: link.nativeID, file: link.file, prompt: context + prompt, model: model, pictures: pictures, fork: fork)
      else {
        if replyThread == thread { finishReply() }
        return done()
      }
      let started = Date().addingTimeInterval(-2)
      start(command, driver: driver, link: link, executable: executable, folder: folder, thread: thread) { [weak self] ok in
        // The copy the CLI made: the thread follows it from now on.
        if ok, fork != nil {
          if let copy = Self.copy(of: link, driver: driver, fork: fork, since: started) {
            self?.agent?.relinkLinked(thread, to: copy.id, file: copy.file)
          } else {
            self?.agent?.error = "\(link.name) made a copy of this chat, but Serein could not find it. Open it from the Agents card."
          }
        }
        done()
      }
    }
    return true
  }
  /// Where a CLI put the copy it made with its fork flag.
  static func copy(of link: SessionLink, driver: HarnessDriver, fork: String?, since: Date) -> (id: String, file: String?)? {
    switch driver {
    case .grok:
      guard let fork, !fork.isEmpty, let file = link.file else { return nil }
      let path = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(fork).appendingPathComponent("chat_history.jsonl").path
      return FileManager.default.fileExists(atPath: path) ? (fork, path) : nil
    case .opencode:
      return link.file.flatMap { LinkedHistory.opencodeCopy(db: $0, of: link.nativeID, since: since) }.map { ($0, link.file) }
    default: return nil
    }
  }
  /// Writes a Pi copy beside the original, named as Pi names its files.
  nonisolated static func forkPi(_ file: String, driver: HarnessDriver) throws -> (id: String, file: String) {
    let id = UUID().uuidString.lowercased()
    let now = Date()
    guard let data = FileManager.default.contents(atPath: file),
      let copy = LinkedHistory.piFork(data, id: id, original: file, now: now)
    else { throw SereinError.invalid("Its session file could not be read.") }
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let name = stamp.string(from: now).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
    let target = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("\(name)_\(id).jsonl")
    try copy.write(to: target, options: .withoutOverwriting)
    return (id, target.path)
  }
  private func start(
    _ command: (arguments: [String], stdin: String?), driver: HarnessDriver, link: SessionLink, executable: String,
    folder: String?, thread: String, ended: @escaping @MainActor (Bool) -> Void
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = command.arguments
    // The harnesses Serein already runs under sandbox-exec (they keep no sandbox of their own)
    // reply under a profile that closes only Serein's own data and settings service, so a page in
    // the reply's context cannot have them read the library. Their own homes stay open. The others
    // (Claude Code, Codex, Cursor, OpenCode) sandbox their own commands, which a
    // second sandbox around them would break.
    if HarnessPolicy.ownSetupDrivers.contains(driver) || driver.wire == .piJSON {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments = ["-p", AgentFileGuard.sereinDataProfile(
        home: FileManager.default.homeDirectoryForCurrentUser, library: AgentAccess.defaultRoot), executable] + command.arguments
    }
    var environment = HarnessRegistry.shared.environment(Provider(driver), executable: executable)
    if let folder {
      process.currentDirectoryURL = URL(fileURLWithPath: folder)
      // OpenCode takes its folder from PWD, which would otherwise be Serein's own.
      environment["PWD"] = folder
    }
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = command.stdin == nil ? FileHandle.nullDevice : input
    process.standardOutput = output
    process.standardError = output
    // The last words the CLI printed, for an error.
    let tail = OSAllocatedUnfairLock(initialState: Data())
    let lastOutput = OSAllocatedUnfairLock(initialState: Date())
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      tail.withLock { $0 = ($0 + chunk).suffix(2000) }
      lastOutput.withLock { $0 = Date() }
    }
    process.terminationHandler = { [weak self] process in
      output.fileHandleForReading.readabilityHandler = nil
      let status = process.terminationStatus
      let reason = process.terminationReason
      let said = String(decoding: tail.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor in
        ended(status == 0 && reason == .exit)
        guard let self else { return }
        let limit = self.replyLimit
        self.replyLimit = nil
        self.finishReply()
        if let limit {
          if self.agent?.conversationID == thread { self.agent?.error = limit }
        } else if status != 0 && reason == .exit, self.agent?.conversationID == thread {
          let last = said.split(separator: "\n").last.map(String.init) ?? ""
          self.agent?.error = "\(link.name) stopped before it answered\(last.isEmpty ? "." : ": " + String(last.prefix(300)))"
        }
      }
    }
    do {
      // Its own process group, so Stop also ends the commands the CLI started.
      try ProcessGroup.configure(process)
      try process.run()
    } catch {
      finishReply()
      ended(false)
      agent?.error = "Serein could not start \(link.name). \(error.localizedDescription)"
      return
    }
    if let stdin = command.stdin {
      // A message with pages can pass the pipe's 64 KiB: write it off the main actor, and a CLI
      // that exits before it reads everything is its own error (EPIPE), not a crash.
      let handle = input.fileHandleForWriting
      _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
      let data = Data(stdin.utf8)
      DispatchQueue.global(qos: .userInitiated).async {
        try? handle.write(contentsOf: data)
        try? handle.close()
      }
    }
    replyProcess = process
    watchReply(process, chat: transcriptPath ?? link.file, started: Date(), lastOutput: { lastOutput.withLock { $0 } })
  }
  /// The relay's limits hold here too (RelayOrchestrator.limits, 60 min in all and 10 min with
  /// nothing new): a reply whose CLI neither prints nor writes in its chat's folder ends as Stop
  /// ends it. Most of these CLIs print only the answer, so the folder is what shows work: the
  /// chat file, its database's log, or a copy made beside it.
  private func watchReply(
    _ process: Process, chat: String?, started: Date, lastOutput: @escaping @Sendable () -> Date
  ) {
    let name = replyName
    let folder = chat.map { path -> URL in
      var isFolder: ObjCBool = false
      let url = URL(fileURLWithPath: path)
      return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
        ? url : url.deletingLastPathComponent()
    }
    Task { @MainActor [weak self] in
      while true {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard let self, self.replyProcess === process, self.replyLimit == nil else { return }
        let written = folder.flatMap {
          try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])
        }?.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
          ?? .distantPast
        switch RelayOrchestrator.limits.breach(startedAt: started, lastEventAt: max(lastOutput(), written)) {
        case .hard(let minutes):
          self.replyLimit = "Stopped after \(minutes) minutes, the limit for this kind of task. Narrow the request and try again."
        case .idle(let minutes): self.replyLimit = TurnFailure.stoppedAnswering(name, minutes: minutes)
        case nil: continue
        }
        ProcessGroup.terminate(process)
        return
      }
    }
  }
  private func finishReply() {
    replyProcess = nil
    replyThread = nil
    replyStarted = nil
    agent?.syncSelection()
    refresh()
  }
  func stopReply() {
    if let replyProcess { ProcessGroup.terminate(replyProcess) } else { finishReply() }
  }
  /// A process of the harness outside Serein in the chat's folder.
  nonisolated static func held(_ driver: HarnessDriver, cwd: String?) async -> Bool {
    guard let cwd else { return false }
    let folder = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
    return await Task.detached(priority: .userInitiated) {
      HarnessProcessDiscovery.snapshot().contains {
        HarnessProcessDiscovery.driver($0) == driver
          && $0.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == folder
      }
    }.value
  }

  /// One Codex chat, through the app server Serein already runs for Codex turns.
  static func read(_ id: String, executable: String) async throws -> LinkedHistory {
    let server = CodexAppServer.shared(executable)
    try await server.ensureStarted()
    let response = try await server.request("thread/read", ["threadId": id, "includeTurns": true])
    guard let thread = (response as? [String: Any])?["thread"] as? [String: Any] else {
      throw SereinError.invalid("Codex returned no chat.")
    }
    return LinkedHistory.codex(thread)
  }

  /// A chat file, at most its newest 24 MB (`omitsEarlier` when cut). With the `tail` a follower
  /// keeps, only the lines written since its last read come from disk.
  nonisolated static func readTail(
    _ file: String, tail: AppendedTail? = nil, parse: @escaping @Sendable (Data, Bool) -> LinkedHistory
  ) async throws -> LinkedHistory {
    try await Task.detached(priority: .userInitiated) {
      let read = try (tail ?? AppendedTail()).read(file)
      var history = parse(read.data, read.omitsEarlier)
      history.path = file
      return history
    }.value
  }

  /// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`, newest days first: the running
  /// session's own file when Serein follows it, else a search of Codex's session folders.
  nonisolated static func codexRollout(_ id: String, home: String = NSHomeDirectory()) -> String? {
    guard UUID(uuidString: id) != nil else { return nil }
    let root = SessionHistory.Roots(home: home, environment: ProcessInfo.processInfo.environment).codexSessions
    let files = FileManager.default
    func folders(_ path: String) -> [String] {
      ((try? files.contentsOfDirectory(atPath: path)) ?? []).filter { Int($0) != nil }.sorted(by: >).map { path + "/" + $0 }
    }
    let suffix = "-" + id.lowercased() + ".jsonl"
    for year in folders(root) {
      for month in folders(year) {
        for day in folders(month) {
          guard let name = ((try? files.contentsOfDirectory(atPath: day)) ?? [])
            .first(where: { $0.hasPrefix("rollout-") && $0.lowercased().hasSuffix(suffix) }) else { continue }
          let path = day + "/" + name
          return ExternalSessionReader.allowedLog(path, driver: .codex, home: home) ? path : nil
        }
      }
    }
    return nil
  }

  /// `~/.claude/projects/<folder>/<id>.jsonl`, for a chat Serein knows only by id.
  nonisolated static func claudeTranscript(_ id: String, home: String = NSHomeDirectory()) -> String? {
    guard UUID(uuidString: id) != nil else { return nil }
    let folders = ClaudeSessionRecords.roots(home: home).flatMap {
      (try? FileManager.default.contentsOfDirectory(at: $0.appendingPathComponent("projects"), includingPropertiesForKeys: nil)) ?? []
    }
    return folders.map { $0.appendingPathComponent(id + ".jsonl").path }.first { FileManager.default.fileExists(atPath: $0) }
  }

  /// Before Serein writes to the linked chat. When another app may hold it, the thread goes on in
  /// the harness's own copy and the original stays as that app left it: Codex makes the copy now
  /// (`thread/fork`); Claude Code makes it in the run (`--fork-session`). False: do not send.
  func prepareSend(_ link: SessionLink, executable: String, cwd: String?) async -> Bool {
    guard !checking else { return false }
    checking = true
    defer { checking = false }
    if link.driver == HarnessDriver.claude.rawValue {
      let environment = HarnessRegistry.shared.environment(.claude, executable: executable)
      if await Self.claudeHeld(link.nativeID, executable: executable, environment: environment, cwd: cwd) {
        agent?.forkLinkedNext = true
        ToastCenter.shared.show("Claude Code still has this chat open, so Serein goes on in a copy. The original chat is unchanged.")
      }
      return true
    }
    guard link.driver == HarnessDriver.codex.rawValue else { return true }
    let id = link.nativeID
    let executables = Dictionary(uniqueKeysWithValues: HarnessRegistry.shared.snapshots.compactMap { driver, snapshot in
      snapshot.path.map { (driver, $0) }
    })
    guard await Self.heldElsewhere(path: watched, executables: executables) else { return true }
    do {
      let copy = try await CodexAppServer.shared(executable).fork(thread: id, cwd: cwd, checkConfig: false)
      agent?.continueLinked(in: copy)
      ToastCenter.shared.show("Codex still has this chat open, so Serein goes on in a copy. The original chat is unchanged.")
      return true
    } catch {
      agent?.error = "Codex still has this chat open, and Serein could not make a copy of it. \(error.localizedDescription)"
      return false
    }
  }

  /// `claude agents --json` lists every interactive and background Claude Code session: one that
  /// is listed and not done holds the chat. When the list cannot be read, a Claude Code process
  /// outside Serein in the chat's folder counts.
  nonisolated static func claudeHeld(
    _ id: String, executable: String, environment: [String: String], cwd: String?
  ) async -> Bool {
    await Task.detached(priority: .userInitiated) {
      let result = HarnessProbe.runSync(executable, ["agents", "--json"], environment: environment, timeout: 8)
      if result.code == 0, let start = result.output.firstIndex(of: "["),
        let sessions = try? JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [[String: Any]]
      {
        return sessions.contains { $0["sessionId"] as? String == id && $0["state"] as? String != "done" }
      }
      guard let cwd else { return true }
      let folder = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
      return HarnessProcessDiscovery.snapshot().contains {
        HarnessProcessDiscovery.driver($0) == .claude
          && $0.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == folder
      }
    }.value
  }

  /// A Codex process outside Serein that has the chat's file open, or that can hold any chat:
  /// an app server (the ChatGPT app, an editor). Serein's own processes are left out.
  nonisolated static func heldElsewhere(path: String?, executables: [HarnessDriver: String]) async -> Bool {
    await Task.detached(priority: .userInitiated) {
      HarnessProcessDiscovery.snapshot(executables: executables).contains { holds($0, file: path, executables: executables) }
    }.value
  }
  nonisolated static func holds(_ process: HarnessProcess, file: String?, executables: [HarnessDriver: String]) -> Bool {
    guard HarnessProcessDiscovery.driver(process, executables: executables) == .codex else { return false }
    if process.arguments.contains("app-server") || process.executable.contains("/ChatGPT.app/") { return true }
    guard let file else { return false }
    let resolved = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
    return process.logs.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolved }
  }

  private func watch(_ path: String?) {
    var target = path
    while let candidate = target, !FileManager.default.fileExists(atPath: candidate) {
      let parent = (candidate as NSString).deletingLastPathComponent
      guard !parent.isEmpty, parent != candidate else { target = nil; break }
      target = parent
    }
    guard target != watched || (target != nil && source == nil) else { return }
    source?.cancel()
    source = nil
    watched = target
    guard let path = target else { return }
    let fd = open(path, O_EVTONLY | O_CLOEXEC)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self, weak source] in
      let gone = source.map { !$0.data.intersection([.delete, .rename]).isEmpty } ?? false
      MainActor.assumeIsolated { self?.changed(gone: gone) }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    self.source = source
  }

  private func changed(gone: Bool) {
    if gone {
      // The next read names the file again and watches it anew.
      source?.cancel()
      source = nil
    }
    let now = Date()
    let first = firstChange ?? now
    firstChange = first
    let wait = max(0, min(0.4, 1.5 - now.timeIntervalSince(first)))
    flush?.cancel()
    flush = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      firstChange = nil
      refresh()
    }
  }
}

extension AgentModel {
  /// Opens a chat from another app (LinkedSessions.link) as a Serein thread that follows it: the
  /// thread already open for that chat, else a new one in the chat's folder. A folder Serein does
  /// not know yet is confirmed by the user first, as an import is.
  /// `lastActive`: when the chat last moved, so opening it is not counted as activity (the Agents
  /// list's Recents goes by it).
  func openLinked(_ link: SessionLink, lastActive: Date? = nil) {
    guard let driver = HarnessDriver(rawValue: link.driver) else { return }
    let provider = Provider(driver)
    let id = link.nativeID
    if let known = conversations.first(where: {
      ($0.link?.driver == link.driver && $0.link?.nativeID == id) || ($0.provider == provider && $0.remoteID == id)
    }) {
      return openConversation(known)
    }
    let codex = available[.codex] ?? HarnessRegistry.shared.executable(.codex)
    // A Codex chat with its session file opens without Codex; replying still needs it.
    guard let browser, driver != .codex || codex != nil || LinkedSessionMonitor.codexRollout(id) != nil else {
      ToastCenter.shared.show("Connect \(link.name) in Settings › AI apps to open this chat.")
      return
    }
    // Failures here go to a toast only: the open thread is not the chat being opened.
    Task { @MainActor in
      do {
        let history = try await LinkedSessionMonitor.read(link, codex: codex)
        guard let folder = history.cwd else {
          ToastCenter.shared.show("Serein could not find the folder this \(link.name) chat ran in.")
          return
        }
        guard let project = LinkedSessions.project(for: folder, browser: browser) else { return }
        let item = Conversation(
          id: UUID().uuidString, title: history.messages.first.map { String($0.text.prefix(100)) } ?? "\(link.name) chat",
          messages: history.messages.map { AgentMessage(role: $0.role, text: $0.text, activities: $0.activities.isEmpty ? nil : $0.activities) },
          provider: provider, mode: .project, projectID: project.id, remoteID: id, scope: Self.adoptScope(provider),
          updatedAt: Date(), autoRouting: false, model: history.model, effort: history.effort,
          lastMessageAt: lastActive ?? Date(), link: SessionLink(driver: link.driver, nativeID: id, file: link.file ?? (driver == .claude ? history.path : nil)))
        conversations.insert(item, at: 0)
        openConversation(item)
        // As an imported chat: read-only until the user turns on clicks or edits.
        allowActions = false
        allowProjectEdits = false
      } catch {
        ToastCenter.shared.show("Serein could not open this chat from \(link.name). \(error.localizedDescription)")
      }
    }
  }

  /// Thread `thread` follows `id` from now on (a copy of its linked chat), whether or not it is open.
  func relinkLinked(_ thread: String, to id: String, file: String?) {
    if conversationID == thread { return continueLinked(in: id, file: file) }
    guard let i = conversations.firstIndex(where: { $0.id == thread }), let link = conversations[i].link else { return }
    conversations[i].link = link.moved(to: id, file: file)
    conversations[i].remoteID = id
    conversations[i].scope = Self.adoptScope(conversations[i].provider)
    try? browser?.library.save(conversations, to: "sessions/threads.json")
  }

  /// The other app's version of the chat replaces what the thread shows; messages that did not
  /// change keep their identity, so their text views stay as they are.
  func showLinked(_ history: LinkedHistory) {
    guard !history.messages.isEmpty || messages.isEmpty else { return }
    // Discovering an action-only answer can insert a row before a steered request. Match
    // by user turn rather than row index so later screenshots and identities do not move.
    var previous: [Int: [AgentMessage]] = [:]
    var turn = -1
    for message in messages {
      if message.role == "you" { turn += 1 }
      previous[turn, default: []].append(message)
    }
    let sameWindow = !history.omitsEarlier
      || messages.filter { $0.role == "you" }.map(\.text) == history.messages.filter { $0.role == "you" }.map(\.text)
    turn = -1
    var request: String?
    var reused = Set<String>()
    var carriedImages: [Int: Set<String>] = [:]
    let next = history.messages.map { message in
      if message.role == "you" { turn += 1; request = message.text }
      let group = previous[turn] ?? []
      let sameTurn = sameWindow && group.first(where: { $0.role == "you" })?.text == request
      let candidates = sameTurn ? group.filter { $0.role == message.role && !reused.contains($0.id) } : []
      let old = candidates.first(where: { $0.text == message.text }) ?? candidates.last
      if let old { reused.insert(old.id) }
      let images = candidates.flatMap { $0.images ?? [] }.filter { carriedImages[turn, default: []].insert($0).inserted }
      return AgentMessage(
        id: old?.id ?? UUID().uuidString, role: message.role, text: message.text,
        images: images.isEmpty ? nil : images, activities: message.activities.isEmpty ? nil : message.activities,
        own: old?.own ?? (sameTurn ? group.first(where: { $0.role == "you" })?.own : nil))
    }
    guard next != messages else { return }
    // New turns from the other app arrive as Serein's own do not: they rise into place.
    withAnimation(next.count > messages.count ? LinkedMotion.arrive : nil) { messages = next }
    saveConversation()
  }
}

@MainActor enum LinkedSessions {
  /// The link that opens a past chat in Serein; nil when Serein cannot read it (a Cursor CLI
  /// chat) or the chat's file is gone. Grok keeps each chat in its own folder under any project
  /// folder; OpenCode keeps every chat in one database.
  static func link(for session: DiscoveredSession) -> SessionLink? {
    guard let driver = HarnessDriver(rawValue: session.provider) else { return nil }
    let roots = SessionHistory.Roots(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
    let fm = FileManager.default
    switch driver {
    case .codex: return SessionLink(driver: session.provider, nativeID: session.id)
    case .claude, .pi, .ohMyPi:
      return session.file.map { SessionLink(driver: session.provider, nativeID: session.id, file: $0) }
    case .grok:
      // Grok names the folder for the project folder with "/" percent-encoded; else look in each.
      func file(_ folder: String) -> String? {
        let path = roots.grok + "/" + folder + "/" + session.id + "/chat_history.jsonl"
        return fm.fileExists(atPath: path) ? path : nil
      }
      let encoded = session.cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
      return (encoded.flatMap(file) ?? ((try? fm.contentsOfDirectory(atPath: roots.grok)) ?? []).lazy.compactMap(file).first)
        .map { SessionLink(driver: session.provider, nativeID: session.id, file: $0) }
    case .opencode:
      return fm.fileExists(atPath: roots.opencodeDB) ? SessionLink(driver: session.provider, nativeID: session.id, file: roots.opencodeDB) : nil
    case .cursor:
      // Agent transcripts only: the CLI's own store.db chats have no format Serein reads yet.
      return session.file.flatMap { $0.hasSuffix(".jsonl") ? SessionLink(driver: session.provider, nativeID: session.id, file: $0) : nil }
    // Serein does not read Gemini CLI's store, so it lists none of its chats.
    case .gemini:
      return nil
    }
  }
  /// A running session of another harness: the chat its records name ("<harness>:<id>",
  /// ExternalSessionReader), else, for a process that names none, the newest past chat of that
  /// harness in the same folder, as Claude Code's own newest transcript stands for its process.
  static func past(for session: ExternalSession) -> DiscoveredSession? {
    let sessions = SessionHistoryStore.shared.history.sessions
    if let exact = sessions.first(where: { "\($0.provider):\($0.id)" == session.id }) { return exact }
    // A process reports its folder with links resolved, as harnesses record it.
    guard session.id.hasPrefix("process:"), let cwd = session.cwd, !cwd.isEmpty else { return nil }
    return sessions.first { $0.provider == session.driver.rawValue && $0.cwd == cwd }
  }
  /// "Continue in a copy" on a chat its own CLI answers: a new thread with the whole chat that goes
  /// on in a native copy, as Codex's does. Pi's copy is made now; Grok and OpenCode make
  /// theirs with the first message. False when this chat's CLI cannot make a copy.
  static func continueInCopy(agent: AgentModel, browser: BrowserModel) -> Bool {
    guard agent.repliesInApp, let link = agent.link, let driver = HarnessDriver(rawValue: link.driver),
      HarnessCommands.copies(driver)
    else { return false }
    agent.saveConversation()
    var copyLink = SessionLink(driver: link.driver, nativeID: link.nativeID, file: link.file, forkNext: true)
    if driver == .pi || driver == .ohMyPi, let file = link.file {
      do {
        let copy = try LinkedSessionMonitor.forkPi(file, driver: driver)
        copyLink = SessionLink(driver: link.driver, nativeID: copy.id, file: copy.file)
      } catch {
        agent.error = "Serein could not make a copy of this \(link.name) chat. \(error.localizedDescription)"
        return true
      }
    }
    let original = agent.conversations.first { $0.id == agent.conversationID }
    var copy = Conversation(
      id: UUID().uuidString, title: original?.title ?? "Copy", messages: agent.messages,
      provider: agent.provider, mode: agent.mode, projectID: agent.projectID, remoteID: copyLink.nativeID,
      scope: AgentModel.adoptScope(agent.provider), updatedAt: Date(), autoRouting: false, model: agent.model,
      effort: agent.effort, lastMessageAt: Date(), link: copyLink)
    copy.readPersonal = agent.inheritedPersonal(original)
    agent.conversations.insert(copy, at: 0)
    try? browser.library.save(agent.conversations, to: "sessions/threads.json")
    agent.openConversation(copy)
    ToastCenter.shared.show(copyLink.forkNext == true
      ? "Your next message starts the copy in \(link.name). The original chat is unchanged."
      : "Continued in a copy. The original chat is unchanged.")
    return true
  }
  /// A message on this chat goes to the harness's own CLI (HarnessCommands.reply): every harness
  /// but Codex and Claude Code, which Serein runs itself.
  static func repliesInApp(_ link: SessionLink) -> Bool {
    HarnessDriver(rawValue: link.driver).flatMap { HarnessCommands.reply($0, id: link.nativeID, file: link.file, prompt: "") } != nil
  }
  /// The project for a chat's folder: one Serein already has (discovery saves every folder it
  /// finds), else the folder the user confirms. Nil when the user cancels.
  static func project(for folder: String, browser: BrowserModel) -> Project? {
    let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
    if let known = browser.projects.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolved }) {
      return known
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = URL(fileURLWithPath: folder)
    panel.message = "This chat ran in \(folder). Confirm that folder to open the chat in Serein."
    guard panel.runModal() == .OK, let url = panel.url,
      url.resolvingSymlinksInPath().path == resolved
    else { return nil }
    if browser.insideSereinData(url.path) {
      browser.refuseSereinDataFolder()
      return nil
    }
    let project = Project(name: url.lastPathComponent, path: url.path, source: .added)
    browser.projects.append(project)
    browser.saveProjects()
    browser.warnIfHoldsSereinData([project.path])
    return project
  }
}

/// In the transcript of a thread that follows another app's chat, under the last message, as
/// Serein's own "Thinking for…" row: that the app is still working on it (from the running
/// sessions' own logs: Codex's `thread/read` does not show another process's turn as running) or
/// waits for an answer there, or why the chat could not be read.
struct LinkedSessionNote: View {
  @ObservedObject var monitor: LinkedSessionMonitor
  var link: SessionLink?
  @ObservedObject private var external = ExternalSessionStore.shared
  @Environment(\.palette) var p
  var state: ExternalSession.State? {
    guard let link else { return nil }
    // Harnesses other than Codex and Claude Code name only their process: match the folder.
    let folder = monitor.folder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    let state = external.sessions.first { $0.id == "\(link.driver):\(link.nativeID)" }?.state
      ?? external.sessions.first {
        $0.id.hasPrefix("process:") && $0.driver.rawValue == link.driver && folder != nil
          && $0.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == folder
      }?.state
    if monitor.replyThread != nil { return .running }
    return state == .open ? nil : state ?? (monitor.working ? .running : nil)
  }
  var body: some View {
    Group {
      if let problem = monitor.problem {
        Text(problem).font(UIStyle.meta).foregroundStyle(p.secondary)
      } else if let state, let link {
        LinkedWorkingRow(link: link, waiting: state == .needsUser, started: monitor.replyStarted)
      }
    }.transition(LinkedMotion.enter(reduce: reduceMotion))
      .animation(LinkedMotion.arrive, value: state)
  }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// The other app's turn: its own mark breathes while it works (opacity and scale only), with the
/// time since Serein's message when Serein sent it. Waiting for an answer holds still, as does
/// Reduce Motion.
struct LinkedWorkingRow: View {
  var link: SessionLink
  var waiting: Bool
  var started: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  @Environment(\.palette) var p
  var provider: Provider? { HarnessDriver(rawValue: link.driver).map(Provider.init) }
  var body: some View {
    HStack(spacing: 8) {
      mark.overlay(alignment: .topTrailing) {
        if waiting { Circle().fill(p.warning).frame(width: 6, height: 6).offset(x: 3, y: -2) }
      }
      Text(waiting ? "\(link.name) is waiting for your answer" : "\(link.name) is working")
        .foregroundStyle(p.secondary)
      if !waiting, let started {
        // Only the time changes each second, so only it is drawn again.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(ThreadRunTrace.spoken(context.date.timeIntervalSince(started))).foregroundStyle(p.faint).monospacedDigit()
        }
      }
    }.font(UIStyle.meta)
    .accessibilityElement(children: .combine)
    .help(waiting ? "\(link.name) asks you something in the app that runs this chat." : "New messages show here as \(link.name) writes them.")
  }
  @ViewBuilder var mark: some View {
    let glyph = HarnessGlyph(provider: provider, size: 12, tinted: true).frame(width: 14, height: 14)
    if waiting || reduceMotion || previewReducedEffects {
      glyph
    } else {
      // Breathed by Core Animation, so SwiftUI does not redraw the row for each frame.
      Breathing { glyph }.frame(width: 14, height: 14).accessibilityHidden(true)
    }
  }
}

/// At the head of a linked chat's transcript: whose chat it is, where it runs, and when it last
/// changed; and, for a long chat, that the newest part is shown.
struct LinkedSourceLine: View {
  @ObservedObject var monitor: LinkedSessionMonitor
  var link: SessionLink
  var project: String?
  @Environment(\.palette) var p
  var body: some View {
    let provider = HarnessDriver(rawValue: link.driver).map(Provider.init)
    HStack(spacing: 8) {
      HarnessGlyph(provider: provider, size: 12, tinted: true).frame(width: 14, height: 14)
      Text("\(link.name) chat" + (project.map { " in \($0)" } ?? ""))
        .foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
      if let last = monitor.lastWrite, let ago = RelativeTimeShort.text(last) {
        Text("last change \(ago == "now" ? "just now" : ago + " ago")").foregroundStyle(p.faint).lineLimit(1)
      }
      if monitor.omitsEarlier {
        Text("newest part shown").foregroundStyle(p.faint).lineLimit(1)
      }
    }.font(UIStyle.meta)
      .accessibilityElement(children: .combine)
      .help("Serein follows this chat as \(link.name) writes it. Your messages go to \(link.name) on the same chat.")
  }
}

/// Motion for linked chats: what the other app writes rises 16 pt into place and fades in; with
/// Reduce Motion it only fades.
enum LinkedMotion {
  static let arrive = Animation.easeOut(duration: 0.25)
  static func enter(reduce: Bool) -> AnyTransition {
    reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity)
  }
}

extension SessionLink {
  /// The harness's name, for the words a person reads.
  var name: String { HarnessDriver(rawValue: driver)?.displayName ?? "the other app" }
}
