import AppKit
import Combine
import SereinCore
import SwiftUI

/// Past sessions of every harness on this Mac (SessionHistory), kept current by a watcher on
/// every harness's store (no polling; its place in the FSEvents journal is saved, so a launch
/// catches up on what changed while Serein was closed), and Codex Cloud tasks, read by the Codex
/// CLI only when the Codex tab shows.
@MainActor final class SessionHistoryStore: ObservableObject {
  static let shared = SessionHistoryStore()
  @Published private(set) var history = SessionHistory()
  @Published private(set) var cloud: [CloudTask] = []
  @Published private(set) var cloudNote: String?
  private var library: Library?
  /// Folders Cursor's hashed names are matched against: the user's projects.
  private var known: () -> [String] = { [] }
  private var refreshing = false
  private var queuedFull = false
  private var queued = Set<String>()
  /// The journal's place after the queued changes (SessionLogWatcher.Batch.through).
  private var queuedThrough: UInt64 = 0
  static let eventKey = "serein.historyEventID"
  private var cloudReadAt: Date?
  private var watcher: SessionLogWatcher?
  private var observers: [Any] = []
  /// UI previews show fixed past sessions without session discovery's consent.
  @Published private(set) var previewing = false
  /// A preview's tab: "all" or a harness raw value.
  @Published var previewTab: String?
  /// A preview's project whose chats show under its row.
  @Published var previewExpand: String?

  func installPreview(_ history: SessionHistory, cloud: [CloudTask]) {
    previewing = true
    watcher?.stop()
    watcher = nil
    self.history = history
    self.cloud = cloud
    cloudReadAt = .distantFuture
  }

  static var roots: SessionHistory.Roots {
    SessionHistory.Roots(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
  }

  func configure(library: Library, known: @escaping () -> [String] = { [] }) {
    guard self.library == nil else { return }
    self.library = library
    self.known = known
    history = library.load(SessionHistory.self, from: SessionHistory.path).flatMap { $0.isCurrent ? $0 : nil } ?? SessionHistory()
    guard !previewing, !RunMode.automated, !RunMode.stress else { return }
    watch()
    let center = NotificationCenter.default
    observers = [
      // A store made since launch (a harness's first session) joins the watched folders.
      center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        // A project added since the last read places its Cursor chats (no file changes for that).
        MainActor.assumeIsolated {
          self?.watch()
          self?.changed([])
        }
      },
      center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.watcher?.stop() }
      },
      // Turning discovery on reads everything once.
      SessionDiscoveryModel.shared.$automatic.dropFirst().removeDuplicates().sink { [weak self] on in
        if on { self?.changed(nil) }
      },
    ]
    if history.entries.isEmpty { changed(nil) }
  }

  private func watch() {
    let roots = SessionLogWatcher.existing(Self.roots.folders)
    guard watcher?.roots != roots else { return }
    watcher?.stop()
    let watcher = SessionLogWatcher(roots: roots, eventKey: Self.eventKey) { [weak self] batch in
      self?.changed(batch.full ? nil : batch.paths, through: batch.through)
    }
    self.watcher = watcher
    watcher.start()
  }

  /// Changed paths; nil reads every session store again. `through` is the watcher's place after
  /// them, saved once they are read and stored.
  func changed(_ paths: Set<String>?, through: UInt64 = 0) {
    guard library != nil, !previewing else { return }
    // Without consent nothing is read; turning it on reads everything, so the place moves on.
    guard SessionDiscoveryModel.shared.consented else {
      SessionLogWatcher.commit(.init(paths: [], full: false, through: through), key: Self.eventKey)
      return
    }
    if refreshing {
      if let paths { queued.formUnion(paths) } else { queuedFull = true }
      queuedThrough = max(queuedThrough, through)
      return
    }
    refreshing = true
    let current = history
    let roots = Self.roots
    let known = Set(known())
    let hidden = HelperFolder.hidden
    let library = self.library
    Task {
      // Batches arriving meanwhile queue (`refreshing`): a burst is read and written at most twice.
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      // Read and written off the main actor: the file is the whole history, pretty-printed.
      let (next, stored) = await Task.detached(priority: .utility) { () -> (SessionHistory, Bool) in
        var history = current
        history.refresh(paths, roots: roots, known: known, hidden: hidden)
        guard history != current, let library else { return (history, true) }
        do {
          try FileManager.default.createDirectory(
            at: library.root.appendingPathComponent("agents"), withIntermediateDirectories: true)
          try library.save(history, to: SessionHistory.path)
          return (history, true)
        } catch {
          return (history, false)
        }
      }.value
      refreshing = false
      if next != history { history = next }
      // A batch that did not reach the disk comes again on the next launch.
      if stored { SessionLogWatcher.commit(.init(paths: [], full: false, through: through), key: Self.eventKey) }
      if queuedFull || !queued.isEmpty || queuedThrough != 0 {
        let again: Set<String>? = queuedFull ? nil : queued
        let place = queuedThrough
        queuedFull = false
        queued = []
        queuedThrough = 0
        changed(again, through: place)
      }
    }
  }

  /// Codex Cloud has no file on this Mac to watch: its tasks are read when the Codex tab shows,
  /// at most once a minute.
  func readCloud() {
    // Codex may be unprobed since launch (HarnessRegistry.deferred): the tab's next showing reads it.
    HarnessRegistry.shared.probeDeferred([.codex])
    guard cloudReadAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true,
      !previewing, let codex = HarnessRegistry.shared.executable(.codex)
    else { return }
    cloudReadAt = Date()
    let env = HarnessRegistry.shared.environment(.codex, executable: codex)
    // Every task: pages of 20 (the most `codex cloud list` returns at once), following its cursor
    // to the end. The list shows when every page is in; a page that fails keeps what is shown.
    Task {
      // `codex cloud` writes ./error.log, with the ChatGPT account id, into the folder it runs in.
      let scratch = CloudTaskModel.scratch()
      defer { try? FileManager.default.removeItem(at: scratch) }
      var all: [CloudTask] = []
      var cursor: String?
      var seen: Set<String> = []
      repeat {
        let result = await HarnessProbe.run(
          codex, ["cloud", "list", "--json", "--limit", "20"] + (cursor.map { ["--cursor", $0] } ?? []),
          environment: env, timeout: 20, cwd: scratch)
        guard result.code == 0 else {
          cloudNote = "Codex Cloud could not be read. Sign in to Codex to see cloud tasks."
          if !all.isEmpty { cloud = all }
          return
        }
        // Warnings may come before the JSON on the same output.
        let text = result.output
        let json = text.firstIndex(of: "{").map { String(text[$0...]) } ?? ""
        let page = CloudTask.page(Data(json.utf8))
        let known = Set(all.map(\.id))
        all += page.tasks.filter { !known.contains($0.id) }
        cursor = page.cursor
        // A cursor that comes back again would never end the list.
        if let next = cursor, !seen.insert(next).inserted { cursor = nil }
      } while cursor != nil
      cloud = all
      cloudNote = nil
    }
  }
}

