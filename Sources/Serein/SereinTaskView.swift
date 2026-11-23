import AppKit
import SereinCore
import SwiftUI

/// A task Serein started, shown in the Serein surface (full or beside). It reads the task by id
/// (the live run's transcript, else the saved chat) and never sets AgentModel's current chat, so a
/// task tab in the main view and this view can show at the same time. Its replies go into the
/// task's own thread (`ComposerFlow.replyToTask`).
struct SereinTaskView: View {
  let id: String
  let style: RelayPanelView.Style
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  @ObservedObject private var placement = SereinSurface.main.placement
  @Environment(\.palette) var p
  init(id: String, style: RelayPanelView.Style, browser: BrowserModel, agent: AgentModel, relay: RelayOrchestrator,
       controller: RelayController)
  {
    self.id = id
    self.style = style
    self.browser = browser
    self.agent = agent
    hub = agent.hub
    self.relay = relay
    self.controller = controller
  }
  private var side: Bool { style == .side }
  var body: some View {
    let run = hub.latest(for: id)
    VStack(spacing: 0) {
      // Full: the content card's header row is the task's (SereinHeaderSlot). Beside: the same
      // header in the panel's first row.
      if side {
        SereinTaskHeader(id: id, browser: browser, agent: agent, relay: relay, style: .side)
          .padding(.leading, 6).padding(.trailing, 8).frame(height: 44)
        Rectangle().fill(p.line).frame(height: 1)
        SereinWaitingLine(relay: relay, underTask: true)
      }
      if placement.taskDetails {
        SereinTaskDetails(id: id, browser: browser, agent: agent)
          .frame(maxWidth: side ? .infinity : UIStyle.composerWidth).frame(maxWidth: .infinity)
        Rectangle().fill(p.line).frame(height: 1)
      }
      Group {
        if let run {
          SereinLiveTaskMessages(id: id, run: run, browser: browser, agent: agent, full: !side)
        } else {
          SereinTaskMessages(
            id: id, messages: agent.conversations.first { $0.id == id }?.messages ?? [], run: nil,
            browser: browser, agent: agent, full: !side)
        }
      }.frame(maxHeight: .infinity)
      if let run { SkillOfferLine(id: id, run: run, browser: browser, agent: agent, full: !side) }
      // “Working in Notes in the background · Stop”, while this task works in a Mac app.
      MacBackgroundLine(thread: id, full: !side)
      // An automatic move to a same-cost backup, with Undo.
      ModelSwitchBanner(agent: agent, chat: id)
      SereinTaskComposer(id: id, browser: browser, agent: agent, full: !side)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .onExitCommand { if side { SereinRouter.escapeSide() } }
      .accessibilityElement(children: .contain).accessibilityLabel("Task")
  }
}

/// A live run's transcript: re-renders as it streams.
private struct SereinLiveTaskMessages: View {
  let id: String
  @ObservedObject var run: AgentRun
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  let full: Bool
  var body: some View {
    SereinTaskMessages(id: id, messages: run.transcript, run: run, browser: browser, agent: agent, full: full)
  }
}

/// The task's messages, the Thinking row (its one step log) on the latest turn, and each turn's
/// edit review, whose answers are applied to this task's thread.
private struct SereinTaskMessages: View {
  let id: String
  let messages: [AgentMessage]
  let run: AgentRun?
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  let full: Bool
  /// The task's older messages, built above its newest ones as the person scrolls up.
  @StateObject private var pages = EarlierPages()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.palette) var p
  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          let start: Int = pages.liveStart(in: messages, thread: id, newest: TranscriptWindow.newest)
          let shown = Array(messages[start...])
          let breaks: Set<String> = ChatTurns.breaks(messages, from: start)
          let userWidth: CGFloat = max(0, min(geometry.size.width, UIStyle.composerWidth) - 32) * 0.8
          VStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
            if messages.isEmpty {
              Text(run?.isActive == true ? "Serein is starting this task." : "This task has no chat to show.")
                .role(.meta).frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
            }
            if start > 0 {
              EarlierMessagesRegion(pages: pages, rows: EarlierRows(thread: id, messages: messages, liveStart: start) { index in
                olderRow(index, userWidth: userWidth)
              })
            }
            let latestCopyID = messages.last(where: { !$0.text.isEmpty })?.id
            ForEach(Array(shown.enumerated()), id: \.element.id) { offset, message in
              taskRow(message, after: start + offset > 0 ? messages[start + offset - 1] : nil, breaks: breaks,
                      latestCopyID: latestCopyID, userWidth: userWidth, live: true)
            }
            TaskAttentionNotice(id: id, hub: agent.hub) {
              DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // After the run: the recording of it, when Record this task was on.
            if run?.isActive != true { TaskReplaySection(thread: id) }
            // Serein's computer, while this task holds or waits for it (ComputerHost).
            ComputerSection(thread: id)
            // What the task downloaded, kept or deleted by the person (TaskShelf).
            TaskShelfSection(thread: id)
            Color.clear.frame(height: 1).id("bottom")
          }.padding(.horizontal, 16).padding(.vertical, full ? 24 : 16)
            .frame(maxWidth: full ? UIStyle.composerWidth : .infinity).frame(maxWidth: .infinity)
            // A short chat still starts at the top of the view.
            .frame(minHeight: geometry.size.height, alignment: .top)
        }
        .modifier(TranscriptOpensAtEnd(thread: id))
        .onChange(of: messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        .onChange(of: messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
      }
    }
  }
  /// One message of the task: its turn gap and time line, then the message, or its condensed
  /// divider. `live` rows are in the chat's own layout and carry the run's trace and edit
  /// reviews; older rows are built outside it (EarlierPages) and show a review only when one exists.
  @ViewBuilder private func taskRow(_ message: AgentMessage, after previous: AgentMessage?, breaks: Set<String>,
                                    latestCopyID: String?, userWidth: CGFloat, live: Bool) -> some View {
    TurnLead(message: message, after: previous, breaks: breaks)
    if let range = message.condensed {
      // Undo waits while the task works; its run still owns the transcript.
      CondensedDivider(
        summary: message, range: range, userWidth: userWidth,
        undo: run?.isActive == true ? nil : { agent.undoCondense(message.id, in: id) })
    } else {
      let isLast = message.id == messages.last?.id
      let trace = live && isLast ? run : nil
      let edit: ((String) -> Void)? = message.role == "you"
        ? { text in agent.flow.rerunTask(id, from: message.id, text: text) } : nil
      MessageHoverControls(alwaysVisible: message.id == latestCopyID) { showsCopy in
        VStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
          if message.role != "you", let trace { ThreadRunTrace(browser: browser, run: trace, compact: { _ = agent.compactNow(trace.spec.threadID) }) }
          if message.role == "you" || !message.text.isEmpty || !(message.images ?? []).isEmpty
            || message.activities?.isEmpty == false || trace?.isActive != true
          {
            ThreadMessageContent(
              message: message,
              placeholder: message.text.isEmpty ? (trace?.isActive == true ? trace?.phase ?? "" : "") : "",
              userWidth: userWidth,
              showsCopy: showsCopy, palette: p, showsActivities: trace?.steps.isEmpty != false,
              edit: edit,
              changedFiles: {
                MessageEdit.laterFileChanges(from: message.id, in: agent.hub.latest(for: id)?.transcript ?? messages)
              }
            ).equatable()
          }
          if message.role == "you", let trace { ThreadRunTrace(browser: browser, run: trace, compact: { _ = agent.compactNow(trace.spec.threadID) }) }
          if live || EditReview.shared.review(for: message.id) != nil { TurnReviewSlot(agent: agent, threadID: id, messageID: message.id) }
        }
      }
    }
  }
  /// `messages[index]` as an older row (EarlierPages): drawn again when the message, its place in
  /// a turn, Undo, a review or the width changes.
  private func olderRow(_ index: Int, userWidth: CGFloat) -> EarlierRow {
    let message = messages[index]
    let previous: AgentMessage? = index > 0 ? messages[index - 1] : nil
    // Checked on every update of the task, so only what is cheap to compare: the turn gap and
    // time line follow from the message before.
    let key = TaskOlderKey(message: message, previous: previous, undo: message.condensed != nil && run?.isActive != true,
                           review: EditReview.shared.review(for: message.id) != nil, width: userWidth)
    return EarlierRow(key: EarlierRowKey(key)) {
      let breaks: Set<String> = ChatTurns.breaks(messages, from: index, through: index)
      return AnyView(taskRow(message, after: previous, breaks: breaks, latestCopyID: nil, userWidth: userWidth, live: false))
    }
  }
}

