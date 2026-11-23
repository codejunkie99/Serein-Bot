import AppKit
import SereinCore
import SwiftUI

/// What the next task works on, in one calm picker (the composer's `+`): a search on top, the four
/// places in one row, the three projects used last with the app and time of their newest chat,
/// all projects, and attachments in a quieter footer. No separators, no check marks: a choice is
/// a filled place or row. None chosen is Auto. This page goes with one project; Library, Mac and
/// Web each replace everything else; choosing the chosen one again clears it.
struct WorkOnPicker: View {
  enum Place: String, CaseIterable, Identifiable {
    case page, web, mac, library
    var id: String { rawValue }
    var icon: String {
      switch self {
      case .page: return "doc.text"
      case .web: return "globe"
      case .mac: return "laptopcomputer"
      case .library: return "clock"
      }
    }
    var title: String {
      switch self {
      case .page: return "This page"
      case .web: return "The web"
      case .mac: return "This Mac"
      case .library: return "Library"
      }
    }
    var help: String {
      switch self {
      case .page: return "The open page: read it, and click and type if you allow it"
      case .web: return "Websites, in tabs of its own"
      case .mac: return "Calendar, Reminders, Notes, Finder and other apps, one approved step at a time"
      case .library: return "Your history, day notes and saved pages, as a private copy"
      }
    }
  }
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var done: () -> Void
  @State private var query = ""
  @State private var showAll = false
  @State private var hovered: String?
  @FocusState private var searching: Bool
  @Environment(\.palette) private var p
  static var width: CGFloat { UIStyle.wide(344) }

  var places: Set<Place> { Self.places(agent) }
  var project: String? { agent.mode == .project ? agent.projectID : nil }
  /// A regular tab with a page: the only kind a task may read.
  var pageAvailable: Bool {
    browser.active.map { !$0.privateMode && !$0.hiddenFromAgents && !$0.address.isEmpty } ?? false
  }

  static func places(_ agent: AgentModel) -> Set<Place> {
    var places: Set<Place> = agent.mode == .page || agent.pageInProject ? [.page] : []
    if let place = [TaskMode.research: Place.web, .anywhere: .mac, .library: .library][agent.mode] { places.insert(place) }
    return places
  }
  /// This page goes with one project; the other places replace everything; the chosen one again clears.
  static func choose(_ place: Place, agent: AgentModel) {
    let on = places(agent).contains(place)
    agent.autoRouting = false
    if place == .page, agent.mode == .project {
      agent.includePage = !on
      return
    }
    agent.projectID = nil
    agent.includePage = false
    if on { return agent.mode = .auto }
    agent.mode = [Place.page: TaskMode.page, .web: .research, .mac: .anywhere, .library: .library][place]!
    if place == .library { DestinationPicker.fitHarness(agent, for: "your library") }
  }
  static func choose(_ project: Project, agent: AgentModel, browser: BrowserModel) {
    if agent.mode == .project && agent.projectID == project.id { return clear(agent) }
    DestinationPicker.apply(
      DestinationOption(kind: .project, id: project.id, title: project.name), agent: agent,
      pageAvailable: browser.section == ShellSection.browser)
  }
  /// Back to Auto: Serein picks where the next task works.
  static func clear(_ agent: AgentModel) {
    agent.autoRouting = false
    agent.projectID = nil
    agent.includePage = false
    agent.mode = .auto
  }

