import AVFoundation
import AppKit
import Combine
import SereinCore
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Relay on screen: a floating panel over every app and Space (⌥Space by default), a menu bar
/// item, and the kill switch (⌃⌥⌘.). The panel does not activate Serein, so the app the user
/// was in stays in front behind it.
@MainActor final class RelayController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  static private(set) var shared: RelayController?
  let relay: RelayOrchestrator
  private var panel: RelayWindow?
  /// The panel's hologram, on its own transparent window standing on the panel's top edge.
  private var hologramWindow: NSPanel?
  nonisolated static let hologramHeight: CGFloat = 230
  nonisolated static let hologramWidth: CGFloat = 400
  /// The summon bar under the hologram: a field, or what it hears while ⌥Space is held.
  static let barSize = NSSize(width: 420, height: 40)
  /// The hologram's size on a screen whose visible height is `screenHeight`: 400 by 230 up to
  /// 820 points, and larger in step with a taller screen, up to half again.
  nonisolated static func hologramSize(screenHeight: CGFloat) -> NSSize {
    let scale: CGFloat = max(1, min(1.5, screenHeight / 820))
    return NSSize(width: (hologramWidth * scale).rounded(), height: (hologramHeight * scale).rounded())
  }
  /// What the user is writing in the summon bar; kept while it is put away.
  @Published var summonDraft = "" {
    didSet { if summonDraft != oldValue { barRefusal = nil } }
  }
  /// Why the bar kept its words (`MessagePlan.refuse`), for the line under it: a toast draws only in Serein's window.
  @Published private(set) var barRefusal: String?
  /// The reason to draw: gone once the same words would go, as when a mention's wait ends.
  var barRefusalShown: String? {
    barRefusal == nil ? nil : relay.messagePlan(
      summonDraft.trimmingCharacters(in: .whitespacesAndNewlines), hasAttachments: false, answersQuestion: false).refusal
  }
  private var status: NSStatusItem?
  private var summon: GlobalHotKey?
  private var kill: GlobalHotKey?
  private var fnWatch: FnKeyWatch?
  private var watch: AnyCancellable?
  private let voice = AVSpeechSynthesizer()
  private let cloudVoice = CloudVoicePlayer()
  /// Hold-to-talk: one recognizer for the panel's microphone and for holding the shortcut.
  let dictation = Dictation()
  /// The pill a hold shows when no bar is up (VoicePillPanel.swift).
  let voicePill = VoicePillController()
  /// What the recognizer heard so far while the shortcut is held.
  @Published private(set) var heard = ""
  /// Call mode: a hands-free loop where replies are read aloud and the mic is a big button.
  @Published var callMode = false {
    didSet {
      guard callMode != oldValue else { return }
      voiceReadBack = nil
      // Nothing held or announced in one call carries into the next.
      heldReply = nil
      announcedCard = nil
      if callMode { announceCard(relay.approvals.first?.id) }
      // A call has the microphone: the wake phrase lets go of it until the call ends.
      WakeListener.shared.refresh()
    }
  }
  /// The card a spoken “allow” was read back for, waiting for “yes” (`CallVoice.readBackWindow`).
  @Published private(set) var voiceReadBack: UUID?
  private var readBackAt = Date.distantPast
  /// The utterance being spoken, and when Serein last stopped speaking: the call's microphone
  /// opens only `CallVoice.echoGuard` after that.
  private var utterance: AVSpeechUtterance?
  private(set) var spokeUntil = Date.distantPast
  /// Serein is speaking, or about to (the wake phrase keeps off the microphone meanwhile).
  var talking: Bool { utterance != nil || speaking }
  /// The call button's hold: its number, the card on screen when it began, and when the
  /// microphone opened (nil while the echo guard holds it shut).
  private var callHold = 0
  private var holdCard: UUID?
  private var micOpenedAt: Date?
  /// The hold whose microphone last recognised words: text from any other hold or session never
  /// counts as this hold's answer.
  private var heardHold = 0
  /// The hold whose words are being finished: its own microphone closing must not speak over it.
  private var releasingHold: Int?
  private var cardWatch: AnyCancellable?
  private var micClosedWatch: AnyCancellable?
  /// The card whose question was last read aloud, and a reply refused while a microphone was
  /// open: both are spoken when the hold ends.
  private var announcedCard: UUID?
  private var heldReply: String?
  private var progressWatch: AnyCancellable?
  private var lastProgressStep: String?
  private var lastProgressAt = Date.distantPast
  /// Relay reads a reply aloud.
  @Published private(set) var speaking = false
  /// The floating panel is on screen: the column's hologram behind it holds still meanwhile.
  @Published private(set) var panelShown = false
  /// What was last asked from the bar, which its reply card follows. Reopened within two minutes,
  /// the bar shows it collapsed to one line; after that it goes.
  struct BarExchange: Equatable {
    let prompt: String
    let at: Date
    /// Who spoken words went to, when the route chose (`VoiceRoute`): shown under them as "To Scout".
    var to: String? = nil
    /// Your messages already in Serein's chat when this was sent: the turn that answers it is the
    /// first one after them, whatever words it carries (a message sent while Serein works goes
    /// with “I interrupted you…”).
    var before: Set<String> = []
    var collapsed = false
  }
  @Published var barExchange: BarExchange?
  /// How long after it was asked a put-away bar still holds its last exchange.
  static let exchangeKept: TimeInterval = 120
  /// The chat whose turn answers the bar's message, while that turn runs (BarWork).
  private var barTurnThread: String?
  /// The bar went while that turn ran: its end gets one notification.
  private var barTurnNotifies = false
  private var barStepAside: Task<Void, Never>?
  /// The bar sits at the top centre of a window (⌘E in Compact Mode, a window with no room beside
  /// the page, a private or other window) rather than over every app: true for a private window.
  @Published private(set) var inWindowPrivate: Bool?
  var inWindow: Bool { inWindowPrivate != nil }
  /// The reply card's way to the chat: “Open in Serein” over other apps, “Show in chat” in
  /// Serein's own window.
  var openLabel: String { Self.openLabel(inWindow: inWindow) }
  static func openLabel(inWindow: Bool) -> String { inWindow ? "Show in chat" : "Open in Serein" }
  private weak var anchorWindow: NSWindow? {
    didSet { if anchorWindow !== oldValue { watchAnchor() } }
  }
  /// The in-window bar follows its window: it moves and resizes with it, and goes when the
  /// window closes or goes to the Dock.
  private var anchorWatch: [AnyCancellable] = []
  /// Say “Serein” (WakeListener): what was heard after the name, while the bar listens for the
  /// rest; nil otherwise. It is shown, never written into `summonDraft`.
  @Published private(set) var wakeWords: String?
  /// The wake phrase opened the bar: it goes again when nothing is sent.
  private var wakeOpenedBar = false
  /// The first hold while macOS has not been asked about the microphone or speech: the bar says
  /// what is about to happen, asks, and sends nothing.
  @Published private(set) var micNotice = false
  private var askingMic = false
  /// The bar has the keyboard (a tap puts it away); one that opened on its own for an approval,
  /// or lost the keyboard to a click elsewhere while a card waits, does not (a tap gives it).
  private var barHasKeyboard = false
  /// The bar opened on its own for an answer: once nothing waits, it goes again.
  private(set) var answerOnly = false
  /// The top edge of the bar on screen; the reply card grows down from it.
  private var barTop: CGFloat = 0
  /// The bar's height with its reply card (the bar alone is 40 points).
  private var barHeight: CGFloat = RelayController.barSize.height
  /// Serein's chat is on screen in a window in front of the user (the bar may have the keyboard):
  /// a message sent from the bar is answered there, and the bar goes.
  var chatInFront: () -> Bool = { RelayController.chatInFront }
  /// Spoken words, finished and failed jobs, and look previews, for the hologram.
  let avatarEvents = PassthroughSubject<RelayAvatarEvent, Never>()
  /// The window's Relay column is on screen (its hologram can show a preview). A count, so two
  /// columns overlapping in a transition never leave it false.
  static var columnShown: Bool { columnCount > 0 }
  static var columnCount = 0
  /// Serein's chat is where the user can answer it: Serein is full or beside
  /// (`SereinLayout.place`) on its chat, not a task, its view is mounted, the app is active, and
  /// the main window is key and not covered by another window.
  static var chatOnScreen: Bool {
    guard SereinSurface.main.chatShowing, columnShown, NSApp.isActive, let window = (NSApp.delegate as? AppDelegate)?.window,
      window.isKeyWindow, window.isVisible, !window.isMiniaturized
    else { return false }
    return window.occlusionState.contains(.visible)
  }
  /// Serein's chat is on screen in its window, though another app may be in front (side by side).
  static var chatVisible: Bool {
    guard SereinSurface.main.chatShowing, columnShown, let window = (NSApp.delegate as? AppDelegate)?.window,
      window.isVisible, !window.isMiniaturized, window.attachedSheet == nil
    else { return false }
    return window.occlusionState.contains(.visible)
  }
  /// Serein's chat shows in the window in front (the ⌥Space bar may hold the keyboard over it).
  static var chatInFront: Bool {
    guard SereinSurface.main.chatShowing, columnShown, NSApp.isActive, let window = (NSApp.delegate as? AppDelegate)?.window,
      window.isMainWindow || window.isKeyWindow, window.isVisible, !window.isMiniaturized
    else { return false }
    return window.occlusionState.contains(.visible)
  }
  /// Serein's window is in front and key, whatever it shows. A sheet on it (Settings, the connect
  /// sheet) does not count: the slim line would sit under the sheet, so a card goes to the bar,
  /// which floats above it.
  static var windowKey: Bool {
    guard NSApp.isActive, let window = (NSApp.delegate as? AppDelegate)?.window, window.isVisible, !window.isMiniaturized,
      window.attachedSheet == nil
    else { return false }
    let key = NSApp.keyWindow
    return window.isKeyWindow || (key != nil && (key?.sheetParent === window || key?.parent === window))
  }
  /// The frontmost app is another app whose frontmost window covers its screen (full screen).
  static func frontAppFullScreen() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let front = list.first(where: {
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
      }),
      let bounds = front[kCGWindowBounds as String] as? NSDictionary,
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { return false }
    // Screens in the window list's coordinates: the origin at the top left of the first screen.
    let height = NSScreen.screens.first?.frame.height ?? 0
    let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: height - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    return ApprovalPlacement.covers(window: rect, screens: screens)
  }
  /// Serein's chat is in an open window, even one behind another app or covered: a card waiting
  /// there is seen when the user comes back.
  static var chatShown: Bool {
    guard SereinSurface.main.chatShowing, columnShown, let window = (NSApp.delegate as? AppDelegate)?.window else { return false }
    return window.isVisible && !window.isMiniaturized
  }
  /// The row's accent dot clears once Serein's chat is on screen again, full or beside.
  static func markRead() {
    guard chatShown, SereinSurface.main.view == .chat else { return }
    SereinSurface.controller?.relay.chatRead()
    if SereinSurface.main.unread { SereinSurface.main.unread = false }
  }
  /// When the person last went to another app or closed or hid the window: the away card's time
  /// (`AwaySummaryCard`). Nil until then, as after a launch.
  static var leftAt: Date?
  private var activation: AnyCancellable?
  /// The app going to the background, and the window closing or going to the Dock: what moves
  /// a waiting card, or says that it waits.
  private var placement: [AnyCancellable] = []
  /// Whether anything waits on the user (an approval, the one-time card, a question, a reminder):
  /// a bar that opened by itself for it goes once nothing does.
  private var waitingWatch: AnyCancellable?
  private var pressedAt: Date?
  private var wasOpen = false
  private var wasKey = false
  private var holdTimer: Task<Void, Never>?
  /// A key is down, or Talk to Serein is listening for a click.
  private(set) var holding = false
  /// Opens Serein's window on a thread (set by the app delegate).
  var openThread: (String) -> Void = { _ in }
  /// Opens Settings on a category ("Relay", "Agents").
  var openSettings: (String) -> Void = { _ in }
  /// Brings Serein's window forward (the menu bar item with ⌥Space off).
  var openWindow: () -> Void = {}
  static let speakKey = "serein.relay.speak"
  /// Settings › Serein › Voice: short progress lines in a call (on), and answering low-risk
  /// questions by voice (off).
  static let speakProgressKey = "serein.relay.call.progress"
  static let voiceAnswersKey = "serein.relay.call.voiceAnswers"
  static var speakProgress: Bool { UserDefaults.standard.object(forKey: speakProgressKey) as? Bool ?? true }
  static var voiceAnswers: Bool { GateSettings.shared.bool(forKey: voiceAnswersKey) }
  static let columnKey = "serein.relay.column"
  /// UI previews: no shortcuts or menu bar item, only the panel's views.
  static var previewing = false
  /// The summon shortcut could not be registered (another app holds it); Settings says so.
  private(set) var summonTaken = false

  static func start(agent: AgentModel, browser: BrowserModel) {
    guard shared == nil else {
      shared?.install()
      return
    }
    let relay = RelayOrchestrator.start(agent: agent, browser: browser)
    let controller = RelayController(relay: relay)
    shared = controller
    // The launch restored the selected thread before Serein knew its own chats.
    agent.recheckSereinChat()
    controller.install()
  }
  private init(relay: RelayOrchestrator) {
    self.relay = relay
    super.init()
    relay.panelVisible = { [weak self] in self?.panel?.isVisible == true }
    relay.chatOnScreen = { Self.chatOnScreen }
    relay.chatShown = { Self.chatShown }
    // Back from System Settings: a card's Automation line reads the permission again.
    activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak relay] _ in
        relay?.refreshAutomation()
        Self.markRead()
      }
    // A card in the chat of a window behind another app waits there, with a notification; once
    // the window closes or goes to the Dock, the card moves to an alert.
    let center = NotificationCenter.default
    placement = [
      // To another app: a card on the slim line (Serein's chat not shown) moves to the bar, as a
      // new one would (F7); a card in a chat left open behind the other app waits there, with a
      // notification.
      center.publisher(for: NSApplication.didResignActiveNotification)
        .sink { [weak relay] _ in
          Self.leftAt = Date()
          relay?.cardsWaitUnseen()
          if !Self.chatShown { Self.reviewCardsSoon(relay) }
        },
      center.publisher(for: NSWindow.willCloseNotification)
        .merge(with: center.publisher(for: NSWindow.didMiniaturizeNotification))
        .filter { ($0.object as? NSWindow) === (NSApp.delegate as? AppDelegate)?.window }
        .sink { [weak relay] _ in
          Self.leftAt = Date()
          Self.reviewCardsSoon(relay)
        },
      // Back to a window whose chat shows (full or beside): the reply is read there.
      center.publisher(for: NSWindow.didBecomeKeyNotification)
        .merge(with: center.publisher(for: NSWindow.didDeminiaturizeNotification))
        .filter { ($0.object as? NSWindow) === (NSApp.delegate as? AppDelegate)?.window }
        .sink { _ in Self.markRead() },
    ]
    // Watched here, not in the bar's view: the card leaves the view in the same update.
    waitingWatch = relay.$approvals.map { !$0.isEmpty }
      .combineLatest(relay.$questionForms.map { !$0.isEmpty }, relay.$consentWaiting, relay.$dueReminders.map { !$0.isEmpty })
      .map { $0 || $1 || $2 || $3 }
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] waiting in
        // (A bar you wrote in, or gave the keyboard, is no longer answer-only and stays.)
        guard let self, !waiting, self.answerOnly, self.panel?.isVisible == true else { return }
        self.hide()
      }
    relay.showPanel = { [weak self] in self?.show() }
    relay.showForAnswer = { [weak self] in self?.show(focus: false) }
    relay.windowKey = { Self.windowKey }
    relay.frontFullScreen = { Self.frontAppFullScreen() }
    relay.chatVisible = { Self.chatVisible }
    relay.previewLook = { [weak self] state, seconds in
      guard let self else { return false }
      self.avatarEvents.send(.preview(state, seconds))
      return self.panel?.isVisible == true || Self.columnShown
    }
    voice.delegate = self
    // In a call: each new card is read aloud, and a read-back for a card that went is dropped.
    cardWatch = relay.$approvals.map { $0.first?.id }.removeDuplicates().receive(on: RunLoop.main)
      .sink { [weak self] id in
        guard let self else { return }
        if self.voiceReadBack != id { self.voiceReadBack = nil }
        self.announceCard(id)
      }
    // Any microphone closing in a call: what it kept from being spoken is spoken now.
    micClosedWatch = dictation.$recording.removeDuplicates().filter { !$0 }.receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.speakHeld() }
    // Steps on the agent tab board and the hub's tick while runs work: a short progress line.
    progressWatch = relay.browser.agentTabs.$runs.map { _ in () }
      .merge(with: relay.agent.hub.$now.map { _ in () })
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.sayProgress() }
    let previous = relay.agent.hub.onEnd
    relay.agent.hub.onEnd = { [weak self] run in
      previous?(run)
      self?.ended(run)
    }
  }
  /// Turns the shortcuts and menu bar item on or off to match Settings: the global shortcuts
  /// only with ⌥Space on; the menu bar item with ⌥Space or Keep Serein in the menu bar.
  func install() {
    // File › Stop Everything carries the same key in the window, with or without ⌥Space.
    (NSApp.delegate as? AppDelegate)?.refreshStopEverythingKey()
    guard !Self.previewing else { return }
    // The faces at the edge of the screen have their own switch, with ⌥Space on or off.
    AssistantDock.shared.install(relay: relay)
    ScreenSignals.shared.install(controller: self)
    ScreenTrailWatch.shared.refresh()
    // Say “Serein” needs ⌥Space: it follows it on or off.
    defer { WakeListener.shared.attach(self) }
    summon?.unregister()
    kill?.unregister()
    fnWatch?.stop()
    summon = nil
    kill = nil
    fnWatch = nil
    let global = RelayOrchestrator.enabled
    voicePill.onClick = { [weak self] in self?.talkFromMenu() }
    voicePill.onMicFailed = { [weak self] in self?.micFailed() }
    voicePill.rest(global && !RunMode.automated && Self.pillOn)
    // Checks and previews never touch the Mac's own Globe key setting.
    if !RunMode.automated { GlobeKey.apply(fnCalls: global && Self.fnCallOn) }
    guard global || RelayOrchestrator.menuBar else {
      if let status { NSStatusBar.system.removeStatusItem(status) }
      status = nil
      watch = nil
      hide()
      return
    }
    // A check or preview run never takes ⌥Space or Fn from the person's apps: a held key there
    // would start listening in a process with no speech permission text, and macOS ends it.
    if global, RunMode.automated {
      summonTaken = false
    } else if global {
      let defaults = UserDefaults.standard
      summon = GlobalHotKey(
        defaults.string(forKey: RelayOrchestrator.summonKey) ?? RelayHotKey.summon,
        release: { [weak self] in self?.summonReleased() }
      ) { [weak self] in self?.summonPressed() }
      summonTaken = summon == nil
      kill = GlobalHotKey(defaults.string(forKey: RelayOrchestrator.killKey) ?? RelayHotKey.killSwitch) { [weak self] in
        self?.killSwitch()
      }
      if Self.fnCallOn {
        fnWatch = FnKeyWatch(claimed: { PushToTalk.ownsFn }) { [weak self] in self?.fnCalled($0) }
      }
    } else {
      summonTaken = false
      hide()
    }
    if status == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      item.button?.image = Self.trayMark(working: false)
      item.button?.target = self
      item.button?.action = #selector(statusClicked)
      item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
      status = item
    }
    // The bar is made now; the hologram's window, with its own web view and WebGL page, on the
    // first ⌥Space (`showHologram`), so a launch that never summons it never loads it.
    if global, panel == nil { panel = makePanel() }
    watch = relay.agent.hub.$runs.combineLatest(relay.agent.hub.$now, MacAwake.shared.$tasks, WakeListener.shared.$state)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refreshStatus() }
  }
  var summonLabel: String {
    RelayHotKey.symbols(UserDefaults.standard.string(forKey: RelayOrchestrator.summonKey) ?? RelayHotKey.summon)
  }
  var killLabel: String {
    RelayHotKey.symbols(UserDefaults.standard.string(forKey: RelayOrchestrator.killKey) ?? RelayHotKey.killSwitch)
  }
  private func refreshStatus() {
    let working = relay.childRuns.filter(\.isActive).count + (relay.run != nil ? 1 : 0)
    // While the wake phrase has the microphone on, the mark carries a microphone.
    let listening = WakeListener.shared.state.micOn
    status?.button?.image = Self.trayMark(working: working > 0, listening: listening)
    status?.button?.title = working > 1 ? " \(working)" : ""
    status?.length = working > 1 || listening ? NSStatusItem.variableLength : NSStatusItem.squareLength
    let tip = working > 0 ? "Serein · working on \(working)"
      : RelayOrchestrator.enabled ? "Serein · \(summonLabel)" : "Serein"
    let lines = [MacAwake.shared.line, Self.wakeLine].compactMap { $0 }
    status?.button?.toolTip = ([tip] + lines).joined(separator: "\n")
  }
  /// What the wake phrase is doing, for the menu bar item; nil while it is off.
  static var wakeLine: String? {
    switch WakeListener.shared.state {
    case .off: return nil
    case .listening: return "Listening for “Serein”"
    case .hearing: return "Listening to you"
    case .paused(let why), .unavailable(let why): return "“Serein”: " + why
    }
  }
  // Serein's petal mark as a template image, so the menu bar tints it for light and dark.
  private static let trayMarks: [Bool: NSImage] = Dictionary(uniqueKeysWithValues: [false, true].map { working in
    let name = working ? "serein-mark-working" : "serein-mark"
    let image = Bundle.assets.url(forResource: name, withExtension: "svg", subdirectory: "Icons")
      .flatMap(NSImage.init(contentsOf:))
      ?? NSImage(systemSymbolName: working ? "sparkles" : "sparkle", accessibilityDescription: nil)!
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    image.accessibilityDescription = "Serein"
    return (working, image)
  })
  /// The mark with a microphone after it: the wake phrase is listening.
  private static let listeningMarks: [Bool: NSImage] = trayMarks.mapValues { mark in
    let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    let micSize = mic?.size ?? .zero
    let image = NSImage(size: NSSize(width: 18 + 3 + ceil(micSize.width), height: 18), flipped: false) { _ in
      mark.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
      mic?.draw(in: NSRect(x: 21, y: (18 - micSize.height) / 2, width: micSize.width, height: micSize.height))
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Serein, listening for its name"
    return image
  }
  private static func trayMark(working: Bool, listening: Bool = false) -> NSImage {
    (listening ? listeningMarks : trayMarks)[working]!
  }
  @objc private func statusClicked() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      let menu = NSMenu()
      // Settings › General › Keep the Mac awake while tasks run, while it holds the Mac awake.
      if let line = MacAwake.shared.line {
        menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
      }
      // Settings › Voice › Say “Serein” to ask, while it is on: what it does now, and its off switch.
      if let line = Self.wakeLine {
        menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Stop Listening for “Serein”", action: #selector(wakeOffFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
      }
      if RelayOrchestrator.enabled {
        menu.addItem(withTitle: "Ask Serein  \(summonLabel)", action: #selector(showFromMenu), keyEquivalent: "").target = self
        menu.addItem(
          withTitle: voicePill.pill.latched ? "Stop and Send" : "Talk to Serein", action: #selector(talkFromMenu), keyEquivalent: ""
        ).target = self
      }
      menu.addItem(withTitle: "Show Serein Window", action: #selector(windowFromMenu), keyEquivalent: "").target = self
      menu.addItem(.separator())
      menu.addItem(askBeforeMenuItem())
      menu.addItem(withTitle: "Stop Everything  \(killLabel)", action: #selector(killFromMenu), keyEquivalent: "").target = self
      menu.addItem(.separator())
      menu.addItem(withTitle: "Serein Settings…", action: #selector(settingsFromMenu), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Quit Serein", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
      status?.menu = menu
      status?.button?.performClick(nil)
      status?.menu = nil
    } else if RelayOrchestrator.enabled {
      toggle()
    } else {
      // Without ⌥Space there is no floating bar: a click brings the window.
      openWindow()
    }
  }
  @objc private func showFromMenu() { show() }
  /// Talk to Serein: the pill listens with no key held, and a click on it sends what was said.
  @objc func talkFromMenu() {
    guard !holding else {
      if voicePill.pill.latched { summonReleased() }
      return
    }
    if panel?.isVisible == true { hide() }
    ScreenContextCapture.shared.begin()
    wasOpen = false
    wasKey = false
    micNotice = false
    beginListen(latched: true)
  }
  /// The microphone or speech recognition could not start under the pill: the pill goes back to
  /// rest and the bar says why (it draws `dictation.error`). A talk from the button has no key to
  /// let go, so it ends here.
  private func micFailed() {
    let latched = voicePill.pill.latched
    voicePill.cancel()
    if panel?.isVisible != true { show() }
    if latched { summonReleased() }
  }
  @objc private func windowFromMenu() { openWindow() }
  @objc private func killFromMenu() { killSwitch() }
  @objc private func settingsFromMenu() { openSettings("Relay") }
  @objc private func wakeOffFromMenu() { GateSettings.shared.set(false, forKey: WakeListener.enabledKey) }
  /// “Serein Asks Before ›”: Every Step / Only Risky Steps / Proactive, the current one ticked.
  func askBeforeMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "Serein Asks Before", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Serein Asks Before")
    for level in ApprovalLevel.chatChoices {
      let choice = submenu.addItem(withTitle: level.menuTitle, action: #selector(levelFromMenu(_:)), keyEquivalent: "")
      choice.target = self
      choice.representedObject = level.rawValue
      choice.state = relay.level == level ? .on : .off
    }
    item.submenu = submenu
    return item
  }
  @objc private func levelFromMenu(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let level = ApprovalLevel(rawValue: raw) else { return }
    setLevel(level)
  }

  /// “Serein asks before”. A level that asks less than Every step needs its confirmation every
  /// time it is chosen, as Full access does; Every step is immediate.
  func setLevel(_ level: ApprovalLevel) {
    // Choosing the current option is still an explicit choice. A freer level always waits for
    // its confirmation; cancelling it must not tick the guide or mark the level user-set.
    guard Self.confirms(level) else {
      relay.setLevel(.everyStep)
      return
    }
    let allowAll = level == .proactive
    let alert = NSAlert()
    alert.messageText = allowAll ? ApprovalLevel.allowAllConfirmTitle : ApprovalLevel.confirmTitle
    alert.informativeText = allowAll
      ? ApprovalLevel.allowAllConfirmBody(killLabel: killLabel) : ApprovalLevel.confirmBody(killLabel: killLabel)
    alert.addButton(withTitle: allowAll ? ApprovalLevel.proactive.composerTitle : ApprovalLevel.confirmButton)
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn { relay.setLevel(level) }
  }
  static func confirms(_ level: ApprovalLevel) -> Bool { level != .everyStep }
  func killSwitch() {
    relay.stopEverything(pause: true)
    ToastCenter.shared.show("Serein stopped everything. Reminders and alerts are paused until you ask Serein something again.")
    TaskNotifications.shared.post(threadID: relay.threadID, title: "Serein stopped", body: "Every task Serein started was stopped.", always: true)
  }

  // MARK: the shortcut: tap to open or hide, hold to talk

  /// How long the shortcut is held before it listens.
  static let holdToTalk: UInt64 = 350_000_000
  /// Fn calls Serein as ⌥Space does, once “Ask from any app” is on. On unless turned off.
  /// The voice pill resting above the Dock between talks (Settings › Ask from any app, or by chat).
  static let pillKey = "serein.relay.talkPill"
  static var pillOn: Bool { UserDefaults.standard.object(forKey: pillKey) as? Bool ?? true }
  static let fnCallKey = "serein.relay.fnCall"
  static var fnCallOn: Bool { UserDefaults.standard.object(forKey: fnCallKey) as? Bool ?? true }
  /// A hold of Fn has already waited `FnCallMachine.holdDelay`, so it listens as soon as ⌥Space would.
  private static let fnListenAfter = holdToTalk - UInt64(FnCallMachine.holdDelay * 1_000_000_000)
  private func fnCalled(_ event: FnCallEvent) {
    switch event {
    case .tap:
      summonPressed()
      summonReleased()
    case .holdBegan: summonPressed(listenAfter: Self.fnListenAfter)
    case .holdEnded: summonReleased()
    case .cancelled: summonCancelled()
    }
  }
  func summonPressed(listenAfter: UInt64 = holdToTalk) {
    // Before the bar shows, while the person's own app is still in front: what they select or
    // point at from now until they let go may ride with what they say (off unless they turned
    // it on; a tap keeps nothing).
    ScreenContextCapture.shared.begin()
    pressedAt = Date()
    // The in-window bar is another place: ⌥Space opens the bar over every app instead.
    wasOpen = panel?.isVisible == true && !inWindow
    wasKey = wasOpen && barHasKeyboard
    micNotice = false
    // The real event, for anything learning the shortcut (onboarding advances on this).
    NotificationCenter.default.post(name: Notification.Name("SereinSummoned"), object: nil)
    // No bar yet: a tap opens it at the release, and a hold shows the pill instead (`beginListen`).
    holdTimer?.cancel()
    holdTimer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: listenAfter)
      // A listen the menu bar button started is already on: this press only ends it.
      guard !Task.isCancelled, let self, self.pressedAt != nil, !self.holding else { return }
      self.beginListen()
    }
  }
  /// The press turned out to be part of another shortcut: what was heard is dropped, nothing is
  /// sent, and a bar this press opened goes away.
  private func summonCancelled() {
    ScreenContextCapture.shared.cancel()
    holdTimer?.cancel()
    pressedAt = nil
    if holding {
      holding = false
      askingMic = false
      if dictation.recording || dictation.starting { dictation.stop() }
      heard = ""
    }
    voicePill.cancel()
    micNotice = false
    if !wasOpen { hide() }
  }
  /// The call button: pressing ends whatever is being spoken (half-duplex — the mic is never
  /// open while Relay talks, and opens only `CallVoice.echoGuard` after it stopped), then
  /// listens until release.
  func callPressed() {
    stopSpeaking()
    holding = true
    heard = ""
    callHold &+= 1
    let hold = callHold
    holdCard = relay.approvals.first?.id
    micOpenedAt = nil
    let wait = spokeUntil.addingTimeInterval(CallVoice.echoGuard).timeIntervalSinceNow
    guard wait > 0 else { return openCallMic() }
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard let self, self.holding, self.callHold == hold else { return }
      self.openCallMic()
    }
  }
  private func openCallMic() {
    micOpenedAt = Date()
    let hold = callHold
    // Another session left running would make start toggle it off and hand back its words.
    if dictation.recording || dictation.starting { dictation.stop() }
    dictation.start { [weak self] text in
      guard let self, self.callHold == hold else { return }
      self.heardHold = hold
      self.heard = text
    }
  }
  func callReleased() {
    guard holding else { return }
    holding = false
    let opened = micOpenedAt
    let card = holdCard
    micOpenedAt = nil
    holdCard = nil
    let hold = callHold
    releasingHold = hold
    Task {
      // What the hold kept from being spoken: a reply that ended meanwhile, or a card that came.
      defer {
        if releasingHold == hold { releasingHold = nil }
        speakHeld()
      }
      let text = await dictation.finish()
      heard = ""
      // Released while the echo guard held the mic shut, or Serein spoke into the hold: nothing
      // that was heard counts.
      guard let opened, heardHold == hold, utterance == nil,
        opened >= spokeUntil.addingTimeInterval(CallVoice.echoGuard) else { return }
      let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !said.isEmpty else { return }
      // A spoken stop works with a card up, as it does without one.
      if RelayStop.isStop(said) { relay.ask(said); return }
      // A card on screen when the hold began: what was said answers it (or is a reply about it).
      if let card { answerByVoice(said, card: card, heardFrom: opened) } else { relay.ask(said) }
    }
  }
  /// A spoken answer to the call's current card. It must still be the card the hold began on;
  /// the answer goes through the card's own `answer` (RelayOrchestrator.answerByVoice).
  private func answerByVoice(_ said: String, card id: UUID, heardFrom opened: Date) {
    guard callMode, let card = relay.approvals.first, card.id == id else { return }
    // The “yes” must be heard after the read-back was given, inside its window.
    let awaiting = voiceReadBack == id && opened > readBackAt
      && Date().timeIntervalSince(readBackAt) <= CallVoice.readBackWindow
    let enabled = Self.voiceAnswers
    let reply = CallVoice.reply(to: CallVoice.heard(said), awaitingYes: awaiting,
                                allowable: CallVoice.allowable(card.effect, enabled: enabled), enabled: enabled)
    voiceReadBack = nil
    switch reply {
    case .answer(let human):
      let answered = relay.answerByVoice(id, human)
      guard answered else { if human == .yes { speak(CallVoice.needsClick) }; return }
      speak(human == .yes ? CallVoice.allowed : CallVoice.declined)
    case .readBack:
      // No read-back heard, no yes to wait for: a check's muted `speak` says it spoke.
      guard !RunMode.checking, speak(CallVoice.readBack(effect: card.effect ?? .unknown, site: card.site)) else { return }
      voiceReadBack = id
      let at = Date()
      readBackAt = at
      // Silence counts as no: the read-back lapses and the card keeps waiting for a click or voice.
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(CallVoice.readBackWindow * 1_000_000_000))
        guard let self, self.voiceReadBack == id, self.readBackAt == at else { return }
        self.voiceReadBack = nil
      }
    case .say(let line):
      speak(line)
    case .ignore: break
    }
  }
  /// In a call, once no microphone is open and nothing is being spoken: a reply that was refused
  /// meanwhile, else a card whose question was not read. Held speech is cleared only once spoken.
  private func speakHeld() {
    guard callMode, !holding, releasingHold == nil, !dictation.recording, utterance == nil else { return }
    if let reply = heldReply {
      if speak(reply) { heldReply = nil }
    } else if let first = relay.approvals.first?.id, first != announcedCard {
      announceCard(first)
    }
  }
  /// In a call with progress speech on, a new card's question is read aloud, with how it can be answered.
  private func announceCard(_ id: UUID?) {
    guard callMode, Self.speakProgress, let id, let card = relay.approvals.first(where: { $0.id == id }) else { return }
    if speak(CallVoice.question(title: card.title, allowable: CallVoice.allowable(card.effect, enabled: Self.voiceAnswers))) {
      announcedCard = id
    }
  }
  /// In a call, the newest step of Serein's run and the tasks it started, as a short line: at
  /// most one every `CallVoice.progressGap`, never over a card, the user's hold or other speech.
  private func sayProgress() {
    guard callMode, Self.speakProgress else { return }
    let board = relay.browser.agentTabs.runs.values.filter { info in
      !info.ended && info.threadID.map { $0 == relay.threadID || relay.isChild($0) } == true
    }.compactMap(\.steps.last)
    let runs = ([relay.run].compactMap { $0 } + relay.childRuns.filter(\.isActive)).compactMap(\.steps.last)
    guard let step = (board + runs).max(by: { $0.time < $1.time }), step.id != lastProgressStep else { return }
    lastProgressStep = step.id
    let now = Date()
    guard relay.approvals.isEmpty, !holding, !dictation.recording, utterance == nil,
      step.failed == nil, now.timeIntervalSince(step.time) < CallVoice.progressGap,
      now.timeIntervalSince(lastProgressAt) >= CallVoice.progressGap,
      let line = CallVoice.progress(step.label)
    else { return }
    lastProgressAt = now
    speak(line)
  }
  /// Speech or the microphone has never been asked. A check can say which, and show no prompt.
  var microphoneNotAsked: () -> Bool = {
    SFSpeechRecognizer.authorizationStatus() == .notDetermined
      || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
  }
  /// Asks macOS for speech and the microphone. A check counts the ask and shows no prompt.
  var requestMicrophoneAccess: () -> Void = {
    SFSpeechRecognizer.requestAuthorization { _ in
      Task { @MainActor in _ = await AVCaptureDevice.requestAccess(for: .audio) }
    }
  }
  /// Opens the microphone for what a hold hears. A check can leave it shut.
  var startDictation: (Dictation, @escaping (String) -> Void) -> Void = { dictation, onText in
    dictation.start(onText: onText)
  }
  private func beginListen(latched: Bool = false) {
    GuideCenter.shared.record(.barHeld)
    HintCenter.shared.recordBarUsed()
    HintCenter.shared.recordInteraction()
    stopSpeaking()
    heard = ""
    // The first time: the bar says macOS will ask, and this hold sends nothing. A key stays down
    // until it comes up. A click has no key-up, so it must not enter `holding`: Talk to Serein
    // would ignore the next click.
    if microphoneNotAsked() {
      micNotice = true
      if !latched {
        holding = true
        askingMic = true
      }
      // The notice is the bar's: the pill has no room for words. show() also leaves the in-window
      // bar, which a pill never does (below).
      if !wasOpen { show() }
      requestMicrophoneAccess()
      if latched {
        holdTimer?.cancel()
        pressedAt = nil
        ScreenContextCapture.shared.cancel()
      }
      return
    }
    holding = true
    // A dictation from the panel's mic hands over to the hold; start alone would end it instead.
    if dictation.recording || dictation.starting { dictation.stop() }
    if !wasOpen {
      // The pill stands in for the bar and never calls show(), which is what used to drop the
      // window ⌘E left behind. A click (Talk to Serein, the pill) comes through here too.
      clearAnchor()
      voicePill.begin(dictation, latched: latched)
    }
    startDictation(dictation) { [weak self] text in self?.heard = text }
  }
  func summonReleased() {
    holdTimer?.cancel()
    pressedAt = nil
    guard holding else {
      ScreenContextCapture.shared.cancel()
      // A tap opens it for writing; a tap on a bar with the keyboard puts it away; a tap on one
      // that opened on its own (an approval) gives it the keyboard. Holding it talks.
      if wasKey { hide() } else if wasOpen { giveKeyboard() } else { show(); startWriting() }
      return
    }
    holding = false
    if askingMic {
      ScreenContextCapture.shared.cancel()
      askingMic = false
      return
    }
    voicePill.release()
    // Spoken words go as typed ones do: the reply grows under the bar (or in Serein's chat when
    // it is in front). They first find their assistant (`VoiceRoute`), since nobody says "@".
    Task { @MainActor in
      // The microphone closes at the release, before anything is waited for (`finish` closes it
      // before its first wait): nothing said while the screen is read joins the message. What was
      // shown is read while the words are finished, with the selection and the pointer where the
      // person left them.
      async let shown = ScreenContextCapture.shared.end()
      let text = await dictation.finish()
      heard = ""
      handOff(text, shown: await shown)
    }
  }
  /// `--ui-voice-pill`: the pill on a voice that rises and falls instead of a microphone. `idle`
  /// is the pill at rest, `listening` grows it and keeps its mark moving, `sent` lets go and its
  /// words take the real hand-off into Serein's chat.
  func previewVoicePill(_ stage: String) async {
    voicePill.rest(true)
    guard stage != "idle" else { return }
    try? await Task.sleep(nanoseconds: 600_000_000)
    voicePill.beginPreview()
    voicePill.micOpened()
    var tick = 0.0
    func speak(_ count: Int) async {
      for _ in 0..<count {
        tick += 1
        voicePill.hear(Float(abs(sin(tick * 0.45)) * (0.3 + 0.65 * abs(sin(tick * 0.09)))))
        try? await Task.sleep(nanoseconds: 33_000_000)
      }
    }
    guard stage == "sent" else {
      Task { while voicePill.pill.phase == .listening { await speak(30) } }
      return
    }
    // As if the person were in another app: the hand-off must bring Serein's chat forward.
    // The preview starts no RelayController wiring (main.swift), so the window is opened as the app does.
    openWindow = { (NSApp.delegate as? AppDelegate)?.showWindow() }
    (NSApp.delegate as? AppDelegate)?.window?.miniaturize(nil)
    await speak(45)
    voicePill.release()
    try? await Task.sleep(nanoseconds: 400_000_000)
    handOff("What is on my calendar this afternoon?", shown: nil)
  }
  /// What a hold or the button heard goes to Serein. With the pill up it decides (`VoicePill.end`),
  /// and Serein's chat comes forward with the message in it.
  func handOff(_ text: String, shown: ScreenContextCapture.Captured?) {
    guard voicePill.pill.shown else { return sendFromBar(text, spoken: true, shown: shown) }
    switch voicePill.end(heard: text) {
    case .send(let words):
      sendFromBar(words, spoken: true, shown: shown, opensChat: true)
    case .drop:
      // Nothing was said: what the hold took goes nowhere.
      sendFromBar("", spoken: true, shown: shown)
    }
  }

  // MARK: panel

  func toggle() {
    if panel?.isVisible == true { hide() } else { show() }
  }
  func show() { show(focus: true) }
  /// The bar over every app. `focus`: it takes the keyboard (⌥Space, the menu bar; only with
  /// ⌥Space on). Without it, it shows for an approval or a question while Serein is out of view,
  /// ⌥Space on or off, and the app the user is in keeps the keyboard.
  func show(focus: Bool) {
    guard !focus || RelayOrchestrator.enabled else { return }
    // Already up (over every app or in a window): it stays where it is.
    let anchor = !focus && panel?.isVisible == true ? anchorWindow : nil
    present(focus: focus, anchor: anchor, isPrivate: inWindowPrivate ?? false)
  }
  /// ⌘E where Serein cannot show beside the page (Compact Mode, no room, a private or other
  /// window): the bar at the window's top centre, with the keyboard. ⌥Space need not be on.
  func showInWindow(_ window: NSWindow, isPrivate: Bool) {
    present(focus: true, anchor: window, isPrivate: isPrivate)
  }
  /// The bar's window, or none when it floats over every app.
  private func setAnchor(_ window: NSWindow?, isPrivate: Bool) {
    anchorWindow = window
    inWindowPrivate = window == nil ? nil : isPrivate
  }
  /// Forgets the window the bar sat in. `hide` does not, so the next in-window bar returns there
  /// until a global hold, or the window closing, calls this.
  private func clearAnchor() {
    setAnchor(nil, isPrivate: false)
  }
  private func present(focus: Bool, anchor: NSWindow?, isPrivate: Bool) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let moving = anchor !== anchorWindow || (anchor == nil) != (inWindowPrivate == nil)
    if !panel.isVisible || moving {
      setAnchor(anchor, isPrivate: isPrivate)
      answerOnly = !focus
      // Reopened within two minutes, the last exchange shows collapsed; after that it goes. While
      // its turn still runs it shows whole, however long ago it went: its progress and Stop.
      if let exchange = barExchange {
        if barTurnThread != nil, relay.working {
          barExchange?.collapsed = false
        } else if Date().timeIntervalSince(exchange.at) > Self.exchangeKept {
          barExchange = nil
        } else {
          barExchange?.collapsed = true
        }
      }
      if let anchor {
        place(panel, under: anchor)
      } else if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
        // Room above the bar for the hologram that stands on it.
        barTop = frame.maxY - frame.height * 0.12 - (Self.hologramOn ? Self.hologramSize(screenHeight: frame.height).height - 8 : 0)
        panel.setFrame(NSRect(x: frame.midX - Self.barSize.width / 2, y: barTop - barHeight,
                              width: Self.barSize.width, height: barHeight), display: false)
      }
    }
    if focus { answerOnly = false }
    panel.orderFrontRegardless()
    if focus {
      panel.makeKey()
      barHasKeyboard = true
    } else if !panel.isKeyWindow {
      barHasKeyboard = false
    }
    panelShown = true
    // The hologram stands on a bar you summoned. One that opened by itself for an answer stays
    // still, without it, until you give it the keyboard: it may wait for hours.
    if anchor == nil && (focus || !answerOnly) { showHologram(over: panel) } else { hideHologram() }
    if focus { NotificationCenter.default.post(name: RelayWindow.focus, object: nil) }
  }
  /// The in-window bar sits under the window's own header row, at its top centre.
  private func place(_ panel: NSPanel, under anchor: NSWindow) {
    barTop = anchor.frame.maxY - 64
    panel.setFrame(NSRect(x: anchor.frame.midX - Self.barSize.width / 2, y: barTop - barHeight,
                          width: Self.barSize.width, height: barHeight), display: false)
  }
  private func watchAnchor() {
    anchorWatch = []
    guard let anchor = anchorWindow else { return }
    let center = NotificationCenter.default
    anchorWatch = [
      center.publisher(for: NSWindow.didMoveNotification, object: anchor)
        .merge(with: center.publisher(for: NSWindow.didResizeNotification, object: anchor))
        .sink { [weak self, weak anchor] _ in
          guard let self, let anchor, let panel = self.panel, panel.isVisible, self.anchorWindow === anchor else { return }
          self.place(panel, under: anchor)
        },
      // What waits in it is not put off: it is placed again (the bar over every app, or the
      // slim line) as the window goes.
      center.publisher(for: NSWindow.willCloseNotification, object: anchor)
        .merge(with: center.publisher(for: NSWindow.didMiniaturizeNotification, object: anchor))
        .sink { [weak self, weak anchor] _ in
          guard let self, self.anchorWindow === anchor, self.panel?.isVisible == true else { return }
          self.hide(deferring: false)
          self.clearAnchor()
        },
    ]
  }
  /// The bar previews draw the bar in the window as if it were up (in memory only):
  /// `--ui-serein-bar-reply` on the exchange just answered (`collapsed`: reopened, on one line;
  /// `window` or `private`: the in-window bar), `--ui-serein-bar-held` on a message held for an
  /// AI app, `--ui-serein-bar-mic` on the first hold's microphone notice, and
  /// `--ui-serein-bar-approval` opened on its own for the card.
  func previewBar() {
    guard SereinBarPreviewLayer.active else { return }
    let arguments = CommandLine.arguments
    panelShown = true
    if arguments.contains("--ui-serein-bar-reply") {
      let mode = arguments.drop(while: { $0 != "--ui-serein-bar-reply" }).dropFirst().first
      let prompt = RelayOrchestrator.previewBarPrompt
      // Every message of yours but the one the bar asked was there before it.
      let yours = relay.transcript.filter { $0.role == "you" }
      let asked = yours.last { $0.text == prompt }?.id
      barExchange = BarExchange(prompt: prompt, at: Date(), before: Set(yours.map(\.id).filter { $0 != asked }),
                                collapsed: mode == "collapsed")
      if mode == "window" || mode == "private" { inWindowPrivate = mode == "private" }
    } else if arguments.contains("--ui-serein-bar-held") {
      barExchange = BarExchange(prompt: RelayOrchestrator.previewHeldPrompt, at: Date())
    } else if arguments.contains("--ui-serein-bar-mic") {
      micNotice = true
    } else {
      answerOnly = true
    }
  }
  /// A tap on a bar that opened on its own: it takes the keyboard.
  func giveKeyboard() {
    guard let panel, panel.isVisible else { return startWriting() }
    panel.makeKey()
    barHasKeyboard = true
    answerOnly = false
    if anchorWindow == nil { showHologram(over: panel) }
    startWriting()
  }
  /// The reply card grew or shrank: the bar's top edge stays put and the card grows down.
  func fitBar(_ height: CGFloat) {
    let height = max(Self.barSize.height, ceil(height))
    barHeight = height
    guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
    let top = panel.isVisible ? panel.frame.maxY : barTop
    panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height), display: true)
    if let hologramWindow, hologramWindow.parent === panel { placeHologram(hologramWindow, over: panel) }
  }
  /// Later, on a card in the bar: the bar goes, and the card waits in Serein's chat (the row says
  /// Needs you, and the notification stays in Notification Center).
  func later() {
    relay.deferWaiting()
    hide()
  }
  /// Open in Serein (or Show in chat): Serein's window comes forward, with Serein where it lives.
  func openInSerein() {
    // You brought the cards into the chat, not put them off: should they lose their place again
    // (the window closes or goes to the Dock), they are placed and announced anew.
    hide(deferring: false, review: false)
    // The chat is coming forward with the reply in it.
    barTurnNotifies = false
    openWindow()
    SereinRouter.openFromBar()
  }
  /// Serein's window comes forward with its chat showing, as Open in Serein does.
  private func chatForward() {
    openWindow()
    SereinRouter.openFromBar()
  }
  /// A card's place may have gone (the column closed, the bar hid, the window closed): after the
  /// view has settled, cards no screen shows move to an alert.
  static func reviewCardsSoon(_ relay: RelayOrchestrator?) {
    guard let relay, !relay.approvals.isEmpty || !relay.questionForms.isEmpty || relay.consentWaiting else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak relay] in relay?.reviewHiddenCards() }
  }
  /// Puts the bar away. What waits in it (an approval, a question) waits in Serein's chat, put off
  /// (Esc, a tap of ⌥Space, Later). `deferring` false: brought into the chat instead (Open in
  /// Serein, a send with the chat in front), so it is placed again if it loses its place.
  /// `review` false: nothing is placed again now (the window is coming forward to show it).
  func hide(deferring: Bool = true, review: Bool = true) {
    defer { if review { Self.reviewCardsSoon(relay) } }
    barStepAside?.cancel()
    // Put away by a click elsewhere, Esc or the wait: the turn runs on and says when it ended.
    if barTurnThread != nil, relay.working, panel?.isVisible == true { barTurnNotifies = true }
    // A request after “Serein” goes with the bar, unsent.
    if wakeWords != nil {
      wakeOpenedBar = false
      WakeListener.shared.cancel()
    }
    if deferring, panel?.isVisible == true { relay.deferWaiting() }
    hideHologram()
    panel?.orderOut(nil)
    panelShown = false
    barHasKeyboard = false
    answerOnly = false
    micNotice = false
  }
  /// The hologram stands on the bar now (checks).
  var hologramVisible: Bool { hologramWindow?.isVisible == true }
  private func hideHologram() {
    if let hologramWindow {
      hologramWindow.parent?.removeChildWindow(hologramWindow)
      hologramWindow.orderOut(nil)
    }
  }
  static var hologramOn: Bool {
    UserDefaults.standard.object(forKey: RelayOrchestrator.hologramKey) as? Bool ?? RelayOrchestrator.hologramDefault
  }
  static func panelHeight(hologram: Bool) -> CGFloat { hologram ? 560 : 480 }
  private func makePanel() -> RelayWindow {
    let panel = RelayWindow(
      contentRect: NSRect(origin: .zero, size: Self.barSize),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.onEscape = { [weak self] in self?.hide() }
    // A click into the field of a bar that opened by itself: you are writing in it now, so it
    // keeps the keyboard's rules (a tap of ⌥Space puts it away, answering does not) and its
    // hologram.
    panel.onBecomeKey = { [weak self] in
      guard let self, let panel = self.panel, panel.isVisible, panel.isKeyWindow else { return }
      self.barHasKeyboard = true
      guard self.answerOnly else { return }
      self.answerOnly = false
      if self.anchorWindow == nil { self.showHologram(over: panel) }
    }
    // Like Spotlight: clicking elsewhere puts it away, unless an approval, a question or a
    // recording waits (then the bar stays, and a tap of ⌥Space gives it the keyboard again).
    panel.onResign = { [weak self] in
      guard let self else { return }
      self.barHasKeyboard = false
      guard self.relay.approvals.isEmpty, !self.relay.consentWaiting, self.relay.questionForms.isEmpty,
        !MacApproval.isOpen, !self.dictation.recording, !self.holding, self.wakeWords == nil
      else { return }
      self.hide()
    }
    let view = SereinBarContent(relay: relay, controller: self, dictation: dictation)
    let host = NSHostingView(rootView: view.font(UIStyle.font(13)))
    host.sizingOptions = []
    host.frame = panel.contentLayoutRect
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    return panel
  }

  /// Shows the hologram on nothing, standing on the panel's top edge; it moves with the panel.
  /// The window is kept once made, so the hologram is already running the next time.
  private func showHologram(over panel: NSPanel) {
    guard Self.hologramOn else { return }
    let window = hologramWindow ?? makeHologramWindow()
    hologramWindow = window
    placeHologram(window, over: panel)
    if window.parent !== panel {
      window.parent?.removeChildWindow(window)
      panel.addChildWindow(window, ordered: .above)
    }
    window.orderFront(nil)
  }
  /// The hologram stands on the bar's top edge, whatever the reply card under it does.
  private func placeHologram(_ window: NSPanel, over panel: NSPanel) {
    let size: NSSize = Self.hologramSize(screenHeight: (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 0)
    window.setFrame(
      NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - 8, width: size.width, height: size.height),
      display: false)
  }
  // MARK: Say “Serein”

  /// WakeListener heard the name, or more words after it: the bar shows them as they come.
  func wakeHeard(_ words: String) {
    if wakeWords == nil {
      wakeOpenedBar = panel?.isVisible != true
      micNotice = false
      show()
    }
    wakeWords = words
  }
  /// The request after the name ended: `words` go to Serein as if typed in the bar (empty: nothing
  /// was said, or it was cancelled or paused). `dismiss`: a bar the wake phrase opened goes again
  /// when nothing was sent.
  func wakeFinished(_ words: String, dismiss: Bool) {
    guard wakeWords != nil else { return }
    wakeWords = nil
    let opened = wakeOpenedBar
    wakeOpenedBar = false
    if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sendFromBar(words)
    } else if dismiss, opened, panel?.isVisible == true {
      hide()
    }
  }
  /// Cancel on the bar while it listens after “Serein”: nothing is sent.
  func cancelWake() { WakeListener.shared.cancel() }

  /// The field takes the keyboard.
  func startWriting() {
    NotificationCenter.default.post(name: RelayWindow.focus, object: nil)
  }
  /// Sends what was written to Serein. The reply grows under the bar, in place: Serein's window
  /// is never brought forward. When Serein's chat already shows in the window in front, the bar
  /// goes and the reply streams there.
  func sendWriting() {
    let text = summonDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    // A waiting question is answered on its card under the bar (`SereinReplyCard`), so the bar's words are always a new message.
    switch relay.messagePlan(text, hasAttachments: false, answersQuestion: false) {
    case .fill(let words):
      summonDraft = words
    case .refuse(let why):
      barRefusal = why
      ChatAnnouncement.post(why, priority: .high)
    case .answer(let words), .send(let words):
      summonDraft = ""
      sendFromBar(words)
    }
  }
  /// A message from the bar, typed or spoken (⌥Space held, then let go): it goes to Serein and
  /// its reply card grows under the bar; with Serein's chat in front, the bar goes and the reply
  /// streams there.
  /// An in-window address-field request can carry its page explicitly. Other bar entry points
  /// supply none, so the global ⌥Space bar never inherits a tab from the main window.
  /// "Send what you say to the assistant it fits" (Settings › Ask from any app): on unless off.
  static var voiceRoutingOn: Bool { UserDefaults.standard.object(forKey: VoiceRoute.settingKey) as? Bool ?? true }

  /// `spoken`: the words came from holding the shortcut, so they are routed by what they say.
  /// `shown`: what the person selected or pointed at during that hold (`ScreenContextCapture`),
  /// which rides with the words as attachments. `opensChat`: the words came from the voice pill, so
  /// Serein's chat comes forward showing them, wherever the person was; a stop never brings it.
  func sendFromBar(
    _ words: String, page: SereinPage? = nil, spoken: Bool = false, shown: ScreenContextCapture.Captured? = nil,
    opensChat: Bool = false
  ) {
    var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      // Nothing was heard: what the hold took goes nowhere.
      if let shown { ComposerContext.discard(shown.filePaths, keeping: []) }
      return
    }
    // Spoken words and the address field's never pass through the draft, which clears it.
    barRefusal = nil
    var shown = shown
    let showing = shown.map { !$0.context.isEmpty || $0.context.missedPicture } ?? false
    // A task the assistant in front started counts: “cancel that” said while one works is a stop too.
    let running = relay.working || relay.liveTasks > 0
    // The bar in a window (⌘E) belongs to the chat it sits over: its words stay there.
    let route = spoken && Self.voiceRoutingOn && !inWindow
      ? VoiceRoute.plan(
        text, team: relay.team, chatInFront: chatInFront(), showing: showing, running: running,
        busy: relay.workingElsewhere)
      : nil
    // A stop is the whole message: with what the hold took, `ask` would send it instead of stopping.
    // Routed words are judged by the assistant they reach (`VoiceRoute.stop`).
    let stop = route?.stop ?? RelayStop.stops(text, overShown: showing, running: running)
    // The pill brings the chat forward. A stop never does, wherever the person was.
    let bringChat = opensChat && !stop
    if stop, let taken = shown {
      ComposerContext.discard(taken.filePaths, keeping: [])
      shown = nil
    }
    let attachments: [SereinAttachment] = shown.map { $0.context.isEmpty ? [] : $0.attachments } ?? []
    // The pointer was on a picture Serein could not read: the words wait in the chat's message
    // box with what else was shown, and the person drags the picture in beside them. They wait
    // as the mention their route made, so sending them later still reaches who they were for.
    if let shown, shown.context.missedPicture {
      for item in attachments { SereinSurface.main.attach(item) }
      SereinRouter.show(draft: route?.message ?? text)
      ToastCenter.shared.show(ScreenContext.dragPictureNotice)
      hide(deferring: false)
      return
    }
    let trail = inWindow ? nil : ScreenTrailWatch.shared.attachment()
    var message = text
    var sentTo: String?
    if var route {
      if route.message != route.words, !relay.bringMentioned(route.message) {
        // The assistant in front is still working: `ask` says so and keeps the words in the
        // composer, as for a typed mention. Nothing is sent to the wrong assistant.
        guard stop else {
          relay.ask(route.message, attachments: attachments, page: page, inWindow: inWindow)
          if bringChat { chatForward() }
          return
        }
        // A stop never waits: it goes on without the name, as a plain stop from the chat in front.
        route.message = route.words
        route.to = nil
      }
      // The route's words, not what was heard: a stop said to the one in front goes without the name.
      message = route.message
      text = route.words
      sentTo = route.to
      if let to = route.to { relay.note("Spoken words went to \(to)", .auto) }
      // Only a name was said: that chat is open now, and there is nothing to send.
      guard !text.isEmpty else {
        relay.ask(message, attachments: attachments, page: page, inWindow: inWindow)
        return
      }
    }
    // Taken before the message goes: the turn answering it is the first after these.
    let before = Set(relay.transcript.filter { $0.role == "you" }.map(\.id))
    if !inWindow {
      GuideCenter.shared.record(.barSent)
      HintCenter.shared.recordBarUsed()
      HintCenter.shared.recordInteraction()
    }
    // A stop, a command, held or refused words start no turn, so they offer nothing.
    if relay.ask(message, attachments: attachments, trail: trail, page: page, inWindow: inWindow), !inWindow {
      relay.offerFollowIfUseful()
    }
    barStepAside?.cancel()
    barTurnThread = nil
    barTurnNotifies = false
    if !inWindow, opensChat || chatInFront() {
      barExchange = nil
      // The chat in front shows what waits, so nothing counts as put off.
      hide(deferring: false)
      if bringChat { chatForward() }
      return
    }
    barExchange = BarExchange(prompt: text, at: Date(), to: sentTo, before: before)
    answerOnly = false
    // The in-window bar is in the chat's own window; a held message has no turn to wait for.
    if !inWindow, relay.working {
      barTurnThread = relay.threadID
      watchBarTurn()
    }
  }
  /// Every `BarWork.patience` seconds while the bar's turn runs: the bar goes once no words are
  /// arriving, and the work runs on behind it. A quick answer ends this with the bar still up.
  private func watchBarTurn() {
    barStepAside = Task { [weak self] in
      var words = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(BarWork.patience))
        guard !Task.isCancelled, let self, self.panel?.isVisible == true, let exchange = self.barExchange else { return }
        let relay = self.relay
        guard relay.working else { return }
        let now = SereinBarReply.replies(relay.run?.transcript ?? relay.transcript, exchange: exchange)
          .reduce(0) { $0 + $1.text.count }
        let waits = !relay.approvals.isEmpty || relay.consentWaiting || !relay.questionForms.isEmpty
          || !relay.dueReminders.isEmpty || !relay.missedRuns.isEmpty || MacApproval.isOpen
        let busy = !self.summonDraft.isEmpty || self.holding || self.dictation.recording || self.wakeWords != nil || self.callMode
        if BarWork.stepsAside(
          wordsBefore: words, wordsNow: now, working: true, waitsOnPerson: waits, personBusy: busy,
          canNotify: TaskNotifications.shared.canReach)
        {
          self.hide()
          return
        }
        words = now
      }
    }
  }
  /// The turn answering the bar ended: one notification when the bar went meanwhile and the reply
  /// isn't on screen. A message queued behind it goes first, and this waits for its turn.
  private func finishBarTurn(_ run: AgentRun) {
    guard let thread = barTurnThread, run.spec.relay, run.spec.threadID == thread else { return }
    if relay.threadID == thread, relay.working { return }
    let notifies = barTurnNotifies
    barTurnThread = nil
    barTurnNotifies = false
    guard notifies, panel?.isVisible != true, !(NSApp.isActive && Self.chatOnScreen) else { return }
    let ending: BarWork.Ending
    switch run.record.outcome {
    case .stopped: ending = .stopped
    case .stuck: ending = .failed
    default: ending = run.usageLimit != nil || run.signedOut ? .failed : .finished
    }
    let reply = barExchange.flatMap { SereinBarReply.replies(run.transcript, exchange: $0).last?.text }
      .flatMap { AgentHub.firstSentence(ChatBubbles.plain(ChatBubbles.withoutPartialTag($0))) }
    let owner: String = relay.assistantOwning(thread: thread) ?? relay.team.activeID
    guard let notice = BarWork.notice(
      name: relay.profileName(owner), ending: ending, reply: reply, readPersonal: relay.agent.readsPersonal(thread: thread))
    else { return }
    TaskNotifications.shared.post(threadID: thread, title: notice.title, body: notice.body, always: true, result: true)
  }
  /// A finish notification's Show result: the reply where the person is, without bringing
  /// Serein's window forward. The dock's chat when the dock is on, else the bar with the reply
  /// it still holds; false when neither can show it, and the chat opens instead.
  func showResult(thread: String) -> Bool {
    if AssistantDock.enabled, AssistantDock.shared.openChat(forThread: thread) { return true }
    guard RelayOrchestrator.enabled, let exchange = barExchange, relay.threadID == thread else { return false }
    // A bar that was put away lets go of an exchange older than `exchangeKept` as it reopens
    // (`present`): it has no reply to show then, and the chat opens instead.
    let running = barTurnThread != nil && relay.working
    if panel?.isVisible != true, !running, Date().timeIntervalSince(exchange.at) > Self.exchangeKept { return false }
    barExchange?.collapsed = false
    show(focus: false)
    return true
  }
  private func makeHologramWindow() -> NSPanel {
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.hologramWidth, height: Self.hologramHeight),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hidesOnDeactivate = false
    // Only light: clicks go to whatever is behind it.
    window.ignoresMouseEvents = true
    let host = NSHostingView(rootView: RelayFloatingHologram(relay: relay, controller: self, dictation: dictation))
    host.sizingOptions = []
    host.frame = NSRect(x: 0, y: 0, width: Self.hologramWidth, height: Self.hologramHeight)
    host.autoresizingMask = [.width, .height]
    window.contentView = host
    return window
  }

  // MARK: voice

  private func ended(_ run: AgentRun) {
    finishBarTurn(run)
    // A reply Serein gave while its chat was nowhere on screen: the row's accent dot.
    if run.spec.threadID == relay.threadID, run.record.outcome == .done, !Self.chatOnScreen {
      SereinSurface.main.unread = true
    }
    // A reply the person watched arrive is read.
    if run.spec.threadID == relay.threadID, Self.chatOnScreen { relay.chatRead(silent: true) }
    // A task finished out of sight while the window is in front: a toast says so.
    SereinFinishToast.ended(run, relay: relay)
    // The hologram bursts when delegated work is done and fractures when a run fails.
    if relay.isChild(run.spec.threadID) || run.spec.threadID == relay.threadID {
      if run.record.outcome == .stuck { avatarEvents.send(.failed) }
      else if run.record.outcome == .done, relay.isChild(run.spec.threadID) { avatarEvents.send(.done) }
    }
    guard run.spec.threadID == relay.threadID, callMode || UserDefaults.standard.bool(forKey: Self.speakKey),
      run.record.outcome != .stopped,
      let reply = run.transcript.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text
    else { return }
    let words: String = ChatBubbles.plain(reply)
    if speak(words) { heldReply = nil } else if callMode { heldReply = words }
  }
  /// False when nothing was spoken because a microphone is open.
  @discardableResult func speak(_ text: String) -> Bool {

    // Half-duplex: nothing is spoken while a microphone is open (a hold, listening, or a request
    // after “Serein”).
    guard !holding, !dictation.recording, wakeWords == nil else { return false }
    // A check reads nothing aloud, although it sees the person's read-aloud setting.
    guard !RunMode.checking else { return true }
    guard let next = SpeechDelivery.callUtterance(text) else { return false }
    voice.stopSpeaking(at: .immediate)
    utterance = next
    cloudVoice.stop()
    // The wake phrase's microphone closes before the first word.
    WakeListener.shared.refresh()
    let provider = VoiceProvider.chosen
    guard provider != .mac else { voice.speak(next); return true }
    // The utterance stays the half-duplex token while the cloud voice plays it.
    cloudVoice.speak(next.speechString, provider: provider,
      started: { [weak self] in self?.speaking = true },
      level: { [weak self] in self?.avatarEvents.send(.word($0)) },
      finished: { [weak self] in self?.spoke(next) },
      failed: { [weak self] error in
        guard let self, self.utterance === next else { return }
        self.voice.speak(next)
        ToastCenter.shared.show(error.localizedDescription, id: "cloud-voice")
      })
    return true
  }
  func stopSpeaking() {
    voice.stopSpeaking(at: .immediate)
    if utterance != nil {
      utterance = nil
      spokeUntil = Date()
      WakeListener.shared.refresh()
    }
    // After the token is cleared, so the player's end does not start a held reply.
    cloudVoice.stop()
  }
  /// The current utterance ended on its own: the echo guard counts from now.
  private func spoke(_ ended: AVSpeechUtterance) {
    // The wake phrase listens again `CallVoice.echoGuard` after the last word.
    defer { WakeListener.shared.refresh() }
    speaking = false
    guard utterance === ended else { return }
    utterance = nil
    spokeUntil = Date()
    speakHeld()
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    Task { @MainActor in self.speaking = true }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.spoke(utterance) }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.spoke(utterance) }
  }
  /// Each word makes the hologram's voice meter leap; longer words leap higher.
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance
  ) {
    let strength = min(1, 0.35 + Double(range.length) / 10)
    Task { @MainActor in self.avatarEvents.send(.word(strength)) }
  }
}

