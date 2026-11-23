import AppKit
import SereinCore
import SwiftUI

// The composer's "+" list (board 17, NbQuick): one in-window list under the message bar (above it
// when the bar sits at the foot of the chat) of what the person can add to a message or go to:
// Attach a file, Teach a skill, the assistants, recent chats, apps, plugins and Add an app…. "+"
// opens it, and so does "@" at the start of an empty draft, whose word filters it. ↑ ↓ move,
// Return picks, Esc closes. The rows come from what is in memory when it opens; the order and
// the filter are SereinCore's `AddListRules`. Picking an app or a plugin only adds words to the
// draft: it grants nothing. Connect goes through the existing sign-in.

/// The list's state: open or not (through `ComposerDropdown`, kind `.addList`), its rows, the
/// filter and the highlighted row. One for the window's Serein composer.
@MainActor final class ComposerAddList: ObservableObject {
  static let shared = ComposerAddList()
  /// The list's place in `ComposerDropdown`: on Serein's composer (the @ list's owner too). A
  /// constant outside the main actor, so the bar's anchor can name it.
  nonisolated static let target = ComposerDropdown.Target(kind: .addList, owner: "serein")

  @Published private(set) var groups: [AddListGroup] = []
  /// The word after a leading "@", or "" when "+" opened the list.
  @Published private(set) var query = ""
  @Published var highlighted = 0
  /// "@" at the start of the draft opened the list: its word is the filter, and a pick takes it out.
  private(set) var byAt = false
  private var all: [AddListRow] = []
  /// The draft Esc closed the list on: it stays closed until the draft changes.
  private var dismissed: String?
  private var monitor: Any?
  private weak var relay: RelayOrchestrator?
  private var teach: (() -> Void)?
  private var addApp: (() -> Void)?

  var isOpen: Bool { ComposerDropdown.shared.open == Self.target }
  /// The rows that show, in the order ↑ ↓ move through them.
  var rows: [AddListRow] { AddListRules.flat(groups) }

  /// "@" and one word at the start of the draft, outside a team chat (where "@" stays the Send to
  /// list's, to ask one assistant).
  static func atWord(_ draft: String, relay: RelayOrchestrator) -> String? {
    guard relay.activeTeam == nil else { return nil }
    return AddListRules.atQuery(draft)
  }

  /// "+": opens the list with every row, or closes it.
  func toggle(relay: RelayOrchestrator, teach: @escaping () -> Void, addApp: @escaping () -> Void) {
    if isOpen {
      close()
      return
    }
    remember(relay: relay, teach: teach, addApp: addApp)
    byAt = false
    open(query: "")
  }

  /// The draft changed: "@" and one word at its start open the list and filter it; any other
  /// change closes it, so Return after typing a message sends it rather than picking a row.
  func draftChanged(_ draft: String, relay: RelayOrchestrator, teach: @escaping () -> Void, addApp: @escaping () -> Void) {
    guard let word = Self.atWord(draft, relay: relay) else {
      dismissed = nil
      if byAt || isOpen { close() }
      return
    }
    guard draft != dismissed else { return }
    dismissed = nil
    remember(relay: relay, teach: teach, addApp: addApp)
    if isOpen && byAt {
      refilter(word)
    } else {
      byAt = true
      open(query: word)
    }
  }

  /// Closes the list. `dismiss` (Esc, a click outside): a list "@" opened stays closed for this draft.
  func close(dismiss: Bool = false) {
    if dismiss, byAt { dismissed = SereinSurface.main.draft }
    if isOpen { ComposerDropdown.shared.close() }
    byAt = false
    stopMonitor()
  }

  /// The face of an assistant row.
  func profile(_ id: String) -> RelayProfile? { relay?.team.profiles.first { $0.id == id } }

