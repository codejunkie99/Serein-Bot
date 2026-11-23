import Darwin
import Foundation
import SereinCore

/// The person's own computer or VM as an assistant's computer (ComputerPlace.ownDesktop and
/// .ownMachine), reached only by running the system's `/usr/bin/ssh` (SSHInvocation): the
/// person's keys and passphrases stay with ssh and the macOS ssh-agent, the host key is checked
/// strictly against Serein's own known_hosts file in the Library (0600), and every link is one ssh
/// process's stdin and stdout. Nothing listens on either side: no port is forwarded and no
/// connection socket is shared.

/// The Host names in ~/.ssh/config for the alias picker. The file is read here and handed straight
/// to SSHConfigHosts, which keeps nothing but the names; no other line is kept, shown or logged.
/// A config kept elsewhere and linked in (a dotfiles folder) is followed to its file.
enum SSHAliasFile {
  static func load() -> [String] {
    let path = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/config").resolvingSymlinksInPath().path
    guard let data = SafeFileRead.regularFile(path, limit: 1_000_000) else { return [] }
    return SSHConfigHosts.aliases(String(decoding: data, as: UTF8.self))
  }
}

/// Why an ssh run failed, in plain words; `failure` says which (a changed key is shown in Settings).
struct OwnLinkError: LocalizedError {
  let failure: SSHFailure
  let target: String
  var errorDescription: String? {
    switch failure {
    case .keyChanged: return OwnCard.keyChanged(target: target)
    case .keyUnknown: return "\(target)'s host key is not trusted yet. The user connects it once in Settings › Serein's computer."
    case .notAccepted: return OwnCard.notAccepted(target: target)
    case .unreachable(let reason): return OwnCard.unreachable(target: target, reason: reason)
    }
  }
}

/// One ssh process kept open as a stream (ComputerStream): its stdin is the command's stdin on the
/// machine, its stdout the command's stdout. It runs in its own process group (ProcessGroup), so a
/// ProxyCommand the person's config starts ends with it.
final class SSHStream: ComputerStream, @unchecked Sendable {
  private let process: Process
  private let input: FileHandle
  private let state = NSLock()
  private var closed = false
  private var inputClosed = false
  private var exitCode: Int?
  private var waiters: [CheckedContinuation<Int, Never>] = []
  private var tail: [String] = []
  private let exited = DispatchSemaphore(value: 0)
  private let writeLock = NSLock()

