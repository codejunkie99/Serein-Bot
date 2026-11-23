import AppKit
import SereinCore
import SwiftUI

/// The assistant inspector: a pane at the trailing edge of the content card (to the right of
/// Serein's chat when Serein is full), Grok's 320 points wide by default and 320–520 by its leading edge.
/// It opens from the assistant's picture at the top of its chat or its name in the header beside,
/// from a sidebar row's info button, or on Working from the header's top-right toggle and the
/// chat's "Working in Scout's computer · Show"; × or Esc closes it. It is the person's own view: no
/// agent tool reads it, and every name and file name in it is shown as plain text.
@MainActor final class AssistantInspector: ObservableObject {
  static let shared = AssistantInspector()
  /// What the pane can show. Tasks and Computer are parts of Activity; a tab saved by an
  /// earlier build under one of those names opens Activity (`tab(for:)`).
  enum Tab: String, CaseIterable, Identifiable {
    case details, library, activity
    var id: String { rawValue }
    var label: String {
      switch self {
      case .details: return "Details"
      case .library: return "Library"
      case .activity: return "Activity"
      }
    }
  }
  static let openKey = "serein.inspector.open"
  static let assistantKey = "serein.inspector.assistant"
  static let widthKey = "serein.inspector.width"
  static let tabsKey = "serein.inspector.tabs"
  static let minWidth: CGFloat = 320
  static let maxWidth: CGFloat = 520
  static let defaultWidth: CGFloat = 320
  /// Opening and closing: the pane appears at once (layout never animates), and only Serein's
  /// hologram glides between the chat's top and the pane's card (`ChatTopHologramView`). None
  /// under Reduce Motion.
  static var moves: Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.42)
  }
  /// Until when a hologram that appears glides from where the last one was: just after the pane
  /// opens or closes, never for a chat switch or a resize.
  private(set) var glideUntil = Date.distantPast
  /// The tabs it shows, each of which works for every assistant in every state (an empty one
  /// says so); Details opens from the settings button instead.
  static let shownTabs: [Tab] = [.activity, .library]
  /// Open or closed, saved with the window (the main window is the only one with Serein).
  @Published private(set) var open: Bool
  @Published private(set) var assistantID: String?
  @Published var width: CGFloat
  /// The tab each assistant showed last.
  @Published private(set) var tabs: [String: String]
  /// Bumped when the person opens it, so the pane takes the keyboard (Esc closes it) without
  /// taking it from the composer when a relaunch restores it.
  @Published private(set) var focusRequest = 0

  init() {
    // Previews and checks start closed at the default width, whatever this Mac saved.
    let defaults = UserDefaults.standard
    let persists = RelayOrchestrator.persists
    open = persists && defaults.bool(forKey: Self.openKey)
    assistantID = persists ? defaults.string(forKey: Self.assistantKey) : nil
    let stored = persists ? defaults.double(forKey: Self.widthKey) : 0
    width = stored > 0 ? min(Self.maxWidth, max(Self.minWidth, CGFloat(stored))) : Self.defaultWidth
    tabs = persists ? (defaults.dictionary(forKey: Self.tabsKey) as? [String: String] ?? [:]) : [:]
  }
  /// The window's room for the page and Serein beside before the pane (ReferenceShell.baseRoom),
  /// kept by the shell. Only `show` reads it, so it is not published (it changes every resize frame).
  var shellRoom: CGFloat = 0
  /// The width the pane takes from that room now: its own, and beside, the gap before its card.
  var room: CGFloat { open && assistantID != nil && SereinSurface.controller != nil ? width + UIStyle.chromeInset : 0 }

  func show(_ id: String, tab: Tab? = nil) {
    if let tab { choose(tab, for: id) }
    // Beside, the pane is its own card after Serein's. When the page, Serein beside and the pane
    // no longer fit together, Serein shows full first (keeping its chat or task), so it stays to
    // the left of the pane instead of being moved out of the way.
    if SereinSurface.main.place == .beside, shellRoom > 0,
      !SereinLayout.fits(compact: false, room: Double(shellRoom - width - UIStyle.chromeInset), minWidth: Double(TaskDock.minWidth))
    {
      SereinRouter.home()
    }
    glideUntil = Date().addingTimeInterval(0.3)
    assistantID = id
    open = true
    focusRequest += 1
    RelayOrchestrator.setSetting(true, forKey: Self.openKey)
    RelayOrchestrator.setSetting(id, forKey: Self.assistantKey)
  }
  /// The mark, the name or the info button again: the pane closes when it shows that assistant,
  /// and otherwise opens on the tab it showed last.
  func toggle(_ id: String) {
    if open, assistantID == id { close() } else { show(id) }
  }
  /// A switch to another assistant (`RelayOrchestrator.switchTo`): an open pane shows the one now
  /// answering, on the tab it showed last, never the one left. A closed pane stays closed.
  func follow(_ id: String) {
    guard open, assistantID != id else { return }
    assistantID = id
    RelayOrchestrator.setSetting(id, forKey: Self.assistantKey)
  }
  func close() {
    guard open else { return }
    glideUntil = Date().addingTimeInterval(0.3)
    open = false
    RelayOrchestrator.setSetting(false, forKey: Self.openKey)
  }
  func tab(for id: String) -> Tab { tabs[id].flatMap(Tab.init(rawValue:)) ?? .activity }
  func choose(_ tab: Tab, for id: String) {
    guard self.tab(for: id) != tab else { return }
    tabs[id] = tab.rawValue
    RelayOrchestrator.setSetting(tabs, forKey: Self.tabsKey)
  }
  func saveWidth() { RelayOrchestrator.setSetting(Double(width), forKey: Self.widthKey) }
}

