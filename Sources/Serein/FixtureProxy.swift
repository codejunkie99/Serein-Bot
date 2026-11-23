import Foundation
import SereinCore
import WebKit

/// A reserved name has no direct fixture origin. Only the harness proxy maps it to its
/// owned loopback server, whose fresh response token proves that the task received bytes.
/// The harness also checks its accepted-connection log for this exact alias and port.
/// Ships in release for the `--stress` driver's `proxy-check`; only the DEBUG
/// `--verify-fixture-proxy` run lets it open a browser of its own.
@MainActor func checkFixtureProxy(browser supplied: BrowserModel? = nil) async throws -> [String: Any] {
  let environment = ProcessInfo.processInfo.environment
  guard let data = environment["SEREIN_DATA_DIR"], data.hasPrefix("/"),
    FixtureApprovals.isAllowed(root: URL(fileURLWithPath: data)),
    let address = environment["SEREIN_PROXY_FIXTURE_URL"], let url = URL(string: address),
    url.scheme == "http", url.host == "serein-fixture.invalid", let port = url.port,
    (1...65535).contains(port), url.user == nil, url.password == nil,
    url.path == "/proxy-proof", url.query == nil, url.fragment == nil,
    let localAddress = environment["SEREIN_FIXTURE_URL"], let local = URL(string: localAddress),
    local.scheme == "http", local.host == "127.0.0.1", local.port == port,
    let token = environment["SEREIN_PROXY_FIXTURE_TOKEN"], token.count == 32,
    token.allSatisfy({ "0123456789abcdef".contains($0) }),
    let endpoint = ConnectProxy.endpoint(), endpoint.host == "127.0.0.1"
  else { throw SereinError.invalid("Proxy checks require a marked temporary library and the exact local fixture transport.") }

  let browser: BrowserModel
  if let supplied { browser = supplied }
  else {
    #if DEBUG
    browser = try BrowserModel(root: URL(fileURLWithPath: data))
    #else
    throw SereinError.invalid("The proxy check runs on the stress driver's browser.")
    #endif
  }
  defer { if supplied == nil { browser.shutdown() } }
  let approvals = try FixtureApprovals(browser: browser)
  defer { approvals.close() }
  let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
  defer {
    browser.endTask(task.capability.task)
    let entries = browser.agentTabs.entries.filter { $0.taskID == task.capability.task }
    for entry in entries { browser.agentTabs.dismiss(entry.id) }
  }
  func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
    try await browser.handle(["task": task.capability.task, "token": task.capability.token,
      "name": name, "arguments": arguments])
  }
  try await approvals.perform(expecting: [.site(url: address)], timeout: 15) {
    let opened = try await call("open_tab", ["url": address])
    guard let id = opened["tab"] as? String,
      let tab = browser.tasks[task.capability.task]?.tabs.first(where: { $0.id == id }),
      tab.owner == task.capability.task, tab.web.configuration.websiteDataStore === task.store,
      task.store !== WKWebsiteDataStore.default(), !task.store.proxyConfigurations.isEmpty
    else { throw SereinError.invalid("Proxy proof did not use an owned task tab and its separate proxied store.") }
    await tab.settle(limit: 5)
    let read = try await call("read", ["tab": id])
    guard tab.web.url == url, read["text"] as? String == token else {
      throw SereinError.invalid("The task did not read the fresh response from the proxy-only fixture name.")
    }
  }
  return ["verified": true, "host": "serein-fixture.invalid", "port": port]
}
