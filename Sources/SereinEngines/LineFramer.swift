import Foundation

/// Splits a byte stream into newline-terminated lines. No size cap: a dropped line would lose a
/// tool result or a turn end, and the CLI's own output is the only producer.
struct LineFramer: Sendable {
  private var buffer: [UInt8] = []
  /// Bytes already searched for a newline, so a long line split across many reads is scanned once.
  private var scanned = 0

  mutating func feed(_ chunk: Data) -> [Data] {
    buffer.append(contentsOf: chunk)
    var lines: [Data] = []
    var start = 0
    var index = scanned
    while index < buffer.count {
      if buffer[index] == 0x0A {
        var end = index
        if end > start, buffer[end - 1] == 0x0D { end -= 1 }
        if end > start { lines.append(Data(buffer[start..<end])) }
        start = index + 1
      }
      index += 1
    }
    if start > 0 { buffer.removeFirst(start) }
    scanned = buffer.count
    return lines
  }

  /// The unterminated tail at end of stream, if any.
  mutating func finish() -> Data? {
    defer { buffer = []; scanned = 0 }
    return buffer.isEmpty ? nil : Data(buffer)
  }
}
