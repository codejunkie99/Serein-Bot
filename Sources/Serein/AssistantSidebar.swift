import AppKit
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// Assistants mode in the sidebar (SPEC.md 2.2, board 12): under the Tabs | Assistants switch,
/// Serein's own row first (a list row like every other, outside the sections), then the pinned
/// faces in a grid in pin order (Serein can be pinned too), then every other assistant in
/// automatic sections (Needs you, Working, Quiet), the quiet "{N} hidden · Show" row, New
/// assistant and, until two are made, the hint. Team headers left the list; teams stay as data
/// and their chats open from the header's picker. Rows are the boards' (`avatar-list-row`: face,
/// status dot, name, status words, chevron; `AssistantListRowStyle`) and share the raised pill's
/// namespace with the tab rows. One click opens an assistant's details card under its row; a
/// right-click or the row's "…" opens its menu (`AssistantRowMenu`). The list holds still while
/// the pointer or the keyboard is in it, during a drag and for 2 seconds after a switch. The
/// states come from `RelayOrchestrator.assistantStatus`, the pins and hidden rows from
/// `AssistantRowState`; every roster edit goes through `changeTeam`.

/// What the board remembers between views: the inline name row, the folded teams, the row the
/// pill sits on, and a drag in progress.
@MainActor final class AssistantSidebarState: ObservableObject {
  static let shared = AssistantSidebarState()
  /// File › New Serein… (⌃⌘N): the New Serein dialog (`NewSereinSheet`).
  static let newAssistant = Notification.Name("SereinNewAssistant")
  static let foldedKey = "serein.sidebar.teamsFolded"
  /// The team whose header shows its rename field.
  @Published var renamingTeam: String?
  /// Folded teams, app-wide.
  @Published var folded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: AssistantSidebarState.foldedKey) ?? []) {
    didSet { RelayOrchestrator.setSetting(Array(folded).sorted(), forKey: Self.foldedKey) }
  }
  /// The "Starter teams" block under 2+ assistants, folded by default.
  @Published var startersFolded = true
  /// The row clicked last (a team id and an assistant id, either nil), so an assistant in several
  /// teams carries the pill on one row only.
  @Published var lastClicked: (team: String?, assistant: String?)?
  static let orderKey = "serein.sidebar.assistantOrder"
  /// The person's own order of the assistants in no team: a drag sets it. State still sets the
  /// section (`AssistantSections.arrange`), so the order counts inside each section.
  @Published var manualOrder: [String] = UserDefaults.standard.stringArray(forKey: AssistantSidebarState.orderKey) ?? [] {
    didSet { RelayOrchestrator.setSetting(manualOrder, forKey: Self.orderKey) }
  }
  /// The row whose details card is open under it, by its row key ("main", "solo:<id>",
  /// "member:<team>:<id>"); nil when none is.
  @Published var detailsKey: String?
  /// Counts the switches, so the list holds still for 2 seconds after each (SPEC.md 2.2).
  @Published private(set) var switches = 0
  /// "{N} hidden · Show" was pressed: the hidden rows show while the list is open, until the
  /// next switch.
  @Published var revealHidden = false
  /// The assistant whose Choose AI app… picker is open beside its row.
  @Published var choosingApp: String?
  func switched() {
    switches += 1
    if revealHidden { revealHidden = false }
  }

  init() {
    // ⌥⌘↑ and ⌥⌘↓ switch assistants from anywhere in the window.
    AssistantSwitcher.install()
  }

  func startNaming() {
    guard let relay = SereinSurface.controller?.relay else { return }
    guard relay.team.profiles.count < AssistantBoard.rosterLimit else {
      ToastCenter.shared.show(AssistantBoard.fullRoster)
      return
    }
    TeamSheets.shared.present(.newSerein)
  }
  func toggleFold(_ teamID: String) {
    if folded.contains(teamID) { folded.remove(teamID) } else { folded.insert(teamID) }
  }
  /// The key of the one row that wears the pill: the row clicked last when it still shows the
  /// active chat, else the first row in sidebar order that does. "main" is the Serein row.
  static func pillKey(relay: RelayOrchestrator, showing: Bool, lastClicked: (team: String?, assistant: String?)?) -> String? {
    // In a team chat the team's row wears it, not its lead's.
    guard showing, relay.activeTeamID == nil, let active = relay.team.active else { return nil }
    let keys = rowKeys(relay: relay)
    if let last = lastClicked {
      if let assistant = last.assistant, assistant == active.id {
        let key = last.team.map { "member:\($0):\(assistant)" } ?? (assistant == relay.team.main?.id ? "main" : "solo:\(assistant)")
        if keys.contains(key) { return key }
      } else if last.assistant == nil, let team = last.team, let group = relay.team.group(team),
        relay.activeTeamID == team, relay.responder(of: group) == active.id
      {
        if keys.contains("team:\(team)") { return "team:\(team)" }
      }
    }
    return keys.first { $0.hasSuffix(":\(active.id)") || ($0 == "main" && active.id == relay.team.main?.id) }
  }
  /// Every row key in sidebar order: the Serein row, then every other assistant (team headers left
  /// the list).
  static func rowKeys(relay: RelayOrchestrator) -> [String] {
    var keys = ["main"]
    for profile in relay.team.profiles where profile.id != relay.team.main?.id { keys.append("solo:\(profile.id)") }
    return keys
  }
  /// The assistant a row key names: "main" is the main assistant, "solo:<id>" that one.
  static func profileID(forKey key: String, relay: RelayOrchestrator) -> String? {
    if key == "main" { return relay.team.main?.id }
    guard key.hasPrefix("solo:") else { return nil }
    return String(key.dropFirst(5))
  }
}

/// The sheets the board opens: New Serein (`NewSereinSheet`) and New team (home, a starter,
/// Describe it, Blank, Duplicate, Import file, or Change… on a proposal card). One at a time,
/// hosted by `TeamSheetHost`: the shell, or
/// Settings while it is open. An assistant is edited on its page in Settings › Assistants
/// (`AssistantSettingsKey.open`).
@MainActor final class TeamSheets: ObservableObject {
  static let shared = TeamSheets()
  enum Start: Equatable {
    case home
    case starter(String)
    case blank
    case duplicate(String?)
    case describe
    case importFile
    /// Change… on a proposal card: the draft, edited in place, then Create answers the card.
    case change(UUID)
  }
  enum Kind: Identifiable, Equatable {
    case newSerein
    case newTeam(Start)
    var id: String {
      switch self {
      case .newSerein: return "serein"
      case .newTeam(let start): return "team:\(start)"
      }
    }
  }
  @Published var presented: Kind?
  func present(_ kind: Kind) { presented = kind }
  func dismiss() { presented = nil }
}

/// Presents TeamSheets: the shell does while Settings is closed, Settings does while it is open,
/// so the window never tries to show two sheets at once.
struct TeamSheetHost: ViewModifier {
  var active: Bool
  let p: Palette
  @ObservedObject private var sheets = TeamSheets.shared
  func body(content: Content) -> some View {
    content.sheet(item: Binding(get: { active ? sheets.presented : nil }, set: { if $0 == nil { sheets.dismiss() } })) { kind in
      switch kind {
      case .newSerein: NewSereinSheet().environment(\.palette, p)
      case .newTeam(let start): NewTeamSheet(start: start).environment(\.palette, p)
      }
    }
  }
}
extension TeamSheets {
  /// The Settings page whose switch allows a place for Serein: Serein's computer and Connections
  /// (Mail, Messages, Calendar, Contacts, connected apps) have their own pages; every other place
  /// is under AI apps.
  static func settingsPage(_ place: AssistantPlace) -> (id: String, name: String) {
    switch place {
    case .computer: return ("Computer", "Settings › Serein's computer")
    case .mail, .messages, .calendar, .contacts, .connectedApps: return ("Connections", "Settings › Connections")
    default: return ("Agents", "Settings › AI apps")
    }
  }
  /// The same, from a place's label (a proposal's dropped places are labels).
  static func settingsPage(label: String) -> (id: String, name: String) {
    settingsPage(AssistantPlace.allCases.first { $0.label == label } ?? .web)
  }
  /// Opens that page from inside a team sheet: the sheet closes first, then Settings opens.
  static func openSettings(_ page: (id: String, name: String)) {
    shared.dismiss()
    DispatchQueue.main.async { RelayController.shared?.openSettings(page.id) }
  }
}

