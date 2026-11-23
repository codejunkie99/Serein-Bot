#if DEBUG
import AppKit
import Combine
import SereinCore
import WebKit

/// Replay WebKit KVO through real nonpersistent views; no website or user library is read.
@MainActor func checkBrowserObservations() async throws {
  var checks = 0
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("Browser observation: " + label) }
    checks += 1
  }
  func drain() async throws {
    for _ in 0..<4 { await Task.yield() }
    try await Task.sleep(nanoseconds: 30_000_000)
  }
  let tab = BrowserTab(privateMode: true, owner: "synthetic-observation-check", store: .nonPersistent())
  defer { tab.discardPage() }
  try await drain()
  // These three observers use .new rather than .initial. Prime the unloaded view's
  // actual state before replaying unchanged events (WebKit can report an empty title).
  tab.refreshTitle(from: tab.web); tab.refreshAddress(from: tab.web)
  tab.refreshLoading(from: tab.web); tab.ext.refreshHistory(from: tab.web)
  var tabPublications = 0, extraPublications = 0
  let tabWatch = tab.objectWillChange.sink { tabPublications += 1 }
  let extraWatch = tab.ext.objectWillChange.sink { extraPublications += 1 }
  defer { tabWatch.cancel(); extraWatch.cancel() }
  let baseline = BaselinePageObservations(tab.web)
  try await drain()
  baseline.publications = 0
  let keys = [#keyPath(WKWebView.title), #keyPath(WKWebView.url),
    #keyPath(WKWebView.isLoading), #keyPath(WKWebView.canGoBack), #keyPath(WKWebView.canGoForward)]
  for _ in 0..<1_000 {
    for key in keys {
      tab.web.willChangeValue(forKey: key)
      tab.web.didChangeValue(forKey: key)
    }
  }
  try await drain()
  try check(baseline.publications == 5_000, "the retained original observers publish for every unchanged notification")
  try check(tabPublications == 0 && extraPublications == 0,
    "5,000 unchanged WebKit observations publish no tab or navigation changes (tab=\(tabPublications), navigation=\(extraPublications))")
  print("BENCH: 5,000 synthetic unchanged KVO deliveries, \(baseline.publications) original publications → \(tabPublications + extraPublications) current publications")

  tab.title = "Synthetic out-of-date title"
  tab.address = "http://127.0.0.1/synthetic-old-address"
  tab.loading = true
  tab.ext.canGoBack = true
  tab.ext.canGoForward = true
  tabPublications = 0; extraPublications = 0
  tab.refreshTitle(from: tab.web)
  tab.refreshAddress(from: tab.web)
  tab.refreshLoading(from: tab.web)
  tab.ext.refreshHistory(from: tab.web)
  try check(tab.title == (tab.web.title ?? "New tab") && tab.address.isEmpty && !tab.loading
    && !tab.ext.canGoBack && !tab.ext.canGoForward,
    "real transitions still synchronize chrome with the currently bound page")
  try check(tabPublications == 3 && extraPublications == 2,
    "each changed chrome value publishes exactly once")
  tabPublications = 0; extraPublications = 0
  tab.ext.clearError(); tab.ext.clearError()
  try check(extraPublications == 0, "clearing absent error overlays does not invalidate navigation chrome")

  tab.error = "Synthetic failed provisional load"
  tab.address = "http://127.0.0.1/synthetic-attempted-address"
  tab.refreshAddress(from: tab.web)
  try check(tab.address.hasSuffix("synthetic-attempted-address"),
    "a failed provisional load keeps its attempted address for retry and session restore")
  tab.error = nil
  tab.sleeping = true
  tab.title = "Synthetic sleeping title"
  tab.refreshTitle(from: tab.web); tab.refreshAddress(from: tab.web)
  try check(tab.title == "Synthetic sleeping title" && tab.address.hasSuffix("synthetic-attempted-address"),
    "sleeping tabs retain their saved title and address")
  tab.sleeping = false

  let previous = tab.web
  // All these tasks queue before the page is replaced, then run after replacement.
  for key in keys {
    previous.willChangeValue(forKey: key)
    previous.didChangeValue(forKey: key)
  }
  tab.discardPage()
  tab.title = "Synthetic queued replacement"
  tab.address = "http://127.0.0.1/synthetic-queued-replacement"
  tab.loading = true
  try await drain()
  try check(tab.title == "Synthetic queued replacement" && tab.address.hasSuffix("synthetic-queued-replacement")
    && tab.loading, "already queued KVO tasks from a discarded view preserve replacement chrome")
  tab.title = "Synthetic current page"
  tab.address = "http://127.0.0.1/synthetic-current-page"
  tab.loading = true
  tab.ext.canGoBack = true; tab.ext.canGoForward = true
  tabPublications = 0; extraPublications = 0
  // Retain the old delivery's view just as an already queued KVO closure does.
  Task { @MainActor in
    tab.refreshTitle(from: previous); tab.refreshAddress(from: previous)
    tab.refreshLoading(from: previous); tab.ext.refreshHistory(from: previous)
  }
  try await drain()
  try check(tab.title == "Synthetic current page" && tab.address.hasSuffix("synthetic-current-page")
    && tab.loading && tab.ext.canGoBack && tab.ext.canGoForward,
    "late deliveries from a discarded page cannot overwrite its replacement")
  try check(tabPublications == 0 && extraPublications == 0,
    "discarded-page observations cause no chrome invalidations")
  tab.wakingAddress = "http://127.0.0.1/synthetic-current-wake"
  let staleError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
  tab.webView(previous, didFail: nil, withError: staleError)
  tab.webView(previous, didFailProvisionalNavigation: nil, withError: staleError)
  tab.webViewWebContentProcessDidTerminate(previous)
  tab.webView(previous, didCommit: nil)
  tab.webView(previous, didStartProvisionalNavigation: nil)
  tab.webView(previous, didFinish: nil)
  try await drain()
  try check(tab.error == nil && !tab.ext.crashed && tab.title == "Synthetic current page"
    && tab.address.hasSuffix("synthetic-current-page") && tab.loading
    && tab.wakingAddress?.hasSuffix("synthetic-current-wake") == true,
    "discarded-page navigation delegates cannot fail, crash or capture the replacement")
  tab.refreshTitle(from: tab.web); tab.refreshAddress(from: tab.web)
  tab.refreshLoading(from: tab.web); tab.ext.refreshHistory(from: tab.web)
  try check(tab.title == (tab.web.title ?? "New tab") && tab.address.isEmpty && !tab.loading
    && !tab.ext.canGoBack && !tab.ext.canGoForward,
    "replacement-page observations still update the current tab")
  print("PASS: \(checks) synthetic WebKit observation, replacement and failed-address checks")
}

/// The previous five unconditional assignments, kept only for the paired replay above.
@MainActor private final class BaselinePageObservations: ObservableObject {
  @Published var title = "New tab"
  @Published var address = ""
  @Published var loading = false
  @Published var back = false
  @Published var forward = false
  var publications = 0
  private var watch: AnyCancellable?
  private var observations: [NSKeyValueObservation] = []
  init(_ web: WKWebView) {
    watch = objectWillChange.sink { [weak self] in self?.publications += 1 }
    observations = [
      web.observe(\.title, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.title = w.title ?? "New tab" }
      },
      web.observe(\.url, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.address = BrowserTab.visibleAddress(w.url) }
      },
      web.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.loading = w.isLoading }
      },
      web.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.back = w.canGoBack }
      },
      web.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.forward = w.canGoForward }
      },
    ]
  }
}
#endif
