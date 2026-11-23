import Darwin
import Foundation

/// Connect-time check for a plugin's outbound proxy.
/// A name is resolved twice. The caller dials only an address both lookups returned.
/// A raw address, a local answer, or a port outside the allow-list never connects.
/// Mac run not verified.
public enum ConnectGate {
  /// HTTPS only. An empty list refuses every port.
  public static let allowedPorts: [Int] = [443]

  /// True when `host` is an address literal rather than a DNS name.
  public static func isRawIP(_ host: String) -> Bool {
    normalizeIP(normalizeHost(host)) != nil
  }

  /// Loopback, private, link-local, metadata, reserved, 6to4, multicast, and the NAT64 prefix.
  public static func isLocal(_ host: String) -> Bool {
    let name = normalizeHost(host)
    if name == "localhost" || name.hasSuffix(".localhost") { return true }
    guard let ip = normalizeIP(name) else { return false }
    switch ip {
    case .v4(let octets): return ipv4IsLocal(octets)
    case .v6(let hextets): return ipv6IsLocal(hextets)
    }
  }

  /// The address to dial, or nil when the connection is refused.
  /// Removing the local-address check dials a name that resolved to loopback.
  public static func admit(
    host: String, port: Int, allowedHosts: [String], ports: [Int] = allowedPorts,
    resolve: (String) -> [String]
  ) -> String? {
    let name = normalizeHost(host)
    guard !name.isEmpty, ports.contains(port) else { return nil }
    guard allowedHosts.contains(where: { PluginSession.hostMatches(name, $0) }) else { return nil }
    // The manifest lists names. A raw address is refused here as well.
    if isRawIP(name) || name == "localhost" || name.hasSuffix(".localhost") { return nil }
    let first = resolve(name)
    let second = resolve(name)
    if first.isEmpty || second.isEmpty { return nil }
    // Removing this check dials a name that resolved to loopback.
    if first.contains(where: isLocal) || second.contains(where: isLocal) { return nil }
    guard let address = first.first, second.contains(address) else { return nil }
    return address
  }

  /// Dials only when `admit` returns an address. The dial closure receives that address, never the name.
  @discardableResult
  public static func dialIfAdmitted(
    host: String, port: Int, allowedHosts: [String], ports: [Int] = allowedPorts,
    resolve: (String) -> [String], dial: (String) -> Void
  ) -> String? {
    guard let address = admit(
      host: host, port: port, allowedHosts: allowedHosts, ports: ports, resolve: resolve
    ) else { return nil }
    dial(address)
    return address
  }

  /// One lookup. A failure returns no addresses, and `admit` refuses that.
  public static func systemResolve(_ host: String) -> [String] {
    let name = normalizeHost(host)
    guard !name.isEmpty else { return [] }
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(name, nil, &hints, &info) == 0, let info else { return [] }
    defer { freeaddrinfo(info) }
    var out: [String] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = info
    while let node = cursor {
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(
        node.pointee.ai_addr, node.pointee.ai_addrlen,
        &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
      ) == 0 {
        let text = String(cString: buffer)
        if !text.isEmpty { out.append(text) }
      }
      cursor = node.pointee.ai_next
    }
    return out
  }

  public static func normalizeHost(_ host: String) -> String {
    var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if name.hasPrefix("[") { name.removeFirst() }
    if name.hasSuffix("]") { name.removeLast() }
    while name.hasSuffix(".") { name.removeLast() }
    return name
  }

  private enum IP {
    case v4([Int])
    case v6([Int])
  }

  private static func normalizeIP(_ host: String) -> IP? {
    if let octets = parseIpv4(host) { return .v4(octets) }
    if let hextets = parseIpv6(host) { return .v6(hextets) }
    return nil
  }

  /// 127/8, 0/8, 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, 224/4, 240/4, and 6to4 anycast.
  private static func ipv4IsLocal(_ octets: [Int]) -> Bool {
    guard octets.count == 4 else { return true }
    let a = octets[0]
    let b = octets[1]
    if a == 127 || a == 0 || a == 10 { return true }
    if a == 172 && (b & 0xf0) == 16 { return true }
    if a == 192 && b == 168 { return true }
    if a == 100 && (b & 0xc0) == 64 { return true }
    if a == 169 && b == 254 { return true }
    if a == 192 && b == 88 && octets[2] == 99 { return true }
    if (a & 0xf0) == 0xe0 { return true }
    return a >= 240
  }

  private static func ipv6IsLocal(_ hextets: [Int]) -> Bool {
    guard hextets.count == 8 else { return true }
    if nat64(hextets) || linkLocal(hextets) || uniqueLocal(hextets) { return true }
    if hextets[0] == 0x2002 { return true }
    if (hextets[0] & 0xff00) == 0xff00 { return true }
    if hextets[4] == 0xffff {
      let high = hextets[6]
      let low = hextets[7]
      if ipv4IsLocal([(high >> 8) & 0xff, high & 0xff, (low >> 8) & 0xff, low & 0xff]) { return true }
    }
    if let embedded = embeddedIpv4(hextets) ?? compatibleIpv4(hextets) {
      return ipv4IsLocal(embedded)
    }
    let unspecified = hextets.allSatisfy { $0 == 0 }
    let loopback = hextets.enumerated().allSatisfy { $0.offset == 7 ? $0.element == 1 : $0.element == 0 }
    return unspecified || loopback
  }

