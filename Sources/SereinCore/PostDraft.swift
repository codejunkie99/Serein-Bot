import Foundation

/// A post for X that an assistant drafted (`post_draft`), shown under its reply as it will look.
/// One post, or a thread when there are more. Serein never posts it: the person copies it or opens
/// X's own composer with the words filled in, and posts it there themselves.
public struct PostDraft: Codable, Hashable, Sendable {
  /// One string per post, in order; more than one is a thread.
  public var posts: [String]
  public init(posts: [String]) { self.posts = posts }

  public static let maxPosts = 25
  /// X's limit for an account without Premium, in weighted characters (`weightedCount`).
  public static let limit = 280
  /// What a draft may hold per post before it is cut, so a runaway answer cannot fill the chat.
  public static let maxStored = 4000
  /// What every link counts as on X, however long it is.
  static let linkWeight = 23

  /// The posts from `post_draft`'s arguments: each trimmed, hidden characters dropped (line breaks
  /// stay), empty ones left out, at most `maxPosts`. nil when no words are left.
  public static func parse(_ a: [String: Any]) -> PostDraft? {
    let given: [String] = (a["posts"] as? [String]) ?? []
    let posts: [String] = given.prefix(maxPosts).compactMap { raw in
      let kept = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0 == "\n" || joinsEmoji($0) || !SafeFileName.hidden($0) }))
      let text = String(kept.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxStored))
      return text.isEmpty ? nil : text
    }
    return posts.isEmpty ? nil : PostDraft(posts: posts)
  }

  /// The joiner and tag characters that hold one emoji together (👩‍💻, a subdivision flag);
  /// `SafeFileName.hidden` would drop them and split the emoji.
  static func joinsEmoji(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value == 0x200D || (0xE0020...0xE007F).contains(scalar.value)
  }
  /// The length X counts (docs.x.com, "Counting characters"): every link is 23, an emoji is 2, a
  /// Latin, Greek or Cyrillic letter or common punctuation is 1, and anything else (CJK, for one)
  /// is 2.
  /// shortcut: links are found by scheme only (no bare "example.com"); upgrade to twitter-text's
  /// TLD list if drafts often carry bare domains.
  public static func weightedCount(_ text: String) -> Int {
    var rest = text.precomposedStringWithCanonicalMapping
    var count = 0
    while let link = rest.range(of: #"https?://[^\s]+"#, options: .regularExpression) {
      count += lettersCount(rest[..<link.lowerBound]) + linkWeight
      rest = String(rest[link.upperBound...])
    }
    return count + lettersCount(Substring(rest))
  }
  static func lettersCount(_ text: Substring) -> Int {
    text.reduce(0) { total, character in
      let scalars = character.unicodeScalars
      guard let first = scalars.first else { return total }
      // A keycap (1️⃣) starts with a plain digit; its U+20E3 makes it an emoji.
      let emoji: Bool = first.properties.isEmojiPresentation || scalars.contains { $0.value == 0x20E3 }
        || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji && $0.value > 0xFF })
      if emoji { return total + 2 }
      // X weighs each code point of other text, so a vowel sign (कि) counts on its own.
      return total + scalars.reduce(0) { sum, scalar in
        let v: UInt32 = scalar.value
        let light: Bool = v <= 0x10FF || (0x2000...0x200D).contains(v) || (0x2010...0x201F).contains(v) || (0x2032...0x2037).contains(v)
        return sum + (light ? 1 : 2)
      }
    }
  }
  /// The posts over `limit`, as 1-based numbers with their counts.
  public var over: [(number: Int, count: Int)] {
    posts.enumerated().compactMap { index, text in
      let count: Int = Self.weightedCount(text)
      return count > Self.limit ? (index + 1, count) : nil
    }
  }
  /// X's composer with `text` filled in; the person posts it there.
  public static func composeURL(_ text: String) -> URL? {
    guard var parts = URLComponents(string: "https://x.com/intent/tweet") else { return nil }
    parts.queryItems = [URLQueryItem(name: "text", value: text)]
    // queryItems leaves "+" as it is, which X reads as a space ("C++" would lose its pluses).
    let query: String? = parts.percentEncodedQuery
    parts.percentEncodedQuery = query?.replacingOccurrences(of: "+", with: "%2B")
    return parts.url
  }
  /// All the posts as one text to paste, a blank line between posts.
  public var plain: String { posts.joined(separator: "\n\n") }
}
