import Foundation

public enum HarnessEvents {
  static func clip(_ s: String, _ n: Int = 160) -> String {
    let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count > n ? String(flat.prefix(n)) + "…" : flat
  }

  /// The task panel's Now line and timeline step for a harness tool call.
  public static func activity(name: String, detail: String, folder: String?) -> RunActivity {
    let n = name.lowercased()
    let target = RunNow.display(detail.isEmpty ? nil : detail, folder: folder)
    if n.contains("serein_browser") || n.hasPrefix("mcp__serein") {
      let tool = name.components(separatedBy: "serein_browser").last?.trimmingCharacters(in: CharacterSet(charactersIn: "_-.")) ?? name
      return RunNow.browserTool(tool)
    }
    switch n {
    case "read", "read_file", "ls", "list":
      return RunActivity(tool: "read", now: target.isEmpty ? "Reading files" : "Reading \(target)", done: target.isEmpty ? "Read files" : "Read \(target)")
    // The detail is the pattern or query the model wrote, not a file: a search, as Glob and Grep are.
    case "glob", "grep", "find", "search", "search_files":
      let q = clip(detail, 32)
      return RunActivity(
        tool: "search", now: q.isEmpty ? "Searching files" : "Searching for “\(q)”",
        done: q.isEmpty ? "Searched files" : "Searched for “\(q)”")
    case "edit", "write", "patch", "write_file", "multiedit", "delete", "move":
      return RunActivity(tool: "edit", now: target.isEmpty ? "Editing files" : "Editing \(target)", done: target.isEmpty ? "Edited files" : "Edited \(target)")
    case "bash", "execute", "run_command", "terminal", "shell":
      return RunNow.command(detail)
    case "fetch", "webfetch", "web_fetch", "websearch", "web_search":
      return RunActivity(tool: "web", now: "Using the web", done: "Used the web")
    default:
      let short = RunNow.toolName(name)
      return RunActivity(tool: "tool", now: "Using \(short)", done: "Used \(short)")
    }
  }

}

/// `codex exec` prints every error as a top-level `error` event, the ones it retries and gets
/// past included, so an `error` fails the turn only while no `turn.completed` has followed it.
public enum ExecErrors {
  /// The text of an `error` or `turn.failed` event (`turn.failed` keeps it in `error.message`).
  public static func message(_ event: [String: Any]) -> String {
    (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String ?? jsonString(event)
  }
  /// The error still standing after `event`, given the one standing before it.
  public static func standing(_ before: String?, after event: [String: Any]) -> String? {
    switch event["type"] as? String {
    case "turn.failed": return message(event)
    case "error": return event["will_retry"] as? Bool == true ? before : message(event)
    case "turn.completed": return nil
    default: return before
    }
  }
}

// MARK: - ACP messages

/// Agent Client Protocol (JSON-RPC 2.0 over stdio) messages Serein sends.
public enum ACPMessages {
  /// A `refusal` stop's error: a model declining a request is never an engine failure (AgentRun.engineFailed).
  public static let refusal = "The agent declined this request."
  public static func request(id: Int, method: String, params: [String: Any]) -> String {
    jsonString(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
  }
  /// No file system or terminal capability: the agent uses its own tools, which ask first.
  /// Cursor is told Serein reads models with their options. Without that it accepts only its
  /// other set of ids in `session/set_model`, not the ones `cursor/list_available_models` lists.
  public static func initialize(_ driver: HarnessDriver? = nil) -> [String: Any] {
    var capabilities: [String: Any] = ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]
    if driver == .cursor { capabilities["_meta"] = ["parameterizedModelPicker": true] }
    return [
      "protocolVersion": 1,
      "clientCapabilities": capabilities,
      "clientInfo": ["name": "serein", "title": "Serein", "version": "1"],
    ]
  }
  public static func newSession(cwd: String, mcp: [[String: Any]]) -> [String: Any] {
    ["cwd": cwd, "mcpServers": mcp]
  }
  /// Reads a `session/request_permission` request.
  public static func permissionRequest(_ params: [String: Any]) -> (request: HarnessPermissionRequest, options: [[String: Any]])? {
    guard let call = params["toolCall"] as? [String: Any] else { return nil }
    let id = call["toolCallId"] as? String ?? UUID().uuidString
    let title = call["title"] as? String ?? ""
    var paths = (call["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
    // Grok 1.0.88 sends no locations; the path is in its tool input.
    if paths.isEmpty {
      let input = call["rawInput"] as? [String: Any]
      let grok = ((call["_meta"] as? [String: Any])?["x.ai/tool"] as? [String: Any])?["input"] as? [String: Any]
      if let path = [input?["file_path"], input?["path"], grok?["path"]].compactMap({ $0 as? String }).first { paths = [path] }
    }
    let request = HarnessPermissionRequest(
      id: id, kind: HarnessPermissionRequest.acpKind(call["kind"] as? String, title: title),
      title: HarnessEvents.clip(title, 120), paths: paths.prefix(20).map { String($0.prefix(400)) })
    return (request, params["options"] as? [[String: Any]] ?? [])
  }
  /// The MCP server Gemini CLI names for the tool a permission request is about
  /// (`toolCall._meta["gemini-cli"].mcp.server_name`); nil from a version that does not say.
  public static func geminiServer(_ params: [String: Any]) -> String? {
    let meta = (params["toolCall"] as? [String: Any])?["_meta"] as? [String: Any]
    return ((meta?["gemini-cli"] as? [String: Any])?["mcp"] as? [String: Any])?["server_name"] as? String
  }
}
