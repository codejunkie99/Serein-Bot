import Foundation

// Codex app server protocol, the subset Serein uses. Discovered from the installed CLI with
// `codex app-server generate-json-schema` / `generate-ts` (codex-cli 0.156.1); no live model call.
//
// Transport: one JSON object per line over the server's stdin/stdout ("JSON-RPC lite": no
// "jsonrpc" field; ids are integers or strings).
//
// Client requests: initialize, config/read, thread/start, thread/resume, thread/fork,
//   thread/unsubscribe, turn/start, turn/interrupt, mcpServerStatus/list, model/list.
// Client notification: initialized.
// Server notifications: thread/started, turn/started, turn/completed, item/started,
//   item/completed, item/agentMessage/delta, thread/tokenUsage/updated, error.
// Server requests (all answered by Serein, never approved beyond its grants):
//   item/fileChange/requestApproval, item/commandExecution/requestApproval,
//   item/permissions/requestApproval, mcpServer/elicitation/request, item/tool/requestUserInput,
//   item/tool/call, applyPatchApproval, execCommandApproval; anything else gets an error.

/// JSON-RPC framing for the Codex app server.
public enum CodexRPC {
  public enum ID: Hashable, Sendable, CustomStringConvertible {
    case int(Int)
    case string(String)
    public var json: Any {
      switch self {
      case .int(let i): return i
      case .string(let s): return s
      }
    }
    public var description: String {
      switch self {
      case .int(let i): return String(i)
      case .string(let s): return s
      }
    }
    init?(_ value: Any?) {
      if let s = value as? String { self = .string(s); return }
      if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
        self = .int(n.intValue)
        return
      }
      return nil
    }
  }

  public enum Message {
    case response(ID, Any)
    case failure(ID?, code: Int, message: String)
    case notification(String, [String: Any])
    case request(ID, String, [String: Any])
  }

  /// One line from the server; nil for anything that is not a protocol message.
  public static func decode(_ line: String) -> Message? {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let id = ID(object["id"])
    if let method = object["method"] as? String {
      let params = object["params"] as? [String: Any] ?? [:]
      if let id { return .request(id, method, params) }
      return .notification(method, params)
    }
    if let error = object["error"] as? [String: Any] {
      return .failure(
        id, code: (error["code"] as? NSNumber)?.intValue ?? 0,
        message: error["message"] as? String ?? "Unknown error")
    }
    if let id, object.keys.contains("result") { return .response(id, object["result"] ?? NSNull()) }
    return nil
  }

  public static func request(id: Int, method: String, params: [String: Any]) -> String {
    jsonString(["id": id, "method": method, "params": params])
  }
  public static func notification(method: String) -> String { jsonString(["method": method]) }
  public static func response(id: ID, result: Any) -> String {
    jsonString(["id": id.json, "result": result])
  }
  public static func error(id: ID, code: Int, message: String) -> String {
    jsonString(["id": id.json, "error": ["code": code, "message": message]])
  }
}

