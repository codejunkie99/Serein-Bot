#if DEBUG
import Foundation
import SereinCore

/// The connected apps one assistant may use (`AssistantScope.apps`), the one-click catalog's
/// addresses, and the MCP Registry search's filter. Pure rules only: no network, no window.
extension AssistantCoreChecks {
  static func appAccess(_ check: Check) throws {
    try appAccessScope(check)
    try appAccessCatalog(check)
    try appAccessKeys(check)
    try appAccessRegistry(check)
  }

  private static func appAccessScope(_ check: Check) throws {
    typealias S = AssistantScope
    let gmail = S.composioAppKey("Gmail")
    let notion = S.connectionAppKey("app.notion")
    try check(gmail == "composio:gmail" && notion == "mcp:app.notion", "App keys name their kind and are lower case")

    let every = S(destinations: [.connectedApps])
    try check(every.apps == nil && every.allowsApp(gmail) && every.allowsApp(notion), "No list is every connected app")
    let some = S(destinations: [.connectedApps], apps: ["composio:GMAIL", "composio:gmail", "slack", "mcp:app.notion"])
    try check(some.apps == ["composio:gmail", "mcp:app.notion"], "A list keeps known kinds once each, in lower case")
    try check(some.allowsApp("COMPOSIO:gmail") && !some.allowsApp("composio:slack"), "A list allows only its apps")
    try check(!S(destinations: [.connectedApps], apps: []).allowsApp(gmail), "An empty list is no app")

    let person = S(destinations: [.web, .connectedApps])
    try check(S.effective(some, person: person).apps == some.apps, "The person's settings keep an assistant's list")
    try check(S.effective(every, person: person).apps == nil, "No list stays every app")
    try check(S.intersect(["composio:gmail", "mcp:app.notion"], ["composio:gmail"]) == ["composio:gmail"]
      && S.intersect(nil, ["composio:gmail"]) == ["composio:gmail"] && S.intersect(nil, nil) == nil,
      "Two lists narrow to the apps both allow")

    let decoder = JSONDecoder()
    func decoded(_ json: String) throws -> S { try decoder.decode(S.self, from: Data(json.utf8)) }
    try check(try decoded(#"{"destinations":["connectedApps"]}"#).apps == nil, "A scope saved before app lists is every app")
    try check(try decoded(#"{"destinations":["connectedApps"],"apps":["composio:gmail"]}"#).apps == ["composio:gmail"],
      "A saved list reads back")
    try check(try decoded(#"{"destinations":["connectedApps"],"apps":"gmail"}"#).apps == [],
      "A list that cannot be read is no app, never every app")
    let encoded = String(decoding: try JSONEncoder().encode(every), as: UTF8.self)
    try check(!encoded.contains("\"apps\""), "No list is not written, so an older build reads the same scope")
    try check(try decoder.decode(S.self, from: JSONEncoder().encode(some)) == some, "A list survives saving")

    let team = RelayTeam(
      profiles: [
        RelayProfile(id: "main", name: "Serein"),
        RelayProfile(id: "mail", name: "Mailer", scope: S(destinations: [.connectedApps], apps: [gmail, notion])),
        RelayProfile(id: "notes", name: "Notes", scope: S(destinations: [.connectedApps], apps: [notion])),
      ],
      activeID: "main")
    let reach = AskPolicy.reach(
      asker: team.profiles[2], target: team.profiles[1], team: team, person: person, turn: .assistant, personWords: nil)
    try check(!reach.full && reach.scope.apps == [notion], "A light ask uses only the apps both assistants may use")
    try check(S.appRefusal(name: "Mailer", app: "Slack").hasPrefix("Mailer can't use Slack."), "The refusal names the assistant and the app")
  }

  private static func appAccessCatalog(_ check: Check) throws {
    let all = ConnectorCatalog.all
    let addresses = all.compactMap { MCPServerConnection.address($0.url) }
    try check(addresses.count == all.count, "Every one-click app's address passes the connection address rule")
    let ids = addresses.compactMap(MCPServerConnection.id(for:))
    try check(ids.count == all.count && Set(ids).count == ids.count, "Every one-click app connects under its own plugin id")
    for category in ConnectorCatalog.Category.allCases {
      try check(all.contains { $0.category == category }, "Connect Apps shows at least one app in \(category.title)")
    }
  }

  private static func appAccessKeys(_ check: Check) throws {
    typealias C = ConnectorCatalog
    guard let github = C.find("GitHub")?.signIn.key, let slack = C.find("slack")?.signIn.key else {
      return try check(false, "GitHub and Slack connect with a token")
    }
    try check(C.find("HubSpot")?.signIn.composioApp == "hubspot" && C.find("hubspot")?.signIn.key == nil,
      "HubSpot connects through Composio, since its server takes only its own OAuth apps")
    try check(C.find("Notion")?.signIn == .browser, "An app with a browser sign-in keeps it")
    try check(github.page.hasPrefix("https://") && slack.page.hasPrefix("https://") && !github.steps.isEmpty && !slack.steps.isEmpty,
      "A token app says where to make the token, and how")

    let fineGrained = "github_pat_" + String(repeating: "A1b2", count: 20)
    try check(github.problem(fineGrained) == nil && github.problem("  ghp_" + String(repeating: "x", count: 36) + "\n") == nil,
      "Fine-grained and classic GitHub tokens fit, with spaces around them trimmed")
    try check(github.problem("") == "Paste the personal access token.", "An empty field asks for the token")
    try check(github.problem("github_pat_ abc def ghi jkl mno pqr")?.contains("without spaces") == true, "A token with spaces inside is refused")
    try check(github.problem("gho_" + String(repeating: "x", count: 36))?.contains("another app") == true,
      "A token GitHub gave another app is named as such")
    try check(github.problem("sk-" + String(repeating: "x", count: 40))?.contains("starts with github_pat_ or ghp_") == true,
      "A token of another service says what a GitHub token starts with")
    try check(github.problem("ghp_short")?.contains("whole") == true, "A cut-off token is refused")
    try check(github.problem("ghp_" + String(repeating: "é", count: 30)) != nil, "A token with characters no token has is refused")
    try check(slack.problem("xoxb-1-" + String(repeating: "x", count: 30))?.contains("bot token") == true,
      "A Slack bot token is named, with the token to copy instead")
    try check(slack.problem("xoxp-1-" + String(repeating: "x", count: 30)) == nil && slack.placeholder == "xoxp-…",
      "A Slack user token fits")
    try check(ConnectLink(app: "github", kind: .mcp)?.name == "GitHub", "The chat's one-click link names GitHub")
  }

  private static func appAccessRegistry(_ check: Check) throws {
    typealias R = MCPRegistry
    try check(R.searchURL("x") == nil && R.searchURL("  ") == nil, "One letter or nothing is not searched")
    try check(R.normalizedQuery("  lin\near   app ") == "lin ear app", "Search words go as one line")
    try check(R.searchURL("linear")?.absoluteString.contains("version=latest") == true, "The search asks for latest versions")
    func item(_ name: String, _ remotes: [[String: Any]], title: String? = nil, latest: Bool = true, status: String = "active")
      -> [String: Any]
    {
      var server: [String: Any] = ["name": name, "description": "Line one\nline\ttwo", "remotes": remotes]
      if let title { server["title"] = title }
      let official: [String: Any] = ["isLatest": latest, "status": status]
      let meta: [String: Any] = ["io.modelcontextprotocol.registry/official": official]
      return ["server": server, "_meta": meta]
    }
    func remote(_ url: String, type: String = "streamable-http", key: Bool = false) -> [String: Any] {
      let required: [String: Any] = ["name": "Authorization", "isRequired": true]
      let headers: [[String: Any]] = key ? [required] : []
      return ["type": type, "url": url, "headers": headers]
    }
    let answer: [String: Any] = ["servers": [
      item("io.github.someone/notion-tools", [remote("https://tools.example.dev/mcp", key: true)], title: "Notion Tools"),
      item("com.notion/mcp", [remote("https://mcp.notion.com/mcp")]),
      item("com.notion/old", [remote("https://old.notion.com/mcp")], latest: false),
      item("com.example/gone", [remote("https://gone.example.com/mcp")], status: "deleted"),
      item("com.example/template", [remote("https://{tenant}.example.com/mcp")]),
      item("com.example/plain", [remote("http://plain.example.com/mcp")]),
      item("com.example/query", [remote("https://q.example.com/mcp?key=1")]),
      item("com.example/local", [["type": "stdio"]]),
      item("com.example/sse-only", [remote("https://sse.example.com/sse", type: "sse")]),
      item("com.notion/claims", [remote("https://old.example.org/sse", type: "sse"), remote("https://notion-copy.example.org/mcp")]),
      item("com.notion/mcp-again", [remote("https://mcp.notion.com/mcp")]),
    ]]
    let servers = R.servers(from: try JSONSerialization.data(withJSONObject: answer))
    try check(servers.map(\.host) == ["mcp.notion.com", "tools.example.dev", "notion-copy.example.org"],
      "Only latest, active https remotes Serein can reach are kept, once each, the publisher's own first; an SSE remote is passed over")
    try check(servers[0].publisher == "notion.com" && servers[0].title == "notion.com" && servers[0].summary == "Line one line two",
      "A server at its publisher's own domain says so, and a bare name like mcp gives way to the domain")
    try check(servers[1].publisher == nil && servers[1].needsKey && servers[1].title == "Notion Tools",
      "A GitHub account's server is a community one, and a required header says it needs a key")
    try check(servers[2].publisher == nil, "A server that names notion.com but runs elsewhere is a community one")
    let many: [String: Any] = ["servers": (0..<50).map { item("com.example/s\($0)", [remote("https://s\($0).example.com/mcp")]) }]
    try check(R.servers(from: try JSONSerialization.data(withJSONObject: many)).count == R.resultLimit, "One search shows at most 30 servers")
    try check(R.servers(from: Data("not json".utf8)).isEmpty, "An unreadable answer shows nothing")
  }
}
#endif
