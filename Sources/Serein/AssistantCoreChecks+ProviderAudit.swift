#if DEBUG
import Foundation
import SereinCore

/// The Cursor, Gemini CLI and Pi fixes from the provider audit: what Serein reads before it lets
/// Cursor run, what it sends each app, and how it reads what they answer.
extension AssistantCoreChecks {
  static func providerAudit(_ check: Check) throws {
    try cursorPreflight(check)
    try cursorSession(check)
    try gemini(check)
    try pi(check)
  }

  /// Pi and Oh My Pi: their model lists, flags and retries.
  private static func pi(_ check: Check) throws {
    let omp = HarnessParse.ohMyPiModels("""
      {"models":[
        {"provider":"anthropic","id":"claude-fixture","selector":"anthropic/claude-fixture","name":"Claude Fixture","thinking":["off","low","medium","high","max"]},
        {"provider":"openai","id":"gpt-fixture","selector":"openai/gpt-fixture","name":"GPT Fixture","thinking":null}]}
      """)
    try check(
      omp.map(\.id) == ["anthropic/claude-fixture", "openai/gpt-fixture"] && omp.map(\.name) == ["Claude Fixture", "GPT Fixture"]
        && omp.first?.effortLevels == ["off", "low", "medium", "high", "max"] && omp.last?.effortLevels == []
        && omp.filter(\.isDefault).map(\.id) == ["anthropic/claude-fixture"],
      "Oh My Pi's models come from its JSON list: its selector, its name, each model's own thinking levels, the first as default")
    try check(
      HarnessParse.ohMyPiModels("error: unknown flag --list-models").isEmpty && HarnessParse.ohMyPiModels("").isEmpty,
      "An Oh My Pi answer that is not its JSON list offers no models")

    let listed = """
      provider   model            context  max-out  thinking  images
      anthropic  claude-fixture   200K     64K      yes       yes
      openai     gpt-fixture      400K     128K     no        yes
      """
    let own = HarnessParse.piOwnModel(Data(#"{"defaultProvider":"openai","defaultModel":"gpt-fixture","theme":"dark"}"#.utf8))
    func defaults(_ own: String?) -> [String] { HarnessParse.piModels(listed, own: own).filter(\.isDefault).map(\.id) }
    try check(
      own == "openai/gpt-fixture" && defaults(own) == ["openai/gpt-fixture"],
      "Pi's default model is the one its own settings name")
    try check(
      defaults(nil) == ["anthropic/claude-fixture"] && defaults("openai/gone") == ["anthropic/claude-fixture"]
        && HarnessParse.piOwnModel(Data(#"{"defaultModel":"gpt-fixture"}"#.utf8)) == nil && HarnessParse.piOwnModel(nil) == nil,
      "Pi's first listed model is the default when its settings name none, or one the list lacks")
    try check(
      HarnessParse.piModels(listed).allSatisfy { !$0.id.isEmpty && !$0.name.lowercased().contains("default") }
        && HarnessParse.piModels("").isEmpty,
      "Pi's list holds only models Pi lists: no placeholder row, and nothing when Pi lists nothing")

    let oldPi = "/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"
    let newPi = "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
    try check(
      HarnessCommands.piOldPackage(oldPi) && !HarnessCommands.piOldPackage(newPi) && !HarnessCommands.piOldPackage(nil),
      "Pi from the package it left is due an update; Pi from its current package is not")
    try check(
      HarnessCommands.update(.pi, installedAt: oldPi).display.contains("npm install -g @earendil-works/pi-coding-agent")
        && HarnessCommands.update(.pi, installedAt: newPi).display == HarnessDriver.pi.updateCommand,
      "That update swaps the npm package, which Pi's own update command cannot do")
  }

  /// Gemini CLI: whose tool a permission request is for, and which start errors mean signed out.
  private static func gemini(_ check: Check) throws {
    func request(_ title: String, server: String?) -> [String: Any] {
      var call: [String: Any] = ["toolCallId": "t", "title": title, "kind": "other"]
      if let server { call["_meta"] = ["gemini-cli": ["mcp": ["server_name": server, "tool_name": "read_page"]]] }
      return ["toolCall": call, "options": []]
    }
    func kind(_ title: String, server: String? = nil) -> HarnessPermissionRequest.Kind? {
      let params = request(title, server: server)
      return ACPMessages.permissionRequest(params).map {
        HarnessPermissionRequest.geminiKind($0.request.kind, title: $0.request.title, server: ACPMessages.geminiServer(params))
      }
    }
    try check(
      kind("read_page (serein_browser MCP Server) {\"url\":\"https://example.com\"}", server: "serein_browser") == .browser
        && kind("read_page", server: "serein_browser") == .browser,
      "A Gemini tool call that Gemini itself places on Serein's server is Serein's browser, whatever its title says")
    try check(
      kind("serein_browser__read_page", server: "files") != .browser
        && kind("read_page (serein_browser MCP Server)", server: "generic_server") != .browser,
      "A tool on another server is never Serein's browser, even when its title names Serein's server")
    try check(
      kind("serein_browser__read_page") == .browser && kind("mcp__serein_browser__read_page") == .browser
        && kind("read_page (serein_browser MCP Server)") == .other && kind("files__serein_browser__x") != .browser,
      "An older Gemini CLI that names no server is judged by its title, which must start with Serein's server")

    func signedIn(_ message: String) -> Bool? {
      HarnessParse.geminiSession(["code": -32000, "message": message] as [String: Any]).auth.signedIn
    }
    try check(
      signedIn("Authentication required.") == false && signedIn("Gemini API key is missing or not configured.") == false,
      "Gemini CLI is signed out when its start error asks for sign-in or a key")
    for message in [
      "request to https://oauth2.googleapis.com/token failed, reason: getaddrinfo ENOTFOUND oauth2.googleapis.com",
      "Quota exceeded for quota metric 'Requests' of service 'cloudcode-pa.googleapis.com'", "fetch failed",
    ] {
      try check(
        signedIn(message) == nil && !HarnessParse.acpNeedsSignIn(code: -32000, message: message, driver: .gemini),
        "A Gemini start error that is not about sign-in leaves it signed in as far as Serein knows: \(message.prefix(30))")
    }
    try check(
      HarnessParse.acpNeedsSignIn(code: -32000, message: "Missing session")
        && HarnessParse.acpNeedsSignIn(code: -32000, message: "Missing session", driver: .cursor),
      "For the other ACP apps the protocol's own code still means signed out")
    try check(
      SlashCommands.docs(.gemini).hasSuffix("/docs/reference/commands.md"),
      "Gemini CLI's command reference opens where its repository keeps it now")
  }

  /// How Serein reads Cursor's models and their reasoning option.
  private static func cursorSession(_ check: Check) throws {
    func meta(_ driver: HarnessDriver?) -> [String: Any]? {
      (ACPMessages.initialize(driver)["clientCapabilities"] as? [String: Any])?["_meta"] as? [String: Any]
    }
    try check(
      meta(.cursor)?["parameterizedModelPicker"] as? Bool == true && meta(.gemini) == nil && meta(nil) == nil,
      "Cursor is told Serein reads models with their options, so it accepts the ids it lists; no other app is told so")
    let listed = HarnessParse.cursorModels([
      "models": [[
        "value": "gpt-fixture", "name": "GPT Fixture",
        "configOptions": [[
          "id": "thinking", "name": "Thinking", "category": "thought_level", "currentValue": "medium",
          "options": [["value": "low", "name": "Low"], ["value": "medium", "name": "Medium"], ["value": "high", "name": "High"]],
        ]],
      ]]
    ])
    let effort = listed.first?.option("effort")
    try check(
      effort?.nativeID == "thinking" && listed.first?.effortLevels == ["low", "medium", "high"] && effort?.defaultValue == "medium",
      "Cursor's reasoning option keeps Cursor's own id beside the name Serein uses for every app")
    let saved = try JSONDecoder().decode(
      HarnessOption.self, from: Data(#"{"id":"effort","label":"Reasoning","kind":"select","choices":[],"defaultValue":""}"#.utf8))
    try check(saved.nativeID == nil && saved.id == "effort", "A model list saved before the option id was kept still loads")
  }

  /// Every file Cursor follows is read from a made-up home, never from this Mac's own settings.
  private static func cursorPreflight(_ check: Check) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("serein-cursor-preflight-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: root) }
    let home = root + "/home", repo = root + "/repo", project = repo + "/app"
    for folder in [home, repo + "/.git", project] { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    var environment: [String: String] = [:]
    func problem(project: String? = nil) -> String {
      CursorPreflight.problem(home: home, environment: environment, project: project, systemHooks: root + "/system/hooks.json") ?? ""
    }
    /// The refusal while `path` holds `text`; the file is gone again afterwards.
    func refusal(_ path: String, _ text: String, project: String? = nil) throws -> String {
      try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      try text.write(toFile: path, atomically: true, encoding: .utf8)
      defer { try? fm.removeItem(atPath: path) }
      return problem(project: project)
    }
    let hooks = #"{"hooks":{"beforeShellExecution":[{"command":"./audit.sh"}]}}"#
    let config = home + "/.cursor/cli-config.json"

    try check(problem(project: project).isEmpty, "Cursor with no settings files is allowed")
    try check(
      try refusal(config, #"{"approvalMode":"allowlist","autoAcceptWebSearch":true,"permissions":{"allow":["Read(**)","Shell(ls -la)"]}}"#).isEmpty
        && (try refusal(home + "/.cursor/hooks.json", #"{"hooks":{"stop":[]}}"#).isEmpty),
      "Cursor stays allowed with its default approval mode, read-only allow rules and a hooks file that lists no hook")
    for mode in ["unrestricted", "auto-run"] {
      try check(
        try refusal(config, "{\"approvalMode\":\"\(mode)\"}").contains("approvalMode"),
        "Cursor is refused when its approval mode is \(mode): only allowlist asks before every command")
    }
    try check(
      try refusal(config, #"{"permissions":{"allow":["Shell(echo $(date))"]}}"#).contains("allow list"),
      "A Cursor allow rule that can expand into another command is refused")

    for (path, name) in [
      (home + "/.cursor/hooks.json", "~/.cursor/hooks.json"),
      (home + "/.cursor/managed/active-team-hooks/hooks.json", "active-team-hooks"),
      (root + "/system/hooks.json", "/system/hooks.json"),
      (home + "/.claude/settings.json", "~/.claude/settings.json"),
    ] {
      try check(try refusal(path, hooks).contains(name), "Cursor is refused while \(name) holds hooks, and the reason names the file")
    }
    try check(
      try refusal(home + "/.claude/settings.json", #"{"permissions":{"allow":["Read(./docs)","Bash(ls)"]}}"#).isEmpty
        && (try refusal(home + "/.claude/settings.json", #"{"permissions":{"allow":["Bash(npm run:*)"]}}"#).contains("Bash(npm run:*)")),
      "Claude Code's allow rules count for Cursor: read-only ones pass, one that runs commands refuses")
    try check(
      try refusal(home + "/.cursor/permissions.json", "// kept by the app\n{\"TerminalAllowlist\":[\"ls\"]}").contains("permissions.json")
        && (try refusal(home + "/.cursor/permissions.json", #"{"mcpAllowlist":["files:*"]}"#).contains("permissions.json"))
        && (try refusal(home + "/.cursor/permissions.json", #"{"mcpAllowlist":[],"terminalAllowlist":[]}"#).isEmpty),
      "Any entry in Cursor's permissions.json refuses, whatever the case of its keys; empty lists do not")
    try check(
      try refusal(home + "/.cursor/hooks.json", "{ \"hooks\": ").contains("could not read"),
      "A Cursor settings file that is not valid JSON refuses, because Cursor may still follow it")

    let installed = home + "/.claude/plugins/installed_plugins.json"
    try fm.createDirectory(atPath: home + "/.claude/plugins", withIntermediateDirectories: true)
    try #"{"version":2,"plugins":{"tools@market":[{"scope":"user","installPath":"/x"}]}}"#.write(toFile: installed, atomically: true, encoding: .utf8)
    try check(
      try refusal(home + "/.claude/settings.json", #"{"enabledPlugins":{"tools@market":true}}"#).contains("plugins")
        && (try refusal(home + "/.claude/settings.json", #"{"enabledPlugins":{"tools@market":false}}"#).isEmpty),
      "Cursor is refused while a Claude Code plugin is installed and turned on, and allowed once it is turned off")
    try fm.removeItem(atPath: installed)
    try check(
      try refusal(home + "/.claude/settings.json", #"{"enabledPlugins":{"tools@market":true}}"#).isEmpty,
      "A plugin switch with no plugin installed does not refuse Cursor")
    let local = home + "/.cursor/plugins/local"
    try check(
      try refusal(local + "/router.tgz", "x").isEmpty && (try refusal(local + "/router/plugin.json", "{}").contains("plugins/local")),
      "Cursor is refused while its own plugins folder holds a plugin; a stray file there is not one")
    try fm.removeItem(atPath: local + "/router")

    // Project files count only for a turn in that project, and the repository root counts too.
    for path in [project + "/.cursor/hooks.json", project + "/.claude/settings.json", repo + "/.claude/settings.local.json"] {
      try check(
        try !refusal(path, hooks, project: project).isEmpty && (try refusal(path, hooks).isEmpty),
        "Cursor is refused in a project whose \(path.dropFirst(repo.count + 1)) holds hooks, and only there")
    }
    try check(
      try refusal(project + "/.cursor/mcp.json", #"{"mcpServers":{"files":{"command":"x"}}}"#, project: project).contains("files"),
      "Cursor is refused in a project that adds its own MCP servers")

    // CURSOR_CONFIG_DIR moves cli-config.json and permissions.json; hooks stay in ~/.cursor.
    environment["CURSOR_CONFIG_DIR"] = root + "/moved"
    try check(
      try refusal(root + "/moved/cli-config.json", #"{"approvalMode":"unrestricted"}"#).contains("approvalMode")
        && (try refusal(config, #"{"approvalMode":"unrestricted"}"#).isEmpty)
        && (try refusal(home + "/.cursor/hooks.json", hooks).contains("hooks")),
      "With CURSOR_CONFIG_DIR set, Cursor's approval mode is read from that folder and its hooks still from ~/.cursor")

    let auto = HarnessGrant(mode: "project", edits: true, permission: .auto)
    try check(
      HarnessPermissions.cursorFlags(auto).isEmpty
        && HarnessPermissions.cursorFlags(HarnessGrant(mode: "project", edits: true, permission: .fullAccess)) == ["--force"],
      "Cursor gets no flag for Auto, because it has none; Full access alone adds --force")
  }
}
#endif
