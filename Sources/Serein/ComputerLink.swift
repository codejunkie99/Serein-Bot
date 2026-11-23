import Darwin
import Foundation
import SereinCore

/// The link between Serein and the helper inside its computer: a command kept open as a stream
/// (ComputerStream), on Docker a `docker exec` as a raw byte stream (DockerEngine.hijack), on the
/// built-in computer a virtio socket connection (VirtualMachineComputer), on a hosted computer its
/// provider's process stream (E2BStream, DaytonaStream). Nothing listens on any network; the
/// computer has no network of its own and no mount but the folder the person shares read-only. One stream carries the helper's JSON lines
/// (HelperChannel); another the browser's proxy connections (ProxyMux). Both run on their own
/// threads and hand results back through callbacks that hop to the main actor only where the
/// caller needs it.
final class ExecStream: ComputerStream {
  /// The descriptor, closed only when nobody can use it any more: the stream and its reader
  /// thread each hold this box, so a number the system hands out again never gets our bytes.
  private final class Descriptor {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
  }
  private let descriptor: Descriptor
  private var fd: Int32 { descriptor.fd }
  private let writeLock = NSLock()
  private var closed = false
  private let closedLock = NSLock()
  /// The last lines the process wrote to stderr, for the settings page's diagnostics.
  private(set) var stderrTail: [String] = []
  /// The exit code a framed stream's last frame carried (stream 3, the built-in computer's link).
  private var exitStatus: Int?
  private let tailLock = NSLock()
  /// What owns the descriptor this one was duplicated from, kept until the stream goes (the
  /// framework's socket connection on the built-in computer).
  private let keep: AnyObject?

  /// Starts reading at once: `onStdout` gets each stdout frame's bytes (every byte when the
  /// stream is not `framed`), `onEnd` fires once when the stream ends (the process exited, the
  /// engine or the computer closed it, or `close` was called).
  init(fd: Int32, rest: Data, framed: Bool = true, keep: AnyObject? = nil, onStdout: @escaping (Data) -> Void,
       onEnd: @escaping () -> Void) {
    let descriptor = Descriptor(fd)
    self.descriptor = descriptor
    self.keep = keep
    let thread = Thread { [weak self] in
      let fd = descriptor.fd
      var buffer = rest
      var chunk = [UInt8](repeating: 0, count: 65536)
      func drain() {
        guard framed else {
          if !buffer.isEmpty { onStdout(buffer) }
          buffer.removeAll()
          return
        }
        while let frame = ComputerWire.dockerFrame(&buffer) {
          if frame.stream == 1 {
            onStdout(frame.payload)
          } else if frame.stream == 2, let self {
            self.tailLock.lock()
            self.stderrTail = Array((self.stderrTail + [String(decoding: frame.payload.prefix(300), as: UTF8.self)]).suffix(8))
            self.tailLock.unlock()
          } else if frame.stream == 3, let self {
            self.tailLock.lock()
            self.exitStatus = Int(String(decoding: frame.payload.prefix(12), as: UTF8.self))
            self.tailLock.unlock()
          }
        }
      }
      drain()
      while true {
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { break }
        buffer.append(contentsOf: chunk.prefix(n))
        drain()
      }
      self?.markClosed()
      onEnd()
    }
    thread.name = "serein.computer.exec"
    thread.qualityOfService = .userInitiated
    thread.start()
  }
  /// The reader saw the end: no more writes; the descriptor itself closes in `Descriptor.deinit`.
  private func markClosed() {
    closedLock.lock(); defer { closedLock.unlock() }
    guard !closed else { return }
    closed = true
    shutdown(fd, SHUT_RDWR)
  }
  deinit {
    // A stream let go while its reader still waits: the shutdown ends the read, and the
    // descriptor closes once the reader thread lets go of it too.
    shutdown(descriptor.fd, SHUT_RDWR)
  }
  var isClosed: Bool {
    closedLock.lock(); defer { closedLock.unlock() }
    return closed
  }
  var stderrLines: [String] {
    tailLock.lock(); defer { tailLock.unlock() }
    return stderrTail
  }
  var exitCode: Int? {
    tailLock.lock(); defer { tailLock.unlock() }
    return exitStatus
  }
  /// Writes to the process's stdin, whole; false once the stream is gone.
  @discardableResult
  func write(_ data: Data) -> Bool {
    guard !isClosed else { return false }
    writeLock.lock(); defer { writeLock.unlock() }
    return ComputerProxy.writeAll(fd, data)
  }
  /// Ends the process's stdin: the write half closes, the output keeps coming.
  func closeWrite() {
    guard !isClosed else { return }
    shutdown(fd, SHUT_WR)
  }
  /// Ends the stream: the reader thread sees the shutdown and closes the descriptor.
  func close() {
    closedLock.lock()
    let open = !closed
    closedLock.unlock()
    if open { shutdown(fd, SHUT_RDWR) }
  }
}

