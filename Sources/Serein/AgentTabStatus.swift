import AppKit
import SereinCore
import SwiftUI

/// Who worked in a tab before it became the user's. Set by `takeOver`; never grants anything.
struct TabAgentMark {
  var agent: String
  var threadID: String?
  var taskID: String
  var title: String
  var summary: String?
  /// Nil when the user took the tab over mid-run: the row then shows no bar.
  var status: AgentTabStatus?
  var startedAt: Date
  var endedAt: Date
  var steps: [AgentStep]
  /// The site whose verification check the person took this tab over for; the tab offers Hand back.
  var verification: String? = nil
  /// The host of the sign-in page the person took this tab over at; the tab offers Hand back.
  var signIn: String? = nil
  /// That sign-in page asks only for a verification code.
  var signInCodeOnly = false
}

/// Everything a tab row, its status bubble and the "worked in this tab" banner need.
struct TabAgentState {
  var agent: String
  var title: String
  var threadID: String?
  var taskID: String
  var status: AgentTabStatus?
  var summary: String?
  var startedAt: Date
  var endedAt: Date?
  var steps: [AgentStep]
  var isolated: Bool
  /// Still on the agent board (not yet the user's tab).
  var onBoard: Bool
  var ended: Bool
  /// The site whose verification check waits for the person.
  var verification: String? = nil
  /// The host of the sign-in page that waits for the person (Sign in as …, Do it myself).
  var signIn: String? = nil
  /// That page asks only for a verification code: Sign in as offers only logins with one saved.
  var signInCodeOnly = false
  var working: Bool { status == .working }
}

extension BrowserModel {
  /// Agent state for a board tab or a tab the user took over; nil for ordinary tabs.
  func agentState(for tab: BrowserTab) -> TabAgentState? {
    if let entry = agentTabs.entry(tab.id), let info = agentTabs.runs[entry.taskID] {
      let working = agentTabs.isWorking(tab.id)
      let bubble = agentTabs.bubble(tab.id)
      return TabAgentState(
        agent: info.agent, title: info.title, threadID: info.threadID, taskID: entry.taskID,
        status: working ? .working : AgentTabStatus.make(working: false, outcome: bubble?.kind.rawValue),
        summary: working ? info.steps.last?.label : bubble?.text, startedAt: info.startedAt,
        endedAt: info.endedAt, steps: info.steps, isolated: info.isolated, onBoard: true,
        ended: info.ended, verification: info.verification, signIn: info.signIn,
        signInCodeOnly: info.signInCodeOnly)
    }
    guard let mark = tab.agentMark else { return nil }
    return TabAgentState(
      agent: mark.agent, title: mark.title, threadID: mark.threadID, taskID: mark.taskID,
      status: mark.status, summary: mark.summary, startedAt: mark.startedAt, endedAt: mark.endedAt,
      steps: mark.steps, isolated: tab.privateMode, onBoard: false, ended: true,
      verification: mark.verification, signIn: mark.signIn, signInCodeOnly: mark.signInCodeOnly)
  }
}

