import AppKit
import SereinCore
import SwiftUI
import WebKit

/// Tabs that agents open, grouped by run, kept visible while they work.
/// The board never grants access: BrowserModel.handle still checks every capability.
@MainActor final class AgentTabBoard: ObservableObject {
  struct Entry: Identifiable {
    let tab: BrowserTab
    let taskID: String
    var id: String { tab.id }
  }
  struct RunInfo {
    var agent = "The agent"
    var threadID: String?
    var title = ""
    var runID: String?
    var isolated = true
    var steps: [AgentStep] = []
    /// From the agent's finish call.
    var outcome: String?
    var summary: String?
    var resultTabID: String?
    var ended = false
    /// The assistant the task works for (its row in the sidebar's Assistants mode lists the
    /// page); nil for the person's own tasks.
    var assistant: String?
    /// For the tab banner ("worked in this tab · 7:28 PM") and the status pill's duration.
    var startedAt = Date()
    var endedAt: Date?
    /// The site whose verification check waits for the person (Take over, then Hand back).
    var verification: String?
    /// The host of the sign-in page the run stopped at: Sign in as … or Do it myself, then Hand back.
    var signIn: String?
    /// That page asks only for a verification code: Sign in as offers only logins with one saved.
    var signInCodeOnly = false
  }
  @Published private(set) var entries: [Entry] = []
  @Published private(set) var runs: [String: RunInfo] = [:]
  /// The agent tab shown when the browser section is "agent".
  @Published var focused: String?
  /// Result tabs the user has not looked at yet.
  @Published var unseen: Set<String> = []
  /// Set when the user tried to use a tab an agent is working in; the pane offers Take over.
  @Published var blockedInputAt: Date?
  weak var hub: AgentHub?
  /// Runs after a kept page closes, so the browser can remove a task store nothing uses now.
  var onDismiss: (() -> Void)?
  /// Result tabs kept after their runs end, at most (matches `AgentHub.trimFinished`).
  static let maxKept = 8
  /// Kept tabs nobody has looked at for this long are unloaded until they are opened again.
  static let idleUnload: TimeInterval = 600
  private var inputMonitor: Any?

