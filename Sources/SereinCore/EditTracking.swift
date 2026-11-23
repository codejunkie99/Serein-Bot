import Foundation

/// Pure rules for reviewing and undoing the files an agent changed in one turn.
/// The git work itself lives in `GitTurns`; everything here is checkable without git.

/// One file in a turn's diff. `added`/`removed` are nil for binary files.
public struct DiffFile: Codable, Equatable, Sendable {
  public var path: String
  public var added: Int?
  public var removed: Int?
  public init(path: String, added: Int?, removed: Int?) {
    self.path = path
    self.added = added
    self.removed = removed
  }
  public var isBinary: Bool { added == nil || removed == nil }
}

public enum DiffStat {
  /// Parses `git diff-tree -r -z --numstat --no-renames` output: `added\tremoved\tpath\0`.
  /// Binary files report `-\t-\tpath`.
  public static func parseNumstat(_ output: String) -> [DiffFile] {
    output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry in
      let parts = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3, !parts[2].isEmpty else { return nil }
      let path = String(parts[2]).trimmingCharacters(in: .newlines)
      guard !path.isEmpty else { return nil }
      return DiffFile(path: path, added: Int(parts[0]), removed: Int(parts[1]))
    }
  }
  public static func totals(_ files: [DiffFile]) -> (added: Int, removed: Int) {
    files.reduce((0, 0)) { ($0.0 + ($1.added ?? 0), $0.1 + ($1.removed ?? 0)) }
  }
  /// "Changed 2 files" style headline.
  public static func headline(_ files: [DiffFile]) -> String {
    files.isEmpty
      ? "No files changed in this turn"
      : "Changed \(files.count) file\(files.count == 1 ? "" : "s")"
  }
}

/// Bounds for one file's unified diff in the card.
public enum UnifiedDiff {
  public static let maxLines = 400
  public static let maxBytes = 96 * 1024
  /// Keeps whole lines up to the caps. `inputTruncated` says the reader already stopped early.
  public static func cap(
    _ text: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes, inputTruncated: Bool = false
  ) -> (text: String, truncated: Bool) {
    var kept: [Substring] = []
    var bytes = 0
    var truncated = inputTruncated
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (i, line) in lines.enumerated() {
      // A trailing empty piece after the final newline is not a line.
      if i == lines.count - 1 && line.isEmpty { break }
      if kept.count >= maxLines || bytes + line.utf8.count + 1 > maxBytes {
        truncated = true
        break
      }
      kept.append(line)
      bytes += line.utf8.count + 1
    }
    // When the reader cut the output mid-line, drop that partial last line.
    if inputTruncated, !kept.isEmpty, !text.hasSuffix("\n") { kept.removeLast() }
    return (kept.joined(separator: "\n"), truncated)
  }
}

/// Plain copy for every tracking state. Serein's own wording, short sentences.
public enum EditTrackingCopy {
  public static let notGit = "Changes aren't tracked outside git."
  public static let notGitHelp =
    "Set up git in this folder to review and undo what agents change. Serein never commits, pushes or changes git settings."
  public static let noGit = "Install the Xcode command line tools to review and undo agent edits."
  public static let untrustedOwner =
    "Git doesn't trust this folder's owner, so changes in it aren't tracked."
  public static let sharedProject =
    "Another task was editing this project at the same time, so this turn's changes can't be told apart."
  public static let interrupted =
    "Serein closed before this turn ended, so its changes weren't saved for undo."
  public static let snapshotFailed = "Git couldn't save a snapshot, so this turn isn't tracked."
  public static let restoreFailed = "Git didn't finish restoring the files. Try again."
  public static let unsafeFilters =
    "This project's git settings name a filter Serein can't switch off, so changes in it aren't tracked."
  public static func tooManyBytes(_ megabytes: Int) -> String {
    "This project has more than \(megabytes) MB of untracked files. Add them to .gitignore to review and undo agent edits."
  }
  public static func tooManyFiles(_ count: Int) -> String {
    "This project has more than \(count.formatted()) untracked files. Add build output to .gitignore to review and undo agent edits."
  }
}