/// `--ui-relay-panel` previews (release builds too): the panel over the window, as it floats over
/// another app.
struct RelayPreviewLayer: View {
  let controller: RelayController
  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.18).allowsHitTesting(false)
      RelayPanelView(relay: controller.relay, agent: controller.relay.agent, controller: controller)
        .font(UIStyle.font(13)).shadow(color: .black.opacity(0.35), radius: 30, y: 12).padding(.top, 90)
    }
  }
}

/// The panel takes typing without activating Serein; Esc hides it.
final class RelayWindow: NSPanel {
  static let focus = Notification.Name("SereinRelayFocus")
  var onEscape: (() -> Void)?
  var onResign: (() -> Void)?
  var onBecomeKey: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func becomeKey() {
    super.becomeKey()
    let action = onBecomeKey
    DispatchQueue.main.async { action?() }
  }
  override func resignKey() {
    super.resignKey()
    let action = onResign
    DispatchQueue.main.async { action?() }
  }
  override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Keeps Serein's transcript on its newest line: a card, question, connect card, Stop line, due
/// reminder or missed run scrolls to the end, and the chat opens there. A new reply word does
/// only while the chat follows the reply (`following`): a reader who scrolled up is left where
/// they are, with a button over the chat's foot that glides back. Each send of the person's
/// re-attaches and glides to the end once. Its own view, so the chain of onChange modifiers is
/// type-checked apart from the panel's long body.
private struct RelayScrollToEnd: ViewModifier {
  @ObservedObject var relay: RelayOrchestrator
  let proxy: ScrollViewProxy
  /// The chat follows the reply to its end (`ChatFollowReading`).
  @Binding var following: Bool
  /// Counts the person's sends.
  var sent = 0
  var reduce = false
  /// The scroll view's height: a card in the dock under it shrinks it, and the end stays in sight.
  var viewport: CGFloat = 0
  func body(content: Content) -> some View {
    let lastText: String? = relay.transcript.last?.text
    let chat: String = relay.threadID
    let approvals: Int = relay.approvals.count
    let questions: Int = relay.questionForms.count
    let consent: Bool = relay.consentWaiting
    let noCards: Bool = relay.connectCards == nil
    let noStop: Bool = relay.stopNotice == nil
    let due: Int = relay.dueReminders.count
    let missed: Int = relay.missedRuns.count
    return content
      .onChange(of: lastText) { if following { toEnd() } }
      .onChange(of: approvals) { toEnd() }
      .onChange(of: questions) { toEnd() }
      .onChange(of: consent) { if consent { toEnd() } }
      .onChange(of: noCards) { toEnd() }
      // A Stop's line (or a bare “stop”, which adds no transcript text) and a reminder's card
      // land at the bottom too; and the chat opens on its newest message.
      .onChange(of: noStop) { toEnd() }
      .onChange(of: due) { toEnd() }
      .onChange(of: missed) { toEnd() }
      .onChange(of: viewport) { if following { toEnd() } }
      .onChange(of: sent) { glide() }
      // Another chat opens at its end, whatever the reader did in the last one.
      .onChange(of: chat) {
        following = true
        DispatchQueue.main.async { toEnd() }
      }
      .onAppear { DispatchQueue.main.async { toEnd() } }
      .overlay(alignment: .bottom) { JumpToLatest(shown: !following, reduce: reduce, action: glide).padding(.bottom, 10) }
  }
  private func toEnd() { proxy.scrollTo("end", anchor: .bottom) }
  /// Back to the end in one glide, and following again.
  private func glide() {
    following = true
    withAnimation(reduce ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
  }
}

/// Over the chat's foot while the reader is away from the end: one click glides to the newest
/// words. It fades in over 0.3 s and out over 0.18 s, and nothing moves.
private struct JumpToLatest: View {
  let shown: Bool
  let reduce: Bool
  let action: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: action) {
      InterfaceIcon(systemName: "arrow.down", size: 12).foregroundStyle(p.ink)
        .frame(width: 30, height: 30)
        .background(p.card, in: Circle())
        .overlay(Circle().strokeBorder(p.line, lineWidth: 1))
        .contentShape(Circle())
    }
    .buttonStyle(AssistantPressStyle())
    .help("Jump to latest").accessibilityLabel("Jump to latest")
    // Hidden, it takes no click, no key and no VoiceOver stop.
    .opacity(shown ? 1 : 0).disabled(!shown).accessibilityHidden(!shown)
    .animation(reduce ? .linear(duration: Motion.reducedDuration) : shown ? .easeOut(duration: 0.3) : .easeIn(duration: 0.18),
               value: shown)
  }
}

