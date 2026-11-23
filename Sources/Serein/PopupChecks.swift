#if DEBUG
import SereinCore
import Foundation
import WebKit

/// A popup keeps `window.opener`: sign-in buttons (Apple, Google, Microsoft and others) open one
/// and get the result back through it. Before this, Serein opened the address in a new tab of
/// its own, `window.open` gave null and the sign-in failed ("popup_blocked_by_browser").
@MainActor func checkPopups() async {
  func check(_ condition: Bool, _ message: String) {
    if !condition {
      FileHandle.standardError.write(Data("FAIL: popup check: \(message)\n".utf8))
      exit(1)
    }
  }
  func until(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
  }
  func load(_ tab: BrowserTab) async {
    let page = "<!doctype html><title>Site</title><script>window.got = 'none';"
      + "addEventListener('message', e => { window.got = e.data })</script>"
    tab.web.loadHTMLString(page, baseURL: URL(string: "https://site.invalid/")!)
    await until { !tab.web.isLoading && tab.web.url != nil }
  }
  func js(_ tab: BrowserTab, _ source: String) async -> Any? {
    try? await tab.web.evaluateJavaScript(source)
  }
  let open =
    "window.pop = window.open('', '_blank', 'width=400,height=500'); window.pop ? 'opened' : 'null'"
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("serein-popups-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  guard let browser = try? BrowserModel(root: root) else { return check(false, "browser model") }

  // PopupPolicy: with no input from the person, a page opens no window and says nothing; with
  // input 30 s ago it is offered in a notice; right after a click it opens.
  let site = browser.newTab()
  await load(site)
  var offered: [URL] = []
  let offer = site.onBlockedPopup
  site.onBlockedPopup = { offered.append($0) }
  let openSite = "window.pop = window.open('https://site.invalid/sign-in', '_blank'); window.pop ? 'opened' : 'null'"
  check(await js(site, openSite) as? String == "null" && offered.isEmpty && browser.tabs.count == 1,
    "a window with no input from the person is blocked, with no notice")
  site.lastInput = Date().addingTimeInterval(-30)
  check(await js(site, openSite) as? String == "null" && offered.map(\.absoluteString) == ["https://site.invalid/sign-in"]
    && browser.tabs.count == 1, "a window 30 s after the person's input is offered in a notice, not opened")
  site.onBlockedPopup = offer

  // A sign-in popup: opened by script a moment after a click (a network step between them),
  // linked to its opener, closed by the opener when done.
  site.lastInput = Date().addingTimeInterval(-4)
  check(await js(site, open) as? String == "opened", "window.open gives the popup")
  check(browser.tabs.count == 2, "the popup is a tab")
  check(await js(site, "window.open('https://site.invalid/again', '_blank') ? 'opened' : 'null'") as? String == "null"
    && site.lastInput == nil && browser.tabs.count == 2, "one input opens one window: a second one is blocked")
  guard let popup = browser.tabs.last, popup !== site else { return check(false, "popup tab") }
  check(popup.openedByPage && popup.openedByScript && popup.opener === site && popup.openerID == site.id,
    "opener link")
  check(browser.selected == popup.id && browser.section == ShellSection.browser, "the popup is in view")
  check(await js(popup, "window.opener !== null") as? Bool == true, "window.opener in the popup")
  _ = await js(popup, "window.opener.postMessage('signed-in', '*'); true")
  try? await Task.sleep(nanoseconds: 300_000_000)
  check(await js(site, "window.got") as? String == "signed-in", "the opener gets the result")
  check(browser.inUse(site) && browser.inUse(popup), "neither tab sleeps while both are open")
  _ = await js(site, "window.pop.close(); true")
  await until { browser.tabs.count == 1 }
  check(
    browser.tabs.count == 1 && browser.selected == site.id, "a closed popup returns to its opener")
  check(await js(site, "window.pop.closed") as? Bool == true, "the opener sees the popup closed")
  check(!browser.tabs.contains { $0.opener === site }, "no popup keeps the opener awake")

  // A private popup uses its opener's private store and gives it back when it closes.
  let hidden = browser.newTab(privateMode: true)
  await load(hidden)
  let store = hidden.web.configuration.websiteDataStore
  hidden.lastInput = Date()
  check(await js(hidden, open) as? String == "opened", "a private tab opens a popup")
  guard let secret = browser.tabs.last, secret !== hidden else {
    return check(false, "private popup")
  }
  check(secret.privateMode && secret.web.configuration.websiteDataStore === store, "private store")
  check(PrivateStorePool.shared.userCount(store) == 2, "the private popup is counted")
  _ = await js(secret, "window.close(); true")
  await until { !browser.tabs.contains { $0 === secret } }
  check(PrivateStorePool.shared.userCount(store) == 1, "the private popup gives the store back")

  // A page the user opened cannot close its tab, even with one history entry.
  let count = browser.tabs.count
  _ = await js(hidden, "window.close(); true")
  try? await Task.sleep(nanoseconds: 500_000_000)
  check(browser.tabs.count == count, "window.close() in a user tab does nothing")

  // A link with target=_blank opens a tab with one history entry. WebKit lets its page call
  // window.close(); the tab is the user's (a meeting link from a calendar) and stays.
  site.lastInput = Date()
  _ = await js(site, "(() => { const a = document.createElement('a'); a.href = 'about:blank';"
    + " a.target = '_blank'; document.body.appendChild(a); a.click(); })(); true")
  await until { browser.tabs.count == count + 1 }
  guard let linked = browser.tabs.last, linked !== site, linked !== hidden else {
    return check(false, "link tab")
  }
  check(linked.openedByPage && !linked.openedByScript && linked.opener == nil, "a link tab has no opener")
  _ = await js(linked, "window.close(); true")
  try? await Task.sleep(nanoseconds: 500_000_000)
  check(browser.tabs.contains { $0 === linked }, "window.close() in a link tab does nothing")
  browser.close(linked)

  // An agent tab opens no popups.
  let agentTab = BrowserTab(owner: "popup-check")
  await load(agentTab)
  agentTab.lastInput = Date()
  check(await js(agentTab, open) as? String == "null", "agent tabs open no popups, also right after input")
}
#endif
