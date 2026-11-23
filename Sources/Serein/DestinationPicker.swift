import AppKit
import SereinCore
import SwiftUI

/// New Task (⌥⌘N): a searchable list of where a fresh task will work. Arrow keys move,
/// Return chooses, Escape closes.
@MainActor enum DestinationPicker {
  private static var panel: PickerPanel?

  static func show(browser: BrowserModel, agent: AgentModel, newTask: Bool = false) {
    guard !agent.choosingDestination else { ToastCenter.shared.show(AgentModel.choosingWords); return }
    if let panel {
      panel.makeKeyAndOrderFront(nil)
      return
    }
    guard newTask || !agent.running else {
      ToastCenter.shared.show("You can choose another destination when this step ends.")
      return
    }
    let page = browser.active.map { !$0.privateMode && !$0.hiddenFromAgents && $0.owner == nil } ?? false
    let options = DestinationSearch.options(
      // Real projects only, as on the Projects page; chat and temporary folders are not offered.
      projects: browser.listedProjects.map { project in
        (project.id, project.name, browser.projectNotes[project.id]?.purpose ?? project.path)
      }, pageAvailable: page && browser.section == ShellSection.browser)
    let current = currentID(agent)
    let view = DestinationPickerView(options: options, current: current) { choice in
      close()
      if let choice {
        if newTask { beginTask(choice, agent: agent, browser: browser, pageAvailable: page && browser.section == ShellSection.browser) }
        else { apply(choice, agent: agent, pageAvailable: page && browser.section == ShellSection.browser) }
      }
    }
    let p = PickerPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    p.titleVisibility = .hidden
    p.titlebarAppearsTransparent = true
    p.isMovableByWindowBackground = false
    p.isReleasedWhenClosed = false
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
    p.level = .floating
    p.onResign = { close() }
    p.contentViewController = NSHostingController(rootView: view)
    p.setContentSize(NSSize(width: 520, height: 380))
    if let host = NSApp.mainWindow ?? NSApp.keyWindow {
      let frame = host.frame
      p.setFrameOrigin(
        NSPoint(x: frame.midX - 260, y: frame.maxY - 380 - min(160, frame.height * 0.18)))
    } else {
      p.center()
    }
    panel = p
    p.makeKeyAndOrderFront(nil)
    NSAccessibility.post(
      element: p, notification: .announcementRequested,
      userInfo: [.announcement: "Choose a project. \(options.count) destinations."])
  }
  /// An explicit new task preserves every running thread and starts with its own empty draft.
  static func startTask(in project: Project, agent: AgentModel, browser: BrowserModel) {
    let choice = DestinationSearch.options(projects: [(project.id, project.name, project.path)], pageAvailable: false)
      .first { $0.id == project.id }!
    beginTask(choice, agent: agent, browser: browser)
  }
  private static func beginTask(_ choice: DestinationOption, agent: AgentModel, browser: BrowserModel, pageAvailable: Bool = false) {
    guard !agent.choosingDestination else { ToastCenter.shared.show(AgentModel.choosingWords); return }
    agent.clear()
    agent.draft = ""
    apply(choice, agent: agent, pageAvailable: pageAvailable)
    agent.showThreadTab(agent.conversationID)
    agent.saveConversation()
    browser.section = ShellSection.thread
    ComposerContext.shared.wantsComposerFocus = true
    ComposerContext.shared.focusComposer += 1
    ComposerContext.shared.taskOptionsThreadID = agent.conversationID
  }
  static func close() {
    let p = panel
    panel = nil
    p?.onResign = nil
    p?.orderOut(nil)
    p?.close()
  }
  static func currentID(_ agent: AgentModel) -> String? {
    switch agent.mode {
    case .page: return DestinationOption.Kind.page.rawValue
    case .anywhere: return DestinationOption.Kind.anywhere.rawValue
    case .research: return DestinationOption.Kind.research.rawValue
    case .project: return agent.projectID
    default: return nil
    }
  }
  /// Project and Library tasks run only on `HarnessPolicy.fileDrivers`. Another harness gives way
  /// to the one this project's threads used last, else the first of them that is set up, and a
  /// toast says so, before a send could be refused.
  static func fitHarness(_ agent: AgentModel, for place: String) {
    let allowed = Provider.allCases.filter { $0.driver.map(HarnessPolicy.fileDrivers.contains) ?? false }
    let used = agent.listedConversations.first {
      $0.projectID != nil && $0.projectID == agent.projectID && allowed.contains($0.provider)
    }?.provider
    guard let driver = HarnessPolicy.fileHarness(
      current: agent.provider.driver, lastUsed: used?.driver,
      available: Set(allowed.filter { agent.available[$0] != nil }.compactMap(\.driver)))
    else { return }
    let next = Provider(driver)
    let before = agent.provider.name
    let models = HarnessRegistry.shared.models(next)
    if let model = models.first(where: \.isDefault) ?? models.first {
      agent.choose(next, model)
    } else {
      agent.provider = next
      agent.model = ""
    }
    ToastCenter.shared.show("\(before) cannot work in \(place), so this task uses \(next.name).")
  }
  /// A project chosen from a page thread keeps that page: the task gets the tab and the folder.
  static func apply(_ choice: DestinationOption, agent: AgentModel, pageAvailable: Bool = false) {
    agent.autoRouting = false
    let keepPage = DestinationSearch.keepsPage(
      choosing: choice.kind, pageAvailable: pageAvailable, hasPage: agent.mode == .page || agent.pageInProject)
    agent.includePage = keepPage
    switch choice.kind {
    case .page:
      agent.mode = .page
      agent.projectID = nil
    case .anywhere:
      agent.mode = .anywhere
      agent.projectID = nil
    case .research:
      agent.mode = .research
      agent.projectID = nil
    case .project:
      agent.projectID = choice.id
      agent.mode = .project
      fitHarness(agent, for: choice.title)
    }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: "Your next message goes to \(choice.title)\(keepPage ? " with this page" : "")."])
  }
}

