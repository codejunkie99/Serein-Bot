import AppKit
import SereinCore
import SwiftUI

/// Where a task works, as the panel and its tabs name it.
struct TaskDestination: Equatable {
  var label: String
  var short: String
  var icon: String
  static func of(mode: TaskMode?, projectName: String?, web: Bool) -> TaskDestination {
    switch mode {
    case .page: return TaskDestination(label: "This page", short: "Page", icon: "globe")
    case .project:
      let name = projectName ?? "Project"
      let first = String(name.split(separator: " ").first ?? Substring(name))
      return TaskDestination(label: name, short: first, icon: "folder")
    case .anywhere: return TaskDestination(label: "Anywhere", short: "Mac", icon: "terminal")
    case .library: return TaskDestination(label: "Library", short: "Library", icon: "bookmark")
    case .answer: return TaskDestination(label: "Answer", short: "Answer", icon: "bubble.left")
    case .auto where !web: return TaskDestination(label: "Auto", short: "Auto", icon: "bubble.left")
    default: return TaskDestination(label: "Web", short: "Web", icon: "globe")
    }
  }
}

/// Everything the panel shows about one task tab: its thread, latest run and board record.
@MainActor struct TaskTabInfo {
  var key: String
  var agentName: String
  var model: String
  var status: AgentTabStatus?
  var startedAt: Date?
  var endedAt: Date?
  var run: AgentRun?
  var board: AgentTabBoard.RunInfo?
  var snapshot: TabAgentState?

  init(key: String, browser: BrowserModel, agent: AgentModel, dock: TaskDock) {
    self.key = key
    let conversation = agent.conversations.first { $0.id == key }
    let run = agent.hub.latest(for: key)
    let boardEntry = browser.agentTabs.runs
      .filter { $0.value.threadID == key || $0.key == key }
      .max { $0.value.startedAt < $1.value.startedAt }
    let snapshot = dock.state.flatMap { ($0.threadID ?? $0.taskID) == key ? $0 : nil }
    self.run = run
    board = boardEntry?.value
    self.snapshot = snapshot
    let current = key == agent.conversationID
    let provider = run?.spec.provider ?? conversation?.provider ?? (current ? agent.provider : nil)
    agentName =
      provider.map { $0.shortName } ?? boardEntry?.value.agent
      ?? snapshot?.agent ?? "Agent"
    model = run?.spec.model ?? conversation?.model ?? (current ? agent.model : "")
    if let run {
      status = run.display(board: boardEntry?.value).status
      startedAt = run.record.startedAt
      endedAt = run.record.endedAt
    } else if let snapshot {
      status = snapshot.status
      startedAt = snapshot.startedAt
      endedAt = snapshot.endedAt
    } else if let info = boardEntry?.value {
      status = info.ended ? AgentTabStatus.make(working: false, outcome: info.outcome) : .working
      startedAt = info.startedAt
      endedAt = info.endedAt
    }
  }
  var running: Bool { status == .working }
  func seconds(now: Date) -> TimeInterval {
    guard let startedAt else { return 0 }
    return (endedAt ?? now).timeIntervalSince(startedAt)
  }
  /// Board (browser) steps and the CLI's own steps, in time order.
  var steps: [AgentStep] {
    ((board?.steps ?? snapshot?.steps ?? []) + (run?.steps ?? [])).sorted { $0.time < $1.time }
  }
  /// The chips for what this run may touch; nil when no run is known.
  var permissions: [TaskPermissions.Chip]? {
    guard let grants = run?.spec.grants else { return nil }
    return TaskPermissions.chips(
      readsPages: true, currentTab: grants.currentTab, actions: grants.actions,
      signIns: grants.signIns, projectName: grants.projectName, edits: grants.edits, mac: grants.mac)
  }
}

/// Escape back to the page (Serein beside's empty composer).
@MainActor enum TaskPanelFocus {
  static func returnToPage(_ browser: BrowserModel) {
    guard browser.section == ShellSection.browser, let web = browser.active?.web, let window = web.window else {
      NSApp.keyWindow?.makeFirstResponder(nil)
      return
    }
    window.makeFirstResponder(web)
  }
}

