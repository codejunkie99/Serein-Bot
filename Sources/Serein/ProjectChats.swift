import AppKit
import SereinCore
import SwiftUI

/// One chat of a project: a Serein thread, a session running in another app, or a past session
/// of any harness on this Mac.
struct ProjectChat: Identifiable {
  enum Kind {
    case thread(Conversation)
    case running(ExternalSession)
    case past(DiscoveredSession)
  }
  var id: String
  var provider: Provider
  var title: String
  var date: Date
  var kind: Kind
  /// The project it belongs to; nil for a folder that is not a project.
  var projectID: String?

  @MainActor var place: String {
    switch kind {
    case .thread: return "Serein"
    case .running(let s): return s.state == .needsUser ? "Needs you" : s.state == .running ? "Working" : "Open"
    case .past(let s): return SessionOpen.continuesInSerein(s) ? "This Mac" : "Opens in \(provider.name)"
    }
  }
}

/// Every chat by project: Serein's threads (by their project), running sessions and the session
/// history (by the folder they ran in, or the nearest project folder above it). `projects` are the
/// real projects (the List's); a chat elsewhere is "without a project". Sessions in temporary
/// folders (test runs) are left out. Grouping is by the app that ran the chat, never by the
/// model's vendor.
struct ProjectChatIndex {
  private(set) var byProject: [String: [ProjectChat]] = [:]
  private(set) var all: [ProjectChat] = []
  /// Chats outside every project, newest first.
  var unplaced: [ProjectChat] { all.filter { $0.projectID == nil } }

  static let temporary: [String] = {
    let tmp = Self.standard(NSTemporaryDirectory())
    return ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", tmp, "/private" + tmp]
  }()
  static func isTemporary(_ cwd: String?) -> Bool {
    guard let cwd = cwd.map(standard) else { return false }
    return temporary.contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
  }

  init() {}
  /// What History lists now (`ProjectAtlas`), from what the app holds in memory: the task threads,
  /// the sessions running in other apps and, once the person allowed it, each AI app's history.
  @MainActor static func listed(browser: BrowserModel, agent: AgentModel) -> ProjectChatIndex {
    let sessions = SessionHistoryStore.shared
    return ProjectChatIndex(
      projects: browser.listedProjects, threads: agent.conversations, running: ExternalSessionStore.shared.sessions,
      history: SessionDiscoveryModel.shared.consented || sessions.previewing ? sessions.history.sessions : [], hides: agent.isSereinChat)
  }
  /// `hides`: threads that are never listed (Serein's own chats) but still hide the harness
  /// session they ran in, so it never shows again as a “past” chat.
  init(projects: [Project], threads: [Conversation], running: [ExternalSession], history: [DiscoveredSession],
       hides: (Conversation) -> Bool = { _ in false }) {
    var folder: [String: String] = [:]
    for project in projects { folder[Self.standard(project.path)] = project.id }
    let home = Self.standard(NSHomeDirectory())
    /// The project of the folder, else of the nearest folder above it. The home folder takes only
    /// sessions that ran in it, not everything under it.
    func project(for cwd: String?) -> String? {
      guard let start = cwd.map(Self.standard), !start.isEmpty else { return nil }
      var path = start
      while true {
        if let id = folder[path], path == start || path != home { return id }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == path || parent.isEmpty { return nil }
        path = parent
      }
    }
    var seen = Set<String>()
    var chats: [ProjectChat] = []
    for session in running where !Self.isTemporary(session.cwd) {
      chats.append(ProjectChat(
        id: "run:" + session.id, provider: Provider(session.driver), title: session.title, date: session.updatedAt,
        kind: .running(session), projectID: project(for: session.cwd)))
      seen.insert(session.id)
    }
    let real = Set(projects.map(\.id))
    for thread in threads where !thread.messages.isEmpty {
      if let remote = thread.remoteID, let driver = thread.provider.driver { seen.insert(driver.rawValue + ":" + remote) }
      if hides(thread) { continue }
      chats.append(ProjectChat(
        id: "thread:" + thread.id, provider: thread.provider, title: Self.title(thread),
        date: thread.lastMessageAt ?? thread.updatedAt, kind: .thread(thread),
        projectID: thread.projectID.flatMap { real.contains($0) ? $0 : nil }))
    }
    for session in history where !seen.contains(session.provider + ":" + session.id) && !Self.isTemporary(session.cwd) {
      guard let driver = HarnessDriver(rawValue: session.provider) else { continue }
      chats.append(ProjectChat(
        id: "past:\(session.provider):\(session.id)", provider: Provider(driver), title: session.title,
        date: session.date, kind: .past(session), projectID: project(for: session.cwd)))
    }
    all = chats.sorted { $0.date > $1.date }
    byProject = Dictionary(grouping: all.filter { $0.projectID != nil }) { $0.projectID ?? "" }
  }