/// What is left of the retired task panel: the per-tab banner state, its remembered keys and pure
/// types. Opening a task goes through `SereinRouter.open(threadID:)`: a task Serein started shows
/// in the Serein surface, every other chat as a task tab.
@MainActor final class TaskDock: ObservableObject {
  static let shared = TaskDock()
  @Published private(set) var open = false
  @Published private(set) var taskID: String?
  @Published private(set) var threadID: String?
  /// The snapshot used when the run is no longer in the hub (for example after a restart).
  @Published private(set) var state: TabAgentState?
  /// Tabs whose "worked in this tab" banner the user dismissed; their status bar stays.
  @Published var hiddenBanners: Set<String> = []
  /// The tab row whose status bubble is showing. Escape closes it while it is open.
  @Published var bubbleTabID: String? {
    didSet { bubbleTabID == nil ? stopEscape() : startEscape() }
  }
  /// Tab rows' frames in the shell's coordinate space, for placing the bubble beside its row.
  var rowFrames: [String: CGRect] = [:]
  /// The open bubble's frame in the same space.
  var bubbleFrame: CGRect = .zero
  private var escapeMonitor: Any?
  /// Escape closes the bubble; a click outside the bubble and its row closes it and still
  /// reaches whatever was clicked.
  private func startEscape() {
    guard escapeMonitor == nil else { return }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      let swallow = MainActor.assumeIsolated { () -> Bool in
        guard let self, let id = self.bubbleTabID else { return false }
        if event.type == .keyDown {
          guard event.keyCode == 53 else { return false }
          self.bubbleTabID = nil
          return true
        }
        guard let content = event.window?.contentView else { return false }
        let point = CGPoint(x: event.locationInWindow.x,
          y: content.bounds.height - event.locationInWindow.y)
        let row = self.rowFrames[id] ?? .zero
        if !self.bubbleFrame.contains(point) && !row.contains(point) { self.bubbleTabID = nil }
        return false
      }
      return swallow ? nil : event
    }
  }
  private func stopEscape() {
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    escapeMonitor = nil
  }

  /// Show task (the banner): the task's chat where it lives (`SereinRouter`). A run with no saved
  /// chat has nothing more to show than its page, already in view.
  func show(_ state: TabAgentState, browser: BrowserModel, agent: AgentModel) {
    bubbleTabID = nil
    if let thread = state.threadID { SereinRouter.open(threadID: thread) }
  }
  func toggle(_ state: TabAgentState, browser: BrowserModel, agent: AgentModel) { show(state, browser: browser, agent: agent) }
  func close() { open = false }

  // MARK: Task tabs

  /// Open threads in the panel's tab strip: thread ids, or a task id for a run with no thread.
  @Published private(set) var tabs: [String] = []
  /// The panel's width, remembered across launches.
  @Published var width: CGFloat = UIStyle.taskPanelWidth
  /// Runs without a saved thread, kept for their tabs while Serein runs.
  private var snapshots: [String: TabAgentState] = [:]
  /// The composer's toolbar (eye, tabs, model and effort pills, paperclip, Queue) has no part
  /// that can shrink; below this it pushes the whole panel past its right edge.
  static var minWidth: CGFloat { UIStyle.wide(352) }
  static let maxWidth: CGFloat = 520
  private static let tabsKey = "serein.taskPanel.tabs"
  private static let selectedKey = "serein.taskPanel.selected"
  private static let widthKey = "serein.taskPanel.width"
  /// Synthetic previews never write the user's defaults.
  private let persists = !CommandLine.arguments.contains("--ui-preview") && !CommandLine.arguments.contains("--verify")
  var selected: String? { threadID ?? taskID }

  init() {
    guard persists else { return }
    let defaults = UserDefaults.standard
    tabs = defaults.stringArray(forKey: Self.tabsKey) ?? []
    threadID = defaults.string(forKey: Self.selectedKey).flatMap { tabs.contains($0) ? $0 : nil }
    let stored = defaults.double(forKey: Self.widthKey)
    if stored > 0 { width = min(Self.maxWidth, max(Self.minWidth, stored)) }
  }
  func persist() {
    guard persists else { return }
    let defaults = UserDefaults.standard
    // Only thread ids survive a restart; the transcript itself stays in conversation storage.
    defaults.set(tabs.filter { snapshots[$0] == nil }, forKey: Self.tabsKey)
    defaults.set(threadID, forKey: Self.selectedKey)
    defaults.set(Double(width), forKey: Self.widthKey)
  }
  /// Opens a chat by the rule per kind (SereinRouter): every old call site gets it.
  func open(thread id: String, browser: BrowserModel, agent: AgentModel) {
    bubbleTabID = nil
    SereinRouter.open(threadID: id)
  }
  func select(_ key: String, browser: BrowserModel, agent: AgentModel) {
    if let snapshot = snapshots[key] {
      show(snapshot, browser: browser, agent: agent)
    } else {
      open(thread: key, browser: browser, agent: agent)
    }
  }
  /// Closes a tab; the thread itself stays in History and All tasks.
  func closeTab(_ key: String, browser: BrowserModel, agent: AgentModel) {
    let result = TaskTabStrip.closing(tabs, selected: selected, key)
    tabs = result.ids
    snapshots[key] = nil
    if let next = result.selected {
      if next != selected { select(next, browser: browser, agent: agent) }
    } else {
      threadID = nil
      taskID = nil
      state = nil
      close()
    }
    persist()
  }
  /// Serein's own chat (not a task it started, which opens here until its task view lands).
  private static func sereinChat(_ id: String, agent: AgentModel) -> Bool {
    !agent.isSereinTask(id) && agent.isSereinChatID(id)
  }
  /// Restored tabs that turn out to be Serein's own chats (known once Serein starts) leave the
  /// strip; a thread that is not loaded yet keeps its tab.
  func dropSereinChats(agent: AgentModel) {
    let kept = tabs.filter { snapshots[$0] != nil || !Self.sereinChat($0, agent: agent) }
    guard kept != tabs else { return }
    tabs = kept
    if let threadID, !kept.contains(threadID) {
      self.threadID = nil
      taskID = nil
      state = nil
      open = false
    }
    persist()
  }
  private func switchThread(_ thread: String, browser: BrowserModel, agent: AgentModel) {
    guard thread != agent.conversationID,
      let conversation = agent.conversations.first(where: { $0.id == thread })
    else { return }
    let section = browser.section
    SereinRouter.direct { agent.openConversation(conversation) }
    browser.section = section
  }
}

