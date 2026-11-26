import Foundation

/// An app's MCP server connected by its address (the Marketplace (Your apps, On this Mac)), with no GitHub manifest:
/// Serein lists the server's tools, the person reviews every one on a card, and the result is a
/// local plugin manifest that goes through the same install, sign-in, session and gate paths as
/// any other plugin. Everything here is pure, so it is checked in SereinChecks.
public enum MCPServerConnection {
  /// How the connection signs in: the plugin system's OAuth 2.1 sign-in, a token the person
  /// pastes (kept in the Keychain), or nothing for a server that needs none.
  public enum Auth: String, Codable, Sendable { case oauth, token, none }

  /// The Keychain name of a pasted token, sent as the bearer token (the manifest's `mcp.token`).
  public static let tokenName = "API_TOKEN"
  /// The most tools one connection may turn on, as for any plugin manifest.
  public static let maxTools = 40

  /// An https address only, on a host name with a dot (never a raw IP address), with no user
  /// name, password, `?…` or `#…` in it, so no key in the address is ever stored or shown; the
  /// plugin system's endpoint rule decides the rest (`PluginManifest.Server.remoteURL`).
  public static func address(_ text: String) -> URL? {
    guard let url = PluginManifest.Server.remoteURL(text), url.scheme?.lowercased() == "https",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      let host = url.host, host.contains("."), !ConnectGate.isRawIP(host)
    else { return nil }
    return url
  }
  /// Why `address` refused a pasted text, in plain words.
  public static let addressHelp =
    "Paste the server’s https address, such as https://mcp.example.com/mcp, without its ?… part; add a key as a token instead."

  /// The local plugin id for an address: `app.` and the host's main name (mcp.notion.com is
  /// app.notion), so the tools Relay sees stay short (`app_notion__search`).
  public static func id(for url: URL) -> String? {
    guard let host = url.host?.lowercased() else { return nil }
    let labels = host.split(separator: ".").map(String.init)
    // mcp.notion.com → notion; x.example.co.uk → example-co-uk, as a two-letter second level
    // (co, ac, …) names no one.
    let key: String
    if labels.count >= 3, labels[labels.count - 2].count <= 2 {
      key = labels.suffix(3).joined(separator: "-")
    } else {
      key = labels.count >= 2 ? labels[labels.count - 2] : labels.first ?? ""
    }
    let slug = key.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? nil : "app." + slug
  }

  /// A tool's risk from its MCP annotations, never from its words: destructiveHint true is a
  /// delete (always asks), readOnlyHint true (a real boolean) is a read, anything else or
  /// nothing is a write (always asks). The gate can still raise it by the tool's name.
  public static func risk(_ tool: [String: Any]) -> PluginManifest.Risk {
    let hints = tool["annotations"] as? [String: Any] ?? [:]
    if hints["destructiveHint"] as? Bool == true { return .delete }
    if let readOnly = hints["readOnlyHint"] as? NSNumber, CFGetTypeID(readOnly) == CFBooleanGetTypeID(), readOnly.boolValue {
      return .read
    }
    return .write
  }

  /// The largest input schema a tool may have, as JSON, to be reviewed at all.
  public static let maxSchemaBytes = 16 * 1024

  /// The tools a server offers that can be reviewed at all: a name the plugin format accepts
  /// (whole, so no line break hides in it), an input schema up to 16 KB, once each, at most 200.
  /// Any other tool is never offered, so it is never called.
  public static func offered(_ tools: [[String: Any]]) -> [(name: String, tool: [String: Any])] {
    var seen = Set<String>()
    var out: [(name: String, tool: [String: Any])] = []
    for tool in tools where out.count < 200 {
      guard let name = tool["name"] as? String,
        name.range(of: "\\A[A-Za-z0-9_.-]{1,128}\\z", options: .regularExpression) != nil,
        jsonString(tool["inputSchema"] ?? ([:] as [String: Any])).utf8.count <= maxSchemaBytes,
        propertyNamesValid(tool["inputSchema"] ?? ([:] as [String: Any])),
        seen.insert(name).inserted
      else { continue }
      out.append((name, tool))
    }
    return out
  }

  /// A valid local tool name for a server's name: snake case, lowercase letters, digits and
  /// underscores, starting with a letter, up to 48 characters, never one already `taken`.
  public static func localName(_ server: String, taken: Set<String>) -> String {
    var name = server.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
    name = name.replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if name.first.map({ !("a"..."z").contains($0) }) ?? true { name = "tool_" + name }
    name = String(name.prefix(48))
    var candidate = name
    var n = 2
    while taken.contains(candidate) {
      let suffix = "_\(n)"
      candidate = String(name.prefix(48 - suffix.count)) + suffix
      n += 1
    }
    return candidate
  }