/// What each assistant produced or holds outside its chats, for the inspector's Library. Every
/// entry names its owners from the record that made it: the assistant whose computer offered a
/// file, the assistant a downloading task worked for (`assistantOwning`), the members of an
/// exported team. The person's own downloads and tasks are never recorded here.
/// The list is kept for this launch only.
@MainActor final class AssistantLibrary: ObservableObject {
  static let shared = AssistantLibrary()
  struct Record: Identifiable, Equatable {
    enum Kind: Equatable { case kept, teamFile }
    let id = UUID()
    let kind: Kind
    let url: URL
    let at: Date
    let owners: [String]
  }
  /// A file from an assistant's computer waiting on its Outbox card.
  struct Offer: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let size: String
    let owner: String
    let thread: String?
    let at = Date()
  }
  static let limit = 200
  @Published private(set) var records: [Record] = []
  @Published private(set) var offers: [Offer] = []

  /// A task download or an Outbox file the person kept in Downloads.
  func kept(_ url: URL, owners: [String]) { add(.kept, url, owners) }
  /// Export Team…: the file the save panel wrote, listed for each member.
  func exported(_ url: URL, owners: [String]) { add(.teamFile, url, owners) }
  private func add(_ kind: Record.Kind, _ url: URL, _ owners: [String]) {
    records.append(Record(kind: kind, url: url, at: Date(), owners: owners))
    if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
  }
  func offered(_ name: String, size: String, owner: String, thread: String?) -> UUID {
    let offer = Offer(name: name, size: size, owner: owner, thread: thread)
    offers.append(offer)
    return offer.id
  }
  func answered(_ id: UUID) { offers.removeAll { $0.id == id } }
}

/// The pane: the Activity · Library tabs (Details from the settings button) with × beside them,
/// then the chosen tab. Who it belongs to shows only on Details, where it is edited; the chat beside it
/// already has the picture and name. A labelled region; Esc closes it while it has the keyboard.
struct InspectorPane: View {
  @ObservedObject var relay: RelayOrchestrator
  let id: String
  let browser: BrowserModel
  /// Inside the content card a 1-point line parts it from the chat or page; beside it is a card.
  var separated = true
  @ObservedObject private var inspector = AssistantInspector.shared
  @FocusState private var focused: Bool
  @Environment(\.palette) var p
  var body: some View {
    Group {
      if let profile = relay.team.profiles.first(where: { $0.id == id }) {
        let tab = inspector.tab(for: profile.id)
        VStack(spacing: 0) {
          // Settings and × in circles at the corners, as Grok's: nothing else competes with the picture and name.
          HStack {
            InspectorCircleButton(
              systemName: "gearshape", help: "\(profile.name)'s settings", label: "\(profile.name)'s settings",
              on: tab == .details, iconOpacity: 0.7
            ) { inspector.choose(tab == .details ? .activity : .details, for: profile.id) }
            Spacer()
            InspectorCircleButton(systemName: "xmark", help: "Close · Esc", label: "Close \(profile.name)'s details", iconOpacity: 0.92) {
              inspector.close()
            }
          }.padding(12).frame(height: 60)
          InspectorFace(relay: relay, profile: profile).padding(.top, 8).padding(.bottom, 12)
          if tab != .details {
            InspectorTabs(profile: profile).padding(.top, 4).padding(.bottom, 10)
          }
          ScrollView {
            Group {
              switch tab {
              case .details:
                VStack(alignment: .leading, spacing: 12) {
                  SettingsBackLink(title: "Activity") { inspector.choose(.activity, for: profile.id) }
                  if let group = relay.activeTeam, profile.id == relay.team.activeID {
                    InspectorTeam(relay: relay, group: group)
                  } else {
                    InspectorSettings(relay: relay, profile: profile)
                  }
                }
              case .library: InspectorLibrary(relay: relay, profile: profile)
              case .activity: InspectorActivity(relay: relay, profile: profile)
              }
            }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
          }.scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.name)'s details")
        // One assistant's open label field or tab state never carries over to another.
        .id(profile.id)
      } else {
        // The assistant was deleted: nothing of it is left to show.
        Color.clear.onAppear { DispatchQueue.main.async { inspector.close() } }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(p.background)
    .overlay(alignment: .leading) { if separated { Rectangle().fill(p.hairline).frame(width: 0.5) } }
    .focusable().focused($focused).focusEffectDisabled()
    .onExitCommand { inspector.close() }
    .onChange(of: inspector.focusRequest, initial: true) { _, request in if request > 0 { focused = true } }
  }
}

/// The label under the name, edited in place: Return saves it through the team journal (its toast
/// has Undo), Esc or leaving the field cancels. At most 40 characters of one line of plain text.
private struct InspectorLabel: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  var font: Font = UIStyle.meta
  @State private var editing = false
  @State private var draft = ""
  @State private var error: String?
  @FocusState private var focused: Bool
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if editing {
        TextField("Add a label", text: $draft).textFieldStyle(.plain).font(font).foregroundStyle(p.ink)
          .padding(.horizontal, 4).frame(height: UIStyle.wide(20))
          .background(p.hover, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius, style: .continuous))
          .focused($focused)
          .onSubmit(save)
          .onExitCommand(perform: cancel)
          .onChange(of: draft) { _, value in
            if value.count > RelayProfile.labelLimit { draft = String(value.prefix(RelayProfile.labelLimit)) }
            error = nil
          }
          .onChange(of: focused) { _, now in if !now, error == nil { cancel() } }
          .onAppear { focused = true }
          .accessibilityLabel("Label for \(profile.name)")
        if let error { Text(error).font(UIStyle.micro).foregroundStyle(p.danger) }
      } else if let label = profile.label {
        Button { start(label) } label: {
          Text(verbatim: label).font(font).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        }.buttonStyle(.pressable).help("Edit the label")
          .accessibilityLabel("Label: \(label)").accessibilityHint("Edits the label")
      } else {
        Button("Add a label") { start("") }.buttonStyle(.pressable).font(UIStyle.metaStrong).foregroundStyle(p.accent)
          .help("A short label under \(profile.name)'s name, like Bookkeeping")
      }
    }
  }
  private func start(_ text: String) {
    draft = text
    error = nil
    editing = true
  }
  private func save() {
    if let refusal = relay.setLabel(profile.id, draft) {
      error = refusal
      return
    }
    editing = false
  }
  private func cancel() {
    error = nil
    editing = false
  }
}

