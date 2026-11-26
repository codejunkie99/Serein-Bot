import Darwin
import Foundation
import SereinCore

/// The environment an agent CLI starts with, and the one way a driver runs a short command.
enum CredentialEnv {
  /// `inherited` under the app's policy (`AgentFileGuard.environment`): every token, secret,
  /// password and credential variable and every secret-looking value goes, except `driver`'s own
  /// key variables; then `own` on top. A nil `driver` (a version probe) keeps no CLI's key.
  static func build(inherited: [String: String], own: [String: String], driver: HarnessDriver?) -> [String: String] {
    AgentFileGuard.environment(inherited, driver: driver).merging(own) { _, mine in mine }
  }

  /// Every CLI process a driver starts, turns and probes: `inherited` stripped (`build`), or kept
  /// whole under the person's own setup; the person's variables and Keychain key for this CLI
  /// (`TurnRequest.environment`) on top; the driver's `own` switches last. PATH is the
  /// executable's folder, then the login shell's PATH (`person["PATH"]`), then the usual folders.
  static func child(
    _ cli: HarnessDriver?, executable: URL, person: [String: String], own: [String: String] = [:],
    ownSetup: Bool = false, inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var env = ownSetup ? OwnSetup.environment(inherited) : build(inherited: inherited, own: [:], driver: cli)
    env.merge(person) { _, theirs in theirs }
    env.merge(own) { _, mine in mine }
    var seen = Set<String>()
    env["PATH"] = ([executable.deletingLastPathComponent().path]
      + LoginShellPath.searchPath(shell: person["PATH"], inherited: inherited["PATH"], home: NSHomeDirectory()))
      .filter { seen.insert($0).inserted }.joined(separator: ":")
    env["CLAUDECODE"] = nil
    env["CODEX_THREAD_ID"] = nil
    return env
  }

  /// A short command's output (stderr too unless `quietErrors`) and exit status; nil when it could
  /// not start, ended on a signal, or ran past `wait` (then it is killed). Blocks the caller.
  static func output(
    _ executable: URL, _ arguments: [String], environment: [String: String], within wait: Duration,
    folder: URL? = nil, quietErrors: Bool = false
  ) -> (text: String, status: Int32)? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    if let folder { process.currentDirectoryURL = folder }
    process.standardOutput = pipe
    process.standardError = quietErrors ? FileHandle.nullDevice : pipe
    process.standardInput = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    guard (try? process.run()) != nil else { return nil }
    let data = NSMutableData()
    // Read apart from the wait: a child that keeps the pipe open past its parent cannot hang it.
    DispatchQueue.global().async {
      data.append(pipe.fileHandleForReading.readDataToEndOfFile())
      read.signal()
    }
    let deadline = DispatchTime.now() + Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
    guard read.wait(timeout: deadline) == .success, exited.wait(timeout: deadline) == .success else {
      kill(process.processIdentifier, SIGKILL)
      return nil
    }
    guard process.terminationReason == .exit else { return nil }
    return (String(decoding: data as Data, as: UTF8.self), process.terminationStatus)
  }
}