/// The chat scroll view's coordinate space, which `ChatFollowReading` measures in.
private let sereinChatSpace = "SereinChatScroll"
/// The chat's scroll view: it opens at its foot and keeps it as the reply grows; its height and
/// coordinate space feed `ChatFollowReading`. Its content is at least as tall as the view, top
/// first, so a short chat still starts at the top.
private struct ChatFollowsEnd: ViewModifier {
  @Binding var viewport: CGFloat
  func body(content: Content) -> some View {
    content
      .defaultScrollAnchor(.bottom)
      .coordinateSpace(name: sereinChatSpace)
      .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { viewport = $0 }
  }
}

/// On the chat's column: where it sits in the scroll view at each scroll step settles whether
/// the chat follows the reply (`TurnActivity.follows`: a scroll up of more than 24 points
/// detaches, coming back within 150 points of the end re-attaches). Only a change of that answer
/// writes view state, not every scroll step; the last reading is kept by reference.
private struct ChatFollowReading: ViewModifier {
  let viewport: CGFloat
  @Binding var following: Bool
  @State private var last = ChatScrollMark()
  func body(content: Content) -> some View {
    content.onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(sereinChatSpace))
    } action: { frame in
      // The column's top moves only when the reader (or a scroll to the end) does: up is negative.
      let moved: CGFloat = last.top.map { $0 - frame.minY } ?? 0
      last.top = frame.minY
      guard viewport > 0 else { return }
      let next: Bool = TurnActivity.follows(following, gap: frame.maxY - viewport, moved: moved)
      if next != following { following = next }
    }
  }
}
private final class ChatScrollMark { var top: CGFloat? }

