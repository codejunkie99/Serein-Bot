import Foundation
import SereinCore

/// One command kept open inside a computer: a `docker exec` stream (ExecStream), a hosted
/// computer's process stream (E2BStream, DaytonaStream), or an ssh process to the person's own
/// machine (SSHStream). The helper's JSON lines (HelperChannel) and the proxy's
/// frames (ProxyMux) run over either, so the tools, the approvals and the proxy rules are the same
/// wherever the computer runs.
protocol ComputerStream: AnyObject {
  var isClosed: Bool { get }
  /// The last lines the command wrote to stderr, for diagnostics.
  var stderrLines: [String] { get }
  /// The bytes for the command's stdin, whole and in order; false once the stream is gone.
  @discardableResult func write(_ data: Data) -> Bool
  /// Ends the command's stdin; its output keeps coming.
  func closeWrite()
  /// Ends the stream; its end callback fires once.
  func close()
}

/// Where one computer runs, as ComputerHost drives it. Screen and input are not part of this:
/// they go through Serein's helper over a command stream (`openStream`), the same on every
/// backend, unless the backend has them itself (NativeScreen), so a backend never sees the
/// person's Mac or the agent's tools.
@MainActor protocol ComputerBackend: AnyObject {
  var capabilities: ComputerCapabilities { get }
  /// Makes sure the computer exists and runs: creates it, or wakes it when paused or stopped.
  /// True when it was newly created.
  func start() async throws -> Bool
  /// Starts `command` inside as the computer's unprivileged user and keeps it open: `onStdout`
  /// gets its output as it comes (on a background thread), `onEnd` fires once when it ends.
  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream
  /// One command to its end: the file `input`, if any, is its stdin; its stdout goes to `sink`
  /// (on a background thread). Returns its exit code.
  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int
  /// Pauses it, with its memory where `capabilities.pauseKeepsMemory`.
  func pause() async throws
  /// Ends every process inside, for a reset. Docker stops the container (the next start starts
  /// it again with its home volume); a backend whose `resetMakesNew` deletes the computer.
  func restart() async throws
  /// Deletes the computer and everything in it; throws while the backend has not confirmed it.
  func delete() async throws
  /// At quit, blocking as quit is: Docker stops the container, a hosted computer is paused.
  func stopForQuit(paused: Bool)
  /// The helper's command, kept open as its JSON-lines link: Serein's in-computer helper, or on
  /// the person's own machine the helper in their home folder (OwnMachineComputer).
  var helperCommand: [String] { get }
  /// The command that runs Cua Driver's MCP server inside this computer over `openStream`, or nil
  /// when this backend never runs it. Whether the computer carries the driver is not this answer:
  /// its start check finds out (ComputerPins.carriesDriver), and ComputerHost.driverScreen needs both.
  var driverCommand: [String]? { get }
  /// `openStream` with stdin as the computer's `shell` user (serein-start.sh), which neither the
  /// display nor the buses admit: computer_run's helper. Nil where this backend has no such user.
  func openShell(_ command: [String], onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream?
}

extension ComputerBackend {
  var helperCommand: [String] { ["python3", "-I", "/opt/serein/helper.py"] }
  var driverCommand: [String]? { nil }
  func openShell(_ command: [String], onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream? { nil }
}

/// A computer on another company's servers under the person's own account (E2BComputer,
/// DaytonaComputer). On top of ComputerBackend (capabilities, create and resume in `start`, the
/// command stream, pause, delete): the network it is made with and confirmed against on every
/// start, files Serein itself puts in, the keep-alive that stops the provider from pausing a
/// computer still in use, and usage. The person's provider key is never put inside the computer,
/// and its public addresses stay off.
@MainActor protocol HostedComputer: ComputerBackend {
  /// The internet the computer is made with, and the one each start has the provider confirm
  /// (a computer whose confirmed network differs is set to this, or not used).
  var network: HostedNetwork { get set }
  /// Whether this start may create or wake the computer (it costs money): false for a run nobody
  /// started by hand unless the person allowed that for the assistant. Checked against the
  /// provider's own state, so a computer the provider paused by itself is not woken either.
  var mayWake: Bool { get set }
  /// Puts a file Serein made (never one an agent names on this Mac) at `path` inside.
  func putFile(_ file: URL, at path: String) async throws
  /// Tells the provider the running computer is still in use.
  func keepAlive() async
  /// Running time so far with the computer's size, for Serein's estimate, and the provider's own
  /// report where it gives one.
  var usage: HostedUsage.Spent { get }
}

extension HostedComputer {
  /// Refuses a create or wake this start may not make (`mayWake`), with the schedule rule's words.
  func wakeAllowed(provider: String) throws {
    guard mayWake else {
      throw SereinError.invalid(
        HostedSpending.startRefusal(
          paid: true, running: false, unattended: true, allowedUnattended: false, provider: provider, assistant: "This assistant")
          ?? HostedCard.needsPerson(provider))
    }
  }
}

/// A backend with screen and input calls of its own (Daytona's computer-use API), used in place of
/// the helper's ops of the same names: `screenshot` (answers `png`, base64), `click`, `type`,
/// `key`, `scroll` (same arguments as the helper's), `windows` (answers `windows`) and `tree`
/// (answers `tree` and `cut`). Every answer is untrusted, as the helper's are.
@MainActor protocol NativeScreen: AnyObject {
  func screen(_ op: String, _ arguments: [String: Any]) async throws -> [String: Any]
}

/// A hosted computer whose provider reports what it cost (Daytona's usage API); `usage` carries
/// the report once fetched.
@MainActor protocol ReportsUsage: AnyObject {
  func refreshUsage() async
}

/// Serein's computer in a hardened container on this Mac (ComputerPolicy, DockerEngine): the
/// Docker part of 33a behind ComputerBackend, unchanged in what it asks of the engine.
@MainActor final class DockerComputer: OwnedHomeCheckpoint {
  let capabilities = ComputerCapabilities.docker
  private let assistantID: String
  private let findEngine: () -> DockerEngine?
  /// The person's read-only shared folder for this computer (ComputerSharedFolder), checked again
  /// at every start; nil for none.
  private let shared: () -> String?
  private var resumeKey: String { "serein.docker.checkpointResume." + assistantID }
  private var pendingResumeID: String? {
    get { UserDefaults.standard.string(forKey: resumeKey) }
    set { UserDefaults.standard.set(newValue, forKey: resumeKey) }
  }
  private var pendingRecoveryWorker: String? {
    get { UserDefaults.standard.string(forKey: "serein.docker.checkpointRecovery." + assistantID) }
    set { UserDefaults.standard.set(newValue, forKey: "serein.docker.checkpointRecovery." + assistantID) }
  }
  var checkpointNeedsResume: Bool { pendingResumeID != nil }
  private var pendingCheckpointCleanup = Set<String>()
  private var containerID: String?
  private var containerName: String { ComputerPolicy.containerPrefix + assistantID }
  private var volumeName: String { ComputerPolicy.volumePrefix + assistantID }

