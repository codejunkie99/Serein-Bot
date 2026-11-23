import Darwin
import Foundation

/// One shell command, run to its end or its time limit: a login zsh in `home`, stdin closed,
/// stdout and stderr together, output kept up to `MacGuestShell.byteLimit` and cut at
/// `MacGuestShell.textLimit` characters. It starts in a process group of its own, so a command
/// stopped at its limit is stopped with everything it started; a command that ends by itself
/// leaves its background jobs (`nohup … &`) running. `sandbox`, when given, is a sandbox-exec
/// profile the shell and everything it starts run inside; `environment` is added to Serein's own.
/// Blocking: callers run it off the main thread.
public enum ShellRunner {
  /// How long the output pipe may stay open after the command ends: a background child the
  /// command left running can hold it, and must not hold the answer.
  public static let drainWait: DispatchTimeInterval = .seconds(1)
  /// How long a group asked to stop has before it is killed.
  public static let stopGrace: DispatchTimeInterval = .seconds(2)
  /// The code a command stopped at its time limit reports, as `timeout` does.
  public static let timedOutCode: Int32 = 124
  static let sandboxExec = "/usr/bin/sandbox-exec"

  public struct Result: Sendable, Equatable {
    public let output: String
    public let code: Int32
    public let cut: Bool
  }

  public static func run(
    _ command: String, home: String, timeout: Int, sandbox: String? = nil, environment: [String: String] = [:]
  ) throws -> Result {
    let argv: [String] = sandbox.map { [sandboxExec, "-p", $0, MacGuestShell.shell, "-l", "-c", command] }
      ?? [MacGuestShell.shell, "-l", "-c", command]
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw MacGuestFailure("Cannot open a pipe for the command") }
    let pid: pid_t
    do { pid = try spawn(argv, home: home, environment: environment, output: fds[1]) } catch { close(fds[0]); close(fds[1]); throw error }
    close(fds[1])
    let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
    let collected = OutputBuffer(limit: MacGuestShell.byteLimit)
    let drained = DispatchSemaphore(value: 0)
    reader.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty { handle.readabilityHandler = nil; drained.signal() } else { collected.append(chunk) }
    }
    let exit = ExitWatch(pid)
    var timedOut = false
    if !exit.wait(.seconds(timeout)) {
      timedOut = true
      // The whole group: the shell and everything it started.
      kill(-pid, SIGTERM)
      if !exit.wait(stopGrace) { kill(-pid, SIGKILL); _ = exit.wait(nil) }
      kill(-pid, SIGKILL)
    }
    _ = drained.wait(timeout: .now() + drainWait)
    reader.readabilityHandler = nil
    try? reader.close()
    let (text, cut) = MacGuestShell.cut(collected.data, truncated: collected.overflowed)
    let note = timedOut ? "\n[stopped after \(timeout) seconds]" : ""
    return Result(output: text + note, code: timedOut ? timedOutCode : exit.code, cut: cut)
  }

  /// posix_spawn into a new process group (its own pid), in `home`, with stdin from /dev/null and
  /// stdout and stderr to `output`; every other descriptor is closed in the child.
  private static func spawn(_ argv: [String], home: String, environment: [String: String], output: Int32) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, output, 1)
    posix_spawn_file_actions_adddup2(&actions, output, 2)
    posix_spawn_file_actions_addchdir_np(&actions, home)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)
    let cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let cEnvironment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
      .merging(environment) { _, given in given }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (cArguments + cEnvironment).forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, argv[0], &actions, &attributes, cArguments, cEnvironment)
    guard status == 0 else { throw MacGuestFailure("Cannot start the command: \(String(cString: strerror(status)))") }
    return pid
  }
}

/// Waits for one child on a background thread and keeps its exit code (128 + the signal for a
/// child a signal ended).
private final class ExitWatch: @unchecked Sendable {
  private let ended = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var status: Int32 = 0
  private var done = false
  init(_ pid: pid_t) {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      var raw: Int32 = 0
      while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
      lock.lock(); status = raw; done = true; lock.unlock()
      ended.signal()
    }
  }
  /// True once the child ended within `limit` (nil waits as long as it takes).
  func wait(_ limit: DispatchTimeInterval?) -> Bool {
    lock.lock(); let already = done; lock.unlock()
    if already { return true }
    guard let limit else { ended.wait(); ended.signal(); return true }
    guard ended.wait(timeout: .now() + limit) == .success else { return false }
    ended.signal()
    return true
  }
  var code: Int32 {
    lock.lock(); defer { lock.unlock() }
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
  }
}

/// A command's output as it arrives, kept up to a limit; the reader keeps draining past it so the
/// command never blocks on a full pipe.
private final class OutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = Data()
  private var dropped = false
  let limit: Int
  init(limit: Int) { self.limit = limit }
  func append(_ chunk: Data) {
    lock.lock(); defer { lock.unlock() }
    let room = limit - stored.count
    if room <= 0 { if !chunk.isEmpty { dropped = true }; return }
    stored.append(chunk.prefix(room))
    if chunk.count > room { dropped = true }
  }
  var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
  var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return dropped }
}