/// What an older row of a task draws from (`SereinTaskMessages.olderRow`).
private struct TaskOlderKey: Equatable {
  let message: AgentMessage
  let previous: AgentMessage?
  let undo: Bool
  let review: Bool
  let width: CGFloat
}

/// The task's header: “‹ Serein”, its title (which truncates first) over its model pill, the
/// status pill, Stop while it runs, Make full or Put beside, and ⋯ (Try Again, Show Details, See the
/// Page, Session Log, Export…, Save as Skill… once done, Delete Chat…).
/// Once the run has left the hub the pill and Try Again read the thread's latest record. Beside a
/// tab the controls sit tight; at the default 380 points the model pill steps aside, and
/// narrower still the pill shows its dot and time only (its words stay in its help and VoiceOver
/// value), so “‹ Serein” and the title keep room.
struct SereinTaskHeader: View {
  let id: String
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  @ObservedObject var relay: RelayOrchestrator
  var style: RelayPanelView.Style
  @ObservedObject private var placement = SereinSurface.main.placement
  @ObservedObject private var tray = SereinTray.shared
  @AppStorage("serein.compact") private var compactMode = false
  @State private var width: CGFloat = 0
  /// Save as Skill's draft while its review sheet is open.
  @State private var skillDraft: TaskSkillDraft?
  /// The task's session log is open (SessionLogSheet).
  @State private var logOpen = false
  @Environment(\.palette) var p
  init(id: String, browser: BrowserModel, agent: AgentModel, relay: RelayOrchestrator, style: RelayPanelView.Style) {
    self.id = id
    self.browser = browser
    self.agent = agent
    hub = agent.hub
    self.relay = relay
    self.style = style
  }
  private var side: Bool { style != .full }
  /// The header row is under 380 points less its insets.
  private var narrow: Bool { side && width > 0 && width < 360 }
  /// Beside at its default width and narrower, the model pill steps aside so “‹ Serein”, a
  /// readable title and Show Serein full (⌘J) all fit.
  private var tight: Bool { side && width > 0 && width < 400 }
  var body: some View {
    let run = hub.latest(for: id)
    let record = tray.record(id)
    let thread = agent.conversations.first { $0.id == id }
    let title = run?.spec.title ?? record?.title ?? thread?.title ?? "Task"
    // The pill goes under the title, or beside it where two lines would overflow the header
    // (Compact Mode, or text above 115%).
    let stacked = !compactMode && UIStyle.textScale <= 1.15
    let titleLayout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
    HStack(spacing: side ? 2 : 8) {
      Button { SereinRouter.backToChat() } label: {
        HStack(spacing: 2) {
          InterfaceIcon(systemName: "chevron.left", size: 11)
          Text("Serein").font(UIStyle.meta).fixedSize()
        }.foregroundStyle(p.secondary).padding(.horizontal, side ? 3 : 6).frame(minWidth: 22).frame(height: 24)
          .contentShape(Rectangle())
      }.buttonStyle(QuietButton()).help("Back to Serein’s chat").accessibilityLabel("Back to Serein")
        .fixedSize().layoutPriority(2)
      titleLayout {
        Text(title.isEmpty ? "Task" : title).font(UIStyle.font(13, weight: .semibold)).foregroundStyle(p.ink)
          .lineLimit(1).truncationMode(.tail).help(title).accessibilityAddTraits(.isHeader)
        // The engine this task's next reply goes to, switched for this task only.
        if thread != nil, !tight {
          // A long model name never widens the row past its column: it falls back to the logo.
          ViewThatFits(in: .horizontal) {
            ModelPill(agent: agent, chat: id, compact: narrow)
            ModelPill(agent: agent, chat: id, compact: true)
          }
        }
      }.padding(.leading, side ? 2 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let run {
        SereinTaskPill(run: run, compact: narrow, side: side).fixedSize().layoutPriority(2)
      } else if let record {
        // A record still marked running with no run behind it ended with an earlier launch.
        SereinRecordPill(outcome: record.outcome == .running ? .stopped : record.outcome,
                         seconds: (record.endedAt ?? record.lastEventAt).timeIntervalSince(record.startedAt),
                         compact: narrow, side: side).fixedSize().layoutPriority(2)
      } else if thread != nil {
        // No run and no record left (an earlier launch, a trimmed ledger): the card's words, and
        // no outcome guessed.
        SereinEarlierPill(side: side).fixedSize().layoutPriority(2)
      }
      if let run, run.isActive {
        Button { hub.stop(run) } label: {
          Text("Stop").font(UIStyle.metaStrong).foregroundStyle(p.ink).padding(.horizontal, side ? 5 : 8).frame(height: 24)
            .contentShape(Rectangle())
        }.buttonStyle(QuietButton()).fixedSize().layoutPriority(2)
          .help("Stop this task. Serein keeps working on other things.").accessibilityLabel("Stop this task")
      }
      HStack(spacing: 0) {
        if side {
          Button { SereinRouter.toggleFullBeside() } label: { icon("arrow.up.left.and.arrow.down.right") }
            .modifier(HeaderIconStyle(side: true)).help("Show Serein full · ⌘J").accessibilityLabel("Show Serein full")
        } else if SereinRouter.returnSection != nil {
          let words = SereinLayout.putBeside(fits: placement.fits)
          Button { SereinRouter.toggleFullBeside() } label: { icon("sidebar.right") }
            .modifier(HeaderIconStyle(side: false)).help(words.help).accessibilityLabel(words.label)
        }
        SereinMenuButton("More", help: "More") {
          menu(outcome: run?.record.outcome ?? record?.outcome, title: title, earlier: run == nil && record == nil && thread != nil)
        } label: { icon("ellipsis") }
          .modifier(HeaderIconStyle(side: side, quiet: false)).fixedSize()
      }.fixedSize().layoutPriority(2)
    }
    // The width offered to the row (not the row's own, which can run wider than it).
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .sheet(isPresented: Binding(get: { skillDraft != nil }, set: { if !$0 { skillDraft = nil } })) {
      if let skillDraft {
        SaveSkillSheet(draft: skillDraft, saved: { SkillOfferLine.close(id) }) { self.skillDraft = nil }.environment(\.palette, p)
      }
    }
    .sheet(isPresented: $logOpen) {
      SessionLogSheet(id: id, agent: agent) { logOpen = false }.environment(\.palette, p)
    }
  }
  private func icon(_ symbol: String) -> some View {
    InterfaceIcon(systemName: symbol, size: side ? 13 : 14).foregroundStyle(side ? p.secondary : p.ink)
      .frame(width: side ? 22 : 26, height: side ? 24 : 26).contentShape(Rectangle())
  }
  @SereinMenuBuilder private func menu(outcome: RunRecord.Outcome?, title: String, earlier: Bool) -> [SereinMenuItem] {
    // A run still marked running with no live run behind it stopped with an earlier launch.
    let ended = outcome == .running && hub.run(for: id) == nil ? .stopped : outcome
    if let ended, [.done, .stuck, .stopped].contains(ended) {
      SereinMenuItem.action("Try Again", icon: "arrow.clockwise") { Self.tryAgain(id, agent: agent) }
    } else if earlier, Self.lastRequest(id, agent: agent) != nil {
      // Finished earlier, its outcome unknown: its chat still has the request to send again.
      SereinMenuItem.action("Try Again", icon: "arrow.clockwise") { Self.tryAgain(id, agent: agent) }
    }
    SereinMenuItem.action(placement.taskDetails ? "Hide Details" : "Show Details", icon: "info.circle") {
      placement.taskDetails.toggle()
    }
    if let page = browser.taskPage(thread: id) {
      SereinMenuItem.action("See the Page", icon: "globe") { browser.openTaskPage(page) }
    }
    // Off the Working strip (and its “Needs you” off the Serein row) once it has ended; the
    // chat and its card stay.
    if hub.run(for: id) == nil,
      SereinTray.items(hub: hub, agent: agent, relay: relay, ledger: tray.ledger, now: Date()).contains(where: { $0.id == id })
    {
      SereinMenuItem.action("Dismiss", icon: "checkmark.circle") { SereinTray.shared.dismiss(id) }
    }
    if !Self.messages(id, agent: agent).isEmpty {
      SereinMenuItem.action("Session Log", icon: "list.bullet.rectangle") { logOpen = true }
      SereinMenuItem.action("Export…", icon: "square.and.arrow.up") {
        ChatExport.save(title: title, messages: Self.messages(id, agent: agent),
                        assistant: (hub.latest(for: id)?.spec.provider ?? agent.conversations.first { $0.id == id }?.provider ?? agent.provider).name)
      }
    }
    // Only once the task is done, and only from the steps Serein itself recorded.
    if ended == .done, let draft = Self.skillDraft(id, browser: browser, agent: agent) {
      SereinMenuItem.action("Save as Skill…", icon: "square.and.pencil") { skillDraft = draft }
    }
    SereinMenuItem.divider
    SereinMenuItem.action("Delete Chat…", icon: "trash", destructive: true) {
      if SereinTaskActions.confirmDelete(title: title) {
        agent.flow.deleteThreads([id])
        SereinRouter.backToChat()
      }
    }
  }
  /// The task's chat: the live run's transcript, else the saved thread (as the view shows it).
  static func messages(_ id: String, agent: AgentModel) -> [AgentMessage] {
    agent.hub.latest(for: id)?.transcript ?? agent.conversations.first { $0.id == id }?.messages ?? []
  }
  /// Save as Skill's draft (TaskSkill.draft, no model) from the task's own record: the board's
  /// browser steps and the run's own steps in time order (`TaskTabInfo.steps`), or, once the run
  /// is gone with no board steps left, the steps saved with its chat. The request and title are
  /// never copied. Nil when Serein recorded no step.
  @MainActor static func skillDraft(_ id: String, browser: BrowserModel, agent: AgentModel) -> TaskSkillDraft? {
    let info = TaskTabInfo(key: id, browser: browser, agent: agent, dock: .shared)
    let runIDs = Set((info.run?.steps ?? []).map(\.id))
    var steps = info.steps.map {
      TaskSkill.Step(tool: $0.tool, label: $0.label, browser: !runIDs.contains($0.id), failed: $0.failed != nil)
    }
    if steps.isEmpty && info.run == nil {
      steps = messages(id, agent: agent).flatMap { $0.activities ?? [] }
        .map { TaskSkill.Step(tool: $0.tool, label: $0.label, browser: false, failed: $0.failed) }
    }
    return steps.isEmpty ? nil : TaskSkill.draft(steps: steps)
  }
  static func lastRequest(_ id: String, agent: AgentModel) -> String? {
    ThreadActions.lastRequest(messages(id, agent: agent).map { ($0.role, $0.text) })
  }
  /// Try Again: the task's last request, sent again into its own thread. If it cannot go (the AI
  /// app is missing, the chat is gone), the task's view opens and its composer says why.
  static func tryAgain(_ id: String, agent: AgentModel) {
    guard let request = lastRequest(id, agent: agent) else {
      agent.flow.setTaskReplyError(id, "This task has no request to send again.")
      SereinRouter.openTask(id)
      return
    }
    agent.flow.setTaskReplyError(id, nil)
    Task {
      if let refused = await agent.flow.replyToTask(id, text: request, interrupt: false) {
        agent.flow.setTaskReplyError(id, refused)
        SereinRouter.openTask(id)
      }
    }
  }
}

/// “Working · 2:16”, “Needs you”, “Done in 3 min”, “Could not finish”, “Stopped”. It ticks once a
/// second only while the task runs (`AtWorkTimelineSchedule`).
struct SereinTaskPill: View {
  @ObservedObject var run: AgentRun
  var compact = false
  var side = false
  var body: some View {
    TimelineView(AtWorkTimelineSchedule(items: run.isActive ? [run.atWorkItem] : [])) { context in
      SereinRecordPill(outcome: run.record.outcome,
                       seconds: (run.record.endedAt ?? context.date).timeIntervalSince(run.record.startedAt),
                       compact: compact, side: side)
    }
  }
}

/// A task with no run and no record left: “Finished earlier”, as its card says, with no outcome
/// guessed.
struct SereinEarlierPill: View {
  var side = false
  @Environment(\.palette) var p
  var body: some View {
    Text(TaskWords.finishedEarlier).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1)
      .padding(.horizontal, side ? 6 : 8).frame(height: 22)
      .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      .help("This task finished before Serein last started")
      .accessibilityElement(children: .ignore).accessibilityLabel("Status").accessibilityValue(TaskWords.finishedEarlier)
  }
}

