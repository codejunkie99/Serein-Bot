import Foundation
import SereinCore

/// A CLI's own words for a turn, as its driver read them off the wire.
enum WireEvent: Sendable, Equatable {
  /// The CLI took the prompt. From here a replay could run tools twice.
  case accepted
  case modeReported([String: String])
  case session(id: String, rebuilt: Bool)
  case text(String)
  case thinking(String)
  case newMessage
  /// `arguments` in one canonical form, for the loop guard. `shellCommand` set for a shell step.
  case toolStarted(id: String, name: String, arguments: String, shellCommand: String?)
  case toolEnded(id: String, result: ToolResult)
  case declined(PendingApprovalValue)
  /// Serein answered the CLI with no approval to offer: allowed once, or refused.
  case permissionAnswered(allowed: Bool)
  case usage(input: Int, output: Int, cachedInput: Int?)
  case context(used: Int, size: Int?, estimated: Bool)
  case commands([SlashCommand])
  /// Something the person should see that is not the reply (a CLI retrying its model).
  case notice(String)
  /// The CLI's own word that its usage limit refused a request, with its reset when it gave one.
  case limitReached(UsageLimit)
  /// The provider's own count of the share it has left, 0 to 1 (an API route's rate-limit headers).
  case usageLeft(Double)
  case turnDone(StopReason)
  case failed(String)
}

struct TurnState: Sendable {
  var prompt: TurnPrompt
  var retries = 0
  var stuck: HarnessStuck
  var loop = HarnessLoopGuard()
  var shellRisk: ShellRisk?
  /// Started and not ended, in start order; each gets `.unknown` if the turn is cut.
  var openTools: [String] = []
  var sessionID: String?
  var noticed = false
  var steps = 0
  var stepBudget: Int?
  /// The `finish` tool was called; the CLI gets `Machine.finishGrace` to end on its own.
  var finishing = false

  init(prompt: TurnPrompt, at date: Date, stepBudget: Int? = nil) {
    self.prompt = prompt
    self.stepBudget = stepBudget
    stuck = HarnessStuck(promptSent: date)
  }
}

enum Phase: Sendable {
  case ready
  /// Sent, not yet taken. The only phase a turn is replayed from.
  case awaitingAccept(TurnState)
  case running(TurnState)
  /// The process failed before accept; a new one starts when the retry is due.
  case retrying(TurnState)
  /// A new process is opening for the replay.
  case relaunching(TurnState)
  /// The stop ladder runs; `end` goes out once the group is gone.
  case stopping(TurnEnd?)
  case dead

  var name: String {
    switch self {
    case .ready: return "ready"
    case .awaitingAccept: return "awaitingAccept"
    case .running: return "running"
    case .retrying: return "retrying"
    case .relaunching: return "relaunching"
    case .stopping: return "stopping"
    case .dead: return "dead"
    }
  }
}

enum MachineInput: Sendable {
  case submit(TurnPrompt, at: Date, stepBudget: Int? = nil)
  case wire(WireEvent, at: Date)
  /// The CLI's process ended.
  case exited(HarnessRetry.Failure)
  case retryDue
  /// `finishGrace` passed after the `finish` tool.
  case finishDue
  /// The replay's new process opened and its mode verified.
  case opened(at: Date)
  case openFailed(StopReason)
  case tick(Date, HarnessStuck.Evidence)
  /// The person pressed Stop.
  case interrupt
  case shutdown
  /// The stop ladder finished.
  case stopped
}

enum Effect: Sendable, Equatable {
  case send(TurnPrompt)
  case emit(EngineEvent)
  case scheduleRetry(after: Duration)
  case scheduleFinish(after: Duration)
  /// End this process and open a new one for the replay.
  case relaunch
  case runStopLadder([StopStep])
}

/// What the session was opened with; fixed for its life.
struct Facts: Sendable {
  var expectedMode: ExpectedMode
  var argv: [String]
  var ladder: [StopStep] = StopLadder.standard
  /// `.declined` reaches the caller only where the person can be asked (`Access.asks`).
  var asks = true
  /// No CLI runs the turn: Serein talks to the provider itself.
  var directHTTP = false
}

struct Policy: Sendable {
  var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
}

/// The turn rules with no I/O: every input in, the next phase and what to do out.
enum Machine {
  static let finishGrace: Duration = .seconds(10)

  /// The `finish` tool under any MCP prefix (`mcp__serein_browser__finish`, `serein_browser__finish`).
  static func isFinish(_ tool: String) -> Bool { tool == "finish" || tool.hasSuffix("__finish") }