  private func remember(relay: RelayOrchestrator, teach: @escaping () -> Void, addApp: @escaping () -> Void) {
    self.relay = relay
    self.teach = teach
    self.addApp = addApp
  }
  private func open(query word: String) {
    guard let relay else { return }
    all = ComposerAddRows.build(relay: relay, hub: relay.agent.hub)
    query = word
    groups = AddListRules.groups(all, query: word)
    highlighted = 0
    ComposerDropdown.shared.open = Self.target
    startMonitor()
  }
  private func refilter(_ word: String) {
    if query != word { highlighted = 0 }
    query = word
    groups = AddListRules.groups(all, query: word)
    highlighted = min(highlighted, max(0, rows.count - 1))
  }

  // MARK: picking

  /// What a row does. Every pick closes the list; the "@word" that opened it leaves the draft,
  /// and any other words stay in the bar.
  func choose(_ index: Int? = nil) {
    let list: [AddListRow] = rows
    let at: Int = index ?? highlighted
    guard list.indices.contains(at), let relay else { return }
    let row: AddListRow = list[at]
    let surface = SereinSurface.main
    let teach = self.teach
    let addApp = self.addApp
    close()
    switch row.kind {
    case .attach:
      surface.draft = AddListRules.clearing(surface.draft)
      surface.chooseDocuments()
    case .teach:
      surface.draft = AddListRules.clearing(surface.draft)
      teach?()
    case .assistant(let id):
      // Its chat opens with the draft still in the bar (the draft is the surface's, not the chat's).
      surface.draft = AddListRules.clearing(surface.draft)
      relay.openAssistant(id)
    case .chat(let id):
      surface.draft = AddListRules.clearing(surface.draft)
      SereinRouter.open(threadID: id)
    case .app(let slug, let connected):
      if connected {
        surface.draft = AddListRules.adding(AddListRules.withWords(row.title), to: surface.draft)
        surface.requestFocus()
      } else {
        surface.draft = AddListRules.clearing(surface.draft)
        Self.connect(slug, name: row.title, addApp: addApp)
      }
    case .plugin:
      surface.draft = AddListRules.adding(AddListRules.withWords(row.title), to: surface.draft)
      surface.requestFocus()
    case .addApp:
      surface.draft = AddListRules.clearing(surface.draft)
      addApp?()
    }
  }

  /// Connect on an app that is not connected: with a Composio key kept, the same sign-in as
  /// Settings › Connections' chips and the connect card (Composio's page in the person's own
  /// browser, never an agent tab); without one, Settings › Connections, where the key is asked.
  /// The list never holds a key field.
  private static func connect(_ slug: String, name: String, addApp: (() -> Void)?) {
    let apps = ComposioApps.shared
    guard ComposioApps.available, apps.waitingFor == nil else {
      addApp?()
      return
    }
    ToastCenter.shared.show("The sign-in page for \(name) opens in your browser.")
    Task { @MainActor in
      do {
        try await apps.connect(app: slug)
      } catch {
        ToastCenter.shared.show(error.localizedDescription)
      }
    }
  }

  // MARK: keys

  private func startMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let swallow = MainActor.assumeIsolated { self?.key(event) ?? false }
      return swallow ? nil : event
    }
  }
  private func stopMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
  /// ↑ ↓ move and wrap, Return picks, Esc closes (a list "@" opened stays closed for this draft).
  /// Keys in the ⌥Space bar and keys with ⌘, ⌃ or ⌥ go on as they are.
  private func key(_ event: NSEvent) -> Bool {
    guard isOpen else {
      // Another dropdown took the place: the keys are left alone from now on.
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.isOpen else { return }
        self.byAt = false
        self.stopMonitor()
      }
      return false
    }
    guard !(event.window is RelayWindow),
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    switch event.keyCode {
    case 53:
      close(dismiss: true)
      return true
    case 125, 126:
      let count: Int = rows.count
      guard count > 0 else { return true }
      highlighted = AddListRules.moving(highlighted, by: event.keyCode == 125 ? 1 : -1, count: count)
      return true
    case 36, 76:
      // Nothing to pick: the list closes and Return does what it always does.
      guard !rows.isEmpty else {
        close(dismiss: true)
        return false
      }
      choose()
      return true
    default:
      return false
    }
  }
}

