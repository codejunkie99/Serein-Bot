import Foundation

/// What happens when a turn stops with no model running to pick the next move: one table from
/// each cause to an ordered list of arms, read by EngineTurn, the hub and the no-stall suite
/// (R28). The mapping from `StopReason` and `EngineRefusal` lives in SereinEngines
/// (StopNote+Turn.swift), because those types do.
public enum StopNote {
  public enum End: Sendable, Equatable {
    case done
    case stoppedByPerson
    case stuck(routes: [String], nextAction: String)
  }

  public enum Next: Sendable, Equatable {
    /// Same session; the line is the next turn's first line.
    case tell(String)
    case freshSession
    /// Never an app already in `Tried.apps` (R5).
    case otherApp
    case retry
    /// Holds no slot (R5).
    case waitForReset(until: Date?)
    /// A card is open.
    case waitForPerson
    case end(End)
  }

  /// Every way a turn can stop, plus hub limits and judge results.
  public enum Cause: String, Sendable, Hashable, CaseIterable, Codable {
    // StopReason, without parked, which is deleted:
    case endTurn, maxTokens, refusal, loop, stuck, stopped, modeMismatch, signIn, usageLimit,
      failed, finishedDone, finishedStuck, stepLimit, keyFailure, modelRejected, offline, resumeFailed
    case declined
    // EngineRefusal:
    case cliCannot, versionTooOld, notReady, threadBusy, needsRepair
    // Hub and judge:
    case hardLimit, idleLimit, workLeft, judgeUnknown, cardExpired
  }

  public enum Arm: Sendable, Equatable {
    case tell, freshSession, otherApp, retry, waitForReset, waitForPerson
    case done, stoppedByPerson, stuck
  }

  public struct Step: Sendable, Equatable {
    public let arm: Arm
    public let times: Int
  }

  private static func steps(_ arms: (Arm, Int)...) -> [Step] { arms.map { Step(arm: $0.0, times: $0.1) } }

  /// Each cause's arms in order, each with how often it may fire. The last arm ends the task.
  public static let table: [Cause: [Step]] = {
    var table: [Cause: [Step]] = [:]
    for cause in Cause.allCases {
      switch cause {
      case .endTurn, .finishedDone: table[cause] = steps((.done, 1))
      case .maxTokens, .stuck, .hardLimit, .idleLimit: table[cause] = steps((.tell, 1), (.freshSession, 1), (.stuck, 1))
      case .refusal, .signIn: table[cause] = steps((.tell, 1), (.otherApp, 1), (.stuck, 1))
      case .loop, .declined, .cardExpired: table[cause] = steps((.tell, 1), (.stuck, 1))
      case .modeMismatch, .failed, .resumeFailed: table[cause] = steps((.freshSession, 1), (.otherApp, 1), (.stuck, 1))
      case .usageLimit: table[cause] = steps((.otherApp, 1), (.waitForReset, 1), (.stuck, 1))
      case .stepLimit: table[cause] = steps((.tell, Tried.refillCap), (.stuck, 1))
      case .offline: table[cause] = steps((.retry, HarnessRetry.maxAttempts), (.stuck, 1))
      case .keyFailure, .modelRejected, .cliCannot, .versionTooOld, .notReady, .needsRepair:
        table[cause] = steps((.otherApp, 1), (.stuck, 1))
      case .threadBusy: table[cause] = steps((.retry, 1), (.stuck, 1))
      case .workLeft, .judgeUnknown: table[cause] = steps((.tell, 1), (.stuck, 1))
      case .finishedStuck: table[cause] = steps((.stuck, 1))
      case .stopped: table[cause] = steps((.stoppedByPerson, 1))
      }
    }
    return table
  }()

  /// The next arm for `cause`, counted in `tried`. Past the total cap, or past every arm, the task
  /// ends stuck with the lines already sent as its routes (R5, R34). `cardOpen`: a card waits on
  /// the person, so a turn that ended by itself waits with it.
  public static func next(_ cause: Cause, tried: inout Tried, cardOpen: Bool, line: String) -> Next {
    if cardOpen, cause == .endTurn || cause == .finishedDone { return .waitForPerson }
    let used = tried.used[cause, default: 0]
    tried.used[cause] = used + 1
    var left = used
    var arm = Arm.stuck
    for step in table[cause] ?? [] {
      arm = step.arm
      if left < step.times { break }
      left -= step.times
    }
    let continues: Set<Arm> = [.tell, .freshSession, .otherApp, .retry]
    if continues.contains(arm) {
      guard tried.continuations < Tried.continuationCap else { return .end(stuck(tried, cause: cause)) }
      tried.continuations += 1
      tried.notes.append(line)
    }
    switch arm {
    case .tell: return .tell(line)
    case .freshSession: return .freshSession
    case .otherApp: return .otherApp
    case .retry:
      tried.retries += 1
      return .retry
    case .waitForReset: return .waitForReset(until: nil)
    case .waitForPerson: return .waitForPerson
    case .done: return .end(.done)
    case .stoppedByPerson: return .end(.stoppedByPerson)
    case .stuck: return .end(stuck(tried, cause: cause))
    }
  }

