import Foundation

/// Isolated git worktree management for parallel swarm writers so concurrent agents never mutate
/// the same working directory simultaneously.
public enum SwarmWorktree {
  public struct Handle: Equatable, Sendable {
    public let repoRoot: URL
    public let worktreeURL: URL
    /// The folder inside the worktree that stands for the folder `create` was given.
    public let folder: URL
    public init(repoRoot: URL, worktreeURL: URL, folder: URL? = nil) {
      self.repoRoot = repoRoot
      self.worktreeURL = worktreeURL
      self.folder = folder ?? worktreeURL
    }
  }

  /// Where a swarm's worktrees go: below the repository, like `TaskWorktree`, so they survive a
  /// restart and the folder's own access already reaches them. Nil when `folder` is not in a repo.
  public static func base(for folder: URL, run: String) -> URL? {
    gitRoot(of: folder).map { $0.root.appendingPathComponent(".serein/swarm/\(run)", isDirectory: true) }
  }

  /// Creates a detached worktree at `baseDirectory/<name>` when `folder` is inside a git repository.
  /// Returns nil when `folder` is not a git repo.
  public static func create(repo folder: URL, name: String, baseDirectory: URL) throws -> Handle? {
    guard let (root, prefix) = gitRoot(of: folder) else { return nil }
    let safe = name.replacingOccurrences(of: "[^a-zA-Z0-9._-]+", with: "-", options: .regularExpression)
    let target = baseDirectory.appendingPathComponent("wt-\(safe)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    if baseDirectory.path.hasPrefix(root.path + "/.serein/") { try excludeSerein(root) }
    let result = runGit(["-C", root.path, "worktree", "add", "--detach", target.path, "HEAD"])
    guard result.status == 0 else {
      throw NSError(domain: "SwarmWorktree", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
    }
    return Handle(repoRoot: root, worktreeURL: target, folder: prefix.isEmpty ? target : target.appendingPathComponent(prefix, isDirectory: true))
  }

  /// Everything the worktree changed against the commit it started from, new files included, as a
  /// patch `apply` takes. Empty when nothing changed; nil when git failed.
  /// shortcut: the patch is decoded as UTF-8, so a text file in another encoding fails to apply and
  /// its worktree is kept; carry `Data` end to end if that shows up.
  public static func diff(_ handle: Handle) -> String? {
    guard runGit(["-C", handle.worktreeURL.path, "add", "-A"]).status == 0 else { return nil }
    let result = runGit(["-C", handle.worktreeURL.path, "diff", "--cached", "--binary", "HEAD"])
    return result.status == 0 ? result.stdout : nil
  }

  /// Applies `patch` to the working tree of the handle's repository, never its index or history.
  /// `git apply` is all or nothing, so a patch that does not fit leaves every file as it was.
  /// Returns git's reason when it did not apply.
  public static func apply(_ patch: String, to handle: Handle) -> String? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("serein-swarm-\(UUID().uuidString).patch")
    defer { try? FileManager.default.removeItem(at: file) }
    do { try patch.write(to: file, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
    let result = runGit(["-C", handle.repoRoot.path, "apply", file.path])
    return result.status == 0 ? nil : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Removes a worktree created by `create(repo:name:baseDirectory:)`.
  public static func remove(_ handle: Handle) {
    _ = runGit(["-C", handle.repoRoot.path, "worktree", "remove", "--force", handle.worktreeURL.path])
    try? FileManager.default.removeItem(at: handle.worktreeURL)
    // rmdir removes only an empty folder: the run's folder goes with its last worktree.
    rmdir(handle.worktreeURL.deletingLastPathComponent().path)
  }

  /// The repository root and `folder`'s path below it.
  private static func gitRoot(of folder: URL) -> (root: URL, prefix: String)? {
    let res = runGit(["-C", folder.path, "rev-parse", "--show-toplevel", "--show-prefix"])
    guard res.status == 0 else { return nil }
    let lines = res.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let top = lines.first, !top.isEmpty else { return nil }
    return (URL(fileURLWithPath: top, isDirectory: true), lines.count > 1 ? lines[1] : "")
  }

  /// Keeps `.serein/` out of the person's git status through the local exclude, as `TaskWorktree` does.
  private static func excludeSerein(_ root: URL) throws {
    let res = runGit(["-C", root.path, "rev-parse", "--git-path", "info/exclude"])
    let raw = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard res.status == 0, !raw.isEmpty else { return }
    let path = raw.hasPrefix("/") ? raw : root.appendingPathComponent(raw).path
    let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    guard !current.split(separator: "\n").contains("/.serein/") else { return }
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "/.serein/\n").write(toFile: path, atomically: true, encoding: .utf8)
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
      // Read before waiting: a diff larger than the pipe buffer would otherwise never let git exit.
      let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      p.waitUntilExit()
      return (p.terminationStatus, out, err)
    } catch {
      return (-1, "", error.localizedDescription)
    }
  }
}
