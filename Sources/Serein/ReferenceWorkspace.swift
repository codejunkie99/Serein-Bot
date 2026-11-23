import SereinCore
import SwiftUI

/// Sidebar navigation button style, task composer, and project workspace.
struct WallNavButton: ButtonStyle {
  var active: Bool
  var inset: CGFloat = 8
  func makeBody(configuration: Configuration) -> some View {
    WallNavSurface(
      active: active, pressed: configuration.isPressed, inset: inset, content: configuration.label)
  }
}
private struct WallNavSurface<Content: View>: View {
  var active: Bool
  var pressed: Bool
  var inset: CGFloat
  var content: Content
  @State private var hovered = false
  @Environment(\.palette) var p
  @Environment(\.isEnabled) var enabled
  var body: some View {
    content.padding(.horizontal, inset).padding(.vertical, 6)
      .foregroundStyle(active ? p.ink : p.secondary)
      .background(pressed ? p.selected : active || hovered ? p.hover : Color.clear,
        in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .contentShape(RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .opacity(enabled ? 1 : 0.5).onHover { hovered = $0 }
  }
}
struct TaskComposer: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject private var talk = PushToTalk.shared
  @ObservedObject private var codexCatalog = CodexCatalog.shared
  @ObservedObject private var harnessRegistry = HarnessRegistry.shared
  @State private var inputFocused = false
  @State private var availableWidth: CGFloat = 768
  @State private var askSignIns = false
  @ObservedObject private var context = ComposerContext.shared
  @ObservedObject private var grants = WebTaskGrant.shared
  @ObservedObject private var dropdown = ComposerDropdown.shared
  @State private var dropdownOwner = UUID().uuidString
  @Environment(\.palette) var p
  var placeholder = "What would you like to move forward?"
  var autofocus = false
  var acceptsComposerFocus = false
  /// The floating Ask box (Serein mark, ⌘E): every send is a chat of its own. Follow-ups go
  /// through the thread view or the task panel.
  var startsNewChat = false
  /// The selected thread's run, as this composer treats it. The Ask box sends beside a run.
  var running: Bool { agent.running && !startsNewChat }
  private var taskTab: Bool { browser.section == ShellSection.thread && !startsNewChat }
  var expanded: Bool {
    inputFocused || !agent.draft.isEmpty || availableWidth < 700 || dropdown.open?.owner == dropdownOwner
  }
  var sendBlockReason: String? {
    guard !running, agent.mode != .auto else { return nil }
    // Another app's chat goes to that app's own CLI, as typed there; HarnessPolicy governs Serein's runs.
    if agent.repliesInApp { return nil }
    return agent.sendBlockReason
  }
  var body: some View {
    VStack(spacing: 4) {
      box
      if taskTab { TaskOptionsRow(browser: browser, agent: agent, owner: dropdownOwner).frame(maxWidth: UIStyle.composerWidth) }
    }
  }
  private var box: some View {
    VStack(alignment: .leading, spacing: 0) {
      ContextChips(browser: browser, agent: agent)
      ConsoleErrorsOffer(browser: browser)
      HStack(alignment: .center, spacing: 8) {
        CommandComposerInput(placeholder: placeholder, agent: agent, browser: browser, owner: dropdownOwner, focused: $inputFocused,
          minHeight: expanded ? 56 : 23, maxHeight: 240, lineSpacing: 6) { option in
            switch ComposerKey.resolve(
              running: running,
              hasText: !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              shift: false, option: option)
            {
            case .send: sendDraft()
            case .addToStep: agent.flow.addToStep()
            case .interruptAndSend:
              talk.stopClickToTalk()
              agent.flow.interruptAndSend(agent.draft)
            case .newline, .ignore: break
            }
          }
          .textInputCursor().fixedSize(horizontal: false, vertical: true)
          .padding(.top, expanded ? 16 : 12).padding(.bottom, expanded ? 4 : 12)
          .padding(.leading, 16).padding(.trailing, expanded ? 16 : 0)
        if !expanded { controls.padding(.trailing, 10) }
      }
      if expanded {
        controls.padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 8)
      }
      if !agent.routeChoices.isEmpty {
        HStack {
          ForEach(browser.projects.filter { agent.routeChoices.contains($0.id) }) { project in
            Button(project.name) {
              let draft = agent.draft
              let section = browser.section
              let dock = TaskDock.shared
              let inPanel = acceptsComposerFocus && dock.open && dock.threadID == agent.conversationID && section != ShellSection.thread
              agent.selectProject(project.id)
              if inPanel {
                browser.section = section
                dock.open(thread: agent.conversationID, browser: browser, agent: agent)
              }
              agent.routeChoices = []
              agent.send(draft)
            }.buttonStyle(QuietButton())
          }
        }.padding(12)
      }
      if let sendBlockReason {
        SendBlockLine(reason: sendBlockReason, agent: agent).padding(12)
      } else if let error = agent.error, !error.hasPrefix("Can't send with ") {
        Text(error).role(.meta).textSelection(.enabled).padding(12)
      }
      ComposerFlowRows(agent: agent)
      WebTaskGrantChip(agent: agent)
    }.padding(1).background(p.pill, in: RoundedRectangle(cornerRadius: UIStyle.composerRadius))
      .frame(maxWidth: UIStyle.composerWidth)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
      .task {
        if autofocus || (acceptsComposerFocus && context.wantsComposerFocus) {
          context.wantsComposerFocus = false
          await Task.yield()
          inputFocused = true
        }
      }
      .onChange(of: context.focusComposer) { _, _ in
        guard acceptsComposerFocus else { return }
        context.wantsComposerFocus = false
        DispatchQueue.main.async { inputFocused = true }
      }
      .onDisappear { talk.stopClickToTalk() }
      .composerDrop(agent)
      .sheet(isPresented: $askSignIns) {
        WebTaskGrantSheet(agent: agent) { askSignIns = false }.environment(\.palette, p)
      }
  }
  /// The shared control row (ComposerControls.swift).
  @ViewBuilder var controls: some View {
    if taskTab {
      // Model, effort and permission sit on the line under the box (TaskOptionsRow).
      HStack(spacing: 8) {
        Spacer(minLength: 8)
        ComposerControls(browser: browser, agent: agent, owner: dropdownOwner, expanded: false, running: running,
          showTaskOptions: false, sendBlockReason: sendBlockReason, askSignIns: $askSignIns, send: sendDraft)
      }
    } else {
      ComposerControls(browser: browser, agent: agent, owner: dropdownOwner, expanded: expanded, running: running,
        sendBlockReason: sendBlockReason, askSignIns: $askSignIns, send: sendDraft)
    }
  }
  /// Return and the send button. The Ask box never continues the selected thread or its native
  /// session: a thread with messages, or one still running, is filed and a new one starts.
  func sendDraft() {
    if ComposerCommands.shared.submit(agent: agent, browser: browser, owner: dropdownOwner) { return }
    talk.stopClickToTalk()
    if startsNewChat && (!agent.messages.isEmpty || agent.running) {
      agent.sendAsNewThread()
    } else {
      agent.send()
    }
  }
  /// "Opus · High": a short model family name and the effort.
  var modelShort: String {
    let model = agent.model.lowercased()
    let families = ["opus", "sonnet", "haiku", "codex", "gpt-5", "gpt-4", "o3", "o4"]
    let family = families.first { model.contains($0) }.map { $0.hasPrefix("gpt") ? $0.uppercased() : $0.capitalized }
    let fallback = agent.model.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).first.map {
      String($0.prefix(12)).capitalized
    }
    let name = agent.model.isEmpty ? agent.provider.name : family ?? fallback ?? agent.model
    return "\(name) · \(agent.effort.capitalized)"
  }
}
extension View {
  /// Composer menus draw their own SwiftUI label (no native chevron or flattened image).
  func composerMenu() -> some View {
    menuStyle(.button).buttonStyle(.pressable).menuIndicator(.hidden)
  }
}
