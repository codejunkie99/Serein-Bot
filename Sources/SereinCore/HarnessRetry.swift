import Foundation

/// Whether a failed turn is sent again, and after how long. A provider hiccup (429, 5xx,
/// overloaded, reset) gets up to `maxAttempts` tries; an auth or request-shape problem gets none.
/// A turn is only ever replayed before the CLI accepted it, and never once its shell steps looked
/// like a push, publish or payment. Pure: the jitter source is passed in.
public enum HarnessRetry {
  public static let maxAttempts = 3
  /// Wait before retry N (0-based), +-25%. With three attempts only the first two are used.
  public static let backoffBase: [TimeInterval] = [1, 3, 8]

  public enum Transient: String, Sendable { case rateLimited, overloaded, serverError, connectionReset, timeout }
  public enum Terminal: String, Sendable {
    case auth, quota, unknownModel, invalidRequest, notFound, providerSafety, terminalExit, interrupted, unknown
  }
  public enum Fault: Equatable, Sendable { case transient(Transient), terminal(Terminal) }

  /// What the driver saw fail. `message` is error text from a stream or RPC (an error and its
  /// cause joined); `exited` is a CLI that ended with a status; `signaled` is a CLI killed by a signal.
  public enum Failure: Equatable, Sendable {
    case message(String)
    case exited(status: Int32, stderr: String)
    case signaled
  }

  /// How far the turn got. `accepted` means the CLI acked the prompt, or anything streamed or
  /// a model call answered: from there a replay could re-run tools.
  public enum Stage: Sendable { case launching, sent, accepted }

  public enum Hold: Equatable, Sendable { case accepted, shellRisk(ShellRisk), cleanExit, terminal(Terminal), attemptsUsed }
  public enum Verdict: Equatable, Sendable {
    /// Send the turn again as retry number `attempt` (1-based) after `after` seconds.
    case replay(attempt: Int, after: TimeInterval)
    case hold(Hold)
  }

  // Order matters: every terminal pattern is read before the transient 429 one.
  private static let terminalPatterns: [(String, Terminal)] = [
    (#"\b(?:40[13]|unauthorized|forbidden|invalid api key|missing bearer|authentication required|not logged in|logged out)\b"#, .auth),
    (usageLimit, .quota),
    (#"\b402\b|\bquota\b|\bbilling\b|\bsubscription\b"#, .quota),
    (#"\bmodel not found\b|\bunknown model\b|\bdoes not exist for model\b|\bunsupported model\b"#, .unknownModel),
    (#"\bunsupported package for\b|\bprovider\.no-route\b"#, .unknownModel),
    (#"\bcan't use (?:the|this bot's) model\b"#, .unknownModel),
    (#"\b400\b|\b422\b|\binvalid request\b|\bmalformed\b"#, .invalidRequest),
    (#"\b404\b|\bno such thread\b|\bthread gone\b"#, .notFound),
    // A turn the person stopped must never come back as an auto-retry.
    (#"\b(?:interrupted|cancelled by user)\b"#, .interrupted),
    (#"\bcertificate[ _]verify[ _]failed\b"#, .unknown),
  ]
  private static let transientPatterns: [(String, Transient)] = [
    (#"\b(?:429|rate.?limit|too many requests)\b"#, .rateLimited),
    (#"\boverloaded\b|\bcapacity\b"#, .overloaded),
    (#"\b5\d{2}\b|\binternal server error\b|\binternal service failure\b|\bServiceUnavailableError\b|\bbad gateway\b|\bservice unavailable\b"#, .serverError),
    // Codex's ChatGPT workspace routing lookup; only its "unauthorized" variant is a sign-in problem.
    (#"\bworkspace routing discovery (?:failed|timed out)\b"#, .serverError),
    (#"\b(?:econnreset|econnrefused|epipe|etimedout|eai_again|unexpected_eof_while_reading|connection reset|connection refused|socket hang up|network error|fetch failed)\b"#, .connectionReset),
    (#"\btimeout(ed)?\b|\btimed? out\b"#, .timeout),
  ]
  /// A subscription's usage running out: terminal even when phrased as a rate limit.
  private static let usageLimit = #"\busage limit\b|\bhit your (?:(?!rate\b)[\w'’-]+ ){0,3}(?:limit|budget)\b|\b(?:weekly|daily|monthly|subscription|usage|session|5-hour) limit reached\b|\bout of (?:usage(?: credits)?|extra usage|credits)\b"#
  /// Provider error wording, not an assistant discussing safety: a surrounding 5xx or 429 must not replay it.
  private static let providerSafety = #"\bblocked by (?:our|the provider['’]s) safety systems\b|\bsafety monitoring\b.{0,100}\b(?:paused|ended|blocked)\b|\b(?:safety_check_failed|safety_policy_violation)\b"#

  public static func classify(_ failure: Failure) -> Fault {
    let text: String
    switch failure {
    case .signaled: return .terminal(.interrupted)
    case .message(let message): text = message
    case .exited(_, let stderr): text = stderr
    }
    func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    if matches(providerSafety) { return .terminal(.providerSafety) }
    if let hit = terminalPatterns.first(where: { matches($0.0) }) { return .terminal(hit.1) }
    if let hit = transientPatterns.first(where: { matches($0.0) }) { return .transient(hit.1) }
    // A nonzero exit with no recognisable text: the CLI already reported its own failure.
    if case .exited = failure { return .terminal(.terminalExit) }
    return .terminal(.unknown)
  }

  /// Seconds to wait before retry `attempt` (0-based); `random` returns a value in 0...1.
  public static func backoff(attempt: Int, random: () -> Double) -> TimeInterval {
    let base = backoffBase[min(max(attempt, 0), backoffBase.count - 1)]
    return base * 0.75 + random() * base * 0.5
  }

  /// `retries` is how many times this turn was already sent again (0 on its first failure).
  /// `shellRisk` is the worst the turn's shell steps looked, from the caller's classifier.
  public static func decide(_ failure: Failure, stage: Stage, retries: Int, shellRisk: ShellRisk?,
                            random: () -> Double) -> Verdict {
    if let shellRisk { return .hold(.shellRisk(shellRisk)) }
    if stage == .accepted { return .hold(.accepted) }
    if retries >= maxAttempts - 1 { return .hold(.attemptsUsed) }
    let fault = classify(failure)
    if stage == .launching {
      // The CLI never took the prompt, so nothing ran: send again at once, unless the cause will repeat.
      if case .terminal(let reason) = fault, ![.terminalExit, .unknown].contains(reason) { return .hold(.terminal(reason)) }
      return .replay(attempt: retries + 1, after: 0)
    }
    if case .exited(0, _) = failure { return .hold(.cleanExit) }
    switch fault {
    case .terminal(let reason): return .hold(.terminal(reason))
    case .transient: return .replay(attempt: retries + 1, after: backoff(attempt: retries, random: random))
    }
  }
}