/// Status colors: working accent, done green, needs you amber, failed red, stopped quiet.
extension AgentTabStatus {
  func color(_ p: Palette) -> Color {
    switch self {
    case .working: return p.accent
    case .done: return p.success
    case .needsYou: return p.warning
    case .failed: return p.danger
    case .stopped: return p.faint
    }
  }
  var spoken: String {
    switch self {
    case .working: return "working"
    case .done: return "done"
    case .needsYou: return "needs you"
    case .failed: return "failed"
    case .stopped: return "stopped"
    }
  }
}

/// The 3-point bar at a tab row's leading edge. Working shimmers in accent unless motion is reduced.
struct AgentStatusBar: View {
  var status: AgentTabStatus
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) var systemReduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var body: some View {
    let still = status != .working || systemReduceMotion || previewReducedEffects
    Capsule().fill(status.color(p).opacity(status == .working ? 0.55 : 0.9))
      .overlay {
        // Run by Core Animation, so SwiftUI does not redraw the bar for each frame.
        if !still { ShimmerSweep(color: p.shimmer) }
      }
      .frame(width: 3)
  }
}

/// The bubble beside a tab row: "<Agent> · <task>", the status word, one line from the agent,
/// and Open task / Take over.
struct AgentStatusBubble: View {
  var state: TabAgentState
  var host: String
  var openTask: () -> Void
  var takeOver: () -> Void
  var close: () -> Void
  /// Where the arrow meets the bubble, from its top: the middle of the tab row.
  var arrowY: CGFloat = 26
  /// For Sign in as … on a tab stopped at a sign-in page.
  var browser: BrowserModel? = nil
  var tab: BrowserTab? = nil
  @Environment(\.palette) var p
  @State private var showSteps = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(state.agent).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
        Text(" · " + (state.title.isEmpty ? host : state.title)).font(UIStyle.body)
          .foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 8)
        Button(action: close) { InterfaceIcon(systemName: "xmark", size: 10).frame(width: 12, height: 12) }
          .buttonStyle(QuietButton()).accessibilityLabel("Close")
      }
      if let status = state.status {
        Text(status.word).font(UIStyle.font(11, weight: .medium)).tracking(0.8)
          .foregroundStyle(status.color(p))
      } else {
        Text("YOURS NOW").font(UIStyle.font(11, weight: .medium)).tracking(0.8)
          .foregroundStyle(p.secondary)
      }
      // The agent's own words, possibly steered by the page, attributed to the agent above.
      if let summary = state.summary, !summary.isEmpty {
        Text(summary).font(UIStyle.reading).foregroundStyle(p.ink)
          .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if state.status == .needsYou && state.onBoard {
        Text(state.verification.map { "Take over, finish the verification check on \($0), then hand the tab back." }
          ?? state.signIn.map { _ in SignInChoice.note(isolated: state.isolated) }
          ?? "Choose Keep tab first, then sign in, pay or download here yourself.").role(.meta)
          .fixedSize(horizontal: false, vertical: true)
      }
      if state.status == .needsYou, state.onBoard, state.signIn != nil, let browser, let tab {
        SignInChoice(browser: browser, tab: tab, takeOver: takeOver, chose: close)
      }
      if !state.steps.isEmpty {
        DisclosureGroup("What the agent did", isExpanded: $showSteps) {
          ScrollView { AgentStepList(steps: state.steps) }.frame(maxHeight: 180)
        }.font(UIStyle.micro).foregroundStyle(p.secondary)
      }
      HStack(spacing: 8) {
        Button("Open task", action: openTask).buttonStyle(QuietButton())
          .help("Show this task beside the page")
        if state.working || (state.onBoard && state.verification != nil) {
          Button("Take over", action: takeOver).buttonStyle(PrimaryButton())
            .help("Stop the agent. The tab becomes yours with the page as it is.")
        }
        Spacer()
        Text(state.isolated ? "Isolated · no sign-ins" : "You can sign in").font(UIStyle.micro)
          .foregroundStyle(state.isolated ? p.faint : p.accent)
      }.padding(.top, 2)
    }.padding(.horizontal, 16).padding(.vertical, 14).padding(.leading, 8)
      .frame(width: UIStyle.wide(340), alignment: .leading)
      .background {
        let shape = BubbleShape(arrowY: min(max(arrowY, 20), 60))
        shape.fill(p.overlay).shadow(color: p.shadow(0.45), radius: 14, y: 6)
          .overlay(shape.stroke(p.borderStrong, lineWidth: UIStyle.hairline))
      }
      .accessibilityAddTraits(.isModal)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(state.agent), \(state.title). \(state.status?.spoken ?? "yours now")")
  }
}

