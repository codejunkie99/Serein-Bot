import Foundation

/// When a Claude Code chat last had a message, from the chat's own timestamps. After a turn ends
/// Claude Code appends bookkeeping lines (cost, title, last prompt, tools used) that move the
/// file's modification time without the chat changing; reading the time from those would make
/// every finished turn look as if a newer one had begun.
public enum TranscriptClock {
  /// How much of the end of a transcript is read: a turn's last lines are near its end.
  static let tailBytes = 256 * 1024

  /// The newest timestamp of a line you or Claude wrote in the main chat (not a helper's).
  public static func lastMessage(in data: Data) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    var latest: Date?
    for line in data.split(separator: 10) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let type = object["type"] as? String, type == "user" || type == "assistant",
        object["isSidechain"] as? Bool != true,
        let stamp = object["timestamp"] as? String,
        let date = fractional.date(from: stamp) ?? whole.date(from: stamp)
      else { continue }
      if latest.map({ date > $0 }) ?? true { latest = date }
    }
    return latest
  }

  /// The same, from the end of the file at `path`; nil when it cannot be read or has no stamps.
  public static func lastMessage(path: String) -> Date? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    guard (try? handle.seek(toOffset: offset)) != nil, var tail = try? handle.readToEnd() else { return nil }
    // A cut first line is not a whole line.
    if offset > 0, let newline = tail.firstIndex(of: 10) { tail = Data(tail[tail.index(after: newline)...]) }
    return lastMessage(in: tail)
  }
}
