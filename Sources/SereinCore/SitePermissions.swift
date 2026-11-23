import Foundation

/// A site feature the person can allow or block per site. Camera and microphone keep their older
/// `serein.media.` keys (values deny/ask); the others use `serein.site.<feature>.<origin>`.
public enum SiteFeature: String, CaseIterable, Sendable {
  case media, geolocation, notifications, autoplay
  public var label: String {
    switch self {
    case .media: return "Camera and microphone"
    case .geolocation: return "Location"
    case .notifications: return "Notifications"
    case .autoplay: return "Autoplay"
    }
  }
  /// The values a person can pick for this feature; the first is the default.
  public var choices: [String] {
    switch self {
    case .media: return ["deny", "ask"]
    case .geolocation, .notifications: return ["ask", "allow", "block"]
    case .autoplay: return ["muted", "allow", "block"]
    }
  }
  public static func valueLabel(_ value: String) -> String {
    switch value {
    case "allow": return "Allowed"
    case "block", "deny": return "Blocked"
    case "ask": return "Ask"
    case "muted": return "Muted only"
    default: return value
    }
  }
}

public struct SitePermissionEntry: Equatable, Identifiable, Sendable {
  public var feature: SiteFeature
  public var origin: String
  public var value: String
  public var key: String
  public var id: String { key }
}

public enum SitePermissions {
  public static let siteDefaultsPrefix = "serein.site."
  /// The one GateSettings key the `serein.site.` choices live under, as a map by their own key.
  public static let gateKey = "serein.sitePermissions"
  public static let mediaDefaultsPrefix = "serein.media."
  public static func origin(scheme: String, host: String, port: Int) -> String {
    let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    return "\(scheme)://\(host.lowercased())" + (port == 0 || defaultPort ? "" : ":\(port)")
  }
  public static func key(_ feature: SiteFeature, origin: String) -> String {
    (feature == .media ? mediaDefaultsPrefix : siteDefaultsPrefix + feature.rawValue + ".") + origin
  }
  public static func entry(forKey key: String, value: String) -> SitePermissionEntry? {
    if key.hasPrefix(mediaDefaultsPrefix) {
      let origin = String(key.dropFirst(mediaDefaultsPrefix.count))
      return origin.isEmpty
        ? nil : SitePermissionEntry(feature: .media, origin: origin, value: value, key: key)
    }
    guard key.hasPrefix(siteDefaultsPrefix) else { return nil }
    let rest = key.dropFirst(siteDefaultsPrefix.count)
    guard let dot = rest.firstIndex(of: "."), let feature = SiteFeature(rawValue: String(rest[..<dot])),
      feature != .media
    else { return nil }
    let origin = String(rest[rest.index(after: dot)...])
    return origin.isEmpty
      ? nil : SitePermissionEntry(feature: feature, origin: origin, value: value, key: key)
  }
  /// Entries found in a defaults dictionary, sorted by origin then feature. Values outside the
  /// feature's choices are ignored.
  public static func entries(in defaults: [String: Any]) -> [SitePermissionEntry] {
    defaults.compactMap { key, raw -> SitePermissionEntry? in
      guard let value = raw as? String, let entry = entry(forKey: key, value: value),
        entry.feature.choices.contains(value) || (entry.feature != .media && value == "allow")
          || (entry.feature != .media && value == "block")
      else { return nil }
      return entry
    }.sorted { ($0.origin, $0.feature.rawValue) < ($1.origin, $1.feature.rawValue) }
  }
  /// The key a location or notification choice is stored under, or nil when the request must
  /// be refused. Only the top-level page may ask: an embedded frame, even one allowed on its own
  /// site, gets nothing. The choice is keyed by the pair (top-level origin, requesting origin);
  /// since the two must match, it is stored under that one origin.
  public static func grantKey(topOrigin: String, requester: String, isMainFrame: Bool) -> String? {
    guard isMainFrame, !requester.isEmpty, topOrigin == requester else { return nil }
    return requester
  }
  /// Private tabs and agent tabs never get a site feature: everything is denied for them.
  public static func tabMayPrompt(isPrivate: Bool, isAgentTab: Bool) -> Bool {
    !isPrivate && !isAgentTab
  }
  /// Whether media may start playing without a gesture. The page script applies the same rule.
  public static func autoplayAllows(policy: String, muted: Bool, userHasActed: Bool) -> Bool {
    if userHasActed { return true }
    switch policy {
    case "allow": return true
    case "block": return false
    default: return muted
    }
  }
  /// At most `limit` notifications per origin in `window` seconds.
  public static func notificationAllowed(
    recent: [Date], now: Date = Date(), limit: Int = 5, window: TimeInterval = 60
  ) -> Bool {
    recent.filter { now.timeIntervalSince($0) < window }.count < limit
  }
}