/// The helper's JSON lines over an exec stream: each request carries an id, each answer comes
/// back under it, and a request with no answer in time fails on its own (a late answer is dropped).
final class HelperChannel {
  private var stream: ComputerStream?
  private let lock = NSLock()
  private var nextID = 1
  private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var lineBuffer = Data()
  /// Helper answers can carry a screenshot or a 50 MB file: the line limit is above both.
  static let lineLimit = 80_000_000
  /// Called once when the stream ends; the owner then marks the computer as needing a restart.
  var onEnd: (() -> Void)?

  /// The callbacks a backend's stream is opened with (ComputerBackend.openStream); output that
  /// comes before `attach` is kept.
  var sink: (Data) -> Void { { [weak self] data in self?.received(data) } }
  var ender: () -> Void { { [weak self] in self?.ended() } }
  func attach(_ stream: ComputerStream) {
    lock.lock()
    self.stream = stream
    lock.unlock()
  }
  var isOpen: Bool {
    lock.lock(); defer { lock.unlock() }
    return stream.map { !$0.isClosed } ?? false
  }
  var stderrLines: [String] {
    lock.lock(); defer { lock.unlock() }
    return stream?.stderrLines ?? []
  }
  /// No request waits for its answer: the helper, which answers one at a time, is free now.
  var idle: Bool {
    lock.lock(); defer { lock.unlock() }
    return waiting.isEmpty
  }

  private func received(_ data: Data) {
    lock.lock()
    lineBuffer.append(data)
    if lineBuffer.count > Self.lineLimit { lineBuffer.removeAll() }
    while let newline = lineBuffer.firstIndex(of: 10) {
      let line = lineBuffer[lineBuffer.startIndex..<newline]
      lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
      if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int,
        let waiter = waiting.removeValue(forKey: id)
      {
        lock.unlock()
        waiter.resume(returning: object)
        lock.lock()
      }
    }
    lock.unlock()
  }
  private func ended() {
    lock.lock()
    let gone = waiting
    waiting.removeAll()
    lock.unlock()
    for (_, waiter) in gone { waiter.resume(throwing: SereinError.invalid("The link to Serein's computer closed.")) }
    onEnd?()
  }

  /// One request and its answer. Throws the helper's error, a timeout, or a closed link.
  func call(_ op: String, _ arguments: [String: Any] = [:], timeout seconds: Int = 30) async throws -> [String: Any] {
    lock.lock()
    let id = nextID
    nextID += 1
    guard let stream, !stream.isClosed else {
      lock.unlock()
      throw SereinError.invalid("The link to Serein's computer is not open.")
    }
    lock.unlock()
    var request = arguments
    request["id"] = id
    request["op"] = op
    let line = Data(jsonString(request).utf8) + Data([10])
    let answer: [String: Any] = try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      waiting[id] = continuation
      lock.unlock()
      guard stream.write(line) else {
        lock.lock()
        let waiter = waiting.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(throwing: SereinError.invalid("The link to Serein's computer closed."))
        return
      }
      Task.detached { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        guard let self else { return }
        self.lock.lock()
        let late = self.waiting.removeValue(forKey: id)
        self.lock.unlock()
        late?.resume(throwing: SereinError.invalid("Serein's computer did not answer within \(seconds) seconds."))
      }
    }
    if let error = answer["error"] as? String { throw SereinError.invalid(String(error.prefix(400))) }
    return answer
  }
  func close() {
    lock.lock()
    let stream = self.stream
    lock.unlock()
    stream?.close()
  }
}

