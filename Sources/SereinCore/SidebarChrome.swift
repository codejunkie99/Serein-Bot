import Foundation

/// Picks a site icon from the page's `<link rel=icon>` candidates. The candidates are page
/// content, so they are untrusted: only http(s) URLs are accepted and the result is a URL to fetch
/// without cookies, nothing more.
public enum FaviconChoice {
  public struct Candidate: Equatable {
    public var href: String
    public var rel: String
    public var sizes: String
    public var type: String
    public init(href: String, rel: String, sizes: String = "", type: String = "") {
      self.href = href
      self.rel = rel
      self.sizes = sizes
      self.type = type
    }
  }
  /// Largest icon file Serein reads.
  public static let maxBytes = 256 * 1024
  /// The icon size the sidebar draws at 2x.
  public static let target = 32.0

  /// The best candidate for a 16-point row icon, else `/favicon.ico` at the page origin.
  /// Nil for pages that are not http(s).
  public static func best(_ candidates: [Candidate], page: URL) -> URL? {
    guard let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = page.host, !host.isEmpty
    else { return nil }
    var scored: [(score: Double, url: URL)] = []
    for candidate in candidates.prefix(40) {
      let rel = candidate.rel.lowercased()
      let words = Set(rel.split(whereSeparator: { $0.isWhitespace }).map(String.init))
      guard words.contains("icon") || words.contains("apple-touch-icon")
        || words.contains("apple-touch-icon-precomposed"),
        !words.contains("mask-icon"),
        let url = URL(string: candidate.href.trimmingCharacters(in: .whitespacesAndNewlines),
          relativeTo: page)?.absoluteURL,
        let itsScheme = url.scheme?.lowercased(), ["http", "https"].contains(itsScheme),
        url.host?.isEmpty == false
      else { continue }
      let touch = words.contains("apple-touch-icon") || words.contains("apple-touch-icon-precomposed")
      let size = largestSize(candidate.sizes) ?? (touch ? 180 : 16)
      let type = candidate.type.lowercased()
      let svg = type.contains("svg") || url.path.lowercased().hasSuffix(".svg")
      // Closest to 32 wins; larger is better than smaller; SVG only as a last resort.
      var score = abs(log2(max(size, 1) / target))
      if size < target { score += 0.5 }
      if svg { score += 3 }
      scored.append((score, url))
    }
    if let pick = scored.min(by: { $0.score < $1.score }) { return pick.url }
    var origin = URLComponents()
    origin.scheme = scheme
    origin.host = host
    origin.port = page.port
    origin.path = "/favicon.ico"
    return origin.url
  }

  static func largestSize(_ sizes: String) -> Double? {
    sizes.lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { part -> Double? in
      let sides = part.split(separator: "x")
      guard sides.count == 2, let w = Double(sides[0]), let h = Double(sides[1]) else { return nil }
      return max(w, h)
    }.max()
  }

  /// Cache file name for a host: lowercase letters, digits, dots and hyphens only.
  public static func cacheName(host: String) -> String? {
    let lower = host.lowercased()
    guard !lower.isEmpty, lower.count <= 253,
      lower.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
      !lower.hasPrefix(".")
    else { return nil }
    return lower + ".png"
  }
}

/// What an agent's status bar on a tab row shows.
public enum AgentTabStatus: String, Equatable {
  case working, done, needsYou, failed, stopped

  /// From the board: a tab still in use is working; otherwise the finish outcome decides.
  public static func make(working: Bool, outcome: String?) -> AgentTabStatus {
    if working { return .working }
    switch outcome {
    case "done": return .done
    case "needs_user", "waiting": return .needsYou
    case "failed", "stuck": return .failed
    default: return .stopped
    }
  }
  /// The status in a word or two, in sentence case (help text, VoiceOver).
  public var word: String {
    switch self {
    case .working: return "Working"
    case .done: return "Done"
    case .needsYou: return "Needs you"
    case .failed: return "Could not finish"
    case .stopped: return "Stopped"
    }
  }
  /// The one length-of-time wording: "41 s", "2 min", "1 h 2 min"; compact for dense
  /// figures: "41s", "2m", "1h 2m". Status pills say it through `TaskWords.pill`.
  public static func duration(_ seconds: TimeInterval, compact: Bool = false) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
    let (secUnit, minUnit, hourUnit) = compact ? ("s", "m", "h") : (" s", " min", " h")
    if s < 60 { return "\(s)\(secUnit)" }
    if s < 3600 { return "\(s / 60)\(minUnit)" }
    return "\(s / 3600)\(hourUnit) \(s % 3600 / 60)\(minUnit)"
  }
}