  /// Starts ssh at once: `onStdout` gets the output as it comes (on a reader thread),
  /// `onStderrLine` each line ssh or the command writes to stderr, `onEnd` fires once at the end.
  init(arguments: [String], onStdout: @escaping (Data) -> Void, onStderrLine: ((String) -> Void)? = nil,
       onEnd: @escaping () -> Void) throws {
    let process = Process()
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: SSHInvocation.ssh)
    process.arguments = arguments
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try ProcessGroup.configure(process)
    let ended = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in ended.signal() }
    self.process = process
    input = stdin.fileHandleForWriting
    signal(SIGPIPE, SIG_IGN)
    try process.run()
    _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    let errors = stderr.fileHandleForReading
    let errorsDone = DispatchSemaphore(value: 0)
    let errorReader = Thread { [weak self] in
      var buffer = Data()
      var chunk = [UInt8](repeating: 0, count: 8192)
      func line(_ bytes: Data) {
        let text = String(decoding: bytes.prefix(400), as: UTF8.self)
        self?.note(text)
        onStderrLine?(text)
      }
      while true {
        let n = Darwin.read(errors.fileDescriptor, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { break }
        buffer.append(contentsOf: chunk.prefix(n))
        while let newline = buffer.firstIndex(of: 10) {
          line(buffer[buffer.startIndex..<newline])
          buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > 65_536 { buffer.removeAll() }
      }
      if !buffer.isEmpty { line(buffer) }
      errorsDone.signal()
    }
    errorReader.name = "serein.computer.ssh-stderr"
    errorReader.start()
    let output = stdout.fileHandleForReading
    let reader = Thread { [weak self] in
      var chunk = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { break }
        onStdout(Data(chunk.prefix(n)))
      }
      ended.wait()
      errorsDone.wait()
      self?.finish(Int(process.terminationStatus))
      onEnd()
    }
    reader.name = "serein.computer.ssh"
    reader.qualityOfService = .userInitiated
    reader.start()
  }
  deinit {
    if process.isRunning { ProcessGroup.terminate(process) }
  }

  private func note(_ line: String) {
    state.lock()
    tail = Array((tail + [line]).suffix(40))
    state.unlock()
  }
  private func finish(_ code: Int) {
    state.lock()
    closed = true
    exitCode = code
    let resumed = waiters
    waiters = []
    state.unlock()
    exited.signal()
    for waiter in resumed { waiter.resume(returning: code) }
  }

  var isClosed: Bool {
    state.lock(); defer { state.unlock() }
    return closed
  }
  var stderrLines: [String] {
    state.lock(); defer { state.unlock() }
    return tail
  }
  @discardableResult func write(_ data: Data) -> Bool {
    state.lock()
    let open = !closed && !inputClosed
    state.unlock()
    guard open else { return false }
    writeLock.lock(); defer { writeLock.unlock() }
    do {
      try input.write(contentsOf: data)
      return true
    } catch {
      return false
    }
  }
  func closeWrite() {
    state.lock()
    let first = !inputClosed
    inputClosed = true
    state.unlock()
    if first {
      writeLock.lock()
      try? input.close()
      writeLock.unlock()
    }
  }
  /// Ends ssh and everything it started; the reader then sees the end and fires it once.
  func close() {
    if process.isRunning { ProcessGroup.terminate(process) }
  }
  /// ssh's exit code once it ended: 255 is ssh's own failure, anything else the command's.
  func finished() async -> Int {
    await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
      state.lock()
      if let exitCode {
        state.unlock()
        done.resume(returning: exitCode)
        return
      }
      waiters.append(done)
      state.unlock()
    }
  }
  /// Waits at most `seconds` for the end, blocking (for quit).
  func wait(seconds: Double) -> Bool { exited.wait(timeout: .now() + seconds) == .success }
}

/// One finished command on the machine: its exit code and the last lines of its stderr.
struct SSHResult {
  var code: Int
  var stderr: [String]
  /// The last thing it said, for a refusal.
  var reason: String {
    let last = stderr.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    return AgentPrivacy.redact(String(last.prefix(200)))
  }
}

/// How Serein reaches one own computer: its destination, the name its host key is kept under, and
/// Serein's known_hosts file. Every ssh run goes through here with the same strict options.
@MainActor final class SSHLink {
  let target: SSHTarget
  let hostAlias: String
  let knownHosts: URL
  var name: String { target.text }

  /// nil for an assistant id that cannot name a host key (OwnComputerNames).
  init?(target: SSHTarget, assistantID: String, folder: URL) {
    guard let alias = SSHInvocation.hostAlias(assistantID: assistantID) else { return nil }
    self.target = target
    hostAlias = alias
    knownHosts = folder.appendingPathComponent("known_hosts")
  }

  // MARK: the host key