  init() {
    // While an agent works in a tab, the user's clicks and keys never reach that page; the
    // pane shows "Take over to use this page" instead (see AgentTabLock).
    inputMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      let blocked = MainActor.assumeIsolated { self?.blocks(event) ?? false }
      return blocked ? nil : event
    }
  }

  /// True for input aimed at a working agent tab's page; that input is swallowed.
  func blocks(_ event: NSEvent) -> Bool {
    guard let window = event.window else { return false }
    for entry in entries where isWorking(entry.id) && entry.tab.web.window === window {
      let web = entry.tab.web
      let aimed: Bool
      if event.type == .keyDown {
        aimed = (window.firstResponder as? NSView)?.isDescendant(of: web) == true
      } else {
        let root = window.contentView?.superview ?? window.contentView
        aimed = root?.hitTest(event.locationInWindow)?.isDescendant(of: web) == true
      }
      if aimed {
        if event.type == .keyDown { window.makeFirstResponder(nil) }
        blockedInputAt = Date()
        return true
      }
    }
    return false
  }

  func register(_ run: AgentRun, hub: AgentHub) {
    self.hub = hub
    var info = runs[run.taskID] ?? RunInfo()
    info.agent = run.spec.provider.shortName
    info.threadID = run.spec.threadID
    info.title = run.spec.title
    info.runID = run.id
    info.assistant = RelayOrchestrator.shared?.assistantOwning(thread: run.spec.threadID)
    runs[run.taskID] = info
    // Record this task (TaskRecordings): starts only when the person turned it on for the thread.
    TaskRecordings.shared.runStarted(task: run.taskID, thread: run.spec.threadID)
  }
  /// An outside agent's session has no run; its tabs show the name the user paired it under.
  func name(task: String, agent: String) {
    var info = runs[task] ?? RunInfo()
    info.agent = agent
    runs[task] = info
  }
  func opened(_ tab: BrowserTab, task: String, isolated: Bool) {
    var info = runs[task] ?? RunInfo()
    info.isolated = isolated
    // The open step named no tab: it is the one it opened (a replay's step list shows it).
    if let last = info.steps.indices.last, ["open", "open_tab"].contains(info.steps[last].tool), info.steps[last].tab == nil {
      info.steps[last].tab = tab.id
    }
    runs[task] = info
    entries.append(Entry(tab: tab, taskID: task))
  }
  /// Per-task audit with timestamps (bug 16).
  func step(task: String, tool: String, arguments: [String: Any]) {
    var info = runs[task] ?? RunInfo()
    var step = AgentStep(tool: tool, label: AgentStep.label(tool: tool, arguments: arguments))
    step.tab = arguments["tab"] as? String
    info.steps.append(step)
    if info.steps.count > AgentTabPolicy.maxSteps { info.steps.removeFirst() }
    runs[task] = info
  }
  /// Names what the latest step did once it is known (an upload's field comes from the page).
  func relabelLast(task: String, tool: String, _ label: String) {
    guard var info = runs[task], let last = info.steps.indices.last, info.steps[last].tool == tool else { return }
    info.steps[last].label = label
    runs[task] = info
  }
  /// `ruleSite` names the site a Never rule refused: the step reads as the rule, not the
  /// model-facing refusal.
  func stepFailed(task: String, tool: String, _ message: String, ruleSite: String? = nil) {
    guard var info = runs[task], !info.ended,
      let last = info.steps.indices.last, info.steps[last].tool == tool,
      info.steps[last].failed == nil
    else { return }
    if let site = ruleSite {
      info.steps[last].failed = SiteRules.personLine(site)
      info.steps[last].ruleSite = site
    } else {
      info.steps[last].failed = message.contains("This step is yours")
        ? "Left for you" : String(message.prefix(120))
    }
    runs[task] = info
  }
  func finished(task: String, outcome: String, summary: String?, result: BrowserTab?, verification: String? = nil,
    signIn: String? = nil, codeOnly: Bool = false)
  {
    var info = runs[task] ?? RunInfo()
    info.outcome = outcome
    info.summary = summary.map { String($0.prefix(600)) }
    info.verification = verification
    info.signIn = signIn
    info.signInCodeOnly = signIn != nil && codeOnly
    info.endedAt = info.endedAt ?? Date()
    let own = entries.filter { $0.taskID == task }
    info.resultTabID = result?.id ?? (own.count == 1 ? own[0].id : nil)
    runs[task] = info
    if let id = info.resultTabID {
      unseen.insert(id)
      if let focused, own.contains(where: { $0.id == focused }) { self.focused = id }
    }
  }
  func closed(_ tabID: String) {
    entries.removeAll { $0.id == tabID }
    unseen.remove(tabID)
    if focused == tabID { focused = nil }
  }
  /// Keeps the result tab (or the only tab) after a task ends; the others are dropped.
  func taskEnded(_ task: String, tabs: [BrowserTab]) -> Set<String> {
    guard var info = runs[task] else { return [] }
    let own = entries.filter { $0.taskID == task }
    let keep =
      info.resultTabID.flatMap { id in own.first { $0.id == id }?.id }
      ?? (own.count == 1 ? own[0].id : nil)
    entries.removeAll { $0.taskID == task && $0.id != keep }
    info.ended = true
    info.endedAt = info.endedAt ?? Date()
    if let keep {
      info.resultTabID = keep
      runs[task] = info
      unseen.insert(keep)
      if let focused, own.contains(where: { $0.id == focused }) { self.focused = keep }
      own.first { $0.id == keep }?.tab.lastActive = Date()
      trimKept()
      return entry(keep) == nil ? [] : [keep]
    }
    runs[task] = nil
    if let focused, own.contains(where: { $0.id == focused }) { self.focused = nil }
    return []
  }
  /// Keeps at most `maxKept` result tabs from ended runs; the oldest go first.
  private func trimKept() {
    let kept = entries.filter { runs[$0.taskID]?.ended == true && $0.id != focused }
    let extra = entries.filter { runs[$0.taskID]?.ended == true }.count - Self.maxKept
    guard extra > 0 else { return }
    for entry in kept.prefix(extra) { dismiss(entry.id) }
  }
  /// Unloads kept result tabs nobody has looked at for a while, so their pages stop running.
  /// Opening one loads its page again (`BrowserTab.wake`).
  func unloadIdle(now: Date = Date()) {
    for entry in entries
    where runs[entry.taskID]?.ended == true && entry.id != focused && !entry.tab.sleeping
      && now.timeIntervalSince(entry.tab.lastActive) > Self.idleUnload
    {
      entry.tab.unload()
    }
  }
  /// A step the person took for the task (Sign in as …), carried into the run that took the tab back.
  func note(_ step: AgentStep, task: String) {
    guard var info = runs[task] else { return }
    info.steps.append(step)
    // The same cap as the agent's own steps: notes from Serein's computer can come often.
    if info.steps.count > AgentTabPolicy.maxSteps { info.steps.removeFirst() }
    runs[task] = info
  }
  /// A line about the step in flight (the kept sign-in an open used), put just before it, so that
  /// step stays last and its failure still marks it.
  func noteBefore(_ step: AgentStep, task: String) {
    guard var info = runs[task] else { return }
    info.steps.insert(step, at: max(info.steps.count - 1, 0))
    if info.steps.count > AgentTabPolicy.maxSteps { info.steps.removeFirst() }
    runs[task] = info
  }
  /// Removes a tab from the board without touching its page; used by take over.
  func release(_ tabID: String) -> RunInfo? {
    guard let entry = entry(tabID) else { return nil }
    closed(tabID)
    var info = runs[entry.taskID]
    info?.steps.append(AgentStep(tool: "take_over", label: "You took over this tab"))
    if let info { runs[entry.taskID] = info }
    if info?.ended == true && !entries.contains(where: { $0.taskID == entry.taskID }) {
      runs[entry.taskID] = nil
    }
    return info
  }
  /// Closes a kept tab once its run is over.
  func dismiss(_ tabID: String) {
    guard let entry = entry(tabID), runs[entry.taskID]?.ended != false else { return }
    entry.tab.discardPage()
    closed(tabID)
    if !entries.contains(where: { $0.taskID == entry.taskID }) { runs[entry.taskID] = nil }
    onDismiss?()
  }

  /// Synthetic UI previews describe a run without starting one.
  func describePreview(task: String, agent: String, threadID: String?, title: String,
    steps: [AgentStep], startedAt: Date)
  {
    var info = runs[task] ?? RunInfo()
    info.agent = agent
    info.threadID = threadID
    info.title = title
    info.steps = steps
    info.startedAt = startedAt
    runs[task] = info
  }
  func entry(_ tabID: String) -> Entry? { entries.first { $0.id == tabID } }
  func info(_ tabID: String) -> RunInfo? { entry(tabID).flatMap { runs[$0.taskID] } }
  func isWorking(_ tabID: String) -> Bool {
    guard let info = info(tabID) else { return false }
    return !info.ended && info.outcome == nil
  }
  func run(for task: String) -> AgentRun? {
    guard let id = runs[task]?.runID else { return nil }
    return hub?.runs.first { $0.id == id }
  }
  /// Short line under the tab title and in the banner.
  func badge(_ tabID: String) -> String {
    guard let info = info(tabID) else { return "" }
    if isWorking(tabID) { return "\(info.agent) is working here" }
    if info.resultTabID == tabID, let bubble = bubble(tabID) { return "Result · " + bubble.title }
    return "\(info.agent) finished with this tab"
  }
  func bubble(_ tabID: String) -> TabBubble? {
    guard let entry = entry(tabID), let info = runs[entry.taskID],
      info.outcome != nil || info.ended
    else { return nil }
    let run = run(for: entry.taskID)
    var outcome = info.outcome
    if outcome == nil, let record = run?.record.outcome {
      outcome = record == .running ? nil : record.rawValue
    }
    return TabBubble.make(outcome: outcome, summary: info.summary, classified: run?.summary?.question)
  }
  func entries(thread: String?, known: Set<String>) -> [Entry] {
    entries.filter { entry in
      let owner = runs[entry.taskID]?.threadID
      if let thread { return owner == thread }
      return owner == nil || !known.contains(owner!)
    }
  }
}

