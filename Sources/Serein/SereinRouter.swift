import AppKit
import Combine
import SereinCore

/// Every way to reach Serein goes through here, so each kind of chat has one home:
/// - Serein's own chats show in the Serein surface (they become its current chat);
/// - tasks Serein started show where Serein is, in its task view (`SereinTaskView`);
/// - every other chat is a task tab.
/// Only `ask` sends (the address field's Ask Serein row); `show(draft:)` fills Serein's composer and
/// focuses it. The main view changes only for an explicit action (a click, a menu, a notification).
@MainActor enum SereinRouter {
  static weak var browser: BrowserModel?
  static weak var agent: AgentModel?
  /// Brings the main window forward (set by the app delegate; nil in checks).
  static var bringWindowForward: (() -> Void)?
  /// Set while the router itself opens a chat as a task tab, so AgentModel does not route it back.
  private(set) static var opensDirectly = false

  static func attach(browser: BrowserModel, agent: AgentModel) {
    self.browser = browser
    self.agent = agent
    // `@Published` sends before the value changes, so `browser.section` is still the old one
    // here: the view left for Serein full is the one ⌘J goes back to. Another selection ends a
    // peek in the same turn, before anything sets a new one.
    SereinPageChip.shared.attach(browser)
    watches = [
      browser.$section.removeDuplicates().sink { [weak browser] next in
        guard let browser, next != browser.section else { return }
        if next == ShellSection.serein {
          lastTab = browser.section
          // The page you leave for Serein full stays the chip's page for 10 minutes.
          SereinPageChip.shared.leaving(browser)
        }
        endPeek()
      },
      browser.$selected.removeDuplicates().sink { [weak browser] next in
        guard let browser, next != browser.selected else { return }
        endPeek()
      },
    ]
  }
  private static var watches: [AnyCancellable] = []
  /// The view in front before Serein full, for ⌘J's way back.
  private(set) static var lastTab: String?
  /// Opens a chat as an ordinary task tab, skipping the routing (the router and the task panel).
  static func direct(_ body: () -> Void) {
    let was = opensDirectly
    opensDirectly = true
    defer { opensDirectly = was }
    body()
  }

  /// Serein full: a new window, the last tab closed, or no tab left to show.
  static func home() {
    guard let browser else { return }
    browser.section = ShellSection.serein
  }

  /// The Serein row and the band tab: Serein full, always (even with Serein beside a page),
  /// its chat showing and its composer focused; a click while full only focuses it.
  static func showFull() {
    let surface = SereinSurface.main
    surface.view = .chat
    if SereinLayout.rowClick(place: surface.place) == .showFull { home() }
    surface.requestFocus()
  }

