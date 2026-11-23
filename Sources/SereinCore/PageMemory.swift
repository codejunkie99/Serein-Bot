import Foundation

/// Text-quote anchor for a kept passage: the words themselves plus a little text on each side.
public struct KeptAnchor: Codable, Equatable, Sendable {
  public var prefix: String
  public var exact: String
  public var suffix: String
  public static let maxExact = 1000
  public static let context = 64
  public init(prefix: String, exact: String, suffix: String) {
    self.prefix = String(prefix.suffix(Self.context))
    self.exact = String(exact.prefix(Self.maxExact))
    self.suffix = String(suffix.prefix(Self.context))
  }
}

/// Same page, ignoring the fragment, a trailing slash and host case.
public enum PageIdentity {
  public static func key(_ address: String) -> String {
    guard var c = URLComponents(string: address) else { return address }
    c.fragment = nil
    c.host = c.host?.lowercased()
    var path = c.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    c.path = path
    return c.string ?? address
  }
}

/// Pages the memory features never read: sign-in, payment, account and similar.
public enum SensitivePage {
  static let words = [
    "login", "log-in", "signin", "sign-in", "signup", "sign-up", "auth", "oauth", "sso", "password",
    "passwd", "checkout", "payment", "billing", "bank", "account", "wallet", "verify", "2fa", "mfa",
    "otp", "card", "secure",
  ]
  public static func isSensitive(address: String) -> Bool {
    guard let u = URL(string: address), let host = u.host?.lowercased() else { return true }
    let hostWords = host.split(separator: ".").map(String.init)
    if hostWords.contains(where: { $0.contains("bank") || $0 == "login" || $0 == "accounts" }) {
      return true
    }
    let path = u.path.lowercased()
    let segments = path.split(whereSeparator: { "/-_.".contains($0) }).map(String.init)
    return words.contains { w in
      w.contains("-") ? path.contains(w) : segments.contains(w)
    }
  }
}

/// Resurfacing a kept passage on the start page after 1 day, 1 week, 1 month and 3 months.
public enum KeptResurface {
  public static let stages: [TimeInterval] = [86_400, 7 * 86_400, 30 * 86_400, 90 * 86_400]
  /// The highest stage reached that has not been shown yet (1...4), if any.
  public static func dueStage(kept: Date, now: Date, shown: Int) -> Int? {
    let age = now.timeIntervalSince(kept)
    let reached = stages.filter { age >= $0 }.count
    return reached > shown ? reached : nil
  }
  public static func due(marks: [Mark], shown: [String: Int], now: Date = Date()) -> [(
    mark: Mark, stage: Int
  )] {
    marks.compactMap { m in
      guard !m.quote.isEmpty, let s = dueStage(kept: m.date, now: now, shown: shown[m.id] ?? 0)
      else { return nil }
      return (m, s)
    }.sorted { $0.mark.date > $1.mark.date }
  }
  public static func label(stage: Int) -> String {
    ["", "From yesterday", "From last week", "From last month", "From three months ago"][
      max(0, min(4, stage))]
  }
}

/// Block-hash diff of a page between two visits.
public enum PageDiff {
  public static let chipThreshold = 200
  static let relative = try! NSRegularExpression(
    pattern:
      "\\b(?:(?:an?|few|several)\\s+)?(?:seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?)\\s+ago\\b|\\b(?:just now|now|today|yesterday|tomorrow)\\b",
    options: [.caseInsensitive])

  /// Letters only: relative times and digits are removed, so counters and clocks do not count.
  public static func normalize(_ block: String) -> String {
    let lower = block.lowercased()
    let ns = lower as NSString
    let stripped = relative.stringByReplacingMatches(
      in: lower, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    var out = ""
    var gap = false
    for ch in stripped {
      if ch.isLetter {
        if gap && !out.isEmpty { out.append(" ") }
        gap = false
        out.append(ch)
      } else {
        gap = true
      }
    }
    return out
  }
  public static func hash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01b3
    }
    return h
  }
  public static func blocks(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }
  }
  public struct Result: Equatable {
    public var added: [String]
    public var addedText: String { added.joined(separator: "\n") }
    public var characters: Int { added.reduce(0) { $0 + $1.count } }
    public var isSignificant: Bool { characters >= PageDiff.chipThreshold }
  }
  static let minimumLetters = 12
  /// Blocks of `current` that were not in `previous`. Saved text is cut at `limit` characters, so a
  /// block that touches the cut is dropped from each side.
  public static func compare(previous: String, current: String, limit: Int = 8000) -> Result {
    func prepared(_ text: String) -> [String] {
      var b = blocks(String(text.prefix(limit)))
      if text.count >= limit, !b.isEmpty { b.removeLast() }
      return b
    }
    let old = Set(prepared(previous).map { hash(normalize($0)) })
    var seen = Set<UInt64>()
    var added: [String] = []
    for block in prepared(current) {
      let n = normalize(block)
      guard n.count >= minimumLetters else { continue }
      let h = hash(n)
      if !old.contains(h), seen.insert(h).inserted { added.append(block) }
    }
    return Result(added: added)
  }
}

/// A summary of new page text may only contain numbers that the new text contains.
public enum SummaryRules {
  static let number = try! NSRegularExpression(pattern: "[0-9]+(?:[.,][0-9]+)*")
  public static func numbers(_ s: String) -> Set<String> {
    let ns = s as NSString
    return Set(
      number.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
        ns.substring(with: $0.range)
      })
  }
  public static func validate(summary: String, newText: String) throws {
    let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, s.count <= 240 else {
      throw SereinError.invalid("Summary has the wrong length")
    }
    guard numbers(s).isSubset(of: numbers(newText)) else {
      throw SereinError.invalid("Summary contains a number that is not in the new text")
    }
  }
}
