import Network
import os
import SereinCore
import SereinEngines
import SwiftUI
import WebKit

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate
{
  let id = UUID().uuidString
  /// Replaced by an empty view when the page is discarded (`discardPage`).
  @Published private(set) var web: WKWebView
  let privateMode: Bool
  /// The agent task that opened this tab; nil once it is the user's (see `takeOver`).
  var owner: String?
  /// Set when the user took this tab over from an agent, e.g. "Taken over from Codex · isolated".
  var takenFrom: String?
  /// Who worked in this tab before it became the user's (status bar, banner, Open task).
  var agentMark: TabAgentMark?
  let ext = TabExtras()
  @Published var sleeping = false
  var sleepingAddress: String?
  /// The back and forward list and scroll position of the page a sleeping tab dropped.
  var sleepingState: Any?
  /// The page refused a close (unsaved work), so the tab stays awake until it is next opened.
  var keepsAwake = false
  /// Set from `wake` until the restored page has loaded; see the form check in `decidePolicyFor`.
  var wakingAddress: String?
  /// The page, or a frame in it, is the answer to a sent form. It cannot be fetched again, so
  /// the tab does not sleep by itself, and `unload` does not keep its history.
  var formResult = false
  var formPending = false
  /// Forms a frame sent that have no answer yet. An answer at the same address is a form result;
  /// a redirect answers at another address, and that page can be fetched again.
  var frameForms = Set<URL>()
  /// What a sleeping tab had in sessionStorage and `window.name`, as the script that puts it
  /// back (`wake`). WebKit keeps both with the web view, which sleep replaces.
  var sleepingStorage: String?
  var wakeScript: String?
  var openerID: String?
  /// The tab whose script opened this one with `window.open`, as a sign-in button does. The two
  /// pages talk through `window.opener`, so neither sleeps while both are open.
  weak var opener: BrowserTab?
  /// WebKit made this page for another page (a popup or a link with target=_blank).
  let openedByPage: Bool
  /// A script opened this page with `window.open` (a sign-in window). Only such a page can close
  /// its tab with `window.close()`. WebKit also lets a page close a tab that has one history
  /// entry, such as a meeting link with target=_blank from a calendar: that tab is the user's.
  var openedByScript = false
  /// Set on View Source tabs: their text is another page's raw markup, so agents never read it
  /// (not as page context, not as a shared tab).
  var isSourceView = false
  /// Never shown to an agent: a source view, or a page on a site the person set to Never.
  var hiddenFromAgents: Bool { isSourceView || SiteRules.rule(for: sleepingAddress ?? address) == .never }
  var sleepingTitle = ""
  var lastActive = Date()
  @Published var title = "New tab"
  @Published var address = ""
  /// Bumped when the top frame navigates, or when the frame holding an approved element does.
  var pageVersion = "0"
  /// Sub-frames that hold an element a person approved. Other frames do not move `pageVersion`.
  var approvalFrames: [WKFrameInfo] = []
  private static let frameLog = Logger(subsystem: "app.serein", category: "page")
  /// Link clicks, form submits, redirects, loads and in-app route changes each take a new version.
  func noteNavigation(because reason: String) {
    pageVersion = PageVersion.advance(pageVersion, because: reason)
  }
  /// Remember the frame that holds the element just approved. The top frame is already watched.
  func noteApprovedElement(_ frame: WKFrameInfo?) {
    guard let frame, !frame.isMainFrame else { return }
    if approvalFrames.contains(where: { $0 === frame }) { return }
    approvalFrames.append(frame)
  }
  /// A main-frame navigation, or a navigation of a watched frame, makes the yes stale.
  /// Every other frame is logged and leaves the yes in place.
  func noteFrameChange(_ frame: WKFrameInfo?, because reason: String, url: String = "", blankChild: Bool = false) {
    let main = frame?.isMainFrame == true
    let holds = frame.map { item in
      approvalFrames.contains { $0 === item || $0.isEqual(item) }
    } ?? false
    let decision = FrameBump.decide(mainFrame: main, holdsApprovedElement: holds, blankChild: blankChild)
    if decision.bumps {
      if main { approvalFrames.removeAll() }
      noteNavigation(because: reason)
    } else if decision.logged {
      Self.frameLog.info("Frame navigation left the approval in place: \(url, privacy: .public)")
    }
  }
  private func navigationReason(_ type: WKNavigationType) -> String {
    switch type {
    case .linkActivated: return "link"
    case .formSubmitted, .formResubmitted: return "form"
    case .backForward: return "history"
    case .reload: return "reload"
    case .other: return "navigation"
    @unknown default: return "navigation"
    }
  }
  @Published var loading = false
  @Published var error: String?
  /// Where the agent is about to act, in the web view's coordinates; nil when the pointer is
  /// hidden. `agentPointerPulse` rings once per action (AgentPointer in Views.swift).
  @Published var agentPointer: CGPoint?
  @Published var agentPointerPulse = 0
  private var agentPointerHide: Task<Void, Never>?
  /// Glides the pointer to `point` (600 ms), rings, and hides it 2.5 s after the last action.
  func pointAgent(at point: CGPoint) async {
    // A tab that is not on screen has no one to follow the pointer, so it acts at once.
    guard let shown = web.window, !PageAX.isHost(shown) else { return }
    if agentPointer == nil {
      agentPointer = CGPoint(x: point.x + 160, y: point.y + 120)
      try? await Task.sleep(nanoseconds: 30_000_000)
    }
    agentPointer = point
    // Under Reduce Motion the pointer jumps there; a short pause still shows the spot.
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    try? await Task.sleep(nanoseconds: reduce ? 150_000_000 : 650_000_000)
    agentPointerPulse += 1
    agentPointerHide?.cancel()
    agentPointerHide = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      if !Task.isCancelled { self?.agentPointer = nil }
    }
  }
  var onVisit: ((BrowserTab, String) -> Void)?
  /// A page opened a popup: the new tab, whether it comes to the front, and the URL it was
  /// created for (the navigation has not started, so the tab's own address is not set yet).
  var onPopup: ((BrowserTab, Bool, URL?) -> Void)?
  /// A Shift-hovered link: Serein previews it in a split's other pane, when one is open.
  var onPreviewLink: ((URL) -> Void)?
  /// A step the person took while recording this tab (Show me once): PageKit's JSON, main frame only.
  var onUserStep: ((String) -> Void)?
  /// A window the page wanted to open too long after the person's last input (PopupPolicy).
  var onBlockedPopup: ((URL) -> Void)?
  /// The person's last click or activation key in this tab (BrowserModel's input monitor), until a
  /// window opens on it. An agent's clicks are page events and never set it.
  var lastInput: Date?
  /// A popup closed itself (`window.close()`), for example at the end of a sign-in.
  var onClose: ((BrowserTab) -> Void)?
  /// True while a live agent task drives this tab (also the user's own tab, in a page task).
  var inTask: (() -> Bool)?
  /// The addresses an outside agent's tab may load (OutsideAgents); nil allows every address.
  var allowsNavigation: ((URL) -> Bool)?
  /// Sites turned off for the assistant whose task drives this tab (AssistantScope): refused like
  /// the person's Never rules, before anything loads.
  var assistantBlocks: ((URL) -> Bool)?
  /// The address of a load refused by a Never site rule while an agent drove this tab; the next
  /// read reports it (`BrowserModel.checkSiteRule`).
  var ruleBlocked: String?
  /// That refused load was on a site turned off for the tab's assistant, not the person's rule.
  var ruleBlockedByAssistant = false
  var darkObserver: NSObjectProtocol?
  var frames: [String: WKFrameInfo] = [:]
  /// The page's open network requests, for `settle`.
  let network = NetworkWatch()
  /// False from the start of a navigation until its new document commits, so `settle` does not
  /// read the old page's state as the new one's.
  var documentCommitted = true
  private var observations: [NSKeyValueObservation] = []
  static let world = WKContentWorld.world(name: "SereinPageReader")
  /// PageKit.js, read once. Without it agents cannot read pages, but tabs still browse.
  static let pageKit: String = {
    guard let url = Bundle.assets.url(forResource: "PageKit", withExtension: "js"),
      let source = try? String(contentsOf: url)
    else {
      FileHandle.standardError.write(
        Data("Serein: PageKit.js is missing from the app; agents cannot read pages.\n".utf8))
      return ""
    }
    return SensitiveFields.script(source)
  }()
  /// PageNav.js, read once. It wraps history at document start in the page world, in every frame.
  static let pageNav: String = {
    guard let url = Bundle.assets.url(forResource: "PageNav", withExtension: "js"),
      let source = try? String(contentsOf: url)
    else {
      FileHandle.standardError.write(
        Data("Serein: PageNav.js is missing from the app; route changes can keep an old approval.\n".utf8))
      return ""
    }
    return source
  }()
  /// "Version/<installed Safari> Safari/605.1.15", read once from Safari's Info.plist.
  static let safariAgentSuffix: String = {
    let plist = "/Applications/Safari.app/Contents/Info.plist"
    let version = (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String)
    return UserAgent.safariSuffix(version: version)
  }()
  /// `openedWith` is the configuration WebKit gives for a popup (`createWebViewWith`). The page
  /// must be made with it: it links the popup to its opener and keeps the opener's data store.
  init(
    privateMode: Bool = false, owner: String? = nil, store: WKWebsiteDataStore? = nil,
    openedWith: WKWebViewConfiguration? = nil
  ) {
    self.privateMode = privateMode
    self.owner = owner
    openedByPage = openedWith != nil
    let config = openedWith ?? WKWebViewConfiguration()
    if openedWith != nil {
      // WebKit's copy shares the opener's script controller, which already has this tab's
      // message handlers; adding them again raises an exception. The popup gets its own.
      config.userContentController = WKUserContentController()
    } else {
      config.websiteDataStore =
        store ?? (privateMode ? .nonPersistent() : StressDriver.store ?? .default())
    }
    // Read as the installed Safari: without the Version/Safari tail, Google and others serve
    // their basic pages to "an old browser".
    config.applicationNameForUserAgent = BrowserTab.safariAgentSuffix
    // Every window a page opens reaches createWebViewWith, which decides (PopupPolicy). With
    // this off, WebKit drops a sign-in window opened after a network step without a word.
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    BrowserMedia.configure(config)
    config.userContentController.addUserScript(
      WKUserScript(
        source: Self.pageNav, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    config.userContentController.addUserScript(
      WKUserScript(
        source: Self.pageKit, injectionTime: .atDocumentEnd, forMainFrameOnly: false,
        in: Self.world))
    config.userContentController.addUserScript(PagePointer.userScript)
    config.userContentController.addUserScript(
      WKUserScript(
        source: Self.draftWatch, injectionTime: .atDocumentStart, forMainFrameOnly: false,
        in: Self.world))
    config.userContentController.addUserScript(
      WKUserScript(
        source: Self.baseShim(denyNotifications: privateMode || owner != nil),
        injectionTime: .atDocumentStart, forMainFrameOnly: false))
    // Agent tabs dial through a connect proxy when one is set (the verification harness sets one).
    // A user tab never does. The default store is the user's: writing the proxy onto it would
    // steer their tabs.
    if let proxy = ConnectProxy.webKitConfiguration(),
      AgentTabGate.maySetProxy(
        owner: owner,
        openedWith: openedWith != nil,
        defaultStore: config.websiteDataStore === WKWebsiteDataStore.default()
      )
    {
      config.websiteDataStore.proxyConfigurations = [proxy]
    }
    web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 750), configuration: config)
    super.init()
    let bridge = FrameBridge(tab: self)
    config.userContentController.add(bridge, contentWorld: Self.world, name: "sereinFrame")
    config.userContentController.add(PageNavBridge(tab: self), name: "sereinNav")
    PasswordCapture.install(on: self, controller: config.userContentController)
    SiteFeatureBridge.install(on: self, controller: config.userContentController)
    ConsoleWatch.install(on: self, controller: config.userContentController)
    PageToolRegistry.install(on: self, controller: config.userContentController)
    wire()
    darkObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name("SereinDarkPagesChanged"), object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in await self?.applyDarkPage() } }
  }
  /// Binds the tab to its current web view; runs again when `discardPage` replaces the view.
  private func wire() {
    ext.bind(web)
    ContentBlocking.shared.attach(web)
    network.attach(web)
    // Match Safari's two-finger trackpad swipe for the current tab's back/forward history.
    web.allowsBackForwardNavigationGestures = true
    web.navigationDelegate = self
    web.uiDelegate = self
    // The page follows the app's appearance (prefers-color-scheme) through the window.
    web.underPageBackgroundColor = Palette.dynamic(\.background)
    observations = [
      web.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.refreshLoading(from: w) }
      },
      web.observe(\.title, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.refreshTitle(from: w) }
      },
      web.observe(\.url, options: [.new]) { [weak self] w, _ in
        Task { @MainActor in self?.refreshAddress(from: w) }
      },
    ]
  }
  // KVO deliveries can already be queued when discardPage replaces the view. Only the
  // current page may update tab chrome; equal values need no SwiftUI invalidation.
  func refreshLoading(from page: WKWebView) {
    guard web === page, loading != page.isLoading else { return }
    loading = page.isLoading
  }
  func refreshTitle(from page: WKWebView) {
    guard web === page, !sleeping else { return }
    let value = page.title ?? "New tab"
    if title != value { title = value }
  }
  func refreshAddress(from page: WKWebView) {
    guard web === page, !sleeping else { return }
    let shown = Self.visibleAddress(page.url)
    // A failed pre-commit load keeps its attempted address for retry and session restore.
    if shown.isEmpty, error != nil { return }
    if address != shown { address = shown }
  }
  /// Ends the page and its WebKit process now. The tab keeps an empty web view, which has no
  /// process until something loads in it. A window that is not on screen holds the views of a
  /// closed tab until it next draws, so the page cannot wait for the tab to be freed.
  func discardPage() {
    PageAX.release(self)
    endWake()
    web.closeAllMediaPresentations(completionHandler: nil)
    web.stopLoading()
    web.navigationDelegate = nil
    web.uiDelegate = nil
    (web.superview as? WebHostContainer)?.detach()
    frames.removeAll()
    loading = false
    web = WKWebView(frame: web.frame, configuration: web.configuration)
    wire()
  }
  func navigate(_ value: String) throws {
    let u = try BrowserPolicy.url(value)
    error = nil
    ruleBlocked = nil
    address = u.absoluteString
    approvalFrames.removeAll()
    noteNavigation(because: "load")
    // WebKit reports the start a moment later; until then the old document would read as ready.
    // A new fragment on the same page stays in the document and never commits, so it is left out.
    let base = { (url: URL?) in url?.absoluteString.split(separator: "#", maxSplits: 1).first }
    if !(u.fragment != nil && base(u) == base(web.url)) { documentCommitted = false }
    web.load(URLRequest(url: u))
  }
  func navigationFailed(_ error: Error) {
    let ns = error as NSError
    loading = false
    // No new document is coming; the one shown is the one to read. A cancel can come from a newer
    // navigation that is already loading; that one still commits.
    if ns.code != NSURLErrorCancelled || !web.isLoading { documentCommitted = true }
    // WebKit cancels its cache lookup for a form result before it asks to send the form again.
    if ns.code != NSURLErrorCancelled { endWake() }
    let failing = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? web.url
    guard let page = ErrorCopy.page(domain: ns.domain, code: ns.code, host: failing?.host) else {
      return
    }
    self.error = page.detail
    // The blank page can arrive before the failure does.
    if address.isEmpty, let tried = failing.map(Self.visibleAddress), !tried.isEmpty {
      address = tried
    }
    // The error page replaces the old page; its console errors no longer belong to it.
    ConsoleWatchStore.shared.reset(id)
    ext.showError(page, url: failing)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard web === webView else { return }
    navigationFailed(error)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard web === webView else { return }
    navigationFailed(error)
  }
  func webView(
    _ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
  ) {
    guard web === webView else { return }
    approvalFrames.removeAll()
    noteNavigation(because: "redirect")
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard web === webView else { return }
    documentCommitted = false
    frames.removeAll()
    // The site icon shows from the cache, or is requested, while the page is still loading.
    FaviconStore.shared.navigationStarted(self, url: webView.url)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard web === webView else { return }
    endWake()
    guard !sleeping else { return }
    Task {
      guard self.web === webView, !sleeping else { return }
      await applyDarkPage()
      guard self.web === webView, !sleeping else { return }
      let captured = await ComposerContext.capture(self)
      guard self.web === webView, !sleeping else { return }
      if !captured.unavailable { onVisit?(self, captured.sensitive ? "" : captured.text) }
      await FaviconStore.shared.refresh(self)
    }
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    // An inline frame (`srcdoc`) is part of its page, not another address. Without this its
    // document was cancelled and the frame stayed empty.
    guard let u = navigationAction.request.url,
      (try? BrowserPolicy.url(u.absoluteString)) != nil || u.absoluteString == "about:blank"
        || (u.absoluteString == "about:srcdoc" && navigationAction.targetFrame?.isMainFrame == false)
    else {
      noCommit(navigationAction.targetFrame)
      decisionHandler(.cancel)
      return
    }
    // A redirect or a link out of an outside agent's sites does not load.
    if navigationAction.targetFrame?.isMainFrame != false, let allows = allowsNavigation, !allows(u),
      u.absoluteString != "about:blank"
    {
      noCommit(navigationAction.targetFrame)
      decisionHandler(.cancel)
      return
    }
    // A tab an agent drives never loads a site the person set to Never, a redirect or a frame
    // included. Only a main-frame load is reported; a refused frame stays empty.
    if owner != nil || inTask?() == true,
      SiteRules.rule(for: u.absoluteString) == .never || assistantBlocks?(u) == true
    {
      if navigationAction.targetFrame?.isMainFrame != false { ruleBlocked = u.absoluteString; ruleBlockedByAssistant = SiteRules.rule(for: u.absoluteString) != .never }
      noCommit(navigationAction.targetFrame)
      decisionHandler(.cancel)
      return
    }
    // A woken tab restores its history. If a page or a frame in it came from a sent form,
    // WebKit first looks in its cache and then asks to send the form again. Nothing is sent:
    // the tab loads its address instead, and a frame stays empty.
    if let address = wakingAddress, navigationAction.navigationType == .formResubmitted {
      decisionHandler(.cancel)
      if navigationAction.targetFrame?.isMainFrame != false {
        wakingAddress = nil
        try? navigate(address)
      }
      return
    }
    let sends = navigationAction.request.httpMethod?.uppercased() == "POST"
    if navigationAction.targetFrame?.isMainFrame == true {
      formPending = sends
    } else if sends, navigationAction.targetFrame != nil, let sent = navigationAction.request.url {
      frameForms.insert(sent)
    }
    // An agent tab's download goes to its task's shelf only while the person allows task downloads.
    let policy: WKNavigationActionPolicy =
      navigationAction.shouldPerformDownload ? (owner == nil || TaskShelf.takes(self) ? .download : .cancel) : .allow
    if policy != .allow { noCommit(navigationAction.targetFrame) }
    if policy == .allow {
      let frame = navigationAction.targetFrame
      let main = frame?.isMainFrame == true
      noteFrameChange(
        frame, because: main ? navigationReason(navigationAction.navigationType) : "frame",
        url: navigationAction.request.url?.absoluteString ?? "")
    }
    decisionHandler(policy)
  }
  /// A main-frame navigation cancelled by policy or turned into a download never commits and may
  /// not report a failure, so the page shown stays the one to read, as in navigationFailed. A
  /// navigation already loading still commits.
  private func noCommit(_ frame: WKFrameInfo?) {
    if frame?.isMainFrame == true, !web.isLoading { documentCommitted = true }
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    if !navigationResponse.isForMainFrame, let answered = navigationResponse.response.url,
      frameForms.remove(answered) != nil
    {
      formResult = true
    }
    let policy: WKNavigationResponsePolicy =
      navigationResponse.canShowMIMEType ? .allow : owner == nil || TaskShelf.takes(self) ? .download : .cancel
    // The main frame's answer is a download (or cancelled): its navigation ends without a commit.
    if policy != .allow, navigationResponse.isForMainFrame { documentCommitted = true }
    decisionHandler(policy)
  }
  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) { handOff(download) }
  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) { handOff(download) }
  /// The person's download goes to the Downloads list; an agent tab's to its task's shelf
  /// (TaskShelf), which cancels it unless the person allows task downloads.
  private func handOff(_ download: WKDownload) {
    if let owner { TaskShelf.shared.accept(download, task: owner) } else { DownloadCenter.shared.accept(download) }
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard owner == nil, let onPopup else { return nil }
    switch PopupPolicy.decide(sinceInput: lastInput.map { Date().timeIntervalSince($0) }) {
    // One input opens one window: the next one needs a new click.
    case .open: lastInput = nil
    case .offer:
      if let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" { onBlockedPopup?(url) }
      return nil
    case .block: return nil
    }
    // The returned page loads the request itself and keeps `window.opener`. Sign-in popups
    // (Apple, Google, Microsoft and others) send their result back through it; with no page
    // returned, `window.open` gives null and the sign-in fails.
    let popup = BrowserTab(privateMode: privateMode, openedWith: configuration)
    if navigationAction.navigationType != .linkActivated {
      popup.opener = self
      popup.openedByScript = true
    }
    let modifiers = navigationAction.modifierFlags
    // Command-click opens in the background; adding Shift keeps the new tab in front.
    onPopup(popup, !modifiers.contains(.command) || modifiers.contains(.shift), navigationAction.request.url)
    return popup.web
  }
  func webViewDidClose(_ webView: WKWebView) {
    guard webView === web, openedByPage, openedByScript else { return }
    // A page that uses the camera or microphone (a call) does not close its own tab.
    guard web.cameraCaptureState == .none, web.microphoneCaptureState == .none else { return }
    onClose?(self)
  }
  /// A page's upload button: the user picks the files in a sheet on the tab's window. A tab that
  /// an agent task owns or drives gets none: an agent's click counts as a user gesture, so it
  /// could open the panel on the user's window (PageKit refuses file inputs to agents too).
  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
  ) {
    guard owner == nil, inTask?() != true, let window = webView.window else { return completionHandler(nil) }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = true
    panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
  }
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    let key =
      "\(origin.protocol)://\(origin.host)"
      + (origin.port == 0 || (origin.protocol == "https" && origin.port == 443)
        || (origin.protocol == "http" && origin.port == 80) ? "" : ":\(origin.port)")
    decisionHandler(
      owner == nil && UserDefaults.standard.string(forKey: "serein.media." + key) == "ask"
        ? .prompt : .deny)
  }
  func applyDarkPage() async {
    guard !sleeping, web.url != nil,
      let path = Bundle.assets.url(forResource: "DarkPages", withExtension: "js"),
      let source = try? String(contentsOf: path)
    else { return }
    let setting = UserDefaults.standard.object(forKey: "serein.darkPages") as? Bool ?? true
    // Darken light webpages applies only while Serein itself is dark.
    let enabled = AppearanceController.shared.scheme.darkensPages(setting: setting)
    _ = try? await script(source + "\nglobalThis.__sereinDarkPages(\(enabled ? "true":"false"));")
  }
  deinit { if let darkObserver { NotificationCenter.default.removeObserver(darkObserver) } }
  func script(_ source: String, frame: WKFrameInfo? = nil) async throws -> Any {
    // A sleeping tab has no page, and a script would start a WebKit process for its empty view.
    guard !sleeping else { throw SereinError.invalid("This tab is asleep.") }
    return try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(source, in: frame, in: Self.world) { result in
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error):
          let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
          continuation.resume(throwing: SereinError.invalid(detail ?? error.localizedDescription))
        }
      }
    }
  }
}
struct SessionRecord: Codable {
  var urls: [String]
  var active: Int
  /// One per address; optional so older session files restore with every tab unpinned.
  var pinned: [Bool]?
  /// One per address, so a tab that has not loaded yet still shows its name.
  var titles: [String]?
  /// What the main view showed (`ShellSection`), so a launch comes back to it. Optional, so an
  /// older session file restores the selected tab as before.
  var section: String?
}
struct BrowserTask {
  /// Sites where this task's routine steps go ahead without a card (RoutineGrants), from its
  /// Allow for this task.
  var routineSites: Set<String> = []
  var capability: Capability
  var file: URL
  var isolated: Bool
  var allowActions: Bool
  var tabs: [BrowserTab]
  var store: WKWebsiteDataStore
  var allowMac = false
  /// Relay's own run: its orchestration tools (RelayTools) answer only for this task.
  var allowRelay = false
  /// The task of the agent that called this one (AppPeerHost): its standing and level are this task's.
  var caller: String?
  var finished = false
  /// An outside agent's sites (OutsideAgents): open and go refuse other addresses, and its tabs
  /// do not follow a redirect or link out of them.
  var allows: ((URL) -> Bool)?
  /// Clicks, types and selects in a row since the last do, for the fast-steps hint.
  var simpleActions = 0
  /// The one sign-in or pay press each tab's last secure card submit covers, keyed by tab id, so
  /// an action on another tab leaves it. Tab ids are never reused: a closed tab's pass covers nothing.
  var securePasses: [String: SecureCard.Pass] = [:]
  /// The repl tool's JavaScript context, kept for the task so values persist between calls.
  var repl: Repl?
  /// The tab of the latest call, where a repl program's `page` starts, and the last page each tab
  /// returned, so a program resolves refs the model saw outside it.
  var lastTab: String?
  var pages: [String: [String: Any]] = [:]
  /// Asks already shown for this task. A repeat for the same element and effect is one ask.
  var pendingApprovals: [ApprovalGate.ActionIntent] = []
  /// Sites whose consent overlay Serein already answered (or tried to) for this task: once each.
  var consentHosts: Set<String> = []
  /// Each tab's latest screenshot for click_point (PointClickBridge), in memory; one click each.
  var shots: [String: PointClick.Shot] = [:]
  /// Set for a paired outside app. One task, the sites it started on, gone when the task ends.
  var pass: TaskPass?
  /// Sites whose kept sign-in this task already used or was refused (useKeptSignIn): once each.
  var keptAsked: Set<String> = []
  /// The Mac script shown for approval. `MacScriptRun` hashes the source before the ask and
  /// hashes this slot again before the run. A difference refuses the run.
  var scriptToRun: String?
  /// Writes through connected apps since the person last allowed more (ConnectedApps.writeLimit).
  var appWrites = 0
  /// The connected apps the run `appRun` already called, for the outside-content rule
  /// (OutsideContent.swift); a new run on the task starts with none.
  var appRun = ""
  var appsUsed: Set<String> = []
  /// Emails and messages sent in this task (Connections); at the limit the person is asked
  /// before more may be sent.
  var sends = 0
  /// The threads an unattended run saved a draft in, by its run's id: one draft per thread per run.
  var unattendedDrafts: (run: String, threads: Set<String>) = ("", [])
}
@MainActor final class BrowserModel: ObservableObject {
  @Published var tabs: [BrowserTab] = []
  @Published var recentlyClosed: [String] = []
  @Published var selected: String? {
    didSet {
      // The idle time of a tab starts when the user leaves it, not when they opened it.
      if oldValue != selected { tabs.first { $0.id == oldValue }?.lastActive = Date() }
      active?.wake()
    }
  }
  /// A new window, or a launch with nothing to restore, opens on Serein full.
  @Published var section = ShellSection.serein {
    didSet {
      // The tab in view is in use only while the browser shows. On Start, History, Projects
      // or a thread its page is off screen: its idle time starts, and it loads again on return.
      guard oldValue != section else { return }
      if section == ShellSection.browser { active?.wake() } else if oldValue == ShellSection.browser { active?.lastActive = Date() }
    }
  }
  /// Saved history read so far: launch reads the newest `Library.launchHistoryDays` off the main
  /// thread; older days, imported history included, come in once something needs them
  /// (`loadAllVisits`).
  @Published var visits: [Visit] = []
  /// True once `visits` holds every saved day.
  private(set) var allVisitsLoaded = false
  private var recentLoad: Task<Void, Never>?
  private var fullLoad: Task<Void, Never>?
  /// Counts clears of history; a read that overlapped one is made again, so nothing cleared returns.
  var historyClears = 0
  @Published var marks: [Mark] = []
  @Published var projects: [Project] = []
  @Published var notice: String?
  @Published var tasks: [String: BrowserTask] = [:]
  /// Tabs the person handed back at a verification check, by chat. The chat's next run takes its
  /// tab just before its agent starts (AgentHub.continuePreparedStart).
  @Published var handBacks: [String: BrowserTab] = [:]
  @Published var timelines: [String: DayTimeline] = [:]
  /// Notes saved by earlier versions; routing still reads them. Nothing writes new ones.
  @Published var projectNotes: [String: ProjectNote] = [:]
  /// What each saved folder looks like on disk (ProjectShelf.swift); drives "Other folders".
  @Published var projectKinds: [String: ProjectCandidateKind] = [:]
  var kindsTask: Task<Void, Never>?
  @Published var intelligenceJobs = Set<AgentFeature>()
  var intelligenceTasks: [AgentFeature: Task<Void, Never>] = [:]
  var lifecycle: Task<Void, Never>?
  var memoryPressure: DispatchSourceMemoryPressure?
  /// One pass over the tabs at a time; a request that comes during a pass runs after it.
  var sleepPassRunning = false
  var sleepPassWaiting: TimeInterval?
  weak var intelligenceAgent: AgentModel?
  var timelineDebounce: Task<Void, Never>?
  /// Read by checks and benches only, so a tool call does not redraw every view of the browser.
  var toolAudit: [String] = []
  /// Each task's line of socket calls while one runs or waits (ToolGate); removed when idle.
  var toolGates: [String: ToolGate] = [:]
  /// Tabs agents open, grouped by run, with per-run steps and outcomes (AgentTabs.swift).
  let agentTabs = AgentTabBoard()
  let secureCards = SecureCards()
  let takeoverCards = TakeoverCards()
  @Published var showAgent = false
  @Published var requestedSettingsSection: String?
  /// Settings in view: it opens in the main window like a tab (`ShellSection.settings`), and
  /// closing it returns to what showed before. Any other navigation (a tab, Serein, a task) leaves
  /// it by setting `section`, as leaving any other view does.
  var showSettings: Bool {
    get { section == ShellSection.settings }
    set {
      if newValue {
        guard section != ShellSection.settings else { return }
        // From the Marketplace, Settings takes over where the Marketplace would go back to, so
        // the two never send each other back and forth.
        sectionBeforeSettings = section == ShellSection.marketplace ? sectionBeforeMarketplace : section
        section = ShellSection.settings
      } else if section == ShellSection.settings {
        section = sectionBeforeSettings
      }
    }
  }
  /// What showed before Settings opened, so closing it goes back there.
  private var sectionBeforeSettings = ShellSection.serein
  /// The Marketplace in view (`ShellSection.marketplace`): apps, teams and plugins, open in the
  /// main window like Settings. Opened from the sidebar, the rail and Add app in the message box's
  /// +; closing returns to what showed before.
  var showMarketplace: Bool {
    get { section == ShellSection.marketplace }
    set {
      if newValue {
        guard section != ShellSection.marketplace else { return }
        // From Settings, the same: the Marketplace goes back where Settings would have. Opened
        // from anywhere but Settings, it starts on Apps; back from Settings it keeps its page.
        if section == ShellSection.settings {
          sectionBeforeMarketplace = sectionBeforeSettings
        } else {
          sectionBeforeMarketplace = section
          marketplacePlace = .apps
        }
        section = ShellSection.marketplace
      } else if section == ShellSection.marketplace {
        section = sectionBeforeMarketplace
      }
    }
  }
  /// What showed before the Marketplace opened, so closing it goes back there.
  private var sectionBeforeMarketplace = ShellSection.serein
  /// The Marketplace's open page, kept while Settings covers it (Manage in Settings, Composio).
  @Published var marketplacePlace: MarketplacePlace = .apps
  @Published var historyEnabled =
    UserDefaults.standard.object(forKey: "serein.history") as? Bool ?? true
  { didSet { UserDefaults.standard.set(historyEnabled, forKey: "serein.history") } }
  let library: Library
  /// The persistent stores of tasks that may use sign-ins, removed once nothing uses them.
  let taskStores: TaskStores
  var behaviorHistory: AgentHistoryStore?
  /// The journal of changing steps (StepJournal). In memory under a preview or a check.
  private(set) lazy var stepJournal = StepJournalStore(
    file: RelayOrchestrator.persists ? library.root.appendingPathComponent(StepJournalStore.path) : nil)
  /// Tasks that took in the person's mail, messages or Mac apps (notePersonalRead). Here, not on
  /// BrowserTask, so a stale `tasks[id] = task` write-back can never drop the mark.
  var personalTasks: Set<String> = []
  /// By task, the sites whose kept sign-in went into its tabs (useKeptSignIn). Such a task never
  /// carries into another turn (AgentModel's warm reuse closes it), and a Sign out ends it
  /// (endTasks(usingKept:)). Here, like `personalTasks`, so no stale write-back drops the mark.
  var keptUsed: [String: Set<String>] = [:]
  let behaviorHistoryPreparation = BehaviorHistoryPreparation()
  @Published var behaviorHistoryPreparing = false
  var behaviorContexts: [String: AgentHistoryRun] = [:]
  /// Threads that took in outside content, oldest first, kept across launches (OutsideContent.swift).
  var outsideThreads: [String] = OutsideThreads.load()
  @Published var behaviorHistoryIssue: String?
  var server: SocketServer?
  let socketDirectory: URL
  var active: BrowserTab? { tabs.first { $0.id == selected } }
  /// A regular tab with no address yet: the start page stands in for its page. A View Source
  /// tab has no address either, but it holds a page; it is the one tab hidden from agents.
  func isNew(_ tab: BrowserTab) -> Bool {
    TabPage.isNew(
      address: tab.address, privateMode: tab.privateMode, owned: tab.owner != nil,
      // A popup can write its page with no address (about:blank); it is not a new tab.
      sourceView: tab.isSourceView || tab.openedByPage)
  }
  /// The tab sharing the content area with the selected one; nil is no split. Resolving
  /// through `tabs` means closing or moving out the companion ends the split on its own.
  @Published var splitCompanionID: String?
  var splitCompanion: BrowserTab? {
    guard let id = splitCompanionID, id != selected else { return nil }
    return tabs.first { $0.id == id }
  }
  /// Moves a tab into the split's right pane, or takes it out again. A split needs two
  /// pages: splitting the only other tab is refused, and a tab shown in the split stops
  /// being the selected one.
  func toggleSplit(_ tab: BrowserTab) {
    if splitCompanionID == tab.id {
      splitCompanionID = nil
      show(tab)
      return
    }
    guard tabs.count >= 2 else { return }
    if selected == tab.id {
      guard let index = tabs.firstIndex(where: { $0.id == tab.id }),
        let other = index > 0
          ? tabs[index - 1]
          : (index + 1 < tabs.count ? tabs[index + 1] : nil)
      else { return }
      show(other)
    }
    splitCompanionID = tab.id
    if section != "browser" { section = "browser" }
  }
  /// Brings a tab into view: its page, or the start page for a new tab.
  func show(_ tab: BrowserTab) {
    selected = tab.id
    section = isNew(tab) ? ShellSection.start : ShellSection.browser
  }
  func rowSelected(_ tab: BrowserTab) -> Bool {
    TabPage.rowSelected(isActive: selected == tab.id, section: section, isNew: isNew(tab))
  }
  /// The start page shows and stands for no tab: then "New tab" is the selected item.
  var startAlone: Bool { TabPage.startAlone(section: section, activeIsNew: active.map(isNew) ?? false) }
  var socketPath: String { socketDirectory.appendingPathComponent("browser.sock").path }
  init(root: URL, prepareHistoryAsynchronously: Bool? = nil) throws {
    library = try Library(root: root)
    taskStores = TaskStores(library: library)
    // Native fixtures keep synchronous setup; the normal app prepares its complete ledger
    // off the UI actor and a task waits for that preparation before it can launch.
    let fixtureHistory = RunMode.automated || RunMode.stress
    let synchronousHistory = prepareHistoryAsynchronously.map { !$0 } ?? fixtureHistory
    if synchronousHistory {
      do {
        let history = try AgentHistoryStore(library: library)
        try history.recoverInterruptedRuns()
        behaviorHistory = history
      } catch {
        behaviorHistoryIssue = "Agent history is incomplete or unreadable. Its files have been preserved."
      }
    }
    library.repairDayKeys()
    // Not in TMPDIR, which task shells may read: every task's capability sits here.
    socketDirectory = AgentFileGuard.runRoot.appendingPathComponent("sr-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(
      at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    if synchronousHistory {
      visits = library.visits()
      allVisitsLoaded = true
    }
    marks = library.load([Mark].self, from: "marks/saved.json") ?? []
    projects = library.load([Project].self, from: "projects/projects.json") ?? []
    projectNotes = Dictionary(
      uniqueKeysWithValues: (library.load([ProjectNote].self, from: "projects/notes.json") ?? [])
        .map { ($0.projectID, $0) })
    if synchronousHistory {
      for url
        in (try? FileManager.default.contentsOfDirectory(
          at: root.appendingPathComponent("index/days"), includingPropertiesForKeys: nil)) ?? []
      {
        if let value = library.load(DayTimeline.self, from: "index/days/" + url.lastPathComponent) {
          timelines[url.deletingPathExtension().lastPathComponent] = value
        }
      }
    } else {
      // Today's description only; another day's is read when it shows (`loadTimeline`).
      timelines[Library.day] = library.load(DayTimeline.self, from: "index/days/\(Library.day).json")
    }
    refreshProjectKinds()
    applyRetention()
    if !synchronousHistory {
      let since = Library.dayKey(Library.launchHistoryStart())
      recentLoad = Task { await self.readVisits(from: since) }
      // Old history is indexed for search by meaning once launch has settled, in small batches.
      let root = library.root
      Task.detached(priority: .background) {
        try? await Task.sleep(for: .seconds(30))
        await SemanticSearchService.shared.backfill(library: root)
      }
    }
    startLifecycle()
    // Each connection on its own thread: an agent's helper sends read-only calls side by side
    // (MCP readOnlyHint), and ToolGate puts one task's calls in order (ToolTurns).
    server = try SocketServer(path: socketPath, concurrent: true) { [weak self] request, clock, reply in
      // The caller's wait started at `clock.start`; every ask in this call closes before it ends (SocketCall).
      Task { @MainActor in
        guard let self else {
          reply(["error": "Browser closed"])
          return
        }
        let call = SocketCall(clock: clock)
        let response = await SocketCalls.$current.withValue(call) { () async -> [String: Any] in
          let entry = await self.enterToolTurn(request)
          if case .timedOut = entry { return ["error": ToolGate.timedOut] }
          defer { if case .turn(let turn) = entry { self.leaveToolTurn(turn) } }
          if case .turn(let turn) = entry { call.longCards = await self.longCards(task: turn.task) }
          // The floor's lines are normal results the model reads and routes around (R17).
          do { return try await self.handle(request) } catch let blocked as Blocked {
            return ["content": [["type": "text", "text": blocked.text]]]
          } catch let check as ApprovalDoor.CheckFirst {
            return ["content": [["type": "text", "text": check.text]]]
          } catch { return ["error": error.localizedDescription] }
        }
        reply(call.reply(response))
      }
    }
    if !synchronousHistory { beginBehaviorHistoryPreparation() }
    // No page uses a task store yet: the ones a crash or a quit left behind go now.
    taskStores.browser = self
    secureCards.browser = self
    takeoverCards.browser = self
    Task { [secureCards] in await Engines.shared.attach(cards: secureCards) }
    agentTabs.onDismiss = { [weak self] in self?.taskStores.release() }
    taskStores.release()
    // The person's clicks and key presses, per tab, for PopupPolicy. Synthetic page events
    // (an agent's clicks) never come through here.
    inputMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    ) { [weak self] event in
      MainActor.assumeIsolated { self?.noteInput(event) }
      return event
    }
  }
  /// A screenshot a task took, for its chat: the browser task's id and the picture's path in the
  /// library (AgentHub adds it to the run's answer).
  var onTaskPicture: ((_ task: String, _ path: String) -> Void)?
  /// A browser-socket step that was refused, declined or failed: the browser task's id and the
  /// redacted reason (AgentHub marks the run's reply with it).
  var onTaskStepFailed: ((_ task: String, _ reason: String) -> Void)?
  /// A choice Serein made on a task's page by itself (a consent overlay's most private option):
  /// the browser task's id and the line its chat shows as a chip (AgentHub).
  var onTaskChoice: ((_ task: String, _ line: String) -> Void)?
  /// A page a task's call read: the browser task's id and the page's host only, for the source
  /// line under a chart or diagram in the run's reply (AgentHub).
  var onTaskRead: ((_ task: String, _ host: String) -> Void)?
  /// Settings › Privacy › “Cookie and consent banners” (on unless turned off).
  nonisolated static let mostPrivateKey = "serein.consent.mostPrivate"
  /// In GateSettings; unset, or a file that cannot be read, is the most private choice.
  static var mostPrivate: Bool { GateSettings.shared.object(forKey: mostPrivateKey) as? Bool ?? true }
  /// Saves a picture for a chat in the library and returns its path there
  /// ("chat-images/<id>.png"); nil when it cannot be written. ponytail: pictures stay until the
  /// library is cleared; remove them with their thread when that matters.
  func saveChatPicture(_ png: Data) -> String? {
    let name = "chat-images/" + UUID().uuidString + ".png"
    do {
      try FileManager.default.createDirectory(
        at: library.root.appendingPathComponent("chat-images", isDirectory: true), withIntermediateDirectories: true)
      try png.write(to: library.root.appendingPathComponent(name), options: .atomic)
      return name
    } catch { return nil }
  }
  /// A picture the person sent, kept beside the chat's pictures so their bubble can show it.
  /// Any image kind is stored as PNG; nil when it cannot be read or written.
  func keepChatPicture(_ path: String) -> String? {
    guard let image = NSImage(contentsOfFile: path), let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
    return saveChatPicture(png)
  }
  private var inputMonitor: Any?
  private func noteInput(_ event: NSEvent) {
    guard let window = event.window, PopupPolicy.counts(keyCode: event.type == .keyDown ? event.keyCode : nil)
    else { return }
    var view: NSView?
    if event.type == .keyDown {
      view = window.firstResponder as? NSView
    } else if let content = window.contentView {
      view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
    }
    while let current = view, !(current is WKWebView) { view = current.superview }
    guard let web = view as? WKWebView, let tab = tabs.first(where: { $0.web === web }) else { return }
    tab.lastInput = Date()
  }
  /// Tabs serve tasks now and keep no session: an older sessions/browser.json stays on disk,
  /// unread and unchanged.
  func persist() {}
  func persistNow() {}
  /// A web link leaves Serein: your browser opens it, under your own sign-ins.
  func openInDefaultBrowser(_ address: String) {
    do {
      let url = try BrowserPolicy.url(BrowserPolicy.address(address))
      if !NSWorkspace.shared.open(url) { notice = "Could not open \(url.host ?? "that link")." }
    } catch { notice = error.localizedDescription }
  }
  /// Reads saved history off the main thread and adds what `visits` lacks. A clear while it read
  /// makes it read again, so a cleared visit never comes back.
  private func readVisits(from day: String?) async {
    let library = library
    while true {
      let clears = historyClears
      let read = await Task.detached(priority: .userInitiated) { library.visits(from: day) }.value
      guard clears == historyClears else { continue }
      let have = Set(visits.map(\.id))
      let fresh = read.filter { !have.contains($0.id) }
      if !fresh.isEmpty { visits = (visits + fresh).sorted { $0.date > $1.date } }
      return
    }
  }
  /// Every saved day in `visits`, for what reads past the launch window: search, recall, an older
  /// day, clearing, imports and the search index. Reads once; later calls return at once.
  func loadAllVisits() async {
    await recentLoad?.value
    guard !allVisitsLoaded else { return }
    let load: Task<Void, Never> = fullLoad ?? Task { await self.readVisits(from: nil) }
    fullLoad = load
    await load.value
    allVisitsLoaded = true
  }
  /// Whether `day` is older than the launch copy of history holds.
  func beforeLaunchHistory(_ day: Date) -> Bool { !allVisitsLoaded && day < Library.launchHistoryStart() }
  /// A day's description (index/days), read off the main thread the first time the day shows.
  func loadTimeline(_ key: String) async {
    guard timelines[key] == nil else { return }
    let library = library, clears = historyClears
    let value = await Task.detached(priority: .userInitiated) { library.load(DayTimeline.self, from: "index/days/\(key).json") }.value
    if let value, timelines[key] == nil, clears == historyClears { timelines[key] = value }
  }
  /// Drops the search vectors of visits no longer saved. The ids come from the files, not
  /// `visits`: that holds only the launch window, and the older days' vectors must stay.
  func pruneSemanticIndex() {
    let library = library, root = library.root
    Task.detached(priority: .utility) {
      let ids = Set(library.visits().map(\.id))
      try? await SemanticSearchService.shared.prune(library: root, ids: ids)
    }
  }
  func attach(_ tab: BrowserTab) {
    tab.onVisit = { [weak self] tab, text in
      guard let self else { return }
      self.persist()
      // A page that finished loading may now join a tab group (ReferenceShell).
      NotificationCenter.default.post(name: Notification.Name("SereinTabVisited"), object: nil)
      KeptPassages.shared.restore(in: tab, marks: self.marks)
      guard self.historyEnabled, !tab.privateMode, tab.owner == nil, !tab.address.isEmpty else {
        return
      }
      guard !BrowserTab.hostIsExcluded(URL(string: tab.address)?.host) else { return }
      if VisitFolding.target(url: tab.address, in: self.visits) != nil { return }
      let visit = Visit(url: tab.address, title: tab.title, text: text)
      do {
        try self.library.append(visit, to: "history/\(Library.day).jsonl")
        self.visits.insert(visit, at: 0)
        // Indexed for search by meaning now, off the main thread, so a search only searches.
        // Fixture runs leave the index to the searches they make.
        if !(RunMode.automated || RunMode.stress) {
          let root = self.library.root
          Task.detached(priority: .background) { try? await SemanticSearchService.shared.index([visit], library: root) }
        }
        self.scheduleTimeline()
      } catch { self.notice = error.localizedDescription }
    }
    tab.inTask = { [weak self, weak tab] in
      guard let self, let tab else { return false }
      return self.tasks.values.contains { $0.tabs.contains { $0 === tab } }
    }
    tab.onPopup = { [weak self, weak tab] popup, select, requested in
      guard let self else { return }
      // A popup from a private tab is private and uses its opener's store. It does not join
      // the opener's tab group.
      if popup.privateMode {
        PrivateStorePool.shared.register(
          tabID: popup.id, store: popup.web.configuration.websiteDataStore)
      } else {
        popup.openerID = tab?.id
      }
      self.attach(popup)
      self.tabs.append(popup)
      // Air traffic control: a link a project claims still opens — just in the background,
      // so the page being read keeps its place — with the project one tap away.
      if select, let project = AirTraffic.route(url: requested ?? popup.web.url, projects: self.projects) {
        ToastCenter.shared.show(
          "Routed: \(AirTraffic.normalize(requested?.host ?? popup.web.url?.host) ?? "this site") belongs to \(project.name).",
          actionTitle: "Show project"
        ) { [weak self] in self?.section = "projects" }
      } else if select {
        self.show(popup)
      }
      self.persist()
    }
    // ⇧-hover a link and the split's other pane previews it; without a split nothing happens
    // (a stray Shift while reading must never move the page).
    tab.onPreviewLink = { [weak self] url in
      guard let self, let companion = self.splitCompanion, companion.web.url != url else { return }
      companion.web.load(URLRequest(url: url))
    }
    tab.onBlockedPopup = { [weak self] url in
      // Offered, not opened: a click on Open sends it to your browser (without `window.opener`).
      _ = ToastCenter.shared.show(
        "\(url.host ?? "This page") wanted to open a window.", actionTitle: "Open"
      ) { [weak self] in
        self?.openInDefaultBrowser(url.absoluteString)
      }
    }
    tab.onClose = { [weak self] popup in
      guard let self else { return }
      // A sign-in popup closes itself when it is done: its opener comes back into view.
      let back = self.selected == popup.id ? popup.opener : nil
      self.close(popup, remember: false)
      if let back, self.tabs.contains(where: { $0 === back }) { self.show(back) }
    }
  }
  @discardableResult func newTab(
    _ address: String = "", select: Bool = true, privateMode: Bool = false
  ) -> BrowserTab {
    let store = privateMode ? PrivateStorePool.shared.mainWindowStore() : nil
    let tab = BrowserTab(privateMode: privateMode, store: store)
    if let store { PrivateStorePool.shared.register(tabID: tab.id, store: store) }
    attach(tab)
    tabs.append(tab)
    if select {
      selected = tab.id
      section = address.isEmpty ? ShellSection.start : ShellSection.browser
    }
    if !address.isEmpty {
      do { try tab.navigate(address) } catch { notice = error.localizedDescription }
    }
    persist()
    return tab
  }
  /// Puts the tabs in `order` (tab ids); tabs it does not name keep their order after it.
  func arrangeTabs(_ order: [String]) {
    let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let named = Set(order)
    let next = order.compactMap { byID[$0] } + tabs.filter { !named.contains($0.id) }
    guard next.map(\.id) != tabs.map(\.id) else { return }
    tabs = next
    persist()
  }
  /// Moves one tab next to another (sidebar drag-to-reorder). Returns false when nothing moved.
  @discardableResult
  func moveTab(_ id: String, to targetID: String, after: Bool) -> Bool {
    guard id != targetID, let source = tabs.firstIndex(where: { $0.id == id }),
      tabs.contains(where: { $0.id == targetID })
    else { return false }
    let tab = tabs.remove(at: source)
    guard let target = tabs.firstIndex(where: { $0.id == targetID }) else {
      tabs.insert(tab, at: source)
      return false
    }
    tabs.insert(tab, at: after ? target + 1 : target)
    persist()
    return true
  }
  func close(_ tab: BrowserTab, remember: Bool = true) {
    // Agent tabs are the agent's browsing, not the user's: never recorded.
    if remember && !tab.privateMode && tab.owner == nil && !tab.address.isEmpty {
      recentlyClosed.append(tab.address)
      recentlyClosed = Array(recentlyClosed.suffix(20))
    }
    tab.discardPage()
    let index = tabs.firstIndex { $0.id == tab.id }
    tabs.removeAll { $0.id == tab.id }
    KeptPassages.shared.forget(tab.id)
    if tab.privateMode && tab.owner == nil { PrivateStorePool.shared.release(tabID: tab.id) }
    // A tab taken over from a task with sign-ins may be the last to use that task's store.
    taskStores.release()
    if selected == tab.id {
      // The neighbour takes its place. The view moves only if this page was the one on screen:
      // closing a page's row from a task chat or History leaves you there.
      let next = index.flatMap({ tabs.indices.contains($0) ? tabs[$0] : nil }) ?? tabs.last
      selected = next?.id
      if [ShellSection.browser, ShellSection.start].contains(section) {
        if let next { show(next) } else { section = ShellSection.serein }
      }
    }
    persist()
  }
  func keepPage() {
    guard let tab = active else { return }
    guard !tab.privateMode else {
      notice = "Private tabs are never saved to your library."
      return
    }
    Task {
      do {
        let (selection, anchor) = await KeptPassages.shared.capture(in: tab)
        var mark = Mark(title: tab.title, url: tab.address, quote: selection)
        mark.anchor = anchor
        marks.insert(mark, at: 0)
        try library.save(marks, to: "marks/saved.json")
        KeptPassages.shared.restore(in: tab, marks: marks)
        notice =
          selection.isEmpty ? "Page saved to your library." : "Passage saved to your library."
      } catch { notice = error.localizedDescription }
    }
  }
  func addProject() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Add project"
    if panel.runModal() == .OK, let url = panel.url,
      !projects.contains(where: { $0.path == url.path })
    {
      if insideSereinData(url.path) { return refuseSereinDataFolder() }
      projects.append(Project(name: url.lastPathComponent, path: url.path, source: .added))
      saveProjects()
      warnIfHoldsSereinData([url.path])
    }
  }
  /// A folder inside Serein's own data (the library, its Anywhere folder, its website data):
  /// never a project, as AgentModel.send refuses to work in one.
  func insideSereinData(_ path: String) -> Bool {
    AgentFileGuard.leadsInto(path, roots: AgentFileGuard.sereinPrivateRoots(
      home: FileManager.default.homeDirectoryForCurrentUser, library: library.root))
  }
  func refuseSereinDataFolder() {
    ToastCenter.shared.show("This folder is inside Serein's own data, which assistants never work in. Choose another folder.")
  }
  /// A folder just added that is the home folder, ~/Library or holds Serein's library: it stays
  /// a project (people do work in their home folder), and a card says Serein's own files stay out
  /// of reach (AgentFileGuard.sereinPrivateRoots, denied by every agent's file guard). It stays
  /// until the person closes it.
  func warnIfHoldsSereinData(_ paths: [String]) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    guard paths.contains(where: { AgentFileGuard.holdsSereinData($0, home: home, library: library.root) }) else { return }
    ToastCenter.shared.show(
      "This folder contains Serein's own data. Serein will keep its own files out of reach of assistants working here.",
      id: "serein-data-project", duration: nil, opaque: true)
  }
  func saveProjects() {
    do {
      try library.save(projects, to: "projects/projects.json")
      try library.saveText(
        projects.map { "- \($0.name): \($0.path)" }.joined(separator: "\n"), to: "projects/INDEX.md"
      )
    } catch { notice = error.localizedDescription }
    refreshProjectKinds()
  }
  /// `current` is the tab a page task works in (the active tab unless Serein's host binding
  /// pinned the one the user's message carried).
  func beginTask(isolated: Bool, allowActions: Bool, includeCurrent: Bool, current: BrowserTab? = nil, allowMac: Bool = false, allowRelay: Bool = false)
    throws -> BrowserTask
  {
    let id = UUID().uuidString
    let cap = Capability(socket: socketPath, task: id)
    let file = socketDirectory.appendingPathComponent(id + ".json")
    try cap.write(to: file)
    // Agent pages never use the user's default store, so a proxy on that store cannot leak.
    // A task that may use sign-ins gets a new persistent store of its own (TaskStores).
    // not run on a real Mac
    let store = isolated ? WKWebsiteDataStore.nonPersistent() : taskStores.make()
    if store === WKWebsiteDataStore.default() {
      throw SereinError.invalid("An agent task cannot use the default data store.")
    }
    var task = BrowserTask(
      capability: cap, file: file, isolated: isolated, allowActions: allowActions, tabs: [],
      store: store)
    if includeCurrent && !isolated {
      // The user's tab is not this task's. The page moves into a tab the task owns. A failed move
      // refuses the task. The page can be asleep when the task starts from a thread or from Start.
      guard AgentTabGate.maySetProxy(
        owner: id,
        openedWith: false,
        defaultStore: store === WKWebsiteDataStore.default()
      ) else {
        throw SereinError.invalid("An agent tab cannot use the default data store.")
      }
      guard let active = current ?? active, !active.privateMode, !active.hiddenFromAgents, !active.address.isEmpty else {
        throw SereinError.invalid("The current page cannot move into an agent tab.")
      }
      active.wake()
      let moved = BrowserTab(privateMode: false, owner: id, store: store)
      moved.assistantBlocks = { [weak self] u in self?.assistantScope(forTask: id)?.scope.blocks(u.absoluteString) == true }
      guard AgentTabGate.mayDrive(
        owner: moved.owner,
        task: id,
        defaultStore: moved.web.configuration.websiteDataStore === WKWebsiteDataStore.default()
      ) else {
        throw SereinError.invalid("The current page cannot move into an agent tab.")
      }
      do { try moved.navigate(active.address) } catch {
        throw SereinError.invalid("The current page could not move into an agent tab.")
      }
      task.tabs.append(moved)
    }
    task.allowMac = allowMac
    task.allowRelay = allowRelay
    // Every task, paired or not, has a site list. The first site asks before it is recorded.
    task.pass = TaskPass.begin(taskID: id)
    tasks[id] = task
    return task
  }
  func endTask(_ id: String) {
    guard let task = tasks.removeValue(forKey: id) else { return }
    personalTasks.remove(id)
    keptUsed[id] = nil
    // Revocation always happens, even if recording has failed.
    let context = behaviorContexts.removeValue(forKey: id)
    MacControl.shared.forget(id)
    MacBackground.shared.end(id)
    TaskShelf.shared.taskEnded(id)
    secureCards.taskEnded(id)
    Task { await Engines.shared.close(Engines.taskThread(id)) }
    try? FileManager.default.removeItem(at: task.file)
    try? FileManager.default.removeItem(at: PluginHost.toolListFile(for: task))
    // A run that ends before its agent starts leaves no handed-back tab for a much later run; the
    // tab's mark still names the check, so Hand back is offered again.
    if let thread = agentTabs.runs[id]?.threadID { handBacks[thread] = nil }
    let kept = agentTabs.taskEnded(id, tabs: task.tabs)
    for tab in task.tabs where tab.owner == id && !kept.contains(tab.id) && !takeoverCards.open.contains(where: { $0.tab === tab }) {
      tab.discardPage()
    }
    taskStores.release()
    // An integrity scan can hold the ledger lock. Revoke authority and release pages
    // before that wait; keep the synchronized revocation event afterward.
    if let context { recordBehavior(context, .capabilityRevoked) }
  }
  /// The task stores a page can still use: each running task's, and that of every tab wherever it
  /// is held (a handed-over page, a task, the agent board, a hand-back).
  func taskStoresInUse() -> Set<UUID> {
    var stores = tasks.values.map(\.store)
    let held = tabs + tasks.values.flatMap(\.tabs) + agentTabs.entries.map(\.tab) + Array(handBacks.values)
      + takeoverCards.open.map(\.tab)
    stores += held.map { $0.web.configuration.websiteDataStore }
    return Set(stores.compactMap(\.identifier))
  }
  func shutdown() {
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    inputMonitor = nil
    cancelBehaviorHistoryPreparation()
    lifecycle?.cancel()
    memoryPressure?.cancel()
    kindsTask?.cancel()
    timelineDebounce?.cancel()
    for job in intelligenceTasks.values { job.cancel() }
    for id in Array(tasks.keys) { endTask(id) }
    server?.stop()
    try? FileManager.default.removeItem(at: socketDirectory)
    persistNow()
  }
  /// The CLI behind task `id` runs on the engines and waits on one tool call at least a secure
  /// card's life, so a card in its call may live that long. Cursor and Gemini stop a call at
  /// 118 s, and their cards keep the 110 s window.
  func longCards(task id: String) async -> Bool {
    guard let hub = agentTabs.hub, let cli = hub.runs.last(where: { $0.taskID == id })?.engineRequest?.cli,
      let wait = await hub.engines.cardWait(for: cli) else { return false }
    return wait >= .seconds(SecureCard.life)
  }
  /// A socket call's place in its task's line (ToolGate). Only a call with the task's capability
  /// waits in line; any other goes straight to `handle`, which refuses it as before.
  func enterToolTurn(_ request: [String: Any]) async -> ToolEntry {
    guard let task = request["task"] as? String, let held = tasks[task], let presented = request["token"] as? String,
      AgentAccess.tokensEqual(presented, held.capability.token), !held.finished
    else { return .unchecked }
    let turn = ToolTurns.turn(name: request["name"] as? String ?? "", arguments: request["arguments"])
    let gate = toolGates[task] ?? ToolGate()
    toolGates[task] = gate
    guard let id = await gate.enter(write: turn.write, tab: turn.tab) else {
      if gate.isIdle, toolGates[task] === gate { toolGates[task] = nil }
      return .timedOut
    }
    return .turn(ToolTurn(task: task, gate: gate, id: id))
  }
  func leaveToolTurn(_ turn: ToolTurn) {
    turn.gate.leave(turn.id)
    if turn.gate.isIdle, toolGates[turn.task] === turn.gate { toolGates[turn.task] = nil }
  }
  func handle(_ request: [String: Any], admitted: ApprovalGate.ActionIntent? = nil) async throws -> [String: Any] {
    guard let id = request["task"] as? String, let task = tasks[id],
      let presented = request["token"] as? String, AgentAccess.tokensEqual(presented, task.capability.token),
      !task.finished
    else { throw SereinError.invalid("Invalid or expired browser capability") }
    let raw = request["name"] as? String ?? ""
    // A repl program's own steps are marked, so a bench tells model calls from steps.
    toolAudit.append(request["repl"] as? Bool == true ? "repl:" + raw : raw)
    if toolAudit.count > 1000 { toolAudit.removeFirst() }
    let context = behaviorContexts[id]
    // Resolved before the call: a Stop while it runs clears the run, and the page still
    // belongs to the chat.
    let owner = agentTabs.runs[id]?.threadID ?? id
    let operation = UUID()
    // The journal first: a changing step an earlier send of this request finished is not run
    // again, and the model reads what it returned then.
    let journal = stepJournal.step(thread: owner, tool: raw, arguments: request["arguments"] as? [String: Any] ?? [:])
    if case .replay(let entry) = journal.before, case .done(let result) = entry.outcome {
      relayTask(id, tasks[id])?.note("Already done for this request, not run again: \(raw)", .auto)
      noteOutsideContent(task: id, tool: raw)
      let then = PageFence.fence(UntrustedText.escape(UntrustedText.capped(AgentPrivacy.redact(result))))
      // A program reads a step's result as a page, which a note is not: it stops here, and the
      // model reads why.
      if request["repl"] as? Bool == true { throw SereinError.invalid(StepJournal.replayedInProgram + "\n" + then) }
      return ["note": StepJournal.replayed, "returned_then": then]
    }
    if let context, !recordBehavior(context, .toolRequested, operationID: operation, tool: .browser(raw)) {
      throw SereinError.invalid("The tool was not run because agent history could not be saved.")
    }
    agentTabs.step(task: id, tool: raw, arguments: request["arguments"] as? [String: Any] ?? [:])
    // Only an authenticated call can mark its own step as failed.
    do {
      let result = try await StepJournal.$live.withValue(journal.live) {
        do {
          return try await perform(request, id: id, task: task, operationID: operation, admitted: admitted)
        } catch let check as VerificationCheck {
          return botCheck(check, tab: (request["arguments"] as? [String: Any])?["tab"] as? String ?? "", task: id)
        }
      }
      if let context { recordBehavior(context, .toolReturned, operationID: operation, tool: .browser(raw)) }
      noteOutsideContent(task: id, tool: raw)
      // A repl call's own result carries a shortened page (element lines, not rows): only real
      // tool calls name the latest tab and page.
      let arguments = request["arguments"] as? [String: Any] ?? [:]
      if raw != "repl", let tab = arguments["tab"] as? String ?? result["tab"] as? String { tasks[id]?.lastTab = tab }
      let page = result["page"] as? [String: Any] ?? result
      if raw != "repl", let tab = page["tab"] as? String, page["elements"] != nil {
        tasks[id]?.pages[tab] = AgentPrivacy.sanitize(page) as? [String: Any]
      }
      #if DEBUG
      await BenchTrace.record(raw, request["arguments"] as? [String: Any] ?? [:], result, nil, tabs: tasks[id]?.tabs ?? [])
      #endif
      var shown = AgentPrivacy.sanitize(result, preservingImageData: true) as? [String: Any] ?? [:]
      // A collected table's values are checked against the page text the agent was shown; the
      // page's own address stays in memory only, to open it on the person's click.
      CollectedPages.note(shown, owner: owner, real: page["url"] as? String)
      // Only a result that carries the page's words counts as read; the host leaves, never the text.
      if let host = ReplySources.readHost(page) { onTaskRead?(id, host) }
      // Mail and Messages carry no address: the app names what was read.
      if raw == "mail_read" { onTaskRead?(id, "Mail") } else if raw == "messages_read" { onTaskRead?(id, "Messages") }
      // A download refused, stopped or deleted since the last call (TaskShelf), redacted and fenced.
      // A repl program's own steps go to the program, not the model, so they leave them waiting.
      if request["repl"] as? Bool != true {
        let notices = TaskShelf.shared.takeNotices(task: id)
        if !notices.isEmpty { shown["download_notices"] = PageFence.fence(UntrustedText.escape(UntrustedText.capped(AgentPrivacy.redact(notices.joined(separator: "\n"))))) }
      }
      if journal.live.started != nil { stepJournal.finish(journal.live, thread: owner, result: Self.journalText(shown)) }
      return shown
    } catch {
      stepJournal.finish(journal.live, thread: owner, result: nil)
      #if DEBUG
      await BenchTrace.record(raw, request["arguments"] as? [String: Any] ?? [:], [:], error, tabs: tasks[id]?.tabs ?? [])
      #endif
      if let context { recordBehavior(context, .toolFailed, operationID: operation, tool: .browser(raw)) }
      // An error can quote the page or the app, so it counts as outside content too.
      noteOutsideContent(task: id, tool: raw)
      let reason = AgentPrivacy.redact(error.localizedDescription)
      // A connection the person has not turned on: Serein's chat shows a card to turn it on under
      // the reply (ConnectNeed). The model reads the same refusal as before.
      if let relay = relayTask(id, tasks[id]), let thread = threadID(forTask: id),
        let need = ConnectNeed.of(
          tool: raw, arguments: request["arguments"] as? [String: Any] ?? [:], refusal: error.localizedDescription)
      {
        relay.noteNeed(need, thread: thread)
      }
      // An unattended run stopped by a site rule is recorded as blocked, not as a failure.
      if let refusal = error as? SiteRuleRefusal, refusal.assistant == nil, let relay = relayTask(id, tasks[id]), relay.runsUnattended {
        relay.scheduledRuleBlock = refusal.site
      }
      agentTabs.stepFailed(task: id, tool: raw, reason, ruleSite: (error as? SiteRuleRefusal).flatMap { $0.assistant == nil ? $0.site : nil })
      onTaskStepFailed?(id, reason)
      throw SereinError.invalid(reason)
    }
  }
  /// A step's result as the journal keeps it: its words, never a picture. A long field is cut
  /// short, not left out.
  nonisolated static func journalText(_ shown: [String: Any]) -> String {
    if let text = shown["text"] as? String { return text }
    let picture = shown["type"] as? String == "image"
    let plain = shown.filter { !($0.value is Data) && !(picture && $0.key == "data") }
      .mapValues { ($0 as? String).map(StepJournal.clip) ?? $0 }
    guard JSONSerialization.isValidJSONObject(plain),
      let data = try? JSONSerialization.data(withJSONObject: plain, options: [.sortedKeys])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  private func perform(
    _ request: [String: Any], id: String, task: BrowserTask, operationID: UUID,
    admitted: ApprovalGate.ActionIntent? = nil
  ) async throws -> [String: Any] {
    var task = task
    let raw = request["name"] as? String ?? ""
    // What Serein's own turn uses, so a note it keeps knows whether the turn read outside text.
    if task.allowRelay { RelayOrchestrator.shared?.noteTurnTool(raw) }
    // Serein's own assistant has no built-in tabs (AssistantWeb): it works on websites through a Mac.
    if task.allowRelay && (AssistantWeb.tabTools.contains(raw)
      || raw == "person_step" && (request["arguments"] as? [String: Any])?["kind"] as? String != "confirm") {
      throw SereinError.invalid(AssistantWeb.refusal)
    }
    // An assistant may be kept off Mac apps (AssistantScope); only narrows what the task holds.
    if ["mac_script", "mac_observe", "mac_act", LocalExecution.toolName].contains(raw), let refusal = assistantRefusal(.mac, taskID: id) {
      throw SereinError.invalid(refusal)
    }
    if raw == LocalExecution.toolName {
      guard task.allowMac else { throw SereinError.invalid("Mac automation unavailable") }
      return try await macRun(request["arguments"] as? [String: Any] ?? [:], id: id, task: task)
    }
    if raw == "mac_script" {
      guard task.allowMac,
        let source = (request["arguments"] as? [String: Any])?["source"] as? String
      else { throw SereinError.invalid("Mac automation unavailable") }
      let result = try await macScript(source, taskID: id, operationID: operationID)
      // Mac apps hold the person's data: whatever a script returns marks the chat.
      guard notePersonalRead(task: id) else {
        StepJournal.live?.ran()
        throw SereinError.invalid(Self.personalMarkWithheld + " The script did run; do not run it again.")
      }
      return result
    }
    if raw == "mac_observe" || raw == "mac_act" {
      guard task.allowMac else { throw SereinError.invalid("Mac automation unavailable") }
      // Accessibility off: the chat shows its card and the model hears Serein waits (MacAccessWait).
      if let waiting = relayTask(id, task)?.macAccessCall(raw, taskID: id) { return ["result": waiting] }
      let arguments = request["arguments"] as? [String: Any] ?? [:]
      let context = behaviorContexts[id]
      let relay = relayTask(id, task)
      let owner = threadID(forTask: id)
      // The step Relay's policy judged, for its "What I did" list.
      var judged: RelayAutonomy.MacStep?
      // Background work (MacBackground): its cards show where this task's questions show, and
      // nobody is there to answer them in an unattended run.
      let background: MacBackgroundAsk? = arguments["background"] as? Bool == true
        ? MacBackgroundAsk(
          thread: owner ?? agentTabs.hub?.runs.first { $0.taskID == id }?.spec.threadID,
          unattended: { [weak self] in self?.isUnattended(task: id) ?? true },
          allowsAll: { [weak self] in self?.allowsAll(task: id) ?? false },
          ask: { [weak self] title, detail, button in
            if let relay { return await relay.confirmAnswer(title, detail, button: button, thread: self?.threadID(forTask: id)) }
            return await MacBackgroundAsk.alert(title, detail, button: button, thread: owner)
          })
        : nil
      if raw == "mac_observe" {
        // An app that holds the person's secrets is refused in the foreground too, before the
        // picture card.
        if let appName = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespaces), !appName.isEmpty,
          let app = try? MacControl.app(named: appName)
        {
          try MacControl.refuseSecrets(app, appName: app.localizedName ?? appName)
        }
        // Background work refused (off, stopped, unattended, a refused app) asks nothing, not even
        // for the picture: the refusal comes before any card.
        if let background, let appName = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespaces),
          !appName.isEmpty
        {
          let app = try MacControl.app(named: appName)
          try MacBackground.shared.mayUse(
            app, appName: app.localizedName ?? appName, task: id, unattended: background.unattended())
        }
        // A picture of another app leaves this Mac. The control list is a read. The picture asks.
        if arguments["picture"] as? Bool == true {
          let appName = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let named = appName.isEmpty ? "the front window" : "“\(appName)”"
          let decision = try ApprovalDoor.answer(
            .init(.effect(.unknown), standing(task: id, else: relay?.standing ?? .noChat(present: true))),
            facts: .init(
              secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
              runsAnything: false, ref: "")).decision()
          if decision != .auto {
            guard let relay else { throw SereinError.invalid(ActionAdmission.needsPerson) }
            let human = await relay.confirmAnswer(
              "Serein wants to take a picture of \(named)",
              "The picture goes to this task.",
              thread: owner)
            guard human == .yes else {
              throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson)
            }
          }
        }
        let observed = try await MacControl.shared.observe(arguments, taskID: id, background: background)
        if background != nil {
          agentTabs.relabelLast(task: id, tool: raw, "Looked at \(observed["app"] as? String ?? "an app") in the background")
        }
        // A Mac app's window (Mail, Messages or any other) holds the person's data: it marks the chat.
        guard notePersonalRead(task: id) else { throw SereinError.invalid(Self.personalMarkWithheld) }
        return observed
      }
      let describe: (RelayAutonomy.MacStep) -> String = {
        background != nil ? MacBackgroundPolicy.describe($0) : RelayToolHost.describe($0)
      }
      func door(_ step: RelayAutonomy.MacStep, _ standing: ApprovalDoor.Standing) -> ApprovalDoor.Answer {
        ApprovalDoor.answer(
          .init(.macStep(step), standing),
          facts: .init(
            secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
            runsAnything: ApprovalDoor.runsAnything(app: step.app), ref: ""))
      }
      let policy: ((RelayAutonomy.MacStep) async throws -> RelayAutonomy.Decision)?
      if let background {
        // A background step follows the person's level like a foreground one; an unattended run
        // is refused, since nobody is there to answer.
        policy = { step in
          judged = step
          guard !background.unattended() else { throw SereinError.invalid(MacBackgroundPolicy.unattended) }
          let standing = self.standing(task: id, else: RelayOrchestrator.standing(relay, present: true))
          var decision = try door(step, standing).decision()
          if decision == .auto, let relay, standing.level != .proactive {
            guard await relay.settleConsent(thread: owner) else { throw SereinError.invalid(RelayOrchestrator.stoppedStep) }
            decision = try door(step, relay.standing(present: true)).decision()
          }
          return decision
        }
      } else if taskStandsProactive(id) {
        policy = { step in
          judged = step
          return try door(step, .proactiveTask(present: true)).decision()
        }
      } else {
        // Relay's run and the runs it started: Autopilot decides, and questions show in its panel.
        policy = relay.map { relay in { step in
          judged = step
          var decision = try door(step, relay.standing).decision()
          // The one-time consent card only before a routine step; its answer may be Ask
          // before every step, so the step is judged again.
          if decision == .auto {
            guard await relay.settleConsent(thread: owner) else { throw SereinError.invalid(RelayOrchestrator.stoppedStep) }
            decision = try door(step, relay.standing).decision()
          }
          return decision
        } }
      }
      let result = try await MacControl.shared.act(arguments, taskID: id, stillAllowed: { [weak self] in
          self?.tasks[id]?.allowMac == true
        }, onDecision: { [weak self] decision in
          if let context, self?.recordBehavior(context, .permissionAnswered, operationID: operationID, tool: .macAct,
                                              decision: decision) != true {
            throw SereinError.invalid("The Mac action was not run because its approval could not be recorded.")
          }
          if let relay, let step = judged { relay.note(describe(step), RelayOrchestrator.how(decision)) }
        },
        policy: policy,
        ask: relay.map { relay in { [weak self] in
          // A step only Every step stops: the card offers Only risky steps in place.
          let title: String = $0
          let detail: String = $1
          var routine = false
          if !relay.autopilot, let step = judged {
            routine = door(step, relay.standing.atRiskyOnly).runs
          }
          return await relay.confirmAnswer(title, detail, thread: self?.threadID(forTask: id), routine: routine)
        } },
        background: background,
        secureCard: { target, kind in try await self.macSecureCard(target, kind: kind, task: id) })
      // The step list says what happened: “Clicked “Send” in Mail”, or “Pressed “Save” in Notes,
      // in the background”.
      if let step = judged {
        agentTabs.relabelLast(
          task: id, tool: raw,
          background != nil
            ? MacBackgroundPolicy.describe(step, inserted: result["inserted"] as? Bool == true) : RelayToolHost.describe(step))
      }
      if relay != nil { GuideCenter.shared.record(.macStepStarted) }
      return result
    }
    // Mail and Messages (Settings › Connections): Serein's run only, refused by place, asked on
    // its card before anything is sent, moved or deleted (BrowserModel.connectionCall).
    if Connections.toolNames.contains(raw) {
      return try await connectionCall(
        raw, request["arguments"] as? [String: Any] ?? [:], taskID: id, task: task, operationID: operationID)
    }
    // Calendar, Reminders, Contacts and Notes (Settings › Connections): Serein's own run only,
    // inside the assistant's places, while the task may use Mac apps, each call through
    // ApprovalDoor.answer.
    if let connection = NativeConnection.of(tool: raw) {
      guard task.allowRelay, relayTask(id, task) != nil else {
        throw SereinError.invalid("\(connection.label) is only available to Serein.")
      }
      if let refusal = assistantRefusal(connection.place, taskID: id) { throw SereinError.invalid(refusal) }
      guard task.allowMac else { throw SereinError.invalid("Mac automation unavailable") }
      return try await nativeConnectionCall(
        raw, connection, request["arguments"] as? [String: Any] ?? [:], taskID: id, operationID: operationID)
    }
    // A plugin tool: Relay's run only, by the risk its manifest declares, recorded like a Mac step.
    if raw.contains("__"), let plugin = PluginHost.shared.tool(raw) {
      guard task.allowRelay, let relay = RelayOrchestrator.shared else {
        throw SereinError.invalid("Plugin tools are only available to Serein.")
      }
      // A server connected by address (Settings › Connections): only for an assistant that may
      // use connected apps (AssistantScope), refused before any card.
      let connection = PluginHost.shared.isConnection(plugin.package)
      if connection, let refusal = assistantRefusal(.connectedApps, taskID: id) {
        throw SereinError.invalid(refusal)
      }
      if connection, let refusal = assistantAppRefusal(
        key: AssistantScope.connectionAppKey(plugin.package.id), app: plugin.manifest.name, taskID: id)
      {
        throw SereinError.invalid(refusal)
      }
      let arguments = request["arguments"] as? [String: Any] ?? [:]
      // The gate reads the server's own tool name too (`gateName`), and a connection's stamp
      // names the server tool, so a review that moves a local name to another tool is a change.
      let pluginEffect = ApprovalGate.pluginEffect(name: plugin.tool.gateName, declared: plugin.tool.risk) ?? .unknown
      let stampName = { (tool: PluginManifest.Tool) in connection ? tool.name + ">" + tool.serverName : tool.name }
      let pluginStamp = ApprovalGate.pluginStamp(name: stampName(plugin.tool), risk: plugin.tool.risk.rawValue)
      let pluginIntent = ApprovalGate.record(
        ApprovalGate.GateAction(kind: "plugin", elementID: raw, pageVersion: pluginStamp, site: nil),
        effect: pluginEffect, mint: { UUID().uuidString })
      // A read is a read-rated tool whose name raises nothing.
      let reads = ApprovalGate.pluginEffect(name: plugin.tool.gateName, declared: plugin.tool.risk, effect: .read) == .read
      let appKey = "mcp:" + plugin.package.id
      if connection { appRunState(id) }
      // A connection's run follows its own standing, unattended or not (a webhook's included).
      let judge = { () throws -> RelayAutonomy.Decision in
        try ApprovalDoor.answer(
          .init(.plugin(name: plugin.tool.gateName, declared: plugin.tool.risk), relay.standing),
          facts: .init(
            secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
            runsAnything: false, ref: "")
        ).decision()
      }
      var decision = try judge()
      // The one-time consent card only before a routine step, then judged again.
      if decision == .auto {
        guard await relay.settleConsent(thread: threadID(forTask: id)) else { throw SereinError.invalid(RelayOrchestrator.stoppedStep) }
        decision = try judge()
      }
      let human: ApprovalGate.HumanAnswer
      if decision == .auto {
        human = .yes
      } else {
        // The card names the server's own tool when it differs, and when a name raised a
        // read-rated tool, says what the raised effect may do instead of "Nothing is changed".
        var card = ApprovalCopy.plugin(
          name: plugin.manifest.name,
          tool: plugin.tool.remote.map { "\(plugin.tool.name) (server: \($0))" } ?? plugin.tool.name,
          risk: plugin.tool.risk)
        if plugin.tool.risk == .read, !reads { card.detail = ApprovalGate.askLine(pluginEffect) }
        human = await relay.confirmAnswer(card.title, card.detail, thread: threadID(forTask: id),
                                           more: ApprovalCopy.details(arguments), moreName: "the details")
      }
      let allowed = human == .yes
      if let context = behaviorContexts[id], !recordBehavior(
        context, .permissionAnswered, operationID: operationID, tool: .plugin,
        decision: decision == .auto ? .allowedByAutopilot : allowed ? .allowedOnce : .denied)
      {
        throw SereinError.invalid("The plugin tool was not run because its approval could not be recorded.")
      }
      relay.note("\(plugin.manifest.name): \(plugin.tool.name.replacingOccurrences(of: "_", with: " "))",
                 decision == .auto ? .auto : allowed ? .allowed : .declined)
      // Read the tool again. The stamp is its name and declared risk now, not the one stored above.
      guard let fresh = PluginHost.shared.tool(raw) else {
        throw SereinError.invalid(ActionAdmission.pageChanged)
      }
      let liveStamp = ApprovalGate.pluginStamp(name: stampName(fresh.tool), risk: fresh.tool.risk.rawValue)
      let liveEffect = ApprovalGate.pluginEffect(name: fresh.tool.gateName, declared: fresh.tool.risk) ?? .unknown
      guard ApprovalGate.beforeInput(
        intent: pluginIntent, answer: human, liveElement: raw, liveVersion: liveStamp, liveEffect: liveEffect)
      else {
        throw SereinError.invalid(ActionAdmission.blocked(
          answer: human, decision: decision, effectChanged: liveEffect != pluginEffect))
      }
      guard tasks[id]?.finished == false else { throw SereinError.invalid("The task ended while awaiting approval") }
      // Asked again: the assistant's app list may have changed while the card waited.
      if connection, let refusal = assistantAppRefusal(
        key: AssistantScope.connectionAppKey(plugin.package.id), app: plugin.manifest.name, taskID: id)
      {
        throw SereinError.invalid(refusal)
      }
      if connection {
        // An app's data is the person's: a chat that used a connection never reaches Serein's
        // computer (personal reads), so the mark is saved before the call, read or write.
        guard notePersonalRead(task: id) else { throw SereinError.invalid(Self.personalMarkFailed) }
        tasks[id]?.appsUsed.insert(appKey)
      }
      return try await PluginHost.shared.call(raw, arguments)
    }
    // The person's connected apps (ComposioApps): Serein's run only, inside its assistant's places.
    if ConnectedApps.toolNames.contains(raw) {
      guard task.allowRelay, RelayOrchestrator.shared != nil else {
        throw SereinError.invalid("Connected apps are only available to Serein.")
      }
      if let refusal = assistantRefusal(.connectedApps, taskID: id) { throw SereinError.invalid(refusal) }
      return try await connectedApp(
        raw, task: id, operationID: operationID, arguments: request["arguments"] as? [String: Any] ?? [:])
    }
    // Team tools (PeerTools): only a task Peers registered holds them; Peers checks every call.
    if PeerTools.names.contains(raw) {
      let call = try PeerTools.parse(raw, request["arguments"] as? [String: Any] ?? [:]).mapError { SereinError.invalid($0.text) }.get()
      let reply = await Peers.shared.handle(call, task: id)
      if reply.isError { throw SereinError.invalid(reply.text) }
      return ["result": reply.text]
    }
    // A hand-off's own run hands part of its task on as its target, from its chat; it holds none
    // of Relay's other tools, and the chain's rules decide (RelayToolHost.handOff).
    if RelayTools.teamNames.contains(raw), let relay = RelayOrchestrator.shared,
      let run = relay.agent.hub.runs.first(where: { $0.taskID == id }), run.spec.initiator == .handoff
    {
      let args = request["arguments"] as? [String: Any] ?? [:]
      if raw == "channel_say" { return try await relay.tools.channelSay(args, handoffChat: run.spec.threadID) }
      return try await relay.tools.handOff(args, handoffChat: run.spec.threadID)
    }
    // A hand-off's own run and its team room: the host finds the seat from the run (Rooms).
    if RelayTools.roomNames.contains(raw) {
      guard let relay = RelayOrchestrator.shared,
        let run = relay.agent.hub.runs.first(where: { $0.taskID == id }), run.spec.initiator == .handoff
      else { throw SereinError.invalid("Only an assistant working on a hand-off has a team room.") }
      return try relay.roomTool(raw, request["arguments"] as? [String: Any] ?? [:], seatThread: run.spec.threadID)
    }
    // Relay's orchestration tools: only its own run holds them (RelayToolHost).
    if RelayTools.names.contains(raw) || RelayTools.teamNames.contains(raw) {
      guard task.allowRelay, let relay = RelayOrchestrator.shared else {
        throw SereinError.invalid("Serein’s tools are only available to Serein.")
      }
      return try await relay.tools.call(raw, request["arguments"] as? [String: Any] ?? [:], thread: threadID(forTask: id))
    }
    // Serein's own settings, when the user asks (AgentSettings): no tab and no website action.
    if ToolSchema.settingsToolNames.contains(raw) {
      let args = request["arguments"] as? [String: Any] ?? [:]
      let relay = relayTask(id, task) ?? RelayOrchestrator.shared
      let settingAction = args["action"] as? String ?? ""
      let decision = try ApprovalDoor.answer(
        .init(.setting(tool: raw, action: settingAction), relay?.standing ?? .noChat(present: true)),
        facts: .init(
          secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
          runsAnything: false, ref: "")
      ).decision()
      if decision == .ask {
        guard let relay else { throw SereinError.invalid(ActionAdmission.needsPerson) }
        let effect = ApprovalGate.settingsEffect(tool: raw, action: settingAction)
        let human = await relay.confirmAnswer(
          "Serein wants to change a setting", ApprovalGate.askLine(effect), thread: threadID(forTask: id))
        guard human == .yes else {
          throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson)
        }
      }
      return try AgentSettings.call(raw, args)
    }
    // Files this task downloaded (TaskShelf): their list and extracted text, never a path.
    if raw == "downloads" {
      return try await TaskShelf.shared.call(task: id, arguments: request["arguments"] as? [String: Any] ?? [:])
    }
    // A step only the person can take (PersonStep): a card, answered at once.
    if raw == PersonStep.tool { return try await personStep(request["arguments"] as? [String: Any] ?? [:], task: id) }
    // A CSV, TSV or .xlsx attached to this turn's message (TableQueryHost): a read of that file only.
    if raw == "table_query" {
      return try await tableQuery(task: id, arguments: request["arguments"] as? [String: Any] ?? [:])
    }
    // Serein's computer (ComputerHost): only an assistant's task that may use it; steps inside
    // need no card, and what leaves it (a file, text) goes through ApprovalGate there.
    if ComputerTools.names.contains(raw) {
      return try await ComputerHost.shared.call(raw, request["arguments"] as? [String: Any] ?? [:], task: id, browser: self)
    }
    // An assistant kept off the Web (or this page) reads and acts on no page; finish still ends
    // its turn (AssistantScope, only narrows).
    if raw != "finish", let refusal = assistantRefusal(nil, taskID: id) { throw SereinError.invalid(refusal) }
    // Fast steps and repl programs only click, type, select and scroll, as the isolated tools do;
    // click_point is a click that always asks.
    if task.isolated && !ToolSchema.isolated.contains(raw) && !["do", "repl", "fetch", "page_tool", "click_point"].contains(raw) {
      throw SereinError.invalid("Tool unavailable for isolated tasks")
    }
    let name = [
      "list_tabs": "tabs", "open_tab": "open", "navigate": "go", "fill": "type",
      "close_tab": "close",
    ][raw, default: raw]
    let a = request["arguments"] as? [String: Any] ?? [:]
    // A repl program's steps keep the whole page text: it stays in the program, not the model's context.
    let full = request["repl"] as? Bool == true
    // Screenshots stay available read-only; pages with sensitive fields are refused below (bug 18).
    if WebsiteActions.blockedWhenOff(name) && !task.allowActions {
      throw SereinError.invalid(
        "Website actions are off. Ask the user to enable clicks and typing for a new task.")
    }
    if name == "tabs" {
      // A tab on a Never site is not listed: its title and address stay out too (SiteRules).
      return ["tabs": task.tabs.filter { !$0.hiddenFromAgents }.map { ["tab": $0.id, "title": $0.title, "url": $0.address] }]
    }
    if name == "repl" {
      guard Repl.available, let code = a["code"] as? String else { throw SereinError.invalid("repl is unavailable") }
      let repl = task.repl ?? Repl()
      tasks[id]?.repl = repl
      let tabs = task.tabs.filter { !$0.hiddenFromAgents }.map { ["tab": $0.id, "title": $0.title, "url": $0.address] }
      return await repl.run(code, tab: task.lastTab, tabs: tabs, pages: task.pages) { [weak self] tool, arguments in
        guard let self, let task = self.tasks[id] else { throw SereinError.invalid("The task ended during this operation") }
        return try await self.handle([
          "task": id, "token": task.capability.token, "name": tool, "arguments": arguments, "repl": true,
        ])
      }
    }
    if name == "fetch" {
      return try await fetch(a["url"] as? String ?? "", task: task)
    }
    if name == "open" {
      guard let u = a["url"] as? String else { throw SereinError.invalid("Missing URL") }
      // Removing this check opens an agent tab on the user's store.
      guard AgentTabGate.maySetProxy(
        owner: id, openedWith: false, defaultStore: task.store === WKWebsiteDataStore.default()
      ) else {
        throw SereinError.invalid("An agent tab cannot use the default data store.")
      }
      try Self.check(try BrowserPolicy.url(u), task)
      guard task.tabs.filter({ $0.owner == id }).count < AgentTabPolicy.maxTabs else {
        throw SereinError.invalid(AgentTabPolicy.capMessage())
      }
      try await authorizeSite(u, taskID: id)
      try await useKeptSignIn(u, taskID: id, into: task.store, tool: raw, arguments: a, operationID: operationID)
      task.pass = tasks[id]?.pass
      task.keptAsked = tasks[id]?.keptAsked ?? task.keptAsked
      let tab = BrowserTab(privateMode: task.isolated, owner: id, store: task.store)
      tab.allowsNavigation = task.allows
      tab.assistantBlocks = { [weak self] u in self?.assistantScope(forTask: id)?.scope.blocks(u.absoluteString) == true }
      task.tabs.append(tab)
      tasks[id] = task
      agentTabs.opened(tab, task: id, isolated: task.isolated)
      try tab.navigate(u)
      return try await pageAfter(tab, task: id, full: full)
    }
    if name == "finish" {
      // The prompt offers done or stuck (TaskPrompt); the old word failed still parses, and waiting
      // hands a verification check or sign-in tab back to the person (below). needs_user is refused.
      guard let said = a["outcome"] as? String, let stored = RunRecord.Outcome(reported: said)
      else {
        throw SereinError.invalid(
          "Invalid outcome: finish with done or stuck. A step only the user can take goes to secure_card or person_step, and the task carries on.")
      }
      let outcome = stored.rawValue
      var resultTab: BrowserTab?
      if let result = a["result_tab"] as? String {
        // A name that is not one of this task's tabs (a ref, "page") shows the tab of the latest
        // call instead: refusing it cost agents a turn or two (5 of 16 bench runs). Only this
        // task's tabs can be shown either way.
        resultTab = task.tabs.first { $0.id == result } ?? task.tabs.first { $0.id == task.lastTab }
      }
      // The agent stopped at a verification check: the run says so and its tab offers Hand back.
      // An inline check the agent left alone counts too: the rest of the page was its to do.
      let check = stored == .waiting ? await resultTab?.verificationCheck(anyShown: true) : nil
      // A sign-in page left to the person: its tab offers Sign in as … (PasswordVault.taskAccounts)
      // and Do it myself. The tab is the one the board keeps (AgentTabBoard.finished).
      let own = task.tabs.filter { $0.owner == id }
      let kept = resultTab ?? (own.count == 1 ? own[0] : nil)
      let signIn = stored == .waiting && check == nil && kept?.owner == id ? await kept?.signInHost() : nil
      guard tasks[id]?.finished == false else { throw SereinError.invalid("The task ended during this operation") }
      finishTurn(
        id, outcome: outcome, summary: a["summary"] as? String, result: resultTab, check: check, signIn: signIn,
        source: .agent)
      return ["outcome": outcome, "summary": a["summary"] ?? ""]
    }
    guard let tid = a["tab"] as? String, let tab = task.tabs.first(where: { $0.id == tid }) else {
      throw SereinError.invalid("Tab does not belong to this task")
    }
    // A tab the agent does not own is the user's. Driving it skips the connect proxy.
    // not run on a real Mac. Mac run not verified.
    // Removing this check drives a tab the agent does not own.
    guard AgentTabGate.mayDrive(
      owner: tab.owner,
      task: id,
      defaultStore: tab.web.configuration.websiteDataStore === WKWebsiteDataStore.default()
    ) else {
      throw SereinError.invalid("The agent does not drive a tab it does not own.")
    }
    if takeoverCards.holds(tab) { return ["tab": tid, "person_step": TakeoverCard.held] }
    // Nothing is read or done on a site the person set to Never; leaving it (go, back, close) is.
    if !["go", "back", "close"].contains(name) { try checkSiteRule(tab) }
    switch name {
    case TakeoverCard.tool:
      return askPersonTakeover(tab, task: id, reason: a["reason"] as? String ?? "")
    case "go":
      guard let url = a["url"] as? String else { throw SereinError.invalid("Missing URL") }
      try Self.check(try BrowserPolicy.url(url), task)
      try await authorizeSite(url, taskID: id)
      try await useKeptSignIn(
        url, taskID: id, into: tab.web.configuration.websiteDataStore, tool: raw, arguments: a, operationID: operationID)
      // Its card can wait: a tab the person took over meanwhile is theirs, never driven.
      guard AgentTabGate.mayDrive(
        owner: tab.owner, task: id, defaultStore: tab.web.configuration.websiteDataStore === WKWebsiteDataStore.default())
      else { throw SereinError.invalid("The agent does not drive a tab it does not own.") }
      try tab.navigate(url)
      return try await pageAfter(tab, task: id, full: full)
    case "close":
      guard tab.owner == id else {
        throw SereinError.invalid("Shared personal tabs cannot be closed by an agent")
      }
      tab.discardPage()
      task.tabs.removeAll { $0.id == tid }
      tasks[id] = task
      agentTabs.closed(tid)
      return ["closed": tid]
    case "back":
      // The previous address is known before the page moves. A new site asks. The gate judges
      // the move. WebKit starts the back a moment later; wait for the address or loading to change.
      guard let previous = tab.web.backForwardList.backItem?.url else {
        throw SereinError.invalid("There is no page to go back to.")
      }
      try Self.check(try BrowserPolicy.url(previous.absoluteString), task)
      try await authorizeSite(previous.absoluteString, taskID: id)
      let relay = relayTask(id, tasks[id])
      let standing = self.standing(task: id, else: RelayOrchestrator.standing(relay, present: !isUnattended(task: id)))
      var gate = ApprovalGate.webAction(
        name: "back", arguments: [:], site: previous.host, pageVersion: tab.pageVersion)
      gate.effect = .navigate
      let rule = SiteRules.rule(for: previous.absoluteString)
      // authorizeSite refused a Never site already; the door's siteNever line is the fallback.
      let decision = try ApprovalDoor.answer(
        .init(.action(gate), standing, site: rule),
        facts: .init(
          secureField: false, botCheck: false, pays: .no, covered: false, path: nil, hostKeyChanged: nil,
          runsAnything: false, ref: "")
      ).decision()
      if decision == .ask {
        let askRelay = relay ?? RelayOrchestrator.shared
        guard let askRelay else { throw SereinError.invalid(ActionAdmission.needsPerson) }
        let whereTo = previous.host ?? "the previous page"
        let human = await askRelay.confirmAnswer(
          "Serein wants to go back",
          "This returns to \(whereTo).",
          thread: threadID(forTask: id), effect: .navigate)
        guard human == .yes else {
          throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson)
        }
      }
      let before = tab.web.url
      tab.web.goBack()
      for _ in 0..<6 where tab.web.url == before && !tab.web.isLoading {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      if let landed = tab.web.url, landed.host != previous.host {
        do {
          try await authorizeSite(landed.absoluteString, taskID: id)
        } catch {
          tab.web.goForward()
          throw error
        }
      }
      return try await pageAfter(tab, task: id, full: full)
    case "wait":
      // The agent asks to let the page finish: a page that updates every 200 ms (progress text, a
      // timer) is not done after 150 ms of quiet, so wait for half a second of it, as before.
      await tab.settle(quiet: 0.5)
      fallthrough
    case "read":
      // A read straight after open waits for the first document instead of failing.
      if a["frame"] == nil && tab.web.isLoading { await tab.settle(limit: 5) }
      return try await pageOutline(tab, task: id, start: a["start"] as? Int ?? 0, frame: a["frame"] as? String)
    case "find":
      // The same read as read (every exclusion and note), answered with the matching rows only.
      if tab.web.isLoading { await tab.settle(limit: 5) }
      let page = try await pageOutline(tab, task: id, start: 0, frame: nil)
      // The find replaced the tab's references: the whole read is the latest page for repl.
      tasks[id]?.pages[tab.id] = AgentPrivacy.sanitize(page) as? [String: Any]
      return PageFind.result(page: page, role: a["role"] as? String, text: a["text"] as? String)
    case "screenshot":
      let shot = try await blankedSnapshot(tab)
      guard tasks[id] != nil else {
        throw SereinError.invalid("The task ended during this operation")
      }
      let png = shot.png
      // The agent's copy is drawn at a size no provider scales down, so click_point's x and y are
      // pixels of the very image the model saw (a Retina picture is twice the view's points).
      let size = PointClick.agentPixels(width: shot.bitmap.pixelsWide, height: shot.bitmap.pixelsHigh)
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size.width, pixelsHigh: size.height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
      else { throw SereinError.invalid("Screenshot unavailable") }
      bitmap.size = NSSize(width: size.width, height: size.height)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
      NSGraphicsContext.current?.imageInterpolation = .high
      shot.image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height))
      NSGraphicsContext.restoreGraphicsState()
      guard let agentPNG = bitmap.representation(using: .png, properties: [:]) else {
        throw SereinError.invalid("Screenshot unavailable")
      }
      // The helper reads at most 2 MB (LocalSocket), so a PNG too big for it goes to the agent
      // as a JPEG, smaller at each step. The chat keeps the full-size PNG.
      var picture = agentPNG, kind = "image/png"
      for quality in [0.85, 0.6, 0.35] where picture.count >= 1_200_000 {
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { break }
        (picture, kind) = (jpeg, "image/jpeg")
      }
      guard picture.count < 1_200_000 else {
        throw SereinError.invalid("Screenshot exceeds transport limit")
      }
      // The same blanked picture shows in the task's chat.
      if let saved = saveChatPicture(png) { onTaskPicture?(id, saved) }
      var content: [[String: Any]] = [["type": "image", "mimeType": kind, "data": picture.base64EncodedString()]]
      // With Click & type on, the picture serves one click_point, whose x and y are its pixels.
      if task.allowActions {
        notePointShot(
          tab, task: id, before: shot.before, after: shot.after, width: size.width, height: size.height)
        content.append(["type": "text", "text": "\(size.width)×\(size.height) pixels; click_point takes x and y in these pixels."])
      }
      return ["content": content]
    case "page_tool":
      // A page's own tool can change what the page holds: it needs Click & type, like a click.
      guard task.allowActions else {
        throw SereinError.invalid(
          "Website actions are off. Ask the user to enable clicks and typing for a new task.")
      }
      let r = try await pageTool(tab, task: id, arguments: a)
      // Like a click: a site tool can open a dialog, and a later read must not answer it.
      tasks[id]?.consentHosts.insert(tab.verificationHost)
      return r
    case "do":
      guard tab.owner == id else {
        throw SereinError.invalid("Fast steps work only in tabs this task opened.")
      }
      guard FastSteps.available else {
        throw SereinError.invalid("Fast steps are off. The user turns them on in Settings.")
      }
      tasks[id]?.simpleActions = 0
      return try await fastSteps(tab, task: id, arguments: a)
    case "upload":
      // A file the user attached to this turn, into one file field, after its own card (PageUpload.swift).
      let uploaded = try await upload(tab, task: id, arguments: a)
      guard tasks[id] != nil else { throw SereinError.invalid("The task ended during this operation") }
      return ["result": uploaded, "page": try await pageAfter(tab, task: id, full: full)]
    case "secure_card":
      guard let ref = a["ref"] as? String else { throw SereinError.invalid("Missing ref") }
      return try await secureCard(tab, task: id, ref: ref)
    case "click", "type", "select", "hover", "scroll", "key", "click_point":
      // A password, card or code field takes the person's secure card; the model's text is dropped.
      if name == "type", let ref = a["ref"] as? String, await isSecureField(tab, ref: ref) {
        return try await secureCard(tab, task: id, ref: ref)
      }
      // PageKit checks the field's final value too (append and key paths).
      if name == "type", HandBack.containsCardNumber(a["text"] as? String ?? "") {
        throw SereinError.invalid(HandBack.message)
      }
      let r: Any
      let actedHost = tab.verificationHost
      // A spot in a screenshot asks on a card of its own and is never admitted ahead.
      if name == "click_point" {
        r = try await clickPoint(tab, task: id, arguments: a)
      } else {
        r = try await runWebAction(
          name: name, arguments: a, tab: tab, taskID: id, admitted: admitted,
          allowed: { [weak self] in self?.tasks[id] != nil })
      }
      guard tasks[id] != nil else {
        throw SereinError.invalid("The task ended during this operation")
      }
      // Once the agent acts on a site, Serein stops answering overlays there: a later read must not
      // close the dialog its own click opened. A scroll or hover leaves a popup it triggers answered.
      if ["click", "type", "select", "key", "click_point"].contains(name) { tasks[id]?.consentHosts.insert(actedHost) }
      var out: [String: Any] = ["result": r, "page": try await pageAfter(tab, task: id, acting: a, full: full)]
      // Agents did not pick do on their own (0 calls in the 32 bench runs that offered it), so the hint goes where they
      // look every turn: in the result, after three simple steps in a row.
      // Read first, then written, so no statement holds overlapping accesses to `tasks`.
      let simpleActions: Int = ["click", "type", "select"].contains(name) ? (tasks[id]?.simpleActions ?? 0) + 1 : 0
      tasks[id]?.simpleActions = simpleActions
      if (tasks[id]?.simpleActions ?? 0) >= 3, FastSteps.available {
        tasks[id]?.simpleActions = 0
        out["hint"] =
          "Three simple steps in a row. Hand the remaining clear steps on this page to do (goal, inputs, checks): it is much faster than one tool call per step."
      }
      return out
    default: throw SereinError.invalid("Unknown browser tool")
    }
  }
  /// Ends the task's turn with `outcome`, from the agent's finish call or from Serein's own hand-off
  /// of a verification check (`check`, `source` .host): the board keeps `result` as the result tab,
  /// and the run takes the outcome (see AgentHub.complete). With a check the run reads "Needs you:
  /// verification check on …", and the tab offers Take over, then Hand back.
  func finishTurn(
    _ id: String, outcome: String, summary: String?, result: BrowserTab?, check: VerificationCheck? = nil,
    signIn: (host: String, codeOnly: Bool)? = nil, source: AgentHistoryEvent.Source
  ) {
    agentTabs.finished(
      task: id, outcome: outcome, summary: summary, result: result, verification: check?.host, signIn: signIn?.host,
      codeOnly: signIn?.codeOnly ?? false)
    if let run = agentTabs.run(for: id) {
      run.reportedOutcome = RunRecord.Outcome(reported: outcome)
      run.verification = check?.host
      run.recordBehavior(.outcomeReported, source: source, outcome: run.reportedOutcome)
      run.reportedSummary = summary.map { String($0.prefix(600)) }
      // The answer came before finish (WebTaskPrompt), so the run ends here: the model turn after
      // finish was 3-6 s of every web task in the bench. The call can reach this socket before the
      // CLI's output carries the answer, so the run ends 2.5 s later.
      // Ended after this call returns: ending inside it would revoke the task it still writes.
      if let hub = agentTabs.hub {
        run.finishCalled = true
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 2_500_000_000)
          hub.endAtFinish(run)
        }
      }
    }
    tasks[id]?.finished = true
  }

  /// Every task has a site list. The first site asks before it is recorded.
  /// Another site asks, and the yes is kept on this task only. An ended pass asks and then refuses.
  func sites(for taskID: String) -> [String] {
    (tasks[taskID]?.pass?.sites ?? []).sorted()
  }

  func setSites(_ hosts: [String], taskID: String) {
    guard var task = tasks[taskID] else { return }
    var pass = task.pass ?? TaskPass.begin(taskID: taskID)
    pass.replace(with: hosts)
    task.pass = pass
    tasks[taskID] = task
  }

  /// The person's rule for `address` as the door reads it for this exact call: Ask every step
  /// reads as normal once the person said yes to this call on its person_step confirm card,
  /// which only their answer grants (`personStepAnswered`, R16). The yes covers one call.
  func siteRule(_ address: String?, tool: String, arguments: [String: Any], task: String) -> SiteRule {
    let rule = SiteRules.rule(for: address)
    guard rule == .ask, let relay = RelayOrchestrator.shared,
      relay.takesConfirm(tool: tool, argsHash: PersonStep.argsHash(arguments), path: nil, task: task)
    else { return rule }
    return .normal
  }

  /// An Ask every step site asks nothing here: moving there reads, and each changing step there
  /// goes to the person's confirm card (`ApprovalDoor`, `siteRule`).
  func authorizeSite(_ raw: String, taskID: String) async throws {
    // A Never rule refuses before any card, for every task (SiteRules), and so does a site turned
    // off for the assistant whose task this is (AssistantScope).
    try SiteRules.check(raw)
    try assistantSiteCheck(raw, taskID: taskID)
    var pass = tasks[taskID]?.pass ?? TaskPass.begin(taskID: taskID)
    if pass.ended { throw SereinError.invalid(ActionAdmission.needsPerson) }
    let host = TaskPass.host(raw)
    guard !host.isEmpty else { return }
    switch TaskPass.admit(pass: &pass, site: host) {
    case .already:
      tasks[taskID]?.pass = pass
      return
    case .ask:
      // At Allow all, and in a task at Proactive, a new site takes no card.
      if taskStandsProactive(taskID) || RelayOrchestrator.shared?.level == .proactive {
        pass.allow(site: host)
        tasks[taskID]?.pass = pass
        return
      }
      let relay = relayTask(taskID, tasks[taskID]) ?? RelayOrchestrator.shared
      guard let relay else { throw SereinError.invalid(ActionAdmission.needsPerson) }
      let first = pass.sites.isEmpty
      let human = await relay.confirmAnswer(
        "Serein wants to act on \(host)",
        first
          ? "Allow this task to act on \(host). A yes covers only this task."
          : "This task did not start on this site. A yes covers only this task.",
        thread: threadID(forTask: taskID))
      guard human == .yes else {
        throw SereinError.invalid(human == .no ? ActionAdmission.declined : ActionAdmission.needsPerson)
      }
      pass.allow(site: host)
      guard !pass.needsSiteAsk(site: host) else { throw SereinError.invalid(ActionAdmission.needsPerson) }
      tasks[taskID]?.pass = pass
    }
  }

  /// Judges a page action, records the intent, and asks when the effect needs a person.
  /// `admitted` is a yes already given for that intent. A higher live effect, or a different
  /// element, still stops the action.
  /// The returned intent is checked again against the live element inside `frameAction`.
  func admitWebAction(
    name: String, arguments: [String: Any], tab: BrowserTab, taskID: String,
    admitted: ApprovalGate.ActionIntent? = nil
  ) async throws -> ApprovalGate.ActionIntent {
    // Refused before any ask: nobody is asked to approve a press in a verification check. The same
    // rule as the press (FrameBridge.frameAction): an accessibility ref counts any check shown.
    let accessibilityRef = (arguments["ref"] as? String)?.hasPrefix("x") == true
    if let check = await tab.verificationCheck(arguments, anyShown: accessibilityRef) { throw check }
    if !tab.address.isEmpty { try await authorizeSite(tab.address, taskID: taskID) }
    let live = await tab.elementFacts(name: name, arguments: arguments)
    guard live.connected else { throw SereinError.invalid(ActionAdmission.pageChanged) }
    let site = URL(string: tab.address)?.host
    let gate = ActionAdmission.action(
      name: name, arguments: arguments, site: site, pageVersion: tab.pageVersion, live: live)
    // `action` stored the classification from the live reading. Use that, then the press reads again.
    let effect = gate.effect ?? ApprovalGate.resolved(gate)
    if let admitted, admitted.elementID != gate.elementID || admitted.pageVersion != tab.pageVersion {
      throw SereinError.invalid(ActionAdmission.pageChanged)
    }
    // A yes is for one effect. Next becoming Pay is a new ask, not a press.
    let reused = admitted?.effect == effect && admitted?.passwordForm == gate.passwordForm ? admitted : nil
    let relay = relayTask(taskID, tasks[taskID])
    // No relay means ask. A task's click switch is not Autopilot.
    let scheduled = isUnattended(task: taskID)
    // With nobody watching, reading, and a plain click or key move on a site the person's own
    // words name, follow their ask level; every other step asks on a deferred card. The site is
    // the one the step lands in: another site's frame inside the tab is that site. A key on a
    // field, list, slider or switch changes a value, so it is not a key move.
    let moves = name != "key" || UnattendedAuthority.keyMoves(on: live.reading)
    let covered: Bool = moves && relay?.wordsCover(effect, site: tab.actionSite(arguments)) == true
    // The site rule only raises: Ask every step parks a change on person_step until the
    // person's yes covers this exact call.
    let rule = siteRule(tab.address, tool: name, arguments: arguments, task: taskID)
    let request = ApprovalDoor.Request(
      .action(gate), standing(task: taskID, else: RelayOrchestrator.standing(relay, present: !scheduled)), site: rule,
      taskID: taskID)
    let readback = ActionAdmission.readback(effect: effect, label: gate.label ?? live.label, reading: live.reading)
    // The person's secure card submit answers the one sign-in or pay press after it, on the same
    // page (SecureCard.Pass); the door journals the step when it runs. Any other step leaves it.
    var passed = false
    if let pass = tasks[taskID]?.securePasses[tab.id] {
      let pressed = arguments["ref"] as? String
      var inForm = false
      if let field = pass.field, let pressed { inForm = await tab.sharesForm(field, pressed, arguments: arguments) }
      passed = reused == nil && StepJournal.live?.stuck == nil
        && pass.covers(effect: effect, tool: name, key: arguments["key"] as? String, tab: tab.id,
                       pageVersion: tab.pageVersion, amount: readback.amount, ref: pressed, inForm: inForm)
      if passed || pass.usedUp(effect: effect, tool: name, key: arguments["key"] as? String, inForm: inForm) {
        tasks[taskID]?.securePasses[tab.id] = nil
      }
    }
    // A pay press the page does not let Serein read may pay. A send or delete it cannot read
    // follows the level like any other step.
    let pays: ApprovalDoor.PaySense =
      effect != .pay ? .no : readback.readable ? .yes(amount: readback.amount) : .unreadable
    let doorAnswer = ApprovalDoor.answer(request, facts: .init(
      secureField: !gate.passwordForm.isEmpty && !passed && reused == nil, botCheck: false,
      pays: pays, covered: passed || reused != nil, path: nil,
      hostKeyChanged: nil, runsAnything: false, ref: arguments["ref"] as? String ?? ""))
    // Paying shows no approval card: the person's submit on the secure card is the yes.
    if case .blocked(.pay) = doorAnswer { throw SereinError.invalid(SecureCard.payOnCard) }
    var decision = try doorAnswer.decision()
    // The secure card's submit is the yes on a card the door showed: the journal writes it down first.
    if passed, decision == .ask, let live = StepJournal.live, !live.allowed() {
      throw SereinError.invalid("The step was not run because the task's step record could not be saved.")
    }
    // A standing yes for routine steps here (this task, or always on the site) answers instead of
    // a card; it never covers a hard stop, a scheduled run or a site set to ask or Never, and it
    // stands only in a turn the person started (`standingYesStands`), or for a step the person's
    // words cover in a run nobody watches: never for a link, a light ask, a paired app, a
    // hand-off or anything else a schedule or check-in does.
    // Grants are kept by the site as its rules name it (“shop.example.com”, without www).
    let grantSite = SiteRules.site(tab.address)
    let standing: Bool = !scheduled && standingYesStands(task: taskID)
    if standing || covered,
      RoutineGrants.covers(decision: decision, effect: effect, site: grantSite, rule: rule, scheduled: scheduled,
                           covered: covered, taskSites: tasks[taskID]?.routineSites ?? [], alwaysSites: RoutineGrants.sites())
    {
      decision = .auto
    }
    let intent = reused ?? ApprovalGate.record(gate, effect: effect, mint: { UUID().uuidString })
    if reused == nil, let pending = tasks[taskID]?.pendingApprovals {
      tasks[taskID]?.pendingApprovals = ApprovalGate.mergePending(pending, intent)
    }
    try SiteRules.check(tab.address)
    let answer: ApprovalGate.HumanAnswer
    if decision == .auto || reused != nil || passed {
      answer = .yes
    } else {
      let askRelay = relay ?? RelayOrchestrator.shared
      guard let askRelay else { throw SereinError.invalid(ActionAdmission.needsPerson) }
      if live.reading.consent == "accept" {
        // An overlay's accept choice is named for what it does. Decline leaves the overlay.
        // A raised effect (a price, "Accept & pay") keeps its own line: the card states what it approves.
        let detail = "This agrees to everything the banner asks, including sharing with the site’s partners. Decline leaves the banner as it is."
        answer = await askRelay.confirmAnswer(
          "Accept all cookies on \(site ?? "this site")?",
          effect == .access ? detail : detail + "\n" + readback.summary,
          button: "Accept all", thread: threadID(forTask: taskID), site: site)
      } else if live.reading.consent == "private" {
        // The private choice is named too. It asks only where a plain click asks, or where a guard
        // (price, card, form) raised it; then the card carries the gate's own effect line.
        let choice = (gate.label ?? live.label).prefix(60)
        answer = await askRelay.confirmAnswer(
          "Choose '\(choice)' on \(site ?? "this site")?",
          effect == .click
            ? "This answers the site’s banner with the option that shares the least. Decline leaves the banner as it is."
            : readback.summary,
          button: "Choose", thread: threadID(forTask: taskID), site: site)
      } else {
        let title = "Serein wants to \(name) on this page"
        // A routine step may be allowed for the rest of the task, or always on this site.
        var offer: RelayOrchestrator.Approval.GrantOffer?
        if let grantSite, RoutineGrants.qualifies(effect), standing, rule == .normal {
          offer = .init(site: grantSite, forTask: { [weak self] in self?.tasks[taskID]?.routineSites.insert(grantSite) },
                        always: { RoutineGrants.allow(grantSite) })
        }
        answer = await askRelay.confirmAnswer(title, readback.summary, thread: threadID(forTask: taskID), site: site,
                                              effect: effect, grants: offer)
      }
    }
    // A yes given before the site became Never does not press (the rule is read again).
    try checkSiteRule(tab)
    guard ApprovalGate.beforeInput(
      intent: intent, answer: answer, liveElement: live.bind, liveVersion: tab.pageVersion, liveEffect: effect)
    else {
      throw SereinError.invalid(ActionAdmission.blocked(
        answer: answer, decision: decision, effectChanged: effect != intent.effect))
    }
    tab.noteApprovedElement(try? tab.actionFrame(arguments))
    return intent
  }

  /// `answerOverlay` false leaves an overlay to the agent (the page after its own click, type, select
  /// or key: a dialog it just opened is not closed); the read still lists the options.
  func pageOutline(_ tab: BrowserTab, task id: String, start: Int, frame: String?, answerOverlay: Bool = true)
    async throws -> [String: Any]
  {
    try checkSiteRule(tab)
    var r = try await tab.frameOutline(start: start, frameID: frame)
    guard tasks[id] != nil else {
      throw SereinError.invalid("The task ended during this operation")
    }
    if frame == nil, answerOverlay, let cleared = try await clearConsent(r, tab: tab, task: id, start: start) {
      r = cleared
    }
    let rows = r["elements"] as? [[String: Any]] ?? []
    // The task's own tabs also get what the accessibility tree knows; the centres are dropped either way.
    if frame == nil, tab.owner == id, let tree = await PageAX.controls(tab) {
      r["elements"] = PageAX.merge(rows, tree)
    } else {
      r["elements"] = rows.map { $0.filter { $0.key != "x" && $0.key != "y" } }
    }
    // One map of the page: the controls of its visible child frames come after the page's own,
    // each with its frame and site (FrameMap). After the accessibility merge, whose tree holds the
    // top document only. A frame on a site the person or this task's assistant keeps agents off
    // is not read. A page that shows no frame reads none.
    let shownFrames = FrameMap.shownFrames(r)
    r["shown_frames"] = nil
    if frame == nil, shownFrames > 0 {
      let children = await tab.childFrameReads(shown: shownFrames) { url in
        do {
          try SiteRules.check(url.absoluteString)
          try assistantSiteCheck(url.absoluteString, taskID: id)
          return true
        } catch { return false }
      }
      guard tasks[id] != nil else { throw SereinError.invalid("The task ended during this operation") }
      r = FrameMap.merge(r, children: children)
    }
    r["tab"] = tab.id
    r["loading"] = tab.loading
    // The page's own tools, fenced as page text: only for the whole tab, and only while allowed.
    r["page_tools"] = frame == nil ? pageToolListing(r["page_tools"], tab: tab) : nil
    if r["sensitive"] as? Bool == true {
      let secure = (r["elements"] as? [[String: Any]])?.contains { $0["secure"] != nil } == true
      r["user_note"] = secure ? SecureCard.readNote : HandBack.message
    }
    // A verification check that stops the page is the person's: the read says so (needs_user,
    // captcha). An inline one leaves the rest of the page to the agent, and the read says that.
    if let check = r["challenge"] as? [String: Any] {
      if check["blocks"] as? Bool == true {
        r.merge(botCheck(VerificationCheck(host: tab.verificationHost), tab: tab.id, task: id)) { _, new in new }
      } else if (r["user_steps"] as? [String]) == ["captcha"] {
        // The inline check is the only step that is the person's: one note, not "finish now".
        r["user_note"] = VerificationCheck.inlineNote
      } else {
        r["challenge_note"] = VerificationCheck.inlineNote
      }
    }
    // An overlay's option words are the page's: fenced like any page text.
    if var consent = r["consent"] as? [String: Any], let options = consent["options"] as? [[String: Any]] {
      consent["options"] = options.map { option in
        var option = option
        option["label"] = PageFence.fence(option["label"] as? String ?? "")
        return option
      }
      r["consent"] = consent
      r["consent_note"] = "An overlay covers this page. To clear it, click the option of kind private (it shares the least). An accept choice always asks the user."
    }
    return r
  }
  /// Answers a cookie, consent, survey or newsletter overlay on the task's own page before the agent
  /// acts there. It runs on the read the agent acts from (read, and the page after open, go or back;
  /// never on a site after the agent's own click, click_point, typing, select or key there, which may
  /// have opened the dialog), not in `admitWebAction`: a press there would drop the refs of the action
  /// that asked.
  /// The choice is an ordinary gated click (`runWebAction`: decide, record, ask, press check), so the
  /// private option passes without a card only where any plain click would. With only an accept
  /// choice its card asks; Decline leaves the overlay and the run waits for the person (needs_user).
  /// Once per site and task. Returns the page after the choice, or nil when nothing was pressed.
  private func clearConsent(_ page: [String: Any], tab: BrowserTab, task id: String, start: Int) async throws
    -> [String: Any]?
  {
    guard Self.mostPrivate, tab.owner == id, tasks[id]?.finished == false, tasks[id]?.allowActions == true,
      let options = (page["consent"] as? [String: Any])?["options"] as? [[String: Any]],
      (page["challenge"] as? [String: Any])?["blocks"] as? Bool != true
    else { return nil }
    func first(_ kind: String) -> [String: Any]? { options.first { $0["kind"] as? String == kind } }
    // Only neutral choices (manage, settings): the agent decides, and an accept behind them still asks.
    guard let pick = first("private") ?? first("accept"), let ref = pick["ref"] as? String else { return nil }
    let host = tab.verificationHost
    guard tasks[id]?.consentHosts.insert(host).inserted == true else { return nil }
    let label = String((pick["label"] as? String ?? "").prefix(60))
    // Serein's own press is a step like the agent's: in the step list and in behaviour history.
    let operation = UUID()
    let context = behaviorContexts[id]
    if let context, !recordBehavior(context, .toolRequested, operationID: operation, tool: .browser("click")) { return nil }
    agentTabs.step(task: id, tool: "click", arguments: ["tab": tab.id, "ref": ref])
    do {
      _ = try await runWebAction(
        name: "click", arguments: ["tab": tab.id, "ref": ref], tab: tab, taskID: id,
        allowed: { [weak self] in self?.tasks[id] != nil })
      if let context { recordBehavior(context, .toolReturned, operationID: operation, tool: .browser("click")) }
    } catch {
      if let context { recordBehavior(context, .toolFailed, operationID: operation, tool: .browser("click")) }
      agentTabs.stepFailed(task: id, tool: "click", AgentPrivacy.redact(error.localizedDescription))
      // A declined or unanswered private choice leaves the overlay to the agent; an accept stops the run.
      let reason = (error as? SereinError)?.errorDescription
      guard pick["kind"] as? String == "accept",
        reason == ActionAdmission.declined || reason == ActionAdmission.needsPerson,
        tasks[id]?.finished == false
      else { return nil }
      let message = "The cookie banner on \(host) is the user's to answer: Serein does not accept all cookies without them."
      if agentTabs.run(for: id) != nil {
        finishTurn(id, outcome: RunRecord.Outcome.waiting.rawValue, summary: message, result: tab, source: .host)
      }
      var stopped = page
      stopped["needs_user"] = true
      stopped["user_note"] = message
      stopped["message"] = message
      return stopped
    }
    onTaskChoice?(id, "Chose '\(label)' on \(host)")
    await tab.settleAfterAction()
    guard tasks[id] != nil else { throw SereinError.invalid("The task ended during this operation") }
    return try await tab.frameOutline(start: start, frameID: nil)
  }
  /// The page after an action or a navigation, so the agent needs no extra read call. An action
  /// in a child frame returns that frame, so the main page's references stay valid.
  func pageAfter(_ tab: BrowserTab, task id: String, acting a: [String: Any] = [:], full: Bool = false)
    async throws -> [String: Any]
  {
    await tab.settleAfterAction()
    guard tasks[id] != nil else {
      throw SereinError.invalid("The task ended during this operation")
    }
    // A redirect onto a Never site was not loaded; the agent learns why instead of "not readable".
    try checkSiteRule(tab, afterAction: true)
    var frame = a["frame"] as? String
    if let ref = a["ref"] as? String, ref.hasPrefix("e"), let end = ref.firstIndex(of: "_") {
      frame = String(ref[ref.index(after: ref.startIndex)..<end])
    }
    if let f = frame, tab.frames[f]?.isMainFrame != false { frame = nil }
    // The action already happened, so a page that cannot be read yet is not a failure.
    guard var page = try? await pageOutline(tab, task: id, start: 0, frame: frame, answerOverlay: a.isEmpty) else {
      return ["tab": tab.id, "loading": tab.loading, "note": "The page is not readable yet. Use wait."]
    }
    // A short page: every action result carrying the whole text (up to 24,000 characters) made each
    // agent turn slower than the read it saved (bench, 16 jobs: 857 s against 560 s). read has the rest.
    if !full, let text = page["text"] as? String, text.count > Self.shortText {
      page["text"] = String(text.prefix(Self.shortText))
      page["next_start"] = nil
      page["text_note"] = "Shortened after the action. Use read for the full text."
    }
    return page
  }
  static let shortText = 1500
  /// Refuses a tab on a site the person set to Never, and reports a load the tab refused for it.
  /// `afterAction` (only `pageAfter`): the action ran before the refused load, so it says so.
  func checkSiteRule(_ tab: BrowserTab, afterAction: Bool = false) throws {
    if let blocked = tab.ruleBlocked {
      tab.ruleBlocked = nil
      let assistant = tab.ruleBlockedByAssistant ? (tab.owner.flatMap { assistantScope(forTask: $0)?.profile.name } ?? "This assistant") : nil
      throw SiteRuleRefusal(site: SiteRules.site(blocked) ?? blocked, redirect: afterAction, assistant: assistant)
    }
    try SiteRules.check(tab.address)
    // An agent tab's owner is its task: that assistant's own Never sites apply too.
    if let owner = tab.owner { try assistantSiteCheck(tab.address, taskID: owner) }
  }
  /// repl's fetch: an address read without a page. GET only, the same address checks as go (each
  /// redirect too), and only in tasks without the user's sign-ins: a raw page can carry tokens that
  /// a read never shows. The body is redacted before it is cut.
  private func fetch(_ address: String, task: BrowserTask) async throws -> [String: Any] {
    guard task.isolated else {
      throw SereinError.invalid("fetch works only in tasks without the user's sign-ins. Open the page and read it.")
    }
    let url = try BrowserPolicy.url(address)
    try Self.check(url, task)
    try assistantSiteCheck(url.absoluteString, taskID: task.capability.task)
    // ponytail: no cookies (an isolated task has no sign-ins); send the task store's if sites need them.
    let configuration = URLSessionConfiguration.ephemeral
    // Through a connect proxy when one is set (the verification harness sets one), else direct.
    if let endpoint = ConnectProxy.endpoint() {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: 1,
        kCFNetworkProxiesHTTPProxy as String: endpoint.host,
        kCFNetworkProxiesHTTPPort as String: endpoint.port,
        kCFNetworkProxiesHTTPSEnable as String: 1,
        kCFNetworkProxiesHTTPSProxy as String: endpoint.host,
        kCFNetworkProxiesHTTPSPort as String: endpoint.port,
      ]
    }
    let session = URLSession(configuration: configuration, delegate: FetchRedirects(task.allows), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 10))
    try SiteRules.check(response.url?.absoluteString)
    let http = response as? HTTPURLResponse, type = http?.mimeType ?? ""
    guard type.isEmpty || type.hasPrefix("text/") || ["json", "xml", "javascript"].contains(where: type.contains) else {
      return ["url": response.url?.absoluteString ?? address, "status": http?.statusCode ?? 0, "type": type, "body": "",
        "note": "Not text. Open the address in a tab instead."]
    }
    var data = Data()
    for try await byte in bytes {
      data.append(byte)
      if data.count >= 2_000_000 { break }
    }
    let body = AgentPrivacy.redact(String(decoding: data, as: UTF8.self))
    // The body stays inside the program; only what it logs reaches the model (Repl's output cap).
    return ["url": response.url?.absoluteString ?? address, "status": http?.statusCode ?? 0, "type": type,
      "body": body, "cut": data.count >= 2_000_000]
  }
  private static func check(_ url: URL, _ task: BrowserTask) throws {
    try SiteRules.check(url.absoluteString)
    if let allows = task.allows, !allows(url) {
      throw SereinError.invalid(
        "This agent may not open \(url.host ?? "this address"). The user sets its sites in Serein › Settings › AI apps.")
    }
  }
}