struct RelayPanelView: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  let controller: RelayController
  @ObservedObject private var appearance = AppearanceController.shared
  @ObservedObject private var dictation: Dictation
  @ObservedObject private var voiceInput: RelayController
  /// The draft lives in the window's Serein surface, so full and beside share it.
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var placement = SereinSurface.main.placement
  @ObservedObject private var network = NetworkMonitor.shared
  /// The status reads the run ledger (a task waiting on you), which loads after launch.
  @ObservedObject private var tray = SereinTray.shared
  /// The tab the next message carries (in the window only; never in the ⌥Space bar).
  @ObservedObject private var pageChip = SereinPageChip.shared
  /// The @ picker and the To chip (in the window only).
  @ObservedObject private var mentions = AssistantMentions.shared
  @ObservedObject private var chatSetup = SereinChatSetup.shared
  @ObservedObject private var connection = SereinConnect.shared
  /// The newest waiting card's primary button, for ⌘Return in an empty bar.
  @ObservedObject private var cardKeys = ChatCardKeys.shared
  @ObservedObject private var browser: BrowserModel
  @State private var showActivity = false
  /// + › Teach a Skill…: the skill sheet with an empty draft.
  @State private var teachingSkill = false
  /// ⇧⌘L: the Library view, over the chat.
  @State private var showingLibrary = false
  /// The chat follows the reply to its end: new reply words keep it there. A scroll up of more
  /// than 24 points stops that until the person scrolls back within 150 points of the end, uses
  /// the button over the chat's foot, or sends (`ChatFollowReading`).
  @State private var following = true
  /// The person's sends, counted: each glides the chat to its end once (`RelayScrollToEnd`).
  @State private var sent = 0
  /// The scroll view's visible height, for `following`.
  @State private var viewport: CGFloat = 0
  @FocusState private var focused: Bool
  /// The approval the brief's Go to card asked the dock for.
  @State private var dockRequest: UUID?
  /// A key caught in the draft (`ComposerGuard`). The key stays only here until the next send.
  @State private var caught: CaughtKey?
  enum CaughtKey {
    /// The note under the box.
    case note(String)
    /// The secure card the note opened.
    case card(String)
  }
  @AppStorage(RelayController.speakKey) private var speak = false
  @AppStorage(RelayOrchestrator.hologramKey) private var hologram = RelayOrchestrator.hologramDefault
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  /// The side panel's height: the hero shows beside only in a column at least 760 points tall.
  @State private var height: CGFloat = 0
  /// Where this chat sits: `.full` in the main body (a centred column, the content card's header
  /// above it), `.side` in the window's right column, `.floating` in the preview panel.
  enum Style { case full, side, floating }
  let style: Style
  /// In the window (full or beside) rather than the floating panel: fills its space, no glass.
  var docked: Bool { style != .floating }
  static let showActivity = Notification.Name("SereinShowActivity")
  init(relay: RelayOrchestrator, agent: AgentModel, controller: RelayController, style: Style = .floating) {
    self.style = style
    self.relay = relay
    self.agent = agent
    browser = relay.browser
    hub = agent.hub
    self.controller = controller
    dictation = controller.dictation
    voiceInput = controller
  }
  private var p: Palette { appearance.palette }

  /// Serein full: the chat in a centred column up to the composer's width.
  private var full: Bool { style == .full }
  /// Serein beside a tab.
  private var side: Bool { style == .side }
  /// The hologram above the chat. Full: the hero while Serein opens the conversation, the
  /// strip while chatting. Beside: the hero over an empty chat only, when no connect card shows
  /// and the column is at least 760 points tall; never a strip while chatting. The floating
  /// panel keeps its own.
  private var showsStage: Bool {
    // The conversation is the whole view in the window: Serein's face is on the sidebar's rail,
    // so neither full nor beside draws a hologram over the chat. The ⌥Space bar keeps its own.
    false
  }
  /// A chat with one assistant, full: its picture and name at the top, as with a contact.
  private var chatTopShowing: Bool { full && SereinChatTop.shows(relay: relay) }
  private var emptyChat: Bool { relay.run == nil && relay.transcript.isEmpty && relay.outgoingHere == nil }
  /// An empty chat with nothing of yours in it: Serein's welcome and the hero. A held
  /// message is yours, so the chat reads as under way.
  private var heroChat: Bool { emptyChat && relay.heldHere.isEmpty }
  /// This chat's task cards, oldest first, each with the message that started its turn (in the
  /// window only).
  private var taskCards: [RelayTaskCardSlot] {
    guard docked else { return [] }
    // A task whose chat was deleted has no card (older state may still list it).
    return relay.state.children.filter { $0.chatID == relay.threadID && SereinTray.shared.exists($0.threadID, agent: agent) }
      .map { RelayTaskCardSlot(after: $0.messageID ?? "", threadID: $0.threadID) }
  }
  /// Who this chat's assistant can hand work to (members of a shared team), in the window only.
  private var handoffTargets: [(id: String, name: String)] {
    guard docked, let active = relay.team.active else { return [] }
    return relay.team.handoffTargets(from: active.id).map { ($0.id, $0.name) }
  }
  /// Ask Writer to Continue: the person-started card with the message's words.
  private var handOff: ((String, String) -> Void)? {
    docked ? { relay.requestHandoff(to: $0, task: $1) } : nil
  }
  /// The team chat's speaker line: the active assistant, while a team is active and it answers for it.
  private var speaker: RelayProfile? {
    guard let group = relay.activeTeam, let active = relay.team.active, relay.responder(of: group) == active.id else { return nil }
    return active
  }
  /// Every assistant's state, for the @ picker's rows.
  private var assistantStates: [String: SereinStatus] {
    Dictionary(uniqueKeysWithValues: relay.team.profiles.map {
      ($0.id, relay.assistantStatus($0.id, hub: hub, online: SereinSurface.online(network.online),
                                    connected: SereinSurface.connected(agent), unread: surface.unread))
    })
  }
  /// The title of a card that waits for the person in this chat: the plan card's step asks first.
  private var askingHere: String? {
    relay.approvals.first { $0.threadID == relay.threadID }?.title
  }
  /// The other assistants that work for this chat now (a hand-off asked here that runs), for
  /// their typing rows.
  private var busyHelpers: [(id: String, profile: RelayProfile?, name: String)] {
    let running = relay.handoffLedger.records.filter { $0.state == .running && $0.askedIn == relay.threadID }
    var seen = Set<String>()
    return running.compactMap { record in
      guard seen.insert(record.to).inserted else { return nil }
      let profile: RelayProfile? = relay.team.profiles.first { $0.id == record.to }
      return (id: record.to, profile: profile, name: relay.profileName(record.to))
    }
  }
  private func taskCard(_ id: String, first: Bool) -> AnyView {
    AnyView(VStack(alignment: .leading, spacing: 12) {
      SereinTaskCard(threadID: id, browser: relay.browser, agent: agent)
      if first { SereinNotifyCard() }
    })
  }

  // MARK: the chat's parts (each its own small view builder, so each type-checks alone)

  /// Full: the content card's header row is Serein's (ReferenceShell). Beside: the same header
  /// in the panel's first row. The floating panel: its own header.
  @ViewBuilder private var panelHeader: some View {
    if side, let controller = SereinSurface.controller {
      SereinFullHeader(relay: relay, agent: agent, controller: controller, style: .side)
        .padding(.leading, 16).padding(.trailing, 10).frame(height: 44)
      Rectangle().fill(p.line).frame(height: 1)
    } else if !full {
      header
      Rectangle().fill(p.line).frame(height: 1)
    }
  }
  /// The scrolling column: the empty chat's top, who the chat is with, the conversation, the
  /// setup cards, what waits under it, the cards that wait for the person, and the end marker the
  /// scroll follows. Spaced by turn: everything in it sits close, and `ChatTurns` puts the room
  /// above each later turn. What follows the conversation belongs to its newest turn.
  private func chatColumn(_ proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
      emptyTop
      contactHeader
      conversation(chatShared(proxy))
      setupCards
      underConversation
      waitingCards
      Color.clear.frame(maxWidth: .infinity).frame(height: 2).sereinHintAnchor(.checkIns).id("end")
    }
    .padding(16).frame(maxWidth: full ? AssistantMetrics.column + 32 : .infinity).frame(maxWidth: .infinity)
    .frame(minHeight: viewport, alignment: .top)
    .modifier(ChatFollowReading(viewport: viewport, following: $following))
    // The person's bubbles wear the avatar's tint; a team chat has no one avatar, so keeps the wash.
    .environment(\.personBubbleTint, p.assistantTint(relay.team.active?.colour))
  }
  /// The window draws no hologram over the chat: Serein's face is on the sidebar's rail.
  @ViewBuilder private var emptyTop: some View {
    // The face of a chat that runs elsewhere (QuickBarFace.swift); nothing at rest.
    if docked && heroChat { QuickBarFace(relay: relay, place: .chat) }
  }
  /// Who this chat is with, over its first message. The time lines in the chat say when. Not over a
  /// team's chat, whose messages say who wrote them.
  @ViewBuilder private var contactHeader: some View {
    if docked, relay.activeTeam == nil, !emptyChat {
      SereinChatContactHeader(
        // The row above already names the chat (its chat top or its name pill), so no second name here.
        profile: relay.team.active, name: nil, orb: false, size: full ? 72 : 52)
        .padding(.bottom, AssistantMetrics.turnGap - AssistantMetrics.turnInnerGap)
    }
  }
  /// What every message list in this chat shares (`RelayChatShared`).
  private func chatShared(_ proxy: ScrollViewProxy) -> RelayChatShared {
    let reduce: Bool = reduceMotion
    // The brief's Go to card: the dock pages to its approvals; a team card sits below, in this scroll view.
    let inDock: Set<UUID> = Set(relay.approvals.filter { DecisionAsk.docks($0) }.map(\.id))
    let goToCard: (UUID) -> Void = { id in
      if inDock.contains(id) {
        dockRequest = id
        withAnimation(reduce ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
        return
      }
      withAnimation(reduce ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
    }
    // Edit and rerun on the user's messages; not while the turn is being handed over.
    let edit: ((String, String) -> String?)? = relay.sending ? nil : { relay.rerun($0, text: $1) }
    // Tasks this chat started: each card stays in the chat for good, after the turn that started
    // it. The first one carries the notification question while macOS has not been asked.
    return RelayChatShared(
      cards: taskCards, goToCard: goToCard, openCards: Set(relay.approvals.map(\.id)), edit: edit,
      face: relay.team.active, profiles: relay.team.profiles)
  }
  /// The newest turn (live, or ended with its run still in memory), the welcome, or the messages.
  /// One branch holds the welcome for both "no AI app" and the first launch, so it keeps its
  /// place when the sign-in ends and an AI app is ready: the picker opens, and the pick's "Done."
  /// and its chips stay. While first-time setup runs in the chat (SereinChatSetupCard, in
  /// `setupCards`), it leads and the welcome waits.
  @ViewBuilder private func conversation(_ shared: RelayChatShared) -> some View {
    if let run = relay.run ?? settledRun {
      turnTranscript(run, shared)
    } else if needsAgent || showsWelcome {
      if needsAgent, !relay.transcript.isEmpty { earlierMessages(shared) }
      // A held message brings its own connect card (`HeldBubbles`): one picker, not two.
      if !chatSetup.isActive(in: relay), relay.heldHere.isEmpty {
        WelcomeFlowView(relay: relay, firstMessage: relay.transcript.isEmpty && WelcomeMoment.greets(in: relay.threadID),
                        ask: { ask($0) })
      }
    } else if relay.outgoingHere != nil || !(relay.transcript.isEmpty && !relay.heldHere.isEmpty) {
      // (Only a held message: no greeting or examples above it.)
      chatMessages(shared)
    }
  }
  /// The turn that ended, while its run is still in memory: the chat keeps drawing from that run,
  /// so the end of a turn changes values in the one list and rebuilds nothing. The reply finishes
  /// its paced reveal, and the trail keeps the fold the person chose.
  private var settledRun: AgentRun? {
    guard !needsAgent, !showsWelcome, let run = hub.latest(for: relay.threadID), !run.transcript.isEmpty else { return nil }
    return run
  }
  private func turnTranscript(_ run: AgentRun, _ shared: RelayChatShared) -> some View {
    // What a reply offers once its turn has ended; none of it while the turn runs.
    let ended: Bool = !run.isActive
    return RelayTranscript(
      run: run, answered: relay.answered, p: p, cards: shared.cards, card: taskCard, brief: relay.briefCard,
      goToCard: shared.goToCard, openCards: shared.openCards, edit: shared.edit,
      handoffTargets: handoffTargets, handOff: handOff, speaker: speaker,
      face: shared.face, profiles: shared.profiles, relay: relay, asking: askingHere,
      outgoing: relay.outgoingHere, waiting: relay.waitsOnPerson(in: run.spec.threadID),
      undoCondense: ended ? { relay.agent.undoCondense($0, in: relay.threadID) } : nil,
      chipSend: ended ? { ask($0) } : nil, retry: ended ? retryLast : nil,
      again: ended ? retryNewest(run) : nil, speak: ended ? { _ = controller.speak($0) } : nil)
  }
  /// The chat's messages above the welcome while no AI app can think.
  private func earlierMessages(_ shared: RelayChatShared) -> some View {
    RelayMessages(messages: relay.transcript, working: false, phase: nil, p: p, answered: relay.answered,
                  showsTitle: !full, cards: shared.cards, card: taskCard, brief: relay.briefCard,
                  goToCard: shared.goToCard, openCards: shared.openCards,
                  undoCondense: { relay.agent.undoCondense($0, in: relay.threadID) }, edit: shared.edit,
                  face: shared.face, profiles: shared.profiles, relay: relay)
  }
  /// The saved messages of a chat with no run in memory. From the press of Send until the run
  /// exists, the person's words and a bare trail follow them (`RelayOrchestrator.outgoing`).
  private func chatMessages(_ shared: RelayChatShared) -> some View {
    let examples: Bool = relay.heldHere.isEmpty
    let suggest: ((String) -> Void)? = examples ? { ask($0) } : nil
    let outgoing: RelayOrchestrator.Outgoing? = relay.outgoingHere
    let messages: [AgentMessage] = relay.transcript + (outgoing?.messages ?? [])
    let ideas: [SereinIdea] = messages.isEmpty ? SereinIdeas.forNewChat() : []
    return RelayMessages(
      messages: messages, working: outgoing != nil, phase: nil, p: p, answered: relay.answered,
      suggest: suggest, ideas: ideas, showsTitle: !full, greets: style == .side,
      aboutPage: side && pageChip.slot.page != nil,
      cards: shared.cards, card: taskCard, brief: relay.briefCard,
      goToCard: shared.goToCard, openCards: shared.openCards,
      undoCondense: { relay.agent.undoCondense($0, in: relay.threadID) }, edit: shared.edit,
      handoffTargets: handoffTargets, handOff: handOff, speaker: speaker,
      face: shared.face, profiles: shared.profiles, relay: relay,
      trail: outgoing.map {
        AnyView(ThinkingTrail(steps: [], startedAt: $0.at, attempt: relay.tryNumber(in: relay.threadID), stop: { relay.stopReply() }))
      },
      chipSend: { ask($0) }, retry: retryLast, speak: { _ = controller.speak($0) }, job: activeJob)
  }
  /// Under the conversation: Serein saying hello, first-time setup in the chat, and the setup
  /// cards Serein offered (setup_offer).
  @ViewBuilder private var setupCards: some View {
    if docked && !chatSetup.isActive(in: relay) && relay.welcoming && relay.transcript.isEmpty {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small).accessibilityHidden(true)
        Text("\(relay.team.activeName) is saying hello…").font(AssistantType.meta).foregroundStyle(p.secondary)
        Spacer(minLength: 0)
        Button("Stop") { relay.cancelWelcome(suppress: true) }.buttonStyle(QuietButton())
      }.accessibilityElement(children: .contain)
    }
    if docked && chatSetup.isActive(in: relay) {
      SereinChatSetupCard(relay: relay, offeredIn: relay.threadID)
        .id(relay.threadID + ":" + String(describing: chatSetup.state.phase))
    }
    ForEach(relay.setupOffersHere, id: \.rawValue) { topic in
      SereinSetupCard(topic: topic, offeredIn: relay.threadID, relay: relay, controller: controller)
        .id(relay.threadID + ":" + topic.rawValue)
    }
  }
  /// Under the conversation: queued messages, other assistants at work, connect cards, held
  /// messages, the Stop line, hand-offs, what the microphone hears, and the activity list.
  @ViewBuilder private var underConversation: some View {
    ResearchCards(research: relay.research, thread: relay.threadID)
    // Messages written while it replies: at 60%, with Queued, Send now, Edit and Remove.
    QueuedBubbles(relay: relay)
    // Every other assistant that works for this chat now: the dots, "Asking …".
    ForEach(busyHelpers, id: \.id) { helper in
      TypingRow(name: helper.name, profile: helper.profile,
                announceKey: "\(helper.id):\(relay.threadID):\(relay.transcript.last?.id ?? "")")
    }
    // Under the reply: a card for each connection the message needed and did not have.
    if let connect = relay.connectCardsHere {
      ForEach(connect.needs, id: \.self) { need in
        if let link = Self.composioLink(need) {
          ConnectChatCard(link: link, card: relay.threadID + ":" + link.app, assistant: relay.team.activeName) {
            relay.continueAfterConnect()
          }
        } else if case .aiApp = need {
          // The AI app is missing or signed out (board 19): the card follows the app the next
          // turn uses (another one picked from the card counts), and the message goes once it can
          // answer.
          AIAppConnectCard(provider: relay.assistantEngine(relay.team.active).provider, agent: relay.agent,
                           assistant: relay.team.activeID) {
            relay.continueAfterConnect()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else if case .aiKey(_, let model, let failure) = need {
          OpenCodeKeyCard(failure: failure, model: model, assistant: relay.team.activeName) {
            relay.continueAfterConnect()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          ConnectNeedCard(need: need, words: connect.request.message.text, relay: relay)
        }
      }
    }
    // Messages held until an AI app connects or the network is back.
    HeldBubbles(relay: relay)
    if let notice = relay.stopNotice { SereinStopNoticeRow(notice: notice, relay: relay, retry: settledRun.flatMap(retryNewest)) }
    // Tasks this assistant handed to another: their status lines and result cards.
    HandoffRows(relay: relay)
    // A Mac tool met Accessibility off: the chat's one card, then its line until the chat carries on.
    if let wait = relay.macAccess.state(in: relay.threadID) { MacAccessCard(state: wait) }
    // What a hold heard so far. The mic itself shows that it listens; no "Listening…" bubble.
    if !voiceInput.heard.isEmpty { heardBubble }
    if showActivity { activityList }
  }
  private var heardBubble: some View {
    HStack {
      Spacer(minLength: 80)
      Text(voiceInput.heard)
        .foregroundStyle(p.ink)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(p.bubble, in: RoundedRectangle(cornerRadius: UIStyle.bubbleRadius))
    }
  }
  /// What waits for the person at the foot of the chat: due reminders, missed runs, the reminder's line, consent,
  /// secure cards, a proposed team or hand-off, approvals and other apps' questions (`DecisionDock`), Serein's own
  /// questions (`QuestionFormCard`), and the failure line. Nothing that asks waits above the composer.
  @ViewBuilder private var waitingCards: some View {
    ForEach(relay.dueReminders, id: \.id) { reminder in reminderCard(reminder) }
    ForEach(relay.missedRuns) { missed in MissedRunCard(missed: missed, relay: relay) }
    if let notice = relay.reminderNotice { ReminderNoticeCard(notice: notice, relay: relay, p: p) }
    if relay.consentWaiting { RelayConsentCard(relay: relay, p: p) }
    SecureCardStack(cards: relay.browser.secureCards)
    TakeoverCardStack(cards: relay.browser.takeoverCards)
    ForEach(Array(relay.approvals.enumerated()), id: \.element.id) { index, approval in
      // In a call the current card shows in the call view, with how to answer it by voice.
      if !(controller.callMode && index == 0), !DecisionAsk.docks(approval) {
        // A proposed team gets its own card (ApprovalCardSlot).
        ApprovalCardSlot(
          approval: approval, relay: relay, controller: controller, p: p,
          showLevels: index == 0 && RelayOrchestrator.previewLevelsPopover)
        .id(approval.id)
      }
    }
    // Approvals and other apps' questions, one card at a time (`DecisionDock`).
    DecisionDock(relay: relay, controller: controller, skipsFirstApproval: controller.callMode, request: $dockRequest) {
      focused = true
    }
    // Sessions in other apps waiting on the person, while they wait, in the chat their texts go to.
    if let main = relay.team.main, relay.existingThread(of: main.id) == relay.threadID {
      WaitingSessionsRow(agent: relay.agent)
    }
    ForEach(relay.questionForms) { form in
      QuestionFormCard(form: form, relay: relay, p: p).id(form.id)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }
    if let error = relay.lastError {
      TurnFailureLine(words: error, attempt: relay.tryNumber(in: relay.threadID), retry: retryLast)
    }
  }
  /// Above the composer: the Working strip (every task, live and from the last day; in the window
  /// only) and Serein's own task in a Mac app. A reply's own status rides in its typing bubble.
  @ViewBuilder private var aboveComposer: some View {
    // Serein's own task working in a Mac app in the background, with Stop.
    MacBackgroundLine(thread: relay.threadID, full: full)
    // One bar, with no rule above it in the window (full or beside); the floating panel keeps
    // its hairline over the composer.
    if !docked { Rectangle().fill(p.line).frame(height: 1) }
  }

  /// Keep the transcript layout separate from lifecycle observers so SwiftUI's concrete view
  /// type stays small enough to check as setup adds more observable state.
  private var panelContent: some View {
    VStack(spacing: 0) {
      panelHeader
      if showsStage { stage.transition(reduceMotion ? .identity : .opacity) }
      ScrollViewReader { proxy in
        ScrollView {
          chatColumn(proxy)
            .environment(\.chatFollow, following ? { proxy.scrollTo("end", anchor: .bottom) } : nil)
          // Another assistant's chat replaces this one at once (inside the 0.12 s swap): no part
          // of the chat slides, and its layout never animates.
        }
          // With a mouse attached the system bar draws a track with its own border beside the chat.
          .scrollIndicators(.never)
          .sereinHintViewport([.asksBefore, .checkIns])
          .modifier(ChatFollowsEnd(viewport: $viewport))
          .modifier(RelayScrollToEnd(relay: relay, proxy: proxy, following: $following, sent: sent, reduce: reduceMotion,
                                     viewport: viewport))
          // No rule under the header row, which holds the chat's picture and name: a message
          // scrolling up to it fades out, so a cut bubble never reads as a line under the name.
          .overlay(alignment: .top) {
            if chatTopShowing {
              LinearGradient(colors: [p.background, p.background.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 28).allowsHitTesting(false)
            }
          }
      }
      aboveComposer
      Group {
        if controller.callMode { CallView(controller: controller, relay: relay, p: p) } else { composer }
      }.modifier(FullComposerCard(full: full, p: p))
    }
    .frame(width: docked ? nil : 640, height: docked ? nil : RelayController.panelHeight(hologram: false))
    .frame(maxWidth: docked ? .infinity : nil, maxHeight: docked ? .infinity : nil)
    .modifier(PanelSurface(docked: docked))
    .background {
      if side, browser.section == ShellSection.browser, let tab = browser.active {
        GuideBesideRender(tab: tab)
      }
    }
  }

  private var panelStateChanges: some View {
    panelContent
    .onChange(of: surface.draft) {
      if docked { HintCenter.shared.recordInteraction() }
      if surface.draft.isEmpty { welcomeIfVisible() } else if docked { relay.cancelWelcome() }
    }
    .onChange(of: relay.threadID) { welcomeIfVisible() }
    .onChange(of: relay.working) { if !relay.working { welcomeIfVisible() } }
    .onChange(of: relay.heldHere.count) { welcomeIfVisible() }
    .onChange(of: needsAgent) { welcomeIfVisible() }
    .onChange(of: network.online) { welcomeIfVisible() }
    .onChange(of: surface.view) { welcomeIfVisible() }
    .onChange(of: placement.place) { welcomeIfVisible() }
  }

  private var panelSetupEvents: some View {
    panelStateChanges
    .onChange(of: browser.showSettings) { welcomeIfVisible() }
    .onChange(of: browser.showMarketplace) { welcomeIfVisible() }
    .onChange(of: chatSetup.state) { welcomeIfVisible() }
    .onChange(of: connection.flow) {
      if docked { chatSetup.connectionChanged(relay) }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      welcomeIfVisible()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      welcomeIfVisible()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in
      welcomeIfVisible()
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if side { height = $0 } }
  }

  var body: some View {
    panelSetupEvents
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsStage)
    .environment(\.palette, p)
    .foregroundStyle(p.ink)
    .tint(p.solid)
    .onReceive(NotificationCenter.default.publisher(for: RelayWindow.focus)) { _ in if !docked { focused = true } }
    .onReceive(NotificationCenter.default.publisher(for: SereinSurface.focus)) { _ in if docked { focused = true } }
    .onReceive(NotificationCenter.default.publisher(for: Self.showActivity)) { _ in if docked { showActivity.toggle() } }
    .onReceive(NotificationCenter.default.publisher(for: AssistantLibraryView.show)) { _ in
      guard docked else { return }
      AssistantLibraryView.pending = false
      showingLibrary = true
    }
    .sheet(isPresented: $showingLibrary) {
      AssistantLibraryView(relay: relay) { showingLibrary = false }.environment(\.palette, p)
    }
    .onChange(of: relay.threadID) { _, _ in
      if docked { RelayController.markRead() }
    }
    .onAppear {
      focused = true
      if docked {
        RelayController.columnCount += 1
        RelayController.markRead()
        // ⇧⌘L brought this chat on screen: the Library opens over it now.
        if AssistantLibraryView.pending {
          AssistantLibraryView.pending = false
          showingLibrary = true
        }
        SereinSetupCard.seedPreview(in: relay)
        welcomeIfVisible()
      }
    }
    .onDisappear {
      guard docked else { return }
      RelayController.columnCount = max(0, RelayController.columnCount - 1)
      // A full/beside switch mounts another view of this same chat. Only cancel when no chat
      // remains on screen after the layout has settled.
      DispatchQueue.main.async {
        if RelayController.columnCount == 0 { relay.cancelWelcome() }
      }
      // A task panel, a narrow window, ×, or ⌘J took the column: its cards must not wait unseen.
      RelayController.reviewCardsSoon(relay)
    }
  }

  // MARK: the hologram

  /// Only the hologram, on nothing: large over a new chat, a strip while chatting (full only). In
  /// the window it is capped at 340 points wide (the stage never grows past 340×170), and full
  /// and beside share the surface's one engine.
  private var stage: some View {
    let hero = heroChat
    let stageHeight: CGFloat = hero ? (docked ? 170 : 190) : (docked ? 84 : 96)
    return RelayAvatarStage(
      state: avatarState, look: relay.look, jobs: avatarJobs, controller: controller,
      paused: docked && voiceInput.panelShown, engine: docked ? surface.engine : nil, onTap: toggleMic)
      .frame(maxWidth: docked ? 340 : .infinity)
      .frame(height: stageHeight)
      .frame(maxWidth: .infinity)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: hero)
      .transaction { if reduceMotion { $0.animation = nil } }
  }
  /// Opening a chat starts a welcome, never a synthetic message from the person. Readiness
  /// changes retry only while this chat is visible; the orchestrator owns deduplication.
  private func welcomeIfVisible() {
    guard docked else { return }
    // The shell publishes placement and closes setup sheets on this same run-loop turn.
    DispatchQueue.main.async {
      guard surface.chatShowing, NSApp.isActive || SereinChatSetup.preview else { return }
      chatSetup.beginIfNeeded(relay)
      // First-time setup, or the first launch's welcome (WelcomeFlowView), already greets: one
      // greeting, not two.
      if chatSetup.isActive(in: relay) || showsWelcome { relay.cancelWelcome() }
      else { relay.welcomeIfNeeded() }
    }
  }
  /// The first launch: Serein's own empty chat, before any AI app was picked here, and the chat
  /// where the pick just happened, so "Done. I think with {Model} now." and its chips stay.
  private var showsWelcome: Bool {
    docked && heroChat && relay.team.activeID == relay.team.main?.id && WelcomeMoment.greets(in: relay.threadID)
  }
  /// The active assistant's job, for its empty chat: Serein is the chief of staff.
  private var activeJob: String {
    guard let active = relay.team.active, active.id != relay.team.main?.id else { return "Your chief of staff" }
    return AssistantRoster.job(of: active) ?? active.label ?? "Ask in your own words."
  }
  /// A Composio app with no ready account: its connect card in the chat; every other need keeps
  /// its own card.
  static func composioLink(_ need: ConnectNeed) -> ConnectLink? {
    switch need {
    case .app(let slug): return ConnectLink(app: slug, kind: .composio)
    default: return nil
    }
  }
  /// What the hologram shows, the most pressing first.
  private var avatarState: RelayLook.State {
    Self.avatarState(relay: relay, listening: dictation.recording, speaking: voiceInput.speaking)
  }
  static func avatarState(relay: RelayOrchestrator, listening: Bool, speaking: Bool) -> RelayLook.State {
    RelayLook.State.current(
      paused: relay.state.paused, needsUser: !relay.approvals.isEmpty || relay.consentWaiting || !relay.dueReminders.isEmpty
        || !relay.missedRuns.isEmpty,
      listening: listening, speaking: speaking, thinking: relay.working || relay.welcoming,
      failed: relay.lastError != nil, jobs: relay.childRuns.filter(\.isActive).count)
  }
  private var avatarJobs: [RelayAvatarJob] { Self.avatarJobs(relay: relay) }
  /// Delegated runs as satellites: running ones, and ones that just finished.
  static func avatarJobs(relay: RelayOrchestrator) -> [RelayAvatarJob] {
    relay.childRuns.filter { $0.isActive || $0.record.endedAt.map { Date().timeIntervalSince($0) < 6 } == true }.prefix(8).map {
      RelayAvatarJob(id: $0.spec.threadID, state: $0.isActive ? "running" : $0.record.outcome == .done ? "done" : "failed")
    }
  }
  /// Tapping the hologram is the microphone button.
  private func toggleMic() {
    // A click while the microphone is still opening cancels it, as a click while it listens does.
    if dictation.recording || dictation.starting {
      dictation.stop()
    } else {
      let before = surface.draft
      dictation.start { text in surface.draft = before.isEmpty ? text : before + " " + text }
    }
    NotificationCenter.default.post(name: docked ? SereinSurface.focus : RelayWindow.focus, object: nil)
  }

  /// What Serein is doing in a few words: the same status as the row, the band tab and Serein
  /// full's header (SereinStatus, most pressing first). The same status, longest first. A narrow
  /// column falls back to the shorter words (“Working on 1 thing”, “Working on 1”, then
  /// “Working”), never to a cut-off fragment; when even “Working” has no room the words step
  /// aside for the buttons (the red Stop says it).
  private var sereinStatus: SereinStatus {
    SereinSurface.status(relay: relay, agent: agent, hub: hub, online: network.online, unread: false)
  }
  /// The active assistant's own state, which its mark in the header follows (`assistantStatus`);
  /// the words and the amber dot keep Serein's whole state.
  private var activeStatus: SereinStatus {
    relay.assistantStatus(relay.team.activeID, hub: hub, online: SereinSurface.online(network.online),
                          connected: SereinSurface.connected(agent), unread: surface.unread)
  }
  private var statusForms: [String] {
    let status = sereinStatus
    if case .working(let jobs) = status {
      return [status.words, "Working on \(jobs)", "Working"]
    }
    return [status.words]
  }

  private var header: some View {
    // The buttons keep their size and never give up width; the status words take what is left.
    // In the narrow column the icons sit edge to edge (their hit areas already leave air around
    // each glyph), so “Working on 1 thing” fits beside Stop, New chat, Call and × at the default
    // width.
    HStack(spacing: 6) {
      HStack(spacing: docked ? 6 : 8) {
        AssistantMark(profile: relay.team.active, size: 14, status: activeStatus)
        Text(verbatim: relay.team.activeName).font(AssistantType.name).lineLimit(1).fixedSize()
        if sereinStatus == .needsYou { Circle().fill(p.warning).frame(width: 6, height: 6).accessibilityHidden(true) }
        let forms = statusForms
        ViewThatFits(in: .horizontal) {
          ForEach(forms, id: \.self) { Text($0).lineLimit(1).fixedSize() }
          Color.clear.frame(width: 0, height: 1)
        }.font(UIStyle.meta).foregroundStyle(p.secondary)
          .accessibilityElement().accessibilityLabel(forms[0])
      }.frame(maxWidth: .infinity, alignment: .leading)
      headerButtons.fixedSize().layoutPriority(1)
    }.padding(.leading, 16).padding(.trailing, docked ? 10 : 16).frame(height: 44)
  }

  private var headerButtons: some View {
    HStack(spacing: docked ? 0 : 8) {
      if !docked {
        Menu {
          ForEach(ApprovalLevel.chatChoices, id: \.self) { level in
            Toggle(level.menuTitle, isOn: Binding(get: { relay.level == level }, set: { if $0 { controller.setLevel(level) } }))
          }
        } label: {
          Text("Asks before: \(relay.level.title.lowercased())").font(UIStyle.micro).foregroundStyle(p.secondary)
        }.menuStyle(.borderlessButton).fixedSize().help("Change what Serein asks about")
      }
      // Words, not puzzles: the two things people look for, then the quieter ones. The narrow
      // column keeps the words for Stop only; what Serein asks before lives on every approval
      // card, in the menu bar and in Settings there.
      if docked {
        iconButton(showActivity ? "list.bullet.circle.fill" : "list.bullet", "What I did") { showActivity.toggle() }
      } else {
        textButton(showActivity ? "Hide steps" : "What I did") { showActivity.toggle() }
      }
      if !docked { iconButton("macwindow", "Open in the Serein window") { controller.openThread(relay.threadID) } }
      iconButton(controller.callMode ? "phone.down.fill" : "phone.fill", controller.callMode ? "End the call" : "Call Serein — hold the button to talk, replies are read aloud") { controller.callMode.toggle() }
    }
  }

  /// Why voice input stopped or could not start (permission, no microphone, the one-minute
  /// limit): the mic button alone cannot say it. Hidden while it listens, and until the next
  /// start once dismissed.
  @ViewBuilder private var micNoteLine: some View {
    if !dictation.recording, !dictation.starting, let note = dictation.error ?? dictation.endNote {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // Each glyph's middle on the first line's middle, not its foot on the baseline.
        InterfaceIcon(systemName: "mic", size: 11).foregroundStyle(p.secondary)
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        Text(note).font(AssistantType.meta).foregroundStyle(dictation.error == nil ? p.secondary : p.warning)
          .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        Button { dictation.clearNotes() } label: {
          InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary)
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(AssistantPressStyle()).help("Dismiss").accessibilityLabel("Dismiss")
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      }.accessibilityElement(children: .contain)
    }
  }

  private func pastedKeyCard(_ key: String) -> some View {
    SecretCard(
      keeper: relay.desk, ask: .pasted, prefilled: key, isSaved: { _ in false },
      save: { _, entry in relay.savePastedSecret(entry) }, carryOn: {})
  }
  private func removeKey() {
    caught = nil
    surface.draft = ComposerGuard.withoutKeys(surface.draft)
  }
  /// The first key goes into the secure card; every key leaves the draft.
  private func secureKey() {
    guard case .note(let key) = caught else { return }
    caught = .card(key)
    surface.draft = ComposerGuard.withoutKeys(surface.draft)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !surface.attachments.isEmpty || (docked && pageChip.slot != .none) || (docked && mentions.recipientName() != nil) {
        attachmentChips
      }
      if docked { SereinPageChipLine() }
      if docked { BuiltInSetupLine() }
      // Messages that wait for the reply now sit in the chat as queued bubbles (QueuedBubbles).
      micNoteLine
      if let target = surface.replyingTo {
        ReplyBar(target: target) { withAnimation(MessageMotion.reply) { surface.replyingTo = nil } }
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      if case .card(let key) = caught { pastedKeyCard(key) }
      composerRow
      if case .note = caught { KeyCaughtNote(remove: removeKey, secure: secureKey) }
    }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 18)
      .animation(MessageMotion.reply, value: surface.replyingTo)
      .sheet(isPresented: $teachingSkill) {
        SaveSkillSheet(draft: TaskSkillDraft(name: "", whenToUse: "", steps: "")) { teachingSkill = false }
          .environment(\.palette, p)
      }
      // A document or a picture dropped here rides with the next message (DocumentAttachments.swift).
      .onDrop(of: [.fileURL, .image], isTargeted: nil) { surface.acceptDropped($0) }
      // ⌘V with a copied picture (a screenshot, an image) attaches it; words still paste as words.
      .modifier(PicturePaste(active: focused) { surface.pastePictures() })
  }
  /// The person's newest words when no reply followed them: Send again runs them once more.
  private var retryLast: (() -> Void)? {
    guard !relay.working, let last = relay.transcript.last, last.role == "you", !last.text.isEmpty else { return nil }
    return retry(last)
  }
  /// Try again on a turn that failed or was stopped: the person's newest words once more, after
  /// any part of a reply (the rewind takes it). Words Serein or a task wrote are not resent.
  private func retryNewest(_ run: AgentRun) -> (() -> Void)? {
    guard !relay.working, [nil, .relay].contains(run.spec.initiator),
      let last = relay.transcript.last(where: { $0.role == "you" }), !last.text.isEmpty,
      RelayAutomatic.kind(of: last.text) == nil
    else { return nil }
    return retry(last)
  }
  /// Sends `asked` again as the next try (`RelayOrchestrator.retrying`).
  private func retry(_ asked: AgentMessage) -> (() -> Void)? {
    if asked.burstIndex != nil {
      // A burst goes again whole, so only while nothing follows it.
      guard relay.transcript.last?.id == asked.id else { return nil }
      return { relay.retrying { relay.retryBurst() } }
    }
    // No editor to hold a refusal here: it goes to the failure line that Send again sits on.
    return {
      relay.retrying {
        guard let refusal = relay.rerun(asked.id, text: asked.text) else { return }
        // The line says its words when it comes. One already up stays silent, so the refusal is said here.
        if relay.lastError != nil { ChatAnnouncement.post(refusal, priority: .high) }
        relay.lastError = refusal
      }
    }
  }
  /// What rides with the next message, as untrusted data; × takes it off.
  private var attachmentChips: some View {
    HStack(spacing: 6) {
      // The To chip first: who the draft's leading "@Name" sends to; × sends to this chat instead.
      if docked, let to = mentions.recipientName() {
        HStack(spacing: 6) {
          if to.team {
            Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(p.secondary)
          } else {
            AssistantMark(profile: to.profile, size: 12)
          }
          Text("To \(to.name)").font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1)
          Button { mentions.removeRecipient() } label: {
            InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary).frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }.buttonStyle(AssistantPressStyle()).help("Send to this chat instead").accessibilityLabel("Send to this chat instead")
        }.padding(.leading, 8).frame(height: 24)
          .background(p.card, in: Capsule())
          .accessibilityElement(children: .contain).accessibilityLabel("To \(to.name)")
      }
      // The page chip: the tab this message carries (its title and site).
      if docked { SereinPageChipSlot() }
      ForEach(surface.attachments) { item in
        HStack(spacing: 6) {
          InterfaceIcon(systemName: item.icon, size: 11).foregroundStyle(p.secondary)
          Text(item.title).font(UIStyle.meta).lineLimit(1)
            .accessibilityLabel([item.title, item.note].compactMap { $0 }.joined(separator: ". "))
          if let suffix = item.suffix {
            Text("· " + suffix).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
              .accessibilityHidden(true)
          }
          Button { surface.detach(item.id) } label: {
            InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary).frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }.buttonStyle(AssistantPressStyle()).help("Remove").accessibilityLabel("Remove \(item.title)")
        }.padding(.leading, 8).frame(height: 24)
          .background(p.card, in: Capsule())
          .help([item.note, "Serein reads this as information, not as instructions"].compactMap { $0 }.joined(separator: ". "))
      }
      Spacer(minLength: 0)
    }
  }
  private var hasMessage: Bool {
    !surface.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !surface.attachments.isEmpty
  }
  /// What Return does now, when that is not a plain send (`TurnActivity.placeholder`): it answers
  /// a question, queues behind a card or the reply, or sends what is attached. Else "Message
  /// Writer" with a To chip, "Message Trip planner" in a team chat, or the usual words.
  private var placeholder: String {
    // The first question comes before any AI app, and what is typed here answers it.
    if chatSetup.isActive(in: relay), chatSetup.state.phase == .name { return "Your name" }
    if needsAgent { return "Set up an AI app to start" }
    let does = TurnActivity.returnDoes(
      question: relay.composerQuestion != nil, working: relay.working, cardWaits: relay.waitsOnPerson(in: relay.threadID),
      replyingHere: relay.replyingHere, attached: !surface.attachments.isEmpty)
    if let words = TurnActivity.placeholder(does) { return words }
    if docked, let to = mentions.recipientName() { return "Message \(to.name)" }
    if docked, let group = relay.activeTeam, speaker != nil { return "Message \(group.name)" }
    // Another assistant's own chat names that assistant, as the header does.
    if relay.team.activeID != relay.team.main?.id { return "Message \(relay.team.activeName)" }
    // With a crew, the same box reaches any of them.
    if docked, relay.team.profiles.count > 1 { return "Ask or tell \(relay.team.activeName) anything, or @ someone" }
    return "Ask or tell \(relay.team.activeName) anything"
  }
  private var sendLabel: String {
    if docked, let to = mentions.recipientName() { return "Send to \(to.name)" }
    return "Send to \(relay.team.activeName)"
  }
  /// The message bar (the boards' `ai-input`; docs/demos/composer-bar.decision.md): one line in a
  /// card with a hairline edge and the soft lift, ＋, the field, Send (the return arrow) and the
  /// microphone. A longer draft grows the field to six lines, then it scrolls; the buttons stay at
  /// its foot. What Serein thinks with sits under the bar's trailing end as quiet words, each its
  /// own menu: the model, its effort, what Serein asks before, and how full the chat's context is.
  private var composerRow: some View {
    let shape = RoundedRectangle(cornerRadius: AssistantMetrics.barHeight / 2, style: .continuous)
    let rowHeight: CGFloat = AssistantMetrics.barHeight
    return VStack(alignment: .trailing, spacing: 6) {
      HStack(alignment: .bottom, spacing: 6) {
        plusMenu.frame(height: rowHeight)
        messageField
        sendButton.frame(height: rowHeight)
        micButton.frame(height: rowHeight)
        // In the window (full or beside) the speaker is in ⋯ (Read Replies Aloud).
        if !docked { speakerButton.frame(height: rowHeight) }
      }
      .padding(.leading, 12).padding(.trailing, 8)
      .frame(minHeight: AssistantMetrics.barHeight)
      // Grok's composer: the pane with a hairline, a soft drop in light only.
      .background(p.panel, in: shape)
      .overlay(shape.strokeBorder(p.line, lineWidth: UIStyle.hairline))
      .shadow(color: p.cardShadow, radius: 4, y: 2)
      .background { barKeys }
      // The "+" list takes the bar's width and place (ComposerAddList.swift), in the window only.
      .composerAddListAnchor(docked)
      engineLine.padding(.trailing, 10)
    }
  }
  /// Under the bar, once an AI app is set up: the model, its effort and what Serein asks before as
  /// words, each opening its own list, then the context ring once the chat has used some.
  @ViewBuilder private var engineLine: some View {
    if SereinSurface.connected(agent) {
      HStack(spacing: 4) {
        ActiveAssistantModelPill(relay: relay, quiet: true).layoutPriority(-1)
        ComposerEffortChip(relay: relay, quiet: true)
        ComposerPermissionChip(relay: relay, controller: controller, quiet: true)
        if let meter = hub.latest(for: relay.threadID)?.contextMeter { ContextRing(meter: meter).padding(.leading, 4) }
      }
    }
  }
  /// ⌘Return and ⌘Z with the bar empty (SPEC.md 2.0 keys): the newest waiting card's primary
  /// button (`ChatCardKeys`; an approval card keeps its own keys), and the live Undo of the newest
  /// receipt. Hidden buttons, there only while the bar is empty and something waits, so ⌘Z
  /// still undoes typing otherwise.
  @ViewBuilder private var barKeys: some View {
    if !hasMessage && cardKeys.hasPrimary && relay.approvals.isEmpty {
      Button("") { cardKeys.pressPrimary() }.keyboardShortcut(.return, modifiers: .command).hidden()
    }
    if !hasMessage, let token = liveUndo {
      Button("") { _ = relay.undoReceipt(token) }.keyboardShortcut("z", modifiers: .command).hidden()
    }
  }
  /// The newest receipt's Undo while it can still be undone (the one Undo the chat shows).
  private var liveUndo: UndoToken? {
    guard let message = relay.transcript.last(where: { !($0.receipts ?? []).isEmpty }) else { return nil }
    let receipt: Receipt? = (message.receipts ?? []).last { $0.undo?.isLive() == true }
    return receipt?.undo
  }
  /// The field: 13 regular, its line and its placeholder centred in the bar's 44 points.
  private var messageField: some View {
    TextField(placeholder, text: $surface.draft, axis: .vertical)
      .textFieldStyle(.plain).font(AssistantType.body).lineLimit(1...6).focused($focused)
      .padding(.vertical, 12)
      .frame(minHeight: AssistantMetrics.barHeight)
      .onSubmit { send(interrupt: false) }
      .shiftReturnNewLine()
      .onKeyPress(keys: [.return], phases: .down) { press in
        // A reply in this chat only: ⌥Return never cuts another assistant's routine short.
        guard press.modifiers.contains(.option), relay.replyingHere, hasMessage else { return .ignored }
        send(interrupt: true)
        return .handled
      }
      .onKeyPress(.upArrow) {
        guard surface.draft.isEmpty, !relay.pending.isEmpty else { return .ignored }
        QueuedBubbles.edit(relay.pending.count - 1, relay: relay)
        return .handled
      }
      // Beside, Esc in an empty composer gives the keyboard back to the page and ends a peek.
      .onExitCommand {
        // Esc first takes the reply bar away, then stops a reply in this chat only.
        if surface.replyingTo != nil {
          withAnimation(MessageMotion.reply) { surface.replyingTo = nil }
        } else if relay.replyingHere && !hasMessage {
          relay.stopReply()
        } else if side && !hasMessage {
          SereinRouter.escapeSide()
        }
      }
      .accessibilityLabel("Message \(relay.team.activeName)")
      .background(alignment: .topLeading) {
        if docked { Color.clear.frame(width: 2, height: 2).sereinHintAnchor(.optionSpace) }
      }
      // The @ picker opens over the field (ComposerDropdownLayer), in the window only.
      .anchorPreference(key: ComposerDropdownAnchorKey.self, value: .bounds) {
        docked ? [ComposerDropdown.Target(kind: .mentions, owner: AssistantMentions.owner): $0] : [:]
      }
      .onChange(of: surface.draft) { _, draft in
        if case .note = caught, !ComposerGuard.looksLikeKey(draft) { caught = nil }
        if docked { mentions.update(relay: relay, draft: draft, focused: focused, states: assistantStates) }
      }
      .onChange(of: focused) { _, now in
        if docked { mentions.update(relay: relay, draft: surface.draft, focused: now, states: assistantStates) }
      }
      .onDisappear { if docked { mentions.close() } }
  }
  /// + : in the window, the list of what to add or go to (ComposerAddList.swift; "@" at the start
  /// of an empty draft opens it too); the floating panel keeps Attach a File… and Add an App….
  private var plusMenu: some View {
    ComposerAddButton(relay: relay, docked: docked, teach: { teachingSkill = true },
                      addApp: {
                        controller.openWindow()
                        DispatchQueue.main.async { SereinRouter.browser?.showMarketplace = true }
                      })
  }
  /// The animated mic (MicOrb): a ring on each click, an arc while it opens, red and moving with
  /// the voice while it listens.
  private var micButton: some View {
    MicOrb(dictation: dictation) { toggleMic() }
  }
  private var speakerButton: some View {
    Button { speak.toggle(); if !speak { controller.stopSpeaking() } } label: {
      InterfaceIcon(systemName: speak ? "speaker.wave.2.fill" : "speaker.slash", size: 13)
        .foregroundStyle(speak ? p.ink : p.faint).frame(width: 28, height: 28)
    }.buttonStyle(GlyphButtonStyle()).help(speak ? "Serein reads replies aloud" : "Read replies aloud")
      .accessibilityLabel(speak ? "Stop reading replies aloud" : "Read replies aloud")
  }
  /// The 28-point glyph in four states (the return arrow for Send) (`TurnActivity.SendButton`): the arrow (Send),
  /// the clock (Send message, while a turn runs), a 12-point square (Stop, an empty box while a
  /// turn runs) and the arrow at 35% (an empty idle box). The pictures crossfade over 120 ms,
  /// opacity only, at once under Reduce Motion. It is the one Stop, and acts only on a reply in
  /// this chat: behind another assistant's routine the square shows at 35%, disabled.
  private var sendButton: some View {
    let state = TurnActivity.sendButton(hasWords: hasMessage, working: relay.working)
    let acts: Bool = TurnActivity.sendActs(state, canStop: relay.replyingHere)
    let label: String
    switch state {
    case .stop: label = "Stop"
    case .queue: label = "Send message"
    case .send, .disabled: label = sendLabel
    }
    return Button {
      if state == .stop { relay.stopReply() } else { send(interrupt: false) }
    } label: {
      ZStack {
        InterfaceIcon(systemName: "arrow.turn.down.left", size: 15).foregroundStyle(p.ink)
          .opacity(state == .send || state == .disabled ? 1 : 0)
        InterfaceIcon(systemName: "clock", size: 14).foregroundStyle(p.ink).opacity(state == .queue ? 1 : 0)
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(p.ink).frame(width: 11, height: 11)
          .opacity(state == .stop ? 1 : 0)
      }
      .animation(reduceMotion ? nil : .linear(duration: TurnActivity.sendSwap), value: state)
      .frame(width: 28, height: 28).contentShape(Rectangle())
    }.buttonStyle(AssistantPressStyle()).disabled(!acts)
      .opacity(acts ? 1 : 0.35)
      .help(state == .stop && !acts ? "Another assistant's routine is running. Stop it from its own chat" : label)
      .accessibilityLabel(label)
  }

  private func send(interrupt: Bool = true) {
    guard hasMessage else { return }
    let typed = surface.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    switch relay.messagePlan(typed, hasAttachments: !surface.attachments.isEmpty) {
    case .fill(let words):
      surface.draft = words
    case .refuse(let why):
      if why == ComposerGuard.keyRefusal, let key = ComposerGuard.firstKey(in: typed) {
        caught = .note(key)
      } else {
        relay.lastError = why
      }
    case .answer(let words):
      caught = nil
      if dictation.recording { dictation.stop() }
      _ = surface.takeMessage()
      _ = relay.answerFromComposer(words)
    case .send(let typedWords):
      caught = nil
      if dictation.recording { dictation.stop() }
      let attachments = surface.takeMessage().attachments
      // A reply quotes what it answers ahead of the words (the bar's message), as the model reads it.
      let target = surface.replyingTo
      let words = target.map { DraftQuote.draft(quoting: $0.text, before: typedWords) } ?? typedWords
      withAnimation(MessageMotion.reply) { surface.replyingTo = nil }
      // The new bubble comes up from the bar (ArrivingBubble).
      SendMotion.last = words
      sent += 1
      relay.ask(words, attachments: attachments, interrupt: interrupt, page: sentPage())
      // Chatting with an AI app ready ends the first launch's welcome.
      if !needsAgent { RelayOrchestrator.setSetting(true, forKey: WelcomeFlowView.welcomedKey) }
      // A send that did not reach the chat (refused on the way) gives its words back to the bar.
      if relay.lastError != nil, surface.draft.isEmpty, !landed(words) {
        surface.draft = typedWords
        surface.replyingTo = target
        SendMotion.last = nil
        relay.lastError = ComposerGuard.notSent
      }
    }
  }
  /// The words reached the chat: as a message, queued behind the reply, or held for later.
  private func landed(_ text: String) -> Bool {
    let words: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if words.isEmpty { return true }
    let inChat: Bool = relay.transcript.contains { $0.role == "you" && $0.text.contains(words) }
    let inRun: Bool = relay.run?.transcript.contains { $0.role == "you" && $0.text.contains(words) } ?? false
    let queued: Bool = relay.pending.contains(words)
    let held: Bool = relay.heldHere.contains { $0.message.text == words }
    return inChat || inRun || queued || held
  }
  /// An example from the empty chat: sent at once, with the page chip's tab.
  private func ask(_ text: String) {
    sent += 1
    relay.ask(text, page: sentPage())
  }
  /// The tab the message carries: the page chip's, in the window only.
  private func sentPage() -> SereinPage? {
    guard docked, let page = pageChip.pageForSend() else { return nil }
    pageChip.markSeen()
    return page
  }

  private var activityList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("What I did").font(UIStyle.metaStrong)
      if relay.activity.isEmpty {
        Text("Nothing yet. Every step Serein and its tasks take shows here.").font(UIStyle.meta).foregroundStyle(p.secondary)
      }
      ForEach(relay.activity.suffix(15).reversed()) { item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.at.formatted(date: .omitted, time: .shortened)).font(UIStyle.microMono).foregroundStyle(p.faint)
          Text(item.text).font(UIStyle.meta).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          if item.how != .user {
            Text(item.how.rawValue).font(UIStyle.micro)
              .foregroundStyle(item.how == .refused || item.how == .declined ? p.warning : p.secondary)
          }
        }
      }
    }.padding(12).background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
  }

  /// No AI app is ready: Serein has nothing to think with yet.
  private var needsAgent: Bool {
    !SereinSurface.connected(agent)
  }
  private func reminderCard(_ reminder: RelayReminder) -> some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "bell", size: 13).foregroundStyle(p.warning)
      Text(reminder.text).fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Done") { relay.dueReminders.removeAll { $0.id == reminder.id } }.controlSize(.small)
    }.padding(12).background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
  }
  /// Run now's help on a missed card, in the chat and the ⌥Space bar (Settings' Run now says the same).
  static func missedHelp(_ relay: RelayOrchestrator) -> String {
    relay.state.paused ? "Serein is stopped. Resume it first."
      : "Runs once now, under the same rules as a timed run: steps still ask."
  }
  /// A scheduled run that did not happen at its time: Run now starts it as Run now in Settings
  /// does (off while Serein is stopped or the run limit is used up); Skip drops it and keeps the
  /// schedule's next run.
  private func textButton(_ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label).font(UIStyle.micro).foregroundStyle(p.secondary).padding(.horizontal, 8).frame(height: 20)
        .background(p.track, in: Capsule())
    }.buttonStyle(AssistantPressStyle())
  }
  /// A 26-point hit area, 24 in the narrow column's header, where the icons sit edge to edge.
  private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      InterfaceIcon(systemName: symbol, size: 13).foregroundStyle(p.secondary)
        .frame(width: docked ? 24 : 26, height: docked ? 24 : 26)
        .contentShape(Rectangle())
    }.buttonStyle(AssistantPressStyle()).help(label).accessibilityLabel(label)
  }
}