  /// Matches for the search; else all projects when asked; else the three used last.
  var shown: [Project] {
    let listed = browser.listedProjects
    if !query.isEmpty { return listed.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    if showAll { return listed }
    var ids: [String] = []
    let threads = agent.listedConversations.sorted { ($0.lastMessageAt ?? $0.updatedAt) > ($1.lastMessageAt ?? $1.updatedAt) }
    for id in threads.compactMap(\.projectID) + listed.map(\.id) where !ids.contains(id) && listed.contains(where: { $0.id == id }) {
      ids.append(id)
    }
    return ids.prefix(3).compactMap { id in listed.first { $0.id == id } }
  }
  /// The app and time of a project's newest chat.
  func last(_ project: Project) -> (provider: Provider, date: Date)? {
    agent.listedConversations.filter { $0.projectID == project.id }
      .max { ($0.lastMessageAt ?? $0.updatedAt) < ($1.lastMessageAt ?? $1.updatedAt) }
      .map { ($0.provider, $0.lastMessageAt ?? $0.updatedAt) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      search
      if query.isEmpty {
        HStack(spacing: 6) { ForEach(Place.allCases) { place($0) } }
          .padding(.horizontal, 10).padding(.top, 10)
      }
      Text(query.isEmpty ? (showAll ? "All projects" : "Projects") : "Projects matching “\(query)”")
        .font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
        .padding(.leading, 16).padding(.top, 16).padding(.bottom, 4)
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(shown) { row($0) }
          if !query.isEmpty || showAll {
            action("Add a folder…", icon: "plus", key: "add") { done(); browser.addProject() }
          } else {
            action("All projects", icon: nil, key: "all", shortcut: "⌘P") { showAll = true }
          }
        }.padding(.horizontal, 6)
      }.frame(maxHeight: showAll || !query.isEmpty ? 260 : nil).fixedSize(horizontal: false, vertical: !(showAll || !query.isEmpty))
      footer.padding(.top, 8)
    }
    .frame(width: Self.width)
    .disabled(agent.running)
    .onAppear { searching = true }
    .onKeyPress(.escape) {
      done()
      return .handled
    }
  }

  var search: some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "magnifyingglass", size: 13).foregroundStyle(p.faint)
      TextField("What should it work on?", text: $query).textFieldStyle(.plain).textInputCursor()
        .font(UIStyle.font(13)).focused($searching)
        .onSubmit {
          guard !query.isEmpty, let first = shown.first else { return }
          Self.choose(first, agent: agent, browser: browser)
          done()
        }
        .accessibilityLabel("Find a project")
    }.padding(.horizontal, 14).frame(height: KeelPicker.searchHeight)
      .background(p.hover.opacity(0.6))
  }

  func place(_ place: Place) -> some View {
    let on = places.contains(place)
    let off = place == .page && !pageAvailable
    return Button {
      Self.choose(place, agent: agent)
      if place != .page { done() }
    } label: {
      VStack(spacing: 6) {
        InterfaceIcon(systemName: place.icon, size: 15)
        Text(place.title).font(UIStyle.meta).lineLimit(1)
      }.foregroundStyle(on ? p.ink : off ? p.faint : p.secondary)
        .frame(maxWidth: .infinity).frame(height: 58)
        .background(on ? p.selected : hovered == place.id ? p.hover : p.hover.opacity(0.6),
          in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .contentShape(RoundedRectangle(cornerRadius: UIStyle.rowRadius))
    }.buttonStyle(.pressable).disabled(off).onHover { hovered = $0 ? place.id : nil }
      .help(off ? "Open a page in a regular tab first" : place.help)
      .accessibilityLabel(place.title).accessibilityAddTraits(on ? .isSelected : [])
  }

  func row(_ item: Project) -> some View {
    let on = project == item.id
    return Button {
      Self.choose(item, agent: agent, browser: browser)
      done()
    } label: {
      HStack(spacing: 10) {
        ProjectTile(name: item.name, size: 20)
        Text(item.name).font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let last = last(item) {
          HarnessGlyph(provider: last.provider, size: 10, tinted: true)
          Text(RelativeTimeShort.text(last.date) ?? "").font(UIStyle.microMono).foregroundStyle(p.faint)
            .lineLimit(1).fixedSize().frame(minWidth: UIStyle.wide(40), alignment: .trailing)
        }
      }.padding(.horizontal, 10).frame(height: 34)
        .background(on ? p.selected : hovered == item.id ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .contentShape(Rectangle())
    }.buttonStyle(.pressable).onHover { hovered = $0 ? item.id : nil }
      .help(item.path)
      .accessibilityLabel(item.name).accessibilityAddTraits(on ? .isSelected : [])
  }

  func action(_ title: String, icon: String?, key: String, shortcut: String? = nil, run: @escaping () -> Void) -> some View {
    Button(action: run) {
      HStack(spacing: 10) {
        if let icon { InterfaceIcon(systemName: icon, size: 12).foregroundStyle(p.secondary).frame(width: 20) }
        Text(title).font(UIStyle.body).foregroundStyle(p.secondary)
        Spacer(minLength: 0)
        if let shortcut { Text(shortcut).font(UIStyle.micro).foregroundStyle(p.faint) }
      }.padding(.horizontal, 10).frame(height: 32)
        .background(hovered == key ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .contentShape(Rectangle())
    }.buttonStyle(.pressable).onHover { hovered = $0 ? key : nil }
  }

  /// Things you attach, not places: quieter, on a small step of tone.
  var footer: some View {
    HStack(spacing: 4) {
      footerButton("Attach files", icon: "paperclip", key: "attach") { done(); ComposerDrop.chooseFiles() }
      footerButton("Point at the page", icon: "scope", key: "point") { done(); PagePointer.point(browser: browser) }
      Spacer(minLength: 0)
    }.padding(.horizontal, 6).padding(.vertical, 6)
      .frame(maxWidth: .infinity).background(p.hover.opacity(0.6))
  }
  func footerButton(_ title: String, icon: String, key: String, run: @escaping () -> Void) -> some View {
    Button(action: run) {
      HStack(spacing: 6) {
        InterfaceIcon(systemName: icon, size: 12)
        Text(title).font(UIStyle.meta)
      }.foregroundStyle(hovered == key ? p.ink : p.secondary).padding(.horizontal, 8).frame(height: 28)
        .background(hovered == key ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
        .contentShape(Rectangle())
    }.buttonStyle(.pressable).onHover { hovered = $0 ? key : nil }
  }
}
