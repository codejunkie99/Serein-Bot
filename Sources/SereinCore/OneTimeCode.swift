import CryptoKit
import Foundation

/// A site's verification-code setup (RFC 6238 time-based codes), from the setup key or the
/// `otpauth://totp/` link a site shows when an authenticator is turned on. The app keeps it only
/// in the Keychain; codes are computed here, on this Mac, as a pure function of the setup and time.
public struct OneTimeCode: Codable, Equatable, Sendable {
  public enum Algorithm: String, Codable, Sendable {
    case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
  }
  public var secret: Data
  public var algorithm: Algorithm
  public var digits: Int
  public var period: Int

  public init(secret: Data, algorithm: Algorithm = .sha1, digits: Int = 6, period: Int = 30) {
    self.secret = secret
    self.algorithm = algorithm
    self.digits = digits
    self.period = period
  }

  /// A pasted setup key (base32; spaces, dashes and padding ignored) or an `otpauth://totp/` link.
  /// Nil for anything else, including counter-based (`hotp`) links, other code lengths than 6 or 8,
  /// and keys shorter than 80 bits.
  public static func parse(_ text: String) -> OneTimeCode? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("otpauth:") else {
      return base32(trimmed).flatMap { valid(OneTimeCode(secret: $0)) }
    }
    guard let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "otpauth",
      parts.host?.lowercased() == "totp"
    else { return nil }
    let query = Dictionary(
      (parts.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    guard let secret = query["secret"].flatMap(base32) else { return nil }
    var code = OneTimeCode(secret: secret)
    if let name = query["algorithm"] {
      guard let algorithm = Algorithm(rawValue: name.uppercased()) else { return nil }
      code.algorithm = algorithm
    }
    if let digits = query["digits"] {
      guard let value = Int(digits) else { return nil }
      code.digits = value
    }
    if let period = query["period"] {
      guard let value = Int(period) else { return nil }
      code.period = value
    }
    return valid(code)
  }

  private static func valid(_ code: OneTimeCode) -> OneTimeCode? {
    [6, 8].contains(code.digits) && (1...300).contains(code.period) && code.secret.count >= 10 ? code : nil
  }

  /// RFC 4648 base32, case-insensitive.
  static func base32(_ text: String) -> Data? {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    let cleaned = text.uppercased().filter { !" -=\t\n".contains($0) }
    guard !cleaned.isEmpty else { return nil }
    var bytes: [UInt8] = []
    var buffer = 0
    var bits = 0
    for character in cleaned {
      guard let value = alphabet.firstIndex(of: character) else { return nil }
      buffer = (buffer << 5) | value
      bits += 5
      if bits >= 8 {
        bits -= 8
        bytes.append(UInt8((buffer >> bits) & 0xff))
      }
      buffer &= (1 << bits) - 1
    }
    return Data(bytes)
  }

  /// The code shown at `date` (RFC 6238: HMAC of the 30-second step count, dynamic truncation).
  public func code(at date: Date) -> String {
    var counter = UInt64(max(0, date.timeIntervalSince1970) / Double(period)).bigEndian
    let message = withUnsafeBytes(of: &counter) { Data($0) }
    let key = SymmetricKey(data: secret)
    let mac: [UInt8]
    switch algorithm {
    case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
    case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
    case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
    }
    let offset = Int(mac[mac.count - 1] & 0x0f)
    let binary =
      (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
      | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
    let value = String(binary % (digits == 8 ? 100_000_000 : 1_000_000))
    return String(repeating: "0", count: max(0, digits - value.count)) + value
  }

  /// When the code shown at `date` changes: the end of its period, from the exact time (a
  /// truncated second would show the old code up to a second late).
  public func changes(after date: Date) -> Date {
    let step = Double(period)
    return Date(timeIntervalSince1970: (floor(max(0, date.timeIntervalSince1970) / step) + 1) * step)
  }
}