/// The rows, built once when the list opens, from what is in memory: the team (`relay.team`,
/// hidden rows from `AssistantRowState`), the chats (each assistant's Main chat and the active
/// assistant's Past chats, `relay.pastChats`), the connected accounts (`ComposioApps`) and the
/// suggested apps (`ConnectedApps.suggested`), and the installed plugins (`PluginHost`).
@MainActor enum ComposerAddRows {
  static func build(relay: RelayOrchestrator, hub: AgentHub) -> [AddListRow] {
    let running: [RunningChat] = RunningChats.all(relay: relay, hub: hub)
    let busy: Set<String> = Set(running.filter { $0.state == .working }.map(\.assistantID))
    let waiting: Set<String> = Set(running.filter { $0.state == .needsYou }.map(\.assistantID))
    let live: Set<String> = Set(running.compactMap { $0.state == .working ? $0.chatID : nil })
    var rows: [AddListRow] = [
      AddListRow(kind: .attach, title: "Attach a file", detail: "PDFs, documents and spreadsheets"),
      AddListRow(kind: .teach, title: "Teach a skill", detail: "Show Serein how once"),
    ]
    rows.append(contentsOf: assistants(relay, busy: busy, waiting: waiting))
    rows.append(contentsOf: chats(relay, hub: hub, live: live))
    rows.append(contentsOf: apps())
    rows.append(contentsOf: plugins())
    rows.append(AddListRow(kind: .addApp, title: "Add an app…", detail: "Connect another app"))
    return rows
  }

  /// Every assistant with its job; a hidden one only while it works or needs the person. The
  /// green "Now" marks one that works.
  private static func assistants(_ relay: RelayOrchestrator, busy: Set<String>, waiting: Set<String>) -> [AddListRow] {
    let hidden: Set<String> = AssistantRowState.shared.hidden
    let main: String? = relay.team.main?.id
    var rows: [AddListRow] = []
    for profile in relay.team.profiles {
      let works: Bool = busy.contains(profile.id)
      let pressing: Bool = works || waiting.contains(profile.id)
      guard AddListRules.listsAssistant(hidden: hidden.contains(profile.id), busy: pressing) else { continue }
      rows.append(AddListRow(kind: .assistant(profile.id), title: profile.name, detail: job(profile, main: main), now: works))
    }
    return rows
  }
  private static func job(_ profile: RelayProfile, main: String?) -> String {
    if profile.id == main { return "Your chief of staff" }
    if let job = AssistantRoster.job(of: profile), let line = AddListRules.oneLine(job, limit: 120) { return line }
    if let label = profile.label, let line = AddListRules.oneLine(label, limit: 120) { return line }
    return "No job yet"
  }

  /// Recent chats across assistants: each one's Main chat with something in it (or a turn running
  /// in it) and the active assistant's Past chats; at most six, newest first, never a hidden ask
  /// chat or the chat on screen (`AddListRules.recentChats`).
  private static func chats(_ relay: RelayOrchestrator, hub: AgentHub, live: Set<String>) -> [AddListRow] {
    var entries: [AddListChat] = []
    for profile in relay.team.profiles {
      guard let thread = relay.knownMainThread(of: profile.id) else { continue }
      if let entry = mainChat(thread, owner: profile.name, relay: relay, hub: hub, live: live) { entries.append(entry) }
    }
    let activeName: String = relay.team.activeName
    for saved in relay.pastChats.prefix(AddListRules.maxChats) {
      let title: String = AddListRules.oneLine(ProjectChatIndex.title(saved), limit: 80) ?? "Chat"
      entries.append(AddListChat(id: saved.id, title: title, ownerName: activeName, date: saved.lastMessageAt ?? saved.updatedAt,
                                 running: live.contains(saved.id)))
    }
    let recent: [AddListChat] = AddListRules.recentChats(entries, hidden: relay.desk.hiddenThreads, current: relay.threadID)
    let now = Date()
    let calendar = Calendar.current
    return recent.map { (chat: AddListChat) -> AddListRow in
      let when: AddListRules.When = AddListRules.when(chat.date, now: now, calendar: calendar)
      let time: String = chat.date.formatted(date: .omitted, time: .shortened)
      let day: String = chat.date.formatted(.dateTime.month(.abbreviated).day())
      let detail: String = AddListRules.chatDetail(owner: chat.ownerName, running: chat.running, when: when, time: time, day: day)
      return AddListRow(kind: .chat(chat.id), title: chat.title, detail: detail, now: chat.running)
    }
  }
  private static func mainChat(
    _ thread: String, owner: String, relay: RelayOrchestrator, hub: AgentHub, live: Set<String>
  ) -> AddListChat? {
    let running: Bool = live.contains(thread)
    if let saved = relay.agent.conversations.first(where: { $0.id == thread }), !saved.messages.isEmpty {
      let title: String = AddListRules.oneLine(ProjectChatIndex.title(saved), limit: 80) ?? "Chat"
      return AddListChat(id: thread, title: title, ownerName: owner, date: saved.lastMessageAt ?? saved.updatedAt, running: running)
    }
    guard running, let run = hub.run(for: thread) else { return nil }
    let title: String = AddListRules.oneLine(run.record.title, limit: 80) ?? "Chat"
    return AddListChat(id: thread, title: title, ownerName: owner, date: run.record.startedAt, running: true)
  }

