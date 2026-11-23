import Foundation

/// History's search through tasks' session logs, away from the main thread. Each task's log is
/// built and folded (case and diacritics) once per version of its chat, kept in memory only, and
/// dropped once the task is no longer handed in (deleted, or now one of Serein's chats).
public actor SessionSearchIndex {
  /// One task as History hands it in: its id, a number that changes whenever its chat does, and
  /// its saved messages with condensed ranges put back.
  public struct Source: Sendable {
    public var id: String
    public var version: Int
    public var messages: [SessionLog.Message]
    public init(id: String, version: Int, messages: [SessionLog.Message]) {
      self.id = id; self.version = version; self.messages = messages
    }
  }

  /// One log folded for search: its redacted lines and the same lines folded.
  public struct Folded: Sendable {
    public let lines: [String]
    let folded: [String]
    public init(_ log: SessionLog) {
      let all = log.entries.flatMap { $0.text.split(separator: "\n").map(String.init) }
      lines = all
      folded = all.map(Self.fold)
    }
    public static func fold(_ text: String) -> String {
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    /// When the log holds every word of `query`: its first line with the first word, one line of
    /// at most 100 characters. Nil otherwise, and for an empty query.
    public func hit(_ query: String) -> String? {
      let words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
      guard let first = words.first else { return nil }
      let whole = folded.joined(separator: "\n")
      guard words.allSatisfy({ whole.contains($0) }), let index = folded.firstIndex(where: { $0.contains(first) })
      else { return nil }
      return RunNow.clip(lines[index], 100)
    }
  }

  private var cache: [String: (version: Int, log: Folded)] = [:]
  public init() {}

  /// Task id to the matching line, for every task whose log holds all the query's words.
  public func search(_ query: String, in sources: [Source]) -> [String: String] {
    var kept: [String: (version: Int, log: Folded)] = [:]
    var hits: [String: String] = [:]
    for source in sources {
      let log = cache[source.id].flatMap { $0.version == source.version ? $0.log : nil }
        ?? Folded(SessionLog(source.messages))
      kept[source.id] = (source.version, log)
      if let line = log.hit(query) { hits[source.id] = line }
    }
    cache = kept
    return hits
  }
}