/// What the run may touch. On grants show their names; off ones show only a muted icon.
/// Any chip opens one explanation of all five.
struct PermissionChips: View {
  var chips: [TaskPermissions.Chip]
  var run: AgentRun?
  var browser: BrowserModel?
  var agent: AgentModel?
  @State private var explain = false
  @Environment(\.palette) var p
  static func icon(_ kind: TaskPermissions.Kind) -> String {
    switch kind {
    case .pages: return "doc.text.magnifyingglass"
    case .act: return "cursorarrow.click"
    case .signIns: return "person.badge.key"
    case .edits: return "pencil"
    case .mac: return "macwindow"
    }
  }
  var body: some View {
    Button { explain.toggle() } label: {
      HStack(spacing: 4) {
        ForEach(chips) { chip in
          HStack(spacing: 4) {
            Image(systemName: Self.icon(chip.kind)).font(.system(size: 10))
            if chip.on { Text(chip.label).font(UIStyle.micro).lineLimit(1).fixedSize() }
          }.foregroundStyle(chip.on ? p.ink : p.faint.opacity(0.7))
            .padding(.horizontal, chip.on ? 7 : 5).frame(height: 20)
            .background(chip.on ? p.track : .clear, in: Capsule())
            .overlay {
              if !chip.on {
                Rectangle().fill(p.faint.opacity(0.7)).frame(width: 12, height: 1).rotationEffect(.degrees(-35))
              }
            }
        }
        Spacer(minLength: 0)
      }.contentShape(Rectangle())
    }.buttonStyle(.pressable).help("What this task may touch")
      .accessibilityLabel("Permissions")
      .accessibilityValue(chips.map { "\($0.label) \($0.on ? "allowed" : "off")" }.joined(separator: ", "))
      .accessibilityHint("Explains what this task may touch")
      .popover(isPresented: $explain, arrowEdge: .bottom) {
        Group {
          if let run, let browser {
            PermissionDetails.Live(chips: chips, run: run, browser: browser, agent: agent)
          } else {
            PermissionDetails(chips: chips, run: nil, browser: nil, agent: agent)
          }
        }.environment(\.palette, p)
      }
  }
}

/// The permissions popover: one row per grant. Each row shows one state. A row with a switch
/// names the switch's state, and its sentence describes that state. A row without a switch
/// shows the task's state as text where the switch would be.
@MainActor struct PermissionDetails: View {
  var chips: [TaskPermissions.Chip]
  var run: AgentRun?
  var browser: BrowserModel?
  var agent: AgentModel?
  @Environment(\.palette) var p
  /// The height of a row's first line, so rows with and without a switch align.
  static let line: CGFloat = 18

  /// Redraws when the run's grants change.
  @MainActor struct Live: View {
    var chips: [TaskPermissions.Chip]
    @ObservedObject var run: AgentRun
    var browser: BrowserModel
    var agent: AgentModel?
    var body: some View { PermissionDetails(chips: chips, run: run, browser: browser, agent: agent) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("What this task may touch").font(UIStyle.bodyStrong)
      ForEach(chips) { row($0) }
      Text(footnote).role(.micro).fixedSize(horizontal: false, vertical: true)
    }.padding(16).frame(width: UIStyle.wide(300))
  }

  var footnote: String {
    guard let run else { return "This task has ended." }
    return run.isActive
      ? "Click & type and Mac actions change at once. Sign-ins and project edits change from the next step you send."
      : "This task has ended. A switch sets the next step you send in this thread."
  }

  /// The project the next step works in, for the Project edits sentence.
  var nextProject: String? {
    guard let agent, agent.mode == .project, let id = agent.projectID else { return nil }
    return browser?.projects.first { $0.id == id }?.name
  }

