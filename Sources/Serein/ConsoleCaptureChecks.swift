#if DEBUG
import SereinCore
import WebKit

extension SmokeTest {
  /// Page-reported console.error capture: regular tabs only.
  @MainActor static func consoleCapture(browser: BrowserModel) async throws -> [String] {
    var results: [String] = []
    func check(_ value: Bool, _ label: String) throws {
      guard value else { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let base = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"]!
    func load(_ tab: BrowserTab) async throws {
      try tab.navigate(base + "plain")
      for _ in 0..<100 {
        if !tab.web.isLoading, tab.web.url != nil { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    // Runs in the page world, like the page's own scripts.
    func report(_ tab: BrowserTab) async throws {
      _ = try await tab.web.evaluateJavaScript("console.error('x'); console.warn('w'); true")
      try await Task.sleep(nanoseconds: 700_000_000)
    }
    let store = ConsoleWatchStore.shared

    let regular = BrowserTab(store: .nonPersistent())
    try await load(regular)
    try await report(regular)
    let snapshot = store.snapshot(regular)
    let block = snapshot.map(ConsoleErrors.render) ?? ""
    try check(
      block.contains("[reported by the page, error] x") && block.contains("<untrusted_console_errors>"),
      "Page console.error appears in the capture of a regular tab, labelled as page-reported")
    store.reset(regular.id)

    let priv = BrowserTab(privateMode: true)
    try await load(priv)
    try await report(priv)
    try check(store.snapshot(priv) == nil && store.counts[priv.id] == nil,
      "Nothing is captured for a private tab")

    let owned = BrowserTab(owner: "console-capture-check", store: .nonPersistent())
    try await load(owned)
    try await report(owned)
    try check(store.snapshot(owned) == nil && store.counts[owned.id] == nil,
      "Nothing is captured for an agent-owned tab")
    return results
  }
}
#endif