/// Activity · Library as Grok's `.segmented`: no track, only the chosen pill filled; VoiceOver reads
/// them as one segmented control.
private struct InspectorTabs: View {
  let profile: RelayProfile
  @ObservedObject private var inspector = AssistantInspector.shared
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  var body: some View {
    let chosen: AssistantInspector.Tab = inspector.tab(for: profile.id)
    HStack(spacing: 2) {
      ForEach(AssistantInspector.shownTabs) { tab in
        Button { choose(tab) } label: {
          InspectorTabLabel(title: tab.label, chosen: chosen == tab)
        }.buttonStyle(.pressable)
      }
    }.frame(maxWidth: .infinity).padding(.horizontal, 16)
      .accessibilityRepresentation {
        Picker("\(profile.name)'s sections", selection: Binding(get: { chosen }, set: { choose($0) })) {
          ForEach(AssistantInspector.shownTabs) { Text($0.label).tag($0) }
        }.pickerStyle(.segmented)
      }
  }
  private func choose(_ tab: AssistantInspector.Tab) {
    withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.2)) {
      inspector.choose(tab, for: profile.id)
    }
  }
}

/// One segment: 13 on 18, 4 by 8 padding; `secondary`, `ink` under the pointer and when chosen.
private struct InspectorTabLabel: View {
  let title: String
  let chosen: Bool
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    Text(title).font(UIStyle.font(13)).tracking(0.195).lineLimit(1).fixedSize()
      .foregroundStyle(chosen || hovered ? p.ink : p.secondary)
      .padding(.horizontal, 8).frame(height: 26)
      .background(chosen ? p.track : .clear, in: Capsule())
      .contentShape(Capsule())
      .onHover { hovered = $0 }
  }
}

/// Details: the assistant's own page from Settings › Assistants under the pane's header (so
/// without its own): AI app and model, What it does, Apps, Routines, Memory and the rest. A row's
/// sub-page opens here with a back link; a link to another Settings page opens Settings.
private struct InspectorSettings: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @State private var sub: [String] = []
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !sub.isEmpty { SettingsBackLink(title: profile.name) { sub.removeLast() } }
      AssistantSettingsPage(relay: relay, profileID: profile.id, header: false)
    }
    .environment(\.settingsNavigation, SettingsNavigation(
      path: [profile.id] + sub,
      push: { sub.append($0) },
      pop: { _ = sub.popLast() },
      go: { path in
        if path.first == profile.id {
          sub = Array(path.dropFirst())
        } else {
          RelayController.shared?.openSettings(SettingsCategory.request("Relay", path: path))
        }
      }))
  }
}

