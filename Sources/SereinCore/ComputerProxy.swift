import Darwin
import Foundation

/// The HTTP(S) CONNECT proxy Serein runs for its computer: the computer has no network of its
/// own, so every connection its browser makes arrives here (over the helper link, ComputerWire),
/// is judged by the person's site rules and the private-address rules (ComputerNetworkPolicy),
/// and is then piped to the site. The address the proxy connects to is the one it checked: a
/// name is resolved once and every answer is checked, so a name that later points at this Mac
/// changes nothing. Each client is one file descriptor served on the calling thread.
public enum ComputerProxy {
  public struct Rules {
    /// Why the host is refused before any lookup, or nil (ComputerNetworkPolicy.hostRefusal
    /// with the task's assistant's Never sites).
    public var hostRefusal: (String, Int) -> String?
    /// Every connection, once, with the host and the refusal if there was one (the step timeline).
    public var log: (String, String?) -> Void
    public init(hostRefusal: @escaping (String, Int) -> String?, log: @escaping (String, String?) -> Void) {
      self.hostRefusal = hostRefusal
      self.log = log
    }
  }

  /// Serves one client connection to its end: reads its request, judges it, connects, pipes.
  /// Closes `client` when done.
  public static func serve(client: Int32, rules: Rules) {
    defer { Darwin.close(client) }
    var yes: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    guard let read = readHead(client) else { return }
    let (head, rest) = read
    guard let request = ComputerProxyRequest.parse(head) else {
      refuse(client, "Serein's computer only reaches sites through CONNECT or plain http requests.")
      return
    }
    if let reason = rules.hostRefusal(request.host, request.port) {
      rules.log(request.host, reason)
      refuse(client, reason)
      return
    }
    let addresses = resolve(request.host, port: request.port)
    guard !addresses.isEmpty else {
      rules.log(request.host, "The name could not be found.")
      refuse(client, "\(request.host) could not be found.")
      return
    }
    if let blocked = addresses.first(where: { ComputerNetworkPolicy.blockedAddress($0.text) }) {
      let reason = ComputerNetworkPolicy.privateRefusal + " (\(request.host) resolves to \(blocked.text).)"
      rules.log(request.host, reason)
      refuse(client, reason)
      return
    }
    if request.tunnel {
      // A tunnel's first record names the site it is for (TLS server name). It must be the host
      // the rules checked, or a connection allowed for one host could ask that host's servers
      // for another site. So the proxy reads that record before it connects.
      guard writeAll(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return }
      let hello = readFirstRecord(client, already: rest)
      if let reason = TLSClientHello.refusal(TLSClientHello.read(hello), host: request.host) {
        rules.log(request.host, reason)
        return
      }
      guard let upstream = connect(addresses) else {
        rules.log(request.host, "The site did not answer.")
        return
      }
      defer { Darwin.close(upstream) }
      rules.log(request.host, nil)
      guard writeAll(upstream, hello) else { return }
      pipe(client, upstream)
      return
    }
    guard let upstream = connect(addresses) else {
      rules.log(request.host, "The site did not answer.")
      refuse(client, "\(request.host) did not answer.", status: "502 Bad Gateway")
      return
    }
    defer { Darwin.close(upstream) }
    rules.log(request.host, nil)
    guard writeAll(upstream, Data((request.forwardHead ?? "").utf8)), writeAll(upstream, rest) else { return }
    pipe(client, upstream)
  }

  /// The bytes of a tunnel's first record (with any bytes that came with the request head), read
  /// for at most 30 seconds and `TLSClientHello.maxRecord` bytes. What it returns is forwarded to
  /// the site unchanged once the record passes.
  private static func readFirstRecord(_ fd: Int32, already: Data) -> Data {
    var buffer = already
    var chunk = [UInt8](repeating: 0, count: 4096)
    while buffer.count < TLSClientHello.maxRecord {
      guard case .needMore(let count) = TLSClientHello.read(buffer), buffer.count < count else { break }
      guard wait(fd, seconds: 30) else { break }
      let n = Darwin.read(fd, &chunk, chunk.count)
      guard n > 0 else { break }
      buffer.append(contentsOf: chunk.prefix(n))
    }
    return buffer
  }

