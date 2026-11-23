import Foundation

/// Stops a turn that keeps making the same call: one tool with identical arguments `limit` times
/// in a row. It replaces a cap on step count, so long useful turns run on.
public struct HarnessLoopGuard: Sendable {
  public static let limit = 4

  private var last: (tool: String, arguments: String)?
  private var repeats = 0

  public init() {}

  /// Records one tool call and returns true when it trips. `arguments` must be in one canonical
  /// form (for JSON, sorted keys) so equal calls compare equal.
  public mutating func record(tool: String, arguments: String) -> Bool {
    repeats = last.map { $0 == (tool, arguments) } == true ? repeats + 1 : 1
    last = (tool, arguments)
    return repeats >= Self.limit
  }
}
