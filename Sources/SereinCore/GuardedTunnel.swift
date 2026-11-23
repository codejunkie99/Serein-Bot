import Foundation
import Network

/// Where a task-shell connection asks to go: the name (or address) the client sent, and the port.
public struct EgressTarget: Sendable, Equatable {
  public let name: String
  public let port: Int

  public init(name: String, port: Int) {
    self.name = name
    self.port = port
  }
}

public enum EgressVerdict: Sendable, Equatable {
  /// Open the tunnel to exactly this address.
  case dial(String)
  /// A tunnel answers success, then a TLS `access_denied` alert; a plain-http request gets a 403
  /// that says why. The person declined or has not answered yet.
  case refuse
  /// The name has no address: a plain gateway failure, so a typo never reads as a decline.
  case unreachable
}

/// Decides each tunnel of a task shell's proxy (`PluginEgress(policy:)`).
public protocol EgressPolicy: Sendable {
  /// May wait (the person's card); the proxy cancels the call when the client goes away.
  func connect(_ target: EgressTarget) async -> EgressVerdict
  /// From the tunnel's first TLS record, after it opened for `opened`.
  func hello(_ reading: TLSClientHello.Reading, opened: String) -> Bool
}

/// One client connection of a policy proxy, from its CONNECT, SOCKS5 or absolute-form plain-http
/// request to the end of the relay. Runs on the proxy's queue only. Each relayed chunk is read
/// only after the last one was sent. When Serein itself runs with an `HTTPS_PROXY` (a company
/// proxy), every dial goes through it, except hosts its `NO_PROXY` names.
final class GuardedTunnel: @unchecked Sendable {
  private enum Phase: Equatable {
    case request
    case socksRequest
    case waiting
    case dialing
    /// The person's own proxy is answering the CONNECT Serein chained to it.
    case upstream(opened: String)
    case hello(opened: String)
    case refusing
    case piping
    /// A last reply is on its way; then the tunnel closes.
    case closing
    case closed
  }

  private enum Framing { case http, socks }

  var onClose: (() -> Void)?
  private let client: NWConnection
  private let policy: any EgressPolicy
  private let queue: DispatchQueue
  private var remote: NWConnection?
  private var phase = Phase.request
  private var framing = Framing.http
  private var buffer = Data()
  /// A plain-http request's head in origin form, sent first once the remote is open.
  private var forward: Data?
  private var upstreamReply = Data()
  private var decision: Task<Void, Never>?
  private var clientEnded = false
  private var remoteEnded = false

  init(_ client: NWConnection, policy: any EgressPolicy, queue: DispatchQueue) {
    self.client = client
    self.policy = policy
    self.queue = queue
  }

  func start() { readClient() }

  func close() {
    guard phase != .closed else { return }
    phase = .closed
    decision?.cancel()
    client.cancel()
    remote?.cancel()
    remote?.stateUpdateHandler = nil
    onClose?()
    onClose = nil
  }

