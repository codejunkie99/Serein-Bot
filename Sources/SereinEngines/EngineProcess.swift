import Foundation

/// A started CLI as drivers see it: whole lines in, whole lines out.
public final class EngineProcess: Sendable {
  let hosted: any HostedProcess
  /// stdout split into lines, with no size cap; finishes when the CLI closes stdout.
  public let lines: AsyncStream<Data>

  init(_ hosted: any HostedProcess) {
    self.hosted = hosted
    let (lines, continuation) = AsyncStream<Data>.makeStream()
    self.lines = lines
    Task {
      var framer = LineFramer()
      for await chunk in hosted.output {
        for line in framer.feed(chunk) { continuation.yield(line) }
      }
      if let tail = framer.finish() { continuation.yield(tail) }
      continuation.finish()
    }
  }

  public func send(line: Data) throws {
    var data = line
    data.append(0x0A)
    try hosted.write(data)
  }

  public func closeInput() { hosted.closeInput() }
  public var pgid: pid_t { hosted.pgid }
}