/// Serein full: the message bar sits in the centred column, with no card around it.
private struct FullComposerCard: ViewModifier {
  let full: Bool
  let p: Palette
  @ViewBuilder func body(content: Content) -> some View {
    if full {
      content.frame(maxWidth: AssistantMetrics.column + 32)
        .frame(maxWidth: .infinity)
    } else {
      content
    }
  }
}

/// The floating panel is glass; the docked column takes the window's card around it.
private struct PanelSurface: ViewModifier {
  let docked: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if docked { content } else { content.darkGlass(16) }
  }
}

/// Relay's live turn: re-renders as its run streams.
/// Where a task card sits in Serein's chat: after the turn that `after` (a message id) started.
struct RelayTaskCardSlot: Equatable {
  let after: String
  let threadID: String
}

/// Where things go in a message list (`RelayMessages`): the messages shown, the message that
/// started the newest turn, the task cards above them and their order, the newest run of replies
/// and the newest brief's message.
private struct RelayMessageLayout {
  /// The messages this layout reads: those it draws, with a few before them for context.
  let shown: [AgentMessage]
  /// Where `shown` starts in the whole conversation.
  var offset = 0
  /// Every message in the conversation, for what only the newest message has.
  var count = 0
  /// Older messages drawn outside the chat's own layout (`EarlierPages`): no newest turn's
  /// lines, status or cards there.
  var older = false
  let turnStart: Int?
  /// The message the work trail sits under: the one before the turn's first reply, or the last
  /// while no reply has come. The same message either way, so the trail keeps its place (and
  /// the fold the person chose) when the first reply lands. Nil, with no turn shown, puts it last.
  let trailAfter: Int?
  let above: [String]
  let order: [String]
  let briefAsk: String?
  /// The messages the room between turns goes above (`ChatTurns.breaks`).
  let turnBreaks: Set<String>
}