/// The pill's look for one outcome: a dot (a check once done) and its words, or in a narrow
/// header the dot and the time.
struct SereinRecordPill: View {
  let outcome: RunRecord.Outcome
  let seconds: TimeInterval
  var compact = false
  var side = false
  @Environment(\.palette) var p
  var body: some View {
    let words = TaskWords.pill(outcome, seconds: seconds)
    HStack(spacing: 4) {
      if outcome == .done {
        InterfaceIcon(systemName: "checkmark", size: 9).foregroundStyle(p.success)
      } else {
        Circle().fill(Self.color(outcome, p)).frame(width: 6, height: 6)
      }
      Text(compact ? TaskWords.compactPill(outcome, seconds: seconds) : words)
        .font(UIStyle.meta).monospacedDigit().foregroundStyle(p.ink).lineLimit(1)
    }.padding(.horizontal, side ? 6 : 8).frame(height: 22)
      .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      .help(words)
      .accessibilityElement(children: .ignore).accessibilityLabel("Status").accessibilityValue(words)
  }
  static func color(_ outcome: RunRecord.Outcome, _ p: Palette) -> Color {
    switch outcome {
    case .running: return p.accent
    case .waiting: return p.warning
    case .done: return p.success
    case .stuck: return p.danger
    case .stopped: return p.faint
    }
  }
}

