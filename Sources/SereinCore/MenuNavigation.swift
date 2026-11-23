import Foundation

/// Keyboard movement inside Serein's own menus: arrows skip headers, dividers and disabled rows
/// and wrap around; typing selects the next row whose title starts with what was typed.
public enum MenuNavigation {
  /// The next selectable row after `current` (or the first when nothing is highlighted).
  /// `step` is +1 for Down and -1 for Up. Nil when no row can be selected.
  public static func move(_ selectable: [Bool], from current: Int?, step: Int) -> Int? {
    let count = selectable.count
    guard count > 0, selectable.contains(true) else { return nil }
    var index = current ?? (step > 0 ? -1 : count)
    for _ in 0..<count {
      index = ((index + step) % count + count) % count
      if selectable[index] { return index }
    }
    return nil
  }
  /// The first selectable row (Return or → on a submenu highlights it).
  public static func first(_ selectable: [Bool]) -> Int? { move(selectable, from: nil, step: 1) }

  /// Type-to-select: the next selectable title (after `current`, wrapping) that starts with
  /// `typed`, ignoring case and leading symbols. A repeated single letter cycles through matches.
  public static func match(_ titles: [String], selectable: [Bool], typed: String, from current: Int?) -> Int? {
    let needle = typed.lowercased()
    guard !needle.isEmpty, titles.count == selectable.count, !titles.isEmpty else { return nil }
    let cycling = needle.count > 1 && Set(needle).count == 1
    let prefix = cycling ? String(needle.prefix(1)) : needle
    let count = titles.count
    // A longer query keeps the current row when it still matches.
    let start = cycling || needle.count == 1 ? (current ?? -1) + 1 : (current ?? 0)
    for offset in 0..<count {
      let index = (start + offset) % count
      guard selectable[index] else { continue }
      let title = titles[index].lowercased().drop { !$0.isLetter && !$0.isNumber }
      if title.hasPrefix(prefix) { return index }
    }
    return nil
  }
}
