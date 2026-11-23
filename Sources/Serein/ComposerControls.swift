import SereinCore
import SwiftUI

/// The composer's control row, shared by the Ask box (TaskComposer) and the task panel
/// (PanelComposer): `+` for what the agent works on (WorkOnPicker), the destination chips, one
/// model and reasoning button, the microphone, and send or stop. When the row is narrow (the task
/// panel), things give way in this order: New task leaves the row (⌘Return still works) and one
/// action stays on the right, Queue while text waits on a run, else Stop or Send; the model
/// button shows only its mark; then the destination chips' names shorten. Help, labels and
/// values stay. Words typed while a run works go at the next step (Queue, the default) or now
/// (Stop and use now, Option-Return, `RunSteering`); after Stop, with nothing typed, Resume
/// carries the run on.
struct ComposerControls: View {
  enum Fit { case full, compact, narrow }
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  /// The composer's ComposerDropdown owner, so its dropdowns anchor to this row.
  var owner: String
  var expanded: Bool
  /// The selected thread's run, as the composer treats it.
  var running: Bool
  var showTaskOptions = true
  var showSendControls = true
  var sendBlockReason: String?
  /// Whether the thread's newest run was stopped; nil asks the hub. UI previews set it.
  var stopped: Bool? = nil
  @Binding var askSignIns: Bool
  var send: () -> Void
  @ObservedObject private var talk = PushToTalk.shared
  @ObservedObject private var codexCatalog = CodexCatalog.shared
  @ObservedObject private var harnessRegistry = HarnessRegistry.shared
  @ObservedObject private var context = ComposerContext.shared
  @ObservedObject private var grants = WebTaskGrant.shared
  @Environment(\.palette) var p
  var canSendDraft: Bool {
    !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (sendBlockReason == nil || SlashCommands.parse(agent.draft) != nil)
  }
  var body: some View {
    ViewThatFits(in: .horizontal) {
      controlsRow(.full)
      controlsRow(.compact)
      controlsRow(.narrow)
    }
  }
  func controlsRow(_ fit: Fit) -> some View {
    HStack(spacing: 8) {
      if showTaskOptions {
      DropdownPill(kind: .workOn, owner: owner, help: "Choose what the agent works on") {
        InterfaceIcon(systemName: "plus", size: 16)
      }.disabled(agent.running).accessibilityLabel("What the agent works on")
      destinationChips(fit)
      if expanded { Spacer(minLength: 8) }
      DropdownPill(kind: .modelAndTraits, owner: owner, help: "Model and reasoning: \(modelAndEffort)\(signedIn ? "" : " · not signed in")") {
        HarnessGlyph(provider: agent.provider, size: 16, tinted: true)
        if fit == .full {
          Text(([modelName] + effortSummary).joined(separator: " · ")).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200)
        }
        // Only a harness that is not signed in gets a mark.
        if !signedIn { Circle().fill(p.warning).frame(width: 5, height: 5) }
      }.accessibilityLabel("Model and reasoning").accessibilityValue(modelAndEffort)
      }
      if showSendControls {
      Button {
        talk.toggleClickToTalk { text in
          let current = agent.draft.trimmingCharacters(in: .whitespacesAndNewlines)
          agent.draft = current.isEmpty ? text : current + " " + text
        }
      } label: {
        InterfaceIcon(systemName: talk.clickListening ? "stop.circle" : "mic", size: 15)
      }.buttonStyle(QuietButton()).help(talk.clickListening ? "Click to finish" : "Click to talk")
        .disabled(talk.clickWorking)
        .accessibilityLabel(talk.clickListening ? "Stop talking" : "Start talking")
        .contextMenu {
          Button("Proofread dictated text") { agent.proofreadDraft() }
            .disabled(agent.draft.isEmpty || agent.running)
        }
      if running && typed && fit == .full {
        Button(action: newTask) {
          Text("New task").font(UIStyle.meta).lineLimit(1).fixedSize()
        }.buttonStyle(QuietButton()).keyboardShortcut(.return, modifiers: .command)
          .help("Send as a new task while this one keeps running · ⌘Return")
        Button {
          if !ComposerCommands.shared.submit(agent: agent, browser: browser, owner: owner) { agent.flow.addToStep() }
        } label: {
          Text("Send").font(UIStyle.meta).lineLimit(1).fixedSize()
        }.buttonStyle(QuietButton())
          .help("Send to \(agent.provider.name) · Return")
        Button { agent.flow.interruptAndSend(agent.draft) } label: {
          Text(verbatim: RunSteering.useNow(several: false)).font(UIStyle.meta).lineLimit(1).fixedSize()
        }.buttonStyle(QuietButton())
          .help("Stop this step and send now. Work already done is kept. · Option-Return")
      }
      if running && typed && fit != .full {
        // The one action on the right. Stop stays in the task's header and on Option-Return.
        Button {
          if !ComposerCommands.shared.submit(agent: agent, browser: browser, owner: owner) { agent.flow.addToStep() }
        } label: {
          HStack(spacing: 5) {
            Text("Send").lineLimit(1).fixedSize()
            InterfaceIcon(systemName: "arrow.turn.down.left", size: 11)
          }.font(UIStyle.metaStrong).foregroundStyle(p.onSolid).padding(.horizontal, 10).frame(height: 28)
            .background(p.solid, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.pressable)
          .help("Send to \(agent.provider.name) · Return. Option-Return stops this step and uses it now. ⌘Return sends it as a new task.")
          .accessibilityLabel("Send reply")
      } else if running {
        Button { agent.cancel() } label: {
          InterfaceIcon(systemName: "stop.fill", size: 11)
            .foregroundStyle(p.onSolid).frame(width: 28, height: 28).background(p.solid, in: Circle())
        }.buttonStyle(.pressable).help("Stop task").accessibilityLabel("Stop task")
      } else {
        if offersResume {
          Button { agent.send(RunSteering.resumeWords) } label: {
            Text(verbatim: RunSteering.resume).font(UIStyle.meta).lineLimit(1).fixedSize()
          }.buttonStyle(QuietButton())
            .help("Carry on from where it stopped, keeping the work already done")
            .accessibilityLabel("Resume the stopped task")
        }
        Button(action: send) {
          InterfaceIcon(systemName: "arrow.up", size: 15)
            .foregroundStyle(canSendDraft ? p.onSolid : p.faint).frame(width: 28, height: 28)
            .background(canSendDraft ? p.solid : p.track, in: Circle())
        }.buttonStyle(.pressable).disabled(!canSendDraft)
          .opacity(agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
          .keyboardShortcut(.return, modifiers: .command).help(sendBlockReason ?? "Send · ⌘Return")
          .accessibilityLabel("Send task")
          .accessibilityHint(sendBlockReason ?? "")
      }
      }
    }.foregroundStyle(p.secondary).frame(height: 32)
      .background {
        // ⌘Return sends as a new task while one runs, also when New task has no room in the row.
        if running && typed && fit != .full {
          Button("", action: newTask).keyboardShortcut(.return, modifiers: .command).hidden()
        }
      }
  }
  var typed: Bool { !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// This thread's newest run was stopped, nothing runs, and nothing is typed.
  var offersResume: Bool {
    let stopped: Bool = self.stopped ?? (agent.hub.latest(for: agent.conversationID)?.record.outcome == .stopped)
    return RunSteering.offersResume(stopped: stopped, running: running, typed: typed)
  }
  func newTask() {
    if ComposerCommands.shared.submit(agent: agent, browser: browser, owner: owner) { return }
    talk.stopClickToTalk()
    agent.sendAsNewThread()
  }
  var signedIn: Bool { agent.available[agent.provider] != nil }
  /// The chips for the chosen destination. Each one's menu holds only what applies to it.
  @ViewBuilder func destinationChips(_ fit: Fit) -> some View {
    switch agent.mode {
    case .auto:
      if fit == .full {
        Text(FeaturePolicy.isEnabled(.routing) ? "Serein picks where to work" : "Choose where it works with +")
          .font(UIStyle.meta).foregroundStyle(p.faint).lineLimit(1)
      }
    case .answer:
      chip("bubble.left", "Answer", fit: fit) {
        macToggle
        removeItem
      }
    case .page:
      pageChip(fit)
    case .project:
      projectChip(fit)
      if agent.includePage { pageChip(fit) }
    case .library:
      chip("clock", "History and saved pages", fit: fit) {
        Text("Reads a private copy of your history, day notes and saved pages.")
        Divider()
        removeItem
      }
    case .anywhere:
      chip("laptopcomputer", "This Mac", fit: fit) {
        Text("Calendar, Reminders, Notes and Finder, and other apps one approved step at a time.")
        Divider()
        removeItem
      }
    case .research:
      let signIns = grants.isGranted(thread: agent.conversationID)
      chip("globe", "The web", note: signIns ? "can sign in" : nil, fit: fit) {
        actionsToggle("Click and type on websites")
        macToggle
        Button(signIns ? "You can sign in during the next task" : "Allow signing in for this task…") {
          askSignIns = true
        }.disabled(signIns)
        Divider()
        removeItem
      }
    }
  }
  /// Regular tabs other than this one that a page task may also read.
  var otherTabs: [BrowserTab] {
    browser.tabs.filter { $0.id != browser.active?.id && !$0.privateMode && !$0.hiddenFromAgents && $0.owner == nil }
  }
  func pageChip(_ fit: Fit) -> some View {
    let host = browser.active.flatMap { URL(string: $0.address)?.host } ?? "This page"
    return chip("doc.text", host, note: agent.allowActions ? "can click" : "read only", fit: fit) {
      actionsToggle("Click and type on this page")
      macToggle
      if agent.mode == .page {
        Menu("Other tabs") {
          if otherTabs.isEmpty { Text("No other tabs open") }
          ForEach(otherTabs) { other in
            Toggle(other.title.isEmpty ? other.address : other.title, isOn: Binding(
              get: { context.tabs.contains { $0.id == other.id } },
              set: { _ in context.toggleTab(other, browser: browser) }))
          }
          Divider()
          Text("Up to \(PageContext.maxTabs) pages, this one included")
        }
      }
      Divider()
      Button("Remove") { WorkOnPicker.choose(.page, agent: agent) }
    }
  }
  func projectChip(_ fit: Fit) -> some View {
    let name = browser.projects.first { $0.id == agent.projectID }?.name ?? "Project"
    let access = ProjectAccess(edits: agent.allowProjectEdits, permission: agent.permission)
    return chip("folder", name, note: access.note, fit: fit) {
      Picker("This task asks before", selection: accessBinding) {
        ForEach(ProjectAccess.allCases) { Text($0.title).tag($0) }
      }.pickerStyle(.inline)
      macToggle
      Divider()
      Button("Choose another project… · ⌘P") { DestinationPicker.show(browser: browser, agent: agent) }
      removeItem
    }
  }
  /// One destination chip: a menu labelled with the destination and its current setting.
  func chip<Items: View>(
    _ icon: String, _ title: String, note: String? = nil, fit: Fit, @ViewBuilder items: () -> Items
  ) -> some View {
    Menu { items() } label: {
      HStack(spacing: 5) {
        InterfaceIcon(systemName: icon, size: 12).foregroundStyle(p.secondary)
        Text(title).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
        if let note, fit == .full { Text(note).foregroundStyle(p.secondary).lineLimit(1) }
      }.font(UIStyle.meta).padding(.horizontal, 9).frame(height: 26).frame(maxWidth: fit == .full ? 240 : 160)
        .background(p.raised, in: Capsule()).contentShape(Capsule())
    }.composerMenu()
      // Narrow: the name shortens before anything else gives way.
      .fixedSize(horizontal: fit != .narrow, vertical: true).layoutPriority(fit == .narrow ? -1 : 0)
      .disabled(agent.running)
      .help(note.map { "\(title) · \($0)" } ?? title)
      .accessibilityLabel(title).accessibilityValue(note ?? "")
  }
  var removeItem: some View { Button("Remove") { WorkOnPicker.clear(agent) } }
  func actionsToggle(_ title: String) -> some View {
    Toggle(title, isOn: Binding(
      get: { agent.allowActions },
      set: {
        agent.allowActions = $0
        AgentModel.remember(.actions, $0)
      }))
  }
  /// This Mac always has Mac actions, and so does every destination once Accessibility is on; until
  /// then the other destinations get them only with this switch.
  @ViewBuilder var macToggle: some View {
    if !MacControl.accessibilityGranted(prompt: false) {
      macSwitch
    }
  }
  private var macSwitch: some View {
    Toggle("Allow Mac actions", isOn: Binding(
      get: { agent.allowMacActions },
      set: {
        agent.allowMacActions = $0
        AgentModel.remember(.mac, $0)
      }))
      .help("Lets the agent operate Mac apps one approved step at a time.")
  }
  /// The project chip's one choice; Full access asks once per project, as before.
  var accessBinding: Binding<ProjectAccess> {
    Binding(
      get: { ProjectAccess(edits: agent.allowProjectEdits, permission: agent.permission) },
      set: { level in
        if level == .full {
          guard FullAccessConsent.request(projectID: agent.projectID, projectName: nil) else { return }
        }
        agent.allowProjectEdits = level.edits
        AgentModel.remember(.edits, level.edits)
        agent.permission = level.permission
      })
  }
  /// The chosen model's display name, or the harness when it uses its default.
  var modelName: String {
    let id = ClaudeModelID.split(agent.model)
    if let choice = HarnessRegistry.shared.models(agent.provider).first(where: { $0.id == id.base }),
      !choice.name.isEmpty
    {
      return choice.name + (id.longContext ? " 1M" : "")
    }
    return agent.model.isEmpty ? agent.provider.name : agent.model
  }
  /// "Medium", "Plan": the effort when the model has levels, and the plan-first state when it is on.
  var effortSummary: [String] {
    [EffortLadder.shown(agent), context.planMode ? "Plan" : nil].compactMap { $0 }
  }
  var modelAndEffort: String {
    [agent.model.isEmpty ? agent.provider.name : agent.model, EffortLadder.shown(agent)].compactMap { $0 }
      .joined(separator: " · ")
  }
}
