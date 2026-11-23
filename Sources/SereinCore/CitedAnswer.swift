import Foundation

/// A reply's sources tied to the claims they support (Cited Answer): each citation marker closes
/// a claim, so pressing it lights that claim and unfolds the page it names. Sources come only
/// from the reply's own words: a numbered list or `[1]: url` lines for `[1]` markers, and links
/// written as citations, `([label](url))`, `[2](url)`, a link named by its host, or `(url)`.
/// Only http and https pages count. Serein does not read these pages, so a source says where a
/// claim came from, never that it is true. A checked research report (`init(research:)`) also
/// carries the exact passage Serein matched on each page.
public struct CitedAnswer: Equatable, Sendable {
  public struct Source: Equatable, Sendable {
    public var number: Int
    public var url: String
    public var title: String?
    /// "example.com" for its page.
    public var host: String { CitedAnswer.host(url) ?? url }
  }
  /// One marker in a paragraph's shown text, in Character offsets: the marker, and the claim it
  /// closes (back to the sentence's start or the previous marker).
  public struct Mark: Equatable, Sendable {
    public var number: Int
    public var marker: Range<Int>
    public var claim: Range<Int>
  }
  /// A checked report's claim: its words and each page that bears on it.
  public struct Claim: Equatable, Sendable {
    public struct Citation: Equatable, Sendable {
      public var number: Int
      /// The exact passage Serein matched on its saved copy of the page.
      public var quote: String
      /// "Quoted from", "Supports", "Disagrees" or "Unclear".
      public var role: String
    }
    public var text: String
    public var citations: [Citation]
    /// The claim check's outcome, labelled as an AI assessment; nil when checks were off.
    public var outcome: String?
  }

  public private(set) var sources: [Source] = []
  public private(set) var claims: [Claim] = []
  /// Each cited page's number, so a page cited twice keeps one.
  private var numbers: [String: Int] = [:]

  /// nil when the reply cites nothing it also names a page for.
  public init?(reply: String) {
    // Every source is a page address; most replies have none and cost one scan.
    guard reply.contains("http") else { return nil }
    var defined: [Int: Source] = [:]
    var body: [String] = []
    for line in reply.components(separatedBy: "\n") {
      let lead = line.first { !$0.isWhitespace }
      if lead == "[" || lead?.isNumber == true, line.contains("http"), let source = Self.definition(line) {
        if defined[source.number] == nil { defined[source.number] = source }
      } else {
        body.append(line)
      }
    }
    let text = body.joined(separator: "\n")
    let cited = Set(Self.matches(Self.markerPattern, in: text).flatMap { Self.numbers($0[1]) })
    for source in defined.values.sorted(by: { $0.number < $1.number }) where cited.contains(source.number) {
      sources.append(source)
      if numbers[source.url] == nil { numbers[source.url] = source.number }
    }
    for groups in Self.matches(Self.linkPattern, in: text) {
      guard let link = Self.citationLink(groups) else { continue }
      add(link.url, title: link.title, preferring: link.number)
    }
    for groups in Self.matches(Self.barePattern, in: text) { add(groups[1], title: nil, preferring: nil) }
    guard !sources.isEmpty else { return nil }
  }

  /// A checked research report: each finding cites the page it was quoted from, then each page
  /// the claim check compared it with. Pages are numbered in the report's order.
  public init(research job: ResearchJob) {
    sources = job.sources.enumerated().map { Source(number: $0.offset + 1, url: $0.element.url) }
    for (position, source) in job.sources.enumerated() where source.comparisonOnly != true {
      for (index, finding) in source.findings.enumerated() {
        var citations = [Claim.Citation(number: position + 1, quote: finding.quote, role: "Quoted from")]
        let check = source.claimCheck?.claims.first { $0.finding == index }
        for item in check?.evidence ?? [] {
          guard let other = job.sources.firstIndex(where: { $0.id == item.sourceID }) else { continue }
          citations.append(Claim.Citation(number: other + 1, quote: item.quote, role: Self.role(item.relation)))
        }
        let outcome = job.checksEnabled == true
          ? check.map { $0.outcome.rawValue + " (AI assessment)" } ?? "Claim check pending" : nil
        claims.append(Claim(text: finding.answer, citations: citations, outcome: outcome))
      }
    }
  }