/// Everything the assistant produced or holds, newest first: its tasks' downloads waiting on the
/// shelf (Keep / Delete, TaskShelf's own paths), files from its computer waiting on their Outbox
/// card, files kept from either, its task recordings and the team files exported with it. Only
/// what an existing record says it owns; nothing here sends a file anywhere.
private struct InspectorLibrary: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @ObservedObject private var shelf = TaskShelf.shared
  @ObservedObject private var library = AssistantLibrary.shared
  @ObservedObject private var recordings = TaskRecordings.shared
  @Environment(\.palette) var p
  enum Kind {
    case download(TaskShelf.File)
    case outbox(AssistantLibrary.Offer)
    case kept(URL)
    case recording(URL)
    case teamFile(URL)
  }
  struct Item: Identifiable {
    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let at: Date
  }
  private static func when(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
  private var items: [Item] {
    let id = profile.id
    let owns: (String) -> Bool = { [relay] thread in relay.assistantOwning(thread: thread) == id }
    let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    var out: [Item] = shelf.files.filter { owns($0.thread) }.map {
      Item(id: "download:" + $0.id, kind: .download($0), name: $0.name, detail: "On the shelf · " + $0.detail, at: $0.at)
    }
    out += library.offers.filter { $0.owner == id }.map {
      Item(id: "outbox:" + $0.id.uuidString, kind: .outbox($0), name: $0.name,
           detail: "From its computer · \($0.size) · waiting for your answer", at: $0.at)
    }
    out += library.records.filter { $0.owners.contains(id) && exists($0.url) }.map {
      Item(id: "record:" + $0.id.uuidString, kind: $0.kind == .kept ? .kept($0.url) : .teamFile($0.url),
           name: $0.url.lastPathComponent,
           detail: ($0.kind == .kept ? "Kept in Downloads · " : "Exported team file · ") + Self.when($0.at), at: $0.at)
    }
    out += recordings.recordings.compactMap { recording -> Item? in
      // The owner it began with; one an earlier build recorded falls back to its thread's owner now.
      guard let ended = recording.endedAt, (recording.owner ?? (owns(recording.thread) ? id : nil)) == id,
        let file = recordings.file(recording), exists(file)
      else { return nil }
      return Item(id: "recording:" + recording.id, kind: .recording(file), name: ChatExport.movieName("task", at: recording.startedAt),
                  detail: "Task recording · " + Self.when(ended), at: ended)
    }
    return out.sorted { $0.at > $1.at }
  }
  enum Filter: String, CaseIterable, Identifiable {
    case all = "All", media = "Media", files = "Files"
    var id: String { rawValue }
    func keeps(_ kind: Kind) -> Bool {
      if case .recording = kind { return self != .files }
      return self != .media
    }
  }
  @State private var filter = Filter.all
  /// Today, This week and Earlier, newest first, leaving out empty groups.
  private static func groups(_ items: [Item]) -> [(title: String, items: [Item])] {
    let calendar = Calendar.current
    let week = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date())) ?? .distantPast
    let today = items.filter { calendar.isDateInToday($0.at) }
    let thisWeek = items.filter { !calendar.isDateInToday($0.at) && $0.at >= week }
    let earlier = items.filter { $0.at < week }
    return [("Today", today), ("This week", thisWeek), ("Earlier", earlier)].filter { !$0.1.isEmpty }
  }
  var body: some View {
    let items = items.filter { filter.keeps($0.kind) }
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 6) {
        ForEach(Filter.allCases) { chip in
          Button { filter = chip } label: {
            Text(chip.rawValue).font(UIStyle.font(12)).foregroundStyle(filter == chip ? p.ink : p.secondary)
              .padding(.horizontal, 10).frame(height: 24)
              .background(filter == chip ? p.selected : .clear, in: Capsule())
              .overlay(Capsule().strokeBorder(p.line, lineWidth: filter == chip ? 0 : 1))
              .contentShape(Capsule())
          }.buttonStyle(.pressable).accessibilityAddTraits(filter == chip ? .isSelected : [])
        }
      }.padding(.horizontal, 12)
      if items.isEmpty {
        Text(verbatim: filter == .all
          ? "Nothing here yet. Files \(profile.name)\u{2019}s tasks download, files from its computer and its task recordings show here."
          : "Nothing in \(filter.rawValue) yet.")
          .font(UIStyle.font(13)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12)
      }
      ForEach(Self.groups(items), id: \.title) { group in
        InspectorSection(title: group.title) {
          InspectorShowMore(items: group.items) { row($0) }
        }
      }
      Text("Everything here stays on this Mac. A file leaves Serein\u{2019}s computer only through the Outbox card in the chat.")
        .font(UIStyle.micro).foregroundStyle(p.faint).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
    }
  }
  private func row(_ item: Item) -> some View {
    HStack(spacing: 10) {
      InterfaceIcon(systemName: icon(item.kind), size: 13).foregroundStyle(p.secondary)
        .frame(width: 28, height: 28)
        .background(p.track, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        // File names come from sites, computers and the person: shown as they are, never read as markup.
        Text(verbatim: item.name).font(UIStyle.font(13)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
        Text(verbatim: item.detail).font(UIStyle.font(12)).foregroundStyle(p.faint).lineLimit(1)
      }.accessibilityElement(children: .combine)
      Spacer(minLength: 4)
      actions(item)
    }.padding(.horizontal, 8).padding(.vertical, 6)
  }
  private func finder(_ url: URL, _ name: String) -> some View {
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(QuietButton())
      .accessibilityLabel("Show \(name) in Finder")
  }
  private func icon(_ kind: Kind) -> String {
    switch kind {
    case .download: return "doc"
    case .outbox: return "desktopcomputer"
    case .kept: return "arrow.down.circle"
    case .recording: return "film"
    case .teamFile: return "person.2"
    }
  }
  @ViewBuilder private func actions(_ item: Item) -> some View {
    switch item.kind {
    case .download(let file):
      if file.state == .ready {
        Button("Keep") { shelf.keep(file.id) }.buttonStyle(QuietButton())
          .help("Move to your Downloads folder").accessibilityLabel("Keep \(file.name)")
      }
      Button("Delete") { shelf.delete(file.id) }.buttonStyle(QuietButton())
        .help(file.state == .ready ? "Delete this file" : "Stop and delete this download").accessibilityLabel("Delete \(file.name)")
    case .outbox(let offer):
      if let thread = offer.thread {
        Button("Show") { SereinRouter.open(threadID: thread) }.buttonStyle(QuietButton())
          .help("Show its Outbox card in the chat").accessibilityLabel("Show the Outbox card for \(offer.name)")
      }
    case .kept(let url):
      finder(url, item.name)
    case .teamFile(let url):
      finder(url, item.name)
    case .recording(let url):
      Button("Open") { _ = NSWorkspace.shared.open(url) }.buttonStyle(QuietButton())
        .help("Watch the recording on this Mac").accessibilityLabel("Open \(item.name)")
    }
  }
}