  /// The harnesses with chats in `projectID`, each with its count, in the harnesses' order.
  func providers(_ projectID: String) -> [(provider: Provider, count: Int)] {
    let counts = Dictionary(grouping: byProject[projectID] ?? [], by: \.provider).mapValues(\.count)
    return Provider.allCases.compactMap { p in counts[p].map { (p, $0) } }
  }
  /// A thread's title: its first request that is the person's own (an imported thread can start
  /// with injected instructions such as AGENTS.md), else the name of a chip sent alone, else its
  /// saved title. Serein's prompts to itself (the daily brief, a check-in) are never a title:
  /// a chat with only those reads “Daily brief”, “Check-in” or “Looking into a task”.
  static func title(_ thread: Conversation) -> String {
    var chip: String?
    var own: String?
    for message in thread.messages.prefix(6) where message.role == "you" {
      if RelayProactive.isOwnPrompt(message.text) {
        own = own ?? message.text
        continue
      }
      if let title = SessionIndex.userTitle(message.text) { return title }
      if chip == nil { chip = message.attached?.first }
    }
    if let chip { return chip }
    let savedIsOwn = RelayProactive.isOwnPrompt(thread.title)
    if !savedIsOwn, let title = SessionIndex.userTitle(thread.title) { return title }
    if let own = own ?? (savedIsOwn ? thread.title : nil) { return RelayProactive.shortTitle(own) }
    return thread.title
  }
  static func standard(_ path: String) -> String {
    path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }
}

/// Opens the exact chat: a Serein thread; a chat Serein can read (LinkedSessions.link), running or
/// past, as a Serein thread that follows it (LinkedSessions.swift); the app any other running
/// session lives in; any other past session in its own CLI, resumed in the folder it ran in, in
/// Serein's terminal.
@MainActor enum SessionOpen {
  static func open(_ chat: ProjectChat, agent: AgentModel) {
    switch chat.kind {
    case .thread(let thread): agent.openConversation(thread)
    case .running(let session): openRunning(session, agent: agent)
    case .past(let session): openPast(session, agent: agent)
    }
  }
  /// A chat Serein can read opens in Serein and follows the app that runs it; any other brings
  /// that app forward.
  static func openRunning(_ session: ExternalSession, agent: AgentModel) {
    if let link = link(for: session) {
      agent.openLinked(link, lastActive: session.updatedAt)
    } else if !AgentsCard.reveal(session) {
      ToastCenter.shared.show("Serein cannot open this \(session.driver.displayName) session. Look for it in its own app.")
    }
  }
  /// Codex and Claude Code name the chat; other harnesses only their process (LinkedSessions.past).
  static func link(for session: ExternalSession) -> SessionLink? {
    let prefix = session.driver.rawValue + ":"
    if [.codex, .claude].contains(session.driver), session.id.hasPrefix(prefix) {
      return SessionLink(
        driver: session.driver.rawValue, nativeID: String(session.id.dropFirst(prefix.count)),
        file: session.driver == .claude ? session.log : nil)
    }
    return LinkedSessions.past(for: session).flatMap(LinkedSessions.link(for:))
  }
  /// Chats Serein can read continue in a Serein thread.
  static func continuesInSerein(_ session: DiscoveredSession) -> Bool { LinkedSessions.link(for: session) != nil }
  static func openPast(_ session: DiscoveredSession, agent: AgentModel) {
    if let link = LinkedSessions.link(for: session) { agent.openLinked(link) } else { resume(session, agent: agent) }
  }
  /// The session in its own CLI.
  static func resume(_ session: DiscoveredSession, agent: AgentModel) {
    guard let driver = HarnessDriver(rawValue: session.provider),
      let command = HarnessCommands.resume(driver, id: session.id, file: session.file, folder: session.cwd)
    else {
      agent.error = "This session cannot be opened from Serein."
      return
    }
    guard HarnessRegistry.shared.executable(Provider(driver)) != nil else {
      agent.error = "\(driver.displayName) is not installed or is turned off in Settings › AI apps."
      return
    }
    HarnessActions.shared.run(command, driver: driver)
  }
}

