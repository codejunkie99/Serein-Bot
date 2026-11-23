import Foundation

/// Where a tab's site icon comes from, in order, and how the icon cache is keyed and trimmed.
///
/// On navigation start: a private tab shows the globe and nothing is fetched. Otherwise the
/// cached icon for the site shows at once; when there is none (or it is stale) the site's
/// `/favicon.ico` and `/apple-touch-icon.png` are requested in parallel with the page. Once the
/// page declares its own `<link rel=icon>`, that icon replaces whatever is showing.
public enum SiteIconPlan {
  public enum Source: Int, Comparable, Sendable {
    case none = 0, cached, probe, declared
    public static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
  }
  public enum CacheState: Equatable, Sendable { case missing, fresh, stale }
  public struct Start: Equatable, Sendable {
    /// Show the cached icon right away.
    public var showCached: Bool
    /// Icons to request now, in preference order (the first that decodes wins).
    public var probe: [URL]
    public init(showCached: Bool, probe: [URL]) {
      self.showCached = showCached
      self.probe = probe
    }
  }

  /// A cached icon is fetched again after a week, and deleted after a month without use.
  public static let maxAge: TimeInterval = 7 * 24 * 3600
  public static let expiry: TimeInterval = 30 * 24 * 3600
  /// The cache folder stays under 4 MB and 1,000 icons; the oldest go first.
  public static let maxBytes = 4 * 1024 * 1024
  public static let maxFiles = 1000

  /// What to do when a navigation to `page` starts.
  /// `mayFetch` is false for isolated agent tabs (they only use icons already cached).
  /// `blocked`: content blocking blocks requests to this host.
  public static func onStart(
    page: URL, privateTab: Bool, mayFetch: Bool, cache: CacheState, blocked: Bool
  ) -> Start {
    guard !privateTab, cacheKey(for: page) != nil else { return Start(showCached: false, probe: []) }
    let fetch = mayFetch && !blocked && cache != .fresh
    return Start(showCached: cache != .missing, probe: fetch ? probeURLs(page: page) : [])
  }

  /// The site's conventional icon locations: `/favicon.ico`, then `/apple-touch-icon.png`.
  public static func probeURLs(page: URL) -> [URL] {
    guard let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = page.host, !host.isEmpty
    else { return [] }
    return ["/favicon.ico", "/apple-touch-icon.png"].compactMap { path in
      var origin = URLComponents()
      origin.scheme = scheme
      origin.host = host.lowercased()
      origin.port = page.port
      origin.path = path
      return origin.url
    }
  }

  /// Whether an icon from `new` should replace the one showing from `current`. A page-declared
  /// icon always wins; a probe never overrides a declared icon.
  public static func replaces(_ current: Source, with new: Source) -> Bool {
    new == .declared || new >= current
  }

  /// The cache key for a page: its lowercased host, plus `_port` for a non-default port, so two
  /// local servers on one host keep separate icons. Nil for anything but http(s).
  public static func cacheKey(for page: URL) -> String? {
    guard let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = page.host?.lowercased(), !host.isEmpty, host.count <= 253, !host.hasPrefix("."),
      host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
    else { return nil }
    let standard = scheme == "https" ? 443 : 80
    if let port = page.port, port != standard { return "\(host)_\(port)" }
    return host
  }
  /// The cache key for an address string; nil when it is not an http(s) URL.
  public static func cacheKey(address: String) -> String? {
    URL(string: address).flatMap(cacheKey(for:))
  }

  public struct CacheEntry: Equatable, Sendable {
    public var name: String
    public var bytes: Int
    public var modified: Date
    public init(name: String, bytes: Int, modified: Date) {
      self.name = name
      self.bytes = bytes
      self.modified = modified
    }
  }
  /// Files to delete: expired ones, then the oldest until the folder fits the caps.
  public static func prune(
    _ entries: [CacheEntry], now: Date, expiry: TimeInterval = expiry, maxBytes: Int = maxBytes,
    maxFiles: Int = maxFiles
  ) -> [String] {
    var gone = Set<String>()
    var kept: [CacheEntry] = []
    for entry in entries {
      if now.timeIntervalSince(entry.modified) > expiry { gone.insert(entry.name) } else { kept.append(entry) }
    }
    kept.sort { $0.modified > $1.modified }
    var bytes = 0
    for (index, entry) in kept.enumerated() {
      bytes += entry.bytes
      if index >= maxFiles || bytes > maxBytes { gone.insert(entry.name) }
    }
    return entries.map(\.name).filter { gone.contains($0) }
  }

  /// Hosts that content blocking blocks outright (`||example.com^` rules that apply to a site's
  /// own requests). Exceptions and third-party-only rules do not count.
  public static func blockedDomains(from filterText: String, allowedSites: [String] = []) -> Set<String> {
    let allowed = Set(allowedSites.map { $0.lowercased() })
    var out = Set<String>()
    for raw in filterText.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("||"), !line.hasPrefix("@@") else { continue }
      let body = line.dropFirst(2)
      let parts = body.split(separator: "$", maxSplits: 1)
      guard let pattern = parts.first else { continue }
      // Party options mean what they mean in FilterRules.convert: third-party-only and
      // domain-scoped rules never block a site's own icon; first-party markers change nothing.
      let options = parts.count > 1 ? parts[1].lowercased().split(separator: ",").map(String.init) : []
      if options.contains(where: { $0 == "third-party" || $0 == "3p" || $0.hasPrefix("domain=") }) { continue }
      let resources = options.filter { !["~third-party", "first-party", "1p", "~3p"].contains($0) }
      if !resources.isEmpty && !resources.contains(where: { ["image", "all", "document"].contains($0) }) {
        continue
      }
      var host = String(pattern)
      if host.hasSuffix("^") { host.removeLast() }
      host = host.lowercased()
      guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
        !allowed.contains(host)
      else { continue }
      out.insert(host)
    }
    return out
  }
  /// True when `host` or one of its parent domains is blocked.
  public static func isBlocked(host: String, domains: Set<String>) -> Bool {
    var labels = host.lowercased().split(separator: ".").map(String.init)
    while labels.count >= 2 {
      if domains.contains(labels.joined(separator: ".")) { return true }
      labels.removeFirst()
    }
    return labels.count == 1 && domains.contains(labels[0])
  }
}
