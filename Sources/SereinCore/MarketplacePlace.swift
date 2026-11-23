import Foundation

/// Where the Marketplace is (`ShellSection.marketplace`): one of its three places, a group's every
/// app (See all), an app the person added (Your apps) or On this Mac. Pure, so checked in
/// AssistantCoreChecks.
public enum MarketplacePlace: Hashable, Sendable {
  case apps, teams, plugins, mac
  /// One group's every app, from its See all on Apps.
  case category(ConnectorCatalog.Category)
  /// An app the person added, by its catalog id.
  case app(String)

  /// How many apps a group shows on Apps before See all.
  public static let preview = 4

  public var label: String {
    switch self {
    case .apps: return "Apps"
    case .teams: return "Teams"
    case .plugins: return "Plugins"
    case .mac: return "On this Mac"
    case .category(let category): return category.title
    case .app(let id): return ConnectorCatalog.all.first { $0.id == id }?.name ?? "App"
    }
  }
  /// The header's trail under "Marketplace": a group sits under Apps; every other place is a
  /// row of the column, so it stands alone.
  public var levels: [String] {
    if case .category = self { return [MarketplacePlace.apps.label, label] }
    return [label]
  }
  /// Where the trail's parent and Esc go: Apps from a group, nowhere from a column row.
  public var parent: MarketplacePlace? {
    if case .category = self { return .apps }
    return nil
  }
  /// The column row that holds the selection: a group's page keeps Apps selected.
  public var columnRow: MarketplacePlace {
    if case .category = self { return .apps }
    return self
  }
}

/// The Marketplace's pure rules: what a group shows before See all, and the order of Your apps.
public enum MarketplaceRules {
  /// A group on Apps: its first `limit` items, and whether See all has more to show.
  public static func preview<Item>(_ items: [Item], limit: Int = MarketplacePlace.preview) -> (shown: [Item], more: Bool) {
    (Array(items.prefix(max(0, limit))), items.count > max(0, limit))
  }
  /// Your apps: every app the person added, what needs them first, then what is being tested,
  /// what works and what is off; the catalog's order within each. An app not set up is not theirs.
  public static func yourApps(_ apps: [(id: String, state: ConnectionState)]) -> [String] {
    func rank(_ state: ConnectionState) -> Int? {
      switch state {
      case .needsAttention: return 0
      case .testing: return 1
      case .working: return 2
      case .off: return 3
      case .notSetUp: return nil
      }
    }
    return apps.enumerated()
      .compactMap { index, app in rank(app.state).map { (rank: $0, index: index, id: app.id) } }
      .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
      .map(\.id)
  }
}