/// Show Details: the AI app, model and effort, what the task may touch, its time and usage, and
/// the step timeline.
private struct SereinTaskDetails: View {
  let id: String
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @Environment(\.palette) var p
  var body: some View {
    let info = TaskTabInfo(key: id, browser: browser, agent: agent, dock: .shared)
    let effort = info.run?.spec.effort ?? agent.conversations.first { $0.id == id }?.effort ?? ""
    VStack(alignment: .leading, spacing: 10) {
      Text(([info.agentName, info.model.isEmpty ? "Default model" : ModelBadge.display(info.model, provider: info.agentName)]
            + (effort.isEmpty ? [] : [HarnessOption.effortLabel(effort) + " effort"])).joined(separator: " · "))
        .font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(2)
      if let chips = info.permissions { PermissionChips(chips: chips, run: info.run, browser: browser, agent: agent) }
      if browser.tasks[id] != nil { TaskSitesEditor(taskID: id, browser: browser) }
      HStack(spacing: 14) {
        if let start = info.startedAt { fact("Started", start.formatted(date: .omitted, time: .shortened)) }
        fact(info.running ? "Elapsed" : "Took", TaskClock.short(info.seconds(now: Date())))
        if let tokens = info.run?.record.tokens, tokens > 0 { fact("Usage", TokenCount.label(tokens)) }
        Spacer(minLength: 0)
      }
      StepTimeline(steps: info.steps, startedAt: info.startedAt, cap: 140, retry: { words in
        // The task's own reply path, so a refusal shows where its composer shows one.
        Task { @MainActor in if let refused = await agent.flow.replyToTask(id, text: words, interrupt: false) { agent.flow.setTaskReplyError(id, refused) } }
      })
    }.padding(.horizontal, 16).padding(.vertical, 12)
  }
  func fact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(UIStyle.micro).foregroundStyle(p.secondary)
      Text(value).font(UIStyle.microMono).foregroundStyle(p.secondary)
    }.accessibilityElement(children: .combine)
  }
}

