import SereinCore
import SwiftUI

/// The Agents list, the orchestrator: Agents at work (the overview), New task and every task by
/// project scroll; Recents stays under them, folded until opened. In a project a row keeps its place (AgentListOrder):
/// a click, a new message or a change of status moves nothing, and a new task starts at the top of
/// its project. Recents goes newest activity first and holds still while the pointer is over it. A
/// row is quiet grey words with no dot; one at work has moving words, and only one that wants the person gets
/// ink and a coloured word. Serein's handoffs are a job row with its helpers on a tree line, and
/// sessions in the AI apps join their project with their sub-threads a click away.
struct AgentsPanelList: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  var selection: Namespace.ID
  @ObservedObject private var tray = SereinTray.shared
  @ObservedObject private var placement = SereinSurface.main.placement
  @ObservedObject private var outside = ExternalSessionStore.shared
  /// Recent sessions the AI apps keep with no process now, once session discovery is allowed.
  @ObservedObject private var history = SessionHistoryStore.shared
  @ObservedObject private var discovery = SessionDiscoveryModel.shared
  @ObservedObject private var memory = AgentListMemory.shared
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.palette) private var p
  /// Recents repeats rows the projects list, so its selected row has a pill of its own.
  @Namespace private var recentsPill
  @State private var hoveredAction: String?
  @State private var showsHidden = false
  /// The Recents order frozen while the pointer is over it.
  @State private var recentHold: [String]?
  /// How tall Recents' rows are: its scroller is no taller, up to `recentsMaxHeight`.
  @State private var recentsHeight: CGFloat = 0
  /// The sub-thread open in the main container, for its row's selected look.
  @State private var shownSubagent: ShownSubagent?
  @ObservedObject private var focus = SubThreadFocus.shared
  /// A project's rows before Show all.
  static let shown = 5
  /// Recents' rows before Show all.
  static let recentShown = 30
  private static let recentKey = "recent"
  /// Open Recents leaves the projects most of the panel.
  private static let recentsMaxHeight: CGFloat = 300

  var body: some View {
    let relay = SereinSurface.controller?.relay
    let items = SereinTray.items(hub: hub, agent: agent, relay: relay, ledger: tray.ledger, now: Date())
    let atWork = items.filter { $0.live || $0.needsYou }
    let groups = AgentsByProject.groups(agent: agent, hub: hub, relay: relay, ledger: tray.ledger, items: items,
                                        projects: browser.projects, outside: outside.sessions,
                                        subagents: outside.subagents, known: memory.known, pinned: memory.pinned,
                                        history: discovery.consented ? history.history.sessions : [])
    let allEntries = groups.flatMap(\.entries)
    let hiddenCount = allEntries.filter { memory.isHidden($0.keys) && $0.status != .needsYou }.count
    VStack(spacing: 0) {
      SidebarPanelScroll { mainList(groups: groups, atWork: atWork.count, hiddenCount: hiddenCount) }
      // In view however long the projects run.
      if !groups.isEmpty { recents(allEntries).padding(.leading, 4).padding(.top, 6) }
    }
    .onChange(of: rememberedNames(groups), initial: true) { _, rows in memory.remember(rows) }
    .onChange(of: atWorkNames(allEntries), initial: true) { _, names in memory.keep(names) }
    .onReceive(focus.$open) { shownSubagent = $0?.shown }
  }

  // MARK: The lists

  private func mainList(groups: [AgentsByProject.Group], atWork: Int, hiddenCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      actionRow("overview", symbol: "square.grid.2x2", title: "Agents at work",
                trailing: atWork == 0 ? nil : "\(atWork)", selected: browser.section == ShellSection.agents) {
        browser.section = ShellSection.agents
      }
      actionRow("new", symbol: "plus", title: "New task", trailing: "⌥⌘N", selected: false) {
        DestinationPicker.newTaskHere(browser: browser, agent: agent)
      }
      if groups.isEmpty {
        Text("No tasks yet").font(AgentsType.detail).foregroundStyle(p.faint).padding(.horizontal, 10).padding(.top, 12)
      } else {
        projectList(groups)
      }
      if hiddenCount > 0 {
        Button(showsHidden ? "Hide \(hiddenCount) hidden" : "\(hiddenCount) hidden · Show") { showsHidden.toggle() }
          .buttonStyle(.pressable).font(UIStyle.meta).foregroundStyle(p.faint)
          .padding(.horizontal, 10).padding(.top, 8)
      }
    }
  }
  @ViewBuilder private func projectList(_ groups: [AgentsByProject.Group]) -> some View {
    ForEach(groups) { group in
      let listed = group.entries.filter(isListed)
      if !listed.isEmpty {
        let folded = memory.foldedProjects.contains(group.id)
        let open = memory.expandedProjects.contains(group.id)
        projectCaption(group, folded: folded).padding(.top, 10)
        if !folded {
          let rows = open ? listed : AgentListOrder.visible(listed, limit: Self.shown) { entry in
            entry.status.leads || memory.isKept(entry.keys) || isSelected(entry)
          }
          ForEach(rows) { entry in entryRows(entry, pill: selection) }
          if listed.count > rows.count || (open && listed.count > Self.shown) {
            showAll(key: group.id, count: listed.count, open: open)
          }
        }
      }
    }
  }
  private func recents(_ entries: [AgentsByProject.Entry]) -> some View {
    let folded = !memory.recentsOpen
    let working = folded && entries.contains { $0.status == .working }
    return VStack(alignment: .leading, spacing: 2) {
      caption("Recents", folded: folded, working: working) {
        recentHold = nil
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { memory.toggleRecents() }
      }
      .agentListProbe("Recents")
      .accessibilityLabel("Recents")
      .accessibilityValue(folded ? (working ? "Folded, something is working" : "Folded") : "")
      .accessibilityHint(folded ? "Shows your newest tasks" : "Hides your newest tasks")
      if !folded { recentList(entries).transition(.opacity) }
    }
  }
  private func recentList(_ entries: [AgentsByProject.Entry]) -> some View {
    let newest = AgentListOrder.recent(entries.filter(isListed), when: \.activity)
    let ordered = recentHold.map { AgentListOrder.held(newest, hold: $0, keys: \.keys) } ?? newest
    let open = memory.expandedProjects.contains(Self.recentKey)
    let rows = open ? ordered : Array(ordered.prefix(Self.recentShown))
    return ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(rows) { entry in entryRows(entry, place: projectName(entry), pill: recentsPill) }
        if ordered.count > Self.recentShown {
          showAll(key: Self.recentKey, count: ordered.count, open: open)
        }
      }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { recentsHeight = $0 }
    }
      .scrollIndicators(.automatic)
      .frame(height: min(recentsHeight, UIStyle.wide(Self.recentsMaxHeight)))
      .environment(\.agentListProbePrefix, "Recents: ")
      .onHover { inside in recentHold = inside ? newest.flatMap(\.keys) : nil }
      .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: rows.map(\.id))
  }
  @ViewBuilder private func entryRows(_ entry: AgentsByProject.Entry, place: String? = nil, pill: Namespace.ID) -> some View {
    switch entry {
    case .task(let task):
      AgentTaskRow(task: task, place: place, selected: isSelected(task), selection: pill,
                   browser: browser, agent: agent, hub: hub)
      if !task.subagents.isEmpty && memory.showsSubagents(task.keys) { subagentRows(task, pill: pill) }
    case .job(let job):
      AgentJobRow(job: job, place: place, selection: pill, browser: browser)
      if !memory.foldedJobs.contains(job.id) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(job.helpers) { helper in
            AgentTaskRow(task: helper, nested: true, selected: isSelected(helper), selection: pill,
                         browser: browser, agent: agent, hub: hub)
          }
        }.overlay(alignment: .topLeading) { AgentTreeLine(count: job.helpers.count) }
          .padding(.leading, 16)
      }
    }
  }
  private func subagentRows(_ task: AgentsByProject.Task, pill: Namespace.ID) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(task.subagents) { helper in
        AgentSubagentRow(helper: helper, parentTitle: memory.title(task.keys) ?? task.title,
                         showing: shownSubagent?.id == helper.id, selection: pill) { open(helper, of: task) }
      }
    }.overlay(alignment: .topLeading) { AgentTreeLine(count: task.subagents.count) }
      .padding(.leading, 16)
  }

  // MARK: Opening a sub-thread

  /// A sub-thread opens in the main container over its parent's chat: the parent opens, so the
  /// header, model and composer line are the parent's, and the sub-thread's transcript shows.
  private func open(_ helper: ExternalSubagent, of task: AgentsByProject.Task) {
    guard helper.log != nil else {
      focus.close()
      return task.open(agent: agent, memory: memory)
    }
    let shown = ShownSubagent(helper: helper, parentTitle: memory.title(task.keys) ?? task.title,
                              provider: task.provider, parent: task)
    // It shows at once, read from its own file; its parent opens behind it when it can.
    focus.open = SubThreadFocus.Open(shown: shown) { continueSubagent(shown, with: $0) }
    browser.section = ShellSection.thread
    task.open(agent: agent, memory: memory)
  }
  /// The person's message to a sub-thread: a Codex helper's own thread takes it; a Claude Code
  /// helper is reached through its parent session, asked to pass it on (`SubagentFollowUp`). The
  /// chat that takes it opens, and the words are sent once it is in front, else left in its box.
  private func continueSubagent(_ shown: ShownSubagent, with words: String) {
    focus.close()
    let text: String
    let target: SessionLink?
    if let thread = shown.codexThread {
      target = SessionLink(driver: HarnessDriver.codex.rawValue, nativeID: thread)
      text = words
      agent.openLinked(target!)
    } else {
      target = shown.parent.outside.flatMap(SessionOpen.link(for:))
      text = SubagentFollowUp.message(words, to: shown.helper.title, id: shown.helper.id)
      shown.parent.open(agent: agent, memory: memory)
    }
    let parentID = shown.parent.id
    Task { @MainActor in
      @MainActor func inFront() -> Bool {
        if let target { return agent.link?.nativeID == target.nativeID }
        return agent.conversationID == parentID
      }
      for _ in 0..<25 where !inFront() { try? await Task.sleep(for: .milliseconds(200)) }
      if inFront() { agent.send(text) } else { agent.draft = text }
    }
  }
  // MARK: What shows

  private func isListed(_ entry: AgentsByProject.Entry) -> Bool {
    // A row that waits on the person shows even when hidden, or the ask would go unseen.
    !memory.isHidden(entry.keys) || showsHidden || entry.status == .needsYou
  }
  private func projectName(_ entry: AgentsByProject.Entry) -> String? {
    switch entry {
    case .task(let task): return task.projectName
    case .job(let job): return job.helpers.lazy.compactMap(\.projectName).first
    }
  }
  /// The task in view: a direct task's chat, or a task of Serein's shown in its surface.
  private func isSelected(_ task: AgentsByProject.Task) -> Bool {
    if browser.section == ShellSection.thread { return agent.conversationID == task.id }
    if browser.section == ShellSection.serein, case .task(let id) = placement.view { return id == task.id }
    return false
  }
  private func isSelected(_ entry: AgentsByProject.Entry) -> Bool {
    switch entry {
    case .task(let task): return isSelected(task)
    case .job(let job): return job.helpers.contains(where: isSelected)
    }
  }
  private func rememberedNames(_ groups: [AgentsByProject.Group]) -> [[String]] {
    groups.map { [$0.key] } + groups.flatMap { $0.entries.flatMap(\.allKeys) }
  }
  private func atWorkNames(_ entries: [AgentsByProject.Entry]) -> [String] {
    entries.filter { $0.status.leads || isSelected($0) }.flatMap(\.keys)
  }

  // MARK: Parts

  private func showAll(key: String, count: Int, open: Bool) -> some View {
    Button(open ? "Show fewer" : "Show all \(count)") {
      if open { memory.expandedProjects.remove(key) } else { memory.expandedProjects.insert(key) }
    }.buttonStyle(.pressable).font(AgentsType.detail).foregroundStyle(p.secondary).padding(.horizontal, 10).padding(.vertical, 3)
  }
  /// A project's caption, quieter than the tasks under it. A click folds it.
  private func projectCaption(_ group: AgentsByProject.Group, folded: Bool) -> some View {
    caption(group.name, folded: folded) { memory.toggleFolded(group.id) }
      .accessibilityLabel("\(group.name), \(group.entries.count) task\(group.entries.count == 1 ? "" : "s")")
      .accessibilityValue(folded ? "Folded" : group.active ? "Something is working" : "")
      .accessibilityHint(folded ? "Shows its tasks" : "Hides its tasks")
  }
  /// A heading that folds what is under it: its name at 12 in `faint` at 75% (full `faint` with
  /// Increase Contrast) and a small disclosure triangle.
  private func caption(_ name: String, folded: Bool, working: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(verbatim: name).font(AgentsType.caption).lineLimit(1).truncationMode(.tail)
        Image(systemName: folded ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill").font(.system(size: 6))
        Spacer(minLength: 4)
        if working { ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true) }
      }.foregroundStyle(p.faint.opacity(contrast == .increased ? 1 : 0.75))
        .padding(.horizontal, 10).frame(height: UIStyle.wide(24)).contentShape(Rectangle())
    }.buttonStyle(.pressable)
      .accessibilityAddTraits(.isHeader)
  }
  private func actionRow(_ key: String, symbol: String, title: String, trailing: String?, selected: Bool,
                         action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        InterfaceIcon(systemName: symbol, size: 14).frame(width: 16)
        Text(title).font(AgentsType.title)
        Spacer()
        if let trailing { Text(trailing).font(UIStyle.microMono).foregroundStyle(p.faint) }
      }.foregroundStyle(p.ink).padding(.leading, 10).padding(.trailing, 8)
    }.buttonStyle(SidebarRowStyle(selected: selected, hovered: hoveredAction == key, selection: selection))
      .onHover { hoveredAction = $0 ? key : (hoveredAction == key ? nil : hoveredAction) }
      .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
  }
}