public enum TrackingLimits {
  public static let maxUntrackedBytes: Int64 = 256 * 1024 * 1024
  public static let maxUntrackedFiles = 20_000
  /// nil when the untracked files are small enough to snapshot.
  public static func refusal(
    untrackedBytes: Int64, untrackedFiles: Int, maxBytes: Int64 = maxUntrackedBytes,
    maxFiles: Int = maxUntrackedFiles
  ) -> String? {
    if untrackedFiles > maxFiles { return EditTrackingCopy.tooManyFiles(maxFiles) }
    if untrackedBytes > maxBytes {
      return EditTrackingCopy.tooManyBytes(Int(maxBytes / (1024 * 1024)))
    }
    return nil
  }
}

/// Paths that git reports for a turn. Anything that could leave the working tree is refused.
public enum TurnPaths {
  public static func isSafe(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }
  }
  /// Ref names are built from run ids; keep them to a safe alphabet.
  public static func refComponent(_ id: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    let cleaned = String(id.filter { allowed.contains($0) }.prefix(64))
    return cleaned.isEmpty ? "turn" : cleaned
  }
}

/// Whether Undo or Redo may run now.
public enum TurnUndo {
  public enum Action: Sendable { case undo, redo }
  public static let running = "Wait for the current turn to finish, then undo."
  public static let runningRedo = "Wait for the current turn to finish, then redo."
  public static let nothing = "This turn changed no files, so there is nothing to undo."
  public static let alreadyUndone = "These changes are already undone."
  public static let alreadyApplied = "These changes are already applied."
  public static let untracked = "This turn's changes weren't tracked."
  /// Checks that need no git: a turn still running, nothing tracked, or a repeated action.
  public static func refusal(
    _ action: Action, running: Bool, tracked: Bool, files: Int, undone: Bool
  ) -> String? {
    if running { return action == .undo ? Self.running : runningRedo }
    if !tracked { return untracked }
    if files == 0 { return nothing }
    if action == .undo && undone { return alreadyUndone }
    if action == .redo && !undone { return alreadyApplied }
    return nil
  }
  /// Files of this turn that differ from what the turn left (undo) or found (redo).
  public static func conflicts(turnFiles: [String], changedSince: [String]) -> [String] {
    let changed = Set(changedSince)
    return turnFiles.filter { changed.contains($0) }
  }
  public static func conflictCopy(_ files: [String], action: Action) -> String? {
    guard let first = files.first else { return nil }
    let more = files.count > 1 ? " and \(files.count - 1) more file\(files.count == 2 ? "" : "s")" : ""
    return action == .undo
      ? "\(first)\(more) changed after this turn. Undo the later changes first, then undo this turn."
      : "\(first)\(more) changed after this turn was undone. Put it back first, then redo."
  }
}

/// An action the agent tried that the user has not allowed yet.
public struct PendingApproval: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  /// The tool as the CLI named it (Edit, Write, file_change …).
  public var tool: String
  /// A project-relative path or short description; untrusted, display only.
  public var target: String
  public init(id: String, tool: String, target: String) {
    self.id = id
    self.tool = tool
    self.target = target
  }
  public var label: String {
    let verb: String
    switch tool {
    case "Write": verb = "Write"
    case "NotebookEdit": verb = "Edit notebook"
    default: verb = "Edit"
    }
    return target.isEmpty ? verb + " a file" : verb + " " + target
  }
}

