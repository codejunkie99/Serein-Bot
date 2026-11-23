
import Foundation

/// The team tools a task's agent uses to work with other agent CLIs (`--peers`): ask one agent or
/// a meeting of several, a writer and a reviewer in one thread, a burst of jobs, and the wait and
/// stop over them. Model-facing and pure; `Peers` (SereinEngines) runs them. Kept apart from
/// Relay's `agent_*` tools, which stay Serein's own run's.
public enum PeerTools {
  public static let flag = "--peers"

  /// Agents per ask or meeting (1-4).
  public static let maxAgents = 4
  public static let maxJobs = 8
  public static let maxRounds = 3
  /// Kept of each answer, from its end. Larger than a 2,000-character status head:
  /// here the answer is what the caller asked for.
  public static let answerLimit = 6_000
  /// A reviewer's reply that starts with this ends a bridge early.
  public static let approved = "APPROVED"

  private struct Spec {
    var name, label, description: String
    var properties: [String: Any]
    var required: [String]
  }

  private static let agentNames = HarnessDriver.allCases.map(\.rawValue).joined(separator: ", ")
  private static var specs: [Spec] {
    let string: [String: Any] = ["type": "string"]
    let agent: [String: Any] = ["type": "string", "description": "One of: \(agentNames)."]
    return [
      Spec(
        name: "peer_ask", label: "Asked other agents",
        description:
          "Ask other agent CLIs (\(agentNames)) and get their answers back. One agent for a second opinion or a sub-question; 2-\(maxAgents) for a meeting: each gets the same question and their answers come back together. They work in this task's folder with your access, and see only what you send, so include the context, the files to read and what counts as done. Waits for the answers as long as one call can, then gives a run id for peer_wait.",
        properties: [
          "agents": ["type": "array", "items": agent, "minItems": 1, "maxItems": maxAgents, "uniqueItems": true],
          "question": ["type": "string", "minLength": 1, "maxLength": 8_000],
        ], required: ["agents", "question"]),
      Spec(
        name: "peer_bridge", label: "Started a writer and a reviewer",
        description:
          "A writer agent and a reviewer agent take turns in one thread: the writer does the task, the reviewer checks it, the writer revises, for up to \(maxRounds) rounds or until the reviewer replies \(approved). Both work in this task's folder with your access. Returns a run id for peer_wait.",
        properties: [
          "writer": agent, "reviewer": agent, "task": ["type": "string", "minLength": 1, "maxLength": 8_000],
          "rounds": ["type": "integer", "minimum": 1, "maximum": maxRounds],
        ], required: ["writer", "reviewer", "task"]),
      Spec(
        name: "peer_burst", label: "Started several agents",
        description:
          "Start up to \(maxJobs) jobs at once, one agent and prompt each, then wait for them all with peer_wait. Jobs past what may run together wait their turn. Each sees only its own prompt.",
        properties: [
          "jobs": [
            "type": "array", "minItems": 1, "maxItems": maxJobs,
            "items": [
              "type": "object", "additionalProperties": false, "required": ["agent", "prompt"],
              "properties": ["agent": agent, "prompt": ["type": "string", "minLength": 1, "maxLength": 8_000]],
            ],
          ]
        ], required: ["jobs"]),
      Spec(
        name: "peer_wait", label: "Waited for other agents",
        description:
          "Wait for runs from peer_ask, peer_bridge or peer_burst (all of yours when runs is left out) for up to seconds, as long as one call can, then report every job and the answers so far. Call again to keep waiting.",
        properties: ["runs": ["type": "array", "items": string], "seconds": ["type": "integer", "minimum": 1]],
        required: []),
      Spec(
        name: "peer_stop", label: "Stopped other agents",
        description: "Stop one run (and everything it started), or every run you started when run is left out.",
        properties: ["run": string], required: []),
    ]
  }

