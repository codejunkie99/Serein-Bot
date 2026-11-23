import Foundation

/// Defense in depth at provider boundaries. It is deliberately conservative about URLs:
/// query strings and fragments never belong in automatically collected agent context.
/// Recognition cannot identify an arbitrary unlabelled secret; file/sensitive-page exclusion
/// remains the primary boundary, including for images (which are never text-redacted).
public enum AgentPrivacy {
  /// Keep descriptive text available when numeric values in a view could form card details.
  public static func hidingDigits(_ text: String) -> String {
    var result = ""
    var hiding = false
    for ch in text {
      if ch.isNumber {
        if !hiding { result += replacement }
        hiding = true
      } else {
        result.append(ch)
        hiding = false
      }
    }
    return result
  }

  public static let replacement = "[REDACTED]"
  /// Keys known by their prefix.
  public static let keyShapes =
    #"(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|[sr]k_(?:test|live)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{16})"#
  private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>\"']+"#, options: .caseInsensitive)
  private static let patterns: [NSRegularExpression] = [
    #"-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#,
    keyShapes,
    #"eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
    #"(?im)\b(?:authorization|proxy-authorization)\s*[:=]\s*(?:bearer|basic)\s+[^\r\n,;]+"#,
    #"(?im)\b(?:set-cookie|cookie)\s*:\s*[^\r\n]+"#,
    #"(?i)[\"']?\b(?:password|passwd|pwd|passphrase|(?:access|refresh|auth|session|id)[_-]?token|token|api[_-]?key|client[_-]?secret|secret[_-]?key|aws_secret_access_key)\b[\"']?\s*[:=]\s*(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\r\n,;&<>]+)"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  public static func url(_ raw: String) -> String {
    guard var c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
      c.host != nil else { return replacement }
    c.user = nil
    c.password = nil
    c.query = nil
    c.fragment = nil
    // Also remove recognizable credentials in paths (for example a JWT or an API key).
    var opaque = false
    c.path = c.path.split(separator: "/", omittingEmptySubsequences: false).map { part in
      let value = String(part)
      if opaque && !value.isEmpty { return replacement }
      if ["reset", "reset-password", "password-reset", "magic-link", "verify", "token", "auth"].contains(value.lowercased()) {
        opaque = true
      }
      if value.range(of: #"^[A-Za-z0-9_-]{24,}$"#, options: .regularExpression) != nil { return replacement }
      return redactSecrets(value)
    }.joined(separator: "/")
    return c.string ?? replacement
  }

  private static func redactSecrets(_ raw: String) -> String {
    patterns.reduce(raw) { text, pattern in
      pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
        withTemplate: replacement)
    }
  }

  public static func redact(_ raw: String) -> String {
    // Values Serein filled first, exactly (R9); card-shaped numbers that pass Luhn as the backstop.
    let raw = cardNumbers(FilledValues.shared.scrubAll(raw))
    var text = raw
    // Replace backwards so UTF-16 ranges stay valid, including emoji and international text.
    for match in urlPattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
      guard let range = Range(match.range, in: text) else { continue }
      text.replaceSubrange(range, with: url(String(text[range])))
    }
    return redactSecrets(text)
  }

  private static let digitRun = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])\d(?:[ \-./\u00A0]?\d){12,18}(?![A-Za-z0-9])"#)
  private static func cardNumbers(_ text: String) -> String {
    var out = text
    for match in digitRun.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: out), HandBack.containsCardNumber(String(out[range])) else { continue }
      out.replaceSubrange(range, with: replacement)
    }
    return out
  }

  /// At most `limit` characters. Interior text is unchanged. A secret the cut splits is
  /// dropped, so the kept side is not left as a prefix the recognizer no longer matches.
  public static func clipped(_ raw: String, limit: Int) -> String {
    guard limit > 0 else { return "" }
    guard raw.count > limit else { return raw }
    let end = raw.index(raw.startIndex, offsetBy: limit)
    return dropSplitSecret(String(raw[..<end]), discarded: String(raw[end...].prefix(8_192)))
  }

  /// Redacts the whole string, then limits it. A key that straddles `limit` is removed
  /// whole; cutting first would send only its prefix (`sk-proj-ABCDEFG`, `sk-proj-A`).
  public static func redact(_ raw: String, limit: Int) -> String {
    clipped(redact(raw), limit: limit)
  }

  /// `head` is the kept prefix and `discarded` is what the cut removed. If a credential
  /// starts in `head` and continues into `discarded`, drop that secret-shaped prefix.
  private static func dropSplitSecret(_ head: String, discarded: String) -> String {
    guard !head.isEmpty, !discarded.isEmpty else { return head }
    let probe = head + discarded
    let boundary = (head as NSString).length
    let ns = probe as NSString
    let span = NSRange(location: 0, length: ns.length)
    var cut: Int?
    for pattern in patterns {
      for match in pattern.matches(in: probe, range: span) {
        let range = match.range
        if range.location < boundary && range.location + range.length > boundary {
          cut = min(cut ?? range.location, range.location)
        }
      }
    }
    guard let cut else { return head }
    if cut == 0 { return "" }
    guard let keep = Range(NSRange(location: 0, length: cut), in: head) else { return head }
    return String(head[keep])
  }

  /// Cleans every textual leaf of an MCP reply, including labels, frame URLs and error details.
  /// Image bytes are opaque; callers must refuse pictures of sensitive pages before this point.
  public static func sanitize(_ value: Any, preservingImageData: Bool = false) -> Any {
    if let text = value as? String { return redact(text) }
    if let array = value as? [Any] { return array.map { sanitize($0, preservingImageData: preservingImageData) } }
    if let object = value as? [String: Any] {
      return Dictionary(uniqueKeysWithValues: object.map { key, value in
        if preservingImageData && object["type"] as? String == "image" && key == "data" { return (key, value) }
        let name = key.lowercased().filter { $0.isLetter || $0.isNumber }
        let secret = ["password", "passwd", "pwd", "passphrase", "token", "accesstoken", "refreshtoken",
          "idtoken", "authtoken", "sessiontoken", "apikey", "clientsecret", "secretkey",
          "authorization", "cookie", "setcookie"].contains(name)
        return (key, secret ? replacement as Any : sanitize(value, preservingImageData: preservingImageData))
      })
    }
    return value
  }
}