  /// The request head up to the blank line, and any bytes that came after it.
  private static func readHead(_ fd: Int32) -> (String, Data)? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while buffer.count < ComputerProxyRequest.headLimit {
      guard wait(fd, seconds: 30) else { return nil }
      let n = Darwin.read(fd, &chunk, chunk.count)
      guard n > 0 else { return nil }
      buffer.append(contentsOf: chunk.prefix(n))
      if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        return (head, Data(buffer[range.upperBound...]))
      }
    }
    return nil
  }

  private static func refuse(_ fd: Int32, _ reason: String, status: String = "403 Forbidden") {
    let body = Data((reason + "\n").utf8)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nProxy-Connection: close\r\n\r\n"
    _ = writeAll(fd, Data(head.utf8) + body)
  }

  struct Address {
    var text: String
    var storage: sockaddr_storage
    var length: socklen_t
  }

  /// Every address the name resolves to, in the resolver's order, each with its text for the rules.
  static func resolve(_ host: String, port: Int) -> [Address] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_ADDRCONFIG
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return [] }
    defer { freeaddrinfo(first) }
    var out: [Address] = []
    var node: UnsafeMutablePointer<addrinfo>? = first
    while let info = node {
      defer { node = info.pointee.ai_next }
      guard let addr = info.pointee.ai_addr else { continue }
      var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(addr, info.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      var storage = sockaddr_storage()
      withUnsafeMutableBytes(of: &storage) { dst in
        dst.copyBytes(from: UnsafeRawBufferPointer(start: addr, count: Int(info.pointee.ai_addrlen)))
      }
      out.append(Address(text: String(cString: text), storage: storage, length: info.pointee.ai_addrlen))
    }
    return out
  }

  /// A connection to the first address that answers within a few seconds; nil when none does.
  private static func connect(_ addresses: [Address]) -> Int32? {
    for address in addresses {
      var storage = address.storage
      let family = Int32(storage.ss_family)
      let fd = Darwin.socket(family, SOCK_STREAM, 0)
      guard fd >= 0 else { continue }
      var yes: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
      var timeout = timeval(tv_sec: 10, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      let result = withUnsafePointer(to: &storage) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, address.length) }
      }
      if result == 0 {
        timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
      }
      Darwin.close(fd)
    }
    return nil
  }

  private static func wait(_ fd: Int32, seconds: Int32) -> Bool {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&p, 1, seconds * 1000) > 0
  }

  /// Writes every byte, or false when the other side is gone. Shared with the engine client.
  public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    return data.withUnsafeBytes { raw -> Bool in
      var done = 0
      while done < raw.count {
        let n = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { return false }
        done += n
      }
      return true
    }
  }

  /// Copies bytes both ways until both sides are done. A side that stops sending closes the
  /// other's write half, so a site's last bytes still arrive; two idle minutes end it.
  private static func pipe(_ a: Int32, _ b: Int32) {
    var openA = true
    var openB = true
    var chunk = [UInt8](repeating: 0, count: 65536)
    while openA || openB {
      var fds = [pollfd(fd: openA ? a : -1, events: Int16(POLLIN), revents: 0),
                 pollfd(fd: openB ? b : -1, events: Int16(POLLIN), revents: 0)]
      let ready = poll(&fds, 2, 120_000)
      guard ready > 0 else { return }
      for (i, from) in [(0, a), (1, b)] where fds[i].revents != 0 {
        let to = from == a ? b : a
        let n = Darwin.read(from, &chunk, chunk.count)
        if n > 0 {
          guard writeAll(to, Data(chunk.prefix(n))) else { return }
        } else if n == 0 || errno != EINTR {
          shutdown(to, SHUT_WR)
          if from == a { openA = false } else { openB = false }
        }
      }
    }
  }
}
