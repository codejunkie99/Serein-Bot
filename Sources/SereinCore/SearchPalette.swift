import Foundation

/// The Search palette's list (the sidebar's Search, File › Search ⌘K): assistants, chats and
/// Settings pages in that order. Pure: the window gives the rows it already holds in memory and
/// draws the sections it gets back.
public enum SearchPalette {
  public struct Row: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// The quiet line under the title; nil shows the title alone.
    public let line: String?
    public init(id: String, title: String, line: String? = nil) {
      self.id = id
      self.title = title
      self.line = line
    }
  }
  public enum Kind: String, CaseIterable, Sendable {
    case assistants, chats, settings
    public var heading: String { rawValue.capitalized }
  }
  public struct Section: Equatable, Identifiable, Sendable {
    public let kind: Kind
    public let rows: [Row]
    public var id: Kind { kind }
  }

  /// The newest chats listed before anything is typed.
  public static let recentChats = 8
  /// The chats a query lists at most: History holds every past session on this Mac.
  public static let matchedChats = 20
  /// ⌘1 to ⌘9 open the first nine assistants listed.
  public static let hintCount = 9

  /// `chats` come newest first. No query: every assistant, the newest chats, every Settings page.
  /// A query keeps the rows whose title or line holds it (any case) and drops empty sections, so
  /// no sections at all means nothing matched.
  public static func sections(query: String, assistants: [Row], chats: [Row], settings: [Row]) -> [Section] {
    let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
    func matching(_ rows: [Row]) -> [Row] {
      words.isEmpty ? rows : rows.filter { row in
        row.title.localizedCaseInsensitiveContains(words) || (row.line?.localizedCaseInsensitiveContains(words) ?? false)
      }
    }
    let found: [(Kind, [Row])] = [
      (.assistants, matching(assistants)),
      (.chats, Array(matching(chats).prefix(words.isEmpty ? recentChats : matchedChats))),
      (.settings, matching(settings)),
    ]
    return found.filter { !$0.1.isEmpty }.map { Section(kind: $0.0, rows: $0.1) }
  }

  /// The key hint of the assistant at `index` in its section; nil from the tenth on.
  public static func hint(_ index: Int) -> String? {
    (0..<hintCount).contains(index) ? "⌘\(index + 1)" : nil
  }
}
