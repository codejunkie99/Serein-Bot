import Foundation

/// A shell step whose effect leaves this Mac and cannot be taken back by running the turn again.
/// A turn that ran one is never replayed (`HarnessRetry.decide`); it resumes and the step's outcome
/// is unknown. The classifier is a separate function so the retry rule never holds a keyword list.
public enum ShellRisk: String, Equatable, Sendable {
  case push, publish, pay

  // shortcut: a word match on the command line, so a wrapper script hides its push; a miss only matters if the stage rule also missed.
  private static let patterns: [(String, ShellRisk)] = [
    (#"\bgit(?:\s+-C\s+\S+|\s+--?[\w-]+(?:=\S+)?)*\s+push\b"#, .push),
    (#"\b(?:npm|pnpm|yarn|bun|cargo)\s+publish\b|\btwine\s+upload\b|\bgem\s+push\b|\bdocker\s+push\b|\bgh\s+release\s+create\b"#, .publish),
    (#"api\.stripe\.com|\bstripe\s|api\.paypal\.com|api-m\.paypal\.com"#, .pay),
  ]

  /// The risk one shell command line looks like, or nil.
  public static func of(_ command: String) -> ShellRisk? {
    patterns.first { command.range(of: $0.0, options: [.regularExpression, .caseInsensitive]) != nil }?.1
  }
}
