import Foundation
import Network

/// A loopback CONNECT proxy one sandboxed plugin exchange goes through, so the manifest's
/// network allow-list is enforced per host (sandbox-exec rules cannot name hosts — this can).
/// The plugin's sandbox denies all outbound network except this listener's port, and its
/// environment points HTTPS_PROXY/HTTP_PROXY here; well-behaved HTTP stacks send
/// `CONNECT host:443`, the proxy admits only allowed hosts, and relays the bytes — TLS stays
/// end to end, the proxy never sees plaintext. A stack that bypasses the proxy hits the deny
/// rule: enforcement fails closed.
public final class PluginEgress: @unchecked Sendable {
  public enum Failure: Error {
    case closed
  }
  private let listener: NWListener
  private let queue = DispatchQueue(label: "serein.plugin-egress")
  private let allowed: [String]
  private let ports: [Int]
  private let resolve: (String) -> [String]
  /// Set for a task shell's proxy (`init(policy:)`); nil for a plugin's allow-list.
  private let policy: (any EgressPolicy)?
  private var tunnels: [ObjectIdentifier: GuardedTunnel] = [:]
  public private(set) var port: UInt16 = 0
  private var stopped = false

  /// Starts the listener on a random loopback port for one plugin exchange.
  /// `resolve` defaults to a real lookup. Tests pass a fixed answer so nothing is dialed on the public internet.
  public convenience init(
    allowed: [String], ports: [Int] = ConnectGate.allowedPorts, resolve: ((String) -> [String])? = nil
  ) throws {
    try self.init(allowed: allowed, ports: ports, resolve: resolve ?? ConnectGate.systemResolve, policy: nil)
  }

  /// A task shell's proxy: HTTP CONNECT or SOCKS5 (the first byte decides), every port, and
  /// `policy` decides each tunnel before any success reply. A refusal answers success, then a TLS
  /// `access_denied` alert in place of the server's hello, which every client prints as
  /// "access denied". Bytes are relayed, never logged.
  public convenience init(policy: any EgressPolicy) throws {
    try self.init(allowed: [], ports: [], resolve: { _ in [] }, policy: policy)
  }

  private init(allowed: [String], ports: [Int], resolve: @escaping (String) -> [String], policy: (any EgressPolicy)?) throws {
    self.allowed = allowed.map { $0.lowercased() }
    self.ports = ports
    self.resolve = resolve
    self.policy = policy
    let parameters = NWParameters.tcp
    // Bind to loopback; port 0 picks an ephemeral port.
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        self?.port = UInt16(self?.listener.port?.rawValue ?? 0)
        ready.signal()
      }
      if case .failed = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    guard port != 0 else { throw Failure.closed }
  }

  public func stop() {
    queue.sync {
      stopped = true
      listener.cancel()
      let open = tunnels.values
      tunnels = [:]
      for tunnel in open { tunnel.close() }
    }
  }

  private func accept(_ connection: NWConnection) {
    queue.async { [weak self] in
      guard let self, !self.stopped else { connection.cancel(); return }
      connection.start(queue: self.queue)
      if let policy = self.policy {
        let tunnel = GuardedTunnel(connection, policy: policy, queue: self.queue)
        let id = ObjectIdentifier(tunnel)
        self.tunnels[id] = tunnel
        tunnel.onClose = { [weak self] in self?.tunnels[id] = nil }
        tunnel.start()
      } else {
        self.readRequest(connection, buffer: Data())
      }
    }
  }

  /// Reads until the CONNECT request head is complete, then decides.
  private func readRequest(_ connection: NWConnection, buffer: Data) {
    guard !stopped else { connection.cancel(); return }
    if let head = PluginEgress.requestHead(buffer) {
      respond(connection, head: head)
      return
    }
    guard buffer.count < 8_192 else { refuse(connection); return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, done, error in
      guard let self, !self.stopped else { connection.cancel(); return }
      if let data, !data.isEmpty {
        var next = buffer
        next.append(data)
        if PluginEgress.requestHead(next) != nil {
          self.respond(connection, head: PluginEgress.requestHead(next)!)
          return
        }
        self.readRequest(connection, buffer: next)
      } else if done || error != nil {
        self.refuse(connection)
      } else {
        self.readRequest(connection, buffer: buffer)
      }
    }
  }

  private func respond(_ connection: NWConnection, head: (host: String, port: Int)) {
    // Dial the checked address only. A name that resolves to loopback, link-local,
    // metadata, or any other local range is refused before a socket opens.
    guard let address = ConnectGate.admit(
      host: head.host, port: head.port, allowedHosts: allowed, ports: ports, resolve: resolve
    ) else {
      refuse(connection)
      return
    }
    relay(connection, host: address, port: UInt16(head.port))
  }

  private func refuse(_ connection: NWConnection) {
    connection.send(content: Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8), completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  /// Opens the real connection and pipes both ways until either side closes.
  private func relay(_ client: NWConnection, host: String, port: UInt16) {
    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443)
    let remote = NWConnection(to: endpoint, using: .tcp)
    remote.stateUpdateHandler = { [weak self, weak client] (state: NWConnection.State) in
      guard let client else { return }
      switch state {
      case .ready:
        client.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        self?.pipe(client, to: remote)
        self?.pipe(remote, to: client)
      case .failed, .cancelled:
        client.cancel()
      default: break
      }
    }
    remote.start(queue: queue)
  }

  private func pipe(_ from: NWConnection, to: NWConnection) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, _ in
      guard let self, !self.stopped else { from.cancel(); to.cancel(); return }
      if let data, !data.isEmpty {
        to.send(content: data, completion: .contentProcessed { _ in })
        self.pipe(from, to: to)
      } else if done {
        from.cancel()
        to.cancel()
      } else if from.state == .cancelled {
        from.cancel()
        to.cancel()
      } else {
        self.pipe(from, to: to)
      }
    }
  }

  /// The CONNECT head, once the request is complete: host and port.
  public static func requestHead(_ buffer: Data) -> (host: String, port: Int)? {
    guard let text = String(data: buffer, encoding: .utf8) else { return nil }
    guard let end = text.range(of: "\r\n\r\n") else { return nil }
    guard let line = text[..<end.lowerBound].split(separator: "\r\n").first else { return nil }
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else { return nil }
    let target = parts[1]
    guard let colon = target.lastIndex(of: ":") else { return nil }
    let host = String(target[..<colon])
    guard let port = Int(target[target.index(after: colon)...]), (1..<65536).contains(port) else {
      return nil
    }
    return (host, port)
  }
}

private extension sockaddr_in {
  init(loopback port: in_port_t) {
    self.init()
    sin_family = sa_family_t(AF_INET)
    sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    sin_port = port.bigEndian
  }
}