  /// The architecture of an image built with this copy's Cua Driver for it (its
  /// `serein.computer.driver` label, read by ComputerHost.inspectImage), or nil for none: such an
  /// image's start check requires that driver.
  let driverArch: () -> CuaDriverRelease.Arch?

  init(
    assistantID: String, engine: @escaping () -> DockerEngine?, shared: @escaping () -> String?,
    driverArch: @escaping () -> CuaDriverRelease.Arch? = { nil }
  ) {
    self.assistantID = assistantID
    findEngine = engine
    self.shared = shared
    self.driverArch = driverArch
  }
  var driverCommand: [String]? { CuaDriverRelease.boxCommand }
  private func liveEngine() throws -> DockerEngine {
    guard let engine = findEngine() else { throw SereinError.invalid(ComputerPolicy.noBackend) }
    return engine
  }
  private func running() throws -> String {
    guard let id = containerID else { throw SereinError.invalid("Serein's computer is not running.") }
    return id
  }

  /// The container for this computer as the engine knows it: its id, state, image and the shared
  /// folder it was made with (its label), or nil.
  private func findContainer(_ engine: DockerEngine) async throws -> (id: String, state: String, image: String, shared: String)? {
    let filters = jsonString(["name": [containerName], "label": [ComputerPolicy.label]])
      .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    let reply = try await Task.detached { try engine.request("GET", "/containers/json?all=true&filters=\(filters)", timeout: 15) }.value
    guard reply.ok, let list = reply.object as? [[String: Any]] else { throw DockerError(text: reply.message) }
    let name = containerName
    let exact = list.first { ($0["Names"] as? [String])?.contains("/" + name) == true }
    guard let exact, let id = exact["Id"] as? String else { return nil }
    let labels = exact["Labels"] as? [String: Any] ?? [:]
    return (id, exact["State"] as? String ?? "", exact["ImageID"] as? String ?? "", labels[ComputerSharedFolder.label] as? String ?? "")
  }

