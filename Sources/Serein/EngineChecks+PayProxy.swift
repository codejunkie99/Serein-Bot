#if DEBUG
import Foundation
import Network
import SereinCore

/// The task shell's policy proxy with real curl: CONNECT and SOCKS5 both pass a named host,
/// a held refusal reads "access denied" with no upstream socket, a money server name inside
/// another tunnel is cut before a byte reaches the server, and a client that hangs up cancels
/// the wait. Upstream is a loopback HTTP server; nothing leaves this Mac.
extension AssistantCoreChecks {
  static func enginePayProxy(_ check: Check) throws {
    let upstream = try LoopbackHTTP()
    defer { upstream.stop() }
    let policy = StubPolicy()
    let proxy = try PluginEgress(policy: policy)
    defer { proxy.stop() }
    let http = ["-x", "http://127.0.0.1:\(proxy.port)"]
    let socks = ["--socks5-hostname", "127.0.0.1:\(proxy.port)"]
    let site = "pass.test:\(upstream.port)"

    var run = curl(http + ["-p", "http://\(site)/"])
    try check(run.status == 0 && run.out == "ok", "A CONNECT tunnel to a passing host relays both ways (\(run.status) \(run.err))")
    run = curl(socks + ["http://\(site)/"])
    try check(run.status == 0 && run.out == "ok", "A SOCKS5 tunnel to a passing host relays both ways (\(run.status) \(run.err))")

    let before = upstream.accepted
    for (framing, flags) in [("CONNECT", http), ("SOCKS5", socks)] {
      run = curl(flags + ["https://money.test:\(upstream.port)/"])
      try check(run.status == 35 && run.err.lowercased().contains("access denied"),
        "A held, refused \(framing) tunnel reads \"access denied\" (\(run.status) \(run.err))")
    }
    try check(upstream.accepted == before, "A refused tunnel never opens an upstream socket")

    let sent = upstream.bytes
    run = curl(http + ["--connect-to", "money.test:\(upstream.port):\(site)", "https://money.test:\(upstream.port)/"])
    try check(policy.saw.last == "pass.test", "A fronted request opens its tunnel under the harmless name")
    try check(run.status == 35 && run.err.lowercased().contains("access denied"),
      "A money server name inside a harmless tunnel is refused (\(run.status) \(run.err))")
    try check(upstream.bytes == sent, "The fronted hello never reaches the server")

    run = curl(http + ["https://typo.test/"])
    try check(run.status != 0 && !run.err.lowercased().contains("access denied"),
      "A name with no address fails as a gateway error, not a decline (\(run.status) \(run.err))")

    let slow = Process()
    slow.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    slow.arguments = http + ["-sS", "https://slow.test/"]
    slow.environment = ["PATH": "/usr/bin:/bin"]
    slow.standardError = FileHandle.nullDevice
    try slow.run()
    let asked = Date().addingTimeInterval(5)
    while !policy.saw.contains("slow.test"), Date() < asked { usleep(20_000) }
    slow.terminate()
    let gone = Date().addingTimeInterval(5)
    while !policy.cancelled, Date() < gone { usleep(20_000) }
    try check(policy.cancelled, "A client that hangs up mid-hold cancels the wait")
  }

  private static func curl(_ arguments: [String]) -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-sS", "--max-time", "10"] + arguments
    process.environment = ["PATH": "/usr/bin:/bin"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    guard (try? process.run()) != nil else { return (-1, "", "curl did not start") }
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let error = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self),
      String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// pass.test dials loopback; money.test is refused after a short hold; slow.test waits until
/// cancelled; typo.test has no address. money.test is the money name for the hello check.
private final class StubPolicy: EgressPolicy, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [String] = []
  private var wasCancelled = false
  var saw: [String] { lock.withLock { seen } }
  var cancelled: Bool { lock.withLock { wasCancelled } }

  func connect(_ target: EgressTarget) async -> EgressVerdict {
    lock.withLock { seen.append(target.name) }
    switch target.name {
    case "pass.test": return .dial("127.0.0.1")
    case "money.test":
      try? await Task.sleep(nanoseconds: 300_000_000)
      return .refuse
    case "slow.test":
      do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { lock.withLock { wasCancelled = true } }
      return .refuse
    default: return .unreachable
    }
  }

  func hello(_ reading: TLSClientHello.Reading, opened: String) -> Bool {
    PayGuard.helloAllowed(reading, opened: opened, book: PayGuard.Book(domains: ["money.test"]))
  }
}

/// Answers every request with "ok" and counts sockets and request bytes.
final class LoopbackHTTP: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "pay-proxy-upstream")
  private let lock = NSLock()
  private var sockets = 0
  private var received = 0
  private(set) var port: UInt16 = 0
  var accepted: Int { lock.withLock { sockets } }
  var bytes: Int { lock.withLock { received } }

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
      if case .failed = state { ready.signal() }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    port = listener.port?.rawValue ?? 0
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock { sockets += 1 }
    connection.start(queue: queue)
    read(connection)
  }

  func stop() { listener.cancel() }

  private func read(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
      guard let data, !data.isEmpty else { connection.cancel(); return }
      lock.withLock { received += data.count }
      guard data.range(of: Data("\r\n\r\n".utf8)) != nil else { return read(connection) }
      let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
#endif