/// The assistant's computer: the live screen (ComputerPanel, with Watch, Take over, Hand back,
/// Pause and ⤢) while it runs; asleep, its mark and Wake, which only starts it; with no computer
/// (the switch off, or the assistant may not use it), one line and the way to turn it on.
private struct InspectorComputer: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @ObservedObject private var host = ComputerHost.shared
  @GateStorage(ComputerPolicy.enabledKey) private var enabled = false
  @Environment(\.palette) var p
  var body: some View {
    if !enabled {
      noComputer("\(profile.name) has no computer: Serein's computer is off.") {
        Button("Turn on Serein's computer") { TeamSheets.openSettings(TeamSheets.settingsPage(.computer)) }
          .buttonStyle(PrimaryButton())
      }
    } else if relay.placeRefusal(.computer, for: profile) != nil {
      noComputer("\(profile.name) can't use Serein's computer. Turn it on in \(profile.name)'s Apps it can use.") {
        Button { AssistantSettingsKey.open(profile.id, to: AssistantSettingsKey.apps) } label: {
          Text(verbatim: "\(profile.name)'s apps…")
        }
          .buttonStyle(QuietButton())
          .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      }
    } else if let computer = host.computers[profile.id] {
      InspectorComputerState(computer: computer, name: profile.name)
    } else {
      // Its record is made once the tab appears, never while the view is drawn (ComputerList's rule).
      Color.clear.frame(height: 1).onAppear { _ = host.computer(for: profile.id) }
    }
  }
  private func noComputer<B: View>(_ line: String, @ViewBuilder button: () -> B) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(line).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      button()
    }.accessibilityElement(children: .contain).accessibilityLabel("\(profile.name)'s computer").accessibilityValue("None")
  }
}
private struct InspectorComputerState: View {
  @ObservedObject var computer: ComputerHost.Computer
  let name: String
  @ObservedObject private var host = ComputerHost.shared
  @ObservedObject private var image = BuiltInImage.shared
  @ObservedObject private var network = NetworkMonitor.shared
  @GateStorage(ComputerPolicy.autoSetUpKey) private var autoSetUp = false
  @Environment(\.palette) var p
  private var awake: Bool { computer.state == .running || computer.state == .starting }
  private var needsSetup: Bool { computer.place == .builtIn && !host.ready(computer) }
  private var problem: String? {
    if case .error(let words) = computer.state { return words }
    return nil
  }
  private var preparesAutomatically: Bool {
    computer.place == .macOS && computer.id == RelayTeam.mainID && autoSetUp
      && ComputerPolicy.isEnabled() && !host.ready(computer) && problem == nil
  }
  private var wakeTitle: String {
    if problem != nil { return "Try again" }
    if computer.place == .macOS && !host.ready(computer) { return "Continue setup" }
    return needsSetup ? "Set up and open" : "Wake"
  }
  /// What VoiceOver reads for the computer: its state and who has control.
  private var spoken: String {
    if needsSetup { return image.working ? "Setting up" : "Not set up" }
    guard awake else { return "Asleep" }
    let state = computer.place == .macOS && computer.macSetup != .ready ? "Setting up" : computer.state.label
    switch computer.control {
    case .assistant: return state + ", \(name) is working in it"
    case .pending: return state + ", taking over after this step"
    case .person: return state + ", you have control"
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      state
      if computer.place == .builtIn, !awake {
        Button("Use macOS instead") {
          Task {
            if await host.useVirtualMac(computer) { await host.resume(computer) }
          }
        }.buttonStyle(QuietButton()).help("Start a real virtual Mac; the Linux disk is kept")
      }
    }
    .task {
      // Opening Activity shows an already configured Mac directly. Pausing it later does not
      // restart it: this runs only when the view appears, not on every state change.
      if computer.place == .macOS, host.ready(computer),
        computer.state == .none || computer.state == .paused || computer.state == .stopped {
        await host.resume(computer)
      }
    }
  }
  private var state: some View {
    Group {
      if computer.place == .macOS, host.ready(computer) {
        ComputerPanel(computer: computer, inWindow: false)
      } else if preparesAutomatically && !awake {
        VStack(spacing: 12) {
          ProgressView().controlSize(.small)
          Text("Preparing a Mac for \(name)").font(UIStyle.bodyStrong).foregroundStyle(p.ink)
          Text(!network.known ? "Checking the connection…" : !network.online ? "Waiting for an internet connection." : network.metered ? "Waiting for a connection without a data limit." : "macOS downloads and installs automatically. The desktop will open when it is ready.")
            .font(UIStyle.meta).foregroundStyle(p.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
      } else if needsSetup && image.working {
        VStack(spacing: 12) {
          Text("Setting up \(name)'s computer").font(UIStyle.bodyStrong).foregroundStyle(p.ink)
          if let fraction = image.fraction {
            ProgressView(value: fraction).progressViewStyle(.linear).tint(p.accent)
              .accessibilityLabel("Download progress")
          } else {
            ProgressView().controlSize(.small)
          }
          Text("Preparing its desktop. This only happens once and may take a few minutes.")
            .font(UIStyle.meta).foregroundStyle(p.secondary).multilineTextAlignment(.center)
          Button("Cancel") { image.cancel() }.buttonStyle(QuietButton())
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
      } else if awake {
        ComputerPanel(computer: computer, inWindow: false)
      } else {
        VStack(spacing: 10) {
          InterfaceIcon(systemName: "desktopcomputer", size: 28).foregroundStyle(p.secondary).accessibilityHidden(true)
          Text(verbatim: computer.place == .macOS && !host.ready(computer) ? "A Mac for \(name)" : needsSetup ? "Set up \(name)'s computer" : "\(name)'s computer is asleep")
            .font(UIStyle.bodyStrong).foregroundStyle(p.ink)
          if needsSetup {
            Text("It sets itself up when \(name) needs it. You can open it now.")
              .font(UIStyle.meta).foregroundStyle(p.secondary).multilineTextAlignment(.center)
            Text(VirtualMachinePolicy.sizeLine).font(UIStyle.micro).foregroundStyle(p.secondary)
          }
          if computer.place == .macOS, !host.ready(computer) {
            Text("Serein downloads macOS and prepares its own account automatically.")
              .font(UIStyle.meta).foregroundStyle(p.secondary).multilineTextAlignment(.center)
          }
          if let problem {
            Text(verbatim: problem).font(UIStyle.micro).foregroundStyle(p.warning).multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          // A Throwaway reset can leave it off with tasks still in line.
          ComputerQueueLines(computer: computer)
          // Wake starts the computer and its desktop; nothing runs inside until the assistant works there.
          Button(wakeTitle) { Task { await host.resume(computer) } }.buttonStyle(PrimaryButton())
            .help("Start \(name)'s computer. It runs nothing until \(name) uses it.")
            .accessibilityLabel("\(wakeTitle) \(name)'s computer")
          if let notice = host.notice, notice != problem {
            Text(verbatim: notice).font(UIStyle.micro).foregroundStyle(p.secondary).multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
        }.frame(maxWidth: .infinity)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(name)'s computer")
    .accessibilityValue(spoken)
  }
}

/// The info button a sidebar assistant row shows on hover: opens (or closes) its inspector.
struct InspectorInfoButton: View {
  let id: String
  let name: String
  @Environment(\.palette) var p
  var body: some View {
    Button { AssistantInspector.shared.toggle(id) } label: {
      InterfaceIcon(systemName: "info.circle", size: 12).foregroundStyle(p.secondary).frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }.modifier(HeaderIconStyle(side: true)).help("Show \(name)'s details").accessibilityLabel("Show \(name)'s details")
  }
}

/// The top of the sidebar, as a contact card: the assistant's picture centred, then "Name · label"
/// on one line. Serein's is a card (affectUI's Profile Menu card): its live hologram, which leaves
/// the chat's top while this shows it, its state in words and Customise. Pressing the hologram
/// customises too (`RelayLookSheet`); while the sheet is open the hologram is in its preview and
/// the drawn mark here, so it stays in one place at a time.
private struct InspectorFace: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  /// `--ui-avatar-customise`: the sheet open on its preview choice.
  @State private var customising = CommandLine.arguments.contains("--ui-avatar-customise")
  @Environment(\.palette) var p
  @Environment(\.sereinReducedEffects) private var reducedEffects
  private static let side: CGFloat = 64
  private var isSerein: Bool { profile.id == relay.team.main?.id && relay.activeTeam == nil }
  var body: some View {
    let state: RelayLook.State = RelayPanelView.avatarState(relay: relay, listening: false, speaking: false)
    VStack(spacing: isSerein ? 12 : 16) {
      Group {
        if isSerein, customising {
          SereinHologramMark(size: Self.side * 0.72, turning: relay.working)
        } else if isSerein {
          ChatTopHologramView(
            state: state, relay: relay, paused: false, needsYou: false, open: { customising = true },
            help: "Customise \(profile.name)", glides: true)
        } else {
          AssistantLiveMark(relay: relay, profile: profile, size: Self.side)
        }
      }
      .frame(width: Self.side, height: Self.side)
      VStack(spacing: 2) {
        HStack(spacing: 0) {
          Text(verbatim: profile.name).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
          if profile.label != nil {
            Text(verbatim: " · ").foregroundStyle(p.secondary).accessibilityHidden(true)
            InspectorLabel(relay: relay, profile: profile, font: UIStyle.font(17, weight: .medium))
          }
        }
        .font(UIStyle.font(17, weight: .medium)).tracking(0.17).lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, 10).frame(height: 28).padding(.horizontal, isSerein ? 0 : 16)
        if isSerein {
          Text(state.title).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
        }
      }
      if isSerein {
        Button("Customise") { customising = true }.buttonStyle(QuietButton(bordered: true))
          .help("Choose \(profile.name)\u{2019}s colour and look")
          .accessibilityHint("Opens \(profile.name)\u{2019}s colours and looks")
      }
    }
    .padding(isSerein ? 16 : 0)
    .frame(maxWidth: .infinity)
    .background {
      if isSerein {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.panel)
          .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.hairline, lineWidth: 0.5))
      }
    }
    .padding(.horizontal, isSerein ? 16 : 0)
    .sheet(isPresented: $customising) {
      RelayLookSheet(relay: relay, worn: relay.look, name: profile.name) { customising = false }
        .environment(\.palette, p).environment(\.sereinReducedEffects, reducedEffects)
    }
  }
}

/// Activity: its tasks, what is coming up, its computer and voice chat, each a labelled card.
private struct InspectorActivity: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      if profile.id == relay.team.main?.id { InspectorTasks(relay: relay) }
      InspectorUpcoming(relay: relay, profile: profile)
      InspectorComputerSection(relay: relay, profile: profile)
      InspectorVoice()
    }
  }
}

