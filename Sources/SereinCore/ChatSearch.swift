import Foundation

/// `chats_search`: which messages in Serein's other chats match the words, best first. Pure, so
/// `--verify-assistant-core` checks it. The text stays data: nothing here reads it as an instruction.
public enum ChatSearch {
  public struct Message: Sendable {
    public var id: String
    public var fromPerson: Bool
    public var text: String
    public var sentAt: Date?
    public init(id: String, fromPerson: Bool, text: String, sentAt: Date?) {
      self.id = id; self.fromPerson = fromPerson; self.text = text; self.sentAt = sentAt
    }
  }
  public struct Chat: Sendable {
    public var id: String
    public var title: String
    public var assistant: String
    public var messages: [Message]
    public init(id: String, title: String, assistant: String, messages: [Message]) {
      self.id = id; self.title = title; self.assistant = assistant; self.messages = messages
    }
  }
  public struct Hit: Equatable, Sendable {
    public var chat: String
    public var message: String
  }

  public static let defaultLimit = 8
  public static let maxLimit = 20
  public static let snippetWidth = 280
  static let stopWords: Set<String> = [
    "a", "an", "and", "are", "about", "as", "at", "be", "did", "do", "for", "from", "how", "i", "in", "is", "it", "me",
    "my", "of", "on", "or", "said", "that", "the", "this", "to", "was", "we", "what", "when", "where", "which", "who",
    "with", "you",
  ]

  static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }
  static func words(_ folded: String) -> [Substring] {
    folded.split { !$0.isLetter && !$0.isNumber }
  }

  /// The query's distinct words, folded, without the words every question has.
  public static func terms(_ query: String) -> [String] {
    var seen = Set<String>()
    return words(fold(query)).map(String.init).filter { !stopWords.contains($0) && seen.insert($0).inserted }
  }

  /// A term matches a word it starts (“trip” finds “trips”); a term with letters outside ASCII
  /// matches anywhere, since those scripts do not always space their words.
  static func matches(_ term: String, words: [Substring], folded: String) -> Bool {
    term.unicodeScalars.allSatisfy(\.isASCII) ? words.contains { $0.hasPrefix(term) } : folded.contains(term)
  }

  /// Messages that hold at least half of the terms, rarer terms counting more, newest first among
  /// equals. Empty for a query with no terms.
  public static func search(_ query: String, in chats: [Chat], limit: Int = defaultLimit) -> [Hit] {
    let terms = terms(query)
    guard !terms.isEmpty else { return [] }
    let needed = (terms.count + 1) / 2
    var found: [(hit: Hit, matched: [Int], date: Date)] = []
    var frequency = [Int](repeating: 0, count: terms.count)
    var total = 0
    for chat in chats {
      for message in chat.messages {
        total += 1
        let folded = fold(message.text)
        let split = words(folded)
        let matched = terms.indices.filter { matches(terms[$0], words: split, folded: folded) }
        for i in matched { frequency[i] += 1 }
        guard matched.count >= needed else { continue }
        found.append((Hit(chat: chat.id, message: message.id), matched, message.sentAt ?? .distantPast))
      }
    }
    let weight = frequency.map { log(1 + Double(total) / Double(max($0, 1))) }
    let scored = found.map { (item: $0, score: $0.matched.reduce(0) { $0 + weight[$1] }) }
    let ranked = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.date > $1.item.date }
    return ranked.prefix(min(max(limit, 1), maxLimit)).map(\.item.hit)
  }

  /// At most `width` characters of `text` around the first term it holds, marked with "…" where cut.
  /// Secrets are taken out of the whole message first: a key cut in the middle has lost the
  /// prefix, and a cookie the header, that marks it as one.
  public static func snippet(_ text: String, query: String, width: Int = snippetWidth) -> String {
    let flat = AgentPrivacy.redact(text).split(whereSeparator: \.isNewline).joined(separator: " ")
    guard flat.count > width else { return flat }
    let first = terms(query).compactMap { flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
      .map(\.lowerBound).min() ?? flat.startIndex
    let lead = min(flat.distance(from: flat.startIndex, to: first), width / 3)
    let start = flat.index(first, offsetBy: -lead)
    let end = flat.index(start, offsetBy: width, limitedBy: flat.endIndex) ?? flat.endIndex
    return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
  }
}