/// The task's reply box, labelled with its target (“Reply to Codex in shop-web”) and its place's
/// glyph, so it never looks like Serein's. While the task works Return holds the reply for when the
/// step ends and ⌥Return stops the step and sends now (the task composer's rule). Options sets the
/// model and effort of the next reply.
private struct SereinTaskComposer: View {
  let id: String
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  @ObservedObject var flow: ComposerFlow
  let full: Bool
  /// The reply being written. It starts from, and is kept in, the surface's per-task drafts, so
  /// switching Serein full ⇄ beside (which builds this view again) loses nothing.
  @State private var draft: String
  @State private var guidanceOwner = UUID().uuidString
  @State private var focused = false
  @State private var options = false
  @Environment(\.palette) var p
  init(id: String, browser: BrowserModel, agent: AgentModel, full: Bool) {
    self.id = id
    self.browser = browser
    self.agent = agent
    hub = agent.hub
    flow = agent.flow
    self.full = full
    _draft = State(initialValue: SereinSurface.main.taskDrafts[id] ?? "")
  }
  /// The next reply's model and effort from Options, kept by the flow for this task.
  private var model: String? { flow.taskChoices[id]?.model }
  private var effort: String? { flow.taskChoices[id]?.effort }
  private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var side: Bool { !full }
  var body: some View {
    let thread = agent.conversations.first { $0.id == id }
    let run = hub.latest(for: id)
    // The next reply goes to the task's record (a model pill switch writes it); the line above
    // the field still names who is working now.
    let provider = thread?.provider ?? run?.spec.provider ?? agent.provider
    let working = run?.spec.provider ?? provider
    let mode = (run?.spec.mode ?? thread?.mode ?? .answer).runKey
    let project = run?.spec.projectName ?? thread?.projectID.flatMap { id in browser.projects.first { $0.id == id }?.name }
    let label = TaskWords.replyTo(app: provider.name, mode: mode, project: project)
    let running = hub.run(for: id) != nil
    let waiting = !running && (run?.record.outcome ?? SereinTray.shared.record(id)?.outcome) == .waiting
    let currentModel = model ?? run?.spec.model ?? thread?.model ?? ""
    let badge = TaskWords.modelBadge(currentModel)
    let modelName = currentModel.isEmpty ? provider.shortName : ModelBadge.display(currentModel, provider: provider.shortName)
    VStack(alignment: .leading, spacing: 6) {
      let stuck = flow.taskReplyStuck(id)
      if running {
        Text(flow.stepPath(id) == .intoTurn
          ? "\(working.name) is working. Your reply goes to it now."
          : "\(working.name) is working. Your reply sends when this step ends.")
          .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      } else if stuck, flow.taskReplyError[id] == nil {
        // The step was stopped or failed, so its held reply did not go: you decide.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("The last step did not finish. Send this now?")
            .font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
          Button { flow.retryTaskReply(id) } label: { Text("Send now").font(UIStyle.metaStrong).foregroundStyle(p.accent) }
            .buttonStyle(QuietButton()).fixedSize().help("Send the held reply now")
        }
      } else if waiting {
        Text("\(working.name) is waiting for your answer. Reply below.")
          .font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
      }
      if let live = hub.run(for: id) { SteeringRows(run: live) }
      ForEach(flow.queue.items(for: id)) { item in
        HStack(spacing: 6) {
          // While the step works it is held for its end; once nothing works, it has not gone.
          Text("\(running ? "Sends when this step ends" : "Not sent"): “\(TaskWords.short(item.text))”")
            .font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
          Button { flow.removeTaskReply(item.id) } label: {
            InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary).frame(width: 16, height: 16)
              .contentShape(Rectangle())
          }.buttonStyle(.pressable).help("Do not send this").accessibilityLabel("Do not send: \(item.text)")
        }.padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
          .background(p.card, in: Capsule())
      }
      HStack(alignment: .center, spacing: 8) {
        InterfaceIcon(systemName: TaskDestination.of(mode: run?.spec.mode ?? thread?.mode, projectName: project, web: false).icon, size: 13)
          .foregroundStyle(p.secondary).frame(width: 16).accessibilityHidden(true)
        ComposerInput(placeholder: label, text: $draft, focused: $focused, maxHeight: 120, label: label) { option in
          switch ComposerKey.resolve(running: running, hasText: hasText, shift: false, option: option) {
          case .send: send(interrupt: false)
          case .addToStep: send(interrupt: false)
          case .interruptAndSend: send(interrupt: true)
          case .newline, .ignore: break
          }
        }.textInputCursor().layoutPriority(1)
        // Full, Options sits by the field; beside a tab it moves to the row below, so the field
        // keeps room to say whom it replies to.
        if !side { optionsChip(badge: badge, modelName: modelName, provider: provider, run: run, thread: thread, currentModel: currentModel) }
        Button { send(interrupt: false) } label: {
          InterfaceIcon(systemName: "arrow.up", size: 13).foregroundStyle(p.onSolid)
            .frame(width: 28, height: 28).background(p.solid, in: Circle())
        }.buttonStyle(.pressable).disabled(!hasText)
          .help("Send to \(provider.name)").accessibilityLabel("Send to \(provider.name)")
      }
      if side || running {
        HStack(spacing: 8) {
          if side { optionsChip(badge: badge, modelName: modelName, provider: provider, run: run, thread: thread, currentModel: currentModel) }
          if running {
            // Beside a tab the short form fits whole; the full sentence stays in its help.
            Text(side ? "⌥Return sends now" : "⌥Return stops the step and sends now").font(UIStyle.micro)
              .foregroundStyle(p.secondary).lineLimit(1).fixedSize()
              .help("⌥Return stops the step and sends now")
              .accessibilityLabel("Option-Return stops the step and sends now")
          }
          Spacer(minLength: 0)
        }
      }
      if let message = flow.taskReplyError[id] {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(message).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
          if !running, !flow.queue.items(for: id).isEmpty {
            Button { flow.retryTaskReply(id) } label: { Text("Try again").font(UIStyle.metaStrong).foregroundStyle(p.accent) }
              .buttonStyle(QuietButton()).fixedSize().help("Send the held reply now")
          }
        }
      }
    }.padding(.horizontal, 14).padding(.vertical, 10)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.composerRadius, style: .continuous))
      .frame(maxWidth: full ? UIStyle.composerWidth : .infinity)
      .padding(.horizontal, full ? 16 : 12).padding(.bottom, full ? 16 : 12).padding(.top, 4)
      .frame(maxWidth: .infinity)
      .onReceive(NotificationCenter.default.publisher(for: SereinSurface.focus)) { _ in focused = true }
      .onChange(of: draft) { _, text in
        SereinSurface.main.taskDrafts[id] = text.isEmpty ? nil : text
        GuidanceTaskInput.shared.set(text, owner: guidanceOwner)
        HintCenter.shared.recordInteraction()
      }
      .onAppear { GuidanceTaskInput.shared.set(draft, owner: guidanceOwner) }
      .onDisappear { GuidanceTaskInput.shared.clear(owner: guidanceOwner) }
  }
  /// “Options · Opus”: the model and effort of the next reply. A model with no short name reads
  /// “Options” alone; the full name is in its help and the popover.
  private func optionsChip(badge: String, modelName: String, provider: Provider, run: AgentRun?, thread: Conversation?,
                           currentModel: String) -> some View
  {
    Button { options.toggle() } label: {
      Text(badge.isEmpty ? "Options" : "Options · \(badge)")
        .font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, 8).frame(height: 24)
        .background(p.track, in: Capsule()).contentShape(Capsule())
    }.buttonStyle(.pressable).fixedSize().help("Model and effort for this task’s next reply · \(modelName)")
      .accessibilityLabel("Options").accessibilityValue(modelName)
      .popover(isPresented: $options, arrowEdge: .bottom) {
        SereinTaskOptions(thread: id, provider: provider,
                          model: Binding(get: { model ?? currentModel }, set: { flow.setTaskChoice(id, model: $0, effort: nil) }),
                          effort: Binding(get: { effort ?? run?.spec.effort ?? thread?.effort ?? "medium" },
                                          set: { flow.setTaskChoice(id, model: nil, effort: $0) }))
          .environment(\.palette, p)
      }
  }
  private func send(interrupt: Bool) {
    let text = draft
    guard hasText else { return }
    draft = ""
    flow.setTaskReplyError(id, nil)
    Task {
      if let refused = await flow.replyToTask(id, text: text, model: model, effort: effort, interrupt: interrupt) {
        flow.setTaskReplyError(id, refused)
        if draft.isEmpty { draft = text }
      }
    }
  }
}