extension BrowserModel {
  func viewAgentTab(_ tab: BrowserTab) {
    agentTabs.focused = tab.id
    agentTabs.unseen.remove(tab.id)
    tab.wake()
    section = ShellSection.agent
  }
  /// Gives the tab to the user with its page intact. While the agent still holds its browser
  /// capability, its run is stopped (revoking only that capability). Once the agent has called
  /// finish, or the run has ended, the tab is released and the run is left alone, so its final
  /// answer still arrives. Isolated tabs keep their ephemeral store and stay out of history.
  func takeOver(_ tab: BrowserTab) {
    guard let entry = agentTabs.entry(tab.id) else { return }
    let taskID = entry.taskID
    let agentHolds = tasks[taskID].map { !$0.finished } ?? false
    if var task = tasks[taskID] {
      task.tabs.removeAll { $0.id == tab.id }
      tasks[taskID] = task
    }
    let bubble = agentTabs.bubble(tab.id)
    let info = agentTabs.release(tab.id)
    if let info {
      // The row keeps the run's outcome bar when a finished tab is kept; a tab taken over
      // mid-run is simply the user's (no bar). The banner still says who worked here.
      tab.agentMark = TabAgentMark(
        agent: info.agent, threadID: info.threadID, taskID: taskID, title: info.title,
        summary: bubble?.text,
        status: agentHolds ? nil : bubble.map { AgentTabStatus.make(working: false, outcome: $0.kind.rawValue) },
        startedAt: info.startedAt, endedAt: info.endedAt ?? Date(), steps: info.steps,
        verification: info.verification, signIn: info.signIn, signInCodeOnly: info.signInCodeOnly)
    }
    tab.owner = nil
    tab.takenFrom =
      "Taken over from \(info?.agent ?? "the agent")"
      + (tab.privateMode ? " · isolated, no sign-ins" : "")
    if let hub = agentTabs.hub, let run = hub.runs.first(where: { $0.taskID == taskID && $0.isActive })
    {
      if agentHolds { hub.stop(run) }
    } else {
      endTask(taskID)
    }
    attach(tab)
    // From now on the tab is the user's: popups, downloads and passwords work as in any tab.
    PasswordCapture.adopt(tab)
    SiteFeatureBridge.adopt(tab)
    tabs.append(tab)
    selected = tab.id
    section = ShellSection.browser
    notice =
      tab.privateMode
      ? "This tab is yours now. It stays isolated: no sign-ins, and nothing is saved."
      : "This tab is yours now."
  }
  /// Whether a reply can ever continue this tab's chat: a saved chat, not Serein's own chat, and not
  /// a page task (that one works in a copy of the person's current tab). It ignores whether a step
  /// is running now, so a run that is just finishing still counts.
  func canResume(_ tab: BrowserTab) -> Bool {
    guard let thread = tab.agentMark?.threadID, let agent = intelligenceAgent,
      let chat = agent.conversations.first(where: { $0.id == thread }),
      ![TaskMode.page, .auto, .library].contains(chat.mode)
    else { return false }
    if let relay = RelayOrchestrator.shared, !relay.isChild(thread), relay.knownThreadIDs.contains(thread) {
      return false
    }
    return true
  }
  /// Hand back is offered on a tab the person took over at a verification check or a sign-in page,
  /// when its chat can resume (`canResume`) and no step is running. A tab already handed back waits
  /// for the chat's next run to take it, so the button goes until then.
  func mayHandBack(_ tab: BrowserTab) -> Bool {
    guard tab.owner == nil, (tab.agentMark?.verification ?? tab.agentMark?.signIn) != nil,
      canResume(tab),
      let thread = tab.agentMark?.threadID,
      handBacks[thread] == nil,
      let agent = intelligenceAgent, agent.hub.run(for: thread) == nil
    else { return false }
    return true
  }
  /// Hand back, once the person has finished the verification check or signed in: the page's old
  /// refs go stale, the tab waits in `handBacks` for the chat, and a short reply goes into the task's
  /// chat through the task reply path (as Try Again does) and starts its next run. That run takes
  /// the tab just before its agent starts (`adoptHandBack`), so the agent's first call already sees it.
  /// `keep` is the person's tick on Keep Serein signed in (`keepableSite`): the site's cookies are
  /// kept for later tasks (TaskStores.keep) before the tab goes back.
  func handBack(_ tab: BrowserTab, keep: Bool = false) async {
    guard mayHandBack(tab), let thread = tab.agentMark?.threadID, let agent = intelligenceAgent,
      let done = tab.agentMark?.verification.map({ "I finished the verification check on \($0)." })
        ?? tab.agentMark?.signIn.map({ "I signed in on \($0)." })
    else { return }
    // Held replies would go first and take the tab with a prompt that says nothing about it.
    guard agent.flow.queue.items(for: thread).isEmpty else {
      notice = "This chat has replies waiting. Send or remove them, then hand the tab back."
      return
    }
    if keep, let site = keepableSite(tab), let host = tab.agentMark?.signIn {
      // The sign-in page's host, and the host the sign-in landed on (keepableSite holds it to the site).
      var hosts: [String] = [host]
      if let here = URL(string: tab.address)?.host { hosts.append(here) }
      let kept: Int? = await taskStores.keep(site: site, hosts: hosts, from: tab.web.configuration.websiteDataStore)
      switch kept {
      case nil: notice = "Serein couldn't keep this sign-in. The tab goes back signed in for this task only."
      case 0?: notice = "Serein found no sign-in for \(site) to keep."
      default: notice = "Serein stays signed in to \(site) for later tasks. Sign out in Settings › Privacy."
      }
    }
    // A ref read before the hand-off points at the page as it was: the run must read it again.
    _ = try? await tab.script("globalThis.__serein.invalidate()")
    for frame in tab.frames.values where !frame.isMainFrame {
      _ = try? await tab.script("globalThis.__serein.invalidate()", frame: frame)
    }
    guard mayHandBack(tab) else { return }
    handBacks[thread] = tab
    // Isolation is decided when the run starts (WebTaskGrant), so the run may still refuse the tab.
    let reply = done + " If tab \(tab.id) is among your tabs, read it "
      + "again before you act; if not, open the page again. Then carry on with the task."
    if let refused = await agent.flow.replyToTask(thread, text: reply, interrupt: false) {
      handBacks[thread] = nil
      notice = refused
      return
    }
    // Nothing started (the reply was only held): the button comes back. A run that already
    // ended has had its entry cleared by `endTask`.
    if agent.hub.run(for: thread) == nil { handBacks[thread] = nil }
  }
  /// The chat's handed-back tab joins `run`'s task: `takeOver` in reverse, through the same
  /// registration as the task's own tabs (`open`). Called once the start is validated and before
  /// the agent is spawned (AgentHub.continuePreparedStart), so no agent call comes before it. An
  /// isolated task never takes a tab that may hold sign-ins; the run then opens the page itself.
  func adoptHandBack(_ run: AgentRun) {
    guard let tab = handBacks.removeValue(forKey: run.spec.threadID) else { return }
    guard var task = tasks[run.taskID], tab.owner == nil, !tab.hiddenFromAgents,
      tabs.contains(where: { $0 === tab }), tab.agentMark?.threadID == run.spec.threadID,
      tab.privateMode || !task.isolated
    else {
      notice = "Serein carries on in a tab of its own. This tab stays yours."
      return
    }
    // The person still looking at the page sees it on the agent board; otherwise the view stays.
    let inView = selected == tab.id && section == ShellSection.browser
    tabs.removeAll { $0 === tab }
    if selected == tab.id { selected = tabs.last?.id }
    tab.objectWillChange.send()
    // "You filled your saved sign-in on …" (Sign in as …) belongs to the steps of the run that carries on.
    let signedIn = tab.agentMark?.steps.last.flatMap { $0.tool == "sign_in" ? $0 : nil }
    tab.owner = run.taskID
    tab.takenFrom = nil
    tab.agentMark = nil
    // `attach` gave the tab the person's history, kept passages, popups and split preview; an
    // agent tab has none. Password and site-permission helpers refuse an owned tab on their own.
    tab.onVisit = nil
    tab.onPopup = nil
    tab.onPreviewLink = nil
    tab.onBlockedPopup = nil
    tab.onClose = nil
    tab.allowsNavigation = task.allows
    let taskID = run.taskID
    tab.assistantBlocks = { [weak self] u in self?.assistantScope(forTask: taskID)?.scope.blocks(u.absoluteString) == true }
    // Whatever was approved on this page before is for another page now: the advanced page version
    // and the fresh task are what keep an old yes from covering it.
    tab.noteNavigation(because: "hand back")
    task.tabs.append(tab)
    task.pendingApprovals = []
    tasks[run.taskID] = task
    agentTabs.opened(tab, task: run.taskID, isolated: task.isolated)
    if let signedIn { agentTabs.note(signedIn, task: run.taskID) }
    if inView { viewAgentTab(tab) }
    persist()
  }
  /// Sign in as … on a task tab stopped at a sign-in page: the vault fills the saved login after
  /// device authentication (PasswordVault.signIn) and sends nothing. The tab is already the
  /// person's and in view (takeOver), so they see the filled page, press its own button, and the
  /// banner's Hand back gives the task the tab again.
  func signIn(_ item: Credential, in tab: BrowserTab) async {
    do { try await PasswordVault.shared.signIn(item, taskTab: tab, browser: self) } catch {
      notice = Self.signInFailure(error)
      return
    }
    filledSignIn(on: item.origin, in: tab, from: nil)
  }
  /// The helper's own words ("This page asks for a new password…"), not WebKit's generic one.
  static func signInFailure(_ error: Error) -> String {
    (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
  }
  /// After Sign in as … filled a login on a tab the person now holds: a saved one, or one from the
  /// password manager `manager` names (PasswordManagers.signIn). The task's steps say that the
  /// person filled a sign-in on the host and, for a manager's login, the manager's name; no
  /// username or password goes there.
  func filledSignIn(on origin: String, in tab: BrowserTab, from manager: String?) {
    let host = CredentialOrigin.displayHost(origin)
    tab.objectWillChange.send()
    tab.agentMark?.steps.append(
      AgentStep(tool: "sign_in", label: manager.map { "You filled your sign-in from \($0) on \(host)" }
        ?? "You filled your saved sign-in on \(host)"))
    let filled = manager == nil ? "Your saved sign-in is filled in." : "Your sign-in is filled in."
    notice =
      canResume(tab)
      ? filled + " Press the page's sign-in button, then choose Hand back."
      : filled + " Press the page's sign-in button. This tab is yours now."
  }
}

/// Counts a page's open data requests (fetch and XMLHttpRequest) through WebKit's resource-load
/// callbacks (SPI, present since macOS 10.15), so `settle` knows when the fetch a click started has
/// come back. Images, scripts, frames, beacons and the ads they bring do not count: on a news site
/// they never stop. Nothing runs in the page, so the page cannot see it. A request open longer than
/// 3 s (long polling, a stream) stops counting. Without the SPI, `idle` is always true.
final class NetworkWatch: NSObject {
  private static let setter = Selector(("_setResourceLoadDelegate:"))
  /// `_WKResourceLoadInfoResourceType` as WebKit reports it (seen on macOS 27): fetch 5,
  /// XMLHttpRequest 12. A load whose type cannot be read counts.
  private static let dataTypes: Set<Int> = [5, 12]
  private var open: [UInt64: Date] = [:]
  private var lastChange = Date.distantPast
  func attach(_ web: WKWebView) {
    open = [:]
    if web.responds(to: Self.setter) { _ = web.perform(Self.setter, with: self) }
  }
  /// No request opened or ended in the last 100 ms, and none younger than 3 s is still open.
  var idle: Bool {
    let now = Date()
    return now.timeIntervalSince(lastChange) >= 0.1 && !open.values.contains { now.timeIntervalSince($0) < 3 }
  }
  /// The load's id when it is a data request (or of a type that cannot be read), else nil.
  private func dataID(_ load: NSObject?) -> UInt64? {
    guard let load, load.responds(to: Selector(("resourceLoadID"))) else { return nil }
    if load.responds(to: Selector(("resourceType"))),
      let type = (load.value(forKey: "resourceType") as? NSNumber)?.intValue, !Self.dataTypes.contains(type)
    { return nil }
    return (load.value(forKey: "resourceLoadID") as? NSNumber)?.uint64Value
  }
  @objc(webView:resourceLoad:didSendRequest:)
  func sent(_ web: WKWebView?, _ load: NSObject?, _ request: NSObject?) {
    guard let id = dataID(load) else { return }
    open[id] = Date()
    lastChange = Date()
  }
  @objc(webView:resourceLoad:didCompleteWithError:response:)
  func ended(_ web: WKWebView?, _ load: NSObject?, _ error: NSObject?, _ response: NSObject?) {
    guard let id = dataID(load), open.removeValue(forKey: id) != nil else { return }
    lastChange = Date()
  }
}

extension BrowserTab {
  /// The wait after an action, shared by agent actions and fast steps: the page goes quiet, and a
  /// navigation that a click started a moment after that loads too.
  func settleAfterAction() async {
    await settle(limit: 3)
    if web.isLoading { await settle(limit: 5) }
  }
  /// Waits for loading to end, the page's requests to come back and the page to stop changing for
  /// 150 ms, up to `limit`. Before, a fixed 500 ms of quiet cost every action at least half a second
  /// and still returned early when a fetch took longer.
  func settle(limit: TimeInterval = 8, quiet: TimeInterval = 0.15) async {
    guard !sleeping else { return }
    let start = Date()
    // The published `loading` flag trails WebKit; read the web view itself. The wait is for the new
    // document's HTML, not for every image and ad: a news site's load event came 8 s late. PageKit
    // registers each document as soon as its HTML is parsed (it runs at document end), so nothing
    // here asks the page itself, which a busy page answered seconds late.
    // A navigation that has not started loading within a second never will (it stayed in the
    // document); stop waiting for its commit then.
    while (web.isLoading || (!documentCommitted && Date().timeIntervalSince(start) < 1))
      && Date().timeIntervalSince(start) < limit
    {
      if documentCommitted, frames.values.contains(where: \.isMainFrame) { break }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    repeat {
      let left = max(0.2, limit - Date().timeIntervalSince(start))
      // The page answers when its own scripts let it; past the limit, stop waiting for the answer.
      _ = await withTimeout(left + 0.1) {
        _ = try? await self.web.callAsyncJavaScript(
          "return globalThis.__serein ? await globalThis.__serein.settle(q, ms) : null;",
          arguments: ["q": Int(quiet * 1000), "ms": Int(left * 1000)], in: nil, contentWorld: Self.world)
      }
      if network.idle { return }
      try? await Task.sleep(nanoseconds: 50_000_000)
    } while Date().timeIntervalSince(start) < limit
  }
  /// True when any visible field in the page or a frame is the user's to fill, or a CAPTCHA
  /// is showing. Fails closed: an unreadable document, a frame that does not answer, or more
  /// frames on the page than Serein could check all count as sensitive.
  func hasUserSteps() async -> Bool {
    let probe = "globalThis.__serein && globalThis.__serein.probe ? globalThis.__serein.probe() : null"
    guard let main = (try? await script(probe)) as? [String: Any],
      let mainSteps = main["steps"] as? Bool, let mainFrames = main["frames"] as? Int
    else { return true }
    if mainSteps { return true }
    var seen = Set<String>()
    var frameCount = mainFrames
    for (key, frame) in frames where !frame.isMainFrame {
      guard let result = (try? await script(probe, frame: frame)) as? [String: Any],
        let steps = result["steps"] as? Bool, let id = result["id"] as? String,
        let count = result["frames"] as? Int
      else {
        // A stale or unreadable frame: forget it and refuse this time.
        frames[key] = nil
        return true
      }
      if steps { return true }
      // One frame can be registered under an old document id too; count each document once.
      if seen.insert(id).inserted { frameCount += count }
    }
    return frameCount > seen.count
  }
  /// The host of a sign-in page: the main document asks for a password or a verification code
  /// (PageKit's user steps) and for no card details. `codeOnly` when it asks for a code but no
  /// password. Nil when the page cannot be read.
  func signInHost() async -> (host: String, codeOnly: Bool)? {
    let js = "globalThis.__serein && globalThis.__serein.userSteps ? globalThis.__serein.userSteps() : null"
    guard let kinds = (try? await script(js)) as? [String], !kinds.contains("card"),
      kinds.contains("password") || kinds.contains("code"), let host = web.url?.host
    else { return nil }
    return (host, !kinds.contains("password"))
  }
  /// For a picture: `blank` makes what the user typed in their own fields (and text that shows
  /// it or a credential) transparent in the page and every frame; `confirmBlank` checks that it
  /// still is. True only when every document confirms it, as hasUserSteps counts them: an
  /// unreadable document, a frame that does not answer, an unchecked frame, a field the page
  /// removed, or a canvas or closed root beside the user's fields all give false.
  func blankSecrets(_ call: String) async -> Bool {
    let js = "globalThis.__serein && globalThis.__serein.\(call) ? globalThis.__serein.\(call)() : null"
    guard let main = (try? await script(js)) as? [String: Any], main["ok"] as? Bool == true,
      let mainFrames = main["frames"] as? Int
    else { return false }
    var seen = Set<String>()
    var frameCount = mainFrames
    for (key, frame) in frames where !frame.isMainFrame {
      guard let result = (try? await script(js, frame: frame)) as? [String: Any], result["ok"] as? Bool == true,
        let id = result["id"] as? String, let count = result["frames"] as? Int
      else {
        frames[key] = nil
        return false
      }
      if seen.insert(id).inserted { frameCount += count }
    }
    return frameCount <= seen.count
  }
  /// Shows again what blankSecrets hid, in the page and every frame.
  func unblankSecrets() async {
    let js = "globalThis.__serein && globalThis.__serein.unblank ? globalThis.__serein.unblank() : null"
    _ = try? await script(js)
    for (_, frame) in frames where !frame.isMainFrame { _ = try? await script(js, frame: frame) }
  }
}

// MARK: - Sidebar rows

/// Agent tabs for one run's thread, or (thread nil) for runs without a visible thread.
struct AgentTabRows: View {
  @ObservedObject var board: AgentTabBoard
  @ObservedObject var browser: BrowserModel
  @Environment(\.palette) var p
  var thread: String?
  var known: Set<String> = []
  var horizontal = false
  var body: some View {
    let rows = board.entries(thread: thread, known: known)
    if thread == nil && !rows.isEmpty && !horizontal {
      Text("Serein’s pages").font(UIStyle.micro).foregroundStyle(p.secondary)
        .padding(.leading, 10).padding(.top, 8).accessibilityAddTraits(.isHeader)
    }
    ForEach(rows) { entry in
      AgentTabRow(tab: entry.tab, board: board, browser: browser)
        .padding(.leading, horizontal ? 0 : 14)
    }
  }
}

/// A page Serein is using, in the tab band (with tabs on top) and under a task tab: the petal,
/// the page's title and “Serein is using this page” or “Serein used this page”, as the sidebar's
/// child rows say it. Whether it is isolated and what it may sign in with stays in Show Details.
private struct AgentTabRow: View {
  @ObservedObject var tab: BrowserTab
  @ObservedObject var board: AgentTabBoard
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var recordings = TaskRecordings.shared
  @Environment(\.palette) var p
  @State private var hovered = false
  var working: Bool { board.isWorking(tab.id) }
  /// Record this task is on and its recording runs.
  var recording: Bool { board.entry(tab.id).map { recordings.isRecording(task: $0.taskID) } ?? false }
  var selected: Bool { browser.section == ShellSection.agent && board.focused == tab.id }
  private var words: String { working ? "Serein is using this page" : "Serein used this page" }
  var body: some View {
    Button { browser.viewAgentTab(tab) } label: {
      HStack(spacing: 8) {
        SereinMark(size: 13).frame(width: 16).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(tab.title.isEmpty ? (URL(string: tab.address)?.host ?? "Serein’s page") : tab.title)
            .font(UIStyle.meta)
            .foregroundStyle(selected || hovered ? p.ink : p.secondary)
            .lineLimit(1).truncationMode(.tail)
          Text(words).font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(1)
        }.layoutPriority(1)
        if recording {
          Circle().fill(p.danger).frame(width: 6, height: 6).help("Recording this task").accessibilityHidden(true)
        }
        // Right after the words, never at the cell's far edge, where it would read as the next
        // tab's spinner.
        if working {
          ActivityRing(active: true).accessibilityHidden(true)
        } else if board.unseen.contains(tab.id) {
          Circle().fill(p.accent).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        Spacer(minLength: 0)
      }.frame(minHeight: 34).padding(.horizontal, 8).contentShape(Rectangle())
    }.buttonStyle(.pressable)
      .background(selected ? p.selected : hovered ? p.hover : Color.clear,
        in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .onHover { hovered = $0 }
      .help([words, URL(string: tab.address)?.host ?? tab.address].filter { !$0.isEmpty }.joined(separator: " · "))
      .accessibilityLabel("Serein’s page: \(tab.title)")
      .accessibilityValue(words + (recording ? ", recording" : "") + (board.unseen.contains(tab.id) ? ", new result" : ""))
      .contextMenu {
        Button(working ? "Let Me Use It" : "Keep This Page") { browser.takeOver(tab) }
        Button("Close Page") { board.dismiss(tab.id) }
          .disabled(board.info(tab.id)?.ended != true)
      }
  }
}

// MARK: - The agent tab surface

struct AgentTabPane: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var board: AgentTabBoard
  @ObservedObject var hub: AgentHub
  @Environment(\.palette) var p
  init(browser: BrowserModel, agent: AgentModel) {
    self.browser = browser
    board = browser.agentTabs
    hub = agent.hub
  }
  var body: some View {
    if let id = board.focused, let entry = board.entry(id) {
      VStack(spacing: 0) {
        AgentWorkBanner(browser: browser, tab: entry.tab)
        ZStack(alignment: .topTrailing) {
          BrowserPane(tab: entry.tab).allowsHitTesting(!board.isWorking(id))
          if board.isWorking(id) {
            AgentTabLock(
              tab: entry.tab, board: board, agent: board.info(id)?.agent ?? "The agent",
              takeOver: { browser.takeOver(entry.tab) })
          }
        }
      }.onAppear { board.unseen.remove(id) }
    } else {
      VStack(spacing: 10) {
        Text("This agent tab is closed.").foregroundStyle(p.secondary)
        Button("Back to Serein") { browser.section = ShellSection.serein }
          .buttonStyle(QuietButton())
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// Covers a page while an agent works in it: the page stays visible, but clicks and keys go
/// nowhere until the user takes the tab over.
private struct AgentTabLock: View {
  @ObservedObject var tab: BrowserTab
  @ObservedObject var board: AgentTabBoard
  var agent: String
  var takeOver: () -> Void
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var nudged = false
  var body: some View {
    ZStack(alignment: .bottom) {
      Color.clear.contentShape(Rectangle())
        .onTapGesture { nudge() }
        .accessibilityHidden(true)
      HStack(spacing: 10) {
        Text("Serein is using this page.")
          .font(UIStyle.meta).foregroundStyle(p.ink)
        Button("Let me use it", action: takeOver).buttonStyle(PrimaryButton())
          .help("Serein stops working here, and the page becomes yours as it is.")
      }.padding(.horizontal, 14).padding(.vertical, 8).darkGlass(UIStyle.panelRadius)
        .overlay(
          RoundedRectangle(cornerRadius: UIStyle.panelRadius)
            .stroke(nudged ? p.accent : Color.clear, lineWidth: 1.5)
        )
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Serein is using this page")
    }
    .onAppear {
      // Keys typed before the agent started must not keep reaching the page.
      if let window = tab.web.window, (window.firstResponder as? NSView)?.isDescendant(of: tab.web) == true {
        window.makeFirstResponder(nil)
      }
    }
    .onChange(of: board.blockedInputAt) { _, _ in nudge() }
  }
  private func nudge() {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { nudged = true }
    Task {
      try? await Task.sleep(nanoseconds: 1_600_000_000)
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { nudged = false }
    }
  }
}

struct AgentStepList: View {
  var steps: [AgentStep]
  /// A replay's list: the tab each step worked in, and a click that moves the video to the step.
  var tab: ((AgentStep) -> String?)? = nil
  var seek: ((AgentStep) -> Void)? = nil
  @Environment(\.palette) var p
  static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()
  var body: some View {
    LazyVStack(alignment: .leading, spacing: 4) {
      if steps.isEmpty { Text("No steps yet.").font(UIStyle.micro).foregroundStyle(p.faint) }
      ForEach(steps) { step in
        if let seek {
          Button { seek(step) } label: { row(step).contentShape(Rectangle()) }.buttonStyle(.pressable)
            .help("Play from this step").accessibilityHint("Plays the recording from this step")
        } else {
          // Outside `row`, whose children combine into one element. It opens Settings; it does
          // not unblock the step in place.
          VStack(alignment: .leading, spacing: 2) {
            row(step)
            if let site = step.ruleSite {
              Button("Change rule…") { RelayController.shared?.openSettings(SettingsCategory.request("Privacy", path: [PrivacyKey.sites])) }
                .buttonStyle(QuietButton()).font(UIStyle.micro)
                .accessibilityLabel("Change the rule for \(site) in Settings")
            }
          }
        }
      }
    }
  }
  private func row(_ step: AgentStep) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(Self.clock.string(from: step.time)).font(UIStyle.microMono).foregroundStyle(p.faint)
      VStack(alignment: .leading, spacing: 1) {
        Text(step.label).font(UIStyle.micro).foregroundStyle(p.ink)
        if let failed = step.failed {
          Text(failed).font(UIStyle.micro).foregroundStyle(p.secondary).textSelection(.enabled)
        }
      }
      if let label = tab?(step) {
        Spacer(minLength: 4)
        Text(label).font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
      }
    }.accessibilityElement(children: .combine)
  }
}