  /// Connected apps first ("Connected"), then the suggested apps that are not ("Not connected",
  /// with Connect).
  private static func apps() -> [AddListRow] {
    var seen = Set<String>()
    var rows: [AddListRow] = []
    for account in ComposioApps.shared.accounts where account.active {
      guard seen.insert(account.app).inserted else { continue }
      rows.append(AddListRow(kind: .app(account.app, connected: true), title: ConnectedApps.name(account.app), detail: "Connected"))
    }
    for app in ConnectedApps.suggested where !seen.contains(app.slug) {
      rows.append(AddListRow(kind: .app(app.slug, connected: false), title: app.name, detail: "Not connected"))
    }
    return rows
  }

  /// Installed plugins that are on (not a server connected by address, not a saved skill). Their
  /// names and descriptions are the plugin's own text: shown as data, one line each.
  private static func plugins() -> [AddListRow] {
    let host = PluginHost.shared
    var rows: [AddListRow] = []
    for package in host.packages {
      guard !host.isConnection(package), host.isEnabled(package), host.states[package.id]?.saved != true else { continue }
      let name: String = AddListRules.oneLine(package.name, limit: AddListRules.nameLimit) ?? package.id
      let about: String = package.manifest?.description ?? package.skills.first?.description ?? ""
      let detail: String = AddListRules.oneLine(about, limit: 120) ?? "Installed"
      rows.append(AddListRow(kind: .plugin(package.id), title: name, detail: detail))
    }
    return rows
  }
}

/// "+" in the message bar. In the window it opens the list (and "@" at the start of an empty
/// draft does too); the floating preview panel keeps the short native menu.
struct ComposerAddButton: View {
  @ObservedObject var relay: RelayOrchestrator
  let docked: Bool
  /// Teach a skill: the skill sheet with an empty draft.
  let teach: () -> Void
  /// Add an app…: Settings › Connections.
  let addApp: () -> Void
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var dropdown = ComposerDropdown.shared
  @Environment(\.palette) private var p

  init(relay: RelayOrchestrator, docked: Bool, teach: @escaping () -> Void, addApp: @escaping () -> Void) {
    self.relay = relay
    self.docked = docked
    self.teach = teach
    self.addApp = addApp
  }

  var body: some View {
    if docked { listButton } else { nativeMenu }
  }

  private var open: Bool { dropdown.open == ComposerAddList.target }