/// What switches the sidebar's list without moving the main view: a tab dragged onto Agents
/// (`AssistantDrop`) and the New team and assistant flows post these; the rail answers them.
enum SidebarModeSwitch {
  static let showAssistants = Notification.Name("SereinShowAssistants")
}
/// The raised pill on a `track` segment (the inspector's tabs), in its own namespace.
struct SwitchSegmentStyle: ButtonStyle {
  var selected: Bool
  var pill: Namespace.ID
  func makeBody(configuration: Configuration) -> some View {
    Segment(configuration: configuration, selected: selected, pill: pill)
  }
  private struct Segment: View {
    let configuration: ButtonStyleConfiguration
    var selected: Bool
    var pill: Namespace.ID
    @State private var hovered = false
    @Environment(\.palette) var p
    var body: some View {
      let shape = RoundedRectangle(cornerRadius: UIStyle.controlRadius, style: .continuous)
      configuration.label
        .background {
          ZStack {
            if selected {
              shape.fill(p.raised).shadow(color: p.shadow(0.45), radius: 2.5, y: 1)
                .overlay(shape.strokeBorder(p.raisedEdge, lineWidth: UIStyle.hairline))
                .matchedGeometryEffect(id: "sidebar-mode", in: pill)
            } else if configuration.isPressed {
              shape.fill(p.selected)
            } else if hovered {
              shape.fill(p.hover)
            }
          }
        }
        .onHover { hovered = $0 }
    }
  }
}

/// New Serein (⌃⌘N anywhere): a small outline icon and label. A click opens the New Serein dialog. With 16
/// assistants it is drawn at 40% and says why.
struct NewAssistantRow: View {
  var selection: Namespace.ID
  @ObservedObject private var board = AssistantSidebarState.shared
  @State private var hovered = false
  @Environment(\.palette) var p
  private var full: Bool { (SereinSurface.controller?.relay.team.profiles.count ?? 0) >= AssistantBoard.rosterLimit }
  var body: some View {
    Button { board.startNaming() } label: {
      HStack(spacing: AssistantMetrics.listRowGap) {
        InterfaceIcon(systemName: "plus", size: 12).foregroundStyle(p.secondary)
          .frame(width: AssistantMetrics.listFace, height: AssistantMetrics.listFace)
        Text("New Serein").font(UIStyle.font(12.5)).foregroundStyle(p.secondary)
        Spacer(minLength: 4)
      }.padding(.horizontal, AssistantMetrics.listRowPaddingH)
    }.buttonStyle(AssistantListRowStyle(selected: false, hovered: hovered, selection: selection))
      .opacity(full ? 0.4 : 1)
      .onHover { hovered = $0 }
      .help(full ? AssistantBoard.fullRoster : "New Serein · ⌃⌘N")
      .accessibilityLabel("New Serein")
      .accessibilityHint(full ? AssistantBoard.fullRoster : "")
  }
}

/// The last row of the list: opens the New team sheet.
struct NewTeamRow: View {
  var selection: Namespace.ID
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    Button { TeamSheets.shared.present(.newTeam(.home)) } label: {
      HStack(spacing: AssistantMetrics.listRowGap) {
        InterfaceIcon(systemName: "person.2", size: 14).foregroundStyle(p.secondary)
          .frame(width: AssistantMetrics.listFace, height: AssistantMetrics.listFace)
        Text("New team").font(UIStyle.font(12.5)).foregroundStyle(p.ink)
        Spacer(minLength: 4)
      }.padding(.horizontal, AssistantMetrics.listRowPaddingH)
    }.buttonStyle(AssistantListRowStyle(selected: false, hovered: hovered, selection: selection))
      .onHover { hovered = $0 }
      .help("New team")
      .accessibilityLabel("New team")
  }
}

/// One row key's resting frame, for drags among assistant rows and team headers.
struct AssistantRowFrameKey: PreferenceKey {
  static var defaultValue: [String: CGRect] { [:] }
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

/// A drag of an assistant row, a pinned face or a team header: it follows the pointer; over a
/// team's row it offers to join; among its own section's rows it reorders; onto the pinned faces
/// (or the drop zone while none are pinned) it pins, and a pinned face dragged out unpins. Release
/// commits through the orchestrator (journaled) or the row marks, so nothing moves that the person
/// did not drop. One drag at a time, so one controller for the sidebar.
@MainActor final class AssistantDragController: ObservableObject {
  static let shared = AssistantDragController()
  static let space = "serein.sidebar.assistants"
  struct Drag: Equatable {
    var key: String
    var profileID: String?
    var team: String?
    var siblings: [String]
    var sourceIndex: Int
    var othersGap: Int
    var translation: CGSize
    var over: String?
    /// A pinned face: the drop sets the pin order (`AssistantRowState.orderPins`).
    var pinned: Bool
    /// Nothing was pinned when it began: the list shows `PinDropZone` above the rows.
    var pinZone: Bool
  }
  @Published var drag: Drag?
  @Published var frames: [String: CGRect] = [:]
  /// The sections of the assistants in no team as they were when a drag of one of their rows
  /// began: the list holds still in them until the drop (`AssistantSections.arrange`).
  @Published var frozenParts: [AssistantSections.Part]?
  private var resting: [String: CGRect] = [:]
  private var springOpen: DispatchWorkItem?