/// A 13-point label over a rounded card of rows, with an optional link at the label's end.
struct InspectorSection<Content: View>: View {
  let title: String
  var link: (title: String, action: () -> Void)? = nil
  @ViewBuilder var content: Content
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title).font(UIStyle.font(13)).tracking(0.195).foregroundStyle(p.secondary).accessibilityAddTraits(.isHeader)
        Spacer()
        if let link {
          Button(link.title, action: link.action).buttonStyle(.pressable).font(UIStyle.font(12)).foregroundStyle(p.secondary)
        }
      }.padding(.horizontal, 12)
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.hairline, lineWidth: UIStyle.hairline))
    }.accessibilityElement(children: .contain)
  }
}

/// A row inside an inspector card: rounded, lit on hover.
struct InspectorRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
  private struct Row: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.palette) private var p
    var body: some View {
      configuration.label
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          configuration.isPressed ? p.selected : hovered && enabled ? p.hover : .clear,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovered = $0 }
    }
  }
}

/// The first five rows, then "Show more" for the rest.
struct InspectorShowMore<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder var row: (Item) -> Row
  static var limit: Int { 5 }
  @State private var all = false
  @Environment(\.palette) var p
  var body: some View {
    ForEach(all ? items : Array(items.prefix(Self.limit))) { row($0) }
    if items.count > Self.limit {
      Button { all.toggle() } label: {
        Text(all ? "Show less" : "Show more").font(UIStyle.font(13)).foregroundStyle(p.secondary)
      }.buttonStyle(InspectorRowStyle())
    }
  }
}

