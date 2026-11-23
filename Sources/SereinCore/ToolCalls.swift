import Foundation

/// One tool call of a turn, as its Tool Call Card opens it: what it was given and what came back.
/// Both are redacted and clipped, and kept in memory for this launch only. The transcript keeps
/// labels alone (`TranscriptActivity`), so nothing here is ever written to disk.
public struct ToolCall: Equatable, Identifiable, Sendable {
  /// The step id the trail and the step list already carry (`RunNow.stepID`).
  public var id: String
  /// The tool's own name ("Bash", "search_web"), shown in mono.
  public var tool: String
  public var input: String
  /// Nil while the call runs.
  public var output: String?
  public var failed: Bool
  public var startedAt: Date
  public var endedAt: Date?
  public init(id: String, tool: String, input: String, output: String? = nil, failed: Bool = false,
              startedAt: Date, endedAt: Date? = nil) {
    self.id = id
    self.tool = tool
    self.input = input
    self.output = output
    self.failed = failed
    self.startedAt = startedAt
    self.endedAt = endedAt
  }
}

public enum ToolCalls {
  public static let inputLimit = 1_200
  public static let outputLimit = 4_000
  /// Calls kept across every run of this launch; the oldest go first.
  public static let keep = 400
  /// A block longer than this many lines folds behind "Show all N lines".
  public static let foldLines = 8

  /// What one `claude` or `codex exec` stream event says about its calls: a `tool_use` or an
  /// `item.started` opens one, a `tool_result` or an `item.completed` closes it with what came back.
  public static func apply(_ event: [String: Any], to calls: inout [String: ToolCall], at now: Date) {
    let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    switch event["type"] as? String ?? "" {
    case "assistant":
      for use in content where use["type"] as? String == "tool_use" {
        guard let id = use["id"] as? String, calls[id] == nil else { continue }
        calls[id] = ToolCall(id: id, tool: use["name"] as? String ?? "tool", input: clean(use["input"], inputLimit), startedAt: now)
      }
    case "user":
      for result in content where result["type"] as? String == "tool_result" {
        guard let id = result["tool_use_id"] as? String, calls[id] != nil else { continue }
        calls[id]?.output = clean(result["content"], outputLimit)
        calls[id]?.failed = result["is_error"] as? Bool == true
        calls[id]?.endedAt = now
      }
    case "item.started":
      guard let item = event["item"] as? [String: Any], let id = item["id"] as? String, calls[id] == nil else { break }
      calls[id] = ToolCall(id: id, tool: item["tool"] as? String ?? item["type"] as? String ?? "tool",
                           input: clean(item["command"] ?? item["arguments"] ?? item["query"], inputLimit), startedAt: now)
    case "item.completed":
      guard let item = event["item"] as? [String: Any], let id = item["id"] as? String, calls[id] != nil else { break }
      calls[id]?.output = clean(item["aggregated_output"] ?? item["result"] ?? item["error"], outputLimit)
      calls[id]?.failed = (item["exit_code"] as? Int).map { $0 != 0 } == true || ["failed", "declined"].contains(item["status"] as? String ?? "")
      calls[id]?.endedAt = now
    default: break
    }
    if calls.count > keep {
      for old in calls.values.sorted(by: { $0.startedAt < $1.startedAt }).prefix(calls.count - keep) { calls[old.id] = nil }
    }
  }

  /// A value as text a person reads: a string as it is (JSON strings parsed first), an object
  /// pretty-printed, a list of text blocks joined. Redacted whole, then clipped.
  static func clean(_ value: Any?, _ limit: Int) -> String {
    AgentPrivacy.redact(text(value), limit: limit)
  }
  static func text(_ value: Any?) -> String {
    switch value {
    case nil: return ""
    case let string as String:
      guard let data = string.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
        object is [String: Any] || object is [Any] else { return string }
      return text(object)
    case let blocks as [[String: Any]] where blocks.allSatisfy({ $0["type"] as? String == "text" }):
      return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    default:
      guard let value, JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      else { return String(describing: value ?? "") }
      return String(decoding: data, as: UTF8.self)
    }
  }

  /// A long block's first `foldLines` lines and how many more there are; open, all of it.
  public static func folded(_ text: String, open: Bool) -> (text: String, hidden: Int) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard !open, lines.count > foldLines else { return (text, 0) }
    return (lines.prefix(foldLines).joined(separator: "\n"), lines.count - foldLines)
  }

  /// How long it took: "0.4s" under a second, "12s", then "1m 05s". Nil while it runs.
  public static func took(_ call: ToolCall) -> String? {
    guard let end = call.endedAt else { return nil }
    let seconds = max(0, end.timeIntervalSince(call.startedAt))
    if seconds < 1 { return String(format: "%.1fs", seconds) }
    let whole = Int(seconds)
    return whole < 60 ? "\(whole)s" : "\(whole / 60)m " + String(format: "%02d", whole % 60) + "s"
  }

  /// Retry on a failed call: the person's message that asks for that one step again.
  public static func retryWords(_ label: String) -> String {
    "This step did not work: “\(label)”. Try it again."
  }
}