  func changed(
    key: String, profileID: String?, team: String?, siblings: [String], translation: CGSize, reduceMotion: Bool,
    parts: [AssistantSections.Part]? = nil, pinned: Bool = false
  ) {
    if drag?.key != key {
      guard let index = siblings.firstIndex(of: key), frames[key] != nil else { return }
      frozenParts = parts
      resting = frames
      drag = Drag(key: key, profileID: profileID, team: team, siblings: siblings, sourceIndex: index, othersGap: index,
                  translation: translation, over: nil, pinned: pinned,
                  pinZone: !pinned && profileID != nil && frames["pins"] == nil)
    }
    guard var state = drag, let own = resting[key] else { return }
    let point = CGPoint(x: own.midX + translation.width, y: own.midY + translation.height)
    state.translation = translation
    let others: [CGRect] = siblings.enumerated().compactMap { offset, other in
      offset == state.sourceIndex ? nil : resting[other]
    }
    state.othersGap = pinned
      ? Self.gridGap(point, others: others)
      : SidebarTabDragMath.gap(draggedMid: point.y, otherMids: others.map(\.midY))
    // A row may land on a team's row, on the pinned faces (live: the zone shows once the drag
    // begins) or, from a team, on the Assistants heading; a pinned face dragged out unpins.
    var over: String?
    if profileID != nil {
      over = resting.first { entry, frame in
        (entry.hasPrefix("team:") || entry == "assistants") && entry != "team:\(team ?? "")" && frame.contains(point)
      }?.key
      if over == "assistants", team == nil { over = nil }
      let inPins: Bool = frames["pins"]?.contains(point) ?? false
      if over == nil, pinned, !inPins { over = "unpin" }
      if over == nil, !pinned, inPins { over = "pins" }
    }
    if over != state.over {
      springOpen?.cancel()
      if let over, over.hasPrefix("team:") {
        let teamID = String(over.dropFirst(5))
        if AssistantSidebarState.shared.folded.contains(teamID) {
          let work = DispatchWorkItem { MainActor.assumeIsolated { _ = AssistantSidebarState.shared.folded.remove(teamID) } }
          springOpen = work
          DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.6), execute: work)
        }
      }
    }
    state.over = over
    drag = state
  }
  func ended(relay: RelayOrchestrator) {
    let frozen: [AssistantSections.Part]? = frozenParts
    defer {
      springOpen?.cancel()
      frozenParts = nil
      drag = nil
    }
    guard let state = drag else { return }
    if let over = state.over, let profileID = state.profileID {
      if over == "pins" {
        AssistantRowState.shared.pin(profileID)
      } else if over == "unpin" {
        AssistantRowState.shared.unpin(profileID)
      } else if over == "assistants", let team = state.team {
        relay.removeFromTeam(profileID, team)
      } else if over.hasPrefix("team:") {
        relay.addToTeam(profileID, String(over.dropFirst(5)))
      }
      return
    }
    let order = SidebarTabDragMath.reordered(ids: state.siblings, sourceIndex: state.sourceIndex, othersGap: state.othersGap)
    guard order != state.siblings else { return }
    // A pinned row: its place among the pins becomes the pin order.
    if state.pinned {
      let ids: [String] = order.compactMap { AssistantSidebarState.profileID(forKey: $0, relay: relay) }
      AssistantRowState.shared.orderPins(ids)
      return
    }
    // A row of the assistants in no team: its place in its own section becomes the person's
    // order (state still sets the section).
    if state.team == nil, let profileID = state.profileID, let frozen, let index = order.firstIndex(of: state.key) {
      AssistantSidebarState.shared.manualOrder = AssistantSections.moving(profileID, to: index, in: frozen)
      return
    }
    if let team = state.team, state.profileID != nil {
      relay.orderMembers(order.map { String($0.split(separator: ":").last ?? "") }, of: team)
    } else if state.profileID == nil {
      relay.orderTeams(order.map { String($0.dropFirst(5)) })
    }
  }
  /// How many of the other faces, in reading order, come before `point`: those in rows above it
  /// and those to its left in its own row.
  static func gridGap(_ point: CGPoint, others: [CGRect]) -> Int {
    others.filter { point.y > $0.maxY || (point.y >= $0.minY && point.x > $0.midX) }.count
  }
  /// The offset the dragged row or face follows the pointer with (less the drop zone above it,
  /// which pushed the list down when it appeared), else nil.
  func lift(key: String) -> CGSize? {
    guard let state = drag, state.key == key else { return nil }
    let zone: CGFloat = state.pinZone ? PinDropZone.height + 2 : 0
    return CGSize(width: state.translation.width, height: state.translation.height - zone)
  }
  /// The shift a resting sibling makes room with, and whether this row is the dragged one.
  func presentation(key: String, siblings: [String], pitch: CGFloat) -> (shift: CGFloat, dragged: Bool, indicator: Edge?) {
    guard let state = drag, state.siblings == siblings else { return (0, false, nil) }
    if state.key == key { return (0, true, nil) }
    guard state.over == nil, let index = siblings.firstIndex(of: key) else { return (0, false, nil) }
    let shift = SidebarTabDragMath.shift(index: index, sourceIndex: state.sourceIndex, othersGap: state.othersGap, pitch: pitch)
    let collapsed = index < state.sourceIndex ? index : index - 1
    let indicator: Edge? = collapsed == state.othersGap ? .top : collapsed == state.othersGap - 1 ? .bottom : nil
    return (shift, false, indicator)
  }
  /// Why a drop on this header is refused, shown as its trailing words while hovering.
  func refusal(over key: String, relay: RelayOrchestrator) -> String? {
    guard let state = drag, state.over == key, let profileID = state.profileID, key.hasPrefix("team:"),
      let group = relay.team.group(String(key.dropFirst(5)))
    else { return nil }
    if group.memberIDs.contains(profileID) { return "Already in" }
    if group.memberIDs.count >= AssistantGroup.maxMembers { return "Full (\(AssistantGroup.maxMembers))" }
    return nil
  }
}

/// Lift, shift and the gap line for a draggable board row or pinned face, and its frame for the
/// controller. Faces in the grid do not shift; the line stands at the gap's side instead.
private struct AssistantDragModifier: ViewModifier {
  @ObservedObject var drag: AssistantDragController
  var key: String
  var profileID: String?
  var team: String?
  var siblings: [String]
  var pitch: CGFloat
  /// The sections on screen, for a row of the assistants in no team: frozen while it is dragged.
  var parts: [AssistantSections.Part]? = nil
  /// A pinned face: a drop sets the pin order.
  var pinned = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  func body(content: Content) -> some View {
    let shown = drag.presentation(key: key, siblings: siblings, pitch: pitch)
    let lift: CGSize = drag.lift(key: key) ?? .zero
    content
      .overlay(alignment: pinned ? (shown.indicator == .top ? .leading : .trailing) : (shown.indicator == .top ? .top : .bottom)) {
        if shown.indicator != nil, !shown.dragged {
          if pinned {
            Capsule().fill(p.accent).frame(width: 2).padding(.vertical, 6)
              .offset(x: shown.indicator == .top ? -2 : 2).allowsHitTesting(false).accessibilityHidden(true)
          } else {
            Capsule().fill(p.accent).frame(height: 2).padding(.horizontal, 2)
              .offset(y: shown.indicator == .top ? -1 : 1).allowsHitTesting(false).accessibilityHidden(true)
          }
        }
      }
      .offset(x: lift.width, y: pinned ? lift.height : shown.shift + lift.height)
      .scaleEffect(shown.dragged ? 1.02 : 1)
      .shadow(color: shown.dragged ? p.shadow(0.38) : .clear, radius: 12, y: 5)
      .zIndex(shown.dragged ? 1 : 0)
      .animation(shown.dragged || reduceMotion ? nil : Motion.pop, value: shown.shift)
      // The finger leads while held; on release the row springs home from where it was let go.
      .animation(shown.dragged || reduceMotion ? nil : Motion.pop, value: lift)
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: AssistantRowFrameKey.self,
            value: [key: geometry.frame(in: .named(AssistantDragController.space))])
        }
      }
      .highPriorityGesture(
        // A drag starts after 4 points (SPEC.md 2.2).
        DragGesture(minimumDistance: 4, coordinateSpace: .named(AssistantDragController.space))
          .onChanged { value in
            drag.changed(key: key, profileID: profileID, team: team, siblings: siblings,
                         translation: value.translation, reduceMotion: reduceMotion, parts: parts, pinned: pinned)
          }
          .onEnded { _ in if let relay = SereinSurface.controller?.relay { drag.ended(relay: relay) } })
  }
}

