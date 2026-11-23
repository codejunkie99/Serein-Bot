import Foundation

/// One row of the ⌘P "Choose a project" picker.
public struct DestinationOption: Equatable, Identifiable, Sendable {
  public enum Kind: String, Sendable { case page, anywhere, research, project }
  public var kind: Kind
  /// The project ID for a project; the kind's name otherwise.
  public var id: String
  public var title: String
  public var detail: String
  public init(kind: Kind, id: String? = nil, title: String, detail: String = "") {
    self.kind = kind
    self.id = id ?? kind.rawValue
    self.title = title
    self.detail = detail
  }
}

public enum DestinationSearch {
  /// The fixed rows, then the projects in the order given. "Answer about this page" appears only
  /// when there is a regular page to ask about.
  public static func options(
    projects: [(id: String, name: String, detail: String)], pageAvailable: Bool
  ) -> [DestinationOption] {
    var out: [DestinationOption] = []
    if pageAvailable {
      out.append(
        DestinationOption(kind: .page, title: "This page", detail: "Reads the page you're on"))
    }
    out.append(DestinationOption(kind: .anywhere, title: "This Mac", detail: "Calendar, Notes, Finder and apps"))
    out.append(DestinationOption(kind: .research, title: "The web", detail: "Research in its own tabs, without your sign-ins"))
    out += projects.map { DestinationOption(kind: .project, id: $0.id, title: $0.name, detail: $0.detail) }
    return out
  }
  /// Rows matching `query`, best first: a title that starts with it, then a word in the title
  /// that does, then the title containing it, then the detail containing it. Ties keep their
  /// order. An empty query keeps every row.
  public static func filter(_ options: [DestinationOption], query: String) -> [DestinationOption] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return options }
    func score(_ o: DestinationOption) -> Int? {
      let title = o.title.lowercased()
      if title.hasPrefix(q) { return 0 }
      let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
      if title.contains(q) { return 2 }
      if o.detail.lowercased().contains(q) { return 3 }
      return nil
    }
    return options.enumerated().compactMap { i, o in score(o).map { ($0, i, o) } }
      .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
  }
  /// Whether the task keeps the tab in view after this choice: a project chosen from a page
  /// thread (or from a project that already has it) works on the page and the folder together.
  /// Any other destination drops it; "This page" has the tab on its own.
  public static func keepsPage(choosing kind: DestinationOption.Kind, pageAvailable: Bool, hasPage: Bool) -> Bool {
    kind == .project && pageAvailable && hasPage
  }
  /// Arrow keys: moves the highlight, wrapping at both ends.
  public static func move(_ index: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((index + delta) % count + count) % count
  }
}