/// A closed tab, kept so the start page can reopen the last few.
public struct ClosedTab: Codable, Equatable, Sendable {
  public var url: String
  public var title: String
  public init(url: String, title: String) {
    self.url = url
    self.title = title
  }
}

/// Tabs folded away from a group; they wait on the start page until restored.
public struct FoldedGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: String = UUID().uuidString
  public var name: String
  public var date: Date = Date()
  public var tabs: [ClosedTab]
  public init(name: String, tabs: [ClosedTab]) {
    self.name = name
    self.tabs = tabs
  }
}

public enum BrowserExtrasLogic {
  /// Newest first. The title is a known visit title, else the host, else the address.
  public static func closedTabs(_ urls: [String], titles: [String: String], limit: Int = 5)
    -> [ClosedTab]
  {
    urls.reversed().prefix(limit).map { url in
      let title = titles[PageIdentity.key(url)] ?? ""
      let host = URL(string: url)?.host ?? url
      return ClosedTab(
        url: url, title: title.trimmingCharacters(in: .whitespaces).isEmpty ? host : title)
    }
  }
  /// "1 download in progress" / "3 downloads in progress".
  public static func downloadsInProgress(_ count: Int) -> String {
    "\(count) download\(count == 1 ? "" : "s") in progress"
  }
  /// The main resource's text from a WebKit web archive (a property list): the bytes WebKit
  /// received, so View Source never requests the page again.
  public static func mainResourceText(_ archive: Data) -> String? {
    guard
      let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil)
        as? [String: Any],
      let main = plist["WebMainResource"] as? [String: Any],
      let data = main["WebResourceData"] as? Data
    else { return nil }
    var encoding = String.Encoding.utf8
    if let name = main["WebResourceTextEncodingName"] as? String {
      let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
      if cf != kCFStringEncodingInvalidId {
        encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
      }
    }
    return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
  }
  public static let sourceLimit = 400_000
  /// A read-only page for a page's source: escaped text in a `pre`, a policy that blocks every
  /// script, frame and request, and a note when the source was cut.
  public static func sourcePage(title: String, source: String, limit: Int = sourceLimit) -> String {
    func escape(_ s: String) -> String {
      s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    let cut = source.count > limit
    let shown = cut ? String(source.prefix(limit)) : source
    let note =
      cut
      ? "<p class=\"note\">Showing the first \(limit.formatted()) of \(source.count.formatted()) characters.</p>"
      : ""
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
      <title>\(escape("Source of " + title))</title>
      <style>body{margin:0;background:#060606;color:#e5e5e5;font:12.5px/1.5 ui-monospace,Menlo,monospace}
      .note{margin:0;padding:10px 16px;background:#101010;color:#a1a1a1;border-bottom:1px solid #222;font-family:-apple-system,system-ui,sans-serif}
      pre{margin:0;padding:16px;white-space:pre-wrap;word-break:break-all;tab-size:2}</style></head>
      <body>\(note)<pre>\(escape(shown))</pre></body></html>
      """
  }
}