  public func source(_ number: Int) -> Source? { sources.first { $0.number == number } }

  /// A paragraph as Markdown with each citation as a plain `[n]` marker: citation links,
  /// `(url)`, `[^n]` and `[1, 2]` become markers; every other link and word stays.
  public func marked(_ paragraph: String) -> String {
    var text = Self.replacing(Self.linkPattern, in: paragraph) { groups in
      guard let link = Self.citationLink(groups), let number = numbers[link.url] else { return nil }
      return "[\(number)]"
    }
    text = Self.replacing(Self.barePattern, in: text) { groups in numbers[groups[1]].map { "[\($0)]" } }
    let known = Set(sources.map(\.number))
    return Self.replacing(Self.markerPattern, in: text) { groups in
      let cited = Self.numbers(groups[1])
      guard !cited.isEmpty, cited.allSatisfy(known.contains) else { return nil }
      return cited.map { "[\($0)]" }.joined()
    }
  }

  /// The markers in a paragraph's shown text (after `marked` and Markdown), each with its claim.
  /// Markers side by side, `[1][2]`, close the same claim.
  public func marks(in shown: String) -> [Mark] {
    let chars = Array(shown)
    let known = Set(sources.map(\.number))
    func marker(at start: Int) -> (number: Int, end: Int)? {
      guard start < chars.count, chars[start] == "[" else { return nil }
      var k = start + 1
      var digits = ""
      while k < chars.count, digits.count < 3, let digit = chars[k].wholeNumberValue, chars[k].isASCII {
        digits.append(String(digit))
        k += 1
      }
      // `[1]:` starts a definition line, not a citation.
      guard let number = Int(digits), known.contains(number), k < chars.count, chars[k] == "]",
        k + 1 >= chars.count || chars[k + 1] != ":"
      else { return nil }
      return (number, k + 1)
    }
    var marks: [Mark] = []
    var floor = 0
    var i = 0
    while i < chars.count {
      guard let first = marker(at: i) else {
        i += 1
        continue
      }
      var group = [(first.number, i..<first.end)]
      var end = first.end
      while true {
        var k = end
        while k < chars.count, chars[k] == " " { k += 1 }
        guard let next = marker(at: k) else { break }
        group.append((next.number, k..<next.end))
        end = next.end
      }
      let claim = Self.claim(chars, from: floor, to: i)
      marks += group.map { Mark(number: $0.0, marker: $0.1, claim: claim) }
      floor = end
      i = end
    }
    return marks
  }

  // MARK: Parsing

  /// The words a marker at `end` closes: back to the last sentence end after `floor`, without
  /// the spaces at either end.
  static func claim(_ chars: [Character], from floor: Int, to end: Int) -> Range<Int> {
    let stops: Set<Character> = [".", "!", "?"]
    var stop = end
    while stop > floor, chars[stop - 1].isWhitespace { stop -= 1 }
    // A stop right before the marker ("a claim.[1]") ends this claim, not the one before.
    let scan = stop > floor && stops.contains(chars[stop - 1]) ? stop - 1 : stop
    var start = floor
    var k = scan - 1
    while k > floor {
      if chars[k].isWhitespace, stops.contains(chars[k - 1]) {
        start = k
        break
      }
      k -= 1
    }
    while start < stop, chars[start].isWhitespace { start += 1 }
    return start..<stop
  }

