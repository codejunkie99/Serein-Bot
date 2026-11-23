#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// Driven by scripts/verify_direct_http.py with a loopback provider and a synthetic tool host.
enum DirectHTTPProbe {
  @MainActor static func run(port: Int, capabilityFile: String) async throws {
    let schema: [String: Any] = ["type": "object", "properties": ["x": ["$ref": "#/$defs/field"]],
      "$defs": ["field": ["type": "string", "description": String(repeating: "a", count: 14_000)]]]
    func schemaFor(sizeLimited: Bool) throws -> [String: Any] {
      let fitted = try DirectHTTPCompatibility.fittedTools([["function": ["parameters": schema]]], sizeLimited: sizeLimited)
      return (fitted.first?["function"] as? [String: Any])?["parameters"] as? [String: Any] ?? [:]
    }
    let parameters = try schemaFor(sizeLimited: true)
    guard try JSONSerialization.data(withJSONObject: parameters).count <= 12_000,
      let fields = parameters["properties"] as? [String: [String: Any]], fields["x"]?["type"] as? String == "string" else {
      throw SereinError.invalid("Moonshot tool schema exceeds its cap or lost the referenced field.")
    }
    let whole = try schemaFor(sizeLimited: false)
    guard whole["$defs"] == nil, let field = (whole["properties"] as? [String: [String: Any]])?["x"],
      field["$ref"] == nil, (field["description"] as? String)?.count == 14_000 else {
      throw SereinError.invalid("A schema reference was not resolved whole for a host with no size cap.")
    }
    for text in [#"{"name":"tabs","arguments":{}}"#, #"{"name":"tabs","parameters":{"limit":2}}"#, #"{"name":"tabs","arguments":"{\"limit\":2}"}"#,
                 "```json\n{\"name\":\"tabs\",\"arguments\":{}}\n```",
                 "<tool_call><function=tabs><parameter=limit>2</parameter></function></tool_call>"] {
      guard DirectHTTPCompatibility.localCall(text)?.name == "tabs", DirectHTTPCompatibility.localCall("Example: " + text) == nil else {
        throw SereinError.invalid("Local tool recovery misread a call envelope.")
      }
    }
    let keys = ["GEMINI_API_KEY": "fixture-gemini", "CURSOR_API_KEY": "fixture-cursor"]
    guard CredentialEnv.build(inherited: keys, own: [:], driver: .gemini) == ["GEMINI_API_KEY": "fixture-gemini"],
      CredentialEnv.build(inherited: keys, own: [:], driver: nil).isEmpty else { throw SereinError.invalid("CLI key isolation failed.") }
    let engines = Engines()
    let entry = ProviderEntry("fixture", "Fixture", .local, "http://127.0.0.1:\(port)/v1", keyless: true)
    // Exercise the same store and route preparation that the model picker uses, in an isolated library.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(root: root)
    let agents = root.appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let legacy: [String: Any] = ["model": "org/model", "endpoint": entry.baseURL, "enabled": true]
    try JSONSerialization.data(withJSONObject: legacy).write(to: agents.appendingPathComponent("local-model.json"))
    let config = root.appendingPathComponent(".cursor")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let configured = config.appendingPathComponent("mcp.json")
    try Data(#"{"mcpServers":{"fixture":{"command":"false"}}}"#.utf8).write(to: configured)
    guard CursorPreflight.problem(home: root.path, systemHooks: "/dev/null-missing") != nil,
      CursorPreflight.problem(home: root.path, systemHooks: "/dev/null-missing", isolated: true) == nil else {
      throw SereinError.invalid("Cursor preflight ignored the launch isolation state.")
    }
    let cursorRequest = TurnRequest(thread: ThreadKey("cursor-test"), cli: .cursor, executable: URL(fileURLWithPath: "/bin/cat"),
      access: .project(folder: root, level: .full), prompt: TurnPrompt(stable: "", volatile: "", message: "fixture", recovery: nil),
      model: nil, effort: nil, resume: nil, browser: nil, taskID: "fixture")
    var directoryRequest = cursorRequest
    let pluginFile = root.appendingPathComponent("fixture-plugins.json")
    let plugins = (0..<140).map { ["name": "fixture__tool" + String($0), "inputSchema": ["type": "object"]] as [String: Any] }
    try JSONSerialization.data(withJSONObject: plugins).write(to: pluginFile)
    directoryRequest.browser = BrowserServer(command: URL(fileURLWithPath: "/no/helper"), arguments: [capabilityFile, "--plugins", pluginFile.path],
      tools: plugins.compactMap { $0["name"] as? String })
    let directory = try DirectHTTPTools(request: directoryRequest, enabled: true)
    let wrapped = DirectHTTPCall(id: "fixture", name: "serein_call_task_tool", arguments: #"{"name":"fixture__tool139","arguments":{}}"#)
    guard directory.definitions.count == 128, try directory.resolved(wrapped).name == "fixture__tool139",
      (try? directory.resolved(DirectHTTPCall(id: "", name: wrapped.name, arguments: #"{"name":"absent","arguments":{}}"#))) == nil else {
      throw SereinError.invalid("Overflow tool directory lost its allowlist.")
    }
    let contract = try CursorDriver().contract(for: cursorRequest, network: .open)
    let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    guard let profile = contract.sandboxProfile,
      CredentialEnv.output(sandbox, ["-p", profile, "/bin/cat", configured.path], environment: [:], within: .seconds(3))?.status == 1,
      CredentialEnv.output(sandbox, ["-p", profile, "/bin/cat", agents.appendingPathComponent("local-model.json").path],
                           environment: [:], within: .seconds(3))?.status == 0 else {
      throw SereinError.invalid("Cursor sandbox did not isolate project configuration.")
    }
    let registry = HarnessRegistry.shared
    registry.probesEnabled = false
    registry.configure(library: library)
    let store = ProviderStore.shared
    store.configure(library: library, background: false)
    await store.setup?.value
    guard let migrated = store.connection("custom-openai"), migrated.localModel == true,
      let oldRoute = try store.run(.opencode, model: "org/model"),
      oldRoute.model == migrated.openCodeID + "/org/model",
      let routeConfig = oldRoute.environment["OPENCODE_CONFIG_CONTENT"],
      let json = try JSONSerialization.jsonObject(with: Data(routeConfig.utf8)) as? [String: Any],
      let providers = json["provider"] as? [String: [String: Any]],
      let options = providers[migrated.openCodeID]?["options"] as? [String: String],
      options["baseURL"] == entry.baseURL else {
      throw SereinError.invalid("Saved namespaced model lost its migrated OpenCode connection.")
    }
    try await store.refreshModels(migrated)
    guard let refreshed = store.connection(migrated.id), refreshed.models.contains("org/model"), refreshed.models.contains("check") else {
      throw SereinError.invalid("Refresh lost saved models or failed to discover models.")
    }
    try store.setDirectHTTP(migrated.id, enabled: true)
    let connection = try await store.connect(entry, key: "")
    try await store.testDirectHTTP(connection, model: "check")
    let thread = ThreadKey("direct-synthetic")
    func turn(_ scenario: String, budget: Int? = nil) async throws -> [EngineEvent] {
      var request = TurnRequest(thread: thread, cli: .opencode, executable: URL(fileURLWithPath: "/no/such/cli"),
        access: .web, prompt: TurnPrompt(stable: "", volatile: "", message: scenario, recovery: nil), model: scenario == "org/model" ? scenario : connection.openCodeID + "/" + scenario,
        effort: nil, resume: nil, browser: BrowserServer(command: URL(fileURLWithPath: "/no/such/mcp"),
          arguments: scenario == "grouped" ? [capabilityFile, "--relay"] : [capabilityFile],
          tools: scenario == "grouped" ? [ToolGroups.runTool, ToolGroups.moreTool] : ["tabs", "list_tabs", "find"]), taskID: "fixture", stepBudget: budget)
      try registry.prepare(&request, ownSetup: false)
      guard request.directHTTP != nil, request.model == scenario else { throw SereinError.invalid("Wrong transport or model") }
      let handle = try await engines.send(request)
      var events: [EngineEvent] = []
      var words: Task<SteerOutcome, Never>?
      for await event in handle.events {
        events.append(event)
        if scenario == "steer", words == nil, case .text = event { words = Task { await engines.steer(thread, "fixture words") } }
        if scenario == "cancel", case .text = event { await engines.stop(thread) }
        if scenario == "toolstop", case .toolStarted = event {
          // Long enough for the tool request to be on its socket.
          Task { try? await Task.sleep(for: .milliseconds(500)); await engines.stop(thread) }
        }
      }
      if let words, await words.value != .steered { throw SereinError.invalid("Words sent mid-turn were not read in the turn") }
      guard events.filter({ if case .ended = $0 { return true }; return false }).count == 1 else {
        throw SereinError.invalid("Expected exactly one terminal event for " + scenario)
      }
      return events
    }
    for (name, outcome) in [("tool", Outcome.completed), ("disconnect", .failed), ("budget", .cutShort),
                            ("unlisted", .failed), ("duplicate", .failed), ("truncated", .failed),
                            ("cancel", .stopped), ("json", .completed), ("next", .completed), ("org/model", .completed),
                            ("loose", .completed), ("length", .cutShort), ("notools", .completed),
                            ("noreasoning", .completed), ("refused", .failed), ("responses", .completed),
                            ("minimax", .failed), ("localtext", .completed), ("many", .completed), ("grouped", .completed), ("steer", .completed),
                            ("retry", .completed), ("usageopt", .completed), ("toolong", .completed), ("again", .completed),
                            ("toolstop", .stopped), ("next", .completed)] {
      let events = try await turn(name, budget: name == "budget" ? 0 : nil)
      guard case .ended(let end) = events.last, end.outcome == outcome else {
        throw SereinError.invalid("Unexpected outcome in " + name + ": " + String(describing: events))
      }
      if name == "minimax", !String(describing: events).contains("fixture balance is empty") {
        throw SereinError.invalid("Lost provider error inside HTTP 200.")
      }
      if name == "refused", !String(describing: events).contains("fixture quota is spent") {
        throw SereinError.invalid("Lost the provider's own words for a refused request")
      }
      if ["tool", "disconnect"].contains(name) {
        guard events.contains(.toolEnded(id: "call-1", result: .ok)) else { throw SereinError.invalid("Lost tool result") }
      }
    }
    try store.remove(migrated.id)
    guard try store.run(.opencode, model: "org/model") == nil else { throw SereinError.invalid("Removed route remained active.") }
    await engines.shutdown()
    print("Direct HTTP turn lifecycle passed.")
  }
}
#endif
