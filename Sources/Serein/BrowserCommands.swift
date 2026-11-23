import Cocoa
import SereinCore
import WebKit

/// Finds the page a command should act on: one a task handed you, while it shows.
@MainActor enum BrowserContext {
  static weak var browser: BrowserModel?
  static var activeTab: BrowserTab? {
    guard let browser, browser.section == ShellSection.browser else { return nil }
    return browser.active
  }
}

extension BrowserModel {
  func noteClosed(_ address: String) {
    recentlyClosed.append(address)
    recentlyClosed = Array(recentlyClosed.suffix(20))
  }
}

extension BrowserTab {
  /// Settings › Privacy › History › Do not save these sites, kept in GateSettings: left out of history,
  /// sessions and page zoom, and never sent to an agent with the tabs (TabGroups).
  static let excludedSitesKey = "serein.excludedSites"
  static var excludedSites: [String] {
    (GateSettings.shared.string(forKey: excludedSitesKey) ?? "").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
  }
  /// While GateSettings cannot be read, every site counts as excluded.
  static func hostIsExcluded(_ host: String?) -> Bool {
    guard let host = host?.lowercased(), !host.isEmpty else { return false }
    if GateSettings.shared.unreadable { return true }
    return excludedSites.contains { !$0.isEmpty && (host == $0 || host.hasSuffix("." + $0)) }
  }
  func applyStoredZoom() {
    guard let key = PageZoom.key(host: web.url?.host) else { return }
    let stored = UserDefaults.standard.double(forKey: key)
    web.pageZoom = CGFloat(TextSize.pageZoom(site: stored, factor: Double(UIStyle.textScale)))
  }
}

extension AppDelegate {
  func installBrowserMenus(_ bar: NSMenu) {
    BrowserContext.browser = browser
    func make(
      _ title: String, _ action: Selector, _ key: String,
      _ mods: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = mods
      item.target = self
      return item
    }
    if let file = bar.items.first(where: { $0.submenu?.title == "File" })?.submenu {
      file.addItem(.separator())
      file.addItem(make("New Serein…", #selector(newAssistant), "n", [.command, .control]))
      file.addItem(make("New Team…", #selector(newTeam), ""))
    }
    let viewItem = NSMenuItem()
    let view = NSMenu(title: "View")
    viewItem.submenu = view
    let compactItem = make("Compact Mode", #selector(toggleCompact), "")
    compactItem.state = UserDefaults.standard.bool(forKey: "serein.compact") ? .on : .off
    view.addItem(compactItem)
    // Serein is the sidebar's main place.
    view.addItem(make("Serein", #selector(showSerein), "1", [.control]))
    view.addItem(.separator())
    view.addItem(make("Allow Web Inspector", #selector(toggleInspector), ""))
    bar.addItem(viewItem)
    let windowItem = NSMenuItem()
    let window = NSMenu(title: "Window")
    windowItem.submenu = window
    window.addItem(make("Next Task Tab", #selector(nextTaskTab), "]", [.command, .shift]))
    window.addItem(make("Previous Task Tab", #selector(previousTaskTab), "[", [.command, .shift]))
    bar.addItem(windowItem)
  }
  /// View › Serein ⌃1; legacy Agents requests also resolve to Serein.
  @objc func showSerein() { showPlace(.serein) }
  @objc func showAssistants() { showPlace(.assistants) }
  private func showPlace(_ mode: SidebarMode) {
    UserDefaults.standard.set(mode.rawValue, forKey: SidebarMode.key)
    NotificationCenter.default.post(name: SidebarPlaces.go, object: nil, userInfo: ["mode": mode.rawValue])
  }
  /// File › New Serein… ⌃⌘N: Serein's list and the name row; File › New Team…: the sheet.
  @objc func newAssistant() { NotificationCenter.default.post(name: AssistantSidebarState.newAssistant, object: nil) }
  @objc func newTeam() { TeamSheets.shared.present(.newTeam(.home)) }
  @objc func toggleCompact(_ sender: NSMenuItem) {
    let on = !UserDefaults.standard.bool(forKey: "serein.compact")
    UserDefaults.standard.set(on, forKey: "serein.compact")
    sender.state = on ? .on : .off
  }
  @objc func nextTaskTab() { cycleTasks(1) }
  @objc func previousTaskTab() { cycleTasks(-1) }
  /// Moves between the task tabs (Serein's own tasks live in its surface, never as tabs); from
  /// anything else it shows the current task tab.
  func cycleTasks(_ offset: Int) {
    guard let agent = browser.intelligenceAgent else { return }
    let ids = ThreadTabs.open(browser: browser, agent: agent).map(\.id)
    guard !ids.isEmpty else { return }
    let current = browser.section == ShellSection.thread ? ids.firstIndex(of: agent.conversationID) : nil
    let next = current.map { ids[(($0 + offset) % ids.count + ids.count) % ids.count] } ?? ids.last!
    SereinRouter.open(threadID: next)
  }
  @objc func toggleInspector() {
    let on = !UserDefaults.standard.bool(forKey: "serein.develop")
    UserDefaults.standard.set(on, forKey: "serein.develop")
    for tab in browser.tabs { tab.web.isInspectable = on }
  }
  @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(toggleInspector) {
      item.state = UserDefaults.standard.bool(forKey: "serein.develop") ? .on : .off
    }
    if item.action == #selector(toggleCompact) {
      item.state = UserDefaults.standard.bool(forKey: "serein.compact") ? .on : .off
    }
    if item.action == #selector(showSerein) || item.action == #selector(showAssistants) {
      let mode = SidebarMode(rawValue: UserDefaults.standard.string(forKey: SidebarMode.key) ?? "") ?? .serein
      item.state = mode == (item.action == #selector(showSerein) ? .serein : .assistants) ? .on : .off
      return true
    }
    if item.action == #selector(newAssistant) || item.action == #selector(newTeam) {
      return RelayController.shared != nil
    }
    if item.action == #selector(checkForUpdates) { return Updates.shared.isAvailable }
    if item.action == #selector(toggleRelayColumn) {
      // Serein full: back to your tab (“Back to Your Tab” with no room there; disabled with no
      // tab). A tab with Serein beside, or with no room: Serein full. Hidden: beside again.
      let state = SereinRouter.switchState
      item.title = state.title
      return RelayController.shared != nil && state.enabled
    }
    // Only what Stop Everything stops: Serein's reply and the tasks it started (a task you
    // started yourself has its own Stop).
    if item.action == #selector(stopEverything) {
      guard let relay = RelayOrchestrator.shared, RelayController.shared != nil else { return false }
      return relay.working || relay.childRuns.contains(where: \.isActive)
    }
    return true
  }
}