/// Hand back on a tab the person took over at a verification check. Whether it shows depends on
/// the chat's run (AgentHub), on a hand back already waiting (BrowserModel.handBacks) and on the
/// tab's mark, so this view observes all three; `agentMark` is not published, and whoever changes
/// it sends the tab's objectWillChange. After a sign-in it offers Keep Serein signed in, unticked
/// (`BrowserModel.keepableSite`: never for a private, isolated or plain HTTP tab).
private struct HandBackButton: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var hub: AgentHub
  @ObservedObject var tab: BrowserTab
  @State private var keep = false
  var body: some View {
    if browser.mayHandBack(tab) {
      HStack(spacing: 10) {
        if let site = browser.keepableSite(tab) {
          Toggle("Keep Serein signed in to \(site)", isOn: $keep).toggleStyle(.checkbox)
            .font(UIStyle.meta).fixedSize()
            .help("Later tasks on \(site) may use this sign-in, each after you say yes. It ends after 30 days unused, or when you sign out in Settings › Privacy.")
        }
        Button("Hand back") {
          let kept = keep
          Task { await browser.handBack(tab, keep: kept) }
        }.buttonStyle(PrimaryButton()).fixedSize()
          .help("The task gets this tab back, reads the page again and carries on.")
      }
    }
  }
}

/// Sign in as … and Do it myself, on a task tab stopped at a sign-in page. Sign in as shows only for
/// logins saved for exactly this HTTPS origin (PasswordVault.taskAccounts), as a menu when several
/// match or when Settings › Passwords also offers 1Password or Bitwarden (PasswordManagers.offered);
/// a look-alike host, plain HTTP or a private window shows only Do it myself. No tool reaches
/// either button: the fill needs this tap and device authentication (or the manager's own unlock),
/// and nothing is sent until the person presses the page's own button.
private struct SignInChoice: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var tab: BrowserTab
  @ObservedObject var vault = PasswordVault.shared
  /// Redraws when the password manager switch changes; the managers themselves are read below.
  @GateStorage(PasswordManagers.enabledKey) private var managersOn = false
  var takeOver: () -> Void
  /// Runs as the person picks a login, before device authentication (the bubble closes).
  var chose: () -> Void = {}
  @Environment(\.palette) var p
  /// One sign-in at a time: a second tap would ask for device authentication again.
  @State private var busy = false
  /// What a sign-in here means for this task only (WebTaskGrant's wording).
  static func note(isolated: Bool) -> String {
    "Sign in here, then the task carries on. "
      + (isolated
        ? "The sign-in stays in this task's own tabs and is thrown away with them; your own browser stays signed out."
        : "The sign-in stays in this task's tabs; your own tabs are not signed in by it.")
  }
  static func name(_ item: Credential) -> String {
    item.username.isEmpty ? CredentialOrigin.displayHost(item.origin) : item.username
  }
  var body: some View {
    let accounts = vault.taskAccounts(for: tab, browser: browser)
    let managers = managersOn ? PasswordManagers.shared.offered(for: tab, browser: browser) : []
    HStack(spacing: 8) {
      if accounts.count == 1, managers.isEmpty, let item = accounts.first {
        Button { start(item) } label: {
          Text("Sign in as " + Self.name(item)).lineLimit(1).truncationMode(.middle)
        }.buttonStyle(PrimaryButton()).disabled(busy)
          .help("Touch ID or your Mac's password fills your saved sign-in here; you press the page's button. The agent never sees it.")
      } else if !accounts.isEmpty || !managers.isEmpty {
        // A menu draws its own label (composerMenu): the primary plate is drawn here, as PrimaryButton's.
        Menu {
          ForEach(accounts) { item in Button(Self.name(item)) { start(item) } }
          if !accounts.isEmpty, !managers.isEmpty { Divider() }
          ForEach(managers, id: \.self) { manager in Button(manager.name + "…") { open(manager) } }
        } label: {
          Text("Sign in as…").font(UIStyle.font(12, weight: .medium)).foregroundStyle(p.onSolid)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(p.solid, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: UIStyle.controlRadius).strokeBorder(p.edge, lineWidth: UIStyle.hairline))
            .opacity(busy ? 0.4 : 1)
        }.composerMenu().fixedSize().disabled(busy)
          .help("Choose a saved sign-in. Touch ID or your Mac's password fills it here; the agent never sees it.")
          .accessibilityLabel("Sign in as. Choose a saved sign-in")
      }
      Button("Do it myself", action: takeOver).buttonStyle(QuietButton()).fixedSize()
        .help("The page becomes yours as it is. Sign in there, then hand the tab back.")
    }
  }
  private func start(_ item: Credential) {
    guard !busy else { return }
    busy = true
    chose()
    Task {
      await browser.signIn(item, in: tab)
      busy = false
    }
  }
  /// 1Password… or Bitwarden…: the person's pick opens the manager's sheet over the window
  /// (ManagerSignInSheet); nothing runs before it.
  private func open(_ manager: PasswordManager) {
    guard !busy else { return }
    chose()
    PasswordManagers.shared.begin(manager, tab: tab, browser: browser)
  }
}

