import Foundation

/// The one project ordering: work that needs you first, then running work, then recently
/// active, then by name.
public enum ProjectOrdering {
  public static func rank(running: Bool, needsYou: Bool, doneToday: Bool) -> Int {
    (needsYou ? 4 : 0) + (running ? 2 : 0) + (doneToday ? 1 : 0)
  }

  /// Sorts ids in place semantics: highest rank first, then most recent activity, then name.
  public static func sorted(
    _ ids: [String], rank: [String: Int], lastActivity: [String: Date], names: [String: String]
  ) -> [String] {
    ids.sorted { a, b in
      let ra = rank[a] ?? 0
      let rb = rank[b] ?? 0
      if ra != rb { return ra > rb }
      let da = lastActivity[a] ?? .distantPast
      let db = lastActivity[b] ?? .distantPast
      if da != db { return da > db }
      return (names[a] ?? a).localizedStandardCompare(names[b] ?? b) == .orderedAscending
    }
  }
}

/// The compact stamp shown on project rows everywhere ("now", "12 min", "3 h", "2 d", "5 w").
public enum RelativeTimeShort {
  public static func text(_ date: Date?, now: Date = Date()) -> String? {
    guard let date, let interval = Calendar.current.dateComponents(
      [.second], from: date, to: now
    ).second, interval >= 0 else { return nil }
    if interval < 60 { return "now" }
    let minutes = interval / 60
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) h" }
    let days = hours / 24
    if days < 7 { return "\(days) d" }
    let weeks = days / 7
    if weeks < 9 { return "\(weeks) w" }
    let months = days / 30
    if months < 18 { return "\(months) mo" }
    return "\(days / 365) y"
  }
}

/// Stable per-project accent derived from its name, so a project wears the same colour
/// everywhere without storing anything.
public enum ProjectMonogram {
  /// FNV-1a scattered over the golden ratio: neighbouring names land on distant hues.
  public static func hue(_ seed: String) -> Double {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in seed.utf8 {
      hash ^= UInt64(byte & 0xff)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    let fraction = Double(hash % 10_000) / 10_000
    return (fraction * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
  }

  /// Up to two leading letters from distinct words ("local knowledge" → "LK"), one otherwise.
  public static func initials(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
      .filter { $0.contains(where: \.isLetter) }
    let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
    return letters.joined().uppercased()
  }
}
