import Foundation

/// Where a task sits in the Agents list. A row keeps its place while it works, finishes or is
/// opened; only a new row or the person's own pin moves anything. Each row goes by every name it
/// has (its chat's id, the session it follows), so a session that becomes a chat when opened stays
/// where it was. Pure, so AssistantCoreChecks checks it.
public enum AgentListOrder {
  /// The most names remembered; the ones at the far end go first.
  public static let limit = 2000

  /// Pinned rows in pin order, then rows not seen before in the order given, then the rest in
  /// their remembered order.
  public static func arranged<T>(
    _ items: [T], known: [String], pinned: [String] = [], keys: (T) -> [String]
  ) -> [T] {
    let places = ranks(known)
    let pins = ranks(pinned)
    let ranked = items.enumerated().map { index, item -> (item: T, pin: Int, place: Int, index: Int) in
      let names = keys(item)
      return (item, names.compactMap { pins[$0] }.min() ?? .max, names.compactMap { places[$0] }.min() ?? -1, index)
    }
    return ranked.sorted { first, second in
      if first.pin != second.pin { return first.pin < second.pin }
      if first.place != second.place { return first.place < second.place }
      return first.index < second.index
    }.map(\.item)
  }

  /// The names to remember after showing `arranged`: a row's new name sits beside its known one, a
  /// new row goes to the front, and names no longer listed keep their place for when they return.
  public static func remembering<T>(_ arranged: [T], known: [String], keys: (T) -> [String]) -> [String] {
    var names = known
    var seen = Set(known)
    var fresh: [String] = []
    for item in arranged {
      let all = keys(item)
      let unseen = all.filter { !seen.contains($0) }
      guard !unseen.isEmpty else { continue }
      seen.formUnion(unseen)
      if let anchor = all.first(where: { known.contains($0) }), let place = names.firstIndex(of: anchor) {
        names.insert(contentsOf: unseen, at: place + 1)
      } else {
        fresh += unseen
      }
    }
    return Array((fresh + names).prefix(limit))
  }

  /// The rows a folded project shows: its first `limit`, and any later one `keep` asks for, in place.
  public static func visible<T>(_ items: [T], limit: Int, keep: (T) -> Bool) -> [T] {
    items.enumerated().filter { $0.offset < limit || keep($0.element) }.map(\.element)
  }

  /// Newest activity first, for Recents; rows with the same time keep the order given.
  public static func recent<T>(_ items: [T], when: (T) -> Date) -> [T] {
    items.enumerated().sorted { first, second in
      let (a, b) = (when(first.element), when(second.element))
      return a != b ? a > b : first.offset < second.offset
    }.map(\.element)
  }

  /// The rows as they stood in `hold`, with any row not in it after them, so a row that appears
  /// while the list holds still moves nothing under the pointer.
  public static func held<T>(_ items: [T], hold: [String], keys: (T) -> [String]) -> [T] {
    let places = ranks(hold)
    let ranked = items.enumerated().map { index, item in
      (item: item, place: keys(item).compactMap { places[$0] }.min() ?? .max, index: index)
    }
    return ranked.sorted { $0.place != $1.place ? $0.place < $1.place : $0.index < $1.index }.map(\.item)
  }

  private static func ranks(_ names: [String]) -> [String: Int] {
    Dictionary(names.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
  }
}