  /// One row of the review card.
  public struct ReviewTool: Identifiable, Equatable, Sendable {
    public var id: String { serverName }
    public let serverName: String
    /// The name Relay calls it by inside this connection.
    public let name: String
    public let risk: PluginManifest.Risk
    /// The server's own words: untrusted, shown fenced and verbatim, without invisible characters.
    public let description: String
    /// The input schema's parameters with their descriptions (the server's words too).
    public let parameters: [Parameter]
    /// The gate takes it as a read: read-rated, and neither name raises it.
    public let reads: Bool
    /// The schema and hints this review pins (`PluginSchemas.fingerprint(_:hints: true)`).
    public let fingerprint: String
    /// Not in the last review.
    public let isNew: Bool
    /// Its schema, description or hints differ from the last review.
    public let changed: Bool
    public var on: Bool
  }

  /// One parameter of a tool, as the review card lists it.
  public struct Parameter: Equatable, Sendable {
    public let name: String
    public let description: String
  }
  /// A schema's top-level properties, by name, each description cut to 200 characters.
  /// Every parameter the model is told about, at any depth, named by its path (`filter.status`,
  /// `items[].id`), each with its title and description as the model gets them (200 characters).
  public static func parameters(_ tool: [String: Any]) -> [Parameter] {
    var out: [Parameter] = []
    func words(_ schema: [String: Any]) -> String {
      ["title", "description"].compactMap { key -> String? in
        guard let text = schema[key] as? String else { return nil }
        let clean = PluginSchemas.visibleText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(200))
      }.joined(separator: " — ")
    }
    func walk(_ schema: [String: Any], _ path: String) {
      if let properties = schema["properties"] as? [String: Any] {
        for key in properties.keys.sorted() {
          let inner = properties[key] as? [String: Any] ?? [:]
          let named = path.isEmpty ? key : path + "." + key
          out.append(Parameter(name: named, description: words(inner)))
          walk(inner, named)
        }
      }
      if let items = schema["items"] as? [String: Any] { walk(items, path + "[]") }
      // Alternatives describe the same value in other shapes.
      for key in ["anyOf", "oneOf", "allOf"] {
        for alternative in schema[key] as? [[String: Any]] ?? [] { walk(alternative, path) }
      }
    }
    walk(tool["inputSchema"] as? [String: Any] ?? [:], "")
    return out
  }

  /// Every key of every `properties` object in a schema, at any depth, is a plain name of up to
  /// 64 characters, so no name carries instructions the review card would not show whole.
  public static func propertyNamesValid(_ schema: Any) -> Bool {
    if let object = schema as? [String: Any] {
      if let properties = object["properties"] as? [String: Any],
        !properties.keys.allSatisfy({ $0.range(of: "\\A[A-Za-z0-9_.-]{1,64}\\z", options: .regularExpression) != nil })
      {
        return false
      }
      return object.values.allSatisfy(propertyNamesValid)
    }
    if let array = schema as? [Any] { return array.allSatisfy(propertyNamesValid) }
    return true
  }

  /// The card's rows for what the server offers now. On a first review every tool starts on (up
  /// to `maxTools`) and the person switches tools off; on a later one a tool keeps its switch only
  /// when it is unchanged, so a new or changed tool is off until the person turns it on.
  public static func review(
    _ tools: [[String: Any]], previous: [PluginManifest.Tool]? = nil, reviewed: [String: String]? = nil
  ) -> [ReviewTool] {
    // Names the last review gave stay theirs; a new tool never takes one.
    var taken = Set(previous?.map { $0.name } ?? [])
    return offered(tools).enumerated().map { (index, entry) -> ReviewTool in
      let local = previous?.first { $0.serverName == entry.name }?.name ?? localName(entry.name, taken: taken)
      taken.insert(local)
      let fingerprint = PluginSchemas.fingerprint(entry.tool, hints: true)
      let pinned = reviewed?[entry.name]
      let isNew = reviewed != nil && pinned == nil
      let changed = pinned != nil && pinned != fingerprint
      let on = previous.map { kept in !changed && !isNew && kept.contains { $0.serverName == entry.name } }
        ?? (index < maxTools)
      let description = PluginSchemas.visibleText(entry.tool["description"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let rated = risk(entry.tool)
      let gate = PluginManifest.Tool(name: local, risk: rated, description: nil, remote: entry.name == local ? nil : entry.name)
      return ReviewTool(
        serverName: entry.name, name: local, risk: rated, description: String(description.prefix(600)),
        parameters: parameters(entry.tool),
        reads: ApprovalGate.pluginEffect(name: gate.gateName, declared: rated, effect: .read) == .read,
        fingerprint: fingerprint, isNew: isNew, changed: changed, on: on)
    }
  }

  /// What the person reviewed, every tool on or off: server name → fingerprint.
  public static func pins(_ tools: [ReviewTool]) -> [String: String] {
    Dictionary(tools.map { ($0.serverName, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
  }

  /// The tools a server offers now that the last review did not see as they are: new ones and
  /// ones whose schema or hints changed. Empty means the list is the one reviewed.
  /// A reviewed tool the server still names but that can no longer be offered (its schema grew
  /// past the cap, or a property name went bad) counts as changed too.
  public static func changes(_ tools: [[String: Any]], reviewed: [String: String]) -> [String] {
    let usable = offered(tools)
    let kept = Set(usable.map { $0.name })
    let changed = usable.filter { reviewed[$0.name] != PluginSchemas.fingerprint($0.tool, hints: true) }.map { $0.name }
    let dropped = tools.compactMap { $0["name"] as? String }.filter { reviewed[$0] != nil && !kept.contains($0) }
    return Array(Set(changed + dropped)).sorted()
  }

  /// The local manifest for the tools switched on, checked by `PluginManifest.decode` like any
  /// plugin's. It reaches only the address's host and none of the person's files. Its version
  /// is the manifest format's, as the tool list pinned at review is what changes.
  public static func manifest(id: String, name: String, address: URL, auth: Auth, tools: [ReviewTool]) throws -> Data {
    let on = tools.filter(\.on)
    guard !on.isEmpty else { throw SereinError.invalid("Turn on at least one tool, or cancel.") }
    guard on.count <= maxTools else {
      throw SereinError.invalid("At most \(maxTools) tools can be on at once. Switch \(on.count - maxTools) off.")
    }
    guard let host = address.host?.lowercased() else { throw SereinError.invalid("That address has no host.") }
    var server: [String: Any] = ["url": address.absoluteString]
    switch auth {
    case .oauth: server["auth"] = "oauth2"
    case .token:
      server["token"] = tokenName
      server["env"] = [tokenName]
    case .none: break
    }
    let object: [String: Any] = [
      "id": id, "name": String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)), "version": "1.0.0",
      "description": String("Connected by address: \(address.absoluteString)".prefix(300)),
      "mcp": server,
      "tools": on.map { tool -> [String: Any] in
        var entry: [String: Any] = ["name": tool.name, "risk": tool.risk.rawValue]
        if tool.serverName != tool.name { entry["remote"] = tool.serverName }
        return entry
      },
      "permissions": ["network": [host], "files": "none"],
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    _ = try PluginManifest.decode(data)
    return data
  }

  /// Official remote MCP servers, each address as its vendor documents it (checked 2026-10-27).
  public struct KnownServer: Equatable, Sendable {
    public let name: String
    public let address: String
  }
  public static let known: [KnownServer] = [
    // https://developers.notion.com/docs/get-started-with-mcp
    KnownServer(name: "Notion", address: "https://mcp.notion.com/mcp"),
    // https://linear.app/docs/mcp
    KnownServer(name: "Linear", address: "https://mcp.linear.app/mcp"),
    // https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp/set-up-the-github-mcp-server
    KnownServer(name: "GitHub", address: "https://api.githubcopilot.com/mcp/"),
    // https://support.atlassian.com/atlassian-rovo-mcp-server/docs/getting-started-with-the-atlassian-remote-mcp-server/
    KnownServer(name: "Atlassian", address: "https://mcp.atlassian.com/v2/mcp"),
    // https://mcp.sentry.dev/ (where https://docs.sentry.io/product/sentry-mcp/ leads)
    KnownServer(name: "Sentry", address: "https://mcp.sentry.dev/mcp"),
    // https://developers.asana.com/docs/using-asanas-mcp-server
    KnownServer(name: "Asana", address: "https://mcp.asana.com/v2/mcp"),
    // https://docs.stripe.com/mcp
    KnownServer(name: "Stripe", address: "https://mcp.stripe.com"),
  ]
  /// The name to show for an address: a known server's, else its host.
  public static func name(for url: URL) -> String {
    known.first { address($0.address)?.absoluteString == url.absoluteString }?.name ?? (url.host ?? url.absoluteString)
  }
}