/// The scrolling list of Assistants mode: the name card when New assistant was chosen, Serein's
/// own row (first, outside the sections, unless it is pinned), the pinned faces in pin order,
/// every other assistant that is not hidden in its section, "{N} hidden · Show", New assistant and
/// the hint. The drags measure in `AssistantDragController.space`, which the sidebar sets above
/// this list so the team rows there take drops too.
struct AssistantSidebarList: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var selection: Namespace.ID
  /// False in Serein's panel, where Serein's tile is the main assistant's row (with its details
  /// card, pages and computer under it): the list starts with the pins and the other assistants.
  var includesMain = true
  var body: some View {
    if let relay = SereinSurface.controller?.relay {
      AssistantSidebarListBody(
        relay: relay, browser: browser, agent: agent, hub: agent.hub, desk: relay.desk, selection: selection,
        includesMain: includesMain)
    } else {
      Text("Serein is not running in this window.").font(UIStyle.meta).foregroundStyle(p.secondary)
        .padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  @Environment(\.palette) var p
}

private struct AssistantSidebarListBody: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  /// `relay.desk`: it publishes on its own (who asks whom, for "Answering {Name}"; the owned links).
  @ObservedObject var desk: AssistantDesk
  var selection: Namespace.ID
  var includesMain = true
  @ObservedObject private var board = AssistantSidebarState.shared
  @ObservedObject private var rowState = AssistantRowState.shared
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var placement = SereinSurface.main.placement
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var tray = SereinTray.shared
  @ObservedObject private var drag = AssistantDragController.shared
  @FocusState private var listFocused: Bool
  @State private var hovering = false
  /// 2 seconds after a switch the list still holds still.
  @State private var settling = false
  /// The sections as they were when the list began to hold still (SPEC.md 2.2, G7): while the
  /// pointer is on it, while it has the keyboard, during a drag and for 2 seconds after a switch.
  /// Changes wait, then apply together. Pins and hides are the person's own and apply at once.
  @State private var heldParts: [AssistantSections.Part]? = nil
  @Environment(\.palette) var p
  /// The rail: the pins and the other assistants as faces in one column, a hairline between them.
  @Environment(\.sidebarRail) private var rail
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  private var mainID: String? { relay.team.main?.id }
  private var others: [RelayProfile] { relay.team.profiles.filter { $0.id != mainID } }
  /// No row animation above 60 rows.
  private var motion: Animation? { others.count > 60 ? nil : Motion.entering(reduceMotion) }
  private var rowTransition: AnyTransition { Motion.arrival(reduceMotion) }
  /// A row and the 2-point gap after it, for the rows that make room during a drag.
  private var rowPitch: CGFloat { UIStyle.wide(AssistantMetrics.listRowHeight) + 2 }
  /// The pill marks the main view: an assistant's row carries it while that chat shows full.
  private var showing: Bool { placement.place == .full && placement.view == .chat }
  /// One assistant's state. A preview draws the main row in the state it names (`--ui-serein-status`).
  private func status(_ id: String) -> SereinStatus {
    if id == mainID, let preview = SereinSurface.previewStatus { return preview }
    return relay.assistantStatus(id, hub: hub, online: SereinSurface.online(network.online),
                                 connected: SereinSurface.connected(agent), unread: surface.unread)
  }
  private var pillKey: String? { AssistantSidebarState.pillKey(relay: relay, showing: showing, lastClicked: board.lastClicked) }
  private var holding: Bool { hovering || listFocused || drag.drag != nil || settling }
  private var rows: [AssistantSections.Row] { others.map { AssistantSections.Row(id: $0.id, status: status($0.id)) } }
  /// The rows that show (`AssistantRowRules.layout`): the main row unless it is pinned, the pins,
  /// and every other row that is not hidden (a hidden one still shows while it needs you or while
  /// its chat is open).
  private var layout: AssistantRowRules.Layout {
    AssistantRowRules.layout(
      main: mainID, rows: rows, marks: rowState.marks, active: relay.team.activeID, revealed: board.revealHidden)
  }
  /// The sections from state only (`AssistantSections.arrange`), with the person's own order
  /// inside each.
  private func liveParts(_ layout: AssistantRowRules.Layout) -> [AssistantSections.Part] {
    AssistantSections.arrange(layout.rest, manualOrder: board.manualOrder)
  }
  /// What shows: the held sections while the list holds still, else the live ones.
  private func parts(_ layout: AssistantRowRules.Layout) -> [AssistantSections.Part] {
    let frozen: [AssistantSections.Part]? = drag.frozenParts ?? heldParts
    guard let frozen else { return liveParts(layout) }
    return AssistantSections.arrange(layout.rest, manualOrder: board.manualOrder, dragging: true, frozen: frozen)
  }
  /// The words under a name (`AssistantRowWords`): Needs you, the live step, "Answering {Name}"
  /// while another assistant's light ask runs on it (`answering`), "Could not finish {routine}"
  /// after a failed run, Paused, Stopped while Stop everything holds it, its next routine, its job.
  private func words(_ profile: RelayProfile, _ state: SereinStatus) -> AssistantRowWords {
    let phase: String? = relay.assistantPhase(profile.id, hub: hub)
    let owned: [RelayReminder] = relay.reminders.filter { $0.profileID == profile.id && $0.action }
    let runs: [RelayReminder] = owned.filter { $0.paused != true }
    let due: Date? = runs.map(\.due).min()
    let next: String? = due.map { AssistantRowWords.checks(next: $0, now: Date(), calendar: .current) }
    let failedRoutine: String? = owned.first { ($0.failures ?? 0) > 0 }?.text
    let failedWatch: String? = relay.watches.first { $0.profileID == profile.id && ($0.failures ?? 0) > 0 }?.name
    let ownJob: String? = AssistantRoster.job(of: profile) ?? profile.label
    let job: String? = profile.id == mainID ? (ownJob ?? "Your chief of staff") : ownJob
    let stopped: Bool = relay.state.paused && !profile.isPaused
    return AssistantRowWords.of(
      status: state, phase: phase, nextRun: next, job: job, answering: relay.answering(profile.id),
      failed: failedRoutine ?? failedWatch, stopped: stopped)
  }
  /// The row the keyboard's Space opens: the active assistant's.
  private var activeKey: String {
    relay.team.activeID == mainID ? "main" : "solo:\(relay.team.activeID)"
  }
  private func rowKey(_ id: String) -> String { id == mainID ? "main" : "solo:\(id)" }

  var body: some View {
    let pill: String? = pillKey
    let current: AssistantRowRules.Layout = layout
    let shown: [AssistantSections.Part] = parts(current)
    let focusKey: String? = listFocused ? activeKey : nil
    VStack(alignment: .leading, spacing: 2) {
      if drag.drag?.pinZone == true { PinDropZone(over: drag.drag?.over == "pins").background { frameReader("pins") } }
      if includesMain { mainRow(current, pill: pill, parts: shown, focusKey: focusKey) }
      // Serein's tile always leads Serein's panel, pinned or not.
      let pins: [String] = includesMain ? current.pinned : current.pinned.filter { $0 != mainID }
      pinnedFaces(pins, pill: pill)
      if rail, !pins.isEmpty, shown.contains(where: { !$0.ids.isEmpty }) { SidebarRailLine() }
      sectionRows(shown, pill: pill, focusKey: focusKey)
      if current.hiddenCount > 0, !board.revealHidden, !rail {
        HiddenAssistantsRow(count: current.hiddenCount) { board.revealHidden = true }
      }
      if includesMain, !rail {
        NewAssistantRow(selection: selection).padding(.top, 4)
        NewTeamRow(selection: selection)
      }
    }
    .animation(motion, value: shown)
    .animation(motion, value: current.pinned)
    .animation(motion, value: pill)
    .animation(motion, value: board.detailsKey)
    .animation(motion, value: board.revealHidden)
    .onHover { hovering = $0 }
    .onChange(of: holding) { _, now in heldParts = now ? liveParts(layout) : nil }
    .task(id: board.switches) {
      guard board.switches > 0 else { return }
      settling = true
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      settling = false
    }
    .modifier(AssistantListKeys(focused: $listFocused, activeKey: activeKey, delete: { deleteActive() }))
    // The chats next to the active one load ahead, so the next switch draws at once.
    .onAppear {
      rowState.attach()
      AssistantSwitcher.preloadSoon(relay)
    }
    // The hidden rows that Show brought back go again once the list closes.
    .onDisappear { if board.revealHidden { board.revealHidden = false } }
    .onChange(of: relay.team.activeID) { AssistantSwitcher.preloadSoon(relay) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Assistants")
  }

  /// Serein's own row, first and outside the sections, while it is not pinned. It never moves.
  @ViewBuilder private func mainRow(
    _ layout: AssistantRowRules.Layout, pill: String?, parts: [AssistantSections.Part], focusKey: String?
  ) -> some View {
    if let main = relay.team.main, layout.main == main.id {
      assistantRow(main, key: "main", siblings: [], pill: pill, parts: parts, focusKey: focusKey)
    }
  }
  /// The pinned faces in pin order, as many to a row as the sidebar's width fits (three at the
  /// usual width, one in the rail), then the pages and computers they use. A drag among them
  /// sets the order; out of the grid it unpins.
  @ViewBuilder private func pinnedFaces(_ ids: [String], pill: String?) -> some View {
    let profiles: [RelayProfile] = ids.compactMap { id in relay.team.profiles.first { $0.id == id } }
    if !profiles.isEmpty {
      let keys: [String] = profiles.map { rowKey($0.id) }
      let columns: [GridItem] = [rail ? GridItem(.flexible()) : GridItem(.adaptive(minimum: 64), spacing: 4)]
      LazyVGrid(columns: columns, spacing: 4) {
        ForEach(profiles, id: \.id) { profile in
          PinnedAssistantTile(relay: relay, profile: profile, status: status(profile.id), selection: selection,
                              selected: pill == rowKey(profile.id))
            .modifier(AssistantDragModifier(drag: drag, key: rowKey(profile.id), profileID: profile.id, team: nil,
                                            siblings: keys, pitch: 0, pinned: true))
            .transition(rowTransition)
        }
      }
      .background { frameReader("pins") }
      .padding(.vertical, rail ? 0 : 4)
      if !rail {
        ForEach(profiles, id: \.id) { profile in
          SereinChildRows(browser: browser, board: browser.agentTabs, selection: selection, owner: profile.id, name: profile.name)
        }
      }
    }
  }
  private func frameReader(_ key: String) -> some View {
    GeometryReader { geometry in
      Color.clear.preference(key: AssistantRowFrameKey.self, value: [key: geometry.frame(in: .named(AssistantDragController.space))])
    }
  }
  /// The other rows, in their sections' order. A row says its own state, so the order is enough.
  @ViewBuilder private func sectionRows(
    _ shown: [AssistantSections.Part], pill: String?, focusKey: String?
  ) -> some View {
    ForEach(shown, id: \.section) { part in
      let keys: [String] = part.ids.map { "solo:\($0)" }
      ForEach(part.ids, id: \.self) { id in
        if let profile = relay.team.profiles.first(where: { $0.id == id }) {
          assistantRow(profile, key: "solo:\(id)", siblings: keys, pill: pill, parts: shown, focusKey: focusKey)
        }
      }
    }
  }

  /// One assistant: its row, the details card under it while open and the pages its tasks use.
  @ViewBuilder private func assistantRow(
    _ profile: RelayProfile, key: String, siblings: [String], pill: String?, parts: [AssistantSections.Part],
    focusKey: String?
  ) -> some View {
    let state: SereinStatus = status(profile.id)
    if rail {
      PinnedAssistantTile(relay: relay, profile: profile, status: state, selection: selection, selected: pill == key,
                          pinned: false)
        .transition(rowTransition)
    } else {
      AssistantRow(relay: relay, profile: profile, status: state, words: words(profile, state),
                   selection: selection, selected: pill == key, key: key, siblings: siblings, parts: parts,
                   keyboardHere: focusKey == key)
        .modifier(AssistantDragModifier(drag: drag, key: key, profileID: profile.id, team: nil, siblings: siblings,
                                        pitch: rowPitch, parts: parts))
        .transition(rowTransition)
      SereinChildRows(browser: browser, board: browser.agentTabs, selection: selection, owner: profile.id, name: profile.name)
    }
  }
  /// ⌘⌫: the delete card for the assistant whose chat is open (never the main assistant).
  private func deleteActive() {
    guard let profile = relay.team.active else { return }
    AssistantConfirm.deleteAssistant(relay, profile)
  }
}

/// The list's keys (SPEC.md 2.0): ↑ ↓ switch at once, Space opens or closes the details, Return
/// goes to the message bar, ⌘⌫ opens the delete card for the selected assistant, Esc closes the
/// details and the name card (the card's own Esc never gets the keyboard here). The row with the
/// keyboard draws its own focus ring, so the system's is off.
private struct AssistantListKeys: ViewModifier {
  var focused: FocusState<Bool>.Binding
  /// The selected row's key ("main" or "solo:<id>").
  var activeKey: String
  var delete: () -> Void
  func body(content: Content) -> some View {
    content
      .focusable()
      .focused(focused)
      .focusEffectDisabled()
      .onMoveCommand { direction in
        if direction == .up {
          _ = AssistantSwitcher.step(-1)
        } else if direction == .down {
          _ = AssistantSwitcher.step(1)
        }
      }
      .onKeyPress(.space) {
        if let relay = SereinSurface.controller?.relay { AssistantDetailsOpener.toggle(relay) }
        return .handled
      }
      .onKeyPress(.return) {
        NotificationCenter.default.post(name: SereinSurface.focus, object: nil)
        return .handled
      }
      .onKeyPress(.delete, phases: .down) { press in
        guard press.modifiers.contains(.command) else { return .ignored }
        delete()
        return .handled
      }
      .onExitCommand {
        AssistantSidebarState.shared.detailsKey = nil
      }
  }
}

/// The quiet last row while rows are hidden: "{N} hidden · Show". A click shows them while the
/// list is open, until the next switch.
struct HiddenAssistantsRow: View {
  var count: Int
  var show: () -> Void
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    let wash: Color = p.isDark ? p.hover : p.raised.opacity(0.5)
    Button(action: show) {
      HStack(spacing: AssistantMetrics.listRowGap) {
        InterfaceIcon(systemName: "eye.slash", size: 14).foregroundStyle(p.secondary)
          .frame(width: AssistantMetrics.listFace)
        Text(verbatim: AssistantRowRules.hiddenWords(count)).font(AssistantType.meta).foregroundStyle(p.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, AssistantMetrics.listRowPaddingH)
      .frame(height: 28)
      .contentShape(Rectangle())
      .background(hovered ? wash : Color.clear,
                  in: RoundedRectangle(cornerRadius: AssistantMetrics.listRowRadius, style: .continuous))
    }
    .buttonStyle(.pressable)
    .onHover { hovered = $0 }
    .help("Show the hidden assistants until you switch")
    .accessibilityLabel(count == 1 ? "1 hidden assistant" : "\(count) hidden assistants")
    .accessibilityHint("Shows them in the list")
  }
}

/// One assistant (`avatar-list-row`, SPEC.md 2.2): its face (32, or 40 in a wide sidebar) with the
/// status dot, its name (13 medium) over its words (12, in their tone), and a chevron, which an
/// 8-point `accent` dot replaces while a reply is unread (`AssistantRowState.unread`, or Serein's
/// own dot for the active chat). While the row is hovered, has the keyboard or its menu is open,
/// a 24-point "…" takes that place and opens the row's menu in the window (`SereinMenu`); a
/// right-click opens the same items as a native menu (`AssistantRowMenu`). One click makes it the
/// one you talk to and opens its details card right under the row; a second click on the open row
/// closes it; a double-click renames it. A chat message dropped on it is handed to it;
/// files, a link, text or a tab open its chat with them (AssistantDrop). VoiceOver: "{Name},
/// {words}", with Move up, Move down, Open details, Pin, Hide, Pause and Delete (the last two type
/// the words into the message bar; nothing applies without Return).
struct AssistantRow: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  let status: SereinStatus
  let words: AssistantRowWords
  var selection: Namespace.ID
  var selected: Bool
  var key: String
  /// Its section's row keys and the sections on screen, for Move up and Move down.
  var siblings: [String] = []
  var parts: [AssistantSections.Part] = []
  /// The list has the keyboard and this is the active row: the focus ring and the "…" show.
  var keyboardHere = false
  @ObservedObject private var board = AssistantSidebarState.shared
  @ObservedObject private var rowState = AssistantRowState.shared
  @ObservedObject private var menus = SereinMenuCenter.shared
  @ObservedObject private var drop = AssistantDrop.shared
  @State private var hovered = false
  @State private var renaming = false
  @State private var draft = ""
  @FocusState private var renameFocused: Bool
  @Environment(\.palette) var p
  private var answers: Bool { relay.team.activeID == profile.id }
  private var isMain: Bool { profile.id == relay.team.main?.id }
  private var dropHover: AssistantDrop.Hover? { drop.hovering(key) }
  private var dropTarget: Bool { dropHover.map { !$0.refused } ?? false }
  /// The ground under the row, for the face's dot ring.
  private var plane: Color { selected ? p.selected : p.sidebar }
  /// A reply not read yet: the row's own mark, or Serein's dot for the active chat.
  private var unread: Bool { status == .unread || rowState.unread.contains(profile.id) }
  private var moreLabel: String { "More for \(profile.name)" }
  private var menuOpen: Bool { menus.presented?.label == moreLabel }
  /// The "…" takes the chevron's place while the row is hovered, has the keyboard or its menu is open.
  private var showsMore: Bool { !renaming && (hovered || keyboardHere || menuOpen) }
  private var choosing: Binding<Bool> {
    Binding(
      get: { board.choosingApp == profile.id },
      set: { open in if !open, board.choosingApp == profile.id { board.choosingApp = nil } })
  }
  var body: some View {
    rowContent
      .help(help)
      .accessibilityLabel("\(profile.name), \(dropHover?.words ?? words.text)")
      .accessibilityValue(selected ? "selected" : "")
      .accessibilityHint("Opens its chat")
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityAction(named: "Move up") { move(-1) }
      .accessibilityAction(named: "Move down") { move(1) }
      .accessibilityAction(named: "Open details") { AssistantInspector.shared.show(profile.id) }
      .accessibilityAction(named: "Open settings") { AssistantSettingsKey.open(profile.id) }
      .accessibilityAction(named: rowState.pinned.contains(profile.id) ? "Unpin" : "Pin") { togglePin() }
      .accessibilityActions { spokenActions }
      .overlay(alignment: .trailing) { moreButton }
      .overlay { focusRing }
      .contextMenu { AssistantRowMenuNative(items: menuItems()) }
      .onHover { hovered = $0 }
      .popover(isPresented: choosing, arrowEdge: .trailing) {
        AssistantAppPicker(relay: relay, profile: profile) { board.choosingApp = nil }
          .environment(\.palette, p)
      }
      // Files, a link, text or a tab open this chat with them; a chat message dragged from the
      // transcript hands off to this assistant (never to the one whose chat it is).
      .modifier(AssistantDropModifier(key: key, target: .assistant(profile.id, team: nil), handOff: messageHandOff))
  }
  private var rowContent: some View {
    Group {
      if renaming {
        renameRow
      } else {
        Button(action: click) { label }
          .buttonStyle(AssistantListRowStyle(selected: selected, hovered: hovered || dropTarget, selection: selection))
      }
    }
    .background(dropTarget ? p.selected : .clear, in: RoundedRectangle(cornerRadius: AssistantMetrics.listRowRadius))
  }
  /// Hide, Pause and Delete; the main assistant has only Pause (its words say why it cannot).
  @ViewBuilder private var spokenActions: some View {
    if !isMain { Button("Hide from sidebar") { rowState.hide(profile.id) } }
    Button("Pause") { type("Pause \(profile.name)") }
    if !isMain { Button("Delete…") { type("Delete \(profile.name)") } }
  }
  private var badge: Provider? { AssistantRowFace.provider(relay, profile) }
  private var label: some View {
    let shown: String = dropHover?.words ?? words.text
    // Small status text uses the checked neutral contrast on selection and hover washes.
    let tone: Color = dropHover != nil || selected || hovered ? p.secondary : p.rowTone(words.tone)
    return HStack(spacing: AssistantMetrics.listRowGap) {
      AssistantRowFace(profile: profile, status: status, plane: plane, provider: badge)
      HStack(spacing: 6) {
        Text(verbatim: profile.name).font(UIStyle.font(12.5)).foregroundStyle(p.ink)
          .lineLimit(1).truncationMode(.tail)
          .layoutPriority(1)
        // An idle row with nothing to say shows only its name; VoiceOver still reads Ready.
        if dropHover != nil || !words.isIdle {
          Text(verbatim: shown).font(UIStyle.font(11)).foregroundStyle(tone)
            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 100, alignment: .leading)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Group {
        if unread {
          Circle().fill(p.accent).frame(width: 8, height: 8)
        } else {
          InterfaceIcon(systemName: "chevron.right", size: 13).foregroundStyle(p.secondary).opacity(0.5)
        }
      }.frame(width: 24, height: 24).opacity(showsMore ? 0 : 1).accessibilityHidden(true)
    }
    .padding(.horizontal, AssistantMetrics.listRowPaddingH).padding(.vertical, AssistantMetrics.listRowPaddingV)
  }
  /// The row's "…" (24 points, where the chevron is): the same items as the right-click menu, in
  /// the window.
  private var moreButton: some View {
    SereinMenuButton(moreLabel, leading: true) { menuItems() } label: {
      InterfaceIcon(systemName: "ellipsis", size: 14).foregroundStyle(p.ink)
        .frame(width: 24, height: 24)
        .background(p.track, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .padding(.trailing, AssistantMetrics.listRowPaddingH)
    .opacity(showsMore ? 1 : 0)
    .allowsHitTesting(showsMore)
    .accessibilityHidden(!showsMore)
  }
  /// While the list has the keyboard, the active row wears the focus ring: `focus`, 2 points, 2
  /// points out.
  @ViewBuilder private var focusRing: some View {
    if keyboardHere {
      RoundedRectangle(cornerRadius: AssistantMetrics.listRowRadius + 4, style: .continuous)
        .strokeBorder(p.accent, lineWidth: 2)
        .padding(-4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
  /// The row's menu items, for the "…" and the right-click menu alike.
  private func menuItems() -> [SereinMenuItem] {
    AssistantRowMenu.items(relay: relay, profile: profile, rename: { startRename() })
      + AssistantRowMenu.sereinItems(relay: relay)
  }
  /// The rename field sits outside the row's button, so it takes the keyboard and the clicks.
  private var renameRow: some View {
    HStack(spacing: AssistantMetrics.listRowGap) {
      AssistantRowFace(profile: profile, status: status, plane: p.sidebar, provider: badge)
      TextField("Name", text: $draft).textFieldStyle(.plain).font(AssistantType.name).foregroundStyle(p.ink)
        .focused($renameFocused)
        .onSubmit { saveRename() }
        .onExitCommand { renaming = false }
        .onChange(of: renameFocused) { _, now in if !now { renaming = false } }
        .accessibilityLabel("Rename \(profile.name)")
    }.padding(.horizontal, AssistantMetrics.listRowPaddingH).frame(height: UIStyle.wide(AssistantMetrics.listRowHeight))
      .background(p.hover, in: RoundedRectangle(cornerRadius: AssistantMetrics.listRowRadius, style: .continuous))
      .onAppear { renameFocused = true }
  }
  /// One click: it answers at once (its details open from its name in the chat's header). The
  /// second click of a double-click renames in place (also Rename… in the
  /// menu); it is read from the click, not from a TapGesture(count: 2), which under the row's
  /// drag gesture kept single clicks from opening the chat. Only a mouse event has a click count:
  /// Space with Full Keyboard Access and a VoiceOver press are not mouse events, and AppKit stops
  /// the app when `clickCount` is read from one.
  private func click() {
    if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp, event.clickCount == 2 {
      startRename()
      return
    }
    board.lastClicked = (nil, profile.id)
    let switching: Bool = !answers
    guard relay.openAssistant(profile.id) else { return }
    if switching { board.switched() }
  }
  /// Move up or Move down inside its section (the person's own order); the pinned faces move
  /// their own (`PinnedAssistantTile`).
  private func move(_ step: Int) {
    guard let index = siblings.firstIndex(of: key) else { return }
    let target: Int = index + (step < 0 ? -1 : 1)
    guard siblings.indices.contains(target) else { return }
    board.manualOrder = AssistantSections.moving(profile.id, to: target, in: parts)
  }
  private func togglePin() {
    if rowState.pinned.contains(profile.id) { rowState.unpin(profile.id) } else { rowState.pin(profile.id) }
  }
  /// Pause and Delete type their words into the message bar; Return sends them.
  private func type(_ words: String) {
    SereinSurface.main.draft = words
    NotificationCenter.default.post(name: SereinSurface.focus, object: nil)
  }
  private func startRename() {
    draft = profile.name
    renaming = true
  }
  /// A dropped chat message's id: its words, from the chat on screen, become the hand-off task.
  private var messageHandOff: (@MainActor (String) -> Void)? {
    guard !answers else { return nil }
    return { id in
      guard let task = relay.transcript.first(where: { $0.id == id })?.text, !task.isEmpty else { return }
      relay.requestHandoff(to: profile.id, task: task)
    }
  }
  private var help: String {
    if relay.working, relay.team.activeID != profile.id {
      return "\(profile.name) · \(relay.team.activeName) keeps working while you switch"
    }
    return "\(profile.name) · Click to talk to \(profile.name) and see its details"
  }
  private func saveRename() {
    let clean = RelayProfile.cleanName(draft)
    if !clean.isEmpty, clean != profile.name, !relay.renameProfile(profile.id, to: clean) {
      ToastCenter.shared.show("Another assistant is called \(clean).")
    }
    renaming = false
  }
}

/// The row's menu (board 12), built once and drawn two ways: in the window from the row's "…"
/// (`SereinMenuButton`) and as the native right-click menu (`AssistantRowMenuNative`); the chat
/// header's ⋯ draws the same items. Pin or Unpin, Rename…, Settings… (its details on the right,
/// where its AI app, Asks first, Hidden and Activity are), Copy chat; Pause or Resume and
/// Delete…. The main assistant has no Pause or Delete. No label holds anything personal: only
/// the assistant's own name shows, in the "…" trigger's words.
@MainActor enum AssistantRowMenu {
  static func items(relay: RelayOrchestrator, profile: RelayProfile, rename: @escaping () -> Void) -> [SereinMenuItem] {
    let state = AssistantRowState.shared
    let id: String = profile.id
    let pinned: Bool = state.pinned.contains(id)
    var items: [SereinMenuItem] = []
    items.append(.action(pinned ? "Unpin" : "Pin", icon: pinned ? "pin.slash" : "pin") {
      if pinned { state.unpin(id) } else { state.pin(id) }
    })
    items.append(.action("Rename…", icon: "pencil", rename))
    items.append(.action("Settings…", icon: "gearshape") { AssistantInspector.shared.show(id, tab: .details) })
    items.append(.action("Copy chat", icon: "doc.on.doc") { copyChat(relay, profile) })
    if id != relay.team.main?.id {
      let paused: Bool = profile.isPaused
      items.append(.divider)
      items.append(.action(paused ? "Resume" : "Pause", icon: paused ? "play" : "pause") {
        setPaused(relay, profile, !paused)
      })
      items.append(.action("Delete…", icon: "trash", destructive: true) { AssistantConfirm.deleteAssistant(relay, profile) })
    }
    return items
  }

  /// Serein's own items after an assistant's: Stop Everything while anything runs (File › Stop
  /// Everything has it always), Resume Serein while paused, and Serein Settings….
  static func sereinItems(relay: RelayOrchestrator) -> [SereinMenuItem] {
    guard let controller = RelayController.shared else { return [] }
    var items: [SereinMenuItem] = [.divider]
    if relay.working || !relay.agent.hub.active.isEmpty {
      items.append(.action("Stop Everything", icon: "stop.circle", shortcut: controller.killLabel, destructive: true) {
        controller.killSwitch()
      })
    }
    if relay.state.paused { items.append(.action("Resume Serein", icon: "play") { relay.resume() }) }
    items.append(.action("Serein Settings…", icon: "gearshape") { controller.openSettings("Relay") })
    return items
  }

  /// Mark as unread, or Mark as read (which also clears Serein's own dot for the active chat).
  static func setUnread(_ relay: RelayOrchestrator, _ id: String, _ unread: Bool) {
    let state = AssistantRowState.shared
    if unread {
      state.markUnread(id)
      return
    }
    state.markRead(id)
    if id == relay.team.activeID, SereinSurface.main.unread { SereinSurface.main.unread = false }
  }

  /// Pause or Resume: the same change `assistant_change` makes with `paused` (`AssistantChange`
  /// through `applyChange`), with its receipt and Undo in the chat on screen. The person's own
  /// action, so it applies at once; a pause holds its routines, watches and links.
  static func setPaused(_ relay: RelayOrchestrator, _ profile: RelayProfile, _ paused: Bool) {
    let request: [String: Any] = ["name": profile.name, "paused": paused]
    let parsed: Result<AssistantChange, AssistantChange.Problem> = AssistantChange.parse(
      request, actingID: profile.id, team: relay.team, person: relay.personScope, global: relay.proactiveLevel)
    switch parsed {
    case .failure(let problem):
      ToastCenter.shared.show(problem.words)
    case .success(let change):
      if case .success(let receipt) = relay.applyChange(change, actor: "user") {
        relay.deliver(receipt: receipt, into: relay.threadID)
      } else {
        ToastCenter.shared.show("\(profile.name) did not change, because it changed meanwhile. Try again.")
      }
    }
  }

  /// Copy chat: the assistant's Main chat as plain text on the pasteboard, "Name: words" per
  /// message. The person's own action: no mark changes.
  static func copyChat(_ relay: RelayOrchestrator, _ profile: RelayProfile) {
    let text: String = AssistantRowRules.plainChat(chatLines(relay, profile))
    guard !text.isEmpty else {
      ToastCenter.shared.show("\(profile.name)'s chat is empty.")
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    ToastCenter.shared.show("Copied \(profile.name)'s chat.")
  }
  /// Its Main chat as the chat shows it: the person's words as "You", replies under its name (or
  /// under the assistant that wrote one), a system line alone, a receipt's line when a message has
  /// no words. A check-in with nothing to say and a prompt Serein wrote to itself are left out.
  /// A receipt's Undo, an ask's own chat and a folded line's words are never copied.
  /// `last`: only that many of its newest messages are read (the row's and the Search palette's
  /// one line); only then do chips sent alone and a reply that only ran tools get a line.
  static func chatLines(_ relay: RelayOrchestrator, _ profile: RelayProfile, last: Int? = nil) -> [AssistantRowRules.ChatLine] {
    let chat: [AgentMessage] = mainChat(relay, profile.id)
    let messages: [AgentMessage] = ChatCondense.expanded(last.map { Array(chat.suffix($0)) } ?? chat)
    var lines: [AssistantRowRules.ChatLine] = []
    for message in messages {
      if let line = message.line {
        lines.append(AssistantRowRules.ChatLine(who: nil, words: line))
        continue
      }
      if message.role == "you" {
        guard !RelayProactive.isOwnPrompt(message.text) else { continue }
        // Chips sent alone: "Sent 2 PDFs", never their names.
        let chips = message.text.isEmpty && last != nil ? message.attached ?? [] : []
        lines.append(chips.isEmpty ? AssistantRowRules.ChatLine(who: "You", words: message.text)
          : AssistantRowRules.ChatLine(who: nil, words: AssistantRowPreview.sent(chips)))
        continue
      }
      guard message.role == "assistant", !RelayProactive.isNothing(message.text) else { continue }
      let who: String = message.from.map { relay.profileName($0) } ?? profile.name
      var words: String = ChatBubbles.plain(QuickReplies.parse(message.text).text)
      if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        words = (message.receipts ?? []).map(\.line).joined(separator: "\n")
      }
      if words.isEmpty, last != nil, let steps = message.activities, !steps.isEmpty { words = AssistantRowPreview.ran(steps.count) }
      lines.append(AssistantRowRules.ChatLine(who: who, words: words))
    }
    return lines
  }
  /// The assistant's Main chat: the live one on screen, else its saved thread (read, never written).
  static func mainChat(_ relay: RelayOrchestrator, _ id: String) -> [AgentMessage] {
    if id == relay.team.activeID { return relay.transcript }
    guard let thread = relay.knownMainThread(of: id) else { return [] }
    if let run = relay.agent.hub.latest(for: thread) { return run.transcript }
    return relay.agent.conversations.first { $0.id == thread }?.messages ?? []
  }
}

/// The same rows as a native right-click menu, each with its icon.
struct AssistantRowMenuNative: View {
  let items: [SereinMenuItem]
  var body: some View {
    ForEach(items) { item in
      AssistantRowMenuNativeItem(item: item)
    }
  }
}
private struct AssistantRowMenuNativeItem: View {
  let item: SereinMenuItem
  var body: some View {
    switch item.kind {
    case .divider:
      Divider()
    case .header, .note:
      Text(item.title)
    case .action, .submenu:
      Button(role: item.destructive ? .destructive : nil) {
        item.action?()
      } label: {
        Label(item.title, systemImage: item.icon ?? "circle")
      }
      .labelStyle(.titleAndIcon)
      .disabled(item.disabled)
    }
  }
}

/// Choose AI app… from the row's menu: Serein's own picker of AI apps and models, with each
/// app's logo (`ModelPickerView` with `assistant:`). A pick sets this assistant's own route
/// (`RelayOrchestrator.chooseRoute`, under the existing switch rules: a move that can change who
/// pays asks on a card first). Keel's size, capped to the window.
struct AssistantAppPicker: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  var close: () -> Void
  @Environment(\.palette) var p
  var body: some View {
    let size: CGSize = Self.size
    ModelPickerView(agent: relay.agent, assistant: profile.id) { close() }
      .frame(width: size.width, height: size.height)
      .background(KeelPicker.surface(p.isDark))
  }
  @MainActor static var size: CGSize {
    let room: NSRect = (NSApp.mainWindow ?? NSApp.keyWindow)?.contentLayoutRect ?? .zero
    let width: CGFloat = room.width > 0 ? min(KeelPicker.width, room.width - 32) : KeelPicker.width
    let height: CGFloat = room.height > 0 ? min(KeelPicker.height, room.height - 32) : KeelPicker.height
    return CGSize(width: max(240, width), height: max(200, height))
  }
}

/// Teams stay as data (team chats open from the header's picker), but their headers left the
/// list (SPEC.md 2.2, G8): every assistant is a row in its section.

/// The delete card and the team alerts. Under checks and previews nothing is asked and nothing is
/// deleted.
@MainActor enum AssistantConfirm {
  /// Delete {Name}… (the row's menu, ⌘⌫ in the list, its Settings page): the path `assistant_delete`
  /// takes. The card in the chat on screen (`DeletePlan`: what ends with it, "Delete assistant"
  /// or "Keep it"), then the receipt with the toast and its 10-second Undo. The main assistant
  /// never goes; the assistant on screen cannot go, so the main one answers first.
  static func deleteAssistant(_ relay: RelayOrchestrator, _ profile: RelayProfile) {
    guard !RunMode.automated else { return }
    if let main = relay.team.main, main.id == profile.id {
      ToastCenter.shared.show(DeletePlan.Refusal.main(profile.name).words)
      return
    }
    // A team sheet closes, so the card shows in the chat.
    TeamSheets.shared.dismiss()
    if relay.team.activeID == profile.id, let main = relay.team.main, !relay.openAssistant(main.id) { return }
    let plan: DeletePlan
    switch relay.deletePlan(for: profile.id) {
    case .success(let found): plan = found
    case .failure(let refusal):
      ToastCenter.shared.show(refusal.words)
      return
    }
    let thread: String = relay.threadID
    Task { @MainActor in
      let human: ApprovalGate.HumanAnswer = await relay.confirmAnswer(
        plan.title, plan.detail, button: DeletePlan.confirm, decline: DeletePlan.keep, thread: thread, effect: .delete)
      guard human == .yes else { return }
      guard let receipt = relay.applyDelete(plan, actor: "user") else {
        ToastCenter.shared.show("The assistants changed while the card waited, so nothing was deleted.")
        return
      }
      relay.deliver(receipt: receipt, into: thread)
    }
  }
  /// Rename Team… where the sidebar may not show (tabs on top, a hidden sidebar): an alert with
  /// the name in a field.
  static func renameTeam(_ relay: RelayOrchestrator, _ group: AssistantGroup) {
    guard !RunMode.automated else { return }
    let alert = NSAlert()
    alert.messageText = "Rename \(group.name)"
    let field = NSTextField(string: group.name)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let clean = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != group.name else { return }
    if !relay.renameTeam(group.id, to: clean) { ToastCenter.shared.show("Another team is called \(clean).") }
  }
  static func deleteTeam(_ relay: RelayOrchestrator, _ group: AssistantGroup) {
    guard !RunMode.automated else { return }
    let names = group.memberIDs.map(relay.profileName)
    let who = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    let alert = NSAlert()
    alert.messageText = "Delete \(group.name)?"
    alert.informativeText = "\(who) stay. The team chat stays in History."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.cancelByDefault()
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    relay.deleteTeam(group.id)
  }
}

/// A chat message dragged onto an assistant row: the drag carries the message's words behind a
/// marker, so a stray text drop never opens a card.
enum MessageDrag {
  static let prefix = "serein-handoff\n"
  /// The drag carries only the message's id; a drop resolves it in the chat on screen, so no
  /// dragged text (a webpage's, say) ever becomes the task.
  static func provider(id: String) -> NSItemProvider { NSItemProvider(object: (prefix + id) as NSString) }
  static func id(_ dropped: String) -> String? {
    guard dropped.hasPrefix(prefix) else { return nil }
    let id = String(dropped.dropFirst(prefix.count))
    return id.isEmpty || id.contains(where: \.isWhitespace) ? nil : id
  }
}
