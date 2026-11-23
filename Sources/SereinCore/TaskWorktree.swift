import Foundation

/// A new task's own git worktree, so it works on a branch of its own beside the person's checkout.
/// It is made inside the project (`.serein/worktrees/<name>`), where the task's folder access
/// already reaches, on a new branch `serein/<name>` from the current commit, and kept out of the
/// project's git status through its local `info/exclude`, never a committed file.
public enum TaskWorktree {
  /// The folder, below the project, that holds the worktrees.
  public static let folder = ".serein/worktrees"

  /// The project is a git checkout (its `.git` is a folder, or a file for a linked worktree).
  public static func isRepository(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
  }

  /// A short folder and branch name from a thread id: letters and digits only.
  public static func name(for thread: String) -> String {
    "task-" + String(thread.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
  }

  /// Makes the worktree and returns its path; an existing one for the same name is reused.
  public static func make(in repo: String, name: String, git: String = "/usr/bin/git") throws -> String {
    guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
      throw SereinError.invalid("That worktree name is not allowed.")
    }
    let path = (repo as NSString).appendingPathComponent(folder + "/" + name)
    if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return path }
    let exclude = try run(git, ["-C", repo, "rev-parse", "--git-path", "info/exclude"])
    let excludePath = exclude.hasPrefix("/") ? exclude : (repo as NSString).appendingPathComponent(exclude)
    let current = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
    if !current.split(separator: "\n").contains("/.serein/") {
      try FileManager.default.createDirectory(
        atPath: (excludePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "/.serein/\n"
      try (current + line).write(toFile: excludePath, atomically: true, encoding: .utf8)
    }
    _ = try run(git, ["-C", repo, "worktree", "add", "-b", "serein/" + name, path, "HEAD"])
    return path
  }

  private static func run(_ git: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: git)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let problem = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let words = String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw SereinError.invalid("git could not make the worktree" + (words.isEmpty ? "." : ": " + String(words.prefix(200))))
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
