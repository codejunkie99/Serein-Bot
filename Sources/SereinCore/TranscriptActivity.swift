import Foundation

/// Display-only tool evidence. Inputs, outputs and reasoning are never stored here.
public struct TranscriptActivity: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var tool: String
  public var label: String
  public var failed: Bool
  public init(id: String, tool: String, label: String, failed: Bool = false) {
    self.id = String(id.prefix(160)); self.tool = tool
    self.label = String(AgentPrivacy.redact(label).prefix(240)); self.failed = failed
  }
  public static func call(name: String, input: Any?, id: String, folder: String? = nil) -> Self {
    let short = name.components(separatedBy: ".").last ?? name
    let normalized: String
    switch short.lowercased() {
    case "exec_command", "shell_command", "shell", "shell_exec", "execute", "bash": normalized = "bash"
    case "apply_patch": normalized = "patch"
    default: normalized = short
    }
    let object: [String: Any]?
    if let string = input as? String {
      object = string.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    } else { object = input as? [String: Any] }
    // Redact the complete selected value before clipping: a cut inside a credential can
    // remove the shape needed to recognize it (for example, a short token prefix).
    // A helper the AI app started (Claude Code's Agent, once Task): what it was asked to do.
    if ["agent", "task"].contains(normalized.lowercased()) {
      let what = (object?["description"] as? String).map { HarnessEvents.clip(AgentPrivacy.redact($0), 60) } ?? ""
      return Self(id: id, tool: "tool", label: what.isEmpty ? "Started a helper" : "Started a helper: \(what)")
    }
    let detail = ["file_path", "path", "filePath", "command", "pattern", "url", "query", "cmd"]
      .compactMap { object?[$0] as? String }.first
      .map { HarnessEvents.clip(AgentPrivacy.redact($0), 120) } ?? ""
    let activity = HarnessEvents.activity(name: normalized, detail: detail, folder: folder)
    return Self(id: id, tool: activity.tool, label: activity.done)
  }
  public static func summary(_ activities: [Self]) -> String {
    var labels: [String] = []
    for action in activities {
      let label: String
      switch action.tool {
      case "read": label = "Read files"
      case "edit": label = "Edited files"
      case "command", "test", "build": label = "Ran commands"
      case "web", "search", "navigate": label = "Used the web"
      default: label = "Used tools"
      }
      if !labels.contains(label) { labels.append(label) }
    }
    return labels.joined(separator: ", ")
  }

  /// Only explicitly typed calls. Tool output and reasoning never become display labels.
  /// `folder`: the chat's own folder, so its files show by their place in it.
  public static func blocks(_ content: Any?, folder: String? = nil) -> [Self] {
    (content as? [[String: Any]] ?? []).prefix(200).enumerated().compactMap { offset, block in
      guard ["tool_use", "toolCall", "tool-call"].contains(block["type"] as? String ?? ""),
        let name = block["name"] as? String else { return nil }
      return call(name: name, input: block["input"] ?? block["arguments"],
        id: block["id"] as? String ?? "call-\(offset)", folder: folder)
    }
  }
  public static func functions(_ calls: Any?) -> [Self] {
    var value = calls
    if let text = calls as? String { value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
    return (value as? [[String: Any]] ?? []).prefix(200).enumerated().compactMap { offset, call in
      let function = call["function"] as? [String: Any] ?? call
      guard let name = function["name"] as? String else { return nil }
      return Self.call(name: name, input: function["arguments"], id: call["id"] as? String ?? "function-\(offset)")
    }
  }
  /// Bounded per turn; later status updates replace the same call without duplicating it.
  public static func merge(_ incoming: [Self], into saved: inout [Self]) {
    for action in incoming {
      if let index = saved.firstIndex(where: { $0.id == action.id }) { saved[index] = action }
      else if saved.count < 200 { saved.append(action) }
    }
  }
  public static func codex(_ item: [String: Any], folder: String? = nil) -> Self? {
    let id = item["id"] as? String ?? ""
    let name: String
    let input: Any?
    var more = 0
    switch item["type"] as? String {
    case "commandExecution": name = "bash"; input = ["command": item["command"] as? String ?? ""]
    case "fileChange":
      // The first file by name and how many more, as Serein's own tasks say it (RunNow.codexItem).
      let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
      name = "edit"
      input = ["path": paths.first ?? ""]
      more = max(paths.count - 1, 0)
    case "mcpToolCall", "dynamicToolCall": name = item["tool"] as? String ?? "tool"; input = item["arguments"]
    case "webSearch": name = "web_search"; input = nil
    default: return nil
    }
    var action = call(name: name, input: input, id: id, folder: folder)
    if more > 0 { action.label += " and \(more) more" }
    action.failed = ["failed", "declined"].contains(item["status"] as? String ?? "")
      || (item["exitCode"] as? Int).map { $0 != 0 } == true
    return action
  }
}