  static func step(_ phase: Phase, _ input: MachineInput, facts: Facts, policy: Policy) -> (Phase, [Effect]) {
    switch (phase, input) {
    case (.dead, _):
      return (.dead, [])
    case (.stopping(let end), .stopped):
      return (.dead, end.map { [.emit(.ended($0))] } ?? [])
    case (.stopping, _):
      return (phase, [])

    case (.ready, .submit(let prompt, let at, let budget)):
      return (.awaitingAccept(TurnState(prompt: prompt, at: at, stepBudget: budget)), [.send(prompt)])
    case (.ready, .shutdown):
      return (.stopping(nil), [.runStopLadder(facts.ladder)])
    case (.ready, .exited):
      return (.dead, [])
    case (.ready, _):
      return (.ready, [])

    case (.awaitingAccept(var turn), .wire(let event, let at)), (.running(var turn), .wire(let event, let at)):
      turn.stuck.heard(at: at)
      turn.noticed = false
      return wire(event, turn: turn, accepted: phase.name == "running", facts: facts, policy: policy)
    case (.awaitingAccept(let turn), .exited(let failure)):
      return failed(failure, turn: turn, stage: .sent, processAlive: false, policy: policy)
    case (.running(let turn), .exited(let failure)):
      return failed(failure, turn: turn, stage: .accepted, processAlive: false, policy: policy)
    case (.awaitingAccept(var turn), .tick(let now, let evidence)), (.running(var turn), .tick(let now, let evidence)):
      let silence = Int(now.timeIntervalSince(turn.stuck.lastHeard))
      switch turn.stuck.tick(now: now, evidence: evidence) {
      case .talking:
        return (same(phase, turn), [])
      case .quiet:
        guard !turn.noticed else { return (same(phase, turn), []) }
        turn.noticed = true
        return (same(phase, turn), [.emit(.notice("The \(facts.directHTTP ? "provider" : "CLI") has sent nothing for \(silence) s."))])
      case .stop:
        return cut(turn, .stuck(seconds: silence), facts: facts)
      }
    case (.awaitingAccept(let turn), .finishDue), (.running(let turn), .finishDue):
      return turn.finishing ? cut(turn, .finished, facts: facts) : (phase, [])
    case (.awaitingAccept(let turn), .interrupt), (.running(let turn), .interrupt),
      (.awaitingAccept(let turn), .shutdown), (.running(let turn), .shutdown):
      return cut(turn, .stopped, facts: facts)

    case (.retrying(let turn), .retryDue):
      return (.relaunching(turn), [.relaunch])
    case (.relaunching(var turn), .opened(let at)):
      turn.stuck = HarnessStuck(promptSent: at)
      return (.awaitingAccept(turn), [.send(turn.prompt)])
    case (.relaunching(let turn), .openFailed(let reason)):
      return (.dead, [.emit(.ended(TurnEnd(reason, sessionID: turn.sessionID)))])
    case (.retrying(let turn), .interrupt), (.relaunching(let turn), .interrupt),
      (.retrying(let turn), .shutdown), (.relaunching(let turn), .shutdown):
      return (.stopping(TurnEnd(.stopped, sessionID: turn.sessionID)), [.runStopLadder(facts.ladder)])
    case (.retrying, _), (.relaunching, _):
      // Output and exits of the process being replaced.
      return (phase, [])

    case (.awaitingAccept, _), (.running, _):
      return (phase, [])
    }
  }

