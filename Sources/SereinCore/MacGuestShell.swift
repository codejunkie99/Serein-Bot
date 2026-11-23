import Foundation

/// Shell and files on Serein's own virtual Mac: what the guest app runs for `computer_run`,
/// `computer_read_file` and `computer_send_file`, and the pure parts both sides share (paths,
/// output cuts, file slices). Everything runs inside the virtual Mac as its signed-in user; the
/// guest refuses to run anywhere but a virtual Mac (GuestGuard).
public enum MacGuestShell {
  /// The mailbox actions that may run for a while, so the guest answers them off its loop.
  public static let actions: Set<String> = ["run", "read_file", "file_out"]
  /// The shell a command runs in, as a login shell so the Mac user's PATH applies.
  public static let shell = "/bin/zsh"
  /// Seconds a command may run before it is stopped.
  public static let timeout = ComputerPolicy.commandTimeout
  /// Characters of output or file text one answer carries.
  public static let textLimit = ComputerPolicy.outputLimit
  /// Bytes read from a command's output before it is cut: enough for `textLimit` characters of
  /// any UTF-8 text, so a cut never falls short of the limit.
  public static let byteLimit = ComputerPolicy.outputLimit * 4
  /// Bytes one file leaving through the Outbox may have.
  public static let fileLimit = ComputerPolicy.fileOutLimit
  /// The exchange file a file leaving the Mac is copied to, for one request.
  public static func outName(_ id: UUID) -> String { "out-\(id.uuidString).bin" }
  /// Long jobs keep running after a turn only in Serein's Linux computers.
  public static let detachRefusal =
    "On Serein's virtual Mac, run the command without detach. For a long job, start it in the background yourself (nohup your-command > ~/job.log 2>&1 &) and read ~/job.log with computer_read_file."

  /// An absolute path inside the Mac: `~` and `~/…` are the user's home; anything else must start
  /// with `/`. Nil for an empty path, a relative one or one with a NUL.
  public static func resolve(_ raw: String, home: String) -> String? {
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
    return path.hasPrefix("/") ? path : nil
  }

  /// A command's output as text cut at `textLimit` characters, and whether anything was left out.
  public static func cut(_ data: Data, truncated: Bool = false) -> (text: String, cut: Bool) {
    let text = String(decoding: data, as: UTF8.self)
    guard text.count > textLimit else { return (text, truncated) }
    return (String(text.prefix(textLimit)), true)
  }

  /// A file's text from byte `start`: at most `textLimit` characters, and where the next part
  /// begins when more is left (a byte offset, on a character boundary). Nil when the bytes from
  /// `start` are not valid UTF-8: decoded with replacements, the offset would drift.
  public static func slice(_ data: Data, start: Int) -> (text: String, next: Int?)? {
    guard start >= 0, start < data.count else { return ("", nil) }
    return page(data[(data.startIndex + start)...], start: start, atEnd: true)
  }

  /// One part of a file from a window of its bytes read at `start` (at most `byteLimit` of them,
  /// so a huge file is never read whole). `atEnd`: the window reaches the end of the file;
  /// otherwise a character cut at the window's edge is left for the next part.
  public static func page(_ window: Data, start: Int, atEnd: Bool) -> (text: String, next: Int?)? {
    let bytes = atEnd ? Data(window) : Data(window.prefix(completeLength(window)))
    guard let text = String(data: bytes, encoding: .utf8) else { return nil }
    if text.count > textLimit {
      let part = String(text.prefix(textLimit))
      return (part, start + part.utf8.count)
    }
    return (text, atEnd ? nil : start + bytes.count)
  }

  public enum FileKind: Equatable, Sendable {
    case file(size: Int), folder, other
  }
  /// What is at `path`, following a symlink to its target: a regular file with the target's size,
  /// a folder, or something else. Nil when nothing is there (or the link is broken).
  public static func fileKind(_ path: String) -> FileKind? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    switch info.st_mode & S_IFMT {
    case S_IFREG: return .file(size: Int(info.st_size))
    case S_IFDIR: return .folder
    default: return .other
    }
  }

  /// The length of `bytes` without a UTF-8 sequence cut off at its end.
  static func completeLength(_ bytes: Data) -> Int {
    let all = [UInt8](bytes)
    var index = all.count - 1
    // Back over at most three continuation bytes to the last lead byte.
    while index >= 0, all.count - index <= 4, all[index] & 0xC0 == 0x80 { index -= 1 }
    guard index >= 0 else { return all.count }
    let lead = all[index]
    let needed = lead < 0x80 ? 1 : lead >> 5 == 0b110 ? 2 : lead >> 4 == 0b1110 ? 3 : lead >> 3 == 0b11110 ? 4 : 1
    return all.count - index < needed ? index : all.count
  }
}
