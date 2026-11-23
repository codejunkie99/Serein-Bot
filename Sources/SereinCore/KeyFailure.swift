import Foundation

/// An AI app's own error that says its key failed: it expired, or it was not accepted (revoked,
/// invalid, wrong, or a 401). Read from the raw error, because `TurnFailure.plainReason` drops any
/// sentence holding "api", and these sentences almost always do.
public enum KeyFailure: String, Hashable, Sendable {
  case expired
  case notAccepted

  /// Lowercased phrases from real AI app errors, checked in order; a bare 401 is checked last.
  static let table: [(phrase: String, failure: KeyFailure)] = [
    ("key has expired", .expired), ("key is expired", .expired), ("key expired", .expired),
    ("invalid x-api-key", .notAccepted), ("invalid api key", .notAccepted), ("incorrect api key", .notAccepted),
    ("invalid_api_key", .notAccepted), ("api key not valid", .notAccepted), ("api key is invalid", .notAccepted),
    ("wrong api key", .notAccepted), ("key has been revoked", .notAccepted), ("key was revoked", .notAccepted),
    ("unauthorized", .notAccepted),
  ]

  /// nil for every other error. Past 600 characters it is a log, not the app's answer, as in
  /// `HarnessParse.asksSignIn`.
  public static func of(_ error: String?) -> KeyFailure? {
    guard let error, error.count <= 600 else { return nil }
    let lower: String = error.lowercased()
    if let row = table.first(where: { lower.contains($0.phrase) }) { return row.failure }
    return lower.range(of: #"\b401\b"#, options: .regularExpression) != nil ? .notAccepted : nil
  }

  /// The failure line's reason: "OpenCode's key has expired."
  public func reason(app: String) -> String {
    self == .expired ? "\(app)'s key has expired." : "\(app)'s key was not accepted."
  }

  /// The card that takes a new key: it asks, hands one key over per Save, and lets the person's
  /// message go again exactly once, when the key was taken. The key only passes through `begin`.
  public struct Ask: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case asking, handing, saved, declined }
    public private(set) var step: Step = .asking
    /// One plain sentence when the last hand-over failed; the field stays for another try.
    public private(set) var refusal: String?
    public init() {}

    /// Save: false for a blank key, or while one is already on its way or settled.
    public mutating func begin(_ key: String) -> Bool {
      guard step == .asking, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      step = .handing
      refusal = nil
      return true
    }
    /// The hand-over's answer, nil when the key was taken. true only the one time the message goes again.
    public mutating func handed(_ failure: String?) -> Bool {
      guard step == .handing else { return false }
      guard failure == nil else {
        step = .asking
        refusal = failure
        return false
      }
      step = .saved
      return true
    }
    /// Not now, or Escape.
    public mutating func decline() {
      if step == .asking { step = .declined }
    }
  }
}
