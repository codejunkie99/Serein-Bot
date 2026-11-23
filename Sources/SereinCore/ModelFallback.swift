import Foundation

/// Where a chat goes when its route fails: the next backup in the person's order, and whether the
/// move can change who pays. Only a same-cost move happens by itself; any other asks first.
public enum ModelFallback {
  public struct Step: Equatable, Sendable {
    public var route: ModelRoute
    /// The bill cannot change, so the move needs no question (a banner says it happened).
    public var sameCost: Bool
  }
  /// The first route after `current` in `list` (from the top when `current` is not on it) that is
  /// installed and can be picked now; nil when there is none. A route that cannot answer is
  /// skipped, never asked about.
  public static func next(current: ModelRoute, list: [ModelRoute]) -> Step? {
    let start = list.firstIndex { $0.id == current.id }.map { $0 + 1 } ?? 0
    guard let route = list[start...].first(where: { $0.id != current.id && $0.installed && $0.selectable })
    else { return nil }
    return Step(route: route, sameCost: sameCost(from: current, to: route))
  }
  /// Where a chat goes when its AI app's usage limit stops it: the person's backups from another
  /// AI app first, in their order, then any other AI app that can answer now (free, then a plan,
  /// then a key). Never the same AI app, and never one whose own limit is still on (`limited`,
  /// provider ids). nil when nothing else can answer, so Serein asks to connect one.
  public static func elsewhere(current: ModelRoute, backups: [ModelRoute], others: [ModelRoute],
                               limited: Set<String>) -> Step? {
    let rank: (ModelRoute) -> Int = { route in
      switch route.costClass {
      case .free: return 0
      case .yourPlan: return 1
      case .yourKey: return 2
      }
    }
    let usable = { (route: ModelRoute) in
      route.provider != current.provider && !limited.contains(route.provider) && route.installed && route.selectable
    }
    let ordered = backups.filter(usable) + others.filter(usable).enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    guard let route = ordered.first else { return nil }
    return Step(route: route, sameCost: sameCost(from: current, to: route))
  }
  /// Free to free, or one provider's plan to the same plan. A move onto a key always counts as
  /// paid, and every other move can change who pays.
  public static func sameCost(from: ModelRoute, to: ModelRoute) -> Bool {
    switch (from.costClass, to.costClass) {
    case (.free, .free): return true
    case (.yourPlan, .yourPlan): return from.provider == to.provider
    default: return false
    }
  }
}
