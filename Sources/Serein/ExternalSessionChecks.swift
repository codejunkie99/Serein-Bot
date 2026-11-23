#if DEBUG
import Foundation
import SereinCore

@MainActor func checkExternalSessionDisplay() {
  func check(_ value: Bool, _ message: String) {
    if !value { fatalError("External session display: " + message) }
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("serein-external-display-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let browser = try! BrowserModel(root: root)
  let project = Project(name: "Synthetic", path: "/synthetic/serein")
  browser.projects = [project]
  let external = ExternalSessionStore.shared
  let activity = ProjectActivityStore.shared
  activity.attach(browser)
  let now = Date()
  external.update([
    ExternalSession(id: "one", driver: .codex, title: "Synthetic running", cwd: project.path, state: .running, updatedAt: now),
    ExternalSession(id: "two", driver: .codex, title: "Synthetic waiting", cwd: project.path, state: .needsUser, updatedAt: now),
    ExternalSession(id: "three", driver: .opencode, title: "Synthetic open", cwd: project.path, state: .open, updatedAt: now),
  ])
  check(external.working == 1 && external.waiting == 1 && external.open == 1, "counts distinguish turn evidence from process presence")
  check(activity.state(project.id)?.running == true && activity.state(project.id)?.needsYou == true, "project markers include confirmed external activity")
  check(browser.library.runs().isEmpty, "external observation writes no run history")
  external.update([ExternalSession(id: "three", driver: .opencode, title: "Synthetic open", cwd: project.path, state: .open, updatedAt: now)])
  check(activity.state(project.id) == nil, "open processes do not leave a false Running badge")
  external.update([])
  check(external.sessions.isEmpty && activity.state(project.id) == nil, "closed external sessions disappear")
}
#endif