/// A connect proxy published as `SEREIN_CONNECT_PROXY` (`host:port`), which the verification
/// harness sets. Agent tabs and fetch use it when set and dial out directly when not. User tabs
/// never do.
enum ConnectProxy {
  static let envName = "SEREIN_CONNECT_PROXY"

  static func endpoint() -> (host: String, port: Int)? {
    guard let raw = ProcessInfo.processInfo.environment[envName] else { return nil }
    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port), !parts[0].isEmpty else {
      return nil
    }
    return (parts[0], port)
  }

  static func webKitConfiguration() -> ProxyConfiguration? {
    guard let endpoint = endpoint(), let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return nil }
    return ProxyConfiguration(httpCONNECTProxy: NWEndpoint.hostPort(host: NWEndpoint.Host(endpoint.host), port: port))
  }
}

/// Each redirect of a repl fetch or a URL watch passes the same checks as the first address.
final class FetchRedirects: NSObject, URLSessionTaskDelegate {
  let allows: ((URL) -> Bool)?
  init(_ allows: ((URL) -> Bool)?) { self.allows = allows }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest) async -> URLRequest?
  {
    guard let url = request.url, (try? BrowserPolicy.url(url.absoluteString)) != nil, allows?(url) ?? true, SiteRules.rule(for: url.absoluteString) != .never else { return nil }
    return request
  }
}