/// The harnesses with chats in a project, as overlapping marks with one total. A click shows or
/// hides the project's chats; the help names each harness's count.
struct ProjectChatStack: View {
  var counts: [(provider: Provider, count: Int)]
  var open: Bool
  var toggle: () -> Void
  @Environment(\.palette) private var p
  var total: Int { counts.map(\.count).reduce(0, +) }
  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        HStack(spacing: -5) {
          ForEach(counts.prefix(4), id: \.provider) { item in
            HarnessGlyph(provider: item.provider, size: 9, tinted: true)
              .frame(width: 18, height: 18)
              .background(p.raised, in: Circle())
              .overlay(Circle().stroke(p.background, lineWidth: 1.5))
          }
        }
        Text("\(total.formatted()) chat\(total == 1 ? "" : "s")").font(UIStyle.micro)
          .foregroundStyle(open ? p.ink : p.faint).lineLimit(1).fixedSize()
      }.padding(.leading, 4).padding(.trailing, 8).frame(height: 24)
        .background(open ? p.selected : .clear, in: Capsule())
        .contentShape(Capsule())
    }.buttonStyle(.pressable)
      .help(counts.map { "\($0.count) \($0.provider.name)" }.joined(separator: ", "))
      .accessibilityLabel("\(total) chats: " + counts.map { "\($0.count) \($0.provider.name)" }.joined(separator: ", "))
      .accessibilityValue(open ? "Shown" : "Hidden")
  }
}

extension Provider {
  /// The harness's name without "Agent" and "Code" ("Claude", "Cursor", "Gemini"), for chips.
  @MainActor var chipName: String {
    switch driver {
    case .claude: return "Claude"
    case .cursor: return "Cursor"
    case .ohMyPi: return "Oh My Pi"
    case .gemini: return "Gemini"
    default: return name
    }
  }
}

/// A harness filter: All, then each harness that has chats.
struct ProviderChips: View {
  var providers: [Provider]
  @Binding var selected: Provider?
  @Environment(\.palette) private var p
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        chip(nil)
        ForEach(providers, id: \.self) { chip($0) }
      }
    }.frame(height: 26)
  }
  func chip(_ provider: Provider?) -> some View {
    let on = selected == provider
    return Button { selected = provider } label: {
      Group {
        if let provider {
          HStack(spacing: 5) {
            HarnessGlyph(provider: provider, size: 11, tinted: true)
            Text(provider.chipName).font(UIStyle.meta)
          }
        } else {
          Text("All").font(UIStyle.meta)
        }
      }.foregroundStyle(on ? p.ink : p.secondary).padding(.horizontal, 9).frame(height: 24)
        .background(on ? p.selected : .clear, in: Capsule())
        .contentShape(Capsule())
    }.buttonStyle(.pressable).accessibilityLabel(provider?.name ?? "All agents")
      .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/// A project's chats under its row, grouped by harness: the chips choose one; All shows each
/// harness under its own heading (its mark, as in the model picker), which expands and
/// collapses, with three chats until "Show all".
struct ProjectChatsPanel: View {
  var chats: [ProjectChat]
  @Binding var provider: Provider?
  @ObservedObject var agent: AgentModel
  @State private var showAll = false
  @State private var collapsed: Set<Provider> = []
  @Environment(\.palette) private var p
  static let shown = 8
  var providers: [Provider] { Provider.allCases.filter { p in chats.contains { $0.provider == p } } }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ProviderChips(providers: providers, selected: $provider).padding(.bottom, 4)
      if let provider {
        let list = chats.filter { $0.provider == provider }
        let visible = showAll ? list : Array(list.prefix(Self.shown))
        ForEach(visible) { chat in ChatRow(chat: chat, agent: agent) }
        if list.count > Self.shown {
          ShowAllButton(showAll ? "Show fewer" : "Show all \(list.count)") { showAll.toggle() }
        }
      } else {
        ForEach(providers, id: \.self) { harness in
          let listed = chats.filter { $0.provider == harness }
          let open = !collapsed.contains(harness)
          DisclosureHeading(open: open, count: listed.count, title: harness.name) {
            HarnessGlyph(provider: harness, size: 11, tinted: true)
          } toggle: {
            if open { collapsed.insert(harness) } else { collapsed.remove(harness) }
          }
          if open {
            ForEach(listed.prefix(3)) { chat in ChatRow(chat: chat, agent: agent) }
            if listed.count > 3 { ShowAllButton("Show all \(listed.count)") { provider = harness } }
          }
        }
      }
    }.padding(.leading, 30).padding(.bottom, 10)
      .onChange(of: provider) { _, _ in showAll = false }
  }
}

/// A heading that expands and collapses what follows: chevron, a mark, the title and a count.
struct DisclosureHeading<Mark: View>: View {
  var open: Bool
  var count: Int
  var title: String
  @ViewBuilder var mark: () -> Mark
  var toggle: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 6) {
        InterfaceIcon(systemName: open ? "chevron.down" : "chevron.right", size: 9).foregroundStyle(p.faint)
          .frame(width: 10)
        mark()
        Text(title).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
        Text("\(count)").font(UIStyle.microMono).foregroundStyle(p.faint)
        Spacer(minLength: 0)
      }.padding(.leading, 6).padding(.top, 8).padding(.bottom, 2).contentShape(Rectangle())
    }.buttonStyle(.pressable)
      .accessibilityLabel("\(title), \(count)").accessibilityValue(open ? "Expanded" : "Collapsed")
      .accessibilityAddTraits(.isHeader)
  }
}