/// The slim line on a page Serein worked in: “Serein used this page · 5:51 PM” with Keep this page
/// (on Serein's own pages), Show task and ×. While Serein works there: “Serein is using this page”
/// with Let me use it.
struct AgentWorkBanner: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var tab: BrowserTab
  @ObservedObject private var board: AgentTabBoard
  @ObservedObject private var dock = TaskDock.shared
  @Environment(\.palette) var p
  init(browser: BrowserModel, tab: BrowserTab) {
    self.browser = browser
    self.tab = tab
    board = browser.agentTabs
  }
  static let clock: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
  }()
  var body: some View {
    if let state = browser.agentState(for: tab),
      state.working || state.verification != nil || state.signIn != nil || !dock.hiddenBanners.contains(tab.id)
    {
      HStack(spacing: 10) {
        if state.working { ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true) }
        if let host = state.verification, !state.working {
          // A verification check waits for the person: Take over, finish it, then Hand back.
          Text(state.onBoard ? "Needs you: verification check on \(host)"
            : "Finish the verification check on \(host), then hand the tab back.")
            .font(UIStyle.meta).foregroundColor(p.ink).lineLimit(1).truncationMode(.tail)
        } else if let host = state.signIn, !state.working {
          // A sign-in page waits for the person: Sign in as … or Do it myself, then Hand back.
          Text(state.onBoard ? "Needs you: sign in on \(host)" : "Sign in on \(host), then hand the tab back.")
            .font(UIStyle.meta).foregroundColor(p.ink).lineLimit(1).truncationMode(.tail)
        } else {
          (Text("Serein").font(UIStyle.meta).foregroundColor(p.ink)
            + Text(state.working ? " is using this page"
              : " used this page · " + Self.clock.string(from: state.endedAt ?? state.startedAt))
              .font(UIStyle.meta).foregroundColor(p.secondary))
            .lineLimit(1).truncationMode(.tail)
        }
        Spacer(minLength: 8)
        if state.working {
          Button("Let me use it") { browser.takeOver(tab) }.buttonStyle(PrimaryButton()).fixedSize()
            .help("Serein stops working here, and the page becomes yours as it is.")
        } else if state.verification != nil || state.signIn != nil {
          if state.onBoard && state.verification == nil {
            SignInChoice(browser: browser, tab: tab, takeOver: { browser.takeOver(tab) })
          } else if state.onBoard {
            Button("Take over") { browser.takeOver(tab) }.buttonStyle(PrimaryButton()).fixedSize()
              .help("The page becomes yours as it is. Finish the check there, then hand the tab back.")
          } else if let agent = browser.intelligenceAgent {
            HandBackButton(browser: browser, hub: agent.hub, tab: tab)
          }
        } else {
          if state.onBoard {
            Button("Keep this page") { browser.takeOver(tab) }.buttonStyle(QuietButton()).font(UIStyle.meta).fixedSize()
              .help("Serein closes its older pages when it needs room. Keep this one open.")
          }
          if state.threadID != nil {
            Button("Show task") {
              if let agent = browser.intelligenceAgent { dock.show(state, browser: browser, agent: agent) }
            }.buttonStyle(QuietButton()).font(UIStyle.meta).fixedSize()
              .disabled(browser.intelligenceAgent == nil)
              .help("Show the task that used this page")
          }
          Button {
            dock.hiddenBanners.insert(tab.id)
          } label: {
            InterfaceIcon(systemName: "xmark", size: 10).frame(width: 12, height: 12)
          }.buttonStyle(QuietButton()).help("Hide this line").accessibilityLabel("Hide this line")
        }
      }.padding(.leading, 16).padding(.trailing, 10).frame(height: 32)
        .background(p.card)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
  }
}