  /// The one list of names; the schemas, the routing and the step labels come from it.
  public static let names: [String] = specs.map(\.name)
  /// Never changes the page or the task: runs beside the caller's other calls (ToolTurns).
  public static let readOnly: Set<String> = ["peer_wait"]

  public static var tools: [[String: Any]] {
    specs.map { spec in
      var tool: [String: Any] = [
        "name": spec.name, "description": spec.description,
        "inputSchema": [
          "type": "object", "properties": spec.properties, "required": spec.required, "additionalProperties": false,
        ],
      ]
      if readOnly.contains(spec.name) { tool["annotations"] = ["readOnlyHint": true] }
      return tool
    }
  }

  public static func label(_ name: String) -> String? { specs.first { $0.name == name }?.label }

  // MARK: Parse

  public static func parse(_ name: String, _ arguments: [String: Any]) -> Result<PeerCall, PeerToolError> {
    func text(_ key: String) -> String? {
      guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
      else { return nil }
      return value
    }
    func agent(_ raw: Any?) -> Result<HarnessDriver, PeerToolError> {
      let given = (raw as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
      if let match = HarnessDriver.allCases.first(where: {
        [$0.rawValue, $0.displayName.lowercased(), $0.instanceID.lowercased()].contains(given)
      }) {
        return .success(match)
      }
      return .failure(PeerToolError("\(given.isEmpty ? "An agent is missing" : "No agent is called \(given)"). Use one of: \(agentNames)."))
    }
    func agents(_ list: [Any]) -> Result<[HarnessDriver], PeerToolError> {
      var out: [HarnessDriver] = []
      for raw in list {
        switch agent(raw) {
        case .success(let one): if !out.contains(one) { out.append(one) }
        case .failure(let error): return .failure(error)
        }
      }
      return .success(out)
    }

    switch name {
    case "peer_ask":
      guard let question = text("question"), let list = arguments["agents"] as? [Any], (1...maxAgents).contains(list.count)
      else { return .failure(PeerToolError("peer_ask takes agents (1-\(maxAgents) names) and question.")) }
      return agents(list).map { .ask(agents: $0, question: question) }
    case "peer_bridge":
      guard let task = text("task") else {
        return .failure(PeerToolError("peer_bridge takes writer, reviewer, task and an optional rounds (1-\(maxRounds))."))
      }
      let rounds = arguments["rounds"] as? Int ?? 2
      guard (1...maxRounds).contains(rounds) else { return .failure(PeerToolError("rounds is 1 to \(maxRounds).")) }
      return agent(arguments["writer"]).flatMap { writer in
        agent(arguments["reviewer"]).map { .bridge(writer: writer, reviewer: $0, task: task, rounds: rounds) }
      }
    case "peer_burst":
      // Every part needs its own words, and an empty one refuses the call.
      guard let list = arguments["jobs"] as? [[String: Any]], (1...maxJobs).contains(list.count) else {
        return .failure(PeerToolError("peer_burst takes jobs: 1-\(maxJobs) of {agent, prompt}, one per part."))
      }
      var jobs: [PeerJob] = []
      for raw in list {
        guard let prompt = (raw["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
          return .failure(PeerToolError("Every job needs a prompt."))
        }
        switch agent(raw["agent"]) {
        case .success(let one): jobs.append(PeerJob(agent: one, prompt: prompt))
        case .failure(let error): return .failure(error)
        }
      }
      return .success(.burst(jobs))
    case "peer_wait":
      let runs = (arguments["runs"] as? [Any])?.compactMap { $0 as? String } ?? []
      return .success(.wait(runs: runs, seconds: arguments["seconds"] as? Int))
    case "peer_stop":
      return .success(.stop(run: text("run")))
    default:
      return .failure(PeerToolError("No team tool is called \(name)."))
    }
  }

  // MARK: Render

  /// Status words for these states.
  static func words(_ state: PeerJobState) -> String {
    switch state {
    case .queued: return "queued, not started yet"
    case .working: return "working"
    case .parked: return "waiting on the person: a secure card is open in the chat"
    case .answered: return "answered"
    case .failed(let why): return "failed: \(why)"
    case .stopped: return "stopped"
    }
  }

  /// The runs as the caller reads them: each job's state and, once in, its answer fenced as
  /// another agent's words.
  public static func render(_ reports: [PeerRunReport]) -> String {
    guard !reports.isEmpty else { return "No team runs of yours are open." }
    var lines: [String] = []
    for report in reports {
      lines.append("Run \(report.id) (\(report.kind.words)): \(report.settled ? "done" : "still working").")
      // A bridge shows only the latest draft and the latest review; earlier ones were revised.
      var shown = Set(report.jobs.indices)
      if case .bridge = report.kind {
        shown = Set(["writer", "reviewer"].compactMap { role in report.jobs.lastIndex { $0.role?.hasPrefix(role) == true } })
      }
      for (index, job) in report.jobs.enumerated() {
        lines.append("- \(job.agent.rawValue)\(job.role.map { ", \($0)" } ?? ""): \(words(job.state))")
        if case .answered(let answer) = job.state, shown.contains(index) {
          lines.append(UntrustedText.wrap("agent_answer", String(answer.suffix(answerLimit)), ref: job.agent.rawValue))
        }
      }
      if case .bridge(let approved) = report.kind, report.settled {
        lines.append(approved ? "The reviewer approved the last draft." : "The reviewer did not approve; the last draft is the writer's final answer above.")
      }
    }
    let open = reports.filter { !$0.settled }.map(\.id)
    if !open.isEmpty {
      lines.append("Not settled. Call peer_wait with runs [\(open.map { "\"\($0)\"" }.joined(separator: ", "))] to keep waiting.")
    }
    lines.append(UntrustedText.outsideNote)
    return lines.joined(separator: "\n")
  }
}

