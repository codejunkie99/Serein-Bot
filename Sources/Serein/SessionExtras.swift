import Combine
import SereinCore
import SwiftUI

/// What survives a quit or a crash beyond the open tabs: the last few closed tabs, tabs folded
/// away from a group, closed windows, and whether the last run ended cleanly.
@MainActor final class SessionExtras: ObservableObject {
  static let shared = SessionExtras()
  static let cleanExitKey = "serein.cleanExit"
  @Published private(set) var folded: [FoldedGroup] = []
  @Published private(set) var closedTitles: [String: String] = [:]
  private weak var browser: BrowserModel?
  private var subscription: AnyCancellable?

  private static var inactive: Bool {
    CommandLine.arguments.contains("--verify") || CommandLine.arguments.contains("--ui-preview")
      || RunMode.stress
  }

  func attach(_ browser: BrowserModel) {
    self.browser = browser
    folded = browser.library.load([FoldedGroup].self, from: "sessions/folded.json") ?? []
    if let closed = browser.library.load([ClosedTab].self, from: "sessions/closed.json") {
      if browser.recentlyClosed.isEmpty { browser.recentlyClosed = closed.map(\.url) }
      closedTitles = Dictionary(
        closed.map { (PageIdentity.key($0.url), $0.title) }, uniquingKeysWith: { first, _ in first })
    }
    guard !Self.inactive else { return }
    let defaults = UserDefaults.standard
    // The tabs come back after an unclean exit without a banner: it only told the person what
    // they could already see.
    defaults.set(false, forKey: Self.cleanExitKey)
    subscription = browser.$recentlyClosed.dropFirst().sink { [weak self] _ in
      Task { @MainActor in self?.closedChanged() }
    }
  }
  /// Called once the app is certain to quit.
  func markCleanExit() {
    guard !Self.inactive else { return }
    if closedSave != nil { flushClosed() }
    UserDefaults.standard.set(true, forKey: Self.cleanExitKey)
  }
  private var closedSave: Task<Void, Never>?
  /// Closing several tabs in a row writes the closed list once, a moment after the last close.
  private func closedChanged() {
    guard closedSave == nil else { return }
    closedSave = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      self?.flushClosed()
    }
  }
  private func flushClosed() {
    closedSave?.cancel()
    closedSave = nil
    guard let current = browser?.recentlyClosed else { return }
    saveClosed(current)
  }

  // MARK: Recently closed

  private func title(for url: String) -> String? {
    let page = PageIdentity.key(url)
    if let known = closedTitles[page] { return known }
    return browser?.visits.first { PageIdentity.key($0.url) == page }?.title
  }
  /// The last five closed tabs, newest first.
  func recentlyClosed(limit: Int = 5) -> [ClosedTab] {
    guard let browser else { return [] }
    var titles = closedTitles
    for url in browser.recentlyClosed.suffix(limit) {
      if let value = title(for: url) { titles[PageIdentity.key(url)] = value }
    }
    return BrowserExtrasLogic.closedTabs(browser.recentlyClosed, titles: titles, limit: limit)
  }
  func reopen(_ tab: ClosedTab) {
    guard let browser else { return }
    if let index = browser.recentlyClosed.lastIndex(of: tab.url) { browser.recentlyClosed.remove(at: index) }
    browser.newTab(tab.url)
  }
  /// Drops closed tabs from the list without opening them; nil drops every one.
  func forget(_ tabs: [ClosedTab]?) {
    guard let browser else { return }
    if let tabs {
      let urls = Set(tabs.map(\.url))
      browser.recentlyClosed.removeAll { urls.contains($0) }
    } else {
      browser.recentlyClosed = []
    }
    writeClosedFile()
  }
  /// Clearing history clears recently closed and folded tabs too: all of them when `urls` is
  /// nil, otherwise only those addresses. The files on disk are rewritten or removed.
  func forgetHistory(_ urls: Set<String>?) {
    guard let browser else { return }
    ClosedWindows.forget(urls)
    let keys = urls.map { Set($0.map(PageIdentity.key)) }
    func gone(_ url: String) -> Bool { keys?.contains(PageIdentity.key(url)) ?? true }
    let before = browser.recentlyClosed
    browser.recentlyClosed.removeAll(where: gone)
    closedTitles = closedTitles.filter { key, _ in keys.map { !$0.contains(key) } ?? false }
    for i in folded.indices { folded[i].tabs.removeAll { gone($0.url) } }
    folded.removeAll { $0.tabs.isEmpty }
    if browser.recentlyClosed.isEmpty || before != browser.recentlyClosed { writeClosedFile() }
    if folded.isEmpty {
      try? FileManager.default.removeItem(
        at: browser.library.root.appendingPathComponent("sessions/folded.json"))
    } else {
      saveFolded()
    }
  }
  /// Rewrites sessions/closed.json from the current list, or removes it when the list is empty.
  /// Written even with history off, so nothing deleted or cleared comes back on the next launch.
  private func writeClosedFile() {
    // While GateSettings cannot be read every site counts as excluded: writing now would empty
    // the list for good.
    guard let browser, !GateSettings.shared.unreadable else { return }
    if browser.recentlyClosed.isEmpty {
      try? FileManager.default.removeItem(
        at: browser.library.root.appendingPathComponent("sessions/closed.json"))
      return
    }
    let list = browser.recentlyClosed.suffix(20)
      .filter { !BrowserTab.hostIsExcluded(URL(string: $0)?.host) }
      .map { ClosedTab(url: $0, title: title(for: $0) ?? "") }
    try? browser.library.save(Array(list), to: "sessions/closed.json")
  }
  private func saveClosed(_ urls: [String]) {
    guard let browser, browser.historyEnabled, !GateSettings.shared.unreadable else { return }
    // Sites kept out of history are not written to disk here either.
    let kept = urls.suffix(20).filter { !BrowserTab.hostIsExcluded(URL(string: $0)?.host) }
    let list = kept.map { ClosedTab(url: $0, title: title(for: $0) ?? "") }
    for item in list where !item.title.isEmpty { closedTitles[PageIdentity.key(item.url)] = item.title }
    do { try browser.library.save(list, to: "sessions/closed.json") } catch {
      browser.notice = error.localizedDescription
    }
  }

  // MARK: Folding

  /// Closes a group's tabs and keeps them on the start page until restored. Private and agent
  /// tabs are never folded.
  func fold(_ tabs: [BrowserTab], name: String) {
    guard let browser else { return }
    let eligible = tabs.filter { !$0.privateMode && $0.owner == nil && !$0.address.isEmpty }
    guard !eligible.isEmpty else { return }
    folded.insert(
      FoldedGroup(name: name, tabs: eligible.map { ClosedTab(url: $0.address, title: $0.title) }),
      at: 0)
    saveFolded()
    // Folding is not closing: the tabs should not show up as recently closed.
    let before = browser.recentlyClosed
    for tab in eligible { browser.close(tab) }
    browser.recentlyClosed = before
    let group = folded[0]
    ToastCenter.shared.show(
      "Folded \(eligible.count) tab\(eligible.count == 1 ? "" : "s") away. They wait on the start page."
    ) { [weak self] in self?.restore(group) }
  }
  func restore(_ group: FoldedGroup) {
    guard let browser, let current = folded.first(where: { $0.id == group.id }) else { return }
    for tab in current.tabs { browser.newTab(tab.url, select: false) }
    discard(group)
  }
  func discard(_ group: FoldedGroup) {
    folded.removeAll { $0.id == group.id }
    saveFolded()
  }
  private func saveFolded() {
    guard let browser else { return }
    do { try browser.library.save(folded, to: "sessions/folded.json") } catch {
      browser.notice = error.localizedDescription
    }
  }
}

