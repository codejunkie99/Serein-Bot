import Foundation
import SereinCore

/// A decider on the Jev client FastSteps already has: one finite choice with a calibrated
/// probability decides one small seam, the answer is validated before use, and every failure — no
/// key, timeout, an answer that does not check out, or a confidence under the threshold — returns
/// nil, meaning the caller does exactly what it would have done without a decider. It never does
/// the work.
@MainActor enum RelayDecider {
  /// A fixed floor on the decider's confidence, not fitted; anything less sure falls back.
  static let threshold = 0.6

  struct Triage: Equatable {
    var hold: Bool
    var confidence: Double
  }

  /// Whether a finished delegated run is worth a turn right now. nil means "tell the user as
  /// before" — the fail-open answer.
  static func triageFinishedReport(summary: String, outcome: String, panelVisible: Bool) async -> Triage? {
    // The user is right there: reports are cheap and welcome; spending a decision on them is not.
    guard !panelVisible else { return nil }
    return await decide(
      state: [
        "run_outcome": outcome,
        // The summary may quote a website; only redacted text goes to the decision model.
        "run_summary": AgentPrivacy.redact(String(summary.prefix(600))),
      ],
      question: [
        "type": "choice",
        "criteria": [
          "tell": "The result changes something the user is waiting on, failed, or needs a decision",
          "hold": "Routine success on work the user can check later",
        ],
        "instructions": ["rules":
          "Decide whether the user should be told immediately. Routine successes can wait in the activity list; failures and answers the user is blocked on cannot."],
      ])
  }

  /// The one seam, shared shape: ask, validate, threshold, fail open.
  static func decide(state: [String: Any], question: [String: Any]) async -> Triage? {
    guard FastSteps.available else { return nil }
    let questions: [String: Any] = [
      "report": question,
    ]
    guard let (answers, calibrated) = try? await FastSteps.ask(state: state, questions: questions),
      let answer = answers["report"] as? [String: Any],
      let choice = answer["choice"] as? String, ["tell", "hold"].contains(choice),
      let confidence = number(answer["confidence"])
    else { return nil }
    // A distribution must name every choice, sum to one, and put the choice on top; an
    // uncalibrated answer (OpenRouter) is the model's own estimate and skips that check.
    if let raw = answer["probabilities"] as? [String: Any] {
      let probabilities = raw.compactMapValues(number)
      guard probabilities.count == raw.count, Set(probabilities.keys) == ["tell", "hold"],
        abs(probabilities.values.reduce(0, +) - 1) < 0.02,
        let top = probabilities.values.max(), (probabilities[choice] ?? -1) >= top - 1e-6
      else { return nil }
      _ = calibrated
    }
    guard confidence >= threshold else { return nil }
    return Triage(hold: choice == "hold", confidence: confidence)
  }

  private static func number(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite && d >= 0 && d <= 1 ? d : nil
  }
}