/// Settings or × in Grok's bordered 36-point circle (`.icon-btn--bordered`) at the pane's top corners.
private struct InspectorCircleButton: View {
  let systemName: String
  let help: String
  let label: String
  var on = false
  var iconOpacity: Double = 0.66
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    Button(action: action) {
      InterfaceIcon(systemName: systemName, size: 16).foregroundStyle(p.ink).opacity(iconOpacity)
        .frame(width: 36, height: 36)
        .background(Circle().fill(p.panel).overlay(Circle().fill(on ? p.selected : hovered ? p.hover : .clear)))
        .overlay(Circle().strokeBorder(p.hairline, lineWidth: 1))
        .contentShape(Circle())
    }.buttonStyle(.pressable).onHover { hovered = $0 }.help(help).accessibilityLabel(label)
  }
}

/// Upcoming: the assistant's routines and reminders by next run, each with its switch.
private struct InspectorUpcoming: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @Environment(\.palette) var p
  var body: some View {
    let routines = relay.reminders.filter { $0.profileID == profile.id }
      .sorted { ($0.paused == true ? 1 : 0, $0.due) < ($1.paused == true ? 1 : 0, $1.due) }
    InspectorSection(title: "Upcoming", link: ("Manage", { AssistantSettingsKey.open(profile.id, to: AssistantSettingsKey.routines) })) {
      if routines.isEmpty {
        Text(verbatim: "Nothing scheduled. Ask \(profile.name) in the chat, like \u{201C}every morning at 9, sum up my inbox.\u{201D}")
          .font(UIStyle.font(13)).foregroundStyle(p.faint).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 8).padding(.vertical, 10)
      }
      InspectorShowMore(items: routines) { routine in
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "clock", size: 16).foregroundStyle(p.secondary).frame(width: 20, height: 20)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            // Routine words come from the person and the assistant: shown as they are.
            Text(verbatim: routine.text).font(UIStyle.font(13)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
            Text(verbatim: routine.paused == true ? "Paused" : Self.when(routine.due))
              .font(UIStyle.font(12)).foregroundStyle(p.faint).lineLimit(1)
          }
          Spacer(minLength: 8)
          if !TodoBoard.isReminder(routine.id) {
            Toggle("", isOn: Binding(get: { routine.paused != true }, set: { relay.setRoutineOn(id: routine.id, on: $0) }))
              .toggleStyle(SereinSwitchStyle(labeled: false))
              .accessibilityLabel(routine.text)
          }
        }
        .padding(.horizontal, 8).frame(minHeight: 44)
        .accessibilityElement(children: .combine)
      }
    }
  }
  private static func when(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return "Today " + time }
    if calendar.isDateInTomorrow(date) { return "Tomorrow " + time }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " " + time
  }
}

/// Computer: one row with its screen's thumbnail and state. Pressing it, or the computer being in
/// use, opens the computer's own controls under the card.
private struct InspectorComputerSection: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  @ObservedObject private var host = ComputerHost.shared
  @GateStorage(ComputerPolicy.enabledKey) private var enabled = false
  @State private var open = false
  @Environment(\.palette) var p
  var body: some View {
    let computer = host.computers[profile.id]
    VStack(alignment: .leading, spacing: 12) {
      InspectorSection(title: "Computer") {
        HStack(spacing: 4) {
          Button { open.toggle() } label: {
            HStack(spacing: 10) {
              thumbnail(computer?.screen)
              VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: profile.id == relay.team.main?.id ? "Serein\u{2019}s computer" : "\(profile.name)\u{2019}s computer")
                  .font(UIStyle.font(13)).foregroundStyle(p.ink).lineLimit(1)
                Text(status(computer)).font(UIStyle.font(12)).tracking(0.12).foregroundStyle(p.faint).lineLimit(1)
              }
              Spacer(minLength: 8)
            }.frame(minHeight: 40)
          }.buttonStyle(InspectorRowStyle()).disabled(!enabled).accessibilityElement(children: .combine)
            .accessibilityHint(open ? "Hides its controls" : "Shows its controls")
          // The same switch as Settings › Computer: on for every assistant allowed to use it.
          Toggle("Serein\u{2019}s computer", isOn: $enabled).toggleStyle(SereinSwitchStyle(labeled: false))
            .padding(.trailing, 8)
            .help(enabled ? "Turn off Serein\u{2019}s computer" : "Turn on Serein\u{2019}s computer")
            .accessibilityLabel("Serein\u{2019}s computer")
        }
      }
      if open && enabled {
        InspectorComputer(relay: relay, profile: profile)
      } else if let computer {
        InspectorComputerWhenInUse(computer: computer) { InspectorComputer(relay: relay, profile: profile) }
      }
    }
    .onChange(of: enabled, initial: true) { _, on in
      if on, host.computers[profile.id] == nil, relay.placeRefusal(.computer, for: profile) == nil { _ = host.computer(for: profile.id) }
    }
  }
  private func thumbnail(_ screen: NSImage?) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.track)
      if let screen {
        Image(nsImage: screen).resizable().aspectRatio(contentMode: .fill)
      } else {
        InterfaceIcon(systemName: "desktopcomputer", size: 14).foregroundStyle(p.faint)
      }
    }
    .frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(p.hairline, lineWidth: UIStyle.hairline))
    .accessibilityHidden(true)
  }
  private func status(_ computer: ComputerHost.Computer?) -> String {
    guard enabled else { return "Off" }
    if relay.placeRefusal(.computer, for: profile) != nil { return "Not allowed" }
    guard let computer else { return "Asleep" }
    if computer.place == .macOS, !host.ready(computer) { return "Setting up\u{2026}" }
    switch computer.state {
    case .running: return computer.control == .person ? "Awake \u{00B7} you have control" : "Awake"
    case .starting: return "Waking up\u{2026}"
    case .error: return "Unreachable"
    default: return "Asleep"
    }
  }
}