  private var folder: URL { knownHosts.deletingLastPathComponent() }
  private func makeFolder() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
  }
  private var knownText: String {
    SafeFileRead.regularFile(knownHosts.path, limit: 4_000_000).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }
  /// The key the person trusted for this computer, if any.
  var storedKey: SSHHostKey? { SSHHostKeys.keys(in: knownText, host: hostAlias).first }
  /// Writes `key` as this computer's only key, or removes its line (nil). Only the person's
  /// answer on the fingerprint card, or Remove, comes here.
  func store(_ key: SSHHostKey?) throws {
    try makeFolder()
    let text = SSHHostKeys.replacing(knownText, host: hostAlias, with: key)
    try Data(text.utf8).write(to: knownHosts, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
  }

  /// The key the machine shows now, fetched without signing in: ssh writes it into a scratch file
  /// of Serein's own (0600, deleted after) and stops before any key, agent or password is offered.
  func scan() async throws -> SSHHostKey {
    try makeFolder()
    let scratch = folder.appendingPathComponent("scan-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: scratch.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
      throw SereinError.invalid("Serein could not prepare the host key check.")
    }
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let remote = SSHInvocation.remote(["true"]),
      let arguments = SSHInvocation.arguments(target: target, hostAlias: hostAlias, knownHosts: scratch.path, scan: true, remote: remote)
    else { throw SereinError.invalid("Serein could not make the SSH command for \(name).") }
    let result = try await Self.run(arguments, input: nil, lines: nil, sink: { _ in })
    let shown = SafeFileRead.regularFile(scratch.path, limit: 1_000_000).map { String(decoding: $0, as: UTF8.self) } ?? ""
    if let key = SSHHostKeys.keys(in: shown, host: hostAlias).first { return key }
    if let failure = failure(result) { throw failure }
    throw OwnLinkError(failure: .unreachable("it showed no host key"), target: name)
  }

  // MARK: commands

  private func arguments(_ words: [String]) throws -> [String] {
    guard let remote = SSHInvocation.remote(words),
      let arguments = SSHInvocation.arguments(target: target, hostAlias: hostAlias, knownHosts: knownHosts.path, scan: false, remote: remote)
    else { throw SereinError.invalid("Serein could not make the SSH command for \(name).") }
    return arguments
  }
  private func failure(_ result: SSHResult) -> OwnLinkError? {
    SSHFailure.classify(code: result.code, stderr: result.stderr.joined(separator: "\n"), hasStoredKey: storedKey != nil)
      .map { OwnLinkError(failure: $0, target: name) }
  }

  /// One command on the machine to its end: the file `input`, if any, is its stdin; its stdout
  /// goes to `sink` and each stderr line to `lines` (on reader threads). ssh's own failures throw
  /// in plain words; any other exit code is the command's.
  func run(_ words: [String], input: URL? = nil, lines: ((String) -> Void)? = nil, sink: @escaping (Data) -> Void = { _ in })
    async throws -> SSHResult
  {
    let result = try await Self.run(try arguments(words), input: input, lines: lines, sink: sink)
    if let failure = failure(result) { throw failure }
    return result
  }
  /// The same, keeping what it printed (a short answer, such as a container's state).
  func output(_ words: [String]) async throws -> (result: SSHResult, text: String) {
    final class Box: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
    }
    let box = Box()
    let result = try await run(words, sink: { piece in
      box.lock.lock()
      if box.data.count < 65_536 { box.data.append(piece) }
      box.lock.unlock()
    })
    box.lock.lock(); defer { box.lock.unlock() }
    return (result, String(decoding: box.data, as: UTF8.self))
  }
  /// A command kept open as a stream (the helper, the proxy shim).
  func open(_ words: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void) throws -> SSHStream {
    let stream = try SSHStream(arguments: try arguments(words), onStdout: onStdout, onEnd: onEnd)
    if !stdin { stream.closeWrite() }
    return stream
  }
  /// At quit: one command, waited for at most `seconds`.
  func runBlocking(_ words: [String], seconds: Double) {
    guard let command = try? arguments(words),
      let stream = try? SSHStream(arguments: command, onStdout: { _ in }, onEnd: {})
    else { return }
    stream.closeWrite()
    if !stream.wait(seconds: seconds) { stream.close() }
  }
  /// A file of Serein's own beside the known_hosts file (0600), for a command's stdin.
  func scratchFile(_ data: Data) throws -> URL {
    try makeFolder()
    let file = folder.appendingPathComponent("input-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw SereinError.invalid("Serein could not prepare the files for \(name).")
    }
    return file
  }

  nonisolated static func run(_ arguments: [String], input: URL?, lines: ((String) -> Void)?, sink: @escaping (Data) -> Void)
    async throws -> SSHResult
  {
    let stream = try SSHStream(arguments: arguments, onStdout: sink, onStderrLine: lines, onEnd: {})
    if let input {
      // Streamed in 1 MB pieces off the main actor, then stdin ends.
      Task.detached {
        if let file = try? FileHandle(forReadingFrom: input) {
          while let piece = try? file.read(upToCount: 1_048_576), !piece.isEmpty {
            guard stream.write(piece) else { break }
          }
          try? file.close()
        }
        stream.closeWrite()
      }
    } else {
      stream.closeWrite()
    }
    let code = await stream.finished()
    return SSHResult(code: code, stderr: stream.stderrLines)
  }
}

/// A computer reached over SSH: ComputerHost trusts its host key (`link`) before anything runs.
@MainActor protocol OwnBackend: ComputerBackend {
  var link: SSHLink { get }
}

