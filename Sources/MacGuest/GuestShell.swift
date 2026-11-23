import Foundation
import SereinCore

/// The guest side of shell and files (MacGuestShell): a command in zsh as this Mac's user, a
/// file's text, and a file copied into the exchange for the Outbox. Each runs off the main
/// thread, so screen and keyboard requests keep being answered meanwhile.
enum GuestShell {
  static var home: String { NSHomeDirectory() }

  /// Runs `command` in a login zsh in the home folder, stdin closed, stdout and stderr together.
  /// Stopped after `MacGuestShell.timeout` seconds (code 124, as `timeout` does).
  static func run(_ command: String, timeout: Int = MacGuestShell.timeout) async throws -> [String: String] {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.contains("\0") else {
      throw MacGuestFailure("command is required")
    }
    return try await Task.detached(priority: .userInitiated) { try runBlocking(command, timeout: timeout) }.value
  }

  private static func runBlocking(_ command: String, timeout: Int) throws -> [String: String] {
    let result = try ShellRunner.run(command, home: home, timeout: timeout)
    return ["output": result.output, "code": String(result.code), "cut": String(result.cut)]
  }

  /// A file's text from byte `start`: only a window of `MacGuestShell.byteLimit` bytes is read,
  /// so a huge file never fills the helper's memory (MacGuestShell.page).
  static func read(_ raw: String, start: Int) async throws -> [String: String] {
    guard let path = MacGuestShell.resolve(raw, home: home) else { throw MacGuestFailure("path must be absolute or start with ~") }
    return try await Task.detached(priority: .userInitiated) {
      let size = try regularFileSize(path)
      guard start < size else { return ["text": ""] }
      let window: Data
      do {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        window = try handle.read(upToCount: MacGuestShell.byteLimit) ?? Data()
      } catch { throw MacGuestFailure("Cannot read \(path): \(error.localizedDescription)") }
      guard let (text, next) = MacGuestShell.page(window, start: start, atEnd: start + window.count >= size) else {
        throw MacGuestFailure("\(path) is not UTF-8 text. Inspect it with computer_run (file, strings, iconv) instead.")
      }
      var values = ["text": text]
      if let next { values["next_start"] = String(next) }
      return values
    }.value
  }

  /// Copies a file into the exchange as `MacGuestShell.outName(id)` for the host to read once.
  static func fileOut(_ raw: String, id: UUID, mailbox: MacMailbox) async throws -> [String: String] {
    guard let path = MacGuestShell.resolve(raw, home: home) else { throw MacGuestFailure("path must be absolute or start with ~") }
    let data = try await Task.detached(priority: .userInitiated) {
      try regularFile(path, limit: MacGuestShell.fileLimit)
    }.value
    try mailbox.write(data, named: MacGuestShell.outName(id))
    return ["name": (path as NSString).lastPathComponent, "out": MacGuestShell.outName(id), "size": String(data.count)]
  }

  /// A regular file's size, following a symlink to its target (stat), refusing folders, missing
  /// files and anything that is not a regular file.
  private static func regularFileSize(_ path: String) throws -> Int {
    guard let kind = MacGuestShell.fileKind(path) else { throw MacGuestFailure("No file at \(path)") }
    switch kind {
    case .file(let size): return size
    case .folder: throw MacGuestFailure("\(path) is a folder; list it with computer_run ls")
    case .other: throw MacGuestFailure("\(path) is not a regular file")
    }
  }

  /// A regular file's bytes, refusing folders and anything over `limit`.
  private static func regularFile(_ path: String, limit: Int64) throws -> Data {
    let size = try regularFileSize(path)
    if Int64(size) > limit { throw MacGuestFailure("\(path) is larger than the Outbox takes") }
    do { return try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) }
    catch { throw MacGuestFailure("Cannot read \(path): \(error.localizedDescription)") }
  }
}