/// Voice chat: who reads replies aloud (this Mac, Grok or ChatGPT, with the person's key), the
/// language Serein listens in, and whether it reads replies aloud.
private struct InspectorVoice: View {
  @AppStorage(TalkLanguage.defaultsKey) private var language = TalkLanguage.system
  @AppStorage(RelayController.speakKey) private var speak = false
  @AppStorage(VoiceProvider.defaultsKey) private var providerID = VoiceProvider.mac.rawValue
  @AppStorage(VoiceProvider.voiceKey) private var voiceID = ""
  @State private var languages: [TalkLanguage.Choice] = []
  @State private var keySaved = false
  @State private var key = ""
  @Environment(\.palette) var p
  private var provider: VoiceProvider { VoiceProvider(rawValue: providerID) ?? .mac }
  private var voiceTitle: String {
    provider == .mac ? "This Mac" : "\(VoiceProvider.voice(for: provider).capitalized) \u{00B7} \(provider.title)"
  }
  var body: some View {
    InspectorSection(title: "Voice chat") {
      row("Voice") {
        HStack(spacing: 4) {
          voiceMenu
          Button("Preview") { preview() }.buttonStyle(.pressable)
            .font(UIStyle.font(12)).foregroundStyle(p.secondary).padding(.horizontal, 8).frame(height: 24)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Hear this voice").accessibilityLabel("Hear this voice")
        }
      }
      if provider != .mac && !keySaved { keyRow }
      row("Language") {
        Menu {
          Picker("Language", selection: $language) {
            ForEach(languages) { Text($0.title).tag($0.id) }
          }.pickerStyle(.inline).labelsHidden()
        } label: {
          pill(languages.first { $0.id == language }?.title ?? "Automatic")
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(languages.isEmpty)
          .accessibilityLabel("Language")
      }
      row("Read replies aloud") {
        Toggle("Read replies aloud", isOn: $speak).toggleStyle(SereinSwitchStyle(labeled: false))
      }
    }
    .task { languages = TalkLanguageSupport.choices() }
    .onChange(of: providerID, initial: true) { _, _ in keySaved = provider.hasKey; key = "" }
  }
  private var voiceMenu: some View {
    Menu {
      Picker("Voice", selection: Binding(
        get: { provider == .mac ? "mac" : "\(provider.rawValue):\(VoiceProvider.voice(for: provider))" },
        set: { pick in
          let parts = pick.split(separator: ":").map(String.init)
          providerID = parts[0]
          voiceID = parts.count > 1 ? parts[1] : ""
        })
      ) {
        Text("This Mac").tag("mac")
        ForEach([VoiceProvider.grok, .openai]) { cloud in
          Section(cloud.title) {
            ForEach(cloud.voices, id: \.self) { Text($0.capitalized).tag("\(cloud.rawValue):\($0)") }
          }
        }
      }.pickerStyle(.inline).labelsHidden()
      if provider != .mac && keySaved {
        Divider()
        Button("Remove \(provider.keyName)") {
          provider.keychain.replace(with: nil)
          keySaved = false
        }
      }
    } label: {
      pill(voiceTitle)
    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Voice, \(voiceTitle)")
  }
  /// The key goes straight to the Keychain; the field empties on save.
  private var keyRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        SecureField(provider.keyName, text: $key, prompt: Text(provider.keyName))
          .textFieldStyle(.plain).font(UIStyle.font(12)).foregroundStyle(p.ink)
          .padding(.horizontal, 8).frame(height: 26)
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.line, lineWidth: 1))
          .onSubmit(save)
        Button("Save", action: save).buttonStyle(QuietButton()).controlSize(.small)
          .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      HStack(spacing: 4) {
        Text(verbatim: "Kept in this Mac\u{2019}s Keychain. Replies go to \(provider.company) to be read.")
          .font(UIStyle.font(12)).foregroundStyle(p.faint).fixedSize(horizontal: false, vertical: true)
        if let page = provider.keyPage {
          Link("Get a key", destination: page).font(UIStyle.font(12)).foregroundStyle(p.secondary)
        }
      }
    }.padding(.horizontal, 8).padding(.vertical, 6)
  }
  private func save() {
    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, provider.keychain.replace(with: value) else { return }
    key = ""
    keySaved = true
    preview()
  }
  private func preview() { RelayController.shared?.speak("Hi, I\u{2019}m Serein. This is how I\u{2019}ll sound.") }
  private func pill(_ title: String) -> some View {
    HStack(spacing: 4) {
      Text(verbatim: title).font(UIStyle.font(13)).foregroundStyle(p.ink).lineLimit(1)
      InterfaceIcon(systemName: "chevron.down", size: 10).foregroundStyle(p.secondary).opacity(0.66)
    }.padding(.leading, 6).padding(.trailing, 4).frame(height: 24)
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.hairline, lineWidth: 1))
      .contentShape(Rectangle())
  }
  private func row<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
    HStack(spacing: 8) {
      Text(title).font(UIStyle.font(13)).foregroundStyle(p.ink)
      Spacer(minLength: 8)
      control()
    }.padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: 30)
  }
}

/// The computer while there is something to see or do: a task holds it, waits for it or it is
/// busy; the person has control; it is on (its live screen); or its setup needs the person (Restart
/// Serein's Mac, Continue setup). Asleep or off with nothing waiting, it stays out of the way.
private struct InspectorComputerWhenInUse<Content: View>: View {
  @ObservedObject var computer: ComputerHost.Computer
  @ViewBuilder var content: Content
  private var inUse: Bool {
    computer.holder != nil || computer.busy || !computer.queue.isEmpty || computer.control == .person
  }
  var body: some View {
    if inUse || computer.state == .running || computer.macSetup.needsPerson { content }
  }
}