  func row(_ task: TaskPermissions.Chip) -> some View {
    let switchable = browser != nil && (run?.canSwitch(task.kind, agent: agent) ?? false)
    let ended = run.map { !$0.isActive } ?? true
    var chip = task
    var note: String?
    if switchable, let run {
      // The label and sentence follow the switch: the run's access while it works, the next
      // step's access after it ends.
      let value = run.switchValue(task.kind, agent: agent)
      let project = ended ? nextProject : run.spec.grants.projectName
      chip = TaskPermissions.chip(task.kind, on: value, projectName: task.kind == .edits ? project : nil)
      let had = run.ranWith(task.kind)
      if ended && value != had { note = "This task ran with it \(had ? "on" : "off")." }
    } else if ended, let run {
      if task.kind == .edits {
        chip = TaskPermissions.chip(.edits, on: run.ranWith(.edits), projectName: run.spec.grants.projectName)
      }
      if !run.threadIsOpen(agent: agent),
        task.kind == .act || task.kind == .mac || (task.kind == .edits && run.spec.grants.projectName != nil) {
        note = "Open this thread to change it."
      }
    }
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: PermissionChips.icon(chip.kind)).font(.system(size: 11))
        .frame(width: 14, height: Self.line)
        .foregroundStyle(chip.on ? p.ink : p.faint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(chip.label).font(UIStyle.meta).foregroundStyle(chip.on ? p.ink : p.secondary)
          Spacer(minLength: 0)
          if switchable, let run, let browser {
            Toggle("", isOn: Binding(
              get: { run.switchValue(chip.kind, agent: agent) },
              set: { run.setSwitch(chip.kind, $0, browser: browser, agent: agent) }))
              .toggleStyle(SereinSwitchStyle(labeled: false))
              .accessibilityLabel(chip.label)
          } else {
            Text(chip.kind == .pages && chip.on ? "Always on" : chip.on ? "On" : "Off")
              .font(UIStyle.micro).foregroundStyle(chip.on ? p.ink : p.faint)
          }
        }.frame(height: Self.line)
        Text(chip.detail).role(.meta).fixedSize(horizontal: false, vertical: true)
        if let note {
          Text(note).role(.micro).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.accessibilityElement(children: .combine)
  }
}

