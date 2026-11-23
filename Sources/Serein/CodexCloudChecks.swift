#if DEBUG
import Foundation
import SereinCore

/// `--verify-cloud-apply [--cloud-task <id>]`: no window and, without `--cloud-task`, no network.
/// A Codex Cloud diff reaches a project only after the person confirms and `git apply --check`
/// passes; a declined or failed apply leaves the folder as it was, unstaged, with no log file.
@MainActor func checkCloudApply() async throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("serein-cloud-check-" + UUID().uuidString)
  defer { try? fm.removeItem(at: root) }
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("FAIL: " + label) }
    print("PASS: " + label)
    fflush(stdout)
  }
  guard let git = GitTurns.locateGit() else { throw SereinError.invalid("git is not available") }
  func run(_ args: [String], in folder: URL) async -> String {
    await HarnessProbe.run(git, args, environment: ProcessInfo.processInfo.environment, timeout: 30, cwd: folder).output
  }
  func repo(_ name: String, _ text: String) async throws -> URL {
    let folder = root.appendingPathComponent(name)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try text.write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    _ = await run(["init", "-q"], in: folder)
    _ = await run(["add", "a.txt"], in: folder)
    _ = await run(["-c", "user.email=check@serein.invalid", "-c", "user.name=check", "commit", "-qm", "base"], in: folder)
    return folder
  }
  let diff = """
    diff --git a/a.txt b/a.txt
    index 0000000..1111111 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1,3 +1,3 @@
     one
    -two
    +TWO
     three

    """
  let task = CloudTask(id: "task_check", title: "Synthetic task", status: "ready", environment: "clean")
  func model(_ folder: URL?, confirm: Bool) -> CloudTaskModel {
    let m = CloudTaskModel(task: task, projects: [])
    m.previewDiff(diff)
    m.folder = folder
    m.confirm = { _, _ in confirm }
    return m
  }
  let clean = try await repo("clean", "one\ntwo\nthree\n")
  let text = { (folder: URL) in (try? String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8)) ?? "" }

  var m = model(clean, confirm: false)
  try check(m.files == 1, "The diff names one file")
  await m.apply()
  try check(text(clean) == "one\ntwo\nthree\n" && m.applied == nil && m.problem == nil, "A declined apply writes nothing")

  m = model(clean, confirm: true)
  await m.apply()
  let status = await run(["status", "--porcelain"], in: clean)
  try check(text(clean) == "one\nTWO\nthree\n" && m.applied != nil, "A confirmed apply writes the diff")
  try check(status.trimmingCharacters(in: .whitespacesAndNewlines) == "M a.txt", "Nothing is staged, and no log file is left in the project")

  let drifted = try await repo("drifted", "one\ndeux\nthree\n")
  m = model(drifted, confirm: true)
  await m.apply()
  try check(
    text(drifted) == "one\ndeux\nthree\n" && m.applied == nil && m.problem?.contains("nothing was written") == true
      && m.problem?.contains("patch does not apply") == true,
    "A diff that does not fit writes nothing and shows git's words")

  let plain = root.appendingPathComponent("plain")
  try fm.createDirectory(at: plain, withIntermediateDirectories: true)
  m = model(plain, confirm: true)
  await m.apply()
  try check(m.problem?.contains("not a git repository") == true, "A folder outside git is refused")
  try check(
    CloudTaskModel(task: task, projects: [Project(name: "clean", path: clean.path, source: .added)]).folder?.path == clean.path,
    "The project named like the task's environment is chosen")

  // A real task's status and diff, read with Codex (network; only with --cloud-task).
  if let index = CommandLine.arguments.firstIndex(of: "--cloud-task"), index + 1 < CommandLine.arguments.count {
    // A headless run finds Codex only after the registry probes it.
    HarnessRegistry.shared.probesEnabled = true
    await HarnessRegistry.shared.refresh(.codex, includeDisabled: true, force: true)
    let live = CloudTaskModel(task: CloudTask(id: CommandLine.arguments[index + 1], title: "Live", status: ""), projects: [])
    await live.load()
    if let problem = live.problem { print("NOTE: \(problem)") }
    try check(live.diff?.hasPrefix("diff --git ") == true && live.status != nil, "A real task's status and diff load")
    print("NOTE: \(live.files) file(s); status: \(live.status ?? "-")")
  }
}
#endif
