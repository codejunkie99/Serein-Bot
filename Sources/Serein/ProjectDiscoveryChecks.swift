#if DEBUG
import Foundation
import SereinCore

/// Synthetic Claude Code and Codex history with two real repositories and three junk folders:
/// without any user action, two projects are listed and three wait under "Other folders".
@MainActor func checkProjectAutoDiscovery() {
  func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
      FileHandle.standardError.write(Data("FAIL: project discovery: \(message)\n".utf8))
      exit(1)
    }
  }
  let fm = FileManager.default
  let sandbox = fm.temporaryDirectory.appendingPathComponent("serein-discovery-\(UUID().uuidString)")
  defer { try? fm.removeItem(at: sandbox) }
  func folder(_ path: String, dirs: [String] = [], files: [String] = []) -> String {
    let url = sandbox.appendingPathComponent("work/" + path)
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    for dir in dirs {
      try! fm.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    for file in files { try! Data("{}".utf8).write(to: url.appendingPathComponent(file)) }
    return url.path
  }
  let repo = folder("atlas", dirs: [".git"])
  let app = folder("web", files: ["package.json"])
  let chat = folder("Codex/2026-10-05/can-you-check-why-the-build")
  let tiny = folder("Codex/2026-10-07/do")
  let plain = folder("Field notes")
  func write(_ text: String, _ path: String) {
    let url = sandbox.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
  }
  for (index, path) in [repo, chat, plain].enumerated() {
    write(
      #"{"type":"user","cwd":"\#(path)","sessionId":"c\#(index)","message":{"role":"user","content":"Synthetic task"}}"#,
      "claude/-synthetic-\(index)/c\(index).jsonl")
  }
  for (index, path) in [app, tiny].enumerated() {
    write(
      #"{"type":"session_meta","payload":{"id":"0199aaaa-bbbb-cccc-dddd-00000000000\#(index)","cwd":"\#(path)"}}"#,
      "codex/2026/10/11/rollout-2026-10-11T10-00-0\(index).jsonl")
  }
  let browser = try! BrowserModel(root: sandbox.appendingPathComponent("library"))
  let model = SessionDiscoveryModel.shared
  model.browser = browser
  check(browser.projects.isEmpty, "the library starts empty")
  func pass() -> ProjectDiscoveryResult {
    ProjectAutoDiscovery.run(
      claudeRoot: sandbox.appendingPathComponent("claude"),
      codexRoot: sandbox.appendingPathComponent("codex"), home: "/nonexistent-home",
      existing: browser.projects, removed: model.dismissed, context: browser.projectCandidateContext)
  }
  model.apply(pass())
  check(browser.listedProjects.count == 2, "two projects listed, got \(browser.listedProjects.map(\.name))")
  check(Set(browser.listedProjects.map(\.name)) == ["atlas", "web"], "the repositories are the projects")
  check(browser.otherFolders.count == 3, "Other folders (3), got \(browser.otherFolders.count)")
  check(browser.notice == nil, "a pass nobody asked for says nothing, got \(browser.notice ?? "nil")")
  // Nothing about an Other folder reaches a provider through routing or dev-server facts.
  let shared = browser.shareableProjects
  check(Set(shared.map(\.path)) == [repo, app], "only listed projects are shareable")
  for folder in browser.otherFolders {
    check(!shared.contains { $0.id == folder.id || $0.path == folder.path }, "routing would see \(folder.name)")
  }
  // Make project moves a folder up; removing one keeps a later pass from adding it back.
  let other = browser.otherFolders[0]
  browser.setPlacement(.project, for: other.id)
  check(browser.listedProjects.count == 3, "Make project lists the folder")
  browser.removeProject(other.id)
  check(pass().added.isEmpty, "a removed folder stays out and nothing is added twice")
  model.dismissed.remove(ProjectAutoDiscovery.key(other.path))
}
#endif