/// The run's steps on a thin rail: time, label, failures in danger. Each step expands to show
/// its kind and offset from the start, and what the call was given and what came back when this
/// launch saw it (`ToolCallDetail`, the Tool Call Card's open part), with Retry on a failed one;
/// a step in Serein's computer with a picture (StepPictures) opens it full size instead. Long runs
/// show the latest 30 until asked.
struct StepTimeline: View {
  var steps: [AgentStep]
  var startedAt: Date?
  var cap: CGFloat = 168
  /// Retry on a failed call: sends these words as the person's next message to the task.
  var retry: ((String) -> Void)? = nil
  @State private var open = Set<String>()
  @State private var all = false
  /// The step whose picture the sheet shows.
  @State private var pictured: AgentStep?
  @ObservedObject private var pictures = StepPictures.shared
  @ObservedObject private var calls = ToolCallBook.shared
  @Environment(\.palette) var p
  static let clock = AgentStepList.clock
  var body: some View {
    let shown = all ? steps : Array(steps.suffix(30))
    ScrollViewReader { proxy in
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if steps.isEmpty {
          Text("No steps yet.").font(UIStyle.micro).foregroundStyle(p.faint)
        }
        if steps.count > shown.count {
          Button("Show all \(steps.count) steps") { all = true }.buttonStyle(.pressable)
            .font(UIStyle.micro).foregroundStyle(p.secondary).padding(.bottom, 6)
        }
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
          row(step, last: index == shown.count - 1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.frame(height: min(cap, estimatedHeight(shown)))
      .defaultScrollAnchor(.bottom)
      // The newest step stays in view while the run works.
      .onAppear {
        let last = shown.last?.id
        DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) }
      }
      .onChange(of: steps.count) { _, _ in proxy.scrollTo(steps.last?.id, anchor: .bottom) }
    }
    .sheet(item: $pictured) { step in
      StepPictureSheet(step: step, file: pictures.files[step.id], detail: detail(step)) { pictured = nil }
        .environment(\.palette, p)
    }
  }
  func row(_ step: AgentStep, last: Bool) -> some View {
    let expanded = open.contains(step.id)
    let hasPicture = pictures.files[step.id] != nil
    let failure: String = step.failed.map { ", failed: \($0)" } ?? ""
    let hint: LocalizedStringKey = hasPicture ? "Shows the picture of Serein's computer after this step"
      : expanded ? "Hides details" : "Shows details"
    let call: ToolCall? = expanded ? calls.calls[step.id] : nil
    let again: (() -> Void)? = retry.map { send in { send(ToolCalls.retryWords(step.label)) } }
    return VStack(alignment: .leading, spacing: 0) {
    HStack(alignment: .top, spacing: 8) {
      Text(Self.clock.string(from: step.time)).font(UIStyle.microMono).foregroundStyle(p.faint)
        .frame(width: 58, alignment: .leading)
      VStack(spacing: 0) {
        Circle().fill(step.failed != nil ? p.danger : p.borderStrong).frame(width: 7, height: 7)
          .padding(.top, 4)
        if !last { Rectangle().fill(p.line).frame(width: 1).frame(maxHeight: .infinity) }
      }.frame(width: 7)
      VStack(alignment: .leading, spacing: 2) {
        Button {
          if hasPicture { pictured = step } else if expanded { open.remove(step.id) } else { open.insert(step.id) }
        } label: {
          HStack(spacing: 4) {
            Text(verbatim: step.label).font(UIStyle.micro).foregroundStyle(p.ink)
              .lineLimit(expanded ? nil : 1).truncationMode(.middle)
            if hasPicture { InterfaceIcon(systemName: "photo", size: 10).foregroundStyle(p.faint).accessibilityHidden(true) }
          }
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.pressable).help(hasPicture ? "Show the picture of Serein's computer after this step" : "")
        if let failed = step.failed {
          Text(verbatim: failed).font(UIStyle.micro).foregroundStyle(p.danger).lineLimit(expanded ? nil : 1)
        }
        if expanded {
          Text(detail(step)).font(UIStyle.micro).foregroundStyle(p.faint)
        }
      }.padding(.bottom, call == nil ? 8 : 4)
    }.accessibilityElement(children: .combine)
      .accessibilityLabel("\(step.label)\(failure)")
      .accessibilityValue(Self.clock.string(from: step.time))
      .accessibilityHint(hint)
      // Its own element, outside the combined row, so Copy, Show all and Retry each take the keyboard.
      if let call {
        ToolCallDetail(call: call, retry: again).padding(.leading, 81).padding(.bottom, 8)
      }
    }
  }
  /// A fixed height for the scroll area (rows are 22 points, a failure line adds 15, expanded
  /// rows add more), so the header has a definite size and never overlaps what follows.
  func estimatedHeight(_ shown: [AgentStep]) -> CGFloat {
    if steps.isEmpty { return 16 }
    var total: CGFloat = steps.count > shown.count ? 22 : 0
    for step in shown {
      total += 22
      if step.failed != nil { total += 15 }
      // A call's open card can be tall: the area takes its cap and scrolls.
      if open.contains(step.id) { total += calls.calls[step.id] == nil ? 30 : cap }
    }
    return total
  }
  func detail(_ step: AgentStep) -> String {
    let kind = step.tool.replacingOccurrences(of: "_", with: " ")
    guard let startedAt else { return kind }
    return "\(kind) · +\(TaskClock.short(step.time.timeIntervalSince(startedAt)))"
  }
}

// MARK: Composer