/// What an older message of Serein's chat draws from (`RelayMessages.olderRow`).
private struct RelayOlderKey: Equatable {
  let near: [AgentMessage]
  let editing: Bool
  let editable: Bool
  /// Undo on a condensed divider, which a turn's end makes available.
  let undoable: Bool
  let unread: Bool
  let face: String?
  let speaker: String?
  /// No later message has receipts: this one's are the newest, and only those show Undo.
  let newestReceipt: Bool
}

/// One reply, worked out once for its parts: its message and place, whether it starts or ends a
/// run, whether it is the newest message, its shown words and chips, and whether its receipts are
/// the newest (only those show Undo).
private struct RelayReplyFacts {
  let message: AgentMessage
  let index: Int
  let first: Bool
  let last: Bool
  let newest: Bool
  let text: String
  let chips: [String]
  let newestReceipt: Bool
  /// The ideas in a reply to Serein's own check-in or brief (`RelayMessages.ideas`); none otherwise.
  let ideas: [RelayProactive.Idea]
  /// What started the turn when Serein spoke first and the chat draws no line for it
  /// (`RelayAutomatic.showsLine`): the reply's ⋯ menu then leads to where it is turned off.
  let spokeFirst: RelayAutomatic.Kind?
}

/// What every message list in one chat shares: its task cards, the brief's Go to card, the open
/// approval cards, Edit and rerun, the chat's own assistant and every assistant.
private struct RelayChatShared {
  let cards: [RelayTaskCardSlot]
  let goToCard: (UUID) -> Void
  let openCards: Set<UUID>
  let edit: ((String, String) -> String?)?
  let face: RelayProfile?
  let profiles: [RelayProfile]
}

private struct RelayTranscript: View {
  @ObservedObject var run: AgentRun
  let answered: [RelayOrchestrator.AnsweredApproval]
  let p: Palette
  var floating = false
  var cards: [RelayTaskCardSlot] = []
  var card: ((String, Bool) -> AnyView)? = nil
  var brief: RelayOrchestrator.BriefWaiting? = nil
  var goToCard: ((UUID) -> Void)? = nil
  var openCards: Set<UUID> = []
  var edit: ((String, String) -> String?)? = nil
  var handoffTargets: [(id: String, name: String)] = []
  var handOff: ((String, String) -> Void)? = nil
  var speaker: RelayProfile? = nil
  var face: RelayProfile? = nil
  var profiles: [RelayProfile] = []
  var relay: RelayOrchestrator? = nil
  /// The title of a card that waits for the person in this chat: the plan's step asks first.
  var asking: String? = nil
  /// The person's next words, from the press of Send until their run exists: they follow the
  /// ended turn's messages, with a bare trail.
  var outgoing: RelayOrchestrator.Outgoing? = nil
  /// A card or a question waits on the person: the trail stands still.
  var waiting = false
  /// Undo on a condensed divider, quick-reply chips, Try again and Read aloud: an ended turn's only.
  var undoCondense: ((String) -> Void)? = nil
  var chipSend: ((String) -> Void)? = nil
  var retry: (() -> Void)? = nil
  /// Try again on the failed line of a turn that ended with a cause; nil when the words were not the person's.
  var again: (() -> Void)? = nil
  var speak: ((String) -> Void)? = nil
  var body: some View {
    let live: Bool = run.isActive
    let next: RelayOrchestrator.Outgoing? = live ? nil : outgoing
    RelayMessages(messages: run.transcript + (next?.messages ?? []), working: live || next != nil, phase: live ? run.phase : nil,
                  p: p, answered: answered, floating: floating,
                  cards: cards, card: card, brief: brief, goToCard: goToCard, openCards: openCards,
                  undoCondense: undoCondense, edit: edit,
                  handoffTargets: handoffTargets, handOff: handOff, speaker: speaker,
                  face: face, profiles: profiles, relay: relay, trail: trail(next),
                  chipSend: chipSend, retry: retry, speak: speak)
      // VoiceOver hears the turn start and end, once each: the trail has no typing row to say it.
      .onChange(of: run.id + (live ? ":live" : ":ended"), initial: true) {
        let name: String = speaker?.name ?? face?.name ?? "Serein"
        if live { ChatAnnouncement.turnBegan(name, key: run.id) } else { ChatAnnouncement.turnEnded(name, how: ended, key: run.id) }
      }
    // A turn that failed says so in place, with what went wrong behind Details. Signed out and a
    // usage limit have their own cards, and a message that moved on to another AI app its held row.
    if !live, next == nil, run.record.outcome == .stuck, !run.signedOut, run.usageLimit == nil, !run.movedOn {
      TurnFailureLine(words: TurnFailure.couldNotAnswer(speaker?.name ?? face?.name ?? "Serein", reason: run.error,
                                                        app: run.spec.provider.name),
                      cause: run.error.map { AgentPrivacy.redact($0) },
                      attempt: relay?.tryNumber(in: run.spec.threadID) ?? 1, retry: again, retryTitle: "Try again")
    }
    // What the turn has to show while it runs: asks, lines, answers, receipts and its plan card.
    if live, let relay {
      LiveTurnFacts(desk: relay.desk, chat: run.spec.threadID, relay: relay, profiles: profiles,
                    now: run.now, gateAsked: asking != nil)
    }
  }
  /// How the turn ended, after the assistant's name, for VoiceOver.
  private var ended: String {
    switch run.record.outcome {
    case .done, .running: return "finished"
    case .stopped: return "stopped"
    case .stuck: return "could not finish"
    case .waiting: return "needs you"
    }
  }
  /// The newest turn's work: a bare trail under words still on their way, else this run's.
  private func trail(_ next: RelayOrchestrator.Outgoing?) -> AnyView? {
    if let next {
      let stop: (() -> Void)? = relay.map { relay in { relay.stopReply() } }
      return AnyView(ThinkingTrail(steps: [], startedAt: next.at, attempt: relay?.tryNumber(in: run.spec.threadID) ?? 1,
                                   stop: stop))
    }
    guard let relay else { return nil }
    // A message written after this run began (one kept because it could not be sent) is not the
    // run's turn: no trail under it.
    let asked: Date? = run.transcript.last(where: { $0.role == "you" })?.sentAt
    if !run.isActive, let asked, asked > run.record.startedAt { return nil }
    let pressed: Date? = relay.sendPressed.flatMap { pressed in
      run.transcript.contains { $0.id == pressed.message } ? pressed.at : nil
    }
    // Stop on the quiet line only for a reply this chat may stop (`replyingHere`).
    let stop: (() -> Void)? = run.isActive && relay.replyingHere ? { relay.stopReply() } : nil
    return AnyView(RunTrail(run: run, browser: relay.browser, since: pressed, waiting: waiting,
                            attempt: relay.tryNumber(in: run.spec.threadID), stop: stop,
                            retry: { _ = relay.ask($0, interrupt: false) }))
  }
}

/// A chat spaced by turn: a turn (the person's message and everything Serein shows for it) sits
/// `AssistantMetrics.turnInnerGap` apart, and `turnGap` goes above the first thing each later turn
/// draws. Mirrors `RelayMessages.messageBody`, so a turn that draws nothing leaves no hole.
enum ChatTurns {
  /// The ids of the messages the turn gap goes above. Never the first thing drawn.
  static func breaks(_ shown: [AgentMessage]) -> Set<String> {
    var breaks: Set<String> = []
    var pending = false
    var drawnBefore = false
    for index in shown.indices {
      if starts(index, in: shown) { pending = true }
      guard draws(index, in: shown) else { continue }
      if pending && drawnBefore { breaks.insert(shown[index].id) }
      pending = false
      drawnBefore = true
    }
    return breaks
  }
  /// A turn starts at the person's message (a run of their messages is one turn, as `messageBody`
  /// joins them), at a turn Serein started itself, and at a condensed divider.
  static func starts(_ index: Int, in shown: [AgentMessage]) -> Bool {
    let message: AgentMessage = shown[index]
    if message.condensed != nil { return true }
    guard message.role == "you" else { return false }
    if index == 0 || RelayAutomatic.kind(of: message.text) != nil { return true }
    let before: AgentMessage = shown[index - 1]
    return !(before.role == "you" && RelayAutomatic.kind(of: before.text) == nil && before.attached == nil)
  }
  /// Whether `messageBody` draws anything for the message.
  static func draws(_ index: Int, in shown: [AgentMessage]) -> Bool {
    let message: AgentMessage = shown[index]
    if message.condensed != nil { return true }
    if let line = message.line, !line.isEmpty { return true }
    if message.role == "you", let automatic = RelayAutomatic.kind(of: message.text) {
      // Serein speaking first has no line: its reply is the first thing the turn draws.
      guard RelayAutomatic.showsLine(automatic) else { return false }
      let next: AgentMessage? = index + 1 < shown.count ? shown[index + 1] : nil
      return !(next.map { $0.role == "assistant" && RelayAutomatic.isQuiet(reply: $0.text) } ?? false)
    }
    if message.role == "assistant", RelayAutomatic.hidesReply(message, after: shown[..<index]) { return false }
    return message.role == "you" || RelayMessages.drawsReply(message)
  }
}

extension RelayMessages {
  /// The ideas in a reply to Serein's own check-in or brief; none for any other reply.
  static func ideas(_ message: AgentMessage, after earlier: ArraySlice<AgentMessage>) -> [RelayProactive.Idea] {
    guard message.text.contains(RelayProactive.ideaMark),
      let asked = earlier.last(where: { $0.role != "assistant" }),
      [.checkIn, .brief].contains(RelayAutomatic.kind(of: asked.text))
    else { return [] }
    return RelayProactive.ideas(in: message.text)
  }
}

extension RelayAutomatic {
  /// A reply with nothing to show: a check-in's “nothing” anywhere, and NOTHING NEW where it
  /// answers a turn Serein started itself (a schedule, a goal, an alert). The current chat, a past
  /// chat and Export… all hide it.
  static func hidesReply(_ message: AgentMessage, after earlier: ArraySlice<AgentMessage>) -> Bool {
    if RelayProactive.isNothing(message.text) { return true }
    guard isQuiet(reply: message.text), let asked = earlier.last(where: { $0.role != "assistant" }) else { return false }
    return kind(of: asked.text) != nil
  }
}

/// Where a turn nobody typed began, in Serein's chat and a past chat (RelayAutomatic): the mark,
/// what started it and an info glyph, never the prompt. A click says why the person is seeing it,
/// with the way to Settings › Serein, where that schedule or alert changes. A check-in and the
/// brief have no line (`RelayAutomatic.showsLine`): they read as Serein's next message.
struct AutomaticTurnLine: View {
  let prompt: String
  let kind: RelayAutomatic.Kind
  @State private var showsWhy = false
  @Environment(\.palette) private var p
  var body: some View {
    let label = RelayAutomatic.label(prompt) ?? ""
    Button { showsWhy.toggle() } label: {
      HStack(spacing: 6) {
        SereinMark(size: 11)
        Text(label).font(UIStyle.micro).foregroundStyle(p.faint).lineLimit(1).truncationMode(.tail)
        InterfaceIcon(systemName: "info.circle", size: 10).foregroundStyle(p.faint)
      }.contentShape(Rectangle())
    }.buttonStyle(AssistantPressStyle())
      .help("Why you're seeing this")
      .accessibilityLabel(label)
      .accessibilityHint("Shows why you're seeing this")
      .popover(isPresented: $showsWhy, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Why you're seeing this").font(UIStyle.bodyStrong)
          Text(RelayAutomatic.why(kind)).font(UIStyle.meta).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if kind != .macAccess {
            Button("Open Settings › Serein") {
              showsWhy = false
              RelayController.shared?.openSettings("Relay")
            }.buttonStyle(PillButton(kind: .tinted, small: true))
          }
        }.padding(14).frame(width: 260, alignment: .leading)
      }
  }
}

/// The words the person just sent, so their new bubble comes up from the message bar (0.16 s
/// `enter`, a fade and a rise from 24 points lower). Only that one bubble moves.
@MainActor enum SendMotion {
  static var last: String?
}

/// The newest bubble's arrival from the message bar; under Reduce Motion a 0.10 s fade.
@MainActor private struct ArrivingBubble: ViewModifier {
  let text: String
  @State private var lift: CGFloat
  @State private var shown: Double
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  init(text: String) {
    self.text = text
    let arriving: Bool = SendMotion.last == text
    _lift = State(initialValue: arriving ? 24 : 0)
    _shown = State(initialValue: arriving ? 0 : 1)
  }
  func body(content: Content) -> some View {
    content.offset(y: lift).opacity(shown)
      .onAppear {
        guard SendMotion.last == text else { return }
        SendMotion.last = nil
        let reduce: Bool = systemReduceMotion || previewReducedEffects
        if reduce { lift = 0 }
        withAnimation(Motion.entering(reduce)) {
          lift = 0
          shown = 1
        }
      }
  }
}

#if DEBUG
  /// Serein's message list alone in a bottom-anchored scroll view, as the chat column holds it,
  /// for `checkTranscriptWindow`. Synthetic messages only.
  struct RelayMessagesCheckHost: View {
    /// At most this many native text views with only the newest messages drawn.
    static let newestTextViews = 3 * RelayMessages.newest
    let messages: [AgentMessage]
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
          RelayMessages(messages: messages, working: false, phase: nil, p: Palette.dusk)
        }.padding(16).frame(maxWidth: AssistantMetrics.column + 32).frame(maxWidth: .infinity)
      }.defaultScrollAnchor(.bottom)
    }
  }
#endif

private struct RelayMessages: View {
  /// Serein keeps one conversation: its newest 16 messages are in this layout, and the older
  /// ones are built above them as the person scrolls up (`EarlierPages`).
  @StateObject private var pages = EarlierPages()
  static let newest = 16
  /// A row's layout reads this many messages on each side of it.
  static let context = 12
  /// One selection for the whole conversation: a drag runs across bubbles, as in Messages.
  @State private var selection = MessageSelection()
  /// Try again's earlier replies: stepping back redraws the newest bubble (`replyFacts`).
  @ObservedObject private var replyVersions = ReplyVersionBook.shared
  let messages: [AgentMessage]
  let working: Bool
  let phase: String?
  let p: Palette
  /// This turn's answered approvals (they reset with each message), placed after the message
  /// that started the turn, so “You allowed this” reads before the reply that followed it.
  var answered: [RelayOrchestrator.AnsweredApproval] = []
  /// A new chat offers a few things to try; a click asks Serein.
  var suggest: ((String) -> Void)? = nil
  /// Things to try with the apps the person connected (SereinIdeas), shown before the examples.
  var ideas: [SereinIdea] = []
  /// The question and its line over the examples (Serein full draws its own, larger, above).
  var showsTitle = true
  /// Beside a tab, the greeting by the hour over the question, as Serein full has it.
  var greets = false
  /// Beside a web page with the page chip: the title and examples are about the page.
  var aboutPage = false
  /// The phase under the reply. Unused now: in the window and in the ⌥Space bar the status line
  /// above the composer has it, with Stop.
  var floating = false
  /// Task cards with the message that started their turn: each sits after that turn's last
  /// message. Cards whose turn is not among the messages shown sit above them.
  var cards: [RelayTaskCardSlot] = []
  var card: ((String, Bool) -> AnyView)? = nil
  /// The latest brief's “Waiting on you”: a read-only card after that brief's reply.
  var brief: RelayOrchestrator.BriefWaiting? = nil
  /// Scrolls Serein's chat to an open approval card; `openCards` are the cards still open.
  var goToCard: ((UUID) -> Void)? = nil
  var openCards: Set<UUID> = []
  /// Undo on a condensed divider, by the summary's id; absent while Serein replies.
  var undoCondense: ((String) -> Void)? = nil
  /// Edit and rerun on a message of the user's, by its id, with the saved words
  /// (RelayOrchestrator.rerun); absent while the turn is being handed to the AI app. A refusal
  /// it gives back keeps the editor open with its words, and the editor says it.
  var edit: ((String, String) -> String?)? = nil
  /// Assistants this chat's assistant can hand work to, for "Ask Writer to Continue" on each
  /// message (the card opens with the message's words), and the drag onto a sidebar row.
  var handoffTargets: [(id: String, name: String)] = []
  var handOff: ((String, String) -> Void)? = nil
  /// The team chat's speaker: the answering assistant. Its messages are group messages, with its
  /// name and picture.
  var speaker: RelayProfile? = nil
  /// The chat's own assistant: its replies are bubbles (nil draws them as a run of text).
  var face: RelayProfile? = nil
  /// Every assistant, for the faces in system lines.
  var profiles: [RelayProfile] = []
  /// For a receipt's buttons; no receipt card shows without it.
  var relay: RelayOrchestrator? = nil
  /// The newest turn's work (RunTrail), above its reply; it stands in for the typing line.
  var trail: AnyView? = nil
  /// Sends a quick-reply chip's words as the person's message; nil hides the chips.
  var chipSend: ((String) -> Void)? = nil
  /// Try again on the newest reply (the person's last words, once more); nil hides it.
  var retry: (() -> Void)? = nil
  /// Read aloud on a reply; nil hides it.
  var speak: ((String) -> Void)? = nil
  /// The chat's assistant's job, for the empty chat's welcome (`ai-welcome`); nil keeps the
  /// question and the examples.
  var job: String? = nil
  /// The message whose words are open in place.
  @State private var editing: String?
  static let examples = [
    "What’s on my calendar today?",
    "Remind me at 5 pm to stretch",
    "Find the best-rated ramen near me",
    "Remember that I prefer short answers",
  ]
  static let pageExamples = [
    "Summarize this page",
    "What should I know before I act on this?",
    "Find the contact details on this page",
    "Remind me to come back to this tomorrow",
  ]
  /// Four suggestions: about the page beside it; else the connected apps' ideas first, then the
  /// general examples.
  private var shownExamples: [SereinIdea] {
    if aboutPage { return Self.pageExamples.map { SereinIdea(app: nil, text: $0) } }
    // A general example an idea already covers ("What’s on my calendar today?") is left out.
    let taken: Set<String> = Set(ideas.map { $0.text.lowercased() })
    let general: [SereinIdea] = Self.examples
      .filter { !taken.contains($0.replacingOccurrences(of: "’", with: "'").lowercased()) }
      .map { SereinIdea(app: nil, text: $0) }
    return Array((ideas + general).prefix(4))
  }
  /// Forms answered in this chat, each shown after the message that started its turn.
  private var answeredForms: [RelayOrchestrator.AnsweredQuestion] {
    guard let relay = RelayOrchestrator.shared else { return [] }
    return relay.answeredQuestions.filter { $0.threadID == relay.threadID }
  }
  var body: some View {
    Group { list }.environment(\.messageSelection, selection)
  }
  /// Where `message` sits in the conversation, for the one selection's reading order.
  private func order(_ message: AgentMessage) -> Int { messages.firstIndex { $0.id == message.id } ?? messages.count }
  @ViewBuilder private var list: some View {
    let thread: String = relay?.threadID ?? ""
    let start: Int = pages.liveStart(in: messages, thread: thread, newest: Self.newest)
    let first: Int = max(0, start - Self.context)
    let layout: RelayMessageLayout = layOut(Array(messages[first...]), offset: first, drawnFrom: start - first)
    // Serein keeps one conversation: older messages come in ahead of a reader scrolling up.
    if start > 0 {
      // Once per update, not per older row: which message has the newest receipts.
      let lastReceipt: Int = messages.lastIndex { !($0.receipts ?? []).isEmpty } ?? -1
      EarlierMessagesRegion(pages: pages, rows: EarlierRows(thread: thread, messages: messages, liveStart: start,
                                                            font: AssistantType.meta) { index in
        olderRow(index, lastReceipt: lastReceipt)
      })
    }
    if messages.isEmpty { emptyTop }
    if let card {
      ForEach(layout.above, id: \.self) { id in card(id, id == layout.order.first) }
    }
    ForEach(Array(layout.shown.enumerated()).dropFirst(start - first), id: \.element.id) { index, message in
      messageRow(message, index: index, layout: layout)
      if let trail, index == layout.trailAfter { trail }
    }
    if layout.turnStart == nil { answeredLines }
    if let trail {
      if layout.trailAfter == nil { trail }
    } else {
      typingRow(layout.shown)
    }
    if working, floating, let phase { phaseRow(phase) }
  }

  // MARK: the parts of the message list (each its own small view builder)