/// "A desktop for Serein": 33a's hardened container on the person's Linux machine, started with
/// that machine's own `docker` over SSH (OwnDesktop). The image is built there once from Serein's
/// own recipe sent over the stream; the container has no network, no ports and no host mounts,
/// and its helper and proxy shim are `docker exec` streams inside one ssh process each.
@MainActor final class OwnDesktopComputer: OwnBackend {
  let capabilities = ComputerCapabilities.ownDesktop
  let link: SSHLink
  private let assistantID: String
  private let container: String
  private let volume: String
  /// Serein's recipe as a tar (ComputerHost's build context).
  private let context: () throws -> Data
  /// A line of the image build, on a reader thread.
  private let progress: (String) -> Void
  /// The caps the container runs with, once known (memory in MB, processors).
  private let caps: (Int, Int) -> Void

  init?(assistantID: String, link: SSHLink, context: @escaping () throws -> Data, progress: @escaping (String) -> Void,
        caps: @escaping (Int, Int) -> Void) {
    guard let names = OwnDesktop.names(assistantID) else { return nil }
    self.assistantID = assistantID
    self.link = link
    container = names.container
    volume = names.volume
    self.context = context
    self.progress = progress
    self.caps = caps
  }

  /// One docker command that must succeed, with what failed in its refusal.
  private func expect(_ words: [String], _ what: String) async throws {
    let result = try await link.run(words)
    guard result.code == 0 else { throw SereinError.invalid("\(what) on \(link.name): \(result.reason)") }
  }

  func start() async throws -> Bool {
    switch try await link.run(["sh", "-c", OwnDesktop.probeScript]).code {
    case 0: break
    case 127: throw SereinError.invalid(OwnCard.noDocker(target: link.name))
    case 125: throw SereinError.invalid(OwnCard.dockerNotAnswering(target: link.name))
    default: try await build()
    }
    _ = try await link.run(["sh", "-c", OwnDesktop.staleScript(container: container)])
    let found = try await link.output(OwnDesktop.stateCommand(container: container))
    guard found.result.code == 0 else { throw SereinError.invalid("Docker on \(link.name) did not list its containers: \(found.result.reason)") }
    var state = found.text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    var created = false
    if state.isEmpty {
      // Sized from the machine itself (at most half its memory and processors, within Settings'
      // limits): a one-processor VM refuses a container asked for two.
      let sized = try await link.output(["sh", "-c", OwnDesktop.sizeScript])
      guard sized.result.code == 0, let size = OwnDesktop.size(sized.text) else {
        throw SereinError.invalid("Serein could not read how many processors and how much memory \(link.name) has: \(sized.result.reason)")
      }
      let memory = ComputerPolicy.memoryMB(totalBytes: size.bytes)
      let cpus = ComputerPolicy.cpus(cores: size.cores)
      guard let create = OwnDesktop.createCommand(assistantID: assistantID, memoryMB: memory, cpus: cpus) else {
        throw SereinError.invalid("Serein could not name the computer on \(link.name).")
      }
      try await expect(OwnDesktop.volumeCommand(assistantID: assistantID, volume: volume), "Its home folder could not be made")
      try await expect(create, "The computer could not be made")
      state = "created"
      created = true
    }
    switch state {
    case "running": break
    case "paused": try await expect(["docker", "unpause", container], "The computer could not be woken")
    default: try await expect(["docker", "start", container], "The computer could not be started")
    }
    if let made = try? await link.output(["docker", "inspect", "-f", OwnDesktop.capsFormat, container]), made.result.code == 0,
      let known = OwnDesktop.caps(made.text)
    {
      caps(known.memoryMB, known.cpus)
    }
    return created
  }

  /// The image, built on the machine from the same recipe as on this Mac (its base pinned by
  /// digest, its packages by version, its label naming the pinned helper and start script); the tar
  /// goes over the ssh stream and its copy here is deleted after.
  private func build() async throws {
    progress("Building Serein's computer on \(link.name). The first time takes a few minutes.")
    let file = try link.scratchFile(try context())
    defer { try? FileManager.default.removeItem(at: file) }
    let result = try await link.run(OwnDesktop.buildCommand, input: file, lines: progress)
    guard result.code == 0 else { throw SereinError.invalid("Serein's computer could not be built on \(link.name): \(result.reason)") }
  }