/// Options: the model and effort of the task's next reply (place and permissions are Serein's
/// choice, under Show Details), and Record this task (off unless turned on, kept per thread).
private struct SereinTaskOptions: View {
  let thread: String
  let provider: Provider
  @Binding var model: String
  @Binding var effort: String
  @ObservedObject private var recordings = TaskRecordings.shared
  @Environment(\.palette) var p
  var body: some View {
    let models = HarnessRegistry.shared.models(provider)
    let picked = model.isEmpty ? (models.first(where: \.isDefault)?.id ?? "") : model
    let chosen = models.first { $0.id == ClaudeModelID.split(picked).base }
    let levels = chosen?.effortLevels ?? []
    VStack(alignment: .leading, spacing: 10) {
      Text("Next reply").font(UIStyle.bodyStrong)
      Picker("Model", selection: Binding(get: { picked }, set: { model = $0 })) {
        if models.isEmpty { Text(provider.shortName).tag("") }
        ForEach(models) { item in Text(item.name.isEmpty ? item.id : item.name).tag(item.id) }
        if !picked.isEmpty, !models.contains(where: { $0.id == picked }) { Text(picked).tag(picked) }
      }
      // No Effort picker for a model that lists no levels: none is sent for it.
      if !levels.isEmpty {
        Picker("Effort", selection: $effort) {
          ForEach(levels, id: \.self) { level in Text(HarnessOption.effortLabel(level)).tag(level) }
          if !levels.contains(effort) { Text(HarnessOption.effortLabel(effort)).tag(effort) }
        }
      }
      Text("Serein chooses where the task works and what it may touch. Show Details lists them.")
        .font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      Divider().overlay(p.line)
      Toggle("Record this task", isOn: Binding(get: { recordings.threads.contains(thread) },
                                               set: { recordings.set($0, thread: thread) }))
      Text(TaskRecording.switchNote)
        .font(UIStyle.micro).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }.padding(16).frame(width: 280)
  }
}

