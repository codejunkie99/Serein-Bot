import Foundation

/// Parsed `passwordrules` attribute (the WHATWG/Apple password-rules syntax), for example
/// `minlength: 12; required: lower; required: upper; required: digit; allowed: [-_.]; max-consecutive: 2`.
/// Unknown properties and malformed values are ignored, as the format recommends.
public struct PasswordRules: Equatable, Sendable {
  /// Each `required:` property is one set; a password needs at least one character from each.
  public var required: [Set<Character>] = []
  /// Union of every `allowed:` property.
  public var allowed: Set<Character> = []
  public var minLength: Int?
  public var maxLength: Int?
  public var maxConsecutive: Int?

  public init() {}

  public var isEmpty: Bool {
    required.isEmpty && allowed.isEmpty && minLength == nil && maxLength == nil
      && maxConsecutive == nil
  }

  public static let upper = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  public static let lower = Set("abcdefghijklmnopqrstuvwxyz")
  public static let digit = Set("0123456789")
  /// The format's `special` class. Space is left out: generated passwords never contain it.
  public static let special = Set("-~!@#$%^&*_+=`|(){}[]:;\"'<>,.?")
  /// Printable ASCII without space.
  public static let asciiPrintable = Set((0x21...0x7E).map { Character(UnicodeScalar($0)) })

  public static func parse(_ text: String) -> PasswordRules {
    var rules = PasswordRules()
    for property in splitProperties(text) {
      guard let colon = property.firstIndex(of: ":") else { continue }
      let name = property[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(property[property.index(after: colon)...])
      switch name {
      case "required":
        let set = classes(value)
        if !set.isEmpty { rules.required.append(set) }
      case "allowed":
        rules.allowed.formUnion(classes(value))
      case "minlength":
        if let n = Int(value.trimmingCharacters(in: .whitespaces)), n >= 0 {
          rules.minLength = max(rules.minLength ?? 0, n)
        }
      case "maxlength":
        if let n = Int(value.trimmingCharacters(in: .whitespaces)), n > 0 {
          rules.maxLength = min(rules.maxLength ?? .max, n)
        }
      case "max-consecutive":
        if let n = Int(value.trimmingCharacters(in: .whitespaces)), n > 0 {
          rules.maxConsecutive = min(rules.maxConsecutive ?? .max, n)
        }
      default: continue
      }
    }
    return rules
  }

  /// Splits on `;` outside of `[...]` custom classes, so `[;]` stays intact.
  private static func splitProperties(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inClass = false
    for ch in text.prefix(2_000) {
      if inClass {
        current.append(ch)
        if ch == "]" { inClass = false }
      } else if ch == "[" {
        inClass = true
        current.append(ch)
      } else if ch == ";" {
        parts.append(current)
        current = ""
      } else {
        current.append(ch)
      }
    }
    parts.append(current)
    return parts
  }

  /// Parses a comma-separated class list such as `upper, digit, [-_]`.
  static func classes(_ value: String) -> Set<Character> {
    var result = Set<Character>()
    var chars = Array(value)
    var i = 0
    while i < chars.count {
      let ch = chars[i]
      if ch == "[" {
        // A custom class runs to the next `]`; a `]` placed first is literal.
        var j = i + 1
        var custom = Set<Character>()
        if j < chars.count, chars[j] == "]" {
          custom.insert("]")
          j += 1
        }
        while j < chars.count, chars[j] != "]" {
          if let ascii = chars[j].asciiValue, ascii >= 0x21, ascii <= 0x7E { custom.insert(chars[j]) }
          j += 1
        }
        if j < chars.count { result.formUnion(custom) }
        i = j + 1
      } else if ch.isLetter {
        var j = i
        var word = ""
        while j < chars.count, chars[j].isLetter || chars[j] == "-" {
          word.append(chars[j])
          j += 1
        }
        switch word.lowercased() {
        case "upper": result.formUnion(upper)
        case "lower": result.formUnion(lower)
        case "digit": result.formUnion(digit)
        case "special": result.formUnion(special)
        case "ascii-printable", "unicode": result.formUnion(asciiPrintable)
        default: break
        }
        i = j
      } else {
        i += 1
      }
    }
    chars.removeAll()
    return result
  }
}

public enum PasswordGenerator {
  public static let defaultLength = 20
  /// Longest password Serein generates. Page-supplied lengths above this are ignored, so a
  /// page cannot make the generator build a huge string on the main thread.
  public static let maxLength = 128
  /// Shortest password Serein generates, even when a field claims to allow less. Short fields
  /// such as six-digit PINs are honoured.
  public static let minLength = 4

  /// A page-supplied length limit, or nil when it is missing, zero or out of range.
  public static func sane(_ value: Int?) -> Int? {
    guard let value, value > 0, value <= maxLength else { return nil }
    return value
  }

