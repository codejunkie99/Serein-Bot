import Darwin
import Foundation
import SereinCore

/// The local container engine Serein's computer runs on: Docker Desktop, Colima, OrbStack or
/// Podman, found by their Unix sockets. Serein talks to the Engine API over that socket with the
/// small HTTP client below; it never runs the `docker` command and opens no port.
enum DockerSocket {
  struct Found: Equatable {
    var path: String
    var name: String
  }
  /// Every place a local engine listens, in the order they are tried. `DOCKER_HOST` set to a
  /// unix:// path comes first, as the engine's own tools honour it.
  static func candidates(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment)
    -> [Found]
  {
    var list: [Found] = []
    if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
      list.append(Found(path: String(host.dropFirst("unix://".count)), name: "Docker (DOCKER_HOST)"))
    }
    list += [
      Found(path: home + "/.docker/run/docker.sock", name: "Docker Desktop"),
      Found(path: home + "/.orbstack/run/docker.sock", name: "OrbStack"),
      Found(path: home + "/.colima/default/docker.sock", name: "Colima"),
      Found(path: home + "/.colima/docker.sock", name: "Colima"),
      Found(path: "/var/run/docker.sock", name: "Docker"),
    ]
    // Podman machines: one socket per machine under its data folder.
    let machines = home + "/.local/share/containers/podman/machine"
    for folder in (try? FileManager.default.contentsOfDirectory(atPath: machines)) ?? [] {
      list.append(Found(path: machines + "/" + folder + "/podman.sock", name: "Podman"))
    }
    list.append(Found(path: home + "/.local/share/containers/podman/machine/podman.sock", name: "Podman"))
    return list
  }
  /// Docker is on this Mac even when no engine runs now: a live socket, an engine's own folder
  /// (where its socket appears while it runs), or the app of Docker Desktop or OrbStack.
  static func installed(home: String = NSHomeDirectory()) -> Bool {
    if find() != nil { return true }
    let evidence = [
      home + "/.docker/run", home + "/.orbstack", home + "/.colima", home + "/.local/share/containers/podman/machine",
      "/Applications/Docker.app", "/Applications/OrbStack.app",
    ]
    return evidence.contains { FileManager.default.fileExists(atPath: $0) }
  }
  /// The first candidate that is a socket file now.
  static func find() -> Found? {
    candidates().first { candidate in
      var info = stat()
      return lstat(candidate.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }
  }
}

struct DockerResponse {
  var status: Int
  var headers: [String: String]
  var body: Data
  var object: Any? { try? JSONSerialization.jsonObject(with: body) }
  var dictionary: [String: Any] { object as? [String: Any] ?? [:] }
  var ok: Bool { (200..<300).contains(status) }
  /// The engine's message for a failed call, in its own words.
  var message: String { dictionary["message"] as? String ?? String(decoding: body.prefix(200), as: UTF8.self) }
}

struct DockerError: LocalizedError {
  var text: String
  var errorDescription: String? { text }
}

/// A connection in flight that another thread may end (a build the person cancelled).
final class DockerCancel {
  private let lock = NSLock()
  private var fd: Int32 = -1
  private var cancelled = false
  func attach(_ fd: Int32) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !cancelled else { return false }
    self.fd = fd
    return true
  }
  func cancel() {
    lock.lock(); defer { lock.unlock() }
    cancelled = true
    if fd >= 0 { shutdown(fd, SHUT_RDWR) }
  }
  var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }
}

/// HTTP/1.1 over the engine's Unix socket: one request per connection, blocking, so every call
/// runs off the main thread. Bodies by Content-Length or chunked; `stream` hands chunked JSON
/// lines over as they come; `hijack` keeps the connection as a raw byte stream (exec).
final class DockerEngine {
  let socketPath: String
  init(socketPath: String) { self.socketPath = socketPath }