/// The sidebar's Agents card. Its tab follows the composer's harness (one way: choosing a tab only
/// changes what is listed; opening a chat sets the composer). Under it, sessions running now in
/// other apps, then every chat by date: Serein's threads, each harness's past sessions on this
/// Mac and Codex Cloud tasks.
struct AgentsCard: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var external = ExternalSessionStore.shared
  @ObservedObject private var store = SessionHistoryStore.shared
  @ObservedObject private var discovery = SessionDiscoveryModel.shared
  /// nil is All.
  @State private var tab: Provider?
  @State private var showAll = false
  /// On the sidebar the card has a heading with a minimize/expand toggle, and the line above it sets
  /// the chat list's height. Elsewhere (the At work popover) it has none of these.
  var sidebar = false
  @AppStorage(SidebarSizes.chatsFoldedKey) private var folded = false
  @AppStorage(SidebarSizes.chatsHeightKey) private var chatsHeight = 0.0
  @State private var headingHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.palette) private var p
  static let shown = 6

  struct Item: Identifiable {
    enum Kind {
      case running(ExternalSession)
      case thread(Conversation)
      case past(DiscoveredSession)
      case cloud(CloudTask)
    }
    var id: String
    var provider: Provider
    var title: String
    var date: Date?
    var kind: Kind
  }

  var items: [Item] {
    var out: [Item] = []
    var seen = Set<String>()
    for session in external.sessions {
      out.append(Item(id: "run:" + session.id, provider: Provider(session.driver), title: session.title, date: session.updatedAt, kind: .running(session)))
      seen.insert(session.id)
    }
    for thread in agent.conversations where !thread.messages.isEmpty {
      // Serein's own chats are never listed, but the harness sessions they ran in stay hidden too.
      if let remote = thread.remoteID, let driver = thread.provider.driver { seen.insert(driver.rawValue + ":" + remote) }
      if agent.isSereinChat(thread) { continue }
      out.append(Item(id: "thread:" + thread.id, provider: thread.provider, title: thread.title, date: thread.lastMessageAt ?? thread.updatedAt, kind: .thread(thread)))
    }
    if discovery.consented || store.previewing {
      for session in store.history.sessions where !seen.contains(session.provider + ":" + session.id) {
        guard let driver = HarnessDriver(rawValue: session.provider) else { continue }
        out.append(Item(
          id: "past:\(session.provider):\(session.id)", provider: Provider(driver), title: session.title, date: session.date,
          kind: .past(session)))
      }
    }
    for task in store.cloud {
      out.append(Item(id: "cloud:" + task.id, provider: .codex, title: task.title, date: task.updatedAt, kind: .cloud(task)))
    }
    return out
  }
  /// All, then each harness that has something to list, in the harnesses' order.
  func tabs(_ items: [Item]) -> [Provider?] {
    let present = Set(items.map(\.provider)).union([agent.provider])
    return [nil] + Provider.allCases.filter(present.contains)
  }

  static func isRunning(_ item: Item) -> Bool {
    if case .running = item.kind { return true }
    return false
  }

  /// Projects whose chats are open on the All tab, closed on a harness tab, and shown in full.
  @State private var opened: Set<String> = []
  @State private var closed: Set<String> = []
  @State private var full: Set<String> = []
  static let perProject = 5

  var body: some View {
    let all: [Item] = items
    let index = ProjectChatIndex(
      projects: browser.listedProjects, threads: agent.conversations, running: external.sessions,
      history: discovery.consented || store.previewing ? store.history.sessions : [], hides: agent.isSereinChat)
    let shown = index.all.filter { tab == nil || $0.provider == tab }
    let running = shown.filter { if case .running = $0.kind { return true } else { return false } }
    let moving: [String] = running.map(\.id) + [tab?.rawValue ?? "all"] + Array(opened) + Array(closed)
    return list(tabs: tabs(all), index: index, running: running)
      .padding(4)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius, style: .continuous))
      .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: moving)
      .onAppear(perform: appeared)
      .onChange(of: agent.provider) { _, provider in tab = provider }
      .onChange(of: tab) { _, shown in switched(to: shown) }
      .onChange(of: store.previewTab) { _, _ in appeared() }
      .accessibilityElement(children: .contain).accessibilityLabel("Agents")
  }
  func appeared() {
    if let forced = store.previewTab {
      tab = forced == "all" ? nil : Provider.allCases.first { $0.driver?.rawValue == forced }
      return
    }
    tab = agent.provider
    if tab == .codex { store.readCloud() }
  }
  func switched(to shown: Provider?) {
    showAll = false
    opened = []
    closed = []
    full = []
    if shown == .codex || shown == nil { store.readCloud() }
  }

  /// A group is open on a harness tab unless closed; on All (and for chats without a project or
  /// in the cloud) only when opened.
  func isOpen(_ key: String) -> Bool {
    tab != nil && !key.hasPrefix("+") ? !closed.contains(key) : opened.contains(key)
  }
  func toggle(_ key: String) {
    if isOpen(key) {
      opened.remove(key)
      closed.insert(key)
    } else {
      closed.remove(key)
      opened.insert(key)
    }
  }

  /// Running sessions, then each project with chats of the chosen app (newest project first),
  /// then chats without a project and Codex Cloud tasks. Grouped by the app that ran a chat.
  func list(tabs: [Provider?], index: ProjectChatIndex, running: [ProjectChat]) -> some View {
    let projects = browser.listedProjects
    let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    func chats(_ list: [ProjectChat]) -> [ProjectChat] {
      list.filter { chat in
        if case .running = chat.kind { return false }
        return tab == nil || chat.provider == tab
      }
    }
    let groups: [(project: Project, chats: [ProjectChat])] = index.byProject.compactMap { id, list in
      guard let project = byID[id] else { return nil }
      let listed = chats(list)
      return listed.isEmpty ? nil : (project, listed)
    }.sorted { ($0.chats.first?.date ?? .distantPast) > ($1.chats.first?.date ?? .distantPast) }
    let loose = chats(index.unplaced)
    let cloud = tab == nil || tab == .codex ? store.cloud : []
    let sized = sidebar && chatsHeight > 0
    return VStack(alignment: .leading, spacing: 2) {
      if sidebar {
        HStack(spacing: 6) {
          SidebarSectionHeading(
            title: "Chats", count: index.all.filter { tab == nil || $0.provider == tab }.count + cloud.count,
            folded: $folded, hovered: headingHovered)
        }.padding(.leading, 8).padding(.trailing, 2).frame(height: 24).onHover { headingHovered = $0 }
      }
      if !(sidebar && folded) {
      tabRow(tabs)
      if !running.isEmpty {
        heading("Running now", running.count)
        ForEach(running) { chat in ChatRow(chat: chat, agent: agent, compact: true) }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(groups, id: \.project.id) { group in
            projectGroup(key: group.project.id, title: group.project.name, chats: group.chats, tile: true)
          }
          if !loose.isEmpty { projectGroup(key: "+loose", title: "No project", chats: loose, tile: false) }
          if !cloud.isEmpty { cloudGroup(cloud) }
          if groups.isEmpty && loose.isEmpty && cloud.isEmpty {
            Text(emptyText).font(UIStyle.meta).foregroundStyle(p.faint).padding(.horizontal, 8).padding(.vertical, 6)
          }
        }
      }.frame(minHeight: sized ? 60 : nil, maxHeight: sized ? CGFloat(chatsHeight) : 360)
        .fixedSize(horizontal: false, vertical: !sized && groups.count + (loose.isEmpty ? 0 : 1) < 4)
      if tab == .codex, let note = store.cloudNote {
        Text(note).font(UIStyle.micro).foregroundStyle(p.faint).padding(.horizontal, 8)
      }
      if !discovery.consented && !store.previewing {
        Text("Past sessions are off. Turn on session discovery in Settings to list them.")
          .font(UIStyle.micro).foregroundStyle(p.faint).padding(.horizontal, 8).padding(.vertical, 2)
      }
      }
    }
  }

  /// A project (or "Chats without a project"): chevron, tile, name, count, and on All the marks
  /// of the apps it has chats from; open, its five newest chats and "Show N more".
  @ViewBuilder func projectGroup(key: String, title: String, chats: [ProjectChat], tile: Bool) -> some View {
    let open = isOpen(key)
    Button { toggle(key) } label: {
      HStack(spacing: 6) {
        InterfaceIcon(systemName: open ? "chevron.down" : "chevron.right", size: 9).foregroundStyle(p.faint).frame(width: 10)
        if tile { ProjectTile(name: title, size: 16) }
        Text(title).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
        Text("\(chats.count)").font(UIStyle.microMono).foregroundStyle(p.faint)
        Spacer(minLength: 0)
        if tab == nil { AppMarks(providers: Provider.allCases.filter { p in chats.contains { $0.provider == p } }) }
      }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
    }.buttonStyle(.pressable)
      .accessibilityLabel("\(title), \(chats.count) chat\(chats.count == 1 ? "" : "s")").accessibilityValue(open ? "Expanded" : "Collapsed")
    if open {
      let all = full.contains(key)
      ForEach(all ? chats : Array(chats.prefix(Self.perProject))) { chat in ChatRow(chat: chat, agent: agent, compact: true) }
      if chats.count > Self.perProject {
        Button(all ? "Show fewer" : "Show \(chats.count - Self.perProject) more") {
          if all { full.remove(key) } else { full.insert(key) }
        }.buttonStyle(.pressable).font(UIStyle.micro).foregroundStyle(p.faint).padding(.leading, 34).padding(.vertical, 3)
      }
    }
  }

  /// Codex Cloud tasks: no folder on this Mac; a click opens the task in a tab.
  @ViewBuilder func cloudGroup(_ tasks: [CloudTask]) -> some View {
    let shown = isOpen("+cloud")
    Button { toggle("+cloud") } label: {
      HStack(spacing: 6) {
        InterfaceIcon(systemName: shown ? "chevron.down" : "chevron.right", size: 9).foregroundStyle(p.faint).frame(width: 10)
        HarnessGlyph(provider: .codex, size: 11, tinted: true)
        Text("Codex Cloud").font(UIStyle.meta).foregroundStyle(p.ink)
        Text("\(tasks.count)").font(UIStyle.microMono).foregroundStyle(p.faint)
        Spacer(minLength: 0)
      }.padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
    }.buttonStyle(.pressable).accessibilityValue(shown ? "Expanded" : "Collapsed")
    if shown {
      ForEach(tasks) { task in
        let item = Item(id: "cloud:" + task.id, provider: .codex, title: task.title, date: task.updatedAt, kind: .cloud(task))
        AgentsRow(item: item, open: { open(item) })
      }
    }
  }

  var emptyText: String { tab.map { "No \($0.name) chats yet." } ?? "No chats yet." }

  func tabRow(_ tabs: [Provider?]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(tabs, id: \.self) { provider in
          let on = tab == provider
          Button {
            tab = provider
          } label: {
            Group {
              if let provider {
                // The model picker's marks, in their own colours.
                HarnessGlyph(provider: provider, size: 13, tinted: true).opacity(on ? 1 : 0.55)
              } else {
                Text("All").font(UIStyle.meta)
              }
            }.foregroundStyle(on ? p.ink : p.secondary)
              .frame(minWidth: 28, minHeight: 24).padding(.horizontal, 4)
              .background(on ? p.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
              .contentShape(Rectangle())
          }.buttonStyle(.pressable).help(provider?.name ?? "All agents")
            .accessibilityLabel(provider?.name ?? "All agents").accessibilityAddTraits(on ? .isSelected : [])
        }
      }.padding(.horizontal, 2)
    }.frame(height: 28)
  }

  func heading(_ title: String, _ count: Int) -> some View {
    HStack(spacing: 6) {
      Text(title).font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityAddTraits(.isHeader)
      Text("\(count)").font(UIStyle.microMono).foregroundStyle(p.faint)
      Spacer(minLength: 0)
    }.padding(.horizontal, 8).padding(.top, 4).frame(height: 22)
  }

  func open(_ item: Item) {
    switch item.kind {
    case .running(let session): SessionOpen.openRunning(session, agent: agent)
    case .thread(let thread): agent.openConversation(thread)
    case .past(let session): SessionOpen.openPast(session, agent: agent)
    case .cloud(let task): CloudTaskWindow.show(task, browser: browser)
    }
  }

  /// Brings forward the app a session runs in: the nearest parent process that is an app. False
  /// when there is none to bring forward.
  @discardableResult static func reveal(_ session: ExternalSession) -> Bool {
    guard let pid = session.pid else { return false }
    for ancestor in [pid] + HarnessProcessDiscovery.ancestors(pid) {
      if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
        app.activate()
        return true
      }
    }
    return false
  }
}