  /// A strong password that satisfies `rules` and the field's own `minlength`/`maxlength`.
  /// With no rules it uses the familiar `abcdef-ghijkl-mnopqr` shape (mixed case and a digit).
  public static func generate<R: RandomNumberGenerator>(
    rules: PasswordRules = PasswordRules(), fieldMinLength: Int? = nil,
    fieldMaxLength: Int? = nil, using rng: inout R
  ) -> String {
    // Out-of-range minimums are ignored; maximums are clamped into minLength...maxLength.
    let lower = max(sane(rules.minLength) ?? 0, sane(fieldMinLength) ?? 0)
    var upper = min(
      rules.maxLength.map { min(max($0, minLength), maxLength) } ?? maxLength,
      fieldMaxLength.flatMap { $0 > 0 ? min(max($0, minLength), maxLength) : nil } ?? maxLength)
    if upper < lower { upper = lower }
    var length = min(max(defaultLength, lower), upper)
    if rules.isEmpty, length == defaultLength {
      return grouped(using: &rng)
    }
    var pool = rules.allowed
    for set in rules.required { pool.formUnion(set) }
    if pool.isEmpty {
      pool = PasswordRules.lower.union(PasswordRules.upper).union(PasswordRules.digit)
    }
    let required =
      rules.required.isEmpty && rules.allowed.isEmpty
      ? [PasswordRules.lower, PasswordRules.upper, PasswordRules.digit] : rules.required
    length = max(length, min(required.count, upper))
    let poolArray = pool.sorted()
    var best = ""
    for _ in 0..<200 {
      var chars: [Character] = required.prefix(length).map { $0.sorted().randomElement(using: &rng)! }
      while chars.count < length { chars.append(poolArray.randomElement(using: &rng)!) }
      chars.shuffle(using: &rng)
      let candidate = String(chars)
      best = candidate
      if satisfies(candidate, rules: rules, required: required) { return candidate }
    }
    return best
  }

  public static func generate(
    rules: PasswordRules = PasswordRules(), fieldMinLength: Int? = nil, fieldMaxLength: Int? = nil
  ) -> String {
    var rng = SystemRandomNumberGenerator()
    return generate(
      rules: rules, fieldMinLength: fieldMinLength, fieldMaxLength: fieldMaxLength, using: &rng)
  }

  public static func satisfies(_ value: String, rules: PasswordRules) -> Bool {
    satisfies(value, rules: rules, required: rules.required)
  }

  private static func satisfies(
    _ value: String, rules: PasswordRules, required: [Set<Character>]
  ) -> Bool {
    for set in required where !value.contains(where: set.contains) { return false }
    if let limit = rules.maxConsecutive {
      var run = 0
      var previous: Character?
      for ch in value {
        run = ch == previous ? run + 1 : 1
        previous = ch
        if run > limit { return false }
      }
    }
    return true
  }

  /// Three groups of six letters and digits joined by hyphens, with at least one capital and
  /// one digit, for example `kepTiw-vu7xod-bamqes`.
  private static func grouped<R: RandomNumberGenerator>(using rng: inout R) -> String {
    let letters = Array("abcdefghijkmnopqrstuvwxyz")
    let digits = Array("23456789")
    var chars = (0..<18).map { _ in letters.randomElement(using: &rng)! }
    let digitAt = Int.random(in: 0..<18, using: &rng)
    var upperAt = Int.random(in: 0..<17, using: &rng)
    if upperAt >= digitAt { upperAt += 1 }
    chars[digitAt] = digits.randomElement(using: &rng)!
    chars[upperAt] = Character(chars[upperAt].uppercased())
    let text = String(chars)
    return [0, 6, 12].map {
      String(text.dropFirst($0).prefix(6))
    }.joined(separator: "-")
  }
}

/// The exact origin a saved password belongs to. Only HTTPS sites, plus plain HTTP on this Mac
/// (localhost, 127.0.0.1, ::1), are eligible. Subdomains are different origins.
public enum CredentialOrigin {
  public static func normalize(_ value: String?) -> String? {
    guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return make(scheme: url.scheme, host: url.host, port: url.port ?? 0)
  }

  /// Builds an origin from parts; port 0 means the scheme's default.
  public static func make(scheme: String?, host: String?, port: Int) -> String? {
    guard let scheme = scheme?.lowercased(), var host = host?.lowercased(), !host.isEmpty else {
      return nil
    }
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
    guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
    let defaultPort = scheme == "https" ? 443 : 80
    let shownHost = host.contains(":") ? "[\(host)]" : host
    return scheme + "://" + shownHost + (port == 0 || port == defaultPort ? "" : ":\(port)")
  }

  /// True when a saved entry belongs to exactly the page's origin.
  public static func matches(_ saved: String, page: String?) -> Bool {
    guard let a = normalize(saved), let b = normalize(page) else { return false }
    return a == b
  }

  /// Stricter than `matches`, for Sign in as … on a task's sign-in page: the page must be HTTPS
  /// (no plain HTTP, not even on this Mac) and its exact origin must be the saved one.
  public static func matchesForTask(_ saved: String, page: String?) -> Bool {
    guard let b = normalize(page), b.hasPrefix("https://") else { return false }
    return normalize(saved) == b
  }

  /// A short label for prompts: the host without `www.`.
  public static func displayHost(_ origin: String) -> String {
    (URL(string: origin)?.host ?? origin).withoutWWW
  }
}

/// What to offer after a sign-in form was submitted.
public enum PasswordFillPolicy {
  public static func allows(savedOrigin: String, page: String?, personal: Bool, awake: Bool,
    loading: Bool, certificateTrusted: Bool) -> Bool {
    personal && awake && !loading && certificateTrusted && CredentialOrigin.matches(savedOrigin, page: page)
  }
}

public enum PasswordSaveDecision: Equatable, Sendable {
  case save
  case update(username: String)
  case none

  /// - Parameters:
  ///   - username: the submitted username (may be empty).
  ///   - saved: usernames already saved for this exact origin.
  ///   - samePassword: whether the saved password for a username equals the submitted one.
  public static func decide(
    username: String, saved: [String], samePassword: (String) -> Bool
  ) -> PasswordSaveDecision {
    if saved.contains(username) {
      return samePassword(username) ? .none : .update(username: username)
    }
    if username.isEmpty, saved.count == 1 {
      return samePassword(saved[0]) ? .none : .update(username: saved[0])
    }
    return .save
  }
}
