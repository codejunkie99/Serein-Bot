import Darwin
import Foundation
import SereinCore

/// Starts each CLI through serein-process-host, so it leads its own group and has a run record
/// before it can run.
struct SereinProcessHost: ProcessHosting {
  /// One value per spawn, inherited by everything the CLI starts, so a stop finds a descendant
  /// that left its tree. The run tag is shared by every CLI of this Serein and cannot scope a stop.
  static let spawnVariable = "SEREIN_SPAWN_TAG"
  let records: RunRecords

  /// A turn with no folder runs in a private empty one, never in Serein's own working directory.
  private func emptyFolder() throws -> URL {
    let folder = records.root.deletingLastPathComponent().appendingPathComponent("engine-empty", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
  }

  /// Reads only: every no-folder turn of every CLI shares the folder, so a file one turn's shell
  /// planted there (an `.mcp.json`, an `AGENTS.md`) would load in the next.
  private static func readable(_ folder: URL) -> String {
    let path = folder.standardizedFileURL.path
    let spellings = Set([path, AgentFileGuard.physicalPath(path)]).sorted().map { "(subpath " + jsonString($0) + ")" }
    return "(allow file-read* " + spellings.joined(separator: " ") + ")\n"
  }

  func spawn(_ contract: LaunchContract) throws -> any HostedProcess {
    let process = Process()
    var environment = contract.environment.merging(records.environment) { _, record in record }
    let spawnTag = UUID().uuidString
    environment[Self.spawnVariable] = spawnTag
    let folder = try contract.access.folder ?? emptyFolder()
    // A turn with no folder runs in the shared empty one inside the library the guard closes.
    let profile = contract.sandboxProfile.map { contract.access.folder == nil ? $0 + Self.readable(folder) : $0 }
    if let profile {
      // sandbox-exec execs the CLI, so its pid and process group stay the same.
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments = ["-p", profile, contract.executable.path] + contract.argv
    } else {
      process.executableURL = contract.executable
      process.arguments = contract.argv
    }
    process.environment = environment
    process.currentDirectoryURL = folder
    try ProcessGroup.configure(process)
    return try HostedCLI(process, records: records, marker: "\(Self.spawnVariable)=\(spawnTag)")
  }
}

private final class HostedCLI: HostedProcess, @unchecked Sendable {
  let pgid: pid_t
  let output: AsyncStream<Data>
  private let input: FileHandle
  private let lock = NSLock()
  private var exit: ProcessExit?
  private var waiting: [CheckedContinuation<ProcessExit, Never>] = []
  private var stderrTail = Data()
  private let marker: String
  private var reached: [pid_t: ProcessGroupRecord.Live] = [:]
  private let walking = NSLock()
  private let watch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