public enum ApprovalEvents {
  static let claudeEditTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
  /// Reads edit approvals from one CLI stream event.
  /// Claude Code: `result.permission_denials[]` with `tool_name`, `tool_use_id`, `tool_input`.
  /// Codex: a `file_change` item that failed or was declined, or an `*approval_request` event.
  public static func parse(_ event: [String: Any], folder: String? = nil) -> [PendingApproval] {
    let kind = event["type"] as? String ?? ""
    if kind == "result", let denials = event["permission_denials"] as? [[String: Any]] {
      return denials.enumerated().compactMap { index, denial in
        guard let tool = denial["tool_name"] as? String, claudeEditTools.contains(tool) else {
          return nil
        }
        let input = denial["tool_input"] as? [String: Any] ?? [:]
        let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
        let id = denial["tool_use_id"] as? String ?? "denial-\(index)"
        return PendingApproval(id: id, tool: tool, target: display(path, folder: folder))
      }
    }
    if kind == "item.completed" || kind == "item.updated",
      let item = event["item"] as? [String: Any], item["type"] as? String == "file_change",
      let status = item["status"] as? String, ["failed", "declined", "rejected"].contains(status)
    {
      let changes = item["changes"] as? [[String: Any]] ?? []
      let id = item["id"] as? String ?? UUID().uuidString
      if changes.isEmpty { return [PendingApproval(id: id, tool: "file_change", target: "")] }
      return changes.enumerated().map { i, change in
        PendingApproval(
          id: "\(id)-\(i)", tool: "file_change",
          target: display(change["path"] as? String, folder: folder))
      }
    }
    if kind.hasSuffix("approval_request") {
      let body = event["msg"] as? [String: Any] ?? event
      let id = (body["call_id"] ?? body["id"]) as? String ?? UUID().uuidString
      if let changes = body["changes"] as? [String: Any], !changes.isEmpty {
        return changes.keys.sorted().enumerated().map { i, path in
          PendingApproval(id: "\(id)-\(i)", tool: "file_change", target: display(path, folder: folder))
        }
      }
    }
    return []
  }
  public static func summary(_ count: Int) -> String {
    count == 1 ? "1 action waits for your approval." : "\(count) actions wait for your approval."
  }
  /// A displayed target that is not inside the project (absolute, home-relative or climbing out).
  public static func isOutsideProject(_ target: String) -> Bool {
    let t = target.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return false }
    if t.hasPrefix("/") || t.hasPrefix("~") { return true }
    return t.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
  /// What "Allow once" really grants: edits anywhere in the project for one reply.
  public static func scope(project: String) -> String {
    "Allow once lets the next reply edit any file in \(project), not only these."
  }
  /// A single line for display: relative to the project when inside it, capped in length.
  static func display(_ path: String?, folder: String?) -> String {
    guard var path = path?.replacingOccurrences(of: "\n", with: " "), !path.isEmpty else {
      return ""
    }
    if let folder, !folder.isEmpty {
      let prefix = folder.hasSuffix("/") ? folder : folder + "/"
      if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
    }
    return path.count > 160 ? "…" + String(path.suffix(159)) : path
  }
}

/// What Serein sends after the user answers an approval card.
public enum ApprovalReplies {
  public static let allowOnce =
    "Go ahead with the file changes you asked to make, then continue the task."
  public static func deny(_ labels: [String], reply: String) -> String {
    let actions = labels.prefix(5).joined(separator: "; ")
    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    return "I didn't allow this: \(actions). Don't make those changes. "
      + (text.isEmpty ? "Tell me what you would do instead." : "Instead: " + text)
  }
}

/// Projects where the user chose "Always allow". Revocable in Settings › AI apps.
public enum ProjectEditApprovals {
  public static let key = "serein.projectsAlwaysAllowEdits"
  public static func all(defaults: any SettingsStore = GateSettings.shared) -> [String] {
    defaults.stringArray(forKey: key) ?? []
  }
  public static func isAllowed(_ projectID: String?, defaults: any SettingsStore = GateSettings.shared) -> Bool {
    guard let projectID, !projectID.isEmpty else { return false }
    return all(defaults: defaults).contains(projectID)
  }
  public static func allow(_ projectID: String, defaults: any SettingsStore = GateSettings.shared) {
    guard !projectID.isEmpty, !isAllowed(projectID, defaults: defaults) else { return }
    defaults.set(all(defaults: defaults) + [projectID], forKey: key)
  }
  public static func revoke(_ projectID: String, defaults: any SettingsStore = GateSettings.shared) {
    defaults.set(all(defaults: defaults).filter { $0 != projectID }, forKey: key)
  }
}