  private static func stuck(_ tried: Tried, cause: Cause) -> End {
    .stuck(routes: tried.notes, nextAction: line(cause))
  }

  /// Fixed text per cause, without its parts. Every line is Serein's own words, never the CLI's.
  public static func line(_ cause: Cause, tool: String = "same", seconds: Int = 0, steps: Int = 0, app: String = "The app",
                          left: String = "", step: String = "a step", card: String = "the card") -> String
  {
    switch cause {
    case .refusal:
      return "Your last turn ended as a refusal. Take another route to the same result, or call finish with outcome stuck and the routes you tried."
    case .loop: return "You repeated the same \(tool) call. It will not change. Take another route."
    case .stuck, .idleLimit: return "You were silent for \(seconds) seconds and the turn was ended. Carry on from your last step."
    case .maxTokens: return maxTokensLine
    case .stepLimit: return "You used \(steps) steps. You have a new budget. Carry on, and say in one line what is left."
    case .signIn: return "\(app) needs signing in. Call agent_sign_in for it, and carry on with the task."
    case .workLeft: return "You ended with this left: \(left). Do it now, or call finish with outcome stuck."
    case .judgeUnknown: return Judge.unknownLine
    case .declined: return "Your app's own rules declined \(step). Take another route."
    case .cardExpired:
      return "The person did not answer \(card). Finish the other parts, or finish stuck with \(card) as the next action."
    case .hardLimit: return "The task reached its time limit and the turn was ended. Carry on from your last step, in smaller steps."
    case .modeMismatch, .failed, .resumeFailed, .offline, .threadBusy, .usageLimit, .keyFailure, .modelRejected,
      .cliCannot, .versionTooOld, .notReady, .needsRepair:
      return "\(app) could not go on (\(reason(cause))). Carry on with the task from your last step."
    case .endTurn, .finishedDone, .finishedStuck, .stopped: return ""
    }
  }
  public static let maxTokensLine = "Your answer was cut at the length limit. Carry on from where it stopped, in smaller steps."

  /// The fixed sentence for a stop reason, never the CLI's raw text.
  public static func reason(_ cause: Cause) -> String {
    switch cause {
    case .modeMismatch: return "it did not start in the mode Serein asked for"
    case .failed: return "it failed"
    case .resumeFailed: return "it could not resume its session"
    case .offline: return "it could not reach the network"
    case .threadBusy: return "its thread was still busy"
    case .usageLimit: return "it reached its usage limit"
    case .keyFailure: return "its key was refused"
    case .modelRejected: return "it does not offer that model"
    case .cliCannot: return "it cannot run this kind of task"
    case .versionTooOld: return "it is too old for this task"
    case .notReady: return "it is not ready"
    case .needsRepair: return "it needs repair"
    default: return cause.rawValue
    }
  }

  /// Sketch.swift's signature: the line without its parts.
  public static func line(_ cause: Cause, tried: Tried) -> String { line(cause) }

  /// A hub limit (R4, R34). The clocks pause while the run waits for the person.
  public static func next(after limit: HubLimit, tried: inout Tried, waiting: Bool) -> Next {
    if waiting { return .waitForPerson }
    let cause: Cause = limit == .hard ? .hardLimit : .idleLimit
    return next(cause, tried: &tried, cardOpen: false, line: line(cause))
  }

  /// R19: a resend carries the steps whose outcome is unknown. Nothing is replayed by code.
  public static func journalLine(_ steps: [String]) -> String? {
    steps.isEmpty ? nil : "These steps may already have run: \(steps.joined(separator: ", ")). Check before repeating."
  }
}

/// A task's stop counts, carried in its run record (R5, R34).
public struct Tried: Sendable, Equatable, Codable {
  public static let continuationCap = 12
  public static let refillCap = 2
  public static let quietLimit = 3
  /// Total over every cause (R34).
  public var continuations = 0
  public var refills = 0
  public var apps: [HarnessDriver] = []
  public var judge: Judge.Reading?
  public var retries = 0
  public var used: [StopNote.Cause: Int] = [:]
  /// Turns in a row with no tool call; finish is not progress (R34).
  public var quiet = 0
  /// The lines sent, reused as routes when the task ends stuck.
  public var notes: [String] = []
  public init() {}
}

public enum HubLimit: Sendable, Equatable { case hard, idle }