  private var listButton: some View {
    let list = ComposerAddList.shared
    return Button {
      list.toggle(relay: relay, teach: teach, addApp: addApp)
    } label: {
      InterfaceIcon(systemName: "plus", size: 16).foregroundStyle(open ? p.ink : p.secondary)
        .frame(width: 28, height: 28)
    }
    .buttonStyle(GlyphButtonStyle())
    .help("Add a file, an app, or go to a chat")
    .accessibilityLabel("Add")
    .accessibilityHint("Opens a list of things to add or go to")
    .accessibilityValue(open ? "Open" : "")
    .onChange(of: surface.draft) { _, draft in
      list.draftChanged(draft, relay: relay, teach: teach, addApp: addApp)
    }
    .onDisappear { list.close() }
  }

  private var nativeMenu: some View {
    Menu {
      Button("Attach a File…") { surface.chooseDocuments() }
      Button("Add an App…", action: addApp)
    } label: {
      InterfaceIcon(systemName: "plus", size: 16).foregroundStyle(p.secondary)
        .frame(width: 28, height: 28).hoverWash(in: Circle())
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help("Attach a file or add an app")
    .accessibilityLabel("Add")
  }
}

extension View {
  /// The message bar's bounds, which the "+" list takes its width and place from (in the window
  /// only). It adds to what the bar's own parts publish (the @ list's field, the model pill).
  func composerAddListAnchor(_ on: Bool) -> some View {
    transformAnchorPreference(key: ComposerDropdownAnchorKey.self, value: .bounds) {
      (value: inout [ComposerDropdown.Target: Anchor<CGRect>], anchor: Anchor<CGRect>) in
      if on { value[ComposerAddList.target] = anchor }
    }
  }
}

/// The list itself, drawn by `ComposerDropdownLayer` on the `raised` plane: rows 40 high (an icon
/// or a face at 22, the title in `body`, one line in `meta` `secondary`, the green "Now", or
/// Connect in `accent`), headings in `meta` `secondary`, scrolling past 420 points.
struct ComposerAddListView: View {
  @ObservedObject private var list = ComposerAddList.shared
  @Environment(\.palette) private var p

  static let rowHeight: CGFloat = 40
  static let headingHeight: CGFloat = 30
  static let inset: CGFloat = 6
  static let maxHeight: CGFloat = 420
  static let rowRadius: CGFloat = 10

  init() {}

  /// Its height for these rows: at most 420 points, then it scrolls.
  static func height(_ groups: [AddListGroup]) -> CGFloat {
    let rows: Int = groups.reduce(0) { $0 + $1.rows.count }
    let headings: Int = groups.filter { $0.section.heading != nil }.count
    let rowsHeight: CGFloat = CGFloat(max(1, rows)) * UIStyle.wide(rowHeight)
    let headingsHeight: CGFloat = CGFloat(headings) * UIStyle.wide(headingHeight)
    return min(maxHeight, rowsHeight + headingsHeight + inset * 2)
  }