/// The panel's reply box: "Reply, or add to the task". While the task runs Return adds the
/// message and Option-Return stops the step and sends now. The eye shows exactly what goes out.
struct PanelComposer: View {
  @State private var dropdownOwner = UUID().uuidString
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject private var context = ComposerContext.shared
  @ObservedObject private var harnessRegistry = HarnessRegistry.shared
  @State private var focused = false
  @State private var askSignIns = false
  @Environment(\.palette) var p
  var hasText: Bool { !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// Keep the send control and the explanation in sync with the exact policy used by Agent.send.
  var sendBlockReason: String? {
    guard !agent.running, agent.mode != .auto else { return nil }
    // Another app's chat goes to that app's own CLI, as typed there; HarnessPolicy governs Serein's runs.
    if agent.repliesInApp { return nil }
    return agent.sendBlockReason
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ContextChips(browser: browser, agent: agent)
      PanelPageOffer(browser: browser, agent: agent)
      CommandComposerInput(placeholder: placeholder, agent: agent, browser: browser, owner: dropdownOwner, focused: $focused,
        label: agent.mode == .page && agent.messages.isEmpty ? "Ask about this page" : "Reply to the task") { option in
          switch ComposerKey.resolve(
            running: agent.running, hasText: hasText,
            shift: false, option: option)
          {
          case .send: sendDraft()
          case .addToStep: agent.flow.addToStep()
          case .interruptAndSend:
            PushToTalk.shared.stopClickToTalk()
            agent.flow.interruptAndSend(agent.draft)
          case .newline, .ignore: break
          }
        }
        .textInputCursor().padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
      // The Ask box's own row: +, the destination chips, model and reasoning, microphone, send.
      ComposerControls(
        browser: browser, agent: agent, owner: dropdownOwner, expanded: true, running: agent.running,
        sendBlockReason: sendBlockReason, askSignIns: $askSignIns, send: sendDraft
      ).padding(.horizontal, 8).padding(.bottom, 8)
      ComposerFlowRows(agent: agent)
      WebTaskGrantChip(agent: agent)
      // Why Send is off, once there is something to send.
      if let sendBlockReason, hasText {
        SendBlockLine(reason: sendBlockReason, agent: agent).padding(.horizontal, 12).padding(.bottom, 8)
      } else if let error = agent.error, !error.hasPrefix("Can't send with ") {
        Text(error).role(.meta).textSelection(.enabled).lineLimit(4).padding(.horizontal, 12).padding(.bottom, 8)
      }
    }.background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.bubbleRadius))
      .composerDrop(agent)
      .background {
        if agent.mode == .page, let tab = browser.active { PageOfferWatcher(browser: browser, agent: agent, tab: tab) }
      }
      .onChange(of: browser.selected) { _, _ in Self.tabChanged(browser: browser, agent: agent) }
      // Ask (toolbar, ⌥⌘E, the page menu) puts the cursor here, ready to type.
      .onChange(of: context.focusComposer) { _, _ in takeFocus() }
      .onAppear { if context.wantsComposerFocus { takeFocus() } }
      .onDisappear { PushToTalk.shared.stopClickToTalk() }
      .sheet(isPresented: $askSignIns) {
        WebTaskGrantSheet(agent: agent) { askSignIns = false }.environment(\.palette, p)
      }
  }
  func sendDraft() {
    if ComposerCommands.shared.submit(agent: agent, browser: browser, owner: dropdownOwner) { return }
    PushToTalk.shared.stopClickToTalk()
    agent.send()
  }
  var placeholder: String {
    agent.mode == .page && agent.messages.isEmpty ? "Ask about this page" : "Reply, or add to the task"
  }
  func takeFocus() {
    context.wantsComposerFocus = false
    DispatchQueue.main.async { focused = true }
  }
}

/// Why Send is off, and the one switch that lets this AI app send when there is one: Grok and
/// Gemini CLI are kept out of Project and Library (`HarnessPolicy.verdict`) but answer in
/// Answer, under the same verdict.
struct SendBlockLine: View {
  let reason: String
  @ObservedObject var agent: AgentModel
  @ObservedObject private var registry = HarnessRegistry.shared
  @Environment(\.palette) var p
  /// Only for an app that can never work in Project or Library (not one of `fileDrivers`).
  private var answers: Bool {
    [TaskMode.project, .library].contains(agent.mode)
      && agent.provider.driver.map(HarnessPolicy.fileDrivers.contains) == false
      && registry.verdict(agent.provider, mode: TaskMode.answer.runKey, edits: false, permission: agent.permission).allowed
  }
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(reason).role(.meta).foregroundStyle(p.warning).fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if answers {
        Spacer(minLength: 0)
        Button("Switch to Answer") {
          agent.autoRouting = false
          agent.mode = .answer
          agent.projectID = nil
        }
        .buttonStyle(QuietButton()).fixedSize()
        .help("Send this as a chat with \(agent.provider.name), without the project's files")
      }
    }
  }
}

