import Foundation

/// History keeps its existing route strings so saved sessions and keyboard commands still work.
public enum HistorySegment: String, CaseIterable, Identifiable, Sendable {
  case pages, chats, activity, projects, todo
  public var id: String { rawValue }
  public static let visible: [Self] = [.projects, .todo]
  /// Older saved routes still resolve, but no longer reopen the removed history screens.
  public var displayed: Self { Self.visible.contains(self) ? self : .projects }
  public var title: String { self == .todo ? "Goals" : rawValue.capitalized }
  public var section: String {
    switch self {
    case .pages: return ShellSection.history
    case .chats: return ShellSection.chats
    case .activity: return ShellSection.today
    case .projects: return ShellSection.projects
    case .todo: return ShellSection.todo
    }
  }
  public init?(section: String) {
    guard let found = Self.allCases.first(where: { $0.section == section }) else { return nil }
    self = found
  }
}

/// Search, source filtering and calendar groups shared by History and Serein's Past chats.
/// The UI supplies display metadata and, for a task, whether its redacted session log matched
/// (`SessionSearchIndex`); searching reads no provider store.
public enum ChatFilter {
  public static let all = "all"
  public static let serein = "serein"
  public struct Item: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var source: String
    public var projectID: String?
    public var projectName: String
    public var date: Date
    public var openNow: Bool
    /// The task's session log holds the query (`SessionSearchIndex`); false for other chats.
    public var logMatch: Bool
    public init(id: String, title: String, source: String, projectID: String? = nil,
                projectName: String = "", date: Date, openNow: Bool = false, logMatch: Bool = false) {
      self.id = id; self.title = title; self.source = source; self.projectID = projectID
      self.projectName = projectName; self.date = date; self.openNow = openNow; self.logMatch = logMatch
    }
  }
  public enum Group: String, CaseIterable, Identifiable, Sendable {
    case openNow = "Open now", today = "Today", yesterday = "Yesterday", week = "This week", earlier = "Earlier"
    public var id: String { rawValue }
  }
  public struct Section: Identifiable, Equatable, Sendable {
    public var group: Group
    public var items: [Item]
    public var id: Group { group }
  }
  public static func sources(_ items: [Item]) -> [String] {
    let present = Set(items.map(\.source))
    let preferred = [serein, "claude", "codex"]
    return [all] + preferred.filter(present.contains) + present.subtracting(preferred).subtracting([all]).sorted()
  }
  public static func matches(_ item: Item, query: String, source: String = all, projectID: String? = nil) -> Bool {
    guard source == all || source == item.source, projectID == nil || projectID == item.projectID else { return false }
    if item.logMatch { return true }
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let text = item.title + " " + item.projectName
    return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
  }
  public static func group(date: Date, now: Date, calendar: Calendar = .current, includesWeek: Bool = true) -> Group {
    let start = calendar.startOfDay(for: now)
    if date >= start { return .today }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: start), date >= yesterday { return .yesterday }
    if includesWeek, let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start, date >= week { return .week }
    return .earlier
  }
  public static func sections(_ items: [Item], query: String = "", source: String = all, projectID: String? = nil,
                              now: Date = Date(), calendar: Calendar = .current, includesWeek: Bool = true) -> [Section] {
    let found = items.filter { matches($0, query: query, source: source, projectID: projectID) }
      .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    let grouped = Dictionary(grouping: found) { item in
      item.openNow ? Group.openNow : group(date: item.date, now: now, calendar: calendar, includesWeek: includesWeek)
    }
    return Group.allCases.compactMap { key in grouped[key].map { Section(group: key, items: $0) } }
  }
}
