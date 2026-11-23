import CryptoKit
import Foundation

/// Certificate exceptions the person accepted. An exception covers one certificate on one host and
/// port, so a different (for example intercepting) certificate for the same host is not accepted.
public struct TrustExceptions: Equatable {
  private var keys = Set<String>()
  public init() {}

  /// Lowercase hex SHA-256 of a certificate's DER bytes.
  public static func fingerprint(_ der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
  }
  public static func key(host: String, port: Int, fingerprint: String) -> String {
    host.lowercased() + ":" + String(port) + "#" + fingerprint.lowercased()
  }
  public mutating func allow(host: String, port: Int, fingerprint: String) {
    guard !host.isEmpty, !fingerprint.isEmpty else { return }
    keys.insert(Self.key(host: host, port: port, fingerprint: fingerprint))
  }
  public func isAllowed(host: String, port: Int, fingerprint: String) -> Bool {
    !fingerprint.isEmpty && keys.contains(Self.key(host: host, port: port, fingerprint: fingerprint))
  }
  public var count: Int { keys.count }
}
