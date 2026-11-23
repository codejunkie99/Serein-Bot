import Foundation
import SereinCore

/// Uses the same capability-bearing host socket and tool allowlist as the packaged MCP helper.
struct DirectHTTPTools {
  let definitions: [[String: Any]]
  let names: Set<String>
  private let overflow: [String: [String: Any]]
  private static let search = "serein_find_task_tools"
  private static let invoke = "serein_call_task_tool"
  private let capability: Capability?
  private let reachable: [[String: Any]]

  init(request: TurnRequest, enabled: Bool) throws {
    guard enabled, let browser = request.browser, let path = browser.arguments.first else {
      definitions = []; names = []; capability = nil; reachable = []; overflow = [:]; return
    }
    let cap = try Capability.read(from: path)
    guard cap.task == request.taskID else { throw DirectHTTPError.invalid("The task's browser access has changed.") }
    capability = cap
    let args = browser.arguments
    var available = ToolSchema.offered(args)
    if let i = args.firstIndex(of: "--plugins"), args.indices.contains(i + 1) {
      let data = try Data(contentsOf: URL(fileURLWithPath: args[i + 1]))
      available += (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).filter {
        ($0["name"] as? String)?.contains("__") == true
      }
    }
    let allowed = Set(browser.tools)
    let grouped = allowed.contains(ToolGroups.runTool) ? ToolGroups.reachable(ToolSchema.everyTool(args)) : []
    let offered = available.filter { allowed.contains($0["name"] as? String ?? "") } + grouped
    reachable = grouped
    var listed = offered
    if listed.count > 128 {
      let extra = listed.dropFirst(126)
      overflow = Dictionary(extra.compactMap { tool in (tool["name"] as? String).map { ($0, tool) } }, uniquingKeysWith: { first, _ in first })
      listed = Array(listed.prefix(126))
      listed += [
        ["name": Self.search, "description": "Find other tools granted to this task by part of their name. Returns their parameter schemas.",
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
        ["name": Self.invoke, "description": "Call a tool returned by serein_find_task_tools with its named arguments.",
         "inputSchema": ["type": "object", "properties": ["name": ["type": "string"], "arguments": ["type": "object"]], "required": ["name", "arguments"]]]
      ]
    } else { overflow = [:] }
    names = Set(listed.compactMap { $0["name"] as? String }).union(overflow.keys)
    definitions = listed.map { tool in
      ["type": "function", "function": ["name": tool["name"]!, "description": tool["description"] ?? "",
        "parameters": tool["inputSchema"] ?? ["type": "object"]]]
    }
  }

  /// Resolve the directory wrapper before journaling, counting and dispatching the underlying call.
  func resolved(_ call: DirectHTTPCall) throws -> DirectHTTPCall {
    guard call.name == Self.invoke, !overflow.isEmpty else { return call }
    guard let args = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any],
      let name = args["name"] as? String, overflow[name] != nil, let input = args["arguments"] as? [String: Any] else {
      throw DirectHTTPError.invalid("The provider requested an unavailable task tool.")
    }
    let data = try JSONSerialization.data(withJSONObject: input)
    return DirectHTTPCall(id: call.id, name: name, arguments: String(decoding: data, as: UTF8.self))
  }

  func call(_ call: DirectHTTPCall) async throws -> (text: String, failed: Bool) {
    guard let capability, names.contains(call.name),
      let arguments = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any] else {
      throw DirectHTTPError.invalid("The provider requested an unavailable tool.")
    }
    if call.name == Self.search, !overflow.isEmpty {
      let query = arguments["query"] as? String ?? ""
      let matches = overflow.keys.sorted().filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
      return (jsonString(Array(matches.prefix(8)).compactMap { overflow[$0] }), false)
    }
    if call.name == ToolGroups.moreTool {
      return (jsonString(try ToolGroups.more(arguments, reachable: reachable)), false)
    }
    let payload = try call.name == ToolGroups.runTool
      ? ToolGroups.request(arguments, reachable: Set(reachable.compactMap { $0["name"] as? String }))
      : ["name": call.name, "arguments": arguments]
    try Task.checkCancellation()
    // The socket may wait for a user approval. Stop ends the request instead of waiting it out.
    let hold = LocalSocket.Hold()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let result = try LocalSocket.request(payload, capability: capability, hold: hold)
            let text = AgentPrivacy.redact(jsonString(result))
            guard text.utf8.count <= 8_000_000 else { throw DirectHTTPError.invalid("The tool result is too large.") }
            continuation.resume(returning: (Self.capped(text, to: Self.resultCap), result["error"] != nil))
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: {
      hold.end()
    }
  }

  /// A whole page or file as a tool result would fill a model's context in one call.
  static let resultCap = 64_000

  static func capped(_ text: String, to limit: Int) -> String {
    let size = text.utf8.count
    guard size > limit else { return text }
    return String(decoding: text.utf8.prefix(limit), as: UTF8.self) + "\n[cut \(size - limit) bytes]"
  }
}
