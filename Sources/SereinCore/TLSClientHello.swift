#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// The site name in the first message of a TLS connection (the ClientHello's server name, SNI).
/// Serein's computer proxy reads it from each tunnel before it connects, so a connection that the
/// site rules allowed for one host cannot ask that host's servers for another site. Pure: it
/// parses bytes and touches no socket.
public enum TLSClientHello {
  /// The longest first record Serein reads: a TLS record holds at most 16 KiB, plus its 5-byte header.
  public static let maxRecord = 5 + 16_384
  /// The Encrypted Client Hello extension (`encrypted_client_hello`): it carries a second, hidden
  /// ClientHello whose name the proxy cannot read, so a ClientHello with it is refused.
  public static let encryptedHelloKind = 0xfe0d

  public enum Reading: Equatable, Sendable {
    /// More bytes are needed: read until `count` bytes are there.
    case needMore(count: Int)
    /// The first record does not start a TLS handshake.
    case notTLS
    /// A ClientHello without a server name.
    case noName
    /// The server name, lowercased, without a closing dot.
    case name(String)
    /// A ClientHello with Encrypted Client Hello: the site it is for is hidden.
    case encryptedHello
  }

  /// Reads the first record in `bytes` (the start of a tunnel). Call it again with more bytes
  /// while it answers `needMore`.
  public static func read(_ bytes: Data) -> Reading {
    let b = [UInt8](bytes.prefix(maxRecord))
    guard b.count >= 5 else { return .needMore(count: 5) }
    // A handshake record (22) of TLS 1.0 or later (3.x).
    guard b[0] == 0x16, b[1] == 0x03 else { return .notTLS }
    let length = Int(b[3]) << 8 | Int(b[4])
    guard length > 0, length <= 16_384 else { return .notTLS }
    let total = 5 + length
    guard b.count >= total else { return .needMore(count: total) }
    return parse(Array(b[5..<total]))
  }

  /// The ClientHello in one handshake record's body.
  static func parse(_ h: [UInt8]) -> Reading {
    var cursor = Cursor(h)
    guard let type = cursor.byte(), type == 0x01, let bodyLength = cursor.number(3) else { return .notTLS }
    // A ClientHello longer than this record is not supported; it is refused as not TLS.
    guard bodyLength <= cursor.left else { return .notTLS }
    guard cursor.skip(2 + 32),  // version, random
      let session = cursor.number(1), cursor.skip(session),
      let suites = cursor.number(2), cursor.skip(suites),
      let compression = cursor.number(1), cursor.skip(compression)
    else { return .notTLS }
    guard cursor.left > 0 else { return .noName }
    guard let extensionsLength = cursor.number(2), extensionsLength <= cursor.left else { return .notTLS }
    var extensions = Cursor(Array(cursor.take(extensionsLength)))
    // Every extension is read: a hidden ClientHello after the name must not pass.
    var found: Reading?
    while extensions.left >= 4 {
      guard let kind = extensions.number(2), let size = extensions.number(2), size <= extensions.left else {
        return .notTLS
      }
      let data = extensions.take(size)
      if kind == encryptedHelloKind { return .encryptedHello }
      if kind == 0 {
        // One server_name only: a second one is not a valid ClientHello.
        guard found == nil else { return .notTLS }
        found = serverName(Array(data))
      }
    }
    return found ?? .noName
  }

  /// The host name in a server_name extension's data.
  static func serverName(_ data: [UInt8]) -> Reading {
    var cursor = Cursor(data)
    guard let listLength = cursor.number(2), listLength <= cursor.left else { return .notTLS }
    var list = Cursor(Array(cursor.take(listLength)))
    while list.left >= 3 {
      guard let nameType = list.byte(), let size = list.number(2), size <= list.left else { return .notTLS }
      let name = list.take(size)
      guard nameType == 0 else { continue }
      guard size > 0, size <= 253, name.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return .notTLS }
      var text = String(decoding: name, as: UTF8.self).lowercased()
      if text.hasSuffix(".") { text.removeLast() }
      return text.isEmpty ? .notTLS : .name(text)
    }
    return .noName
  }

  /// Why a tunnel to `host` must close after its first record, or nil when it may go on. A name
  /// must match the host that the rules checked. No name is allowed only for a host that is an
  /// IP address. A tunnel that is not TLS, or that hides its site (Encrypted Client Hello), is
  /// refused.
  public static func refusal(_ reading: Reading, host: String) -> String? {
    var wanted = host.lowercased()
    if wanted.hasSuffix(".") { wanted.removeLast() }
    switch reading {
    case .needMore:
      return "The connection did not start in time."
    case .notTLS:
      return "Serein's computer opens only encrypted connections through a tunnel."
    case .noName:
      return isAddress(wanted) ? nil : "The connection did not say which site it is for."
    case .name(let name):
      return name == wanted ? nil : "The connection asked \(wanted) for another site (\(name))."
    case .encryptedHello:
      return "The connection hid which site it is for."
    }
  }

  /// True for an IPv4 or IPv6 literal (with or without brackets).
  static func isAddress(_ host: String) -> Bool {
    var text = host
    if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
    var v4 = in_addr()
    var v6 = in6_addr()
    return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
  }

  /// Reads big-endian numbers and byte runs, never past the end.
  struct Cursor {
    let bytes: [UInt8]
    var at = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var left: Int { bytes.count - at }
    mutating func byte() -> UInt8? {
      guard left >= 1 else { return nil }
      at += 1
      return bytes[at - 1]
    }
    mutating func number(_ width: Int) -> Int? {
      guard left >= width else { return nil }
      var value = 0
      for _ in 0..<width {
        value = value << 8 | Int(bytes[at])
        at += 1
      }
      return value
    }
    mutating func skip(_ count: Int) -> Bool {
      guard count >= 0, left >= count else { return false }
      at += count
      return true
    }
    mutating func take(_ count: Int) -> ArraySlice<UInt8> {
      let end = min(at + max(count, 0), bytes.count)
      let slice = bytes[at..<end]
      at = end
      return slice
    }
  }
}