/// Displays the harness product mark.
struct HarnessGlyph: View {
  var provider: Provider?
  var size: CGFloat = 13
  var tinted = false
  /// Settings pages show a company's coloured logo where it has one (Claude, Codex, Gemini), and
  /// the other harnesses' marks as app-icon tiles (`HarnessTile`).
  var logo = false
  static let claudeOrange = KeelPicker.claudeOrange
  static func symbol(_ provider: Provider) -> String {
    guard let driver = provider.driver else { return "terminal" }
    return "harness.\(driver.rawValue)"
  }
  /// The coloured logo for a harness whose company has one (Icons/logo-*.svg).
  static func colourBrand(_ provider: Provider) -> Brand? {
    switch provider.driver {
    case .claude?: return .claude
    case .codex?: return .codex
    case .gemini?: return .gemini
    default: return nil
    }
  }
  var body: some View {
    Group {
      if let provider, logo, let brand = Self.colourBrand(provider) {
        BrandLogo(brand, size: size)
      } else if let provider, logo, provider.driver != nil {
        HarnessTile(provider: provider, size: size)
      } else if let provider {
        InterfaceIcon(systemName: Self.symbol(provider), size: size)
          .foregroundStyle(tinted && provider == .claude ? Self.claudeOrange : Color.primary)
      } else {
        Image(systemName: "sparkles").font(.system(size: size, weight: .semibold))
      }
    }.accessibilityHidden(true)
  }
}

/// Displays the harness product mark.
struct HarnessTile: View {
  let provider: Provider
  var size: CGFloat = 22
  @Environment(\.palette) private var p
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
    InterfaceIcon(systemName: HarnessGlyph.symbol(provider), size: size * 0.62)
      .foregroundStyle(Color.white)
      .frame(width: size, height: size)
      .background(Color.black, in: shape)
      .accessibilityHidden(true)
  }
}

/// The leading-edge handle that resizes the panel between `TaskDock.minWidth` and 520 points.
struct PanelResizeHandle: View {
  /// The width it drags; nil drags the task panel's own.
  var width: Binding<CGFloat>? = nil
  var label = "Task panel width"
  /// After a drag or a VoiceOver step; nil saves the task panel's width.
  var onEnd: (() -> Void)? = nil
  /// The widths it allows; nil is the task panel's (also Serein beside's).
  var range: ClosedRange<CGFloat>? = nil
  @ObservedObject private var dock = TaskDock.shared
  @State private var start: CGFloat?
  @State private var hovered = false
  @Environment(\.palette) var p
  init(width: Binding<CGFloat>? = nil, label: String = "Task panel width", range: ClosedRange<CGFloat>? = nil, onEnd: (() -> Void)? = nil) {
    self.width = width
    self.label = label
    self.range = range
    self.onEnd = onEnd
  }
  private var current: CGFloat { width?.wrappedValue ?? dock.width }
  private func set(_ value: CGFloat) {
    let bounds = range ?? TaskDock.minWidth...TaskDock.maxWidth
    let clamped = min(bounds.upperBound, max(bounds.lowerBound, value))
    if let width { width.wrappedValue = clamped } else { dock.width = clamped }
  }
  private func ended() { if let onEnd { onEnd() } else { dock.persist() } }
  var body: some View {
    Rectangle().fill(hovered || start != nil ? p.borderStrong : Color.clear).frame(width: 2)
      .frame(width: 8).contentShape(Rectangle())
      .onHover { inside in
        guard inside != hovered else { return }
        hovered = inside
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .onDisappear {
        if hovered {
          hovered = false
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            let base = start ?? current
            if start == nil { start = base }
            set(base - value.translation.width)
          }
          .onEnded { _ in
            start = nil
            ended()
          }
      )
      .accessibilityElement().accessibilityLabel(label)
      .accessibilityValue("\(Int(current)) points")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: set(current + 20)
        case .decrement: set(current - 20)
        @unknown default: break
        }
        ended()
      }
      .help("Drag to resize")
  }
}
