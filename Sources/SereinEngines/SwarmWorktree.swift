import Foundation

/// Isolated git worktree management for parallel swarm writers so concurrent agents never mutate
/// the same working directory simultaneously.
public enum SwarmWorktree {
  public struct Handle: Equatable, Sendable {
    public let repoRoot: URL
    public let worktreeURL: URL
    public init(repoRoot: URL, worktreeURL: URL) {
      self.repoRoot = repoRoot
      self.worktreeURL = worktreeURL
    }
  }

  /// Creates a detached worktree at `baseDirectory/<name>` when `folder` is inside a git repository.
  /// Returns nil when `folder` is not a git repo.
  public static func create(repo folder: URL, name: String, baseDirectory: URL) throws -> Handle? {
    guard let root = gitRoot(of: folder) else { return nil }
    let safe = name.replacingOccurrences(of: "[^a-zA-Z0-9._-]+", with: "-", options: .regularExpression)
    let target = baseDirectory.appendingPathComponent("wt-\(safe)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    let result = runGit(["-C", root.path, "worktree", "add", "--detach", target.path, "HEAD"])
    guard result.status == 0 else {
      throw NSError(domain: "SwarmWorktree", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
    }
    return Handle(repoRoot: root, worktreeURL: target)
  }

  /// Removes a worktree created by `create(repo:name:baseDirectory:)`.
  public static func remove(_ handle: Handle) {
    _ = runGit(["-C", handle.repoRoot.path, "worktree", "remove", "--force", handle.worktreeURL.path])
    try? FileManager.default.removeItem(at: handle.worktreeURL)
  }

  private static func gitRoot(of folder: URL) -> URL? {
    let res = runGit(["-C", folder.path, "rev-parse", "--show-toplevel"])
    guard res.status == 0 else { return nil }
    let trimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
  }

  private static func runGit(_ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
      try p.run()
      p.waitUntilExit()
      let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      return (p.terminationStatus, out, err)
    } catch {
      return (-1, "", error.localizedDescription)
    }
  }
}