  /// Where things go in the messages shown, worked out once per draw. `shown` starts at `offset`
  /// in the conversation; the rows drawn start `drawnFrom` into it, the rest being context.
  private func layOut(_ shown: [AgentMessage], offset: Int = 0, drawnFrom: Int = 0) -> RelayMessageLayout {
    // The newest turn among the rows drawn, not the context before them.
    let turnStart: Int? = shown.indices.last { $0 >= drawnFrom && shown[$0].role == "you" }
    let asked: [AgentMessage] = shown[min(drawnFrom, shown.count)...].filter { $0.role == "you" }
    let placed: Set<String> = Set(asked.map(\.id))
    let above: [String] = cards.filter { !placed.contains($0.after) }.map(\.threadID)
    let later: [String] = asked.flatMap { message in cards.filter { $0.after == message.id }.map(\.threadID) }
    // Only the newest brief: the morning prompt reads the same every day.
    let briefAsk: String? = brief.flatMap { brief in shown.last { $0.role == "you" && $0.text == brief.prompt }?.id }
    let trailAfter: Int? = turnStart.map { start in
      (shown.indices.first { $0 > start && shown[$0].role == "assistant" } ?? shown.count) - 1
    }
    return RelayMessageLayout(
      shown: shown, offset: offset, count: messages.count, turnStart: turnStart, trailAfter: trailAfter, above: above,
      order: above + later, briefAsk: briefAsk, turnBreaks: ChatTurns.breaks(shown))
  }
  /// `messages[index]` as an older row (EarlierPages), laid out with the messages around it. It
  /// is drawn again when it or its neighbours change, or Edit, Undo, the unread line, the assistant,
  /// or whether its receipts are still the newest (`lastReceipt`: the last message with any, or -1).
  private func olderRow(_ index: Int, lastReceipt: Int) -> EarlierRow {
    let first: Int = max(0, index - Self.context)
    let last: Int = min(messages.count - 1, index + Self.context)
    let near: [AgentMessage] = Array(messages[max(0, index - 1)...min(messages.count - 1, index + 1)])
    let message: AgentMessage = messages[index]
    // Checked on every update of the chat, so only what is cheap to compare.
    let key = RelayOlderKey(near: near, editing: editing == message.id, editable: edit != nil,
                            undoable: undoCondense != nil,
                            unread: relay.map { $0.unreadFrom[$0.threadID] == message.id } ?? false,
                            face: face?.id, speaker: speaker?.id, newestReceipt: lastReceipt <= index)
    return EarlierRow(key: EarlierRowKey(key)) {
      let around: RelayMessageLayout = olderLayout(Array(messages[first...last]), offset: first)
      return AnyView(messageRow(message, index: index - first, layout: around))
    }
  }
  /// An older row's layout: the newest turn's lines, cards and status are not its to draw.
  private func olderLayout(_ shown: [AgentMessage], offset: Int) -> RelayMessageLayout {
    RelayMessageLayout(shown: shown, offset: offset, count: messages.count, older: true, turnStart: nil, trailAfter: nil,
                       above: [], order: [], briefAsk: nil, turnBreaks: ChatTurns.breaks(shown))
  }
  /// An empty chat: the assistant's welcome (`ai-welcome`), or the question and the examples.
  @ViewBuilder private var emptyTop: some View {
    if let face, let job, !aboutPage {
      AssistantWelcomeHeader(profile: face, name: face.name, job: job, chips: shownExamples.map(\.text), ask: suggest)
    } else {
      emptyChat
    }
  }
  /// One message, then what follows it: the turn's answered cards, its task cards and the brief's
  /// waiting card.
  @ViewBuilder private func messageRow(_ message: AgentMessage, index: Int, layout: RelayMessageLayout) -> some View {
    let next: AgentMessage? = index + 1 < layout.shown.count ? layout.shown[index + 1] : nil
    let endsTurn: Bool = next == nil || next?.role == "you"
    let asked: String? = layout.shown[...index].last(where: { $0.role == "you" })?.id
    if layout.turnBreaks.contains(message.id) {
      Color.clear.frame(height: AssistantMetrics.turnGap - 2 * AssistantMetrics.turnInnerGap).accessibilityHidden(true)
    }
    if let relay, relay.unreadFrom[relay.threadID] == message.id {
      // The away card reads the Tasks tab's list, which starts on first attach.
      UnreadLine().onAppear { SereinSessions.shared.attach(relay: relay) }
      AwaySummaryCard(relay: relay, firstUnreadAt: message.sentAt, goToCard: goToCard)
    }
    if MessageTimeline.startsGroup(message.sentAt, after: index > 0 ? layout.shown[index - 1].sentAt : nil), let at = message.sentAt {
      MessageTimeLine(at: at)
    }
    messageBody(message, index: index, next: next, layout: layout)
    if index == layout.turnStart { answeredLines }
    // A form Serein asked in this turn and the person's answer, after the message that started it.
    ForEach(answeredForms.filter { $0.after == message.id }) { form in AnsweredQuestionChips(answered: form, p: p) }
    // An older turn's task cards stay above the newest messages (`layout.above`), where they were.
    if let card, endsTurn, let asked, !layout.older {
      ForEach(cards.filter { $0.after == asked }.map(\.threadID), id: \.self) { id in card(id, id == layout.order.first) }
    }
    // Only when something waits: a card that says nothing waits is not part of the conversation.
    if let brief, !brief.items.isEmpty, let briefAsk = layout.briefAsk, endsTurn, asked == briefAsk {
      SereinBriefWaitingCard(items: brief.items, open: openCards, goTo: goToCard, p: p)
    }
  }
  @ViewBuilder private func messageBody(_ message: AgentMessage, index: Int, next: AgentMessage?, layout: RelayMessageLayout) -> some View {
    let quiet: Bool = next.map { $0.role == "assistant" && RelayAutomatic.isQuiet(reply: $0.text) } ?? false
    if let range = message.condensed {
      CondensedDivider(summary: message, range: range, userWidth: 280,
                       undo: undoCondense == nil ? nil : { undoCondense?(message.id) })
    } else if let line = message.line, !line.isEmpty {
      // Serein's own line: the centred capsule with the faces it names, a folded line that opens
      // to its words, or a warning about an assistant's held-back answer.
      HostLineView(message: message, profiles: profiles)
    } else if message.role == "you", let automatic = RelayAutomatic.kind(of: message.text) {
      // Serein started this turn itself: never the prompt. A check-in or the brief is just its
      // next message; any other turn says what started it and why. Nothing at all when it had
      // nothing to say.
      if !quiet, RelayAutomatic.showsLine(automatic) { AutomaticTurnLine(prompt: message.text, kind: automatic).padding(.top, 4) }
    } else if message.role == "assistant", RelayAutomatic.hidesReply(message, after: layout.shown[..<index]) {
      EmptyView()
    } else if message.role == "you" {
      // Messages in a row sit close together, as one run.
      let joined: Bool = index > 0 && layout.shown[index - 1].role == "you"
        && RelayAutomatic.kind(of: layout.shown[index - 1].text) == nil && layout.shown[index - 1].attached == nil
      personMessage(message, tail: next.map { $0.role != "you" || RelayAutomatic.kind(of: $0.text) != nil } ?? true,
                    status: layout.older ? nil : personStatus(index: index, in: layout.shown))
        .padding(.top, joined ? AssistantMetrics.bubbleGap - AssistantMetrics.turnInnerGap : 0)
    } else if Self.drawsReply(message) {
      assistantMessage(message, index: index, layout: layout)
    }
  }
  /// Under the person's newest message: Seen once the AI app has started answering, Sent until
  /// then, Not sent when its turn could not start. Nothing under an older message, or when a turn
  /// ended with no answer.
  private func personStatus(index: Int, in shown: [AgentMessage]) -> ChatReading.PersonStatus? {
    let later: ArraySlice<AgentMessage> = shown[(index + 1)...]
    guard !later.contains(where: { $0.role == "you" && RelayAutomatic.kind(of: $0.text) == nil }) else { return nil }
    if relay?.unsent.contains(shown[index].id) == true { return .notSent }
    // Only the chat's own answer says it has seen: another assistant may have written first.
    let entries: [ChatReading.Entry] = later.filter { $0.from == nil }.map(RelayMessagesReading.entry)
    if ChatReading.personSeen(after: entries) { return .seen }
    return working ? .sent : nil
  }
  /// The message a bubble answers: saved on the reply, or while it streams read from its tag.
  private func quoted(_ piece: ChatBubbles.Piece, in reply: AgentMessage) -> AgentMessage? {
    var answered: AgentMessage?
    if let id = reply.replies?[String(piece.id)] {
      answered = messages.first { $0.id == id }
    } else if let tag = piece.replyTag, let at = messages.firstIndex(where: { $0.id == reply.id }) {
      answered = AgentMessage.burst(before: at, in: messages).first { $0.burstIndex == tag }
    }
    return answered?.text.isEmpty == false ? answered : nil
  }
  /// Every answered approval as a small chip, after the message that started the turn (allowed,
  /// declined, skipped or expired). The latest one still carries the approval hint's anchor.
  private var answeredLines: some View {
    // An answer given in another chat stays there.
    let here = answered.filter { $0.threadID == nil || relay == nil || $0.threadID == relay?.threadID }
    return ForEach(here) { answer in
      RelayAnsweredLine(answer: answer, p: p)
      if answer.id == here.last?.id { SereinApprovalHintAnchor() }
    }
  }
  /// The assistant works and has written nothing yet: Grok's activity line, at once.
  @ViewBuilder private func typingRow(_ shown: [AgentMessage]) -> some View {
    let waiting: Bool = shown.last.map { $0.role != "assistant" || $0.text.isEmpty } ?? true
    if working, waiting, let face = speaker ?? face {
      // Said once for this turn: the turn's message from the person names it.
      let asked: AgentMessage? = shown.last(where: { $0.role == "you" })
      let turn: String = asked?.id ?? face.id
      // In a team chat, the line sits beside the picture of whoever is working.
      HStack(alignment: .bottom, spacing: speaker == nil ? 0 : GroupFace.gap) {
        if let speaker { GroupFace(profile: speaker) }
        TypingRow(name: face.name, profile: speaker == nil ? face : nil, caption: phase, since: asked?.sentAt,
                  announceKey: "\(face.id):\(turn)")
      }
    }
  }
  private func phaseRow(_ phase: String) -> some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.mini)
      Text(phase).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
    }
  }

  /// An assistant's message draws when it has words or anything the host put on it: receipts, an
  /// ended plan, a dashboard, a routine offer, connect links or chips.
  static func drawsReply(_ message: AgentMessage) -> Bool {
    // "Needs you" about another app's session, including texts saved before the row: the row at
    // the chat's foot says it while it is true (`WaitingSessionsRow`), so the line never draws.
    if message.notice == true, message.waitingSession != nil { return false }
    if !message.text.isEmpty || message.plan != nil { return true }
    if message.siteID != nil || message.dashboard != nil || message.routineOffer != nil || message.post != nil || message.view?.isValid == true { return true }
    // Notes kept draw nothing (ReceiptBlock), so they alone do not make a message show.
    let receipts: Bool = (message.receipts ?? []).contains { $0.kind != .memorySaved }
    let connect: Bool = !(message.connect ?? []).isEmpty
    let chips: Bool = !(message.chips ?? []).isEmpty
    return receipts || connect || chips
  }

  /// The words a reply shows: without its chips line, its idea lines and a bare DONE. Empty when it
  /// draws no bubble, which may still leave it a receipt or another card.
  static func shownWords(_ message: AgentMessage, after earlier: ArraySlice<AgentMessage>) -> String {
    if RelayAutomatic.hidesReply(message, after: earlier) { return "" }
    // A "Sessions finished" card is its rows; its words are for copying and search.
    if message.notice == true, message.finished != nil { return "" }
    if message.notice == true, message.aboutSession != nil { return SessionReport.display(message.text) }
    let parsed: QuickReplies.Parsed = QuickReplies.parse(message.text)
    let words: String = ideas(message, after: earlier).isEmpty ? parsed.text : RelayProactive.withoutIdeas(parsed.text)
    return HostFacts.hides(words) ? "" : words
  }

  /// An empty chat: the question, its line and the things to try.
  @ViewBuilder private var emptyChat: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsTitle {
        if greets { Text(SereinGreeting.text()).font(AssistantType.meta).foregroundStyle(p.secondary) }
        Text(aboutPage ? "Ask about this page, or anything else." : "What can I do for you?").font(AssistantType.title)
        Text("Ask in your own words. Serein answers, works in your Mac apps and on the web, and takes on bigger jobs while you keep going.")
          .font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let suggest {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(shownExamples, id: \.self) { example in
            Button { suggest(example.text) } label: {
              HStack(spacing: 8) {
                if let app = example.app {
                  IdeaIcon(app: app, size: 14)
                } else {
                  InterfaceIcon(systemName: "arrow.up.right", size: 11).foregroundStyle(p.faint)
                }
                Text(example.text).font(AssistantType.body).foregroundStyle(p.ink)
              }.padding(.horizontal, 12).padding(.vertical, 7)
                .background(p.wash(0.05), in: Capsule())
                .contentShape(Capsule())
            }.buttonStyle(AssistantPressStyle()).accessibilityLabel("Ask: \(example.text)")
          }
        }.padding(.top, 4)
      }
    }.padding(.vertical, 16)
      // Serein full: the examples sit centred under its question.
      .frame(maxWidth: showsTitle ? nil : .infinity, alignment: showsTitle ? .leading : .center)
  }

  /// The person's words: the boards' bubble at the trailing edge, with Reply and ⋯ (Copy, Save as
  /// shortcut, Edit) on hover, and the names of what rode with it.
  @ViewBuilder private func personMessage(_ message: AgentMessage, tail: Bool, status: ChatReading.PersonStatus?) -> some View {
    MessageHoverControls { hovered in
      HStack {
        // Words already keep their hover controls on the left; a second gap squeezed them in a narrow pane.
        Spacer(minLength: message.text.isEmpty || editing == message.id ? 80 : 0)
        if editing == message.id, let edit {
          MessageEditor(text: message.text, attached: message.attached?.isEmpty == false,
                        changedFiles: MessageEdit.laterFileChanges(from: message.id, in: messages),
                        save: {
                          let refusal = edit(message.id, $0)
                          if refusal == nil { editing = nil }
                          return refusal
                        }, cancel: { editing = nil })
        } else {
          VStack(alignment: .trailing, spacing: 4) {
            // Chips sent alone show only their names: no empty bubble, and no words you never typed.
            if !message.text.isEmpty {
              // Beside the bubble on hover, so they leave no gap under it.
              HStack(spacing: 6) {
                MessageActions(text: message.text, saveShortcut: true, edit: edit == nil ? nil : { editing = message.id })
                  .opacity(hovered ? 1 : 0).offset(x: hovered ? 0 : 6)
                  .animation(MessageMotion.controls, value: hovered)
                  .allowsHitTesting(hovered).accessibilityHidden(!hovered)
                HStack(alignment: .bottom, spacing: 8) {
                  MessageTime(date: message.sentAt, shown: hovered, trailing: true)
                  PersonBubble(text: message.text, tail: tail)
                    // Words that did not go read as not sent, as a held message does.
                    .opacity(relay?.unsent.contains(message.id) == true ? 0.6 : 1)
                    .environment(\.messageSelectionPrefix, [order(message)])
                    .accessibilityAction(named: "Reply") { MessageActions.reply(message.text, mine: true) }
                    .accessibilityAction(named: "Save as shortcut") { ShortcutBook.offer(message.text) }
                    // Edit is hidden from VoiceOver until hover; this keeps it reachable.
                    .accessibilityActions { if edit != nil { Button("Edit message") { editing = message.id } } }
                }
              }
            }
            // Pictures the person sent, as they look; Copy Image and Open are on each.
            if let images = message.images, !images.isEmpty {
              HStack(spacing: 6) {
                ForEach(images, id: \.self) { MessageImage(source: $0, alt: "Your picture", thumbnail: true) }
              }
            }
            // What rode with it as untrusted data: its chip's name, never its text.
            ForEach(message.attached ?? [], id: \.self) { title in
              HStack(spacing: 5) {
                InterfaceIcon(systemName: "paperclip", size: 10).foregroundStyle(p.secondary)
                Text(title).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1)
              }.padding(.horizontal, 8).frame(height: 22).background(p.track, in: Capsule())
                .accessibilityElement(children: .combine).accessibilityLabel("Attached: \(title)")
            }
            if let status { PersonStatusLine(status: status) }
          }
          .modifier(HandoffMessageMenu(id: message.id, text: message.text, targets: handoffTargets, handOff: handOff))
        }
      }
    }
    .modifier(ArrivingBubble(text: message.text))
  }

  /// A reply: the chat's assistant's words (a group message with its name in a team
  /// chat, or when another assistant wrote it, `AgentMessage.from`), then its receipts, its ended
  /// plan, its connect card or chips and, under the newest reply, its quick-reply chips and actions.
  @ViewBuilder private func assistantMessage(_ message: AgentMessage, index: Int, layout: RelayMessageLayout) -> some View {
    let reply: RelayReplyFacts = replyFacts(message, index: index, layout: layout)
    if message.id.hasPrefix("research-"), let relay {
      ResearchStoryReport(research: relay.research, message: message)
    } else {
      replyRow(reply, layout: layout)
    }
    // A check-in's ideas (IDEA lines): each as a card with Do it and Not now, under its words.
    if let relay, !reply.ideas.isEmpty {
      ForEach(reply.ideas) { IdeaCard(idea: $0, relay: relay) }
    }
    replyCards(reply, shown: layout.shown)
    replyFoot(reply)
  }
  /// A reply's place in its run, its shown words and chips, worked out once for its parts.
  private func replyFacts(_ message: AgentMessage, index: Int, layout: RelayMessageLayout) -> RelayReplyFacts {
    let shown: [AgentMessage] = layout.shown
    // The newest message of the whole conversation, which a layout may not reach.
    let newest: Bool = layout.offset + index == layout.count - 1
    let previous: AgentMessage? = index > 0 ? shown[index - 1] : nil
    // A message with no bubble (one only just begun, a bare DONE, a lone receipt) leaves the tail
    // on the last bubble.
    let followed: AgentMessage? = shown.indices[(index + 1)...].first { later in
      let candidate: AgentMessage = shown[later]
      return candidate.role != "assistant" || candidate.line != nil || !Self.shownWords(candidate, after: shown[..<later]).isEmpty
    }.map { shown[$0] }
    let first: Bool = previous.map { $0.role != "assistant" || $0.line != nil || $0.from != message.from } ?? true
    let last: Bool = followed.map { $0.role != "assistant" || $0.line != nil || $0.from != message.from } ?? true
    let parsed: QuickReplies.Parsed = QuickReplies.parse(message.text)
    // A reply to Serein's own check-in or brief: its idea lines show as cards, not words.
    let ideas: [RelayProactive.Idea] = Self.ideas(message, after: shown[..<index])
    // A bare DONE (a turn whose receipt says it all) stays hidden, while it streams too.
    let words: String = Self.shownWords(message, after: shown[..<index])
    // The newest reply shows the version the person stepped to (`MessageActions`).
    let text: String = newest && message.from == nil && !words.isEmpty ? replyVersions.text(current: words) : words
    // Chips the host kept on the message (after the turn), else a CHIPS: line still in its words.
    let chips: [String] = message.chips ?? parsed.chips
    let later: ArraySlice<AgentMessage> = messages[min(messages.count, layout.offset + index + 1)...]
    let newestReceipt: Bool = !later.contains { !($0.receipts ?? []).isEmpty }
    let started: RelayAutomatic.Kind? = shown[..<index].last(where: { $0.role == "you" })
      .flatMap { RelayAutomatic.kind(of: $0.text) }
    return RelayReplyFacts(
      message: message, index: index, first: first, last: last, newest: newest,
      text: text, chips: chips, newestReceipt: newestReceipt,
      ideas: ideas, spokeFirst: started.flatMap { RelayAutomatic.showsLine($0) ? nil : $0 })
  }
  /// The ⋯ menu's last item on a reply to Serein's own check-in or brief: the brief's switch is on
  /// Settings › Assistants, and how often an assistant speaks first is on its own page.
  private func firstSettings(_ reply: RelayReplyFacts) -> (title: String, open: () -> Void)? {
    guard let kind = reply.spokeFirst, let title = RelayAutomatic.settingsTitle(kind) else { return nil }
    let assistant: String? = face?.id ?? relay?.team.mainProfileID
    return (title, {
      if kind != .brief, let assistant { AssistantSettingsKey.open(assistant) } else { RelayController.shared?.openSettings("Relay") }
    })
  }
  /// The reply's words: another assistant's group bubble, the team speaker's, or the chat's own
  /// assistant's bubbles.
  @ViewBuilder private func replyRow(_ reply: RelayReplyFacts, layout: RelayMessageLayout) -> some View {
    let message: AgentMessage = reply.message
    let author: RelayProfile? = message.from.flatMap { id in profiles.first(where: { $0.id == id }) }
    if reply.text.isEmpty {
      EmptyView()
    } else if let author {
      // Another assistant's answer: its name; its words are its own, as text.
      GroupMessageRow(profile: author, showsName: reply.first, tail: reply.last, showsFace: speaker != nil) {
        Text(verbatim: reply.text).font(AssistantType.bubble).foregroundStyle(p.ink).lineSpacing(4)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(author.name) answered: \(reply.text)")
    } else if let speaker {
      replyPieces(message, text: reply.text, newest: reply.newest) { piece, isLast in
        GroupMessageRow(profile: speaker, showsName: reply.first && piece.id == 0,
                        tail: reply.last && isLast, showsFace: true,
                        hugging: piece.kind == .words ? piece.text : nil) {
          pieceBody(piece, message)
        }
      }
      .modifier(HandoffMessageMenu(id: message.id, text: message.text, targets: handoffTargets, handOff: handOff))
    } else if face != nil {
      ownReplyRow(reply)
    } else {
      // No assistant, no bubbles: paragraphs at the reply size, as a run of text.
      replyPieces(message, text: reply.text, newest: reply.newest, spacing: 12) { piece, _ in
        pieceBody(piece, message, metrics: .assistant)
      }
      .modifier(HandoffMessageMenu(id: message.id, text: message.text, targets: handoffTargets, handOff: handOff))
    }
  }
  /// The chat's own assistant's reply, a bubble at a time, the tail on the last. Reply and ⋯
  /// (Copy, Try again, Read aloud) sit beside its last bubble on hover or while one holds the keyboard, and
  /// VoiceOver has them as actions.
  private func ownReplyRow(_ reply: RelayReplyFacts) -> some View {
    let message: AgentMessage = reply.message
    let live: Bool = working && reply.newest
    let again: (() -> Void)? = reply.newest && !working ? retry : nil
    return MessageHoverControls { hovered in
      Group {
        if !live, let visual = ReplyStoryPresentation(text: reply.text) {
          ReplyStoryCard(story: visual.story, details: visual.details, sourceLine: ReplySources.line(message.read))
            .overlay(alignment: .topTrailing) { replyActions(reply, retry: again, hovered: hovered) }
        } else {
          replyPieces(message, text: reply.text, newest: reply.newest) { piece, isLast in
            if piece.kind == .words {
              SereinReplyBubble(text: piece.text, tail: reply.last && isLast) {
                pieceBody(piece, message)
              } accessory: {
                if isLast && !live {
                  HStack(alignment: .bottom, spacing: 8) {
                    MessageTime(date: message.sentAt, shown: hovered, trailing: false)
                    replyActions(reply, retry: again, hovered: hovered)
                  }
                }
              }
            } else {
              pieceBody(piece, message).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                  if isLast && !live { replyActions(reply, retry: again, hovered: hovered) }
                }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Copy") { MessageActions.copy(ChatBubbles.plain(reply.text)) }
    .accessibilityAction(named: "Reply") { MessageActions.reply(ChatBubbles.plain(reply.text)) }
    .accessibilityActions {
      if let again { Button("Try again", action: again) }
      if let speak { Button("Read aloud") { speak(ChatBubbles.plain(reply.text)) } }
    }
    .modifier(HandoffMessageMenu(id: message.id, text: message.text, targets: handoffTargets, handOff: handOff))
  }
  /// Reply and ⋯, beside the reply's last bubble, so they read as the reply's.
  private func replyActions(_ reply: RelayReplyFacts, retry: (() -> Void)?, hovered: Bool) -> some View {
    MessageActions(text: ChatBubbles.plain(reply.text), retry: retry, speak: speak, settings: firstSettings(reply))
      .opacity(hovered ? 1 : 0).offset(x: hovered ? 0 : -6)
      .animation(MessageMotion.controls, value: hovered)
      .allowsHitTesting(hovered).accessibilityHidden(!hovered)
  }
  /// Start on the newest reply's plan while this chat waits for the person's yes to it: the words
  /// go as the person's own message, the way a quick-reply chip does.
  private var planStart: ((String) -> Void)? {
    guard let chipSend, let relay, ComposerContext.shared.awaitingApproval.contains(relay.threadID), !working else { return nil }
    return chipSend
  }
  /// What the host put on the reply: its dashboard (open on the newest reply), its
  /// receipts, its ended plan, its connect card or chips, and a routine offer.
  @ViewBuilder private func replyCards(_ reply: RelayReplyFacts, shown: [AgentMessage]) -> some View {
    let message: AgentMessage = reply.message
    if let siteID = message.siteID {
      SavedSiteCard(id: siteID)
    } else if let spec = message.dashboard {
      DashboardCard(spec: spec, chips: ["Update it"], ask: dashboardUpdate(spec), open: reply.newest)
    }
    if let draft = message.post {
      PostDraftCard(draft: draft)
    }
    if let tree = message.view {
      UITreeCard(tree: tree, id: message.id, send: chipSend)
    }
    if let receipts = message.receipts, !receipts.isEmpty, let relay {
      ReceiptBlock(receipts: receipts, replyText: reply.text, relay: relay, showsUndo: reply.newestReceipt)
    }
    if let plan = message.plan {
      FoldedPlanRow(plan: plan, start: reply.newest ? planStart : nil)
    }
    if let links = message.connect, !links.isEmpty {
      connectOffer(links, message: message, index: reply.index, shown: shown)
    }
    // "Make it a routine?" (board 13).
    if let offer = message.routineOffer, let relay {
      RoutineOfferCard(offer: offer, relay: relay)
    }
    // A finished session's pictures (SessionReport): its first and last, before and after.
    if message.notice == true, let pictures = message.images, !pictures.isEmpty {
      HStack(alignment: .top, spacing: 8) {
        ForEach(pictures, id: \.self) { MessageImage(source: $0, alt: "Screenshot from that session") }
      }.frame(maxWidth: AssistantMetrics.replyMax, maxHeight: 220, alignment: .leading)
    }
    // A report's reel: a session's lines, tests and what it made, or yesterday's under the brief.
    // No Listen: the figures say it at a glance.
    if let reel = message.reel {
      ReportReelCard(reel: reel)
    }
    // Turns in other apps that ended with nothing to report: one row each (`SessionFinishesCard`).
    if message.notice == true, let rows = message.finished, !rows.isEmpty {
      SessionFinishesCard(rows: rows, agent: relay?.agent)
    }
  }
  /// Under the newest reply, once it ends: its quick-reply chips and its actions.
  @ViewBuilder private func replyFoot(_ reply: RelayReplyFacts) -> some View {
    if reply.newest, !working, let chipSend, !reply.chips.isEmpty {
      QuickReplyChips(chips: reply.chips, send: chipSend)
    }
    // The chat's own assistant has them on hover (`ownReplyRow`).
    if reply.newest, !working, !reply.text.isEmpty, reply.message.from == nil, speaker != nil || face == nil {
      MessageActions(text: ChatBubbles.plain(reply.text), retry: retry, speak: speak, settings: firstSettings(reply))
    }
  }

  /// A dashboard's one chip, "Update it": it asks for that dashboard again in the person's words.
  /// None while no chip can send (the live turn).
  private func dashboardUpdate(_ spec: DashboardSpec) -> ((String) -> Void)? {
    guard let chipSend else { return nil }
    let title: String = spec.title
    return { _ in chipSend("Update the \(title) dashboard") }
  }

  /// One app to connect is its card in the chat; several are chips. Once connected, the card
  /// carries the person's words of that turn on, once, and only words the person wrote.
  @ViewBuilder private func connectOffer(_ links: [ConnectLink], message: AgentMessage, index: Int, shown: [AgentMessage]) -> some View {
    let secrets: [ConnectLink] = links.filter { $0.kind == .secret }
    let apps: [ConnectLink] = links.filter { $0.kind != .secret }
    if let relay {
      ForEach(secrets, id: \.app) { link in secretOffer(link, relay: relay, message: message, index: index, shown: shown) }
    }
    if !apps.isEmpty { appOffer(apps, message: message, index: index, shown: shown) }
  }
  /// The card a `secret_ask` link stands for, read from the saved records by id.
  @ViewBuilder private func secretOffer(
    _ link: ConnectLink, relay: RelayOrchestrator, message: AgentMessage, index: Int, shown: [AgentMessage]
  ) -> some View {
    if let record = relay.desk.secrets.first(where: { $0.id == link.app }) {
      let asked: AgentMessage? = shown[...index].last(where: { $0.role == "you" })
      let words: String? = asked.flatMap { Self.ownWords($0, relay: relay) }
      SecretCard(
        keeper: relay.desk, ask: .record(record),
        isSaved: { desk in desk.secrets.first(where: { $0.id == record.id })?.savedAt != nil },
        save: { _, entry in relay.saveSecret(record, entry) }
      ) { if let words { relay.ask(words) } }
    }
  }
  @ViewBuilder private func appOffer(_ links: [ConnectLink], message: AgentMessage, index: Int, shown: [AgentMessage]) -> some View {
    if links.count == 1, let link = links.first, let relay {
      let asked: AgentMessage? = shown[...index].last(where: { $0.role == "you" })
      let words: String? = asked.flatMap { Self.ownWords($0, relay: relay) }
      let author: RelayProfile? = message.from.flatMap { id in profiles.first(where: { $0.id == id }) }
      let who: String = author?.name ?? face?.name ?? "Serein"
      if link.kind == .key, let account = HostedAccount.forKey(link) {
        SecretCard(
          keeper: account, ask: .place(link, assistant: who), isSaved: { $0.hasKey },
          save: { account, entry in account.save(entry.key) ? nil : account.status ?? "Keychain did not save the key." }
        ) { if let words { relay.ask(words) } }
      } else if link.kind == .mcp, let connector = ConnectorCatalog.byID(link.app) {
        // One click: sign in in the browser, then the person's words go on once.
        OneClickConnectPill(connector: connector) { if let words { relay.ask(words) } }
      } else {
        // Board 13: the pill first ("{App} is not connected yet." and Connect {App}), then the steps.
        ConnectChatCard(link: link, card: message.id + ":" + link.app, assistant: who, pill: true) {
          if let words { relay.ask(words) }
        }
      }
    } else if let chipSend {
      ConnectChips(links: links, ask: chipSend)
    }
  }
  /// The words a connect card may send again as the person's message: the turn's words the host
  /// recorded as the person's own (`personWords`), never a paired app's request, a routine's or a
  /// link's prompt, or a prompt Serein wrote to itself. nil when they are not the person's.
  @MainActor static func ownWords(_ asked: AgentMessage, relay: RelayOrchestrator) -> String? {
    let text: String = asked.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !RelayProactive.isOwnPrompt(asked.text), RelayAutomatic.kind(of: asked.text) == nil,
      asked.notice != true, asked.from == nil else { return nil }
    guard let typed = relay.personWords?.trimmingCharacters(in: .whitespacesAndNewlines), typed == text else { return nil }
    return text
  }

  /// A reply's pieces, a new bubble for each short paragraph. The newest reply is one paced view
  /// through its turn's end, so words not shown yet finish their reveal when the turn ends
  /// instead of landing at once; one already whole starts whole. An older reply is drawn whole.
  @ViewBuilder private func replyPieces<Row: View>(
    _ message: AgentMessage, text: String, newest: Bool, spacing: CGFloat = AssistantMetrics.bubbleGap,
    @ViewBuilder row: @escaping (ChatBubbles.Piece, Bool) -> Row
  ) -> some View {
    let streaming: Bool = working && newest
    let at = messages.firstIndex(where: { $0.id == message.id }) ?? messages.count
    let ordered = ChatBubbles.ordered(text, replies: AgentMessage.burst(before: at, in: messages).count, streaming: streaming)
    if newest {
      PacedReplyPieces(text: ordered, streaming: streaming, spacing: spacing, row: row)
    } else {
      ReplyPieces(text: ordered, spacing: spacing, row: row)
    }
  }
  /// One piece: the message it answers, when it says, over its words.
  private func pieceBody(_ piece: ChatBubbles.Piece, _ message: AgentMessage, metrics: MessageMetrics = .bubble) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let answered = quoted(piece, in: message) { ReplyQuote(text: answered.text) }
      pieceWords(piece, message, metrics: metrics)
    }
  }
  /// One piece's words at the bubble sizes (14 on 20-point lines, headings 16 and 13, code in
  /// Geist Mono 12).
  private func pieceWords(_ piece: ChatBubbles.Piece, _ message: AgentMessage, metrics: MessageMetrics = .bubble) -> some View {
    // The whole reply's citations, so a marker finds a source list that landed in another piece.
    MessageContent(text: piece.text, read: message.read, cited: messageCachedCitations(message.text))
      .environment(\.messageMetrics, metrics)
      .environment(\.messageSelectionPrefix, [order(message), piece.id])
  }
}


/// The top of Serein's chat, as at the top of a conversation with a contact: the hologram mark
/// (another assistant's mark), the name and when you last talked. With the live
/// hologram above the chat, only the name and time show.
private struct SereinChatContactHeader: View {
  let profile: RelayProfile?
  /// Nil when the chat's top already says who this is.
  let name: String?
  let orb: Bool
  let size: CGFloat
  @Environment(\.palette) private var p
  var body: some View {
    VStack(spacing: 6) {
      if orb {
        if profile == nil || profile?.id == RelayTeam.mainID {
          SereinHologramMark(size: size)
        } else {
          AssistantMark(profile: profile, size: size * 0.6).frame(width: size, height: size)
        }
      }
      if let name {
        Text(name).font(UIStyle.font(13, weight: .medium)).foregroundStyle(p.ink).lineLimit(1)
      }
    }.frame(maxWidth: .infinity).padding(.top, orb ? 8 : 0).padding(.bottom, 6)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(name.map { "Chat with \($0)" } ?? "Chat")
  }
}

/// "Ask Writer to Continue" on a message (each assistant that shares a team; more than four go
/// into "Ask to Continue ›"), then "Hand Off To ›" with the full list; either hands the
/// message's words to that assistant at once. The message can also be dragged onto
/// an assistant's row in the sidebar (MessageDrag).
private struct HandoffMessageMenu: ViewModifier {
  /// The message's id (what a drag carries) and its words (what the card starts with).
  let id: String
  let text: String
  let targets: [(id: String, name: String)]
  let handOff: ((String, String) -> Void)?
  func body(content: Content) -> some View {
    if let handOff, !targets.isEmpty, !text.isEmpty {
      content
        .contextMenu {
          if targets.count <= 4 {
            ForEach(targets, id: \.id) { target in
              Button("Ask \(target.name) to Continue") { handOff(target.id, text) }
            }
          } else {
            Menu("Ask to Continue") {
              ForEach(targets, id: \.id) { target in Button(target.name) { handOff(target.id, text) } }
            }
          }
          Menu("Hand Off To") {
            ForEach(targets, id: \.id) { target in Button(target.name) { handOff(target.id, text) } }
          }
        }
        .onDrag { MessageDrag.provider(id: id) }
        .accessibilityAction(named: "Hand off") { handOff(targets[0].id, text) }
    } else {
      content
    }
  }
}

/// The brief's “Waiting on you”, read only: one line per card open when the brief began, and no
/// card at all when none was. Go to card scrolls Serein's chat to a card still open; one answered
/// since reads Answered. Nothing here answers a card; that stays on the card itself.
private struct SereinBriefWaitingCard: View {
  let items: [RelayBriefing.Waiting]
  let open: Set<UUID>
  let goTo: ((UUID) -> Void)?
  let p: Palette
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(RelayBriefing.waitingTitle).font(UIStyle.metaStrong).foregroundStyle(p.ink)
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.line).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          if let id = item.cardID, open.contains(id), let goTo {
            // The font sits on the label: QuietButton sets its own on the label, which would win.
            Button { goTo(id) } label: {
              Text("Go to card").font(UIStyle.metaStrong).foregroundStyle(p.accent)
            }.buttonStyle(QuietButton()).fixedSize()
              .help("Show this card in the chat").accessibilityLabel("Go to card: \(item.line)")
          } else {
            Text("Answered").font(UIStyle.meta).foregroundStyle(p.faint)
          }
        }
      }
    }.padding(.horizontal, 12).padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(RelayBriefing.waitingTitle)
  }
}