/// A thread item, reduced to what Serein shows.
public struct CodexItem: Equatable, Sendable {
  public var id: String
  public var type: String
  public var text: String?
  /// Responses wire phase: commentary, partial_answer or final_answer (older CLIs omit it).
  public var phase: String?
  public var command: String?
  /// File paths of a `fileChange` item.
  public var paths: [String]
  public var status: String?
  public var server: String?
  public var tool: String?
  public init(_ json: [String: Any]) {
    id = json["id"] as? String ?? ""
    type = json["type"] as? String ?? ""
    text = json["text"] as? String
    phase = json["phase"] as? String
    command = json["command"] as? String
    paths = (json["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
    status = json["status"] as? String
    server = json["server"] as? String
    tool = json["tool"] as? String
  }
}

public enum TokenCount {
  /// "840 tokens", "12.4k tokens", "1.2M tokens".
  public static func label(_ n: Int) -> String {
    if n < 1000 { return "\(n) token\(n == 1 ? "" : "s")" }
    if n < 1_000_000 {
      let k = Double(n) / 1000
      return (k < 100 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k") + " tokens"
    }
    return String(format: "%.1fM", Double(n) / 1_000_000) + " tokens"
  }
}

/// A request the server sent to Serein.
public struct CodexServerRequest: Equatable {
  public var id: CodexRPC.ID
  public var method: String
  public var thread: String?
  public var turn: String?
  public var item: String?
  public var command: String?
  public var reason: String?
  /// Questions, elicitation and dynamic tool calls are requests, but not permission decisions.
  public var isPermissionRequest: Bool {
    switch method {
    case "item/fileChange/requestApproval", "item/commandExecution/requestApproval",
         "item/permissions/requestApproval", "applyPatchApproval", "execCommandApproval": return true
    default: return false
    }
  }
  public init(id: CodexRPC.ID, method: String, params: [String: Any]) {
    self.id = id
    self.method = method
    thread = params["threadId"] as? String ?? params["conversationId"] as? String
    turn = params["turnId"] as? String
    item = params["itemId"] as? String ?? params["callId"] as? String
    command =
      params["command"] as? String
      ?? (params["command"] as? [String]).map { $0.joined(separator: " ") }
    reason = params["reason"] as? String
  }
}

/// How Serein answers the server's requests. Serein never approves anything: what its grants
/// allow is already inside the sandbox, so a request means something outside it. A declined
/// file change becomes an approval card; "Allow once" grants the next turn edits.
public enum CodexApprovals {
  public struct Answer {
    /// The JSON-RPC result, or nil when `error` is set.
    public var result: [String: Any]?
    public var error: String?
    public var approvals: [PendingApproval] = []
    /// A line for the transcript.
    public var note: String?
  }

  /// `paths`: the files of the request's `fileChange` item, from its `item/started`.
  public static func answer(_ request: CodexServerRequest, paths: [String] = [], folder: String?)
    -> Answer
  {
    switch request.method {
    case "item/fileChange/requestApproval":
      let id = request.item ?? request.id.description
      let approvals =
        paths.isEmpty
        ? [PendingApproval(id: id, tool: "file_change", target: "")]
        : paths.enumerated().map { i, path in
          PendingApproval(
            id: "\(id)-\(i)", tool: "file_change",
            target: ApprovalEvents.display(path, folder: folder))
        }
      return Answer(result: ["decision": "decline"], approvals: approvals)
    case "item/commandExecution/requestApproval":
      let command = String((request.command ?? "a command").prefix(120))
      return Answer(
        result: ["decision": "decline"],
        note: "Serein declined a command outside the sandbox: \(command)")
    case "item/permissions/requestApproval":
      return Answer(result: ["permissions": [String: Any](), "scope": "turn"])
    case "mcpServer/elicitation/request":
      return Answer(result: ["action": "decline", "content": NSNull(), "_meta": NSNull()])
    case "item/tool/requestUserInput":
      return Answer(result: ["answers": [String: Any]()])
    case "item/tool/call":
      return Answer(result: ["contentItems": [Any](), "success": false])
    case "applyPatchApproval", "execCommandApproval":
      return Answer(
        result: ["decision": ["denied": ["rejection": "Not allowed by Serein for this task."]]])
    default:
      return Answer(result: nil, error: "Serein does not handle \(request.method).")
    }
  }

  /// A completed `fileChange` item that was declined or failed, as approvals (same ids as above).
  public static func refused(_ item: CodexItem, folder: String?) -> [PendingApproval] {
    guard item.type == "fileChange", let status = item.status, ["declined", "failed"].contains(status)
    else { return [] }
    if item.paths.isEmpty { return [PendingApproval(id: item.id, tool: "file_change", target: "")] }
    return item.paths.enumerated().map { i, path in
      PendingApproval(
        id: "\(item.id)-\(i)", tool: "file_change",
        target: ApprovalEvents.display(path, folder: folder))
    }
  }
}

/// What one run may do, fixed when it starts.
public struct CodexRunSettings: Equatable, Sendable {
  public var cwd: String
  public var model: String
  public var effort: String
  public var instructions: String
  /// Project edits granted: workspace-write limited to `cwd`. Otherwise read-only.
  public var writable: Bool
  /// The shell tool (Project and Library modes, as with `codex exec`).
  public var shell: Bool
  public var helperPath: String
  public var helperArgs: [String]
  /// Browser tool names, each set to `approval_mode = "approve"`.
  public var tools: [String]
  public var images: [String]
  public init(
    cwd: String, model: String, effort: String, instructions: String, writable: Bool, shell: Bool,
    helperPath: String, helperArgs: [String], tools: [String], images: [String] = []
  ) {
    self.cwd = cwd
    self.model = model
    self.effort = effort
    self.instructions = instructions
    self.writable = writable
    self.shell = shell
    self.helperPath = helperPath
    self.helperArgs = helperArgs
    self.tools = tools
    self.images = images
  }
}

/// Request parameters. The app server has no `--ignore-user-config`, so everything the user's
/// config.toml could loosen is set explicitly and then checked (`CodexChecks`).
public enum CodexParams {
  public static let browserServer = "serein_browser"
  /// Features switched off for the whole server. Unknown names are ignored by Codex.
  public static let disabledFeatures = [
    "apps", "plugins", "remote_plugin", "hooks", "multi_agent", "multi_agent_v2", "memories",
    "browser_use", "browser_use_external", "computer_use", "in_app_browser", "image_generation",
    "tool_suggest", "guardian_approval", "goals", "realtime_conversation", "view_image",
    "skill_mcp_dependency_install", "workspace_dependencies", "js_repl",
  ]

  /// `-c` values that switch `features` off, with `agents.enabled=false`: the model catalog can
  /// pick the v2 sub-agent tools whatever the two multi_agent flags say (checked 2026-11-16,
  /// codex-cli 0.167.0: only this key took spawn_agent out of the prompt input).
  public static func offConfigs(_ features: [String] = disabledFeatures) -> [String] {
    features.map { "features.\($0)=false" } + ["agents.enabled=false"]
  }

  public static func serverArguments() -> [String] {
    var args = ["app-server", "--listen", "stdio://"]
    let configs =
      [
        "approval_policy=\"on-request\"", "approvals_reviewer=\"user\"",
        "sandbox_mode=\"read-only\"", "web_search=\"disabled\"", "notify=[]",
      ] + offConfigs()
    for c in configs { args += ["-c", c] }
    return args
  }

  public static func initialize(version: String) -> [String: Any] {
    [
      "clientInfo": ["name": "serein", "title": "Serein", "version": version],
      "capabilities": [
        "experimentalApi": false, "requestAttestation": false,
        "optOutNotificationMethods": ["remoteControl/status/changed"],
      ],
    ]
  }

  /// MCP server names from a `config/read` result (user and project layers alike).
  public static func configuredServers(_ configRead: Any) -> [String] {
    let config = (configRead as? [String: Any])?["config"] as? [String: Any] ?? [:]
    return (config["mcp_servers"] as? [String: Any] ?? [:]).keys.filter { $0 != browserServer }
      .sorted()
  }

  /// Per-thread overrides: every other MCP server off, Serein's browser server on with its
  /// capability, the shell only where `codex exec` would have it.
  public static func threadConfig(_ s: CodexRunSettings?, disable: [String]) -> [String: Any] {
    var config: [String: Any] = [
      "web_search": "disabled", "features.view_image": false,
      "features.skill_mcp_dependency_install": false,
      "sandbox_workspace_write.writable_roots": [String](),
      "sandbox_workspace_write.network_access": false,
    ]
    // A name that is not a plain TOML key cannot be switched off; CodexChecks then refuses.
    for name in disable where !name.contains(".") && !name.contains("\"") {
      config["mcp_servers.\(name).enabled"] = false
    }
    guard let s else {
      config["features.shell_tool"] = false
      config["features.unified_exec"] = false
      return config
    }
    if !s.shell {
      config["features.shell_tool"] = false
      config["features.unified_exec"] = false
    } else {
      config["features.shell_tool"] = true
    }
    if !s.effort.isEmpty { config["model_reasoning_effort"] = s.effort }
    let prefix = "mcp_servers.\(browserServer)."
    config[prefix + "command"] = s.helperPath
    config[prefix + "args"] = s.helperArgs
    // A browser step can wait on the person's card: 118 s, or a held secure card's 570 s.
    config[prefix + "tool_timeout_sec"] = Int(SecureCard.cliLimit)
    for tool in s.tools { config[prefix + "tools.\(tool).approval_mode"] = "approve" }
    return config
  }

  /// A copy of a thread for "Continue in a copy". It is unloaded at once; the copy's first turn
  /// resumes it with that turn's settings.
  public static func threadFork(id: String, cwd: String?, disable: [String]) -> [String: Any] {
    var p: [String: Any] = [
      "threadId": id, "excludeTurns": true, "approvalPolicy": "on-request",
      "approvalsReviewer": "user", "sandbox": "read-only",
      "config": threadConfig(nil, disable: disable),
    ]
    if let cwd { p["cwd"] = cwd }
    return p
  }

  /// Words for a turn that runs. Codex refuses when `turn` is no longer the active turn.
  public static func steer(thread: String, turn: String, text: String) -> [String: Any] {
    ["threadId": thread, "expectedTurnId": turn, "input": [["type": "text", "text": text]]]
  }
  public static func interrupt(thread: String, turn: String) -> [String: Any] {
    ["threadId": thread, "turnId": turn]
  }

  public static func serverStatus(thread: String) -> [String: Any] {
    ["threadId": thread, "detail": "toolsAndAuthOnly"]
  }
}

/// Checks before Serein lets a thread run, and the capability probe.
public enum CodexChecks {
  /// Methods Serein needs from the installed CLI.
  public static let requiredRequests: Set<String> = [
    "initialize", "config/read", "thread/start", "thread/resume", "thread/fork",
    "thread/unsubscribe", "turn/start", "turn/interrupt", "mcpServerStatus/list",
  ]
  public static let requiredNotifications: Set<String> = [
    "turn/started", "turn/completed", "item/started", "item/completed", "item/agentMessage/delta",
    "thread/tokenUsage/updated", "error",
  ]
  public static let requiredServerRequests: Set<String> = [
    "item/fileChange/requestApproval", "item/commandExecution/requestApproval",
  ]

  /// Method names in a generated `ClientRequest.json`, `ServerNotification.json` or
  /// `ServerRequest.json` (`oneOf[].properties.method.enum`).
  public static func methods(schema: Data) -> Set<String> {
    guard let object = try? JSONSerialization.jsonObject(with: schema) as? [String: Any] else {
      return []
    }
    let variants = (object["oneOf"] ?? object["anyOf"]) as? [[String: Any]] ?? []
    var out = Set<String>()
    for v in variants {
      let method = (v["properties"] as? [String: Any])?["method"] as? [String: Any]
      for name in method?["enum"] as? [String] ?? [] { out.insert(name) }
    }
    return out
  }

  public static func supports(requests: Set<String>, notifications: Set<String>, serverRequests: Set<String>)
    -> Bool
  {
    requiredRequests.isSubset(of: requests) && requiredNotifications.isSubset(of: notifications)
      && requiredServerRequests.isSubset(of: serverRequests)
  }

  /// nil when a thread/start, resume or fork response shows Serein's settings in force.
  /// `profile`: the permissions profile the thread was started with. Its network is open, so
  /// `networkAccess` may be true, but only when Codex reports that profile. `opened`: roots past
  /// the project the profile writes (home at Allow all).
  public static func threadProblem(
    _ response: Any, writable: Bool, approvalPolicy: String = "on-request", profile: String? = nil,
    opened: [String] = []
  ) -> String? {
    let r = response as? [String: Any] ?? [:]
    guard (r["thread"] as? [String: Any])?["id"] is String else {
      return "The Codex server started no thread."
    }
    if r["approvalPolicy"] as? String != approvalPolicy {
      return "Codex did not accept Serein's approval setting."
    }
    if let profile, (r["activePermissionProfile"] as? [String: Any])?["id"] as? String != profile {
      return "Codex did not take Serein's permissions profile."
    }
    if let reviewer = r["approvalsReviewer"], reviewer as? String != "user" {
      return "Codex routes approvals to an automatic reviewer, which Serein does not allow."
    }
    let sandbox = r["sandbox"] as? [String: Any] ?? [:]
    let type = sandbox["type"] as? String
    if profile == nil, sandbox["networkAccess"] as? Bool == true { return "Codex would allow network access." }
    switch type {
    case "readOnly": return nil
    case "workspaceWrite" where writable:
      let roots = (sandbox["writableRoots"] as? [String] ?? []).map(AgentFileGuard.physicalPath)
      // Codex reports roots resolved (/private/tmp/x) and cwd as given (/tmp/x).
      let cwd = (r["cwd"] as? String).flatMap { $0.isEmpty ? nil : AgentFileGuard.physicalPath($0) } ?? ""
      let inside = ([cwd] + opened.map(AgentFileGuard.physicalPath)).filter { !$0.isEmpty }
      let outside = roots.filter { root in
        !inside.contains { root == $0 || root.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
      }
      return outside.isEmpty ? nil : "Codex would allow writes outside the project."
    default: return "Codex did not accept Serein's sandbox."
    }
  }

  /// Servers in an `mcpServerStatus/list` result that are neither Serein's nor switched off.
  public static func unexpectedServers(_ statusList: Any) -> [String] {
    let data = (statusList as? [String: Any])?["data"] as? [[String: Any]] ?? []
    return data.compactMap { s in
      guard let name = s["name"] as? String else { return nil }
      if name == CodexParams.browserServer && s["pluginId"] as? String == nil { return nil }
      return s["runtimeStatus"] as? String == "disabled" ? nil : name
    }.sorted()
  }

  /// Codex exec-policy `.rules` files can let commands run outside the sandbox. `codex exec`
  /// ignores them (`--ignore-rules`); the app server cannot, so runs with a shell fall back.
  /// Project rules load from every `.codex` folder between the folder and its repository root.
  public static func rulesPresent(
    codexHome: URL, folder: URL?, home: String = NSHomeDirectory(),
    fileManager fm: FileManager = .default
  ) -> Bool {
    var dirs = [codexHome.appendingPathComponent("rules")]
    if let folder {
      dirs += projectFolders(from: folder, home: home, fileManager: fm).map {
        $0.appendingPathComponent(".codex/rules")
      }
    }
    for dir in dirs {
      let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
      if names.contains(where: { $0.hasSuffix(".rules") }) { return true }
    }
    return false
  }

  /// A `.codex/config.toml` between the folder and its repository root: a project config layer,
  /// which the app server would apply and `codex exec --ignore-user-config` did not.
  public static func projectConfigPresent(
    folder: URL, home: String = NSHomeDirectory(), fileManager fm: FileManager = .default
  ) -> URL? {
    projectFolders(from: folder, home: home, fileManager: fm).map {
      $0.appendingPathComponent(".codex/config.toml")
    }.first { fm.fileExists(atPath: $0.path) }
  }

  /// The folder and its parents up to the first one with `.git` (the repository root). The home
  /// folder itself is never included: its `.codex` is the user's Codex home, not a project.
  static func projectFolders(from folder: URL, home: String, fileManager fm: FileManager) -> [URL] {
    var out: [URL] = []
    var current = folder.standardizedFileURL
    let homePath = URL(fileURLWithPath: home).standardizedFileURL.path
    for _ in 0..<64 {
      if current.path == homePath || current.path == "/" { break }
      out.append(current)
      if fm.fileExists(atPath: current.appendingPathComponent(".git").path) { break }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    return out
  }

  /// Config keys that change where requests go or what runs, which `codex exec
  /// --ignore-user-config` used to drop. Any of them in a loaded layer sends Codex to exec.
  public static let overrideKeys = [
    "openai_base_url", "chatgpt_base_url", "model_provider", "model_providers",
    "shell_environment_policy", "model_instructions_file", "experimental_instructions_file",
    "profile",
  ]

  /// Why the app server's effective config is not what Serein runs with, from a `config/read`
  /// result with `includeLayers`. nil when it may be used. Only layers count: packaged defaults
  /// and Serein's own command-line flags are fine.
  public static func configProblem(_ configRead: Any) -> String? {
    let read = configRead as? [String: Any] ?? [:]
    guard let layers = read["layers"] as? [[String: Any]] else {
      return "Codex runs through codex exec because Serein could not read which Codex config files apply."
    }
    var keys: [String] = []
    for layer in layers {
      let name = layer["name"] as? [String: Any] ?? [:]
      let type = name["type"] as? String ?? ""
      if ["packagedDefaults", "sessionFlags"].contains(type) { continue }
      if type == "project" {
        let folder = name["dotCodexFolder"] as? String ?? "the project"
        return "Codex runs through codex exec because \(folder) has its own Codex config."
      }
      let config = layer["config"] as? [String: Any] ?? [:]
      for key in overrideKeys where meaningful(config[key]) && !keys.contains(key) { keys.append(key) }
      if let servers = config["mcp_servers"] as? [String: Any],
        servers[CodexParams.browserServer] != nil, !keys.contains("mcp_servers.serein_browser")
      {
        keys.append("mcp_servers.serein_browser")
      }
    }
    guard !keys.isEmpty else { return nil }
    let routed = keys.contains { CodexRouting.keys.contains($0) }
    return "Codex runs through codex exec because your Codex config overrides "
      + keys.joined(separator: ", ") + "."
      + (routed ? " Your base URL, model provider and model catalog still apply there." : "")
  }

  static func meaningful(_ value: Any?) -> Bool {
    switch value {
    case nil, is NSNull: return false
    case let s as String: return !s.isEmpty
    case let d as [String: Any]: return d.values.contains { meaningful($0) }
    case let a as [Any]: return !a.isEmpty
    default: return true
    }
  }

  /// Features that must be off in every thread (and the shell where the mode has none), from an
  /// `experimentalFeature/list` result for that thread. nil when they are.
  public static let featuresOff = [
    "hooks", "plugins", "remote_plugin", "apps", "multi_agent", "multi_agent_v2", "memories",
    "browser_use", "browser_use_external", "computer_use", "in_app_browser", "image_generation",
    "guardian_approval",
  ]
  public static func featureProblem(_ features: [[String: Any]], shell: Bool) -> String? {
    var enabled: [String: Bool] = [:]
    for f in features {
      if let name = f["name"] as? String { enabled[name] = f["enabled"] as? Bool ?? true }
    }
    if !shell && enabled["shell_tool"] != false { return "Codex would keep its shell tool on." }
    let on = featuresOff.filter { enabled[$0] == true }
    return on.isEmpty ? nil : "Codex would keep \(on.joined(separator: ", ")) on."
  }

  /// The `nextCursor` of a paginated result, nil on the last page.
  public static func nextCursor(_ result: Any) -> String? {
    (result as? [String: Any])?["nextCursor"] as? String
  }

  public static func codexHome(environment: [String: String], home: String) -> URL {
    if let value = environment["CODEX_HOME"], !value.isEmpty { return URL(fileURLWithPath: value) }
    return URL(fileURLWithPath: home).appendingPathComponent(".codex")
  }
}

public enum CodexModels {
  /// Visible models from `model/list` results (every page). No count limit:
  /// a cap cut off routed catalogs, and with them a model that had just arrived.
  public static func choices(_ modelList: Any) -> [ModelChoice] {
    let data = (modelList as? [String: Any])?["data"] as? [[String: Any]] ?? []
    var seen = Set<String>()
    return data.compactMap { m in
      guard m["hidden"] as? Bool != true, let model = (m["model"] ?? m["id"]) as? String,
        !model.isEmpty, seen.insert(model).inserted
      else { return nil }
      let name = (m["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model
      let blurb = String((m["description"] as? String ?? "").prefix(140))
      let efforts = (m["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap {
        ($0["reasoningEffort"] as? String).map { String($0.prefix(20)) }
      }
      return ModelChoice(
        model: model, name: String(name.prefix(60)), tier: .balanced,
        blurb: blurb.isEmpty ? "From your Codex model list." : blurb, efforts: efforts,
        defaultEffort: m["defaultReasoningEffort"] as? String, isDefault: m["isDefault"] as? Bool == true)
    }
  }
  /// Codex's own model cache (`models_cache.json`: `{models: [{slug, display_name, description,
  /// visibility, priority, supported_reasoning_levels: [{effort}], default_reasoning_level}]}`),
  /// so the real list shows before Codex's server first starts. Lowest priority first.
  public static func cached(_ data: Data) -> [ModelChoice] {
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let rows = (json?["models"] as? [[String: Any]] ?? []).filter { $0["visibility"] as? String != "hide" }
      .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
    return choices(["data": rows.map { m -> [String: Any] in
      [
        "model": m["slug"] ?? "", "displayName": m["display_name"] ?? "", "description": m["description"] ?? "",
        "supportedReasoningEfforts": (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap {
          $0["effort"].map { ["reasoningEffort": $0] }
        },
        "defaultReasoningEffort": m["default_reasoning_level"] ?? NSNull(),
      ]
    }])
  }
}

/// The part of the user's Codex config that says where requests go: a custom base URL, a model
/// provider table, the model catalog, and the model an unpicked chat runs (the app server reads
/// it from config.toml, so exec must too). `codex exec --ignore-user-config` drops it, which left
/// routed models (a local router, a third-party provider) unreachable; Serein re-applies exactly
/// these keys with `-c`, and nothing else from the config.
public enum CodexRouting {
  public static let keys = [
    "openai_base_url", "chatgpt_base_url", "model_provider", "model_providers", "model_catalog_json", "model",
  ]
  /// The routing keys of the effective config from a `config/read` result.
  public static func routing(_ configRead: Any) -> [String: Any] {
    let read = configRead as? [String: Any] ?? [:]
    let config = read["config"] as? [String: Any] ?? [:]
    var out: [String: Any] = [:]
    for key in keys {
      if let value = config[key], CodexChecks.meaningful(value) { out[key] = value }
    }
    return out
  }
  /// `-c` values that put the routing back for `codex exec`. A model picked in Serein goes as
  /// `--model`, so the config's own is left out then.
  public static func arguments(_ routing: [String: Any], picked: String = "") -> [String] {
    routing.keys.sorted().filter { $0 != "model" || picked.isEmpty }
      .compactMap { key in toml(routing[key]!).map { "\(key)=\($0)" } }
  }
  /// A TOML inline value: string, number, boolean, array or inline table. nil for null.
  public static func toml(_ value: Any) -> String? {
    switch value {
    case is NSNull: return nil
    case let number as NSNumber:
      return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
    case let string as String: return jsonString(string)
    case let array as [Any]: return "[" + array.compactMap(toml).joined(separator: ", ") + "]"
    case let table as [String: Any]:
      let pairs = table.keys.sorted().compactMap { key -> String? in
        toml(table[key]!).map { tomlKey(key) + " = " + $0 }
      }
      return "{" + pairs.joined(separator: ", ") + "}"
    default: return nil
    }
  }
  static func tomlKey(_ key: String) -> String {
    key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) && !key.isEmpty ? key : jsonString(key)
  }
}
