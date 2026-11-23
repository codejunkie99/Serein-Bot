import Foundation

/// The official MCP Registry (registry.modelcontextprotocol.io): servers anyone can publish, found
/// when the person asks Connect Apps to search it. Only servers with a remote Serein can reach are
/// kept: the latest active version, a streamable-http or sse remote whose address passes
/// `MCPServerConnection.address` (https, a host name, no `?…` part) and has no `{…}` to fill in.
/// Nobody has reviewed these servers, so every row says so and names the address's host, and
/// connecting one goes through Add an MCP Server's full review. Servers whose publisher is the
/// address's own domain come first; the rest keep the registry's order.
public enum MCPRegistry {
  public static let base = "https://registry.modelcontextprotocol.io/v0/servers"
  /// The most rows one search shows.
  public static let resultLimit = 30
  public static let queryLimit = 80
  /// The registry's own page size; filtering keeps fewer.
  static let pageSize = 100

  public struct Server: Equatable, Sendable, Identifiable {
    /// The registry's reverse-DNS name, such as `app.linear/linear`.
    public let name: String
    /// What the row shows: the server's title, else the last part of its name.
    public let title: String
    /// One line from the server's own description.
    public let summary: String
    /// The remote's https address.
    public let url: String
    /// The address's host, shown on every row, since the name can claim anything.
    public let host: String
    /// The remote names headers it requires (often a key), so a sign-in alone may not be enough.
    public let needsKey: Bool
    /// The domain that published it, when the registry name's namespace (which the registry checks
    /// against that domain) is the address's own domain: `com.notion/mcp` at mcp.notion.com is
    /// notion.com. nil for anyone else, such as a server about Notion run by someone else.
    public let publisher: String?
    public var id: String { url }
  }

  /// Search words as they are sent: trimmed, one line, at most `queryLimit` characters.
  public static func normalizedQuery(_ raw: String) -> String {
    let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    return String(words.prefix(queryLimit))
  }

  /// The search request for `raw`, or nil when there is nothing to search for.
  public static func searchURL(_ raw: String) -> URL? {
    let query = normalizedQuery(raw)
    guard query.count >= 2 else { return nil }
    var components = URLComponents(string: base)
    components?.queryItems = [
      URLQueryItem(name: "search", value: query),
      URLQueryItem(name: "version", value: "latest"),
      URLQueryItem(name: "limit", value: String(pageSize)),
    ]
    return components?.url
  }

  /// The servers in one answer of `GET /v0/servers`, filtered and de-duplicated by address, at
  /// most `resultLimit`. Anything unreadable is left out, never guessed.
  public static func servers(from data: Data) -> [Server] {
    let found = listed(data)
    return found.filter { $0.publisher != nil } + found.filter { $0.publisher == nil }
  }
  static func listed(_ data: Data) -> [Server] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = root["servers"] as? [[String: Any]]
    else { return [] }
    var seen = Set<String>()
    var kept: [Server] = []
    for item in items {
      guard kept.count < resultLimit, let server = item["server"] as? [String: Any], current(item) else { continue }
      guard let name = (server["name"] as? String).map(oneLine), !name.isEmpty,
        let remote = reachableRemote(server["remotes"]), seen.insert(remote.url).inserted
      else { continue }
      let publisher = publisherDomain(name).flatMap { domain in
        remote.host == domain || remote.host.hasSuffix("." + domain) ? domain : nil
      }
      let titled = (server["title"] as? String).map(oneLine) ?? ""
      let last = String(name.split(separator: "/").last ?? Substring(name))
      let generic = ["mcp", "server", "mcp-server", "remote", "api"].contains(last.lowercased())
      let title = !titled.isEmpty ? titled : generic ? (publisher ?? remote.host) : last
      kept.append(
        Server(
          name: String(name.prefix(120)), title: String(title.prefix(60)),
          summary: String(oneLine(server["description"] as? String ?? "").prefix(200)),
          url: remote.url, host: remote.host, needsKey: remote.needsKey, publisher: publisher))
    }
    return kept
  }

  /// The domain a reverse-DNS registry name stands for: `com.notion/mcp` is notion.com. nil for a
  /// GitHub namespace (`io.github.someone`), which names an account, not a domain.
  static func publisherDomain(_ name: String) -> String? {
    guard let namespace = name.split(separator: "/").first?.lowercased(), !namespace.hasPrefix("io.github.") else {
      return nil
    }
    let labels = namespace.split(separator: ".").map(String.init)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil })
    else { return nil }
    return labels.reversed().joined(separator: ".")
  }

  /// Latest and active, when the registry says; a listing without that metadata counts as current.
  static func current(_ item: [String: Any]) -> Bool {
    guard let meta = (item["_meta"] as? [String: Any])?["io.modelcontextprotocol.registry/official"] as? [String: Any]
    else { return true }
    if meta["isLatest"] as? Bool == false { return false }
    if let status = meta["status"] as? String, status.lowercased() != "active" { return false }
    return true
  }

  /// The first remote Serein can connect to, by its own address rule. Streamable HTTP only:
  /// `PluginSession.runRemote` does not read an SSE server's `endpoint` event.
  static func reachableRemote(_ raw: Any?) -> (url: String, host: String, needsKey: Bool)? {
    for remote in raw as? [[String: Any]] ?? [] {
      guard let type = remote["type"] as? String, type.lowercased() == "streamable-http",
        let text = remote["url"] as? String, !text.contains("{"), !text.contains("}"),
        let url = MCPServerConnection.address(text), let host = url.host?.lowercased()
      else { continue }
      let headers = remote["headers"] as? [[String: Any]] ?? []
      let needsKey = headers.contains { $0["isRequired"] as? Bool == true }
      return (url.absoluteString, host, needsKey)
    }
    return nil
  }

  /// One line of plain text: control characters and runs of space become one space.
  static func oneLine(_ text: String) -> String {
    let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
    return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
  }
}
