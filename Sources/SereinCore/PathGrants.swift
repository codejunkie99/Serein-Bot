import Foundation

/// R22: the person's yes on a confirm with a path widens the fence for that task only. Read by
/// AgentFileGuard and LaunchContract on the next launch or step. In memory: a widening lasts the
/// task's life and no longer.
public final class PathGrants: @unchecked Sendable {
  public static let shared = PathGrants()
  private let lock = NSLock()
  private var byTask: [String: [String]] = [:]

  public func widen(task: String, path: String) {
    lock.withLock {
      if !(byTask[task] ?? []).contains(path) { byTask[task, default: []].append(path) }
    }
  }
  public func paths(task: String) -> [String] { lock.withLock { byTask[task] ?? [] } }
  /// The folders a launch of task `task` may also write (M2), resolved as they are opened. Only
  /// absolute paths, and never one that is, holds or lies in Serein's private stores, a protected
  /// folder (sign-ins, keychains) or the home folder itself.
  public func roots(task: String, home: URL, library: URL?) -> [URL] {
    let real = { AgentFileGuard.physicalPath($0) }
    let closed = (AgentFileGuard.sereinPrivateRoots(home: home, library: library).map(\.path)
      + AgentFileGuard.protectedPaths(home: home)).map(real)
    let homePath = real(home.path)
    return paths(task: task).filter { $0.hasPrefix("/") }.map(real).filter { path in
      path != "/" && !AgentFileGuard.within(homePath, path)
        && !closed.contains { AgentFileGuard.within(path, $0) || AgentFileGuard.within($0, path) }
    }.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }
  public func forget(task: String) { lock.withLock { byTask[task] = nil } }
}