  /// ⌘E, File › Ask Serein, the petal and Serein buttons, the new-tab page's “Or ask Serein”, the
  /// slim line's Show: Serein's chat shows and its composer takes the keyboard. A draft fills the
  /// composer; nothing is sent. Serein beside stays beside; hidden, it peeks beside this tab
  /// (the saved choice stays); with no room it shows full.
  static func show(draft: String? = nil, attach: SereinAttachment? = nil) {
    let surface = SereinSurface.main
    surface.view = .chat
    if let draft = draft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
      surface.draft = surface.draft.isEmpty ? draft : surface.draft + "\n" + draft
    }
    if let attach { surface.attach(attach) }
    reveal()
    surface.requestFocus()
  }

  /// ⌘E in the main window: Serein's chat, focused, as `show()` does; with no room for Serein
  /// beside the page (Compact Mode, a narrow window), the bar at the window's top centre instead,
  /// so the page stays as it is.
  static func askFromKeyboard() {
    let surface = SereinSurface.main
    if let browser, browser.section != ShellSection.serein, !surface.fits, let controller = RelayController.shared,
      let window = (NSApp.delegate as? AppDelegate)?.window
    {
      controller.showInWindow(window, isPrivate: false)
      return
    }
    show()
  }
  /// Open in Serein, on the ⌥Space bar's reply card: Serein's chat where it lives, beside when it
  /// is beside this tab, else full. (The window was brought forward first.)
  static func openFromBar() {
    let surface = SereinSurface.main
    surface.view = .chat
    if surface.place != .beside { home() }
    surface.requestFocus()
  }
  /// Asks Serein now: the address field's Ask Serein row. The reply shows where Serein is: beside
  /// (a peek when hidden), never a switch to full; with no room for Serein beside the page, in the
  /// in-window bar's reply card. `page` is the page chip's tab, when the chip is there.
  static func ask(_ text: String, page: SereinPage? = nil) {
    guard let relay = RelayOrchestrator.shared else { return }
    if page != nil { SereinPageChip.shared.markSeen() }
    let surface = SereinSurface.main
    if let browser, browser.section != ShellSection.serein, !surface.fits, let controller = RelayController.shared,
      let window = (NSApp.delegate as? AppDelegate)?.window
    {
      controller.showInWindow(window, isPrivate: false)
      controller.sendFromBar(text, page: page)
      return
    }
    relay.ask(text, page: page)
    surface.view = .chat
    reveal()
  }

  /// Puts the surface on screen: where Serein lives, a peek when hidden, full when there is no
  /// room. The main view stays unless Serein has to show full.
  private static func reveal() {
    let surface = SereinSurface.main
    apply(SereinLayout.askFromHidden(place: surface.place, fits: surface.fits))
  }

  // MARK: placement (Serein beside)

  /// Serein beside is the saved choice (`serein.relay.column`).
  static var besideOn: Bool {
    UserDefaults.standard.object(forKey: RelayController.columnKey) as? Bool ?? true
  }
  /// Serein beside only because something asked from this tab.
  static var peeking: Bool { SereinLayout.peeking(peek: SereinSurface.main.peek, besideOn: besideOn) }
  /// Where ⌘J goes back to from Serein full: the view before it, while it still has something
  /// to show (a page needs a tab, Serein's page needs one too).
  static var returnSection: String? {
    guard let browser else { return nil }
    func page() -> String? { browser.active.map { browser.isNew($0) ? ShellSection.start : ShellSection.browser } }
    switch lastTab {
    case nil, ShellSection.serein?, ShellSection.browser?, ShellSection.start?: return page()
    case ShellSection.agent?: return browser.agentTabs.focused == nil ? page() : ShellSection.agent
    case ShellSection.thread?: return agent?.openThreads.isEmpty == false ? ShellSection.thread : page()
    case let other?: return other
    }
  }
  /// ⌘J's title and what it does now.
  static var switchState: SereinSwitch {
    let surface = SereinSurface.main
    return SereinLayout.afterSwitch(place: surface.place, fits: surface.fits, hasTab: returnSection != nil)
  }
  /// ⌘J, Make full, Put beside: Serein full ⇄ beside (from hidden, beside turns on). The draft,
  /// the chat, the task in view and the hologram's engine live in the surface, so nothing is lost
  /// on the way.
  static func toggleFullBeside() {
    let state = switchState
    guard state.enabled else { return }
    apply(state.move)
    SereinSurface.main.requestFocus()
  }
  /// Hide (× in the side header): beside turns off, or a peek ends. The toast's Undo puts it back.
  static func hide() {
    let wasPeeking = peeking
    apply(SereinLayout.hide(peeking: wasPeeking))
    returnFocusToPage()
    showHiddenToast(undo: SereinLayout.undoHide(peeking: wasPeeking))
  }
  /// “Serein is hidden. Press ⌘J to bring it back.”, with Undo; it stays while the pointer or
  /// the keyboard is on it, and VoiceOver reads it. `--ui-serein-hidden` holds it on screen.
  static func showHiddenToast(undo: SereinMove = SereinMove(besideOn: true), duration: TimeInterval? = 8) {
    ToastCenter.shared.show(
      "Serein is hidden. Press ⌘J to bring it back.", id: "serein-hidden", actionTitle: "Undo",
      duration: duration, opaque: true
    ) { apply(undo) }
  }
  /// Keep beside (the peek's pin): the peek becomes the saved choice.
  static func keepBeside() { apply(SereinLayout.keepBeside) }
  /// Esc in an empty composer beside: the keyboard goes back to the page, and a peek ends.
  static func escapeSide() {
    endPeek()
    returnFocusToPage()
  }
  private static func returnFocusToPage() {
    if let browser { TaskPanelFocus.returnToPage(browser) }
  }
  static func endPeek() {
    if SereinSurface.main.peek { apply(SereinLayout.endPeek) }
  }
  /// Carries out one placement change. `besideOn == nil` never writes the saved choice.
  static func apply(_ move: SereinMove) {
    let surface = SereinSurface.main
    switch move.target {
    case .stay: break
    case .full: home()
    case .back: if let back = returnSection, let browser { browser.section = back }
    }
    if let on = move.besideOn { RelayOrchestrator.setSetting(on, forKey: RelayController.columnKey) }
    if let peek = move.peek, surface.peek != peek { surface.peek = peek }
  }

  /// A chat row, a notification, a card's Open: the rule per kind.
  static func open(threadID id: String) {
    guard let agent, let browser else { return }
    if let relay = RelayOrchestrator.shared {
      if relay.isChild(id) {
        openTask(id)
        return
      }
      if id == relay.threadID || (agent.openThreadItem(id).map(agent.isSereinChat) ?? relay.knownThreadIDs.contains(id)) {
        // Its one conversation (or another assistant's) shows as the chat; an earlier chat of
        // Serein's opens to read.
        SereinSurface.main.view = relay.resumeChat(id) ? .chat : .pastChat(id)
        reveal()
        SereinSurface.main.requestFocus()
        return
      }
    }
    guard let item = agent.openThreadItem(id) else { return }
    direct { agent.openConversation(item) }
    if browser.section != ShellSection.thread { browser.section = ShellSection.thread }
  }

  /// A task Serein started: its view in the Serein surface, where Serein is (beside, a peek when
  /// hidden, full with no room). The main view stays as it was, and AgentModel's current chat is
  /// never touched, so a task tab and this view can show at once.
  static func openTask(_ id: String) {
    // A deleted task's chat has nothing to show.
    if let agent, !SereinTray.shared.exists(id, agent: agent) { return }
    SereinSurface.main.view = .task(id)
    reveal()
  }
  /// Back from a task's view to Serein's own chat (“‹ Serein”, Show on the waiting line).
  static func backToChat() {
    SereinSurface.main.view = .chat
    SereinSurface.main.requestFocus()
  }
}
