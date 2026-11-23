import Foundation

/// Decides when a page load should be folded into an earlier visit instead of
/// creating a new history entry (reloads and quick revisits of the same page).
public enum VisitFolding {
  public static let window: TimeInterval = 30 * 60

  /// Scheme, host, port, path and query; the fragment is ignored and scheme/host are case-folded.
  public static func key(_ url: String) -> String {
    guard var c = URLComponents(string: url) else { return url }
    c.fragment = nil
    c.scheme = c.scheme?.lowercased()
    c.host = c.host?.lowercased()
    if c.path.isEmpty { c.path = "/" }
    return c.string ?? url
  }

  /// The id of an existing visit to the same page within the window, if any. `visits` is newest
  /// first (`Library.visits`), so the scan stops at the first visit older than the window.
  public static func target(
    url: String, now: Date = Date(), in visits: [Visit], window: TimeInterval = VisitFolding.window
  ) -> String? {
    let wanted = key(url)
    for visit in visits {
      let age = now.timeIntervalSince(visit.date)
      if age > window { break }
      if age >= 0 && key(visit.url) == wanted { return visit.id }
    }
    return nil
  }
}
