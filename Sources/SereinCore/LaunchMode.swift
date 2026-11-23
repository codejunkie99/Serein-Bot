import Foundation

/// How a process was started, from its arguments. Only a normal launch may open the person's
/// library; a check, a preview or a stress run opens a throwaway one under the system's temp folders.
public struct LaunchMode: Equatable, Sendable {
  /// A check (`--verify…`). Checks exist only in debug builds, so a release build reads the flags as nothing.
  public let checking: Bool
  public let previewing: Bool
  public let stress: Bool

  public init(arguments: [String], checksBuilt: Bool) {
    checking = checksBuilt && arguments.contains { $0.hasPrefix("--verify") }
    previewing = arguments.contains("--ui-preview")
    stress = arguments.contains("--stress")
  }

  /// `library` is SEREIN_DATA_DIR resolved, nil when unset; `temporary` the temp roots resolved.
  public func mayOpen(library: String?, temporary: [String]) -> Bool {
    guard checking || previewing || stress else { return true }
    guard let library else { return false }
    return temporary.contains { library.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
  }
}