/// Call mode: one big press-and-hold button. Pressing ends whatever is being spoken, the mic
/// opens, and the release sends; the reply is read aloud. Half-duplex on purpose — the
/// microphone is never open while Relay speaks, since a raw AVAudioEngine has no echo
/// cancellation. The current approval card stays above the button, answered by click or voice.
private struct CallView: View {
  @ObservedObject var controller: RelayController
  @ObservedObject var relay: RelayOrchestrator
  let p: Palette
  @State private var holding = false
  @GateStorage(RelayController.voiceAnswersKey) private var voiceAnswers = false
  var body: some View {
    VStack(spacing: 10) {
      if let card = relay.approvals.first {
        VStack(alignment: .leading, spacing: 6) {
          ApprovalCardSlot(approval: card, relay: relay, controller: controller, p: p)
            .id(card.id)
          Text(voiceLine(card)).font(UIStyle.meta).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(voiceLine(card))
        }.padding(.horizontal, 12)
      }
      Text(status).font(UIStyle.meta).foregroundStyle(p.secondary)
        .accessibilityLabel("Call status: \(status)")
      Circle()
        .fill(holding ? p.danger : p.accent)
        .frame(width: 74, height: 74)
        .overlay(InterfaceIcon(systemName: holding ? "mic.fill" : relay.working ? "ellipsis" : "phone.fill", size: 26).foregroundStyle(p.onSolid))
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
          .onChanged { _ in if !holding { holding = true; controller.callPressed() } }
          .onEnded { _ in if holding { holding = false; controller.callReleased() } })
        .help("Hold to talk")
        .accessibilityLabel(holding ? "Listening. Release to send" : "Hold to talk")
        .accessibilityAddTraits(.isButton)
      if !controller.heard.isEmpty {
        Text(controller.heard).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(2)
      }
    }.padding(.vertical, 12).frame(maxWidth: .infinity)
      .accessibilityElement(children: .contain)
  }
  private var status: String {
    if holding || controller.dictation.recording { return "Listening… release to send" }
    if controller.speaking { return "Serein is speaking. Hold to talk" }
    if relay.working { return "Working…" }
    return "Hold to talk"
  }
  /// How the card on screen can be answered by voice: allow only for a voice-eligible step with
  /// voice answers on, after a read-back; decline always.
  private func voiceLine(_ card: RelayOrchestrator.Approval) -> String {
    if controller.voiceReadBack == card.id { return "Say yes to allow it (hold to talk). Anything else leaves it waiting." }
    return CallVoice.allowable(card.effect, enabled: voiceAnswers)
      ? "Say allow or decline (hold to talk)"
      : "Say decline (hold to talk). Allowing this one needs a click."
  }
}

/// The ⌥Space panel's hologram on its own window above the panel: no background, over whatever
/// is behind. It holds still while the panel is put away.
struct RelayFloatingHologram: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var controller: RelayController
  @ObservedObject var dictation: Dictation
  var body: some View {
    RelayAvatarStage(
      state: RelayPanelView.avatarState(relay: relay, listening: dictation.recording, speaking: controller.speaking),
      look: relay.look, jobs: RelayPanelView.avatarJobs(relay: relay), controller: controller,
      paused: !controller.panelShown, minFps: 60, overOtherApps: true)
  }
}

/// The active assistant's AI app and model, one click from the chat, in its message bar: the
/// inspector's `ModelPill` with `assistant:`, whose popover is `ModelPickerView` for that assistant
/// and whose pick sets its own route. It redraws when the route changes. `compact` draws the logo
/// tile alone.
struct ActiveAssistantModelPill: View {
  @ObservedObject var relay: RelayOrchestrator
  var compact = false
  var headerHeight: CGFloat? = nil
  var quiet = false
  var body: some View {
    let routeKey: String = relay.team.active?.route.map { "\($0.provider):\($0.model)" } ?? "default"
    ModelPill(agent: relay.agent, compact: compact, assistant: (relay.team.activeID, relay.team.activeName), headerHeight: headerHeight,
      quiet: quiet)
      .id(relay.team.activeID + ":" + routeKey)
  }
}

/// What ⌥Space shows under the hologram. A tap gives a field: its message goes to Serein and its
/// reply grows under the bar (`SereinReplyCard`), in place. Held, it shows what it hears and sends
/// it on release. In a window (⌘E with no room beside the page, a private or other window) it
/// sits at the window's top centre, with no hologram.
struct RelaySummonBar: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var controller: RelayController
  @ObservedObject var dictation: Dictation
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var agent: AgentModel
  /// What the hold is noting on screen, while "Share what I select or point at" is on.
  @ObservedObject private var screen = ScreenContextCapture.shared
  @Environment(\.palette) private var p
  @FocusState private var focused: Bool
  init(relay: RelayOrchestrator, controller: RelayController, dictation: Dictation) {
    self.relay = relay
    self.controller = controller
    self.dictation = dictation
    agent = relay.agent
  }

  private var listening: Bool { dictation.recording || !controller.heard.isEmpty }
  /// Two chips before the field: the private one shortens to “Private” (its full words stay in
  /// help and VoiceOver), and the placeholder to its short form.
  private var crowded: Bool { controller.inWindowPrivate == true && status != nil }
  /// No AI app and offline show as a chip before the field, which stays while you type.
  private var status: (words: String, icon: String, help: String)? {
    if !SereinSurface.connected(agent) {
      return ("Not connected", "bolt.horizontal", "\(relay.team.activeName) has no AI app to think with yet. What you write waits until you connect one.")
    }
    if !SereinSurface.online(network.online) {
      return ("Offline", "wifi.slash", "This Mac is offline. What you write sends when you are back online.")
    }
    return nil
  }
  /// What happens to a message: no AI app, offline, busy. Nothing about the page goes with it
  /// yet, in a window or not, so the field never says it does.
  private var placeholder: String {
    // Beside two chips (a private window that is not connected or offline) the words are short,
    // so they fit whole.
    if !SereinSurface.connected(agent) { return crowded ? "Connect an AI app first" : "Connect an AI app to ask \(relay.team.activeName)" }
    if !SereinSurface.online(network.online) { return crowded ? "Sends when you are back" : "What you write sends when you are back" }
    if relay.working { return "\(relay.team.activeName) is working. Add or change something…" }
    return "Ask \(relay.team.activeName) anything"
  }

  var body: some View {
    HStack(spacing: 8) {
      if controller.micNotice {
        InterfaceIcon(systemName: "mic", size: 12).foregroundStyle(p.secondary)
        Text("Serein needs the microphone to listen. macOS asks once. Let go, then choose OK.")
          .font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      } else if let words = controller.wakeWords {
        // After “Serein”: what follows it, sent after a pause. Cancel (or Esc) sends nothing.
        InterfaceIcon(systemName: "waveform", size: 12).foregroundStyle(p.secondary)
        Text(words.isEmpty ? "Listening… pause to send" : words)
          .foregroundStyle(words.isEmpty ? p.secondary : p.ink)
          .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel(words.isEmpty ? "Listening. Pause to send" : "Heard: \(words)")
        Button("Cancel") { controller.cancelWake() }.buttonStyle(QuietButton())
          .help("Send nothing · Esc").accessibilityLabel("Cancel, send nothing")
      } else if listening {
        InterfaceIcon(systemName: "waveform", size: 12).foregroundStyle(p.secondary)
        Text(controller.heard.isEmpty ? "Listening… let go to send" : controller.heard)
          .foregroundStyle(controller.heard.isEmpty ? p.secondary : p.ink)
          .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
        // What rides with the words, said as it is taken: "Pages · selected text · circled".
        if let seeing = screen.seeing, !seeing.isEmpty {
          HStack(spacing: 4) {
            InterfaceIcon(systemName: "cursorarrow.rays", size: 10)
            Text(seeing).font(UIStyle.micro).lineLimit(1)
          }
          .foregroundStyle(p.secondary)
          .padding(.horizontal, 8).frame(height: 20).background(p.track, in: Capsule())
          .fixedSize()
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Goes with your words: \(seeing)")
        }
      } else {
        // A private window's bar never shares the tab, and says so.
        if controller.inWindowPrivate == true {
          chip(crowded ? "Private" : "Private window · not shared", icon: "eye.slash", help: "Nothing about this window goes to Serein")
            .accessibilityLabel("Private window. Nothing about it goes to Serein")
        }
        if let status { chip(status.words, icon: status.icon, help: status.help) }
        // The placeholder carries what happens to a message (it waits while offline or not
        // connected), so it is drawn in the secondary ink, not the system's fainter one.
        TextField("", text: $controller.summonDraft)
          .textFieldStyle(.plain).focused($focused)
          .onSubmit { controller.sendWriting() }
          .background(alignment: .leading) {
            if controller.summonDraft.isEmpty {
              Text(placeholder).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
          }
          .accessibilityLabel("Message \(relay.team.activeName)")
          .accessibilityHint(placeholder)
        if !controller.summonDraft.trimmingCharacters(in: .whitespaces).isEmpty {
          Button { controller.sendWriting() } label: {
            InterfaceIcon(systemName: "arrow.up", size: 11).foregroundStyle(p.onSolid)
              .frame(width: 24, height: 24).background(p.solid, in: Circle()).contentShape(Circle())
          }.buttonStyle(AssistantPressStyle()).help("Send").accessibilityLabel("Send to \(relay.team.activeName)")
        }
      }
    }
    .padding(.leading, 16).padding(.trailing, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Glass, as its reply card is (`BarGlass`): no dark plate under the hologram.
    .barGlass(in: Capsule())
    .overlay(Capsule().stroke(p.borderStrong))
    .environment(\.palette, p)
    .onAppear { focused = true }
    .onReceive(NotificationCenter.default.publisher(for: RelayWindow.focus)) { _ in focused = true }
  }
  /// A status chip before the field (private window, Not connected, Offline): ink in a hairline
  /// on the bar's own glass.
  private func chip(_ words: String, icon: String, help: String) -> some View {
    HStack(spacing: 4) {
      InterfaceIcon(systemName: icon, size: 10)
      Text(words).font(UIStyle.meta).lineLimit(1).fixedSize()
    }.foregroundStyle(p.ink).padding(.horizontal, 8).frame(height: 22)
      .overlay(Capsule().strokeBorder(p.borderStrong))
      .help(help)
      .accessibilityElement(children: .combine)
  }
}

/// The ⌥Space panel's content: the 40-point bar, and under it, when there is something to show,
/// the reply card. It reports its height so the panel grows down from the bar's top edge.
struct SereinBarContent: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var controller: RelayController
  @ObservedObject var dictation: Dictation
  @ObservedObject private var appearance = AppearanceController.shared
  var body: some View {
    let p = appearance.palette
    VStack(spacing: 8) {
      // Only while the bar is up: put away, its panel stays made but draws (and streams) nothing.
      if controller.panelShown {
        // The face of the chat that runs now (QuickBarFace.swift); no chat title in a bar that
        // opened by itself or in a private window.
        QuickBarFace(relay: relay, place: .bar, showsTitle: !controller.answerOnly && controller.inWindowPrivate != true) {
          controller.openInSerein()
        }
        RelaySummonBar(relay: relay, controller: controller, dictation: dictation)
          .frame(height: RelayController.barSize.height)
        if let why = controller.barRefusalShown {
          Text(why).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .barGlass(in: RoundedRectangle(cornerRadius: UIStyle.panelRadius, style: .continuous))
        }
        SereinReplyCard(relay: relay, controller: controller)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controller.fitBar($0) }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.palette, p)
    .foregroundStyle(p.ink)
    .tint(p.solid)
  }
}

/// `--ui-serein-bar-reply` and `--ui-serein-bar-approval` (release builds too): the ⌥Space bar,
/// its hologram and its reply card drawn over the window, as they float over another app. The
/// window behind is as it was.
struct SereinBarPreviewLayer: View {
  @ObservedObject var controller: RelayController
  static let flags = ["--ui-serein-bar-reply", "--ui-serein-bar-approval", "--ui-serein-bar-held", "--ui-serein-bar-mic"]
  static var active: Bool {
    CommandLine.arguments.contains("--ui-preview") && flags.contains { CommandLine.arguments.contains($0) }
  }
  var body: some View {
    // No scrim: the real bar dims nothing, so the window shows as it was, under the card's shadow.
    VStack(spacing: -8) {
      if RelayController.hologramOn && !controller.inWindow {
        RelayFloatingHologram(relay: controller.relay, controller: controller, dictation: controller.dictation)
          .frame(width: RelayController.hologramWidth, height: RelayController.hologramHeight)
      }
      SereinBarContent(relay: controller.relay, controller: controller, dictation: controller.dictation)
        .frame(width: RelayController.barSize.width)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }
    // In a window, the bar sits under the window's own header row, as `showInWindow` puts it.
    .padding(.top, controller.inWindow ? 64 : RelayController.hologramOn ? 24 : 96)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

/// The line under a reminder Serein just set: how it behaves while Serein is closed, with the
/// one button that changes that. It follows the chat it belongs to and goes with the next
/// message or New chat.
struct ReminderNoticeCard: View {
  let notice: RelayOrchestrator.ReminderNotice
  @ObservedObject var relay: RelayOrchestrator
  let p: Palette
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      InterfaceIcon(systemName: icon, size: 13).foregroundStyle(p.secondary).padding(.top, 2)
      VStack(alignment: .leading, spacing: 8) {
        Text(text).font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        if let button {
          // Quiet, so an approval below stays the strongest call to action.
          Button(button) { act() }.buttonStyle(.bordered).controlSize(.small)
        }
      }
      Spacer(minLength: 0)
      Button { relay.reminderNotice = nil } label: {
        InterfaceIcon(systemName: "xmark", size: 10).foregroundStyle(p.secondary).frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }.buttonStyle(AssistantPressStyle()).help("Dismiss").accessibilityLabel("Dismiss")
    }
    .padding(12)
    .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
    .accessibilityElement(children: .contain)
  }
  private var icon: String {
    switch notice {
    case .allowNotifications, .notificationsOff: return "bell"
    case .keepRunning, .keptInMenuBar: return "clock"
    }
  }
  private var text: String {
    switch notice {
    case .allowNotifications: return "Serein reminds you with a notification, even when Serein is closed."
    case .notificationsOff: return "Notifications are off for Serein, so this reminder only shows in Serein."
    case .keepRunning(let when):
      return "Serein must be running \(when) to do this. If it is closed then, it tells you it missed it."
    case .keptInMenuBar: return "Serein stays in the menu bar. Turn this off in Settings › Assistants › Ask from any app."
    }
  }
  private var button: String? {
    switch notice {
    case .allowNotifications: return "Allow notifications"
    case .notificationsOff: return "Open System Settings"
    case .keepRunning: return "Keep Serein in the menu bar"
    case .keptInMenuBar: return nil
    }
  }
  private func act() {
    switch notice {
    case .allowNotifications:
      TaskNotifications.shared.requestAuthorization()
      relay.reminderNotice = nil
    case .notificationsOff:
      if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
        NSWorkspace.shared.open(url)
      }
      relay.reminderNotice = nil
    case .keepRunning: relay.keepInMenuBar()
    case .keptInMenuBar: break
    }
  }
}

/// A beside tick follows the page actually rendered, even when page sharing is off or its chip
/// was removed. Observing the tab also covers an empty new tab navigating to its first page.
private struct GuideBesideRender: View {
  @ObservedObject var tab: BrowserTab
  var body: some View {
    Color.clear
      .onAppear(perform: record)
      .onChange(of: tab.address) { record() }
  }
  private func record() {
    guard !RunMode.previewing, CurrentPageContext.shareable(tab.address),
      !tab.hiddenFromAgents else { return }
    GuideCenter.shared.record(.besideRendered)
  }
}
