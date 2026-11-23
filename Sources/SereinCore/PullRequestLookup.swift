import Foundation

/// Pure rules for finding a task's pull request and reading its state with `gh`: the GitHub
/// repository and branch of a working folder (read from its `.git` files, so no git command ever
/// runs inside a project, whose config could run code), the arguments for `gh`, and its answer.
public enum PullRequestLookup {
  public enum State: String, Equatable, Sendable {
    case open, draft, merged, closed, conflict
    public var word: String {
      switch self {
      case .open: return "Open"
      case .draft: return "Draft"
      case .merged: return "Merged"
      case .closed: return "Closed"
      case .conflict: return "Has conflicts"
      }
    }
  }
  public struct Info: Equatable, Sendable {
    public var number: Int
    public var url: String
    public var state: State
    public init(number: Int, url: String, state: State) {
      self.number = number; self.url = url; self.state = state
    }
  }
  public static let fields = "number,url,state,isDraft,mergeable"

  /// `owner/repo` for a GitHub remote URL (ssh or https), nil for any other host.
  public static func repository(remote: String) -> String? {
    var rest = remote.trimmingCharacters(in: .whitespaces)
    for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/"]
    where rest.hasPrefix(prefix) {
      rest = String(rest.dropFirst(prefix.count))
      if rest.hasSuffix(".git") { rest = String(rest.dropLast(4)) }
      if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
      let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, parts.allSatisfy({ safeName($0) }) else { return nil }
      return rest
    }
    return nil
  }
  /// A pull request page, `https://github.com/<owner>/<repo>/pull/<n>`, kept only in that form.
  public static func pullURL(_ text: String) -> String? {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 7, parts[0] == "https:", parts[1].isEmpty, parts[2] == "github.com",
      safeName(parts[3]), safeName(parts[4]), parts[5] == "pull",
      !parts[6].isEmpty, parts[6].count <= 7, parts[6].allSatisfy(\.isNumber)
    else { return nil }
    return text
  }
  /// A branch name `gh` may be given as an argument: git's own rules, minus a leading dash.
  public static func safeBranch(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 200 && !name.hasPrefix("-") && !name.contains("..")
      && name.unicodeScalars.allSatisfy { $0.value > 32 && $0.value != 127 && !"~^:?*[\\".unicodeScalars.contains($0) }
  }
  private static func safeName<S: StringProtocol>(_ part: S) -> Bool {
    !part.isEmpty && part.count <= 100 && !part.hasPrefix("-") && !part.hasPrefix(".")
      && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
  }

  /// The repository and branch a folder is on: the nearest `.git` above it (a folder, or a
  /// worktree's `gitdir:` file), its HEAD's branch, and the `origin` remote of its config.
  public static func repositoryAndBranch(folder: String, fileManager: FileManager = .default)
    -> (repository: String, branch: String)?
  {
    var path = URL(fileURLWithPath: folder).standardizedFileURL.path
    var gitDir: String?
    while !path.isEmpty {
      let dot = path + "/.git"
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: dot, isDirectory: &isDirectory) {
        if isDirectory.boolValue {
          gitDir = dot
        } else if let text = small(dot), let line = text.split(whereSeparator: \.isNewline).first,
          line.hasPrefix("gitdir: ")
        {
          let target = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
          gitDir = target.hasPrefix("/") ? target : URL(fileURLWithPath: path).appendingPathComponent(target).standardizedFileURL.path
        }
        break
      }
      let parent = (path as NSString).deletingLastPathComponent
      if parent == path { break }
      path = parent
    }
    guard let gitDir, let head = small(gitDir + "/HEAD")?.trimmingCharacters(in: .whitespacesAndNewlines),
      head.hasPrefix("ref: refs/heads/")
    else { return nil }
    let branch = String(head.dropFirst("ref: refs/heads/".count))
    // A worktree keeps its config in the main repository (`commondir`).
    var common = gitDir
    if let relative = small(gitDir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines), !relative.isEmpty {
      common = relative.hasPrefix("/") ? relative : URL(fileURLWithPath: gitDir).appendingPathComponent(relative).standardizedFileURL.path
    }
    guard safeBranch(branch), let config = small(common + "/config"),
      let remote = originURL(config: config), let repository = repository(remote: remote)
    else { return nil }
    return (repository, branch)
  }
  /// `url` under `[remote "origin"]` in a git config's text.
  public static func originURL(config: String) -> String? {
    var inOrigin = false
    for raw in config.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
      guard inOrigin else { continue }
      let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      if pair.count == 2, pair[0] == "url" { return pair[1] }
    }
    return nil
  }
  private static func small(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 64 * 1024)).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// `gh pr view <url>` for a known pull request.
  public static func viewArguments(url: String) -> [String] { ["pr", "view", url, "--json", fields] }
  /// `gh pr list` for the newest pull request from a branch, in any state.
  public static func listArguments(repository: String, branch: String) -> [String] {
    ["pr", "list", "--repo", repository, "--head", branch, "--state", "all", "--limit", "1", "--json", fields]
  }
  /// `gh`'s JSON answer (one object, or a list of at most one), as an Info.
  public static func parse(_ data: Data) -> Info? {
    let json = try? JSONSerialization.jsonObject(with: data)
    guard let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first,
      let number = object["number"] as? Int, let url = (object["url"] as? String).flatMap(pullURL)
    else { return nil }
    let state: State
    switch object["state"] as? String {
    case "MERGED": state = .merged
    case "CLOSED": state = .closed
    default:
      state = object["isDraft"] as? Bool == true ? .draft : object["mergeable"] as? String == "CONFLICTING" ? .conflict : .open
    }
    return Info(number: number, url: url, state: state)
  }
}
