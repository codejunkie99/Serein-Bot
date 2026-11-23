import AppKit
import Combine
import SereinCore
import SwiftUI
import WebKit

/// What the hologram does besides showing a state: a spoken word, a finished or failed job, a
/// preview of a state (look_show).
enum RelayAvatarEvent {
  case word(Double)
  case done
  case failed
  case preview(String, Double)
}

/// A delegated run as a satellite.
struct RelayAvatarJob: Equatable {
  let id: String
  let state: String
}

/// Relay's hologram (tools/avatar, bundled as Avatar/avatar.bundle.js) in a web view that holds
/// nothing else. The page is a fixed string with no base URL and a policy of no network; the
/// renderer is a user script from Serein's bundle; the data store is not persistent and every
/// navigation after the first is refused. Serein sends it a look that RelayLook validated, the
/// state and the jobs; the page sends back only taps.
@MainActor final class RelayAvatarEngine: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  static let script: String? = Bundle.assets.url(forResource: "avatar.bundle", withExtension: "js", subdirectory: "Avatar")
    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
  static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}\
    #stage{position:fixed;inset:0;cursor:grab;-webkit-user-select:none;user-select:none;touch-action:none}#stage:active{cursor:grabbing}</style>
    </head><body><div id="stage"></div></body></html>
    """
  /// A frame-rate ceiling for measurements (SEREIN_AVATAR_FPS in debug builds); 0 is none.
  static var maxFps: Int {
    #if DEBUG
    return Int(ProcessInfo.processInfo.environment["SEREIN_AVATAR_FPS"] ?? "") ?? 0
    #else
    return 0
    #endif
  }
  /// A pixel density for measurements (SEREIN_AVATAR_DPR in debug builds); 0 is the display's.
  static var pixelRatio: Double {
    #if DEBUG
    return Double(ProcessInfo.processInfo.environment["SEREIN_AVATAR_DPR"] ?? "") ?? 0
    #else
    return 0
    #endif
  }
  /// No WebGL or no renderer: the stage shows Relay's symbol instead.
  @Published private(set) var failed = false
  /// The renderer is running and has the current look and state.
  @Published private(set) var ready = false
  private(set) var web: AvatarWebView!
  var onTap: () -> Void = {}
  /// A steady frame-rate floor while it moves (0 is the renderer's own); set before it starts.
  var minFps = 0
  /// A still frame (UI previews with reduced effects).
  var still = false
  private var loaded = false
  private var restarts = 0
  private var wanted: (state: String, look: RelayLook, jobs: [RelayAvatarJob], active: Bool, light: Bool, paused: Bool) = ("idle", .serein, [], true, false, false)
  private var sent: (state: String?, look: RelayLook?, jobs: [RelayAvatarJob]?, active: Bool?, light: Bool?, paused: Bool?) = (nil, nil, nil, nil, nil, nil)
  private var watches: [AnyCancellable] = []
  private var windowWatches: [NSObjectProtocol] = []
  /// The stage's window is minimized or fully covered: nobody sees it, so it holds still.
  private(set) var windowHidden = false

  /// Every hologram on screen, for UI preview captures.
  private static let all = NSHashTable<RelayAvatarEngine>.weakObjects()
  /// The holograms in `window` and their current frames, in window coordinates. Their web views
  /// are hidden until `restore` runs, so a capture of the window draws only the frames (the
  /// view itself is transparent on screen; an in-process capture would paint it white).
  static func frames(in window: NSWindow) async -> (frames: [(NSRect, Data)], restore: () -> Void) {
    var out: [(NSRect, Data)] = []
    var hidden: [AvatarWebView] = []
    // A hologram still starting (a busy Mac) gets a few seconds before the capture.
    let shown = all.allObjects.filter { $0.web.window === window && !$0.web.isHiddenOrHasHiddenAncestor }
    let deadline = Date().addingTimeInterval(15)
    while shown.contains(where: { !$0.ready && !$0.failed }) && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    for engine in shown where engine.ready {
      if let png = await engine.snapshot() { out.append((engine.web.convert(engine.web.bounds, to: nil), png)) }
      engine.web.isHidden = true
      hidden.append(engine.web)
    }
    return (out, { hidden.forEach { $0.isHidden = false } })
  }
  /// Waits (up to 15 seconds) until every hologram in `window` has drawn, so a native capture
  /// (`--ui-hologram` previews) shows the light, not the empty stage it starts as.
  static func settle(in window: NSWindow) async {
    let deadline = Date().addingTimeInterval(15)
    func starting() -> Bool {
      all.allObjects.contains { $0.web.window === window && !$0.web.isHiddenOrHasHiddenAncestor && !$0.ready && !$0.failed }
    }
    while starting() && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    if Date() < deadline { try? await Task.sleep(nanoseconds: 500_000_000) }
  }
  /// The web view draws no background of its own (checks).
  var transparent: Bool { (web.value(forKey: "drawsBackground") as? Bool) == false }

  override init() {
    super.init()
    Self.all.add(self)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.preferences.isElementFullscreenEnabled = false
    config.mediaTypesRequiringUserActionForPlayback = .all
    let content = WKUserContentController()
    if let script = Self.script {
      content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
    }
    content.add(WeakMessageHandler(self), contentWorld: .page, name: "avatar")
    config.userContentController = content
    let web = AvatarWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: config)
    web.engine = self
    // Transparent, so the light floats over the panel's glass. Key-value coding finds WebKit's
    // _setDrawsBackground:; the check makes sure it took.
    if ["setDrawsBackground:", "_setDrawsBackground:"].contains(where: { web.responds(to: NSSelectorFromString($0)) }) {
      web.setValue(false, forKey: "drawsBackground")
    }
    web.allowsMagnification = false
    web.allowsBackForwardNavigationGestures = false
    web.allowsLinkPreview = false
    web.navigationDelegate = self
    web.uiDelegate = self
    web.setAccessibilityElement(false)
    #if DEBUG
    if #available(macOS 13.3, *) { web.isInspectable = true }
    #endif
    self.web = web
    failed = Self.script == nil
    if !failed { web.loadHTMLString(Self.page, baseURL: nil) }
  }

  /// What the hologram should show; only what changed reaches the page. `light`: the view sits
  /// on a light background, where the light is drawn as colored ink.
  /// `paused`: another hologram shows the same thing (the panel over the column); this one holds still.
  func update(state: RelayLook.State, look: RelayLook, jobs: [RelayAvatarJob], light: Bool = false, paused: Bool = false) {
    wanted.state = state.rawValue
    wanted.look = look
    wanted.jobs = Array(jobs.prefix(8))
    wanted.light = light
    wanted.paused = paused
    flush()
  }
  /// Live voice level and events from Relay's panel.
  func attach(_ controller: RelayController) {
    guard watches.isEmpty else { return }
    // The voice level at most 15 times a second, and only when it moved: the renderer smooths it.
    controller.dictation.meter.$level.combineLatest(controller.dictation.$recording)
      .map { level, recording in recording ? (Double(level) * 20).rounded() / 20 : 0 }
      .removeDuplicates()
      .throttle(for: .milliseconds(66), scheduler: RunLoop.main, latest: true)
      .sink { [weak self] level in self?.call("relayAvatar.setLevel(v)", ["v": level]) }
      .store(in: &watches)
    controller.avatarEvents.receive(on: RunLoop.main).sink { [weak self] event in self?.send(event) }.store(in: &watches)
  }
  func send(_ event: RelayAvatarEvent) {
    switch event {
    case .word(let strength): call("relayAvatar.pulse(v)", ["v": strength])
    case .done: call("relayAvatar.event('done')")
    case .failed: call("relayAvatar.event('error')")
    case .preview(let state, let seconds): call("relayAvatar.preview(s, n)", ["s": state, "n": seconds])
    }
  }
  /// What the renderer reports about itself (checks).
  func info() async -> [String: Any] {
    (try? await web.callAsyncJavaScript("return window.relayAvatar ? relayAvatar.info() : null", arguments: [:], in: nil, contentWorld: .page)) as? [String: Any] ?? [:]
  }
  /// A frame as PNG data (checks and previews).
  func snapshot() async -> Data? {
    guard let url = (try? await web.callAsyncJavaScript("return window.relayAvatar ? relayAvatar.snapshot() : null", arguments: [:], in: nil, contentWorld: .page)) as? String,
      let comma = url.firstIndex(of: ",")
    else { return nil }
    return Data(base64Encoded: String(url[url.index(after: comma)...]))
  }

  private func flush() {
    guard ready else { return }
    if sent.look != wanted.look {
      call("relayAvatar.setLook(look)", ["look": wanted.look.json])
      sent.look = wanted.look
    }
    if sent.state != wanted.state {
      call("relayAvatar.setState(s)", ["s": wanted.state])
      sent.state = wanted.state
    }
    if sent.jobs != wanted.jobs {
      call("relayAvatar.setJobs(jobs)", ["jobs": wanted.jobs.map { ["id": $0.id, "state": $0.state] }])
      sent.jobs = wanted.jobs
    }
    if sent.active != wanted.active {
      call("relayAvatar.setActive(on)", ["on": wanted.active])
      sent.active = wanted.active
    }
    if sent.light != wanted.light {
      call("relayAvatar.setTheme(t)", ["t": wanted.light ? "light" : "dark"])
      sent.light = wanted.light
    }
    // A window nobody can see (minimized, or covered by other windows) holds still too.
    let holdStill = wanted.paused || windowHidden
    if sent.paused != holdStill {
      call("relayAvatar.setPaused(on)", ["on": holdStill])
      sent.paused = holdStill
    }
  }
  private func call(_ body: String, _ arguments: [String: Any] = [:]) {
    guard ready else { return }
    web.callAsyncJavaScript("if (window.relayAvatar) { \(body) }", arguments: arguments, in: nil, in: .page) { _ in }
  }
  private func boot() {
    let config: [String: Any] = [
      "look": wanted.look.json, "state": wanted.state, "transparent": true, "still": still, "active": wanted.active,
      "theme": wanted.light ? "light" : "dark",
      "maxFps": Self.maxFps, "minFps": minFps, "pixelRatio": Self.pixelRatio,
      "quality": ProcessInfo.processInfo.isLowPowerModeEnabled ? "low" : "high",
      "reducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
    ]
    web.callAsyncJavaScript(
      "return window.RelayAvatar ? RelayAvatar.boot(config) : false", arguments: ["config": config], in: nil, in: .page
    ) { [weak self] result in
      guard let self else { return }
      guard case .success(let value) = result, (value as? Bool) == true else {
        self.failed = true
        return
      }
      self.sent = (self.wanted.state, self.wanted.look, nil, self.wanted.active, self.wanted.light, nil)
      self.ready = true
      self.flush()
    }
  }

  // MARK: hosts: the stages showing this engine (one web view, the newest stage wins)

  private var hosts: [Weak<AvatarWebContainer>] = []
  /// A stage shows this engine right now.
  var hosted: Bool { hosts.contains { $0.value != nil } }
  /// Called when the first stage arrives (true) or the last one leaves (false), so the owner can
  /// let go of an engine nobody shows (SereinSurface).
  var onHostsChanged: ((Bool) -> Void)?
  /// A new stage takes the web view.
  func claim(_ container: AvatarWebContainer) {
    hosts.removeAll { $0.value == nil || $0.value === container }
    hosts.append(Weak(container))
    place()
    onHostsChanged?(true)
  }
  /// The newest stage keeps the web view; an older one never takes it back.
  func adopt(into container: AvatarWebContainer) {
    guard hosts.last?.value === container else { return }
    place()
  }
  /// A stage left: the web view moves to the newest one still there, or leaves the window.
  func release(_ container: AvatarWebContainer) {
    hosts.removeAll { $0.value == nil || $0.value === container }
    if web.superview === container { web.removeFromSuperview() }
    place()
    if !hosted { onHostsChanged?(false) }
  }
  private func place() {
    guard let host = hosts.last?.value, web.superview !== host else { return }
    web.removeFromSuperview()
    web.frame = host.bounds
    web.autoresizingMask = [.width, .height]
    host.addSubview(web)
  }

  // MARK: window activity: a hologram behind other apps draws fewer frames

  func windowChanged(_ window: NSWindow?) {
    windowWatches.forEach(NotificationCenter.default.removeObserver)
    windowWatches = []
    guard let window else {
      // No stage shows it (Serein hidden, the hologram turned off, or a page with the column
      // off): the renderer holds still. Its owner lets go of it after a minute with no stage
      // (SereinSurface.engine), which ends its web content process; until then showing Serein
      // again is instant.
      windowHidden = true
      flush()
      return
    }
    wanted.active = Self.inFront(window)
    windowHidden = Self.unseen(window)
    flush()
    let center = NotificationCenter.default
    let refresh: @Sendable (Notification) -> Void = { [weak self, weak window] _ in
      MainActor.assumeIsolated {
        self?.activityChanged(window)
        // The key window settles after the notification (a sheet or popover taking the keyboard
        // from its own window): look again on the next turn.
        DispatchQueue.main.async { self?.activityChanged(window) }
      }
    }
    windowWatches.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: refresh))
    // Any window taking the keyboard: this one, one of its sheets or popovers, or another window.
    windowWatches.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: refresh))
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      windowWatches.append(center.addObserver(forName: name, object: nil, queue: .main, using: refresh))
    }
    for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                 NSWindow.didDeminiaturizeNotification] {
      windowWatches.append(center.addObserver(forName: name, object: window, queue: .main, using: refresh))
    }
  }
  /// Minimized, closed (ordered out, which is how Serein hides its window), not visible at all
  /// (another window covers all of it), or not key (the keyboard is in another app or another
  /// window). A sheet or popover of this window holding the keyboard still counts as this
  /// window. The floating hologram over every app is never counted as unseen. Each change
  /// arrives as an occlusion or key change, so the engine wakes when it shows again.
  private static func unseen(_ window: NSWindow) -> Bool {
    if window.isMiniaturized { return true }
    guard window.level < .floating else { return false }
    if !window.isVisible || !window.occlusionState.contains(.visible) { return true }
    return !holdsKeyboard(window)
  }
  /// The key window is `window` or a sheet or child window of it.
  private static func holdsKeyboard(_ window: NSWindow) -> Bool {
    var key = NSApp.keyWindow
    while let current = key {
      if current === window { return true }
      key = current.sheetParent ?? current.parent
    }
    return false
  }

  /// In front of the user: Serein is the active app, its window has the keyboard, or it floats
  /// above every app (⌥Space's hologram, which never takes the keyboard and is paused when put away).
  private static func inFront(_ window: NSWindow) -> Bool {
    NSApp.isActive || window.isKeyWindow || window.level >= .floating
  }
  /// `--ui-hologram` previews capture a window that is never key (it opens in the background):
  /// its holograms count as seen, so the light is drawn for the capture.
  private static let previewSeen = CommandLine.arguments.contains("--ui-preview") && CommandLine.arguments.contains("--ui-hologram")
  private func activityChanged(_ window: NSWindow?) {
    wanted.active = window.map { Self.previewSeen || Self.inFront($0) } ?? false
    windowHidden = window.map { !Self.previewSeen && Self.unseen($0) } ?? true
    flush()
  }

  // MARK: the page: one load, no navigation, no windows, taps only

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let first = !loaded && action.request.url?.absoluteString == "about:blank" && action.targetFrame?.isMainFrame == true
    decisionHandler(first ? .allow : .cancel)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !loaded else { return }
    loaded = true
    boot()
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ready = false
    loaded = false
    sent = (nil, nil, nil, nil, nil, nil)
    restarts += 1
    // Twice is enough: after that the symbol stands in.
    if restarts <= 2 { webView.loadHTMLString(Self.page, baseURL: nil) } else { failed = true }
  }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    switch type {
    case "tap": onTap()
    case "error": failed = true
    default: break
    }
  }
}

/// WKUserContentController keeps its handlers; this one does not keep the engine.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: RelayAvatarEngine?
  init(_ target: RelayAvatarEngine) { self.target = target }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
  }
}

/// The hologram's web view never takes the keyboard from Relay's composer, and scrolling over
/// it scrolls what is behind.
final class AvatarWebView: WKWebView {
  weak var engine: RelayAvatarEngine?
  override var acceptsFirstResponder: Bool { false }
  override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    engine?.windowChanged(window)
  }
  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    menu.removeAllItems()
    super.willOpenMenu(menu, with: event)
  }
}

/// A weak reference in a list.
private struct Weak<Value: AnyObject> {
  weak var value: Value?
  init(_ value: Value) { self.value = value }
}

/// Each stage gets its own container; the engine's one web view lives in the newest container
/// still on screen. Serein full and beside share one engine, and a switch (hero → strip, full ⇄
/// beside) briefly mounts two stages: the web view moves to the new one and, if that one goes
/// first, back to the one that stays. It never leaves a live stage blank.
final class AvatarWebContainer: NSView {
  weak var engine: RelayAvatarEngine?
  override var isFlipped: Bool { true }
}

private struct AvatarWebHost: NSViewRepresentable {
  let engine: RelayAvatarEngine
  func makeNSView(context: Context) -> AvatarWebContainer {
    let container = AvatarWebContainer(frame: .zero)
    container.engine = engine
    engine.claim(container)
    return container
  }
  func updateNSView(_ container: AvatarWebContainer, context: Context) {
    engine.adopt(into: container)
  }
  static func dismantleNSView(_ container: AvatarWebContainer, coordinator: ()) {
    container.engine?.release(container)
  }
}

/// Relay's hologram on a stage: the panel's hero, its strip while chatting, the column, and the
/// look preview in Settings. A tap talks to Relay. Without WebGL it is Relay's symbol.
/// `engine`: the window's one engine (SereinSurface), shared by Serein full and beside; without
/// one the stage makes its own when it first appears.
struct RelayAvatarStage: View {
  let state: RelayLook.State
  let look: RelayLook
  var jobs: [RelayAvatarJob] = []
  /// Live voice and events (the panel and column); nil for a preview.
  var controller: RelayController?
  /// Hold still: the floating panel shows the same hologram over this one.
  var paused = false
  /// A steady frame-rate floor (⌥Space's floating hologram moves at 60 while it is shown).
  var minFps = 0
  /// Floats over other apps (⌥Space): drawn for macOS's appearance, not Serein's own.
  var overOtherApps = false
  var engine: RelayAvatarEngine? = nil
  var onTap: () -> Void = {}
  @StateObject private var own = OwnAvatarEngine()

  var body: some View {
    RelayAvatarStageBody(
      engine: engine ?? own.engine, state: state, look: look, jobs: jobs, controller: controller,
      paused: paused, minFps: minFps, overOtherApps: overOtherApps, onTap: onTap)
  }
}

/// A stage's own engine, made only when the stage has no shared one.
@MainActor private final class OwnAvatarEngine: ObservableObject {
  lazy var engine = RelayAvatarEngine()
}

private struct RelayAvatarStageBody: View {
  @ObservedObject var engine: RelayAvatarEngine
  let state: RelayLook.State
  let look: RelayLook
  let jobs: [RelayAvatarJob]
  let controller: RelayController?
  let paused: Bool
  let minFps: Int
  let overOtherApps: Bool
  let onTap: () -> Void
  @Environment(\.sereinReducedEffects) private var reducedEffects
  @Environment(\.palette) private var p

  var body: some View {
    ZStack {
      if engine.failed {
        SereinMark(size: 22)
      } else {
        AvatarWebHost(engine: engine).opacity(engine.ready ? 1 : 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onAppear { sync() }
    .onChange(of: state) { sync() }
    .onChange(of: look) { sync() }
    .onChange(of: jobs) { sync() }
    .onChange(of: p.isDark) { sync() }
    .onChange(of: paused) { sync() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Serein, \(state.title.lowercased())")
    .accessibilityHint("Talks to Serein")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onTap() }
  }
  private func sync() {
    engine.still = reducedEffects
    engine.minFps = minFps
    engine.onTap = onTap
    if let controller { engine.attach(controller) }
    // Read on each sync, which every summon causes (`paused`), so a change in macOS is picked up.
    let macIsDark: Bool = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    let ink: Bool = AppearanceScheme.hologramInk(sereinIsDark: p.isDark, macIsDark: macIsDark, overOtherApps: overOtherApps)
    engine.update(state: state, look: look, jobs: jobs, light: ink, paused: paused)
  }
}