/// Windows closed this session, so Reopen Closed Window can bring one back.
@MainActor enum ClosedWindows {
  private(set) static var stack: [[String]] = []
  static func record(_ urls: [String], browser: BrowserModel?) {
    guard !urls.isEmpty else { return }
    stack.append(urls)
    stack = Array(stack.suffix(5))
    // The window comes back as a whole, so its tabs are not also offered one by one.
    guard let browser else { return }
    for url in urls { if let i = browser.recentlyClosed.lastIndex(of: url) { browser.recentlyClosed.remove(at: i) } }
  }
  @discardableResult static func reopen() -> Bool {
    guard let urls = stack.popLast() else { return false }
    for url in urls { BrowserContext.browser?.openInDefaultBrowser(url) }
    return true
  }
  static func forget(_ urls: Set<String>?) {
    let keys = urls.map { Set($0.map(PageIdentity.key)) }
    stack = stack.map { tabs in
      tabs.filter { url in keys.map { !$0.contains(PageIdentity.key(url)) } ?? false }
    }.filter { !$0.isEmpty }
  }
  static var canReopen: Bool { !stack.isEmpty }
}

extension AppDelegate {
  /// Quitting with downloads running asks first; so does quitting while Serein works, or with a
  /// request due that it cannot run while closed (QuitGuard). A quit that goes ahead while a
  /// built-in computer is on waits until it saved its memory (ComputerHost.saveForQuit), at most
  /// two minutes, since the framework saves on the main queue.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let reply = terminateReply(sender)
    guard reply == .terminateNow, ComputerHost.shared.needsSaveForQuit else { return reply }
    final class Once {
      var sent = false
    }
    let once = Once()
    let send: @MainActor () -> Void = {
      guard !once.sent else { return }
      once.sent = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    Task { @MainActor in
      await ComputerHost.shared.saveForQuit()
      send()
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 120_000_000_000)
      send()
    }
    return .terminateLater
  }
  private func terminateReply(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let recording = PageViewportRecorder.shared
    if recording.busy {
      if recording.state == .recording { recording.stop() }
      else if recording.state == .ready { Task { await recording.save() } }
      // Finish/export first. Cancelled saves keep the video and its Save/Discard controls.
      return cancelQuit()
    }
    guard !RunMode.checking, preview == nil else {
      return .terminateNow
    }
    let count = DownloadCenter.shared.activeCount
    if count > 0 {
      let alert = NSAlert()
      alert.messageText = BrowserExtrasLogic.downloadsInProgress(count) + ". Quit anyway?"
      alert.informativeText = "Quitting stops them. A stopped download can often be resumed later."
      alert.addButton(withTitle: "Keep downloading")
      alert.addButton(withTitle: "Quit anyway")
      if alert.runModal() == .alertFirstButtonReturn { return cancelQuit() }
      DownloadCenter.shared.cancelAll()
    }
    // Closing the last window (or the end of the work it waited for) quits without asking once
    // its own question came at close, or when nothing was due then (quitAfterLastWindow). An
    // install the Update button or an agent started already asked about running tasks, so it
    // asks nothing more either; Sparkle's own Install and Relaunch still asks below.
    if closingLastWindow || Updates.shared.installing { return .terminateNow }
    guard let reason = quitReason() else { return .terminateNow }
    // A request alone never holds up a logout, restart or shutdown: the user did not choose to
    // quit Serein then, and cancelling would stop the whole thing.
    if reason.kind == .request, Self.systemQuit { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = reason.title
    alert.informativeText = reason.detail
    alert.addButton(withTitle: reason.keep)
    alert.addButton(withTitle: reason.quit)
    if let cancel = reason.cancel { alert.addButton(withTitle: cancel) }
    NSApp.activate(ignoringOtherApps: true)
    switch alert.runModal() {
    case .alertSecondButtonReturn: return .terminateNow
    case .alertFirstButtonReturn where reason.kind == .request:
      // Keep Serein in the menu bar: the switch keeps Serein (and the request) running, and the
      // window goes, as the user wanted from ⌘Q.
      keepInMenuBar()
      window?.close()
      return cancelQuit()
    default: return cancelQuit()
    }
  }
  /// A quit that does not go ahead: the next one asks again.
  private func cancelQuit() -> NSApplication.TerminateReply {
    closingLastWindow = false
    closeAnswered = false
    Updates.shared.installCancelled()
    return .terminateCancel
  }
  /// “Keep Serein in the menu bar” from a quit or close question. The confirmation line (“Serein
  /// stays in the menu bar. Turn this off in Settings › Assistants › Ask from any app.”) waits in Serein's chat for when
  /// the window comes back, as it does when the same button is chosen there.
  private func keepInMenuBar() {
    if let relay = RelayOrchestrator.shared {
      relay.keepInMenuBar()
    } else {
      if RelayOrchestrator.persists { RelayOrchestrator.menuBar = true }
      RelayController.shared?.install()
    }
  }
  /// A window the user can see and go back to is open: the main window, a private window or
  /// another browser window, minimized or not. PageAX's hidden host windows (borderless, parked
  /// off screen while an agent tab is read), panels and other helpers do not count.
  func userWindowOpen(excluding: NSWindow? = nil) -> Bool {
    NSApp.windows.contains { window in
      window !== excluding && (window.isVisible || window.isMiniaturized) && !(window is NSPanel)
        && !PageAX.isHost(window) && window.styleMask.contains(.titled) && window.canBecomeMain
    }
  }
  /// The last window closed and nothing keeps Serein running: quit. Silently when its close
  /// question was already answered or nothing is due; otherwise applicationShouldTerminate asks
  /// the request question as an alert, so a request is never missed without a word (the last
  /// window was a private one, say, so the main window's close never asked).
  func quitAfterLastWindow() -> Bool {
    if closeAnswered || nextRequest() == nil { closingLastWindow = true }
    closeAnswered = false
    return true
  }
  /// What quitting now would stop: live tasks (Serein's and the ones you started), Serein's
  /// reply, or the next request.
  func quitReason(now: Date = Date()) -> QuitGuard.Reason? {
    // `slotted` leaves out Serein's own run, which `replying` already counts.
    QuitGuard.reason(
      live: agent?.hub.slotted.count ?? 0, replying: RelayOrchestrator.shared?.working == true,
      nextRequest: nextRequest(now: now))
  }
  /// The request due in the next 24 hours that Serein would miss while closed; none while Stop
  /// Everything has Serein paused or nobody is signed in, since it would not run then anyway.
  func nextRequest(now: Date = Date()) -> QuitGuard.Request? {
    guard let relay = RelayOrchestrator.shared else { return nil }
    return QuitGuard.nextRequest(relay.reminders, now: now, paused: relay.state.paused)
  }
  /// The quit comes from a logout, restart or shutdown (the quit Apple event's reason).
  static var systemQuit: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    else { return false }
    return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
      .map { OSType($0) }.contains(reason)
  }
}

