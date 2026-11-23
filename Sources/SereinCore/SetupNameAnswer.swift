import Foundation

/// What someone typed at “What should I call you?”: a name, or something they want (a question or
/// a request), which must not become what Serein calls them. Length is left to the name check, so
/// an overlong name still gets its own answer.
public enum SetupNameAnswer: Equatable, Sendable {
  case name(String)
  case request

  public init(_ typed: String) {
    let text = Self.trimmed(typed)
    guard !text.isEmpty, !text.contains(where: { "?？".contains($0) }) else {
      self = .request
      return
    }
    let body = Self.withoutGreeting(text)
    let (words, wordLimit) = Self.withoutIntro(body)
    let name = Self.trimmed(words)
    let parts = name.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    guard let first = parts.first, parts.count <= wordLimit, !Self.isSentenceWithoutSpaces(name) else {
      self = .request
      return
    }
    let asks = parts.count == 1 ? Self.neverAName.contains(first) : Self.startsRequest(first, words: parts.count)
    self = asks ? .request : .name(name)
  }

  private static let endPunctuation = CharacterSet(charactersIn: ".!,;:~。！，；：、")
  private static let greetings = ["hello", "hey", "hi", "yo", "你好", "您好"]
  /// An intro and how many words may follow it: “I'm” also starts sentences, so it admits fewer.
  private static let intros: [(words: String, limit: Int)] = [
    ("you can call me ", 4), ("just call me ", 4), ("call me ", 4), ("my name is ", 4), ("my name's ", 4),
    ("my name’s ", 4), ("name's ", 4), ("name’s ", 4), ("i'm ", 2), ("i’m ", 2), ("im ", 2), ("i am ", 2),
    ("it's ", 2), ("it’s ", 2), ("this is ", 2), ("我叫", 4), ("叫我", 4), ("我是", 4),
  ]
  /// Alone, these are a greeting or an answer. Others that start requests (“can”, “will”) are real
  /// names on their own, so they count only with more words after them.
  private static let neverAName: Set<String> = [
    "hi", "hello", "hey", "yo", "there", "serein", "what", "whats", "what's", "what’s", "who", "why", "how", "where",
    "when", "help", "thanks", "thank", "ok", "okay", "yes", "no", "你好", "您好", "谢谢", "帮我",
  ]
  private static let requestStarts: Set<String> = neverAName.union([
    "which", "can", "could", "would", "should", "do", "does", "did", "is", "are", "am", "tell", "show", "open",
    "please", "remind", "write", "find", "make", "i", "i'm", "i’m", "my", "the", "a", "an",
  ])

  private static func startsRequest(_ first: String, words: Int) -> Bool {
    // “Will Smith” is a name; “will you help me” is not.
    requestStarts.contains(first) || (first == "will" && words > 2)
  }
  /// Chinese and Japanese have no spaces to count, and a name there is a few characters long.
  private static func isSentenceWithoutSpaces(_ text: String) -> Bool {
    guard text.count > 6, !text.contains(where: \.isWhitespace) else { return false }
    return text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) }
  }
  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines.union(endPunctuation))
  }
  private static func withoutGreeting(_ text: String) -> String {
    for greeting in greetings {
      guard let found = text.range(of: greeting, options: [.caseInsensitive, .anchored]) else { continue }
      let rest = text[found.upperBound...]
      guard let next = rest.first, next.isWhitespace || next.isPunctuation else { continue }
      let words = trimmed(String(rest))
      if !words.isEmpty { return words }
    }
    return text
  }
  private static func withoutIntro(_ text: String) -> (String, Int) {
    for intro in intros {
      if let found = text.range(of: intro.words, options: [.caseInsensitive, .anchored]) {
        return (String(text[found.upperBound...]), intro.limit)
      }
    }
    return (text, 4)
  }
}