  private func readClient() {
    client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, error in
      guard phase != .closed else { return }
      let next = { [self] in
        guard phase != .closed, phase != .closing else { return }
        if error != nil || (done && phase != .piping) { close(); return }
        if done {
          clientEnded = true
          remote?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
          if remoteEnded { close() }
          return
        }
        readClient()
      }
      if let data, !data.isEmpty, phase == .piping, let remote {
        remote.send(content: data, completion: .contentProcessed { _ in next() })
        return
      }
      if let data, !data.isEmpty {
        buffer.append(data)
        // Before the tunnel opens a client gets one TLS record of room, or a plain request's body.
        guard buffer.count <= (forward == nil ? TLSClientHello.maxRecord : Self.bodyRoom) else { return close() }
        advance()
      }
      next()
    }
  }

  private static let bodyRoom = 1 << 20

  private func readRemote(_ remote: NWConnection) {
    remote.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, done, error in
      guard phase != .closed else { return }
      if case .upstream(let opened) = phase {
        if let data { upstreamReply.append(data) }
        return upstreamAnswered(opened, remote, failed: error != nil || done)
      }
      let next = { [self] in
        guard phase != .closed else { return }
        if error != nil { close(); return }
        if done {
          remoteEnded = true
          client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
          if clientEnded || phase != .piping { close() }
          return
        }
        readRemote(remote)
      }
      if let data, !data.isEmpty {
        client.send(content: data, completion: .contentProcessed { _ in next() })
      } else {
        next()
      }
    }
  }

  private func advance() {
    switch phase {
    case .request:
      guard let first = buffer.first else { return }
      if first == 0x05 { socksGreeting() } else { httpRequest() }
    case .socksRequest: socksRequest()
    case .hello(let opened): firstRecord(opened: opened)
    case .refusing:
      if !buffer.isEmpty { sendThenClose(PayGuard.accessDenied) }
    case .waiting, .dialing, .upstream, .piping, .closing, .closed: break
    }
  }

  private func httpRequest() {
    if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
      let head = buffer[..<end.upperBound]
      if let connect = PluginEgress.requestHead(Data(head)) {
        buffer.removeSubrange(..<end.upperBound)
        decide(EgressTarget(name: connect.host, port: connect.port))
      } else if let plain = Self.forwardHead(Data(head)) {
        buffer.removeSubrange(..<end.upperBound)
        forward = plain.head
        decide(EgressTarget(name: plain.host, port: plain.port))
      } else {
        sendThenClose(Data("HTTP/1.1 405 Method Not Allowed\r\n\r\n".utf8))
      }
    } else if buffer.count > 8_192 {
      sendThenClose(Data("HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n".utf8))
    }
  }

  /// `05 n methods…`: only "no authentication" (00) is offered back.
  private func socksGreeting() {
    framing = .socks
    let b = [UInt8](buffer)
    guard b.count >= 2, b.count >= 2 + Int(b[1]) else { return }
    guard b[2..<(2 + Int(b[1]))].contains(0x00) else { return sendThenClose(Data([0x05, 0xff])) }
    buffer.removeFirst(2 + Int(b[1]))
    client.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in })
    phase = .socksRequest
    advance()
  }

  /// `05 cmd 00 atyp address port`: CONNECT (01) to an IPv4 (01), name (03) or IPv6 (04) address.
  private func socksRequest() {
    let b = [UInt8](buffer)
    guard b.count >= 5 else { return }
    guard b[0] == 0x05, b[1] == 0x01 else { return sendThenClose(socksReply(0x07)) }
    let name: String
    let start: Int
    switch b[3] {
    case 0x01:
      start = 4 + 4
      guard b.count >= start + 2 else { return }
      name = b[4..<8].map(String.init).joined(separator: ".")
    case 0x03:
      start = 5 + Int(b[4])
      guard b.count >= start + 2 else { return }
      name = String(decoding: b[5..<start], as: UTF8.self)
    case 0x04:
      start = 4 + 16
      guard b.count >= start + 2 else { return }
      var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      _ = Array(b[4..<20]).withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &text, socklen_t(text.count)) }
      name = String(cString: text)
    default:
      return sendThenClose(socksReply(0x08))
    }
    let port = Int(b[start]) << 8 | Int(b[start + 1])
    buffer.removeFirst(start + 2)
    decide(EgressTarget(name: name, port: port))
  }

  private func decide(_ target: EgressTarget) {
    phase = .waiting
    decision = Task { [policy, queue] in
      let verdict = await policy.connect(target)
      queue.async { self.apply(verdict, to: target) }
    }
  }

  private func apply(_ verdict: EgressVerdict, to target: EgressTarget) {
    guard phase == .waiting else { return }
    switch verdict {
    case .refuse where forward != nil:
      let body = "Blocked: Serein asked the person on a card before this task reaches \(target.name), or they declined. Route: carry on with the rest; Serein sends a message when they answer.\n"
      sendThenClose(Data("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
    case .refuse:
      client.send(content: success, completion: .contentProcessed { _ in })
      phase = .refusing
      advance()
    case .unreachable:
      sendThenClose(framing == .socks ? socksReply(0x04) : Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
    case .dial(let address):
      phase = .dialing
      let chained = Self.upstream.flatMap { $0.skips(target.name) ? nil : $0 }
      let host = chained?.host ?? address
      let port = NWEndpoint.Port(rawValue: chained?.port ?? UInt16(clamping: target.port)) ?? 443
      let remote = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: port), using: .tcp)
      self.remote = remote
      remote.stateUpdateHandler = { [self] state in
        switch state {
        case .ready where phase == .dialing:
          guard chained != nil else { return opened(target.name, remote) }
          // The person's own proxy dials by the name, as their tools would.
          let authority = ConnectGate.isRawIP(address) && address.contains(":") ? "[\(address)]" : target.name
          phase = .upstream(opened: target.name)
          remote.send(content: Data("CONNECT \(authority):\(target.port) HTTP/1.1\r\nHost: \(authority):\(target.port)\r\n\r\n".utf8), completion: .contentProcessed { _ in })
          readRemote(remote)
        case .waiting, .failed:
          if phase == .dialing || phase == .upstream(opened: target.name) {
            failDial()
          } else {
            close()
          }
        default: break
        }
      }
      remote.start(queue: queue)
    }
  }

  /// The remote is open: a plain request goes out at once, a tunnel answers success and checks
  /// the client's first record.
  private func opened(_ name: String, _ remote: NWConnection) {
    if let forward {
      remote.send(content: forward + buffer, completion: .contentProcessed { _ in })
      buffer = Data()
      phase = .piping
      readRemote(remote)
      return
    }
    client.send(content: success, completion: .contentProcessed { _ in })
    phase = .hello(opened: name)
    readRemote(remote)
    advance()
  }

  private func upstreamAnswered(_ name: String, _ remote: NWConnection, failed: Bool) {
    guard let end = upstreamReply.range(of: Data("\r\n\r\n".utf8)) else {
      return failed || upstreamReply.count > 8_192 ? failDial() : readRemote(remote)
    }
    let status = String(decoding: upstreamReply[..<end.lowerBound], as: UTF8.self).split(separator: " ").dropFirst().first
    guard status == "200" else { return failDial() }
    upstreamReply = Data()
    opened(name, remote)
  }

  private func failDial() {
    sendThenClose(framing == .socks ? socksReply(0x05) : Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
  }

  /// `GET http://host[:port]/path HTTP/1.1`: host, port and the head in origin form, with the
  /// proxy's own headers dropped and `Connection: close`, so one connection carries one request
  /// to the host that was judged.
  static func forwardHead(_ head: Data) -> (host: String, port: Int, head: Data)? {
    guard let text = String(data: head, encoding: .utf8) else { return nil }
    var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    guard let first = lines.first else { return nil }
    let parts = first.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[1].lowercased().hasPrefix("http://"), let url = URL(string: String(parts[1])),
      let host = url.host, !host.isEmpty
    else { return nil }
    let port = url.port ?? 80
    guard (1..<65536).contains(port) else { return nil }
    var path = url.path.isEmpty ? "/" : url.path
    if let query = url.query { path += "?" + query }
    let dropped: Set<String> = ["proxy-connection", "proxy-authorization", "connection", "keep-alive"]
    lines = lines.dropFirst().filter { line in
      !dropped.contains(line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "")
    }
    if !lines.contains(where: { $0.lowercased().hasPrefix("host:") }) { lines.insert("Host: \(url.port == nil ? host : "\(host):\(port)")", at: 0) }
    let rewritten = (["\(parts[0]) \(path) \(parts[2])"] + lines + ["Connection: close", "", ""]).joined(separator: "\r\n")
    return (host, port, Data(rewritten.utf8))
  }

  /// The person's own proxy, read once from Serein's environment.
  private static let upstream = Upstream(ProcessInfo.processInfo.environment)

  /// The first client bytes in an open tunnel: a TLS ClientHello is checked, anything else passes.
  private func firstRecord(opened: String) {
    guard let first = buffer.first else { return }
    let reading = first == 0x16 ? TLSClientHello.read(buffer) : .notTLS
    if case .needMore = reading { return }
    guard policy.hello(reading, opened: opened) else { return sendThenClose(PayGuard.accessDenied) }
    remote?.send(content: buffer, completion: .contentProcessed { _ in })
    buffer = Data()
    phase = .piping
  }

  private var success: Data {
    framing == .socks
      ? socksReply(0x00) : Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)
  }

  private func socksReply(_ code: UInt8) -> Data { Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) }

  private func sendThenClose(_ data: Data) {
    phase = .closing
    client.send(content: data, completion: .contentProcessed { [self] _ in queue.async { self.close() } })
  }
}

/// The company or personal proxy Serein itself was started behind (`HTTPS_PROXY`, http only),
/// and the hosts its `NO_PROXY` keeps off it.
struct Upstream: Equatable, Sendable {
  let host: String
  let port: UInt16
  let bypass: [String]

  init?(_ environment: [String: String]) {
    guard let value = environment["HTTPS_PROXY"] ?? environment["https_proxy"], let url = URL(string: value),
      url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty
    else { return nil }
    self.host = host
    port = UInt16(clamping: url.port ?? 80)
    bypass = (environment["NO_PROXY"] ?? environment["no_proxy"] ?? "").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
  }

  func skips(_ name: String) -> Bool {
    let host = ConnectGate.normalizeHost(name)
    if ConnectGate.isLocal(host) { return true }
    return bypass.contains { entry in
      let suffix = entry.hasPrefix(".") ? String(entry.dropFirst()) : entry
      return entry == "*" || host == suffix || host.hasSuffix("." + suffix)
    }
  }
}