/// A panel that can take typing and closes when it loses focus.
final class PickerPanel: NSPanel {
  var onResign: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func resignKey() {
    super.resignKey()
    let action = onResign
    DispatchQueue.main.async { action?() }
  }
}

struct DestinationPickerView: View {
  var options: [DestinationOption]
  var current: String?
  var done: (DestinationOption?) -> Void
  @State private var query = ""
  @State private var index = 0
  @FocusState private var focused: Bool
  @Environment(\.palette) var p
  var shown: [DestinationOption] { DestinationSearch.filter(options, query: query) }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        InterfaceIcon(systemName: "magnifyingglass", size: 14).foregroundStyle(p.faint)
        TextField("Choose a project", text: $query).textFieldStyle(.plain).textInputCursor().font(UIStyle.font(14))
          .focused($focused)
          .onKeyPress(.downArrow) {
            index = DestinationSearch.move(index, by: 1, count: shown.count)
            return .handled
          }
          .onKeyPress(.upArrow) {
            index = DestinationSearch.move(index, by: -1, count: shown.count)
            return .handled
          }
          .onKeyPress(.return) {
            if shown.indices.contains(index) { done(shown[index]) }
            return .handled
          }
          .onKeyPress(.escape) {
            done(nil)
            return .handled
          }
          .accessibilityLabel("Search destinations")
        Text("⌘P").font(UIStyle.microMono).foregroundStyle(p.faint).accessibilityHidden(true)
      }.padding(.horizontal, 16).frame(height: 48)
      Rectangle().fill(p.line).frame(height: 1)
      if shown.isEmpty {
        Text(
          options.contains { $0.kind == .project }
            ? "No destination matches." : "No projects yet. Add a folder, or send it Anywhere."
        ).role(.meta).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(Array(shown.enumerated()), id: \.element.id) { i, option in
                row(option, selected: i == index).id(option.id)
                  .onTapGesture { done(option) }
                  .onHover { if $0 { index = i } }
              }
            }.padding(6)
          }.onChange(of: index) { _, i in
            if shown.indices.contains(i) { proxy.scrollTo(shown[i].id) }
          }
        }
      }
    }.frame(width: 520, height: 380).darkGlass(UIStyle.panelRadius)
      .onChange(of: query) { _, _ in index = 0 }
      .onAppear {
        index = options.firstIndex { $0.id == current } ?? 0
        focused = true
      }
  }
  func row(_ option: DestinationOption, selected: Bool) -> some View {
    HStack(spacing: 10) {
      InterfaceIcon(systemName: icon(option.kind), size: 14).foregroundStyle(p.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(option.title).font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1)
        if !option.detail.isEmpty {
          Text(option.detail).role(.meta).lineLimit(1).truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      if option.id == current {
        InterfaceIcon(systemName: "checkmark", size: 12).foregroundStyle(p.secondary)
      }
    }.padding(.horizontal, 10).padding(.vertical, 7)
      .background(selected ? p.selected : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction { done(option) }
  }
  func icon(_ kind: DestinationOption.Kind) -> String {
    switch kind {
    case .page: return "globe"
    case .anywhere: return "macwindow"
    case .research: return "magnifyingglass"
    case .project: return "folder"
    }
  }
}

extension AppDelegate {
  /// Menu items for the workflow additions. Appended after the browser menus.
  func installWorkflowMenus(_ bar: NSMenu) {
    guard let file = bar.items.first(where: { $0.submenu?.title == "File" })?.submenu else { return }
    let item = NSMenuItem(title: "New Task…", action: #selector(newTask), keyEquivalent: "n")
    item.keyEquivalentModifierMask = [.command, .option]
    item.target = self
    file.addItem(item)
  }
  @objc func newTask() {
    guard let browser, let agent else { return }
    DestinationPicker.newTaskHere(browser: browser, agent: agent)
  }
}