  init(_ process: Process, records: RunRecords, marker: String) throws {
    self.marker = marker
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    input = stdin.fileHandleForWriting
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    output = stream
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        continuation.finish()
      } else {
        continuation.yield(data)
      }
    }
    try process.run()
    // The host calls setsid before exec, so the pid leads the group from then on.
    pgid = process.processIdentifier
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty { handle.readabilityHandler = nil; return }
      self.lock.withLock {
        self.stderrTail.append(data)
        if self.stderrTail.count > 8_192 { self.stderrTail.removeFirst(self.stderrTail.count - 8_192) }
      }
    }
    // A command started detached whose parent then leaves goes to launchd, and Codex clears its
    // environment, so neither the tree at stop time nor the spawn tag finds it: walk while it runs.
    watch.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
    watch.setEventHandler { [weak self] in _ = self?.learn(tagged: false) }
    watch.resume()
    let pid = pgid
    process.terminationHandler = { [weak self] done in
      self?.watch.cancel()
      records.release(pid)
      self?.finish(status: done.terminationStatus, signaled: done.terminationReason == .uncaughtSignal)
    }
  }

  private func finish(status: Int32, signaled: Bool) {
    let (done, resumed) = lock.withLock {
      let done = ProcessExit(status: status, signaled: signaled, stderr: String(decoding: stderrTail, as: UTF8.self))
      exit = done
      defer { waiting = [] }
      return (done, waiting)
    }
    for continuation in resumed { continuation.resume(returning: done) }
  }

  func write(_ data: Data) throws { try input.write(contentsOf: data) }
  func closeInput() {
    // A CLI that leaves on end of input orphans its detached children: learn them while it runs.
    _ = learn(tagged: true)
    try? input.close()
  }

  func signalGroup(_ signal: Int32) {
    let found = learn(tagged: true)
    for pid in found.keys { _ = kill(pid, signal) }
    for group in Set(found.values.map(\.pgid)).subtracting([pgid, getpgrp(), 0, 1]) { _ = kill(-group, signal) }
    // Before the host's setsid the group does not exist yet; the leader alone is the whole run.
    // After the leader exits its group lives on in its children, so the group goes first.
    if kill(-pgid, signal) != 0, errno == ESRCH { _ = kill(pgid, signal) }
  }

  /// True while the CLI's group or any process it started runs.
  var groupAlive: Bool {
    (kill(-pgid, 0) == 0 || errno == EPERM) || (kill(pgid, 0) == 0 || errno == EPERM) || !learn(tagged: true).isEmpty
  }

  /// Every process the CLI started that still runs (same pid and start time): its descendants,
  /// and with `tagged` any process still carrying this spawn's tag. Descendants seen once are
  /// kept, so a stop still reaches them after their parent or the CLI left.
  private func learn(tagged: Bool) -> [pid_t: ProcessGroupRecord.Live] {
    walking.withLock {
      let table = KernelProcessTable()
      var found: [pid_t: ProcessGroupRecord.Live] = [:]
      for (pid, seen) in lock.withLock({ reached }) {
        if let live = table.live(pid), live.started == seen.started { found[pid] = live }
      }
      var parents = [pgid] + Array(found.keys)
      while let parent = parents.popLast() {
        for child in table.children(of: parent) where found[child] == nil {
          guard let live = table.live(child) else { continue }
          found[child] = live
          parents.append(child)
        }
      }
      if tagged {
        for pid in table.carrying(marker) where found[pid] == nil && pid != pgid {
          if let live = table.live(pid) { found[pid] = live }
        }
      }
      lock.withLock { reached = found }
      return found
    }
  }

  func exited() async -> ProcessExit {
    await withCheckedContinuation { continuation in
      let done: ProcessExit? = lock.withLock {
        if let exit { return exit }
        waiting.append(continuation)
        return nil
      }
      if let done { continuation.resume(returning: done) }
    }
  }
}

/// The kernel's view, for the sweep.
struct KernelProcessTable: ProcessTable {
  func live(_ pid: pid_t) -> ProcessGroupRecord.Live? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
      info.pbi_uid == getuid(), info.pbi_status != SZOMB
    else { return nil }
    return ProcessGroupRecord.Live(
      started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, pgid: Int32(bitPattern: info.pbi_pgid))
  }

  func members(ofGroup pgid: pid_t) -> [pid_t] { pids(PROC_PGRP_ONLY, UInt32(pgid)) }
  func children(of pid: pid_t) -> [pid_t] { pids(PROC_PPID_ONLY, UInt32(pid)) }

  /// This user's processes whose environment holds `entry` (`NAME=value`).
  func carrying(_ entry: String) -> [pid_t] {
    pids(PROC_UID_ONLY, getuid()).filter { environment(of: $0)?.contains(entry) == true }
  }

  private func pids(_ type: Int32, _ info: UInt32) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 4096)
    let bytes = buffer.withUnsafeMutableBytes { proc_listpids(UInt32(type), info, $0.baseAddress, Int32($0.count)) }
    return buffer.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
  }

  /// KERN_PROCARGS2 is argc, the exec path, NUL padding, argc arguments (any may be empty), then
  /// the environment.
  func environment(of pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var index = MemoryLayout<Int32>.size
    func next() -> String? {
      guard index < size, let end = buffer[index..<size].firstIndex(of: 0) else { return nil }
      defer { index = end + 1 }
      return String(decoding: buffer[index..<end], as: UTF8.self)
    }
    _ = next()
    while index < size, buffer[index] == 0 { index += 1 }
    for _ in 0..<argc { _ = next() }
    var environment: [String] = []
    while let entry = next(), !entry.isEmpty { environment.append(entry) }
    return environment
  }

  func signalGroup(_ pgid: pid_t, _ signal: Int32) { _ = kill(-pgid, signal) }
}