/// Delete Chat…, with the same question from every place that deletes a task's chat.
@MainActor enum SereinTaskActions {
  static func confirmDelete(title: String) -> Bool {
    if RunMode.automated { return false }
    let alert = NSAlert()
    alert.messageText = TaskWords.deleteTitle(title)
    alert.informativeText = TaskWords.deleteBody
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.cancelByDefault()
    return alert.runModal() == .alertFirstButtonReturn
  }
}

extension BrowserModel {
  /// The page a task worked in: its newest agent tab still on the board, else a tab kept from it.
  func taskPage(thread id: String) -> BrowserTab? {
    let task = agentTabs.runs.filter { $0.value.threadID == id }.max { $0.value.startedAt < $1.value.startedAt }?.key
    if let task, let entry = agentTabs.entries.last(where: { $0.taskID == task }) { return entry.tab }
    return tabs.first { $0.agentMark?.threadID == id }
  }
  /// See the Page, Show task's way back: Serein's page as it is, or the tab it became.
  func openTaskPage(_ tab: BrowserTab) {
    if agentTabs.entry(tab.id) != nil { viewAgentTab(tab) } else { show(tab) }
  }
}

/// “Save how I did this as a skill?” under a long reply the person asked for (SkillOffer), with
/// Save, which opens Save as Skill prefilled (nothing is kept without that sheet's own Save), and
/// a dismiss. Once per chat, remembered on this Mac.
private struct SkillOfferLine: View {
  let id: String
  @ObservedObject var run: AgentRun
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  let full: Bool
  @State private var draft: TaskSkillDraft?
  @State private var gone = false
  @Environment(\.palette) var p
  static let turnsKey = "serein.skillOffer.turns"
  static let closedKey = "serein.skillOffer.closed"
  /// Put away, or a skill saved from this chat: no offer again.
  static func close(_ chat: String) {
    let closed = UserDefaults.standard.stringArray(forKey: closedKey) ?? []
    guard !closed.contains(chat) else { return }
    // shortcut: the newest 500 chats are kept; an older chat could be offered once more.
    UserDefaults.standard.set(Array((closed + [chat]).suffix(500)), forKey: closedKey)
  }
  private var offered: String? { (UserDefaults.standard.dictionary(forKey: Self.turnsKey) as? [String: String])?[id] }
  private var shows: Bool {
    guard !gone else { return false }
    let kind = StepBudget.kind(initiator: run.spec.initiator, relay: run.spec.relay, unattended: false)
    let closed = (UserDefaults.standard.stringArray(forKey: Self.closedKey) ?? []).contains(id)
    return SkillOffer.offers(outcome: run.record.outcome, steps: run.record.toolCount, kind: kind, turn: run.id,
                             offeredFor: offered, closed: closed)
  }
  var body: some View {
    if shows, let made = SereinTaskHeader.skillDraft(id, browser: browser, agent: agent) {
      HStack(spacing: 8) {
        Text(SkillOffer.words).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
        // The font sits on the label: QuietButton sets its own on the label, which would win.
        Button { draft = made } label: {
          Text("Save").font(UIStyle.metaStrong).foregroundStyle(p.ink)
        }.buttonStyle(QuietButton()).fixedSize()
          .help("Opens Save as Skill with the steps filled in").accessibilityLabel("Save how this was done as a skill")
        Spacer(minLength: 0)
        Button {
          Self.close(id)
          gone = true
        } label: {
          InterfaceIcon(systemName: "xmark", size: 10).foregroundStyle(p.secondary).frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }.buttonStyle(QuietButton()).help("Don't offer this here again").accessibilityLabel("Dismiss the skill offer")
      }.padding(.horizontal, full ? 0 : 14).frame(height: 32)
        .frame(maxWidth: full ? UIStyle.composerWidth : .infinity).padding(.horizontal, full ? 16 : 0)
        .frame(maxWidth: .infinity)
        .onAppear {
          // The chat's one offer goes to this turn.
          var turns = UserDefaults.standard.dictionary(forKey: Self.turnsKey) as? [String: String] ?? [:]
          guard turns[id] == nil else { return }
          if turns.count >= 500, let old = turns.keys.first { turns[old] = nil }
          turns[id] = run.id
          UserDefaults.standard.set(turns, forKey: Self.turnsKey)
        }
        .sheet(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
          if let draft {
            SaveSkillSheet(draft: draft, saved: {
              Self.close(id)
              gone = true
            }) { self.draft = nil }.environment(\.palette, p)
          }
        }
    }
  }
}