extension AppDelegate: NSWindowDelegate {
  /// Closing the window quits Serein when nothing keeps it running. With a request due in the
  /// next 24 hours, it asks first in a sheet with the same three buttons as ⌘Q, so the request is
  /// never missed silently. That includes while work runs: Serein then stays in the Dock until
  /// the work ends and quits after it (applicationShouldTerminateAfterLastWindowClosed), and the
  /// question says so. Work alone needs no question.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === window else { return true }
    closeAnswered = false
    guard RelayOrchestrator.persists, preview == nil,
      !RelayOrchestrator.enabled, !RelayOrchestrator.menuBar,
      !userWindowOpen(excluding: sender),
      let reason = QuitGuard.closeReason(working: assistantWorking, nextRequest: nextRequest())
    else { return true }
    let alert = NSAlert()
    alert.messageText = reason.title
    alert.informativeText = reason.detail
    alert.addButton(withTitle: reason.keep)
    alert.addButton(withTitle: reason.quit)
    if let cancel = reason.cancel { alert.addButton(withTitle: cancel) }
    alert.beginSheetModal(for: sender) { [weak self] response in
      switch response {
      case .alertFirstButtonReturn:
        // The switch keeps Serein running once the window closes.
        self?.keepInMenuBar()
        sender.close()
      case .alertSecondButtonReturn:
        // Close anyway. close() skips this question; the last window closing then quits (now,
        // or when the work ends) without asking again.
        self?.closeAnswered = true
        sender.close()
      default: break
      }
    }
    return false
  }
}

