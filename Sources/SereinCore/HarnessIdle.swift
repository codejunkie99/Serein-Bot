
import Foundation

/// How long a thread's warm CLI stays up after a turn before it is closed. The next turn resumes
/// its session by id.
public enum HarnessIdle {
  public static let idle: TimeInterval = 10 * 60
  /// A thread nobody had in front of them this long (delegated work, a routine)...
  public static let watchedWindow: TimeInterval = 30 * 60
  /// ...keeps its CLI only this long.
  public static let unwatched: TimeInterval = 30
  public static let floor: TimeInterval = 10

  /// `lastSeen` is when the person last wrote in, opened or read the thread. `lowMemory` is the
  /// shorter idle the caller picks when the Mac is short of memory, or nil.
  public static func closeAfter(lastSeen: Date?, now: Date, lowMemory: TimeInterval? = nil) -> TimeInterval {
    let configured = lowMemory.map { min(idle, $0) } ?? idle
    let watched = lastSeen.map { now.timeIntervalSince($0) <= watchedWindow } ?? false
    return max(floor, watched ? configured : min(configured, unwatched))
  }
}