  /// `[1]` or `[^1]`, or `[1, 2]`; not a link's label and not a definition.
  static let markerPattern = #"\[\^?(\d{1,3}(?:\s*,\s*\^?\d{1,3})*)\](?![(:])"#
  /// A Markdown link, its label in one or two brackets, perhaps wrapped in parentheses.
  static let linkPattern = #"(\(\s*)?\[\[?([^\[\]\n]{1,200})\]?\]\((https?://[^\s()]+)\)(\s*\))?"#
  /// A bare page address in parentheses, not a link's own target.
  static let barePattern = #"(?<!\])\((https?://[^\s()]+)\)"#

  /// `[1]: https://…`, `[^1] Title https://…` or `1. [Title](https://…)`: a numbered source line.
  static func definition(_ line: String) -> Source? {
    let pattern = #"^\s*(?:\[\^?(\d{1,3})\]:?|(\d{1,3})[.)])\s+(.+?)\s*$"#
    guard let groups = matches(pattern, in: line).first,
      let number = Int(groups[1].isEmpty ? groups[2] : groups[1])
    else { return nil }
    let rest = groups[3]
    if let link = matches(#"\[([^\[\]\n]{1,200})\]\((https?://[^\s()]+)\)"#, in: rest).first, host(link[2]) != nil {
      return Source(number: number, url: link[2], title: title(link[1], url: link[2]))
    }
    guard let found = matches(#"https?://[^\s<>()]+"#, in: rest).first else { return nil }
    let url = String(found[0].reversed().drop { ".,;:".contains($0) }.reversed())
    guard host(url) != nil else { return nil }
    let words = rest.replacingOccurrences(of: found[0], with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|<>").union(.whitespaces))
    return Source(number: number, url: url, title: title(words, url: url))
  }

  /// A link written as a citation: in parentheses, labelled with a number, or labelled with its
  /// own host. Any other link is part of the sentence and stays a link.
  static func citationLink(_ groups: [String]) -> (url: String, title: String?, number: Int?)? {
    let label = groups[2].trimmingCharacters(in: .whitespaces)
    let url = groups[3]
    guard let host = host(url) else { return nil }
    let number = label.allSatisfy(\.isNumber) ? Int(label) : nil
    let wrapped = !groups[1].isEmpty && !groups[4].isEmpty
    guard wrapped || number != nil || label.lowercased() == host else { return nil }
    return (url, number == nil ? title(label, url: url) : nil, number)
  }

  private mutating func add(_ url: String, title: String?, preferring wanted: Int?) {
    guard numbers[url] == nil, Self.host(url) != nil else { return }
    let taken = Set(sources.map(\.number))
    let number = wanted.flatMap { taken.contains($0) ? nil : $0 } ?? (taken.max() ?? 0) + 1
    numbers[url] = number
    sources.append(Source(number: number, url: url, title: title))
    sources.sort { $0.number < $1.number }
  }

  /// A label worth showing: not empty and not just the page's host or address.
  private static func title(_ label: String, url: String) -> String? {
    let trimmed = label.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != url, trimmed.lowercased() != host(url) else { return nil }
    return String(trimmed.prefix(200))
  }

  static func host(_ url: String) -> String? {
    guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
      let host = parsed.host?.lowercased(), !host.isEmpty
    else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private static func role(_ relation: ResearchClaimCheck.Relation) -> String {
    switch relation {
    case .supports: return "Supports"
    case .contradicts: return "Disagrees"
    case .unclear: return "Unclear"
    }
  }

  private static func numbers(_ list: String) -> [Int] {
    list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: " ^"))) }
  }

  /// Each match's groups as strings, "" for a group that did not take part.
  static func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
      (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
  }

  /// Replaces each match that `with` gives text for, from the end so earlier ranges hold.
  private static func replacing(_ pattern: String, in text: String, with: ([String]) -> String?) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    var result = text
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
      guard let replacement = with(groups), let range = Range(match.range, in: result) else { continue }
      result.replaceSubrange(range, with: replacement)
    }
    return result
  }
}
