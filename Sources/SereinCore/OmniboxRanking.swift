import Foundation

/// Pure ranking for the unified address field. No UI, no network.
public enum OmniboxKind: String, Equatable {
  case open, search, task, suggestion, tab, history, saved
}

public enum OmniboxInputClass: Equatable {
  case empty, url, search, task
}

public struct OmniboxRow: Identifiable, Equatable {
  public var id: String { kind.rawValue + "|" + payload }
  public let kind: OmniboxKind
  public let title: String
  public let subtitle: String
  /// open/history/saved: address. search/suggestion: query. task: task text. tab: tab id.
  public let payload: String
  public var removable: Bool { kind == .history }
  public init(kind: OmniboxKind, title: String, subtitle: String = "", payload: String) {
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.payload = payload
  }
}

public struct OmniboxTab: Equatable {
  public let id: String
  public let title: String
  public let url: String
  public let isPrivate: Bool
  public init(id: String, title: String, url: String, isPrivate: Bool = false) {
    self.id = id
    self.title = title
    self.url = url
    self.isPrivate = isPrivate
  }
}

public struct OmniboxPage: Equatable {
  public let title: String
  public let url: String
  public let note: String
  public init(title: String, url: String, note: String = "") {
    self.title = title
    self.url = url
    self.note = note
  }
}

public enum OmniboxRanking {
  static let strongVerbs: Set<String> = [
    "fix", "refactor", "implement", "write", "add", "update", "rename", "debug", "summarize",
    "summarise", "review", "draft", "create", "build", "remove", "delete", "migrate", "convert",
    "rewrite", "investigate", "optimize", "generate", "document", "test", "deploy", "clean",
  ]
  static let weakVerbs: Set<String> = [
    "find", "compare", "research", "check", "make", "show", "list", "get", "look", "explain",
    "set", "change", "move", "help", "plan",
  ]
  static let politeLeads = [
    "please ", "can you ", "could you ", "would you ", "help me ", "i want you to ",
    "i need you to ", "i need to ", "i want to ",
  ]

  /// Text that talks to an assistant: “Ask Serein” ranks first for it (§7.7).
  static let assistantLeads = [
    "remind me ", "remember ", "tell me ", "can you ", "could you ", "would you ", "will you ",
    "please ", "help me ",
  ]
  /// Words that make a question about you or Serein (“is my flight on time?”).
  static let personalWords: Set<String> = ["my", "me", "i", "i'm", "you", "your", "serein"]