public struct PeerToolError: Error, Equatable, Sendable {
  public let text: String
  public init(_ text: String) { self.text = text }
}

public struct PeerJob: Sendable, Equatable {
  public var agent: HarnessDriver
  public var prompt: String
  public init(agent: HarnessDriver, prompt: String) {
    self.agent = agent
    self.prompt = prompt
  }
}

public enum PeerCall: Sendable, Equatable {
  /// One agent, or a meeting of several on the same question.
  case ask(agents: [HarnessDriver], question: String)
  case bridge(writer: HarnessDriver, reviewer: HarnessDriver, task: String, rounds: Int)
  case burst([PeerJob])
  /// Empty `runs`: every open run of the caller's.
  case wait(runs: [String], seconds: Int?)
  /// nil: every run of the caller's.
  case stop(run: String?)
}

public enum PeerJobState: Sendable, Equatable {
  case queued, working
  case answered(String)
  case failed(String)
  /// A secure card outlasted the callee's tool call; the person's answer starts its next turn.
  case parked
  case stopped

  public var settled: Bool {
    switch self {
    case .queued, .working: return false
    case .answered, .failed, .parked, .stopped: return true
    }
  }
}

public struct PeerJobReport: Sendable, Equatable {
  public var agent: HarnessDriver
  /// "writer, round 1" in a bridge.
  public var role: String?
  public var state: PeerJobState
  public init(agent: HarnessDriver, role: String? = nil, state: PeerJobState) {
    self.agent = agent
    self.role = role
    self.state = state
  }
}

public struct PeerRunReport: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case ask(count: Int)
    case bridge(approved: Bool)
    case burst

    var words: String {
      switch self {
      case .ask(let count): return count == 1 ? "ask" : "meeting of \(count)"
      case .bridge: return "writer and reviewer"
      case .burst: return "burst"
      }
    }
  }
  public var id: String
  public var kind: Kind
  public var jobs: [PeerJobReport]
  public var settled: Bool
  public init(id: String, kind: Kind, jobs: [PeerJobReport], settled: Bool) {
    self.id = id
    self.kind = kind
    self.jobs = jobs
    self.settled = settled
  }
}