  private static func wire(_ event: WireEvent, turn: TurnState, accepted: Bool, facts: Facts, policy: Policy) -> (Phase, [Effect]) {
    var turn = turn
    switch event {
    case .accepted:
      return (.running(turn), [])
    case .modeReported(let reported):
      if case .failure(let reason) = ModeCheck.verify(facts.expectedMode, reported: reported, argv: facts.argv) {
        return cut(turn, reason, facts: facts)
      }
      return (accepted ? .running(turn) : .awaitingAccept(turn), [])
    case .session(let id, let rebuilt):
      turn.sessionID = id
      return (.running(turn), [.emit(.session(id: id, rebuilt: rebuilt))])
    case .text(let text): return (.running(turn), [.emit(.text(text))])
    case .thinking(let text): return (.running(turn), [.emit(.thinking(text))])
    case .newMessage: return (.running(turn), [.emit(.newMessage)])
    case .usage(let input, let output, let cached):
      return (.running(turn), [.emit(.usage(input: input, output: output, cachedInput: cached))])
    // A level that never asks offers no approval, but the refusal is still history.
    case .declined(let approval):
      return (.running(turn), [.emit(facts.asks ? .declined(approval) : .permissionAnswered(allowed: false))])
    case .permissionAnswered(let allowed): return (.running(turn), [.emit(.permissionAnswered(allowed: allowed))])
    // Reports, not progress: they leave the phase as it was.
    case .context(let used, let size, let estimated):
      return (accepted ? .running(turn) : .awaitingAccept(turn), [.emit(.context(used: used, size: size, estimated: estimated))])
    case .commands(let commands):
      return (accepted ? .running(turn) : .awaitingAccept(turn), [.emit(.commands(commands))])
    case .notice(let text):
      return (accepted ? .running(turn) : .awaitingAccept(turn), [.emit(.notice(text))])
    case .limitReached(let limit):
      return (accepted ? .running(turn) : .awaitingAccept(turn), [.emit(.limitReached(limit))])
    case .usageLeft(let share):
      return (accepted ? .running(turn) : .awaitingAccept(turn), [.emit(.usageLeft(share))])
    case .toolStarted(let id, let name, let arguments, let shell):
      turn.openTools.append(id)
      turn.steps += 1
      if let shell, let risk = ShellRisk.of(shell) { turn.shellRisk = risk }
      let started = Effect.emit(.toolStarted(id: id, name: name, detail: shell ?? ""))
      if turn.loop.record(tool: name, arguments: arguments) {
        let (phase, effects) = cut(turn, .loop(tool: name), facts: facts)
        return (phase, [started] + effects)
      }
      if let budget = turn.stepBudget, turn.steps > budget {
        let (phase, effects) = cut(turn, .stepLimit(budget), facts: facts)
        return (phase, [started] + effects)
      }
      if isFinish(name), !turn.finishing {
        turn.finishing = true
        return (.running(turn), [started, .scheduleFinish(after: finishGrace)])
      }
      return (.running(turn), [started])
    case .toolEnded(let id, let result):
      turn.openTools.removeAll { $0 == id }
      return (.running(turn), [.emit(.toolEnded(id: id, result: result))])
    case .turnDone(let reason):
      let ended: StopReason = turn.finishing && reason == .endTurn ? .finished : reason
      let end = TurnEnd(ended, sessionID: turn.sessionID)
      return (.ready, unknownTools(turn) + [.emit(.ended(end))])
    case .failed(let message):
      return failed(.message(message), turn: turn, stage: accepted ? .accepted : .sent, processAlive: true, policy: policy)
    }
  }

  private static func failed(
    _ failure: HarnessRetry.Failure, turn: TurnState, stage: HarnessRetry.Stage, processAlive: Bool, policy: Policy
  ) -> (Phase, [Effect]) {
    // Gated here as well as in the rule: after accept or a risky shell step, a replay could run a tool twice.
    let verdict: HarnessRetry.Verdict =
      stage == .accepted ? .hold(.accepted)
      : turn.shellRisk.map { .hold(.shellRisk($0)) }
      ?? HarnessRetry.decide(failure, stage: stage, retries: turn.retries, shellRisk: nil, random: policy.random)
    switch verdict {
    case .replay(let attempt, let after):
      var next = turn
      next.retries = attempt
      let wait = Duration.milliseconds(Int64((after * 1_000).rounded()))
      return (.retrying(next), [.emit(.retrying(attempt: attempt, after: wait, reason: describe(failure))), .scheduleRetry(after: wait)])
    case .hold:
      let end = TurnEnd(reason(for: failure), sessionID: turn.sessionID)
      return (processAlive ? .ready : .dead, unknownTools(turn) + [.emit(.ended(end))])
    }
  }

  /// Ends the turn by ending the process; the end goes out once the group is gone.
  private static func cut(_ turn: TurnState, _ reason: StopReason, facts: Facts) -> (Phase, [Effect]) {
    (.stopping(TurnEnd(reason, sessionID: turn.sessionID)), unknownTools(turn) + [.runStopLadder(facts.ladder)])
  }

  private static func unknownTools(_ turn: TurnState) -> [Effect] {
    turn.openTools.map { .emit(.toolEnded(id: $0, result: .unknown)) }
  }

  private static func same(_ phase: Phase, _ turn: TurnState) -> Phase {
    if case .running = phase { return .running(turn) }
    return .awaitingAccept(turn)
  }

  private static func describe(_ failure: HarnessRetry.Failure) -> String {
    switch failure {
    case .message(let text): return text
    case .exited(let status, let stderr): return stderr.isEmpty ? "exited with status \(status)" : stderr
    case .signaled: return "ended by a signal"
    }
  }

  private static func reason(for failure: HarnessRetry.Failure) -> StopReason {
    let text = describe(failure)
    switch HarnessRetry.classify(failure) {
    case .terminal(.auth) where text.localizedCaseInsensitiveContains("api key"): return .keyFailure(text)
    case .terminal(.auth): return .signIn(text)
    case .terminal(.quota): return .usageLimit(text)
    case .terminal(.unknownModel): return .modelRejected(text)
    case .terminal(.notFound): return .resumeFailed(text)
    case .transient(.connectionReset), .transient(.timeout): return .offline(text)
    case .terminal(.providerSafety): return .refusal
    case .terminal(.interrupted): return .stopped
    default: return .failed(text)
    }
  }
}