  var body: some View {
    let groups: [AddListGroup] = list.groups
    let flat: [AddListRow] = AddListRules.flat(groups)
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if flat.isEmpty { nothing }
          ForEach(groups, id: \.section) { group in
            section(group, flat: flat)
          }
        }
        .padding(Self.inset)
      }
      .onChange(of: list.highlighted) { _, index in
        if flat.indices.contains(index) { proxy.scrollTo(flat[index].id) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Add to this message")
  }

  @ViewBuilder private func section(_ group: AddListGroup, flat: [AddListRow]) -> some View {
    if let heading = group.section.heading {
      Text(verbatim: heading).font(AssistantType.meta).foregroundStyle(p.secondary)
        .padding(.horizontal, 10).padding(.bottom, 4)
        .frame(height: UIStyle.wide(Self.headingHeight), alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
    ForEach(group.rows) { row in
      let index: Int = flat.firstIndex(where: { $0.id == row.id }) ?? 0
      AddListRowView(row: row, lit: index == list.highlighted, profile: profile(row)) { list.choose(index) }
        .id(row.id)
        .onHover { inside in
          if inside { list.highlighted = index }
        }
    }
  }

  private func profile(_ row: AddListRow) -> RelayProfile? {
    guard case .assistant(let id) = row.kind else { return nil }
    return list.profile(id)
  }

  private var nothing: some View {
    Text(verbatim: AddListRules.nothing(list.query)).font(AssistantType.meta).foregroundStyle(p.secondary)
      .lineLimit(1).truncationMode(.tail)
      .padding(.horizontal, 10)
      .frame(height: UIStyle.wide(Self.rowHeight))
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One row: its mark, the title, one line, and the green "Now" or Connect at its end. The
/// highlighted row (the keys' or the pointer's) takes the `hover` wash.
private struct AddListRowView: View {
  let row: AddListRow
  let lit: Bool
  let profile: RelayProfile?
  let pick: () -> Void
  @Environment(\.palette) private var p

  private var offersConnect: Bool {
    if case .app(_, let connected) = row.kind { return !connected }
    return false
  }
  private var spoken: String {
    var parts: [String] = [row.title, row.detail]
    if row.now { parts.append("working now") }
    if offersConnect { parts.append("Connect") }
    return parts.joined(separator: ", ")
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ComposerAddListView.rowRadius, style: .continuous)
    Button(action: pick) {
      HStack(spacing: 10) {
        AddListMark(row: row, profile: profile)
        Text(verbatim: row.title).font(AssistantType.body).foregroundStyle(p.ink).lineLimit(1).layoutPriority(1)
        Text(verbatim: row.detail).font(AssistantType.meta).foregroundStyle(p.secondary)
          .lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if row.now { now }
        if offersConnect {
          Text("Connect").font(UIStyle.font(12, weight: .medium)).foregroundStyle(p.accent).fixedSize()
        }
      }
      .padding(.horizontal, 10)
      .frame(height: UIStyle.wide(ComposerAddListView.rowHeight))
      .background(lit ? p.hover : Color.clear, in: shape)
      .contentShape(shape)
    }
    .buttonStyle(AssistantPressStyle())
    .accessibilityLabel(spoken)
    .accessibilityAddTraits(lit ? .isSelected : [])
  }

  private var now: some View {
    HStack(spacing: 5) {
      Circle().fill(p.success).frame(width: 7, height: 7)
      Text("Now").font(AssistantType.meta).foregroundStyle(p.success)
    }
    .fixedSize()
    .accessibilityHidden(true)
  }
}

/// A row's mark at 22 points: the assistant's face, an app's logo on a light wash, a plugin's
/// mark, else an outline icon on a `track` tile.
private struct AddListMark: View {
  let row: AddListRow
  let profile: RelayProfile?
  @Environment(\.palette) private var p
  static let side: CGFloat = 22

  var body: some View {
    switch row.kind {
    case .attach: tile("paperclip")
    case .teach: tile("wand.and.stars")
    case .assistant: AssistantMark(profile: profile, size: Self.side)
    case .chat: tile("bubble.left")
    case .app(let slug, _): logo(BrandLogo(Brand.app(slug), size: 15, name: row.title))
    case .plugin(let id): plugin(id)
    case .addApp: tile("plus")
    }
  }

  private func tile(_ symbol: String) -> some View {
    InterfaceIcon(systemName: symbol, size: 13).foregroundStyle(p.secondary)
      .frame(width: Self.side, height: Self.side)
      .background(p.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .accessibilityHidden(true)
  }
  private func logo(_ mark: BrandLogo) -> some View {
    mark.frame(width: Self.side, height: Self.side)
      .background(p.wash(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .accessibilityHidden(true)
  }
  /// As Settings › Plugins draws it: the AI app's mark for an imported one, GitHub's for one from
  /// GitHub, else a plain glyph.
  @ViewBuilder private func plugin(_ id: String) -> some View {
    let host = PluginHost.shared
    let state: PluginHost.State? = host.states[id]
    let package: PluginPackage? = host.packages.first { $0.id == id }
    if let imported = state?.imported, let brand = Brand.aiApp(imported) {
      logo(BrandLogo(brand, size: 15))
    } else if state?.source != nil {
      logo(BrandLogo(.github, size: 15))
    } else {
      tile(package?.manifest == nil ? "text.book.closed" : "puzzlepiece.extension")
    }
  }
}
