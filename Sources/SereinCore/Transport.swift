import Darwin
import Foundation

public struct Capability: Codable {
  public var socket: String
  public var token: String
  public var task: String
  public init(socket: String, task: String) {
    self.socket = socket
    self.task = task
    token = UUID().uuidString + UUID().uuidString
  }
  public func write(to url: URL) throws {
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  public static func read(from path: String) throws -> Capability {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else {
      throw SereinError.invalid("Missing or unsafe browser capability. Launch through Serein.")
    }
    return try JSONDecoder().decode(
      Capability.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }
}
public enum LocalSocket {
  public static func address(_ path: String) throws -> sockaddr_un {
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else {
      throw SereinError.invalid("Socket path too long")
    }
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &a.sun_path) { dst in dst.copyBytes(from: bytes) }
    return a
  }
  public static func send(_ value: Any, fd: Int32) throws {
    var data = Data(jsonString(value).utf8)
    data.append(10)
    try data.withUnsafeBytes { ptr in
      var count = 0
      while count < data.count {
        let n = Darwin.write(fd, ptr.baseAddress!.advanced(by: count), data.count - count)
        guard n > 0 else { throw SereinError.invalid("Browser connection closed") }
        count += n
      }
    }
  }
  public static func receive(fd: Int32) throws -> [String: Any] {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < 2_000_000 {
      let n = Darwin.read(fd, &buf, buf.count)
      guard n > 0 else { throw SereinError.invalid("Browser connection timed out or closed") }
      data.append(contentsOf: buf.prefix(n))
      if let end = data.firstIndex(of: 10) {
        guard
          let result = try JSONSerialization.jsonObject(with: data.prefix(upTo: end))
            as? [String: Any]
        else { throw SereinError.invalid("Invalid browser response") }
        return result
      }
    }
    throw SereinError.invalid("Browser response exceeded size limit")
  }
  public static func configure(_ fd: Int32) {
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    // Past the server's longest wait (a held secure card), so the caller hears every answer.
    var timeout = timeval(tv_sec: SecureCard.socketTimeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }
  /// Lets another thread end a request that is waiting for its answer.
  public final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var ended = false
    public init() {}
    /// A blocked read wakes on shutdown, not on close. The request closes its own socket.
    public func end() {
      lock.withLock {
        ended = true
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
      }
    }
    /// False once ended. -1 lets go of a socket about to close, so `end` never reaches a reused number.
    fileprivate func take(_ socket: Int32) -> Bool {
      lock.withLock {
        fd = socket
        return !ended
      }
    }
  }
  public static func request(_ value: [String: Any], capability: Capability, hold: Hold? = nil) throws -> [String: Any]
  {
    var envelope = value
    envelope["token"] = capability.token
    envelope["task"] = capability.task
    return try request(envelope, socket: capability.socket, hold: hold)
  }
  /// One request and its answer on any Serein socket.
  public static func request(_ envelope: [String: Any], socket: String, hold: Hold? = nil) throws -> [String: Any] {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SereinError.invalid("Could not create socket") }
    defer {
      _ = hold?.take(-1)
      Darwin.close(fd)
    }
    guard hold?.take(fd) != false else { throw CancellationError() }
    configure(fd)
    var address = try address(socket)
    let result = withUnsafePointer(to: &address) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw SereinError.invalid("Serein is closed or the task has ended") }
    // A Stop that landed before the connect could not shut the socket down, so it is seen here.
    guard hold?.take(fd) != false else { throw CancellationError() }
    try send(envelope, fd: fd)
    return try receive(fd: fd)
  }
}
public final class SocketServer {
  /// How long a call waits for its answer: below every agent's tool limit, so the caller hears
  /// the answer (or this timeout) before it gives up. A card inside the call closes before then
  /// (`CallWindow`); a secure card holding the call moves it out (`CallClock`).
  public static let answerWait: TimeInterval = 118
  private var fd: Int32 = -1
  private let path: String
  /// `concurrent` serves each connection on its own thread, for clients that call at the same
  /// time (outside agents, and agents' browser helpers, whose calls ToolGate orders per task);
  /// otherwise one connection at a time.
  public init(
    path: String, concurrent: Bool = false,
    handler: @escaping ([String: Any], CallClock, @escaping ([String: Any]) -> Void) -> Void
  ) throws {
    self.path = path
    fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SereinError.invalid("Could not create socket") }
    var a = try LocalSocket.address(path)
    let result = withUnsafePointer(to: &a) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw SereinError.invalid("Could not bind browser socket")
    }
    chmod(path, 0o600)
    guard Darwin.listen(fd, 8) == 0 else {
      Darwin.close(fd)
      unlink(path)
      throw SereinError.invalid("Could not listen on socket")
    }
    let serverFD = fd
    DispatchQueue.global(qos: .userInitiated).async {
      while true {
        let client = Darwin.accept(serverFD, nil, nil)
        if client < 0 { break }
        // The socket is owner-only already; a caller from another account is refused as well.
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
          Darwin.close(client)
          continue
        }
        if concurrent {
          DispatchQueue.global(qos: .userInitiated).async { SocketServer.serve(client, handler) }
        } else {
          // Serial connection processing bounds resource use; tool calls are short.
          SocketServer.serve(client, handler)
        }
      }
    }
  }
  private static func serve(
    _ client: Int32, _ handler: @escaping ([String: Any], CallClock, @escaping ([String: Any]) -> Void) -> Void
  ) {
    LocalSocket.configure(client)
    defer { Darwin.close(client) }
    // A caller that hung up without a request (a probe) gets no answer: macOS refuses
    // SO_NOSIGPIPE on a closed socket, so writing to it would end Serein with SIGPIPE.
    guard let request = try? LocalSocket.receive(fd: client) else { return }
    do {
      let box = ReplyBox()
      let ready = DispatchSemaphore(value: 0)
      let clock = CallClock()
      handler(request, clock) { response in
        box.set(response)
        ready.signal()
      }
      while ready.wait(timeout: .now() + max(0, clock.deadline.timeIntervalSinceNow)) == .timedOut {
        if clock.deadline.timeIntervalSinceNow <= 0 { throw SereinError.invalid("Browser operation timed out") }
      }
      try LocalSocket.send(box.get(), fd: client)
    } catch { try? LocalSocket.send(["error": error.localizedDescription], fd: client) }
  }
  public func stop() {
    if fd >= 0 {
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
      fd = -1
      unlink(path)
    }
  }
  deinit { stop() }
}
private final class ReplyBox {
  private let lock = NSLock()
  private var response: [String: Any] = [:]
  func set(_ value: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    response = value
  }
  func get() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return response
  }
}
