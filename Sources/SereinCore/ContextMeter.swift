import Foundation

/// "about 42% of context" on a task's result line: how much of the model's context window the
/// task's last request filled. The harness's own counts when it reports them (the request's size
/// and the window); otherwise an estimate from the chat's text against the model's known window,
/// labelled "estimate". A route that reports no size and whose window Serein does not know shows
/// nothing. Kept with the run's record (`RunRecord.context`) so the line reads the same later.
public struct ContextMeter: Codable, Equatable, Sendable {
  /// 1 to 100.
  public var percent: Int
  /// The request's size or the window was not reported by the harness.
  public var estimated: Bool
  /// Above this the line turns to the warning colour and suggests a fresh task.
  public static let warning = 80
  /// The one line under a meter past `warning`.
  public static let advice = "Context is nearly full. Open the session log and Continue from here in a fresh task."

  public init(percent: Int, estimated: Bool) {
    self.percent = percent
    self.estimated = estimated
  }

  public var warns: Bool { percent > Self.warning }
  public var label: String { "about \(percent)% of context" + (estimated ? " (estimate)" : "") }

  /// `reported`: the last request's tokens as the harness printed them; `window`: the window it
  /// printed; `estimate`: tokens guessed from the chat's text; `knownWindow`: the model's window
  /// when the harness prints none. Nil when there is no size or no window to set it against.
  public static func measure(reported: Int?, window: Int?, estimate: Int?, knownWindow: Int?) -> ContextMeter? {
    let given = reported.flatMap { $0 > 0 ? $0 : nil }
    let size = window.flatMap { $0 > 0 ? $0 : nil }
    guard let tokens = given ?? estimate.flatMap({ $0 > 0 ? $0 : nil }),
      let of = size ?? knownWindow.flatMap({ $0 > 0 ? $0 : nil })
    else { return nil }
    let share = Int((Double(tokens) * 100 / Double(of)).rounded())
    return ContextMeter(percent: min(100, max(1, share)), estimated: given == nil || size == nil)
  }

  /// The window of a model whose harness may print none: Claude Code's models have 200,000
  /// tokens, or 1,000,000 with the long-context choice (`[1m]`). Nil for every other harness,
  /// whose models Serein does not know.
  public static func knownWindow(_ driver: HarnessDriver?, model: String) -> Int? {
    guard driver == .claude else { return nil }
    return ClaudeModelID.split(model).longContext ? 1_000_000 : 200_000
  }
}