  /// The hardening every computer starts with. No network, no capabilities, no new
  /// privileges, a read-only root, its own home volume, the person's RAM and CPU caps, no
  /// mounts but the person's shared folder bound read-only (`:ro`) outside the home, no ports,
  /// never privileged.
  func containerConfig(memoryMB: Int, cpus: Int, volume: String, shared: String?) -> [String: Any] {
    var host: [String: Any] = [
      "NetworkMode": "none",
      "CapDrop": ["ALL"],
      "SecurityOpt": ["no-new-privileges:true"],
      "ReadonlyRootfs": true,
      "Privileged": false,
      "PublishAllPorts": false,
      "Memory": Int64(memoryMB) * 1_048_576,
      "MemorySwap": Int64(memoryMB) * 1_048_576,
      "NanoCpus": Int64(cpus) * 1_000_000_000,
      "PidsLimit": 1024,
      "ShmSize": 268_435_456,
      "Init": true,
      "Tmpfs": [
        "/tmp": "rw,nosuid,size=512m", "/run": "rw,nosuid,noexec,size=16m", "/var/tmp": "rw,nosuid,noexec,size=64m",
      ],
      "Mounts": [["Type": "volume", "Source": volume, "Target": "/home/serein"]],
      "RestartPolicy": ["Name": "no"],
    ]
    if let shared { host["Binds"] = [shared + ":" + ComputerSharedFolder.mountPoint + ":ro"] }
    return [
      "Image": ComputerPolicy.imageTag,
      "Hostname": "serein-computer",
      "User": "1000:1000",
      "Labels": [ComputerPolicy.label: assistantID, ComputerSharedFolder.label: shared ?? ""],
      "Tty": false, "OpenStdin": false,
      "HostConfig": host,
    ]
  }

  func start() async throws -> Bool {
    let engine = try liveEngine()
    var created = false
    var found = try await findContainer(engine)
    let shared = self.shared()
    // A container made from an older image (Rebuild) or with another shared folder is made again
    // around the same home volume, so the pinned files and the person's mount are the ones in use.
    // A bind Docker's file sharing does not allow fails with the engine's own words: say what fixes it.
    let sharingHint = shared == nil ? "" : " " + ComputerSharedFolder.dockerSharing
    let image = (try? await currentImage(engine)) ?? ""
    if let old = found, (!image.isEmpty && old.image != image) || old.shared != (shared ?? "") {
      let id = old.id
      let removed = try await Task.detached { try engine.request("DELETE", "/containers/\(id)?force=true", timeout: 60) }.value
      guard removed.ok || removed.status == 404 else { throw DockerError(text: removed.message) }
      containerID = nil
      found = nil
    }
    if found == nil {
      let memory = ComputerPolicy.memoryMB(totalBytes: ProcessInfo.processInfo.physicalMemory)
      let cpus = ComputerPolicy.cpus(cores: ProcessInfo.processInfo.activeProcessorCount)
      let volume = volumeName
      let owner = self.assistantID
      _ = try await Task.detached {
        try engine.json("POST", "/volumes/create", ["Name": volume, "Labels": [ComputerPolicy.label: owner]], timeout: 30)
      }.value
      let config = containerConfig(memoryMB: memory, cpus: cpus, volume: volume, shared: shared)
      let name = containerName
      let made = try await Task.detached { try engine.json("POST", "/containers/create?name=\(name)", config, timeout: 60) }.value
      guard made.ok, let id = made.dictionary["Id"] as? String else { throw DockerError(text: made.message + sharingHint) }
      found = (id, "created", image, shared ?? "")
      created = true
    }
    guard let container = found else { throw DockerError(text: "The computer could not be created.") }
    containerID = container.id
    let id = container.id
    if container.state != "running" || pendingRecoveryWorker != nil {
      // An interrupted restore must finish rollback before the desktop sees its home.
      guard try await checkpoint(.recover, input: nil, sink: { _ in }) == 0 else {
        throw SereinError.invalid("Docker could not confirm recovery of the home. The saved archive is kept.")
      }
    }
    switch container.state {
    case "running" where pendingResumeID != id: break
    case "running", "paused":
      let completion = await resumeAfterCheckpoint(.success(0), id: id, engine: engine)
      guard completion.desktopRunning else { throw DockerError(text: "Docker could not confirm that the desktop resumed.") }
    default:
      let reply = try await Task.detached { try engine.request("POST", "/containers/\(id)/start", timeout: 60) }.value
      guard reply.ok || reply.status == 304 else { throw DockerError(text: reply.message + sharingHint) }
    }
    pendingResumeID = nil // Docker confirmed the current desktop is available.
    return created
  }