  /// 64:ff9b::/96. The whole prefix is local, including a public embedded address.
  private static func nat64(_ hextets: [Int]) -> Bool {
    hextets[0] == 0x64 && hextets[1] == 0xff9b
      && hextets[2] == 0 && hextets[3] == 0 && hextets[4] == 0 && hextets[5] == 0
  }

  /// fe80::/10.
  private static func linkLocal(_ hextets: [Int]) -> Bool {
    (hextets[0] & 0xffc0) == 0xfe80
  }

  /// fc00::/7. fec0::/10 is outside this block.
  private static func uniqueLocal(_ hextets: [Int]) -> Bool {
    (hextets[0] & 0xfe00) == 0xfc00
  }

  private static func embeddedIpv4(_ hextets: [Int]) -> [Int]? {
    let mapped = hextets.prefix(5).allSatisfy { $0 == 0 } && hextets[5] == 0xffff
    guard mapped else { return nil }
    return octets(high: hextets[6], low: hextets[7])
  }

  private static func compatibleIpv4(_ hextets: [Int]) -> [Int]? {
    guard hextets.prefix(6).allSatisfy({ $0 == 0 }) else { return nil }
    return octets(high: hextets[6], low: hextets[7])
  }

  private static func octets(high: Int, low: Int) -> [Int] {
    [(high >> 8) & 0xff, high & 0xff, (low >> 8) & 0xff, low & 0xff]
  }

  private static func parseIpv4(_ host: String) -> [Int]? {
    guard !host.contains(":") else { return nil }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard (1...4).contains(parts.count) else { return nil }
    var numbers: [UInt64] = []
    for part in parts {
      guard let value = parseIpv4Part(part) else { return nil }
      numbers.append(value)
    }
    for index in 0..<(numbers.count - 1) where numbers[index] > 255 { return nil }
    let last = numbers[numbers.count - 1]
    let restCount = 5 - numbers.count
    let lastLimit = UInt64(1) << (8 * restCount)
    guard last < lastLimit else { return nil }
    var bytes: [Int] = numbers.dropLast().map { Int($0) }
    var rest = last
    var restBytes: [Int] = []
    for _ in 0..<restCount {
      restBytes.append(Int(rest & 0xff))
      rest >>= 8
    }
    bytes.append(contentsOf: restBytes.reversed())
    guard bytes.count == 4 else { return nil }
    return bytes
  }

  private static func parseIpv4Part(_ part: String) -> UInt64? {
    var radix = 10
    var digits = part
    if digits.count >= 2, digits.hasPrefix("0x") {
      radix = 16
      digits = String(digits.dropFirst(2))
      guard !digits.isEmpty, digits.allSatisfy(isHex) else { return nil }
    } else if digits.count >= 2, digits.hasPrefix("0") {
      radix = 8
      digits = String(digits.dropFirst())
      guard !digits.isEmpty, digits.allSatisfy({ ("0"..."7").contains(String($0)) }) else { return nil }
    } else {
      guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
    }
    return UInt64(digits, radix: radix)
  }

  private static func parseIpv6(_ host: String) -> [Int]? {
    guard host.contains(":"), !host.contains("%") else { return nil }
    let halves = host.components(separatedBy: "::")
    guard halves.count <= 2 else { return nil }
    guard let left = parseIpv6Side(halves[0]) else { return nil }
    if halves.count == 1 { return left.count == 8 ? left : nil }
    guard let right = parseIpv6Side(halves[1]) else { return nil }
    let missing = 8 - left.count - right.count
    guard missing >= 1 else { return nil }
    return left + Array(repeating: 0, count: missing) + right
  }

  private static func parseIpv6Side(_ side: String) -> [Int]? {
    if side.isEmpty { return [] }
    let pieces = side.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    var groups: [Int] = []
    for (index, piece) in pieces.enumerated() {
      if piece.contains(".") {
        guard index == pieces.count - 1, let ipv4 = parseIpv4(piece) else { return nil }
        groups.append((ipv4[0] << 8) | ipv4[1])
        groups.append((ipv4[2] << 8) | ipv4[3])
        continue
      }
      guard (1...4).contains(piece.count), piece.allSatisfy(isHex), let value = Int(piece, radix: 16), value <= 0xffff else {
        return nil
      }
      groups.append(value)
    }
    return groups
  }

  private static func isDigit(_ character: Character) -> Bool {
    character.isASCII && character.isNumber
  }

  private static func isHex(_ character: Character) -> Bool {
    character.isASCII && character.isHexDigit
  }
}
