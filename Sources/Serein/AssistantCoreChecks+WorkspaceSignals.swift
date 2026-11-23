#if DEBUG
import Foundation
import SereinCore

/// Which workspaces a person's chats lean on (WorkspaceSignals.swift), and what Serein offers to
/// connect from that. Synthetic chat text only.
extension AssistantCoreChecks {
  static func workspaceSignals(_ check: Check) throws {
    typealias W = WorkspaceSignals
    let claudeChat = #"""
      {"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__claude_ai_Notion__notion-search","input":{"query":"roadmap"}}]}}
      {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cd web && vercel deploy --prod"}}]}}
      {"type":"user","message":{"content":"see https://www.notion.so/acme/Roadmap-123 and https://www.notion.so/acme/Roadmap-123"}}
      """#
    let hits = W.count(claudeChat)
    try check(hits["Notion"] == 2, "An MCP tool and a link to the site both count for Notion; the same link twice counts once")
    try check(hits["Vercel"] == 1, "A shell command past cd counts for its command-line tool")
    try check(hits["GitHub"] == nil, "A workspace the chat never touches is not counted")

    // As Codex writes them: a parsed command, and a tool call's arguments as escaped JSON.
    let codexChat = #"{"parsed_cmd":[{"type":"unknown","cmd":"gh pr create --fill"}]} {"arguments":"{\"cmd\":\"FOO=1 npx vercel env pull\"}"}"#
    let codexHits = W.count(codexChat)
    try check(codexHits["GitHub"] == 1, "Codex's cmd is read as a command too")
    try check(codexHits["Vercel"] == 1, "Environment settings and npx are looked past to the real command")
    try check(W.count(#"{"command":"echo vercel is great"}"#)["Vercel"] == nil, "A word inside a command's arguments is not the command")
    try check(W.count("https://notvercel.com.evil.example/x")["Vercel"] == nil, "A look-alike host is not the app's site")

    let json = Data(#"{"mcpServers":{"linear":{"command":"x","env":{"KEY":"secret"}}},"projects":{"/p":{"mcpServers":{"github":{}}}}}"#.utf8)
    let names = W.configuredServers(json: json)
    try check(names == ["github", "linear"], "Server names come from the app's settings at any depth")
    try check(!names.joined().contains("secret"), "A server's keys and environment are never read out")
    let toml = "[mcp_servers.notion]\ncommand = \"npx\"\n[mcp_servers.\"supabase\"]\n[other]\n"
    try check(W.configuredServers(toml: toml) == ["notion", "supabase"], "Codex's mcp_servers tables are found")
    try check(W.workspaces(forServers: ["claude_ai_Gmail", "my-linear"]).sorted() == ["Gmail", "Linear"],
      "A server's name points to its workspace")

    let suggested = W.suggestions(chats: ["Notion": 9, "Vercel": 4, "Slack": 1, "GitHub": 12], configured: ["Linear"],
                                  connected: ["GitHub"])
    try check(suggested.map(\.name) == ["Notion", "Vercel", "Linear"],
      "Offers go most chats first, set-up apps count, one chat is not enough, and a connected app is not offered")
    try check(W.suggestions(chats: Dictionary(uniqueKeysWithValues: W.known.map { ($0.name, 5) }), configured: [], connected: []).count == 4,
      "At most four apps are offered at once")
    for workspace in W.known {
      try check(ConnectCatalog.resolve(workspace.name) != nil, "\(workspace.name) is a name connect_app understands")
    }

    let big = Data(repeating: 65, count: W.readLimit * 3)
    try check(W.sample(big).utf8.count <= W.readLimit + 1, "A long chat is read by its start and end only")

    // One-click apps (ConnectorCatalog): found by name or another word, linked with no key.
    typealias C = ConnectorCatalog
    try check(C.find("Notion")?.id == "notion" && C.find("notion app")?.id == "notion", "An app is found by its name, with or without “app”")
    try check(C.find("Gmail") == nil && C.macFallback["gmail"] == "mail" && C.macFallback["google calendar"] == "calendar",
      "Gmail and Google Calendar go through the Mac's Mail and Calendar until Serein has its own Google sign-in")
    try check(Set(C.all.map(\.id)).count == C.all.count && C.all.allSatisfy { $0.url.hasPrefix("https://") && URL(string: $0.url) != nil },
      "Every one-click app has its own id and an https server address")
    try check(ConnectLink(app: "notion", kind: .mcp)?.name == "Notion" && ConnectLink(app: "not-a-connector", kind: .mcp) == nil,
      "A chat's one-click link names a catalog app and nothing else")
    for name in ["Notion", "Linear", "Vercel", "Figma", "Supabase", "Stripe", "Sentry", "Asana", "Dropbox"] {
      try check(C.find(name) != nil, "A workspace the chats use, \(name), connects in one click")
    }
  }
}
#endif