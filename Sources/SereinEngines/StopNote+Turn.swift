import Foundation
import SereinCore

/// The stop table's readings of the engine's own types, which SereinCore cannot see.
extension StopNote {
  public static func cause(_ reason: StopReason, finish: FinishCall? = nil) -> Cause {
    switch reason {
    case .endTurn: return .endTurn
    case .maxTokens: return .maxTokens
    case .refusal: return .refusal
    case .loop: return .loop
    case .stuck: return .stuck
    case .stopped: return .stopped
    case .modeMismatch: return .modeMismatch
    case .signIn: return .signIn
    case .usageLimit: return .usageLimit
    case .failed: return .failed
    case .finished:
      if case .stuck = finish { return .finishedStuck }
      return .finishedDone
    case .stepLimit: return .stepLimit
    case .keyFailure: return .keyFailure
    case .modelRejected: return .modelRejected
    case .offline: return .offline
    case .resumeFailed: return .resumeFailed
    case .declined: return .declined
    }
  }

  public static func cause(_ refusal: EngineRefusal) -> Cause {
    switch refusal {
    case .cliCannot: return .cliCannot
    case .versionTooOld: return .versionTooOld
    case .notReady: return .notReady
    case .threadBusy: return .threadBusy
    case .needsRepair: return .needsRepair
    }
  }

  /// The line with its parts filled from the reason, never from the CLI's own words.
  public static func line(for reason: StopReason, app: String = "The app") -> String {
    let cause = cause(reason)
    switch reason {
    case .loop(let tool): return line(cause, tool: tool)
    case .stuck(let seconds): return line(cause, seconds: seconds)
    case .stepLimit(let steps): return line(cause, steps: steps)
    case .declined(let step): return line(cause, step: step)
    default: return line(cause, app: app)
    }
  }

  public static func next(
    after reason: StopReason, finish: FinishCall?, tried: inout Tried, cardOpen: Bool, app: String = "The app"
  ) -> Next {
    if case .stepLimit = reason { tried.refills += 1 }
    return next(cause(reason, finish: finish), tried: &tried, cardOpen: cardOpen, line: line(for: reason, app: app))
  }

  public static func next(before refusal: EngineRefusal, tried: inout Tried, app: String = "The app") -> Next {
    let cause = cause(refusal)
    return next(cause, tried: &tried, cardOpen: false, line: line(cause, app: app))
  }
}
