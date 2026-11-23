#if DEBUG
import AppKit
import SereinCore

/// Integration checks for held tasks after a restart and early site icons (run by `--verify`).
extension SmokeTest {
  /// A task saved by an earlier session, in the thread that is open now, must not be sent when
  /// the composer flow starts (the launch path). It stays a "Ready to send" row.
  @MainActor static func heldTaskWaitsAtLaunch(browser: BrowserModel, agent: AgentModel) async throws -> Bool {
    let runsBefore = agent.hub.runs.count
    var saved = OfflineQueue.load(from: browser.library)
    let task = PendingTask(
      threadID: agent.conversationID, prompt: "go into youtube", provider: agent.provider.rawValue,
      mode: TaskMode.research.rawValue)
    saved.add(task)
    try saved.save(to: browser.library)
    // A fresh flow loads the file as at launch; its first settle runs on the next turns.
    let flow = ComposerFlow(agent: agent)
    flow.start(browser: browser)
    try await Task.sleep(nanoseconds: 800_000_000)
    let waiting = flow.offline.tasks.contains { $0.id == task.id }
      && flow.restoredTasks.contains { $0.id == task.id }
      && agent.hub.runs.count == runsBefore && !agent.running
    flow.cancelOffline(task.id)
    agent.error = nil
    return waiting
  }

  /// A fixture site whose HTML is delayed shows its icon before the page finishes loading: the
  /// host's /favicon.ico is requested when navigation starts.
  @MainActor static func iconBeforeLoad(browser: BrowserModel, baseURL: String) async throws -> Bool {
    guard let page = URL(string: baseURL + "slow-icon-page"),
      let key = SiteIconPlan.cacheKey(for: page)
    else { return false }
    FaviconStore.shared.forget(key: key)
    let tab = BrowserTab()
    try tab.navigate(page.absoluteString)
    var sawEarly = false
    for _ in 0..<60 {
      try await Task.sleep(nanoseconds: 50_000_000)
      if FaviconStore.shared.icon(address: page.absoluteString, privateTab: false) != nil {
        // The HTML is held back for two seconds; the icon must arrive while it is still loading.
        sawEarly = tab.web.title?.contains("Slow icon fixture") != true
        break
      }
    }
    for _ in 0..<60 where tab.loading { try await Task.sleep(nanoseconds: 100_000_000) }
    let private_ = BrowserTab(privateMode: true)
    try private_.navigate(page.absoluteString)
    try await Task.sleep(nanoseconds: 300_000_000)
    let privateGlobe = FaviconStore.shared.icon(for: private_) == nil
    private_.web.stopLoading()
    return sawEarly && privateGlobe
  }
}
#endif