private struct AgentsRow: View {
  var item: AgentsCard.Item
  var open: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p
  static let ago: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()
  var place: String {
    switch item.kind {
    case .running(let s):
      return s.state == .needsUser ? "Needs you" : s.state == .running ? "Working" : "Open"
    case .thread: return "Serein"
    case .past: return "This Mac"
    case .cloud(let task): return "Cloud" + (task.status.isEmpty ? "" : " · " + task.status.capitalized)
    }
  }
  var detail: String {
    guard let date = item.date else { return place }
    let now = Date()
    return place + " · " + (now.timeIntervalSince(date) < 60 ? "now" : Self.ago.localizedString(for: date, relativeTo: now))
  }
  var help: String {
    switch item.kind {
    case .running(let s):
      return SessionOpen.link(for: s) != nil ? "Open in Serein; it follows the app the chat runs in" : "Bring forward the app it runs in"
    case .thread: return "Open in Serein"
    case .past(let s): return SessionOpen.continuesInSerein(s) ? "Continue in Serein (you confirm its folder)" : "Open in its own app"
    case .cloud: return "See the task's changes, and apply them to its project"
    }
  }
  var body: some View {
    Button(action: open) {
      HStack(spacing: 8) {
        HarnessGlyph(provider: item.provider, size: 12, tinted: true)
          .frame(width: 22, height: 22).background(p.raised, in: RoundedRectangle(cornerRadius: 6))
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: item.title).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1)
          Text(detail).font(UIStyle.meta).lineLimit(1)
            .foregroundStyle(place == "Needs you" ? p.warning : p.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        if case .running(let s) = item.kind {
          if s.state == .running { ActivityRing(active: true) }
          else if s.state == .needsUser { Circle().fill(p.warning).frame(width: 6, height: 6) }
        }
      }.padding(.horizontal, 6).padding(.vertical, 4)
        .background(hovered ? p.raised.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }.buttonStyle(.pressable).onHover { hovered = $0 }.help(help)
      .transition(.opacity.combined(with: .move(edge: .top)))
      .accessibilityLabel("\(item.provider.name): \(item.title), \(place)").accessibilityHint(help)
  }
}