/// `--ui-serein-quit-guard`: the ⌘Q question, drawn over the window the way the alert would sit,
/// so a capture can show its words. It is a stand-in for the system alert, which shows the app
/// icon and draws its own buttons. Its words come from the app's own `quitReason()`, so they
/// always match what the window behind shows: the seeded chat with Serein's two tasks working
/// (“Working on 2 things”), or with `request`, a request turn and its 9:00 request, nothing
/// working. `--ui-serein-close-guard`: the sheet that closing the window asks with that request;
/// `--ui-serein-close-guard work` also has Serein's task working, so it quits when that ends.
struct QuitGuardPreview: View {
  @Environment(\.palette) private var p
  /// Closing the window rather than ⌘Q.
  var closing = false
  private var reason: QuitGuard.Reason? {
    guard let app = NSApp.delegate as? AppDelegate else { return nil }
    return closing
      ? QuitGuard.closeReason(working: app.assistantWorking, nextRequest: app.nextRequest())
      : app.quitReason()
  }
  var body: some View {
    if let reason {
      ZStack(alignment: .top) {
        p.scrim.ignoresSafeArea().allowsHitTesting(false)
        VStack(spacing: 12) {
          // The petal, not the app icon: an unbundled preview build has only a generic one.
          SereinMark(size: 40).accessibilityHidden(true)
          Text(reason.title).font(UIStyle.bodyStrong).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          Text(reason.detail).font(UIStyle.meta).foregroundStyle(p.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          // The system alert's own buttons: the default one filled with the system accent (drawn
          // here, since a preview window is never key and the system style would gray it), the
          // rest plain.
          VStack(spacing: 8) {
            Text(reason.keep).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 30)
              .background(Color(nsColor: .controlAccentColor), in: Capsule())
            Button {} label: { Text(reason.quit).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
            if let cancel = reason.cancel {
              Button {} label: { Text(cancel).frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
            }
          }.padding(.top, 4)
        }
        .padding(20).frame(width: 280)
        // The shadow belongs to the card's shape only; on the whole stack it drew a faint
        // outline behind the petal.
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.card)
            .shadow(color: .black.opacity(0.3), radius: 24, y: 10))
        .padding(.top, closing ? 28 : 60)
      }.foregroundStyle(p.ink)
    }
  }
}

