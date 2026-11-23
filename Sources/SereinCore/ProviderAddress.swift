import Darwin
import Foundation

/// The one address rule for a provider connection: where a key may be sent.
/// - Never a link-local or cloud metadata address, wherever Serein runs.
/// - Plain http only to this Mac (loopback) or a private network (RFC 1918, IPv6 unique local); the
///   internet needs https. A name counts as private only by a local suffix and only when every
///   address it resolves to is private; a dotless name does not. With no key to carry (`keyless`),
///   plain http also reaches a carrier-grade NAT address (100.64.0.0/10, Tailscale) and any name
///   (dotless, *.ts.net) whose every address is private or carrier-grade NAT.
/// - A cloud computer (E2B or Daytona) never gets this Mac's or a non-public
///   address: there it would reach the cloud's own internals.
/// - No user, password, query or fragment. Redirects are refused by every request (EphemeralHTTP).
public enum ProviderAddress {
  public enum Place: Sendable { case thisMac, cloud }

  /// Why the address is refused, from the text alone (a literal IP, a local name); nil when it
  /// passes. `check` also resolves the name.
  public static func syntax(_ address: String, place: Place, keyless: Bool = false) -> String? {
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty
    else { return "Enter the full address, starting with https://." }
    guard scheme == "https" || scheme == "http" else { return "The address must start with https://." }
    guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
      return "Remove the user name, password, ? or # part from the address."
    }
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let literal = ComputerNetworkPolicy.ipv4(bare) != nil || ComputerNetworkPolicy.ipv6Groups(bare) != nil
    let here = isHere(address) || (keyless && (!literal || isCGNAT(host)))
    return verdict(scheme: scheme, addresses: [host], here: here, inside: isLocalName(host) || ComputerNetworkPolicy.blockedAddress(host), place: place)
  }

  /// `syntax`, then every address the name resolves to: a public-looking name that points at a
  /// metadata or private address is refused the same way, and a local name that points at a
  /// public address is not local. Blocks for the lookup; call it off the main thread.
  public static func check(_ address: String, place: Place, keyless: Bool = false) -> String? {
    checkFound(address, place: place, keyless: keyless).refused
  }
  /// `check`, and whether the name resolved: a name not found now is no verdict, not a refusal.
  public static func checkFound(_ address: String, place: Place, keyless: Bool = false) -> (refused: String?, found: Bool) {
    if let refused = syntax(address, place: place, keyless: keyless) { return (refused, true) }
    guard let url = URL(string: address), let host = url.host, let scheme = url.scheme?.lowercased() else { return ("Enter the full address.", true) }
    let addresses = resolve(host)
    guard !addresses.isEmpty else { return ("\(host) could not be found.", false) }
    let here = addresses.allSatisfy { isPrivate($0) || (keyless && isCGNAT($0)) }
    let inside = isLocalName(host.lowercased()) || addresses.contains { ComputerNetworkPolicy.blockedAddress($0) }
    return (verdict(scheme: scheme, addresses: addresses, here: here, inside: inside, place: place), true)
  }

  /// `scheme://host:port`, every loopback spelling (localhost, 127.x, ::1) as 127.0.0.1 and the
  /// scheme's port filled in, so two spellings of one server compare equal.
  public static func server(_ address: String) -> String? {
    guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), var host = url.host?.lowercased() else { return nil }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let loopback = host == "localhost" || host.hasSuffix(".localhost") || ComputerNetworkPolicy.ipv4(host)?.first == 127
      || ComputerNetworkPolicy.ipv6Groups(host) == [0, 0, 0, 0, 0, 0, 0, 1]
    return "\(scheme)://\(loopback ? "127.0.0.1" : host):\(url.port ?? (scheme == "https" ? 443 : 80))"
  }
  /// The same server (`server`) and the same path, a trailing slash aside.
  public static func same(_ a: String, _ b: String) -> Bool {
    func path(_ s: String) -> String { URL(string: s)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "" }
    guard let server = server(a) else { return false }
    return server == self.server(b) && path(a) == path(b)
  }

  /// True for an address on this Mac or a private network, from its text: a loopback or private
  /// literal, or a local name (localhost, .local, .lan, .home, .internal).
  public static func isHere(_ address: String) -> Bool {
    guard let host = URL(string: address)?.host?.lowercased() else { return false }
    return isLocalName(host) || isPrivate(host)
  }

  /// `here`: plain http may carry a key there. `inside`: not the public internet.
  private static func verdict(scheme: String, addresses: [String], here: Bool, inside: Bool, place: Place) -> String? {
    if addresses.contains(where: isMetadata) { return "Serein never sends a key to a link-local or cloud metadata address." }
    if place == .cloud, inside { return "A cloud computer cannot reach this Mac or a private network address." }
    if scheme == "http", !here { return "Use https:// for an address that is not this Mac or a private network." }
    return nil
  }

  /// Link-local ranges and the fixed metadata hosts of the big clouds, an IPv4 one carried in IPv6
  /// included (mapped, NAT64, 6to4: ComputerNetworkPolicy.embeddedV4).
  static func isMetadata(_ host: String) -> Bool {
    let text = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if ["metadata.google.internal", "metadata", "instance-data", "instance-data.ec2.internal"].contains(text) { return true }
    func metadataV4(_ v4: [UInt8]) -> Bool { (v4[0] == 169 && v4[1] == 254) || v4 == [100, 100, 100, 200] }
    if let v4 = ComputerNetworkPolicy.ipv4(text) { return metadataV4(v4) }
    guard let groups = ComputerNetworkPolicy.ipv6Groups(text.split(separator: "%").first.map(String.init) ?? text) else { return false }
    if groups[0] & 0xFFC0 == 0xFE80 { return true }
    if groups == [0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254] { return true }
    return ComputerNetworkPolicy.embeddedV4(groups).map(metadataV4) ?? false
  }

  /// Loopback, RFC 1918 or IPv6 unique local (fc00::/7), an IPv4 one carried in IPv6 included.
  static func isPrivate(_ ip: String) -> Bool {
    let text = ip.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    func privateV4(_ a: [UInt8]) -> Bool { a[0] == 127 || a[0] == 10 || (a[0] == 172 && a[1] & 0xF0 == 16) || (a[0] == 192 && a[1] == 168) }
    if let v4 = ComputerNetworkPolicy.ipv4(text) { return privateV4(v4) }
    guard let groups = ComputerNetworkPolicy.ipv6Groups(text.split(separator: "%").first.map(String.init) ?? text) else { return false }
    if groups == [0, 0, 0, 0, 0, 0, 0, 1] || groups[0] & 0xFE00 == 0xFC00 { return true }
    guard groups != [0, 0, 0, 0, 0, 0, 0, 0], let v4 = ComputerNetworkPolicy.embeddedV4(groups) else { return false }
    return privateV4(v4)
  }

  /// Carrier-grade NAT, 100.64.0.0/10 (Tailscale's addresses), an IPv4 one carried in IPv6 included.
  static func isCGNAT(_ ip: String) -> Bool {
    let text = ip.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let v4 = ComputerNetworkPolicy.ipv4(text)
      ?? ComputerNetworkPolicy.ipv6Groups(text.split(separator: "%").first.map(String.init) ?? text).flatMap(ComputerNetworkPolicy.embeddedV4)
    return v4.map { $0[0] == 100 && $0[1] & 0xC0 == 64 } ?? false
  }

  private static func isLocalName(_ host: String) -> Bool {
    host == "localhost" || [".localhost", ".local", ".lan", ".home", ".internal"].contains { host.hasSuffix($0) }
  }

  /// Numeric addresses for a name (a literal comes back as itself).
  static func resolve(_ host: String) -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), nil, &hints, &list) == 0, let first = list else {
      return []
    }
    defer { freeaddrinfo(first) }
    var addresses: [String] = []
    var next: UnsafeMutablePointer<addrinfo>? = first
    while let current = next {
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
        addresses.append(String(cString: buffer))
      }
      next = current.pointee.ai_next
    }
    return addresses
  }
}
