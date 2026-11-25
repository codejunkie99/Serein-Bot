#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// The stuck watch's socket reading: loopback peers (a local proxy, an MCP bridge) never count
/// as the CLI talking to its model, and a turn with a process gets a reading instead of nil.
extension AssistantCoreChecks {
  static func stuckLoopback(_ check: Check) throws {
    for host in ["127.0.0.1", "127.8.9.10", "::1", "[::1]", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1", "::ffff:7f00:1", " LocalHost "] {
      try check(HarnessStuck.isLoopbackAddress(host), "\(host) counts as loopback")
    }
    for host in ["8.8.8.8", "128.0.0.1", "10.0.0.127", "::2", "::ffff:8.8.8.8", "2606:4700::1111", "api.anthropic.com", ""] {
      try check(!HarnessStuck.isLoopbackAddress(host), "\(host) is not loopback")
    }
    try check(HarnessStuck.modelConnections(remotes: ["127.0.0.1", "::ffff:127.0.0.1", "160.79.104.10", "::1", "2606:4700::1111"]) == 2,
      "Only the two non-loopback remotes count as model connections")
    try check(HarnessStuck.modelConnections(remotes: []) == 0, "No remotes is zero model connections")

    let me = getpid()
    try check(HarnessStuck.modelConnections(pids: []) == nil, "Sampling no process is unknown, not zero")
    try check(HarnessStuck.modelConnections(pids: [99_999_999]) == nil, "Sampling a process that does not exist is unknown, not zero")
    try check(Engines.openTCP(group: nil) == nil, "A turn with no process has no socket reading")

    let before = HarnessStuck.modelConnections(pids: [me])
    try check(before != nil, "The sampler reads this process's sockets")
    guard let local = connectedPair("127.0.0.1") else { return try check(false, "Opened a loopback TCP connection") }
    defer { local.forEach { close($0) } }
    try check(HarnessStuck.modelConnections(pids: [me]) == before, "An open loopback TCP connection is not counted")
    try check(Engines.openTCP(group: me) == before, "The tick reading for a known pid is not nil and skips loopback")

    // A peer on this Mac's own network address is not loopback, so it shows the reading can see a count.
    guard let address = nonLoopbackIPv4() else { return print("SKIP: no non-loopback IPv4 address on this Mac") }
    guard let lan = connectedPair(address) else { return try check(false, "Opened a TCP connection to \(address)") }
    defer { lan.forEach { close($0) } }
    try check(HarnessStuck.modelConnections(pids: [me]) == before.map { $0 + 2 }, "Both ends of a connection to \(address) count")
    try check(Engines.openTCP(group: me) == before.map { $0 + 2 }, "The tick reading counts the connection to \(address)")
  }

  /// A listener, a connected client and the accepted end, all in this process.
  private static func connectedPair(_ host: String) -> [Int32]? {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    func call(_ body: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32) -> Int32 {
      var length = size
      return withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, &length) } }
    }
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { return nil }
    guard call({ p, _ in bind(listener, p, size) }) == 0, listen(listener, 1) == 0, call({ getsockname(listener, $0, $1) }) == 0 else {
      close(listener)
      return nil
    }
    let client = socket(AF_INET, SOCK_STREAM, 0)
    guard client >= 0, call({ p, _ in Darwin.connect(client, p, size) }) == 0 else {
      close(listener)
      if client >= 0 { close(client) }
      return nil
    }
    let accepted = accept(listener, nil, nil)
    guard accepted >= 0 else {
      close(listener)
      close(client)
      return nil
    }
    return [listener, client, accepted]
  }

  private static func nonLoopbackIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var item = list
    while let entry = item?.pointee {
      defer { item = entry.ifa_next }
      guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
        entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
      else { continue }
      var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      let found = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet_ntop(AF_INET, &$0.pointee.sin_addr, &text, socklen_t(text.count)) }
      if found != nil { return String(cString: text) }
    }
    return nil
  }
}
#endif