  func openShell(_ command: [String], onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream?
  {
    let words = OwnDesktop.execCommand(container: container, stdin: true, command: command, asShell: true)
    return try link.open(words, stdin: true, onStdout: onStdout, onEnd: onEnd)
  }

  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream
  {
    try link.open(OwnDesktop.execCommand(container: container, stdin: stdin, command: command), stdin: stdin,
                  onStdout: onStdout, onEnd: onEnd)
  }
  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    try await link.run(OwnDesktop.execCommand(container: container, stdin: input != nil, command: command), input: input, sink: sink).code
  }
  func pause() async throws {
    try await expect(["sh", "-c", OwnDesktop.pauseScript(container: container)], "The computer could not be paused")
  }
  /// Stops the container, which ends every process inside; the next start starts it again.
  func restart() async throws {
    try await expect(["docker", "stop", "-t", "5", container], "The computer could not be stopped")
  }
  /// Remove: the container, its home volume and, when no other Serein computer is left there,
  /// the image. Throws while the machine has not confirmed it, so it is never reported gone early.
  func delete() async throws {
    let code = try await link.run(["sh", "-c", OwnDesktop.removeScript(container: container, volume: volume)]).code
    if code == 125 { throw SereinError.invalid(OwnCard.dockerNotAnswering(target: link.name)) }
    guard code == 0 else { throw SereinError.invalid("The computer on \(link.name) could not be removed (code \(code)).") }
  }
  func stopForQuit(paused: Bool) {
    let stop = "docker stop -t 5 \(container)"
    link.runBlocking(["sh", "-c", paused ? "docker unpause \(container) >/dev/null 2>&1; " + stop : stop], seconds: 15)
  }
}

/// "Use this machine as it is": the person's Linux desktop or Mac with Serein's helper in their
/// home folder (OwnHelperManifest), written again at every start as their user, with no root and
/// nothing that starts by itself. Its link is the helper's own ssh session; it has no proxy shim
/// (the machine's internet is its own). Serein never resets, empties or archives it.
@MainActor final class OwnMachineComputer: OwnBackend {
  let capabilities = ComputerCapabilities.ownMachine
  let link: SSHLink
  /// The shipped helper file.
  private let helper: () -> URL?
  /// A line for the person (Remove kept a folder that holds something else).
  private let note: (String) -> Void

  init(link: SSHLink, helper: @escaping () -> URL?, note: @escaping (String) -> Void) {
    self.link = link
    self.helper = helper
    self.note = note
  }
  var helperCommand: [String] { OwnHelperManifest.helperCommand }

  /// Installs (or rewrites) the helper, only the pinned one; the machine itself is already running.
  func start() async throws -> Bool {
    guard let file = helper() else { throw SereinError.invalid("Serein's helper is missing from this copy of Serein.") }
    guard let data = try? Data(contentsOf: file), ComputerPins.matches(data, ComputerPins.helper) else {
      throw SereinError.invalid(ComputerPins.changedCopy)
    }
    let result = try await link.run(["sh", "-c", OwnHelperManifest.installScript], input: file)
    switch result.code {
    case 0: return false
    case 3: throw SereinError.invalid(OwnCard.noPython(target: link.name))
    case 4: throw SereinError.invalid(OwnCard.folderTaken(target: link.name))
    default: throw SereinError.invalid("Serein's helper could not be installed on \(link.name): \(result.reason)")
    }
  }
  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream
  {
    try link.open(command, stdin: stdin, onStdout: onStdout, onEnd: onEnd)
  }
  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    try await link.run(command, input: input, sink: sink).code
  }
  /// The helper's link is closed first (`linksSurvivePause` is false); the machine carries on.
  func pause() async throws {}
  func restart() async throws {
    throw SereinError.invalid("Serein never resets your own machine.")
  }
  /// Remove: exactly the manifest's items. Throws while the machine has not confirmed it.
  func delete() async throws {
    let code = try await link.run(["sh", "-c", OwnHelperManifest.removeScript]).code
    guard code == 0 || code == 5 else { throw SereinError.invalid("Serein's helper on \(link.name) could not be removed (code \(code)).") }
    if code == 5 {
      note("~/\(OwnHelperManifest.folder) on \(link.name) stays because something else is in it; Serein removed only its helper.")
    }
  }
  func stopForQuit(paused: Bool) {}
}