/// Start-page cards: tabs folded away, and the last five tabs closed. Quiet when empty.
struct StartExtraCards: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var session = SessionExtras.shared
  /// A long press on a closed tab starts choosing; Delete removes the chosen, Clear All every one.
  @State private var selecting = false
  @State private var picked = Set<String>()
  @Environment(\.palette) var p
  var body: some View {
    let closed = session.recentlyClosed()
    VStack(alignment: .leading, spacing: 32) {
      if !session.folded.isEmpty {
        section("Folded away") {
          ForEach(session.folded) { group in
            HStack(spacing: 10) {
              InterfaceIcon(systemName: "tray.full", size: 14).foregroundStyle(p.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(UIStyle.body).lineLimit(1).truncationMode(.tail)
                Text("\(group.tabs.count) tab\(group.tabs.count == 1 ? "" : "s")").role(.meta)
              }
              Spacer()
              Button("Restore") { session.restore(group) }.buttonStyle(QuietButton())
              Button("Discard") { session.discard(group) }.buttonStyle(QuietButton())
                .foregroundStyle(p.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 10)
          }
        }
      }
      if !closed.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 4) {
            Text("Recently closed").font(UIStyle.body).foregroundStyle(p.secondary)
            Spacer()
            if selecting {
              Button {
                session.forget(closed.filter { picked.contains($0.url) })
                picked = []
                selecting = false
              } label: {
                Text("Delete").foregroundStyle(picked.isEmpty ? p.secondary : p.danger)
              }.buttonStyle(QuietButton()).disabled(picked.isEmpty)
                .help("Remove the chosen tabs from this list")
              Button("Cancel") {
                selecting = false
                picked = []
              }.buttonStyle(QuietButton())
            } else {
              Button("Clear All") { session.forget(nil) }.buttonStyle(QuietButton())
                .help("Empty the recently closed list")
            }
          }.font(UIStyle.meta).frame(height: 24)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(closed.enumerated()), id: \.offset) { _, tab in
              ClosedRow(tab: tab, selecting: selecting, picked: picked.contains(tab.url),
                open: { session.reopen(tab) },
                toggle: {
                  if picked.contains(tab.url) { picked.remove(tab.url) } else { picked.insert(tab.url) }
                },
                hold: {
                  selecting = true
                  picked.insert(tab.url)
                })
            }
          }.frame(maxWidth: .infinity, alignment: .leading).card(p)
        }
      }
    }.padding(.top, closed.isEmpty && session.folded.isEmpty ? 0 : 32)
  }
  func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(UIStyle.body).foregroundStyle(p.secondary).frame(height: 24)
      VStack(alignment: .leading, spacing: 0) { content() }
        .frame(maxWidth: .infinity, alignment: .leading).card(p)
    }
  }
}

