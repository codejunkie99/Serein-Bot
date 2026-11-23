import Foundation

/// Air traffic control (Meridian's link routing): a project claims the links of the sites it
/// belongs to. A claimed link is never refused — routing only decides where a link belongs —
/// so the browser opens it in the background and offers the project, instead of yanking the
/// user off the page they were reading. Pure, so it is checked in SereinChecks.
public enum AirTraffic {
  /// The first project whose routes claim this host.
  public static func route(host: String?, projects: [Project]) -> Project? {
    guard let host = normalize(host), !host.isEmpty else { return nil }
    return projects.first { project in
      (project.routes ?? []).contains { PluginSession.hostMatches(host, $0) }
    }
  }

  public static func route(url: URL?, projects: [Project]) -> Project? {
    guard let url, let host = url.host, url.scheme == "https" || url.scheme == "http" else {
      return nil
    }
    return route(host: host, projects: projects)
  }

  /// Hosts compare lowercased and bare: no port, no "www." — "www.GitHub.com:443" and
  /// "github.com" are one site.
  public static func normalize(_ host: String?) -> String? {
    guard var host = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
      !host.isEmpty
    else { return nil }
    if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    return host.isEmpty ? nil : host
  }

  /// What the user typed into the routes field, as patterns: comma (or newline) separated,
  /// each trimmed, ports and "www." stripped, empties out. One host ("github.com") matches
  /// only itself; a leading "*." ("*.github.com") matches its subdomains.
  public static func parse(_ raw: String) -> [String] {
    raw
      .components(separatedBy: CharacterSet(charactersIn: ",\n"))
      .map { entry in
        var host = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("https://") || host.hasPrefix("http://") {
          host = String(host.dropFirst(host.hasPrefix("https://") ? 8 : 7))
        }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host
      }
      .filter { !$0.isEmpty }
  }

  /// The routes back for the field: one line, comma-separated.
  public static func text(_ routes: [String]?) -> String {
    (routes ?? []).joined(separator: ", ")
  }
}