/// "Show all 52": quiet, under a list.
struct ShowAllButton: View {
  var title: String
  var action: () -> Void
  @Environment(\.palette) private var p
  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }
  var body: some View {
    Button(title, action: action).buttonStyle(.pressable).font(UIStyle.micro).foregroundStyle(p.faint)
      .padding(.leading, 36).padding(.vertical, 4)
  }
}

/// One chat: harness mark, title, a state only when it says something (working, needs you, a
/// Serein thread), and when. Where it opens is in the help.
struct ChatRow: View {
  var chat: ProjectChat
  var agent: AgentModel
  /// Where it ran, when the list is not grouped by project.
  var detail: String? = nil
  /// The narrow sidebar: a state is a dot, and the time column is narrower.
  var compact = false
  @State private var hovered = false
  @Environment(\.palette) private var p
  var badge: String? {
    switch chat.kind {
    case .running(let s): return s.state == .needsUser ? "Needs you" : s.state == .running ? "Working" : nil
    case .thread: return "Serein"
    case .past: return nil
    }
  }
  var help: String {
    switch chat.kind {
    case .thread: return "Open in Serein"
    case .running(let s):
      return SessionOpen.link(for: s) != nil
        ? "Open in Serein; it follows the app the chat runs in" : "Bring forward the app it runs in"
    case .past(let s):
      return SessionOpen.continuesInSerein(s)
        ? "Open in Serein; it stays up to date with \(chat.provider.name)" : "Opens in \(chat.provider.name)"
    }
  }
  var body: some View {
    Button { SessionOpen.open(chat, agent: agent) } label: {
      HStack(spacing: 10) {
        HarnessGlyph(provider: chat.provider, size: 11, tinted: true).frame(width: 16)
        Text(verbatim: chat.title).font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let detail {
          Text(verbatim: detail).font(UIStyle.micro).foregroundStyle(p.faint).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 160, alignment: .trailing)
        }
        if let badge, compact {
          if badge != "Serein" {
            Circle().fill(badge == "Needs you" ? p.warning : p.accent).frame(width: 6, height: 6)
              .accessibilityHidden(true)
          }
        } else if let badge {
          Text(badge).font(UIStyle.micro).lineLimit(1).fixedSize()
            .foregroundStyle(badge == "Needs you" ? p.warning : badge == "Working" ? p.accent : p.secondary)
        }
        Text(RelativeTimeShort.text(chat.date) ?? "").font(UIStyle.microMono).foregroundStyle(p.faint)
          .lineLimit(1).fixedSize().frame(minWidth: UIStyle.wide(compact ? 30 : 44), alignment: .trailing)
      }.padding(.leading, compact ? 6 : 10).padding(.trailing, compact ? 4 : 6).frame(height: compact ? 28 : 32)
        .background(hovered ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .contentShape(Rectangle())
    }.buttonStyle(.pressable).onHover { hovered = $0 }.help(help)
      .contextMenu { menu }
      .accessibilityLabel("\(chat.provider.name): \(chat.title)" + (badge.map { ", \($0)" } ?? ""))
      .accessibilityHint(help)
  }
  @ViewBuilder var menu: some View {
    if case .past(let session) = chat.kind {
      if SessionOpen.continuesInSerein(session) {
        Button("Continue in Serein") { SessionOpen.open(chat, agent: agent) }
      }
      Button("Open in \(chat.provider.name)") { SessionOpen.resume(session, agent: agent) }
      if !session.cwd.isEmpty {
        Button("Show Folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd) }
      }
    } else {
      Button("Open") { SessionOpen.open(chat, agent: agent) }
    }
  }
}

/// Small overlapping marks of the apps a group has chats from (the model picker's marks).
struct AppMarks: View {
  var providers: [Provider]
  @Environment(\.palette) private var p
  var body: some View {
    HStack(spacing: -4) {
      ForEach(providers.prefix(4), id: \.self) { provider in
        HarnessGlyph(provider: provider, size: 8, tinted: true)
          .frame(width: 15, height: 15)
          .background(p.raised, in: Circle())
          .overlay(Circle().stroke(p.card, lineWidth: 1.5))
      }
    }.accessibilityLabel(providers.map(\.name).joined(separator: ", "))
  }
}