/// One closed tab. Click reopens it; a long press starts choosing (then a click toggles the
/// box); a drag carries it to the tab list, sidebar or band, where letting go opens it.
private struct ClosedRow: View {
  let tab: ClosedTab
  var selecting: Bool
  var picked: Bool
  var open: () -> Void
  var toggle: () -> Void
  var hold: () -> Void
  @State private var hovered = false
  /// A hold that already started choosing: its release is not a click.
  @State private var held = false
  @ObservedObject private var drag = TabZoneDrag.shared
  @Environment(\.palette) var p
  var body: some View {
    HStack(spacing: 10) {
      if selecting {
        Button(action: toggle) {
          Image(systemName: picked ? "checkmark.square.fill" : "square").font(.system(size: 14))
            .foregroundStyle(picked ? p.accent : p.secondary).frame(width: 16)
        }.buttonStyle(.pressable).accessibilityLabel(picked ? "Chosen" : "Not chosen")
      } else {
        InterfaceIcon(systemName: "arrow.uturn.backward", size: 12).foregroundStyle(p.faint).frame(width: 16)
      }
      Text(tab.title).font(UIStyle.body).lineLimit(1).truncationMode(.tail)
      Spacer()
      Text(URL(string: tab.url)?.host ?? "").role(.micro).lineLimit(1)
    }.padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
      .background(hovered ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .opacity(drag.item?.id == tab.url ? 0.4 : 1)
      .onHover { hovered = $0 }.help(tab.url)
      .onTapGesture {
        if held { held = false } else if selecting { toggle() } else { open() }
      }
      .onLongPressGesture(minimumDuration: 0.45) {
        held = true
        if !selecting { hold() }
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 10, coordinateSpace: .named(AgentBubbleLayer.space))
          .onChanged { value in
            drag.update(TabZoneItem(id: tab.url, title: tab.title, icon: "arrow.uturn.backward", armed: "Open as a tab"), at: value.location)
          }
          .onEnded { value in drag.drop(at: value.location, open: open) })
      .accessibilityElement(children: .combine)
      .accessibilityLabel(selecting ? "\(picked ? "Chosen" : "Not chosen"): \(tab.title)" : "Reopen \(tab.title)")
      .accessibilityAction(named: "Choose") { hold() }
  }
}

/// What is carried toward the tab list: a closed tab, or a project to continue in a tab.
struct TabZoneItem: Equatable {
  var id: String
  var title: String
  var icon: String
  /// What letting go there does ("Open as a tab").
  var armed: String
}

/// An item in flight toward the sidebar (a project from Projects); dropping there opens it.
@MainActor final class TabZoneDrag: ObservableObject {
  static let shared = TabZoneDrag()
  @Published var item: TabZoneItem?
  @Published var point: CGPoint = .zero
  @Published var armed = false
  static func inTabZone(_ point: CGPoint) -> Bool {
    point.x < UIStyle.wallWidth
  }
  func update(_ item: TabZoneItem, at point: CGPoint) {
    self.item = item
    self.point = point
    armed = Self.inTabZone(point)
  }
  func drop(at point: CGPoint, open: () -> Void) {
    let hit = Self.inTabZone(point)
    item = nil
    armed = false
    if hit { open() }
  }
}

/// The dragged item under the pointer, over everything (ReferenceShell).
struct TabZoneGhost: View {
  @ObservedObject private var drag = TabZoneDrag.shared
  @Environment(\.palette) var p
  var body: some View {
    if let item = drag.item {
      HStack(spacing: 8) {
        InterfaceIcon(systemName: drag.armed ? "plus" : item.icon, size: 12)
          .foregroundStyle(drag.armed ? p.accent : p.secondary)
        Text(drag.armed ? item.armed : item.title).font(UIStyle.font(13)).lineLimit(1)
      }.padding(.horizontal, 12).frame(width: 220, height: 32, alignment: .leading)
        .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: UIStyle.rowRadius).stroke(drag.armed ? p.accent : p.borderStrong))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .position(x: drag.point.x + 20, y: drag.point.y + 12)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
  }
}