  private func open(timeout seconds: Int32) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DockerError(text: "Could not create a socket for the container engine.") }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: Int(seconds), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = try LocalSocket.address(socketPath)
    let result = withUnsafePointer(to: &address) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw DockerError(text: "The container engine is not running (its socket did not answer).")
    }
    return fd
  }

  private func send(_ fd: Int32, method: String, path: String, body: Data?, contentType: String, extra: [String]) throws {
    var head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: Serein\r\n"
    for line in extra { head += line + "\r\n" }
    if let body {
      head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
    }
    head += "\r\n"
    guard ComputerProxy.writeAll(fd, Data(head.utf8)), ComputerProxy.writeAll(fd, body ?? Data()) else {
      throw DockerError(text: "The container engine closed the connection.")
    }
  }

  /// The status line and headers, and whatever body bytes came with them.
  private func readHead(_ fd: Int32) throws -> (status: Int, headers: [String: String], rest: Data) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    while buffer.count < 65536 {
      let n = Darwin.read(fd, &chunk, chunk.count)
      guard n > 0 else { throw DockerError(text: "The container engine sent no answer.") }
      buffer.append(contentsOf: chunk.prefix(n))
      guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
      let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
      let lines = head.components(separatedBy: "\r\n")
      let words = lines.first?.split(separator: " ", maxSplits: 2) ?? []
      guard words.count >= 2, let status = Int(words[1]) else { throw DockerError(text: "The container engine sent a reply Serein could not read.") }
      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
          line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      }
      return (status, headers, Data(buffer[range.upperBound...]))
    }
    throw DockerError(text: "The container engine sent a reply that was too long.")
  }

  /// Reads the body as the headers say; `onData` sees each piece as it arrives.
  private func readBody(_ fd: Int32, headers: [String: String], rest: Data, limit: Int, onData: (Data) -> Void) throws {
    var chunk = [UInt8](repeating: 0, count: 65536)
    var total = 0
    func take(_ data: Data) throws {
      total += data.count
      guard total <= limit else { throw DockerError(text: "The container engine's reply was too large.") }
      onData(data)
    }
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      var buffer = rest
      while true {
        guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
          let n = Darwin.read(fd, &chunk, chunk.count)
          guard n > 0 else { return }
          buffer.append(contentsOf: chunk.prefix(n))
          continue
        }
        let sizeText = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
          .split(separator: ";").first.map(String.init) ?? ""
        // A size past what is left of the limit is refused before any arithmetic on it.
        guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0, size <= limit - total else {
          throw DockerError(text: "The container engine sent a chunk Serein could not read.")
        }
        buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
        if size == 0 { return }
        while buffer.count < size + 2 {
          let n = Darwin.read(fd, &chunk, chunk.count)
          guard n > 0 else { return }
          buffer.append(contentsOf: chunk.prefix(n))
        }
        try take(Data(buffer.prefix(size)))
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + size + 2)
      }
    }
    if let lengthText = headers["content-length"], let length = Int(lengthText) {
      guard length >= 0, length <= limit else { throw DockerError(text: "The container engine sent a reply Serein could not read.") }
      var got = rest
      if got.count > length { got = got.prefix(length) }
      try take(got)
      var remaining = length - got.count
      while remaining > 0 {
        let n = Darwin.read(fd, &chunk, min(chunk.count, remaining))
        guard n > 0 else { return }
        try take(Data(chunk.prefix(n)))
        remaining -= n
      }
      return
    }
    try take(rest)
    while true {
      let n = Darwin.read(fd, &chunk, chunk.count)
      guard n > 0 else { return }
      try take(Data(chunk.prefix(n)))
    }
  }

  /// One call, whole answer. Blocking.
  func request(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json",
               timeout: Int32 = 60, limit: Int = 8_000_000) throws -> DockerResponse {
    let fd = try open(timeout: timeout)
    defer { Darwin.close(fd) }
    try send(fd, method: method, path: path, body: body, contentType: contentType, extra: [])
    let head = try readHead(fd)
    var body = Data()
    try readBody(fd, headers: head.headers, rest: head.rest, limit: limit) { body.append($0) }
    return DockerResponse(status: head.status, headers: head.headers, body: body)
  }
  func json(_ method: String, _ path: String, _ object: [String: Any]? = nil, timeout: Int32 = 60) throws -> DockerResponse {
    let body = try object.map { try JSONSerialization.data(withJSONObject: $0) }
    return try request(method, path, body: body, timeout: timeout)
  }

  /// A long answer of JSON lines (a build): each whole line goes to `onLine` as it arrives. The
  /// status is the headers' status; the engine reports a failed step inside the lines.
  func stream(_ method: String, _ path: String, body: Data?, contentType: String, cancel: DockerCancel,
              onLine: @escaping ([String: Any]) -> Void) throws -> Int {
    let fd = try open(timeout: 600)
    defer { Darwin.close(fd) }
    guard cancel.attach(fd) else { throw DockerError(text: "Cancelled.") }
    try send(fd, method: method, path: path, body: body, contentType: contentType, extra: [])
    let head = try readHead(fd)
    var pending = Data()
    try readBody(fd, headers: head.headers, rest: head.rest, limit: 64_000_000) { data in
      pending.append(data)
      while let newline = pending.firstIndex(of: 10) {
        let line = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { onLine(object) }
      }
    }
    if let object = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] { onLine(object) }
    return head.status
  }

  /// Starts an exec and keeps its connection as a raw stream: bytes written go to the process's
  /// stdin; bytes read are its output in the engine's frames (ComputerWire.dockerFrame). The
  /// caller owns the descriptor.
  func hijack(_ path: String, _ object: [String: Any]) throws -> (fd: Int32, rest: Data) {
    let fd = try open(timeout: 30)
    let body = try JSONSerialization.data(withJSONObject: object)
    do {
      try send(fd, method: "POST", path: path, body: body, contentType: "application/json",
               extra: ["Connection: Upgrade", "Upgrade: tcp"])
      let head = try readHead(fd)
      guard head.status == 101 || head.status == 200 else {
        var text = Data()
        try? readBody(fd, headers: head.headers, rest: head.rest, limit: 100_000) { text.append($0) }
        throw DockerError(text: DockerResponse(status: head.status, headers: head.headers, body: text).message)
      }
      // The stream has no end: clear the read timeout the connection was opened with.
      var none = timeval(tv_sec: 0, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
      return (fd, head.rest)
    } catch {
      Darwin.close(fd)
      throw error
    }
  }
}