  /// The id of Serein's image as the engine has it now ("" when it is not there).
  private func currentImage(_ engine: DockerEngine) async throws -> String {
    let reply = try await Task.detached { try engine.request("GET", "/images/\(ComputerPolicy.imageTag)/json", timeout: 10) }.value
    return reply.ok ? reply.dictionary["Id"] as? String ?? "" : ""
  }

  private func execStream(_ engine: DockerEngine, container: String, cmd: [String], stdin: Bool, user: String = "1000:1000")
    async throws -> (fd: Int32, rest: Data, execID: String)
  {
    let created = try await Task.detached {
      try engine.json("POST", "/containers/\(container)/exec", [
        "AttachStdin": stdin, "AttachStdout": true, "AttachStderr": true, "Tty": false, "Cmd": cmd,
        "User": user, "WorkingDir": "/home/serein",
      ], timeout: 30)
    }.value
    guard created.ok, let execID = created.dictionary["Id"] as? String else { throw DockerError(text: created.message) }
    let stream = try await Task.detached { try engine.hijack("/exec/\(execID)/start", ["Detach": false, "Tty": false]) }.value
    return (stream.fd, stream.rest, execID)
  }

  /// A `docker exec` kept open as a raw stream (the helper, the proxy shim).
  func openStream(_ command: [String], stdin: Bool, onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream
  {
    let stream = try await execStream(try liveEngine(), container: try running(), cmd: command, stdin: stdin)
    return ExecStream(fd: stream.fd, rest: stream.rest, onStdout: onStdout, onEnd: onEnd)
  }
  /// The image's `shell` user (uid 1001) in the desktop user's group.
  func openShell(_ command: [String], onStdout: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    async throws -> ComputerStream?
  {
    let stream = try await execStream(try liveEngine(), container: try running(), cmd: command, stdin: true, user: "1001:1000")
    return ExecStream(fd: stream.fd, rest: stream.rest, onStdout: onStdout, onEnd: onEnd)
  }

  /// One command to its end: the file `input` is streamed to its stdin in 1 MB pieces off the
  /// main actor, its stdout goes to `sink` (on the reader thread); returns its exit code.
  func runOnce(_ command: [String], input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    let engine = try liveEngine()
    let stream = try await execStream(engine, container: try running(), cmd: command, stdin: input != nil)
    return try await finishOnce(stream, engine: engine, input: input, sink: sink)
  }

  /// Cleanup is independent of a committed restore. A worker normally disappears on DELETE,
  /// on stop through AutoRemove, or when its fixed lifetime ends. Retry lost replies locally.
  @discardableResult private func retireCheckpointWorker(_ id: String, engine: DockerEngine) async -> Bool {
    let retired = await Task.detached {
      if let removed = try? engine.request("DELETE", "/containers/\(id)?force=true", timeout: 20),
         removed.ok || removed.status == 404 { return true }
      if let stopped = try? engine.request("POST", "/containers/\(id)/stop?t=0", timeout: 15),
         stopped.ok || stopped.status == 404 { return true }
      return false
    }.value
    if retired {
      pendingCheckpointCleanup.remove(id)
    } else if pendingCheckpointCleanup.insert(id).inserted {
      NSLog("Serein will retry checkpoint worker cleanup when Docker is available.")
    }
    return retired
  }

  /// A private maintenance container can read both owners without granting capabilities to
  /// the desktop. It receives only the home volume and the exact image of the running box.
  func checkpoint(_ operation: CheckpointOperation, input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    let engine = try liveEngine()
    guard let found = try await findContainer(engine) else { throw SereinError.invalid("The checkpoint computer is missing.") }
    if operation == .restore && !["created", "exited"].contains(found.state) {
      throw SereinError.invalid("Stop the Docker desktop before restoring its home.")
    }
    if let previous = pendingRecoveryWorker {
      guard operation == .recover, await retireCheckpointWorker(previous, engine: engine) else {
        throw SereinError.invalid("Docker has not confirmed the previous checkpoint operation. Resume the computer to recover its home.")
      }
    }
    for id in Array(pendingCheckpointCleanup) { await retireCheckpointWorker(id, engine: engine) }
    let command = try operation.command(home: "/checkpoint")
    let mount: [String: Any] = ["Type": "volume", "Source": volumeName, "Target": "/checkpoint", "ReadOnly": operation == .save || operation == .check]
    let config: [String: Any] = [
      "Labels": ["app.serein.checkpoint-worker": assistantID],
      "Image": found.image, "Entrypoint": ["/bin/sleep", "3600"], "Cmd": [], "WorkingDir": "/", "User": "0:0",
      "HostConfig": ["NetworkMode": "none", "ReadonlyRootfs": true, "AutoRemove": true, "CapDrop": ["ALL"],
        "CapAdd": operation == .check ? [] : operation == .save ? ["DAC_OVERRIDE"] : ["DAC_OVERRIDE", "CHOWN", "FOWNER", "FSETID"],
        "SecurityOpt": ["no-new-privileges:true"], "Mounts": [mount], "PidsLimit": 8, "Memory": 536870912],
    ]
    let created = try await Task.detached { try engine.json("POST", "/containers/create", config) }.value
    guard created.ok, let id = created.dictionary["Id"] as? String else { throw DockerError(text: created.message) }
    let changesHome = operation == .recover || operation == .restore
    // Persist before starting the command: a dropped Docker reply does not stop the worker.
    // Another launch must retire this exact worker before inspecting or rolling back its journal.
    if changesHome { pendingRecoveryWorker = id }
    let resumeOwed = found.state == "running" && operation != .check
    let outcome: Result<Int, Error>
    do {
      if resumeOwed {
        // Persist before sending pause: Docker may accept it while its reply is lost.
        pendingResumeID = found.id
        let reply = try await Task.detached { try engine.request("POST", "/containers/\(found.id)/pause", timeout: 30) }.value
        guard reply.ok else { throw DockerError(text: reply.message) }
      }
      let start = try await Task.detached { try engine.request("POST", "/containers/\(id)/start", timeout: 60) }.value
      guard start.ok else { throw DockerError(text: start.message) }
      let stream = try await execStream(engine, container: id, cmd: command, stdin: input != nil, user: "0:0")
      outcome = .success(try await finishOnce(stream, engine: engine, input: input, sink: sink))
    } catch {
      outcome = .failure(error)
    }
    await retireCheckpointWorker(id, engine: engine)
    if changesHome {
      switch outcome {
      case .success(0): pendingRecoveryWorker = nil
      case .success(let code):
        // Recovery will inspect the on-volume journal before the desktop can run again.
        return code
      case .failure:
        throw SereinError.invalid("Docker did not confirm the checkpoint operation. The saved archive is kept. Resume the computer to recover its home.")
      }
    }
    guard resumeOwed else { return try outcome.get() }
    let completion = await resumeAfterCheckpoint(outcome, id: found.id, engine: engine)
    if completion.desktopRunning { pendingResumeID = nil }
    return try completion.result.get()
  }

  private func resumeAfterCheckpoint(_ outcome: Result<Int, Error>, id: String, engine: DockerEngine) async -> DockerCheckpointCompletion {
    await Task.detached {
      DockerCheckpointCompletion.finish(outcome, unpause: {
        (try? engine.request("POST", "/containers/\(id)/unpause", timeout: 15))?.ok == true
      }, state: {
        let response = try? engine.request("GET", "/containers/\(id)/json", timeout: 10)
        return (response?.dictionary["State"] as? [String: Any])?["Status"] as? String
      })
    }.value
  }

  private func finishOnce(_ stream: (fd: Int32, rest: Data, execID: String), engine: DockerEngine,
                          input: URL?, sink: @escaping (Data) -> Void) async throws -> Int {
    let execID = stream.execID
    // The stream may end before its initializer returns (a fast command): the first end resumes,
    // whenever it comes. The holder keeps the stream alive until then.
    final class Holder {
      let lock = NSLock()
      var done = false
      var stream: ExecStream?
    }
    let holder = Holder()
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
      let exec = ExecStream(fd: stream.fd, rest: stream.rest, onStdout: sink, onEnd: {
        holder.lock.lock()
        let first = !holder.done
        holder.done = true
        holder.lock.unlock()
        if first { finished.resume() }
      })
      holder.lock.lock()
      holder.stream = exec
      holder.lock.unlock()
      if let input {
        Task.detached {
          if let file = try? FileHandle(forReadingFrom: input) {
            while let piece = try? file.read(upToCount: 1_048_576), !piece.isEmpty {
              guard exec.write(piece) else { break }
            }
            try? file.close()
          }
          exec.closeWrite()
        }
      }
    }
    holder.lock.lock()
    holder.stream = nil
    holder.lock.unlock()
    return try await Task.detached {
      try DockerExecExit.wait(inspect: {
        try engine.request("GET", "/exec/\(execID)/json", timeout: 2)
      }, between: { Thread.sleep(forTimeInterval: 0.25) })
    }.value
  }

  /// `docker pause`: the container is frozen, its exec streams with it.
  func pause() async throws {
    let engine = try liveEngine()
    let id = try running()
    let reply = try await Task.detached { try engine.request("POST", "/containers/\(id)/pause", timeout: 30) }.value
    guard reply.ok || reply.status == 304 else { throw DockerError(text: reply.message) }
    pendingResumeID = nil
  }

  /// Stops the container, which ends every process inside (a background job, the browser) and
  /// empties /tmp, /var/tmp, /run and /dev/shm; the next start starts it again.
  func restart() async throws {
    let engine = try liveEngine()
    let id = try running()
    let stopped = try await Task.detached { try engine.request("POST", "/containers/\(id)/stop?t=5", timeout: 20) }.value
    guard stopped.ok || stopped.status == 304 else { throw DockerError(text: stopped.message) }
    pendingResumeID = nil
  }

  /// The container and its home volume; the image stays. Without an engine nothing can be
  /// deleted, so it throws: the computer is never reported gone while it is still there.
  func delete() async throws {
    guard let engine = findEngine() else { throw SereinError.invalid(ComputerPolicy.noBackend) }
    containerID = nil
    if let found = try? await findContainer(engine) {
      let id = found.id
      _ = try? await Task.detached { try engine.request("DELETE", "/containers/\(id)?v=true&force=true", timeout: 60) }.value
    }
    let volume = volumeName
    _ = try? await Task.detached { try engine.request("DELETE", "/volumes/\(volume)?force=true", timeout: 60) }.value
  }

  /// The container stops (its volume stays).
  func stopForQuit(paused: Bool) {
    guard let engine = findEngine(), let id = containerID else { return }
    if paused { _ = try? engine.request("POST", "/containers/\(id)/unpause", timeout: 10) }
    _ = try? engine.request("POST", "/containers/\(id)/stop?t=5", timeout: 15)
  }
}
