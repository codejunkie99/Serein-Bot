import Foundation
import CoreFoundation
import Darwin
import SereinCore

/// Writes the guest stream to a new private archive. The old checkpoint stays usable until
/// every byte is on disk and the guest has confirmed a complete snapshot.
final class CheckpointOutput: @unchecked Sendable {
  private let temporary: URL
  private let handle: FileHandle
  private let lock = NSLock()
  private var writeError: Error?

  init(replacing destination: URL) throws {
    temporary = destination.deletingLastPathComponent().appendingPathComponent(".checkpoint-" + UUID().uuidString)
    let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard writeError == nil else { return }
    do { try handle.write(contentsOf: data) } catch { writeError = error }
  }

  func finish() throws {
    lock.lock()
    defer { lock.unlock() }
    if let writeError { throw writeError }
    try handle.synchronize()
    try handle.close()
  }

  func publish(to destination: URL) throws {
    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  var url: URL { temporary }

  deinit { try? FileManager.default.removeItem(at: temporary) }
}

enum CheckpointOperation: String {
  case save, check, restore, recover

  static func verifyEnvelope(_ url: URL) throws {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let length = try file.seekToEnd()
    guard length >= 1024, length.isMultiple(of: 512) else {
      throw SereinError.invalid("The checkpoint archive is incomplete.")
    }
    try file.seek(toOffset: length - 1024)
    guard try file.read(upToCount: 1024) == Data(repeating: 0, count: 1024) else {
      throw SereinError.invalid("The checkpoint archive is incomplete.")
    }
  }

  func command(home: String) throws -> [String] {
    guard let url = Bundle.assets.url(forResource: "checkpoint", withExtension: "py", subdirectory: "Computer") else {
      throw SereinError.invalid("Serein’s checkpoint worker is missing.")
    }
    return ["/usr/bin/python3", "-I", "-c", try String(contentsOf: url, encoding: .utf8), rawValue, home]
  }
}

/// Only these fixed operations can access both guest identities. The model's command path
/// continues to run under the shell account.
@MainActor protocol OwnedHomeCheckpoint: ComputerBackend {
  func checkpoint(_ operation: CheckpointOperation, input: URL?, sink: @escaping (Data) -> Void) async throws -> Int
}

/// Docker can accept an unpause and lose its response. The worker exit status describes the
/// data operation. Desktop availability controls the resume notice and the next startup retry.
struct DockerCheckpointCompletion {
  let result: Result<Int, Error>
  let desktopRunning: Bool

  static func finish(_ result: Result<Int, Error>, unpause: () -> Bool, state: () -> String?) -> Self {
    for _ in 0..<2 {
      if unpause() { return Self(result: result, desktopRunning: true) }
      switch state() {
      case "running": return Self(result: result, desktopRunning: true)
      case "paused", nil: continue
      default: return Self(result: result, desktopRunning: false)
      }
    }
    return Self(result: result, desktopRunning: false)
  }
}

/// EOF ends the attachment, while only Docker's exec inspection can confirm the process exit.
enum DockerExecExit {
  static func wait(inspect: () throws -> DockerResponse, between: () -> Void) throws -> Int {
    for attempt in 1...8 {
      if let reply = try? inspect(), reply.ok {
        let fields = reply.dictionary
        if let running = fields["Running"] as? NSNumber, CFGetTypeID(running) == CFBooleanGetTypeID(),
           !running.boolValue, let code = fields["ExitCode"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(),
           (0...255).contains(code.intValue), code.doubleValue == Double(code.intValue) {
          return code.intValue
        }
      }
      if attempt < 8 { between() }
    }
    throw SereinError.invalid("Docker did not confirm that the command exited.")
  }
}
