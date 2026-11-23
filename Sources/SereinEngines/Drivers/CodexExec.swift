import Foundation
import SereinCore

// MARK: - codex exec session

/// One `codex exec --json` turn: the prompt goes on stdin, the process ends with the turn.
final class CodexExecSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  private let process: EngineProcess

  init(_ process: EngineProcess, mode: VerifiedMode, resume: String?, ephemeral: Bool, notice: String? = nil) {
    self.mode = mode
    self.process = process
    let (wire, out) = AsyncStream<WireEvent>.makeStream()
    self.wire = wire
    if let notice { out.yield(.notice(notice)) }
    Task {
      var reader = CodexExecReader(resume: resume, ephemeral: ephemeral)
      for await line in process.lines {
        guard let event = try? JSONDecoder().decode(JSON.self, from: line) else { continue }
        for wireEvent in reader.read(event) { out.yield(wireEvent) }
      }
      if let standing = reader.unfinished { out.yield(.failed(standing)) }
      out.finish()
    }
  }

  /// The whole prompt, stable part first, since exec has no instructions channel off argv.
  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    let text = [prompt.stable, prompt.volatile, prompt.message].filter { !$0.isEmpty }.joined(separator: "\n\n")
    try process.send(line: Data(text.utf8))
    process.closeInput()
  }

  /// exec reads stdin once: words mid-turn go back to the caller as the next turn.
  var steers: Bool { false }
  var reusable: Bool { false }
  func steer(_ text: String) async -> SteerOutcome { .handedBack(text) }
}

extension StopReason {
  /// `codex exec resume` started a new session in place of the one it was asked to continue,
  /// before it answered.
  public static let execResumeRefused = StopReason.resumeFailed("Codex has no saved session to continue.")
}

/// `codex exec --json` events as wire events.
struct CodexExecReader {
  let resume: String?
  /// `--ephemeral` saves no rollout, so its thread cannot be resumed and is never reported.
  let ephemeral: Bool
  private var started: Set<String> = []
  private var spoke = false
  private var standing: String?
  private var done = false
  /// The resume was refused: the rest of this process's output is a turn without the conversation.
  private var refused = false

  init(resume: String?, ephemeral: Bool) {
    self.resume = resume
    self.ephemeral = ephemeral
  }

  /// An error no turn end followed.
  var unfinished: String? { done ? nil : standing }

  mutating func read(_ event: JSON) -> [WireEvent] {
    guard !refused else { return [] }
    let object = event.any as? [String: Any] ?? [:]
    standing = ExecErrors.standing(standing, after: object)
    switch event["type"]?.string {
    case "thread.started":
      guard let id = event["thread_id"]?.string, !ephemeral else { return [] }
      // Asked to resume a session it no longer has, exec starts a new one and would answer
      // without the conversation: the turn ends before it answers, and the caller sends it fresh.
      if let resume, resume != id {
        refused = true
        done = true
        return [.turnDone(.execResumeRefused)]
      }
      return [.session(id: id, rebuilt: false)]
    case "turn.started":
      return [.accepted]
    case "item.started":
      return start(event["item"] ?? .null)
    case "item.completed":
      return complete(event["item"] ?? .null)
    case "turn.completed":
      done = true
      let usage = event["usage"]
      return [
        .usage(
          input: Int(usage?["input_tokens"]?.number ?? 0), output: Int(usage?["output_tokens"]?.number ?? 0),
          cachedInput: usage?["cached_input_tokens"]?.number.map { Int($0) }),
        .turnDone(.endTurn),
      ]
    case "turn.failed":
      done = true
      return [.turnDone(CodexFailure.reason(ExecErrors.message(object), info: nil))]
    default:
      return []
    }
  }

  private mutating func start(_ item: JSON) -> [WireEvent] {
    let id = item["id"]?.string ?? UUID().uuidString
    let tool: (name: String, arguments: String, shell: String?)
    switch item["type"]?.string {
    case "command_execution":
      let command = CodexThread.command(item)
      tool = ("shell", command, command)
    case "file_change":
      tool = ("edit", item["changes"]?.array?.compactMap { $0["path"]?.string }.joined(separator: "\n") ?? "", nil)
    case "mcp_tool_call":
      tool = (item["tool"]?.string ?? "mcp", item["arguments"].map { jsonString($0.any) } ?? "", nil)
    case "web_search":
      tool = ("web_search", item["query"]?.string ?? "", nil)
    default:
      return []
    }
    guard started.insert(id).inserted else { return [] }
    return [.toolStarted(id: id, name: tool.name, arguments: tool.arguments, shellCommand: tool.shell)]
  }

  private mutating func complete(_ item: JSON) -> [WireEvent] {
    let id = item["id"]?.string ?? ""
    switch item["type"]?.string {
    case "agent_message":
      guard let text = item["text"]?.string, !text.isEmpty else { return [] }
      defer { spoke = true }
      return (spoke ? [.newMessage] : []) + [.text(text)]
    case "reasoning":
      return (item["text"]?.string).map { [.thinking($0)] } ?? []
    case "command_execution", "file_change", "mcp_tool_call", "web_search":
      let status = item["status"]?.string
      let result: ToolResult = status == "failed" || status == "declined" ? .failed : .ok
      return start(item) + [.toolEnded(id: id, result: result)]
    default:
      return []
    }
  }
}

// MARK: - JSON bridging

extension JSON {
  /// From JSONSerialization-style values, as SereinCore's Codex helpers build them.
  init(_ value: Any) {
    switch value {
    case let json as JSON: self = json
    case is NSNull: self = .null
    case let string as String: self = .string(string)
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
    case let number as NSNumber: self = .number(number.doubleValue)
    case let array as [Any]: self = .array(array.map(JSON.init))
    case let object as [String: Any]: self = .object(object.mapValues(JSON.init))
    default: self = .null
    }
  }

  var any: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .number(let value): return NSNumber(value: value)
    case .string(let value): return value
    case .array(let value): return value.map(\.any)
    case .object(let value): return value.mapValues(\.any)
    }
  }

  var object: [String: JSON]? { if case .object(let value) = self { return value }; return nil }
}