  public static func classify(_ input: String) -> OmniboxInputClass {
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return .empty }
    if s.hasPrefix("/") && s.count > 1 { return .task }
    if looksLikeURL(s) { return .url }
    let lower = s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    let words = lower.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    // (a) A lead that asks an assistant: remind me, remember, can you, please…
    if assistantLeads.contains(where: { lower.hasPrefix($0) }) { return .task }
    // (b) A question of at least three words about you or Serein. “how tall is everest?” and
    // “how to …” stay searches.
    if lower.hasSuffix("?"), words.count >= 3,
      words.contains(where: { personalWords.contains($0.trimmingCharacters(in: .punctuationCharacters.subtracting(["'"]))) })
    {
      return .task
    }
    if words.count >= 3 {
      if politeLeads.contains(where: { lower.hasPrefix($0) }) { return .task }
      if strongVerbs.contains(words[0]) { return .task }
      if words.count >= 5 && weakVerbs.contains(words[0]) { return .task }
    }
    return .search
  }

  public static func looksLikeURL(_ s: String) -> Bool {
    if s.contains(" ") { return false }
    let lower = s.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
      return URL(string: s)?.host?.isEmpty == false
    }
    if lower.contains("://") { return false }
    var host = lower
    if let slash = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
      host = String(host[..<slash])
    }
    if let colon = host.lastIndex(of: ":"),
      host.index(after: colon) != host.endIndex,
      host[host.index(after: colon)...].allSatisfy(\.isNumber)
    {
      host = String(host[..<colon])
    }
    if host == "localhost" { return true }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
    if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return labels.count == 4 }
    guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else {
      return false
    }
    return labels.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
  }

  public static func searchURL(_ query: String, engine: String) -> String {
    let base =
      engine == "Google"
      ? "https://www.google.com/search"
      : engine == "Bing" ? "https://www.bing.com/search" : "https://duckduckgo.com/"
    var c = URLComponents(string: base)!
    c.queryItems = [URLQueryItem(name: "q", value: query)]
    return c.url!.absoluteString
  }

  /// The selected engine's own suggestion endpoint.
  public static func suggestionURL(_ query: String, engine: String) -> URL? {
    let (base, key) =
      engine == "Google"
      ? ("https://suggestqueries.google.com/complete/search", "q")
      : engine == "Bing" ? ("https://api.bing.com/osjson.aspx", "query") : ("https://duckduckgo.com/ac/", "q")
    var c = URLComponents(string: base)!
    c.queryItems = (engine == "Google" ? [URLQueryItem(name: "client", value: "firefox")] : [])
      + [URLQueryItem(name: key, value: query)]
    return c.url
  }

  /// Suggestions are fetched only when the person turned them on, the tab is not private, and the
  /// text is a plain search. Web addresses, `/` commands and task requests are never sent.
  public static func shouldFetchSuggestions(_ text: String, enabled: Bool, privateTab: Bool) -> Bool {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return enabled && !privateTab && query.count >= 2 && classify(query) == .search
  }

  /// Parses `[{"phrase":"..."}]` (DuckDuckGo) or the OpenSearch form `["q",["a","b"]]` (Google, Bing).
  public static func parseSuggestions(_ data: Data, limit: Int = 5) -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var phrases: [String] = []
    if let array = json as? [[String: Any]] {
      phrases = array.compactMap { $0["phrase"] as? String }
    } else if let array = json as? [Any], array.count > 1, let list = array[1] as? [Any] {
      phrases = list.compactMap { $0 as? String }
    }
    var seen = Set<String>()
    var out: [String] = []
    for raw in phrases {
      let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !phrase.isEmpty, phrase.count <= 120, seen.insert(phrase.lowercased()).inserted
      else { continue }
      out.append(phrase)
      if out.count >= limit { break }
    }
    return out
  }

  static func tokens(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }
  /// Every token occurs, ignoring case, in at least one of `fields`. Tokens hold no whitespace,
  /// so this equals a search of the fields joined with spaces.
  static func matches(_ tokens: [String], in fields: String...) -> Bool {
    guard !tokens.isEmpty else { return false }
    // Most titles and addresses are ASCII: compare their bytes with A–Z folded, without a
    // lowercased copy of each field. Anything else takes the full Unicode path.
    let ascii = tokens.allSatisfy { $0.utf8.allSatisfy { $0 < 0x80 } }
    var lowered: [String]?
    return tokens.allSatisfy { token in
      fields.contains { field in
        if ascii, let hit = asciiContains(field, token) { return hit }
        if lowered == nil { lowered = fields.map { $0.lowercased() } }
        return lowered!.contains { $0.contains(token) }
      }
    }
  }
  /// `needle` (lowercase ASCII) occurs in `haystack` with A–Z folded; nil when `haystack` is not
  /// ASCII, so the caller takes the Unicode path.
  static func asciiContains(_ haystack: String, _ needle: String) -> Bool? {
    var haystack = haystack, needle = needle
    return haystack.withUTF8 { h in
      needle.withUTF8 { n -> Bool? in
        guard let lead = n.first else { return true }
        var ascii = true, found = false
        @inline(__always) func lower(_ b: UInt8) -> UInt8 { b &- 0x41 < 26 ? b | 0x20 : b }
        var start = 0
        while start < h.count {
          let b = h[start]
          if b >= 0x80 { ascii = false; break }
          if !found, start + n.count <= h.count, lower(b) == lead {
            var i = 1
            while i < n.count, lower(h[start + i]) == n[i] { i += 1 }
            if i == n.count { found = true }
          }
          start += 1
        }
        return ascii ? found : nil
      }
    }
  }
  /// The first `limit` items that pass `test`, in order. The rest are not tested: the field
  /// ranks up to 3,000 history entries on each key press, and most queries fill the rows early.
  static func first<T>(_ limit: Int, of items: [T], where test: (T) -> Bool) -> [T] {
    var out: [T] = []
    for item in items where test(item) {
      out.append(item)
      if out.count == limit { break }
    }
    return out
  }
  static func shortURL(_ url: String) -> String {
    guard let u = URL(string: url), let host = u.host else { return url }
    let path = u.path == "/" ? "" : u.path
    return host.withoutWWW + path
  }

  /// Ranks rows. Private tabs are dropped here; callers must also pass only non-private history.
  /// `assistant` is false while no AI app is connected: Search then always ranks first.
  public static func rank(
    _ input: String, tabs: [OmniboxTab] = [], history: [OmniboxPage] = [],
    saved: [OmniboxPage] = [], suggestions: [String] = [], engine: String = "DuckDuckGo",
    assistant: Bool = true
  ) -> [OmniboxRow] {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let kind = classify(text)
    if kind == .empty { return [] }
    let isSlash = text.hasPrefix("/") && text.count > 1
    let taskText = isSlash ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text
    let query = taskText
    let toks = tokens(query)

    let openRow = OmniboxRow(
      kind: .open, title: "Open \(text)", subtitle: shortURL(BrowserPolicy.address(text)),
      payload: text)
    let searchRow = OmniboxRow(
      kind: .search, title: "Search for \u{201C}\(query)\u{201D}", subtitle: "Web search",
      payload: query)
    let taskRow = OmniboxRow(
      kind: .task, title: "Ask Serein", subtitle: taskText, payload: taskText)
    let suggestionRows = suggestions.filter { $0.lowercased() != query.lowercased() }.prefix(4).map {
      OmniboxRow(kind: .suggestion, title: $0, subtitle: "Suggestion", payload: $0)
    }

    let visibleTabs = tabs.filter { !$0.isPrivate }
    let tabRows = first(3, of: visibleTabs) { matches(toks, in: $0.title, $0.url) }.map {
      OmniboxRow(
        kind: .tab, title: $0.title.isEmpty ? shortURL($0.url) : $0.title,
        subtitle: shortURL($0.url), payload: $0.id)
    }
    let openURLs = Set(visibleTabs.map(\.url))
    var seen = Set<String>()
    let historyRows = first(4, of: history) {
      matches(toks, in: $0.title, $0.url) && !openURLs.contains($0.url)
        && seen.insert($0.url).inserted
    }.map {
      OmniboxRow(
        kind: .history, title: $0.title.isEmpty ? shortURL($0.url) : $0.title,
        subtitle: shortURL($0.url), payload: $0.url)
    }
    let savedRows = first(2, of: saved) { matches(toks, in: $0.title, $0.url, $0.note) }
      .map {
        OmniboxRow(
          kind: .saved, title: $0.title.isEmpty ? shortURL($0.url) : $0.title,
          subtitle: $0.note.isEmpty ? shortURL($0.url) : String($0.note.prefix(90)),
          payload: $0.url)
      }

    var rows: [OmniboxRow] = []
    switch kind {
    case .url: rows = [openRow, searchRow] + tabRows
    case .task: rows = (assistant ? [taskRow, searchRow] : [searchRow, taskRow]) + tabRows
    default:
      // Keep the intent and its alternate together. A history hit or an arriving suggestion
      // must not change ⌥Return from asking Serein to navigating to a search in a new tab.
      rows = [searchRow, taskRow] + suggestionRows + tabRows
    }
    rows += historyRows + savedRows
    var ids = Set<String>()
    return rows.filter { ids.insert($0.id).inserted }
  }
  /// The row ⌥Return takes: the second of the first two when they are “Ask Serein” and Search
  /// (either way round); nil otherwise, when ⌥Return opens the highlighted row in a new tab.
  public static func alternate(_ rows: [OmniboxRow]) -> Int? {
    guard rows.count >= 2 else { return nil }
    let pair = Set([rows[0].kind, rows[1].kind])
    return pair == [.task, .search] ? 1 : nil
  }
  /// The key hint a row shows: “Return” on the first of that pair, “⌥Return” on the second.
  public static func keyHint(_ rows: [OmniboxRow], index: Int) -> String? {
    guard alternate(rows) != nil, index < 2 else { return nil }
    return index == 0 ? "Return" : "\u{2325}Return"
  }
}

extension String {
  /// A host without a leading `www.`.
  var withoutWWW: String { hasPrefix("www.") ? String(dropFirst(4)) : self }
}