/// The browser's proxy connections, multiplexed over one command stream by the shim inside the
/// computer. Each `open` becomes a socket pair: one end is served by the CONNECT proxy
/// (ComputerProxy.serve, on its own thread), the other is pumped to and from the stream.
final class ProxyMux {
  private var stream: ComputerStream?
  /// Guards `stream` only. Pumps take it to send while the reader may sit in a blocking write
  /// under `lock`, so the two never wait on each other. Never held while taking `lock`.
  private let streamLock = NSLock()
  /// Guards `ends` and `frameBuffer`.
  private let lock = NSLock()
  private var ends: [UInt32: Int32] = [:]
  private var frameBuffer = Data()
  private let rules: ComputerProxy.Rules
  /// Connections open at once, so a runaway page cannot exhaust threads.
  static let maxOpen = 64

  init(rules: ComputerProxy.Rules) { self.rules = rules }

  /// The callbacks a backend's stream is opened with (ComputerBackend.openStream).
  var sink: (Data) -> Void { { [weak self] data in self?.received(data) } }
  var ender: () -> Void { { [weak self] in self?.ended() } }
  func attach(_ stream: ComputerStream) {
    streamLock.lock()
    self.stream = stream
    streamLock.unlock()
  }

  private func received(_ data: Data) {
    lock.lock()
    frameBuffer.append(data)
    var frames: [(UInt32, ComputerWire.Kind, Data)] = []
    do {
      while let frame = try ComputerWire.decode(&frameBuffer) { frames.append(frame) }
    } catch {
      // Out of step: nothing sensible can follow, so the stream ends and the computer restarts it.
      lock.unlock()
      close()
      return
    }
    lock.unlock()
    for (id, kind, payload) in frames {
      switch kind {
      case .open: open(id)
      // Written and shut down under the lock the pump closes its end under, so the descriptor
      // is still this connection's when the bytes go.
      case .data:
        lock.lock()
        if let end = ends[id] { _ = ComputerProxy.writeAll(end, payload) }
        lock.unlock()
      case .close:
        lock.lock()
        if let end = ends[id] { shutdown(end, SHUT_WR) }
        lock.unlock()
      }
    }
  }

  private func open(_ id: UInt32) {
    var pair: [Int32] = [-1, -1]
    lock.lock()
    let room = ends.count < Self.maxOpen
    lock.unlock()
    guard room, socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      send(id, .close)
      return
    }
    let served = pair[0]
    let pumped = pair[1]
    // The reader writes here after the serve thread may have closed `served`: an error, not SIGPIPE.
    var yes: Int32 = 1
    setsockopt(pumped, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    lock.lock()
    ends[id] = pumped
    lock.unlock()
    let rules = self.rules
    let serve = Thread { ComputerProxy.serve(client: served, rules: rules) }
    serve.name = "serein.computer.proxy"
    serve.start()
    let pump = Thread { [weak self] in
      var chunk = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = Darwin.read(pumped, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { break }
        self?.send(id, .data, Data(chunk.prefix(n)))
      }
      self?.send(id, .close)
      if let self {
        self.lock.lock()
        self.ends[id] = nil
        Darwin.close(pumped)
        self.lock.unlock()
      } else {
        Darwin.close(pumped)
      }
    }
    pump.name = "serein.computer.pump"
    pump.start()
  }

  private func send(_ id: UInt32, _ kind: ComputerWire.Kind, _ payload: Data = Data()) {
    streamLock.lock()
    let stream = self.stream
    streamLock.unlock()
    stream?.write(ComputerWire.encode(id: id, kind: kind, payload: payload))
  }

  /// The stream is gone: every connection's end is shut down under the lock; each pump then
  /// removes and closes its own end, so no descriptor is touched after it closed.
  private func ended() {
    lock.lock()
    for (_, end) in ends { shutdown(end, SHUT_RDWR) }
    lock.unlock()
  }
  var isOpen: Bool {
    streamLock.lock(); defer { streamLock.unlock() }
    return stream.map { !$0.isClosed } ?? false
  }
  func close() {
    streamLock.lock()
    let stream = self.stream
    streamLock.unlock()
    stream?.close()
  }
}
