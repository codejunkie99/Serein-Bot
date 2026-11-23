import Foundation

/// One source for what a run looks like right now. The task panel's status pill, its Now line,
/// the transcript's placeholder for a reply that has not started and the At work row all read
/// this, so they can never disagree (for example "Finished the task" beside "Running 0:24").
public enum RunDisplay {
  /// The newest browser step the agent tab board recorded for the run.
  public struct Step: Equatable, Sendable {
    public var tool: String
    public var label: String
    public var time: Date
    public init(tool: String, label: String, time: Date) {
      self.tool = tool
      self.label = label
      self.time = time
    }
  }
  public struct Input: Equatable, Sendable {
    /// True while the CLI turn has not ended.
    public var active: Bool
    /// The run record's outcome raw value once it ended ("done", "needs_user", "failed", "stopped").
    public var outcome: String?
    /// The CLI's own activity line and when it was seen.
    public var cliNow: String?
    public var cliNowAt: Date?
    public var lastStep: Step?
    /// The CLI's coarse phase ("Starting Codex").
    public var phase: String?
    /// The agent called `finish`; the CLI turn may still be writing its last words.
    public var finishReported: Bool
    /// The reply has started streaming.
    public var replying: Bool
    public init(
      active: Bool, outcome: String? = nil, cliNow: String? = nil, cliNowAt: Date? = nil,
      lastStep: Step? = nil, phase: String? = nil, finishReported: Bool = false, replying: Bool = false
    ) {
      self.active = active
      self.outcome = outcome
      self.cliNow = cliNow
      self.cliNowAt = cliNowAt
      self.lastStep = lastStep
      self.phase = phase
      self.finishReported = finishReported
      self.replying = replying
    }
  }
  public struct State: Equatable {
    public var status: AgentTabStatus
    /// The agent reported it is finished, but the run has not ended yet.
    public var wrappingUp: Bool
    /// The Now line while the run is active; nil once it ended.
    public var line: String?
    /// Stands in for an assistant message that has no text yet.
    public var placeholder: String
  }

  public static let wrappingUp = "Wrapping up"

  public static func resolve(_ input: Input) -> State {
    guard input.active else {
      let status = AgentTabStatus.make(working: false, outcome: input.outcome)
      let placeholder: String
      switch status {
      case .stopped: placeholder = "Stopped before a reply."
      case .failed: placeholder = "Could not finish."
      case .needsYou: placeholder = "Needs you."
      case .done, .working: placeholder = "Finished without a written reply."
      }
      return State(status: status, wrappingUp: false, line: nil, placeholder: placeholder)
    }
    // "Finished the task" is the browser half ending; the CLI turn is still closing.
    if input.finishReported || input.lastStep?.tool == "finish" {
      return State(status: .working, wrappingUp: true, line: wrappingUp, placeholder: wrappingUp + "…")
    }
    var line: String?
    if let text = input.cliNow, !text.isEmpty,
      input.lastStep.map({ step in input.cliNowAt.map { step.time <= $0 } ?? false }) ?? true
    {
      line = text
    } else if let step = input.lastStep {
      line = RunNow.present(step.label)
    }
    if line == nil {
      if input.replying {
        line = "Writing a reply"
      } else if let phase = input.phase, !phase.isEmpty {
        line = phase
      } else {
        line = "Working"
      }
    }
    let text = line ?? "Working"
    return State(
      status: .working, wrappingUp: false, line: text,
      placeholder: text.hasSuffix("…") ? text : text + "…")
  }
}
