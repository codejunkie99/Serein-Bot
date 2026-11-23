import AppKit
import SereinCore
import SwiftUI

// The parts of the assistant list (SPEC.md 2.2 and 2.3, the Nb boards scaled to the 232-point
// sidebar): the row's style and face, the section headings, the details card under a row, the
// name card for a new assistant, the hint, and the keys. AssistantSidebar.swift puts them together.

/// A compact 30-point list row with a flat neutral selection and no shadow. The highlight
/// glides between rows in the sidebar's selection namespace. Status text uses `secondary`
/// while selected or hovered so it stays legible on these neutral washes.
struct AssistantListRowStyle: ButtonStyle {
  var selected: Bool
  var hovered: Bool
  var selection: Namespace.ID
  /// A pinned face sizes to its face and name instead of the row height.
  var fitsContent = false
  func makeBody(configuration: Configuration) -> some View {
    RowBody(configuration: configuration, selected: selected, hovered: hovered, selection: selection, fitsContent: fitsContent)
  }
  private struct RowBody: View {
    let configuration: ButtonStyleConfiguration
    var selected: Bool
    var hovered: Bool
    var selection: Namespace.ID
    var fitsContent: Bool
    @Environment(\.palette) var p
    var body: some View {
      let shape = RoundedRectangle(cornerRadius: AssistantMetrics.listRowRadius, style: .continuous)
      configuration.label
        .frame(height: fitsContent ? nil : UIStyle.wide(AssistantMetrics.listRowHeight))
        .contentShape(shape)
        .background {
          ZStack {
            if selected {
              shape.fill(p.selected)
                .matchedGeometryEffect(id: "sidebar-selection", in: selection)
            }
            if configuration.isPressed {
              shape.fill(p.selected)
            } else if hovered && !selected {
              shape.fill(p.hover)
            }
          }
        }
        .scaleEffect(fitsContent && configuration.isPressed ? Motion.pressScale : 1)
        .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
    }
  }
}

/// A row's face with its status dot at the lower trailing edge: `success` while it works,
/// `warning` while it needs you, none otherwise; the dot scales with the face.
/// The AI app it thinks with wears its logo at the lower leading edge, in the same ring. The
/// unread dot sits where the chevron was (the row draws it); the face's own motion is
/// `AssistantMark`'s.
struct AssistantRowFace: View {
  let profile: RelayProfile
  let status: SereinStatus
  var size: CGFloat = AssistantMetrics.listFace
  /// The ground under the face, for the dot's ring.
  var plane: Color
  /// The AI app the assistant thinks with; nil while none is connected.
  var provider: Provider? = nil
  /// The AI app `profile` thinks with, once it can: a default nobody connected shows nothing.
  static func provider(_ relay: RelayOrchestrator, _ profile: RelayProfile) -> Provider? {
    let provider = relay.assistantEngine(profile).provider
    return relay.agent.available[provider] != nil ? provider : nil
  }
  @Environment(\.palette) var p
  private var dot: Color? {
    if status.spins { return p.success }
    if status == .needsYou { return p.warning }
    return nil
  }
  var body: some View {
    AssistantMark(profile: profile, size: size, status: status == .unread ? .ready : status)
      .overlay(alignment: .bottomLeading) {
        if let provider {
          let badge: CGFloat = (size * 0.4).rounded()
          HarnessGlyph(provider: provider, size: badge - 2, logo: true)
            .frame(width: badge, height: badge)
            .background(p.card, in: Circle())
            .padding(2).background(plane, in: Circle())
            .offset(x: -3, y: 3)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if let dot {
          Circle().fill(dot).frame(width: min(7, size * 0.28), height: min(7, size * 0.28))
            .padding(1).background(plane, in: Circle())
            .offset(x: 1, y: 1)
            .accessibilityHidden(true)
        }
      }
  }
}

/// The colour of the words under a name, by their tone (`AssistantRowWords`).
extension Palette {
  func rowTone(_ tone: AssistantRowWords.Tone) -> Color {
    switch tone {
    case .working: return success
    case .needsYou: return warning
    case .failed: return danger
    case .faint: return faint
    case .quiet: return secondary
    }
  }
}

/// The pinned assistants as faces in a grid at the top of the list, in pin order, each with its
/// name under it. A click opens its chat; a drag reorders the pins, and out of the grid unpins
/// (`AssistantDragController`). In the sidebar's rail every assistant is such a face, with no
/// name under it and its name as its help; one that is not pinned offers Pin.
struct PinnedAssistantTile: View {
  @ObservedObject var relay: RelayOrchestrator
  let profile: RelayProfile
  let status: SereinStatus
  var selection: Namespace.ID
  var selected: Bool
  var pinned = true
  @ObservedObject private var board = AssistantSidebarState.shared
  @ObservedObject private var rowState = AssistantRowState.shared
  @State private var hovered = false
  @Environment(\.palette) var p
  @Environment(\.sidebarRail) private var rail
  var body: some View {
    Button(action: open) {
      let face = AssistantRowFace(profile: profile, status: status, size: rail ? AssistantMetrics.railFace : 40,
                                  plane: selected ? p.raised : p.sidebar, provider: AssistantRowFace.provider(relay, profile))
      if rail {
        face.frame(width: AssistantMetrics.railTile.width, height: AssistantMetrics.railTile.height)
      } else {
        VStack(spacing: 4) {
          face
          Text(verbatim: profile.name).font(AssistantType.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
        }
        .padding(.vertical, 6).padding(.horizontal, 2).frame(maxWidth: .infinity)
      }
    }
    .buttonStyle(AssistantListRowStyle(selected: selected, hovered: hovered, selection: selection, fitsContent: true))
    .sidebarRailCentred(rail)
    .onHover { hovered = $0 }
    .contextMenu { Button(pinned ? "Unpin" : "Pin") { togglePin() } }
    .help(profile.name)
    .accessibilityLabel(pinned ? "\(profile.name), pinned" : profile.name)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint("Opens its chat")
    .accessibilityAction(named: pinned ? "Unpin" : "Pin") { togglePin() }
    .accessibilityAction(named: "Move up") { rowState.orderPins(AssistantRowRules.movingPin(profile.id, step: -1, in: rowState.pinned)) }
    .accessibilityAction(named: "Move down") { rowState.orderPins(AssistantRowRules.movingPin(profile.id, step: 1, in: rowState.pinned)) }
  }
  private func open() {
    board.lastClicked = (nil, profile.id)
    let switching: Bool = relay.team.activeID != profile.id
    guard relay.openAssistant(profile.id) else { return }
    if switching { board.switched() }
  }
  private func togglePin() {
    if pinned { rowState.unpin(profile.id) } else { rowState.pin(profile.id) }
  }
}

/// Where a row lands to be pinned while nothing is: shown at the top of the list during the drag.
struct PinDropZone: View {
  static let height: CGFloat = 52
  var over: Bool
  @Environment(\.palette) var p
  var body: some View {
    RoundedRectangle(cornerRadius: AssistantMetrics.listRowRadius)
      .strokeBorder(over ? p.accent : p.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      .background(over ? p.selected : .clear, in: RoundedRectangle(cornerRadius: AssistantMetrics.listRowRadius))
      .overlay { Text("Drop here to pin").font(AssistantType.meta).foregroundStyle(over ? p.ink : p.secondary) }
      .frame(height: Self.height)
      .accessibilityHidden(true)
  }
}

/// The card a click opens right under a row (`card-profile`, SPEC.md 2.3): the face at 40, the
/// name in the title size, its job on one line, its team, the counts as chips (Routines,
/// Remembers, Apps: each posts the person's words, and Serein answers), the logos of its apps,
/// and Message, which opens its chat with the keyboard in the message bar. A paused assistant
/// shows how to start it again and a Resume chip instead. The card never holds a form.
struct AssistantDetailsCard: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var hub: AgentHub
  /// `relay.desk`: it publishes on its own (the owned links in Routines).
  @ObservedObject var desk: AssistantDesk
  let profile: RelayProfile
  var close: () -> Void
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var composio = ComposioApps.shared
  /// Its notes, read once when the card opens (another assistant's are in its own folder).
  @State private var remembered: Int? = nil
  @Environment(\.palette) var p
  private var scope: AssistantScope { relay.effectiveScope(profile) ?? relay.personScope }
  private var isMain: Bool { profile.id == relay.team.main?.id }
  private var job: String {
    if isMain { return "Your chief of staff" }
    if let job = AssistantRoster.job(of: profile) { return job }
    if let label = profile.label, !label.isEmpty { return label }
    return "No job yet. Tell \(profile.name) what to do."
  }
  private var team: String? {
    guard let first = relay.team.groups(of: profile.id).first else { return nil }
    return "In the \(first.name) team"
  }
  /// Its routines, watches and links (SPEC.md 2.3).
  private var routines: Int {
    let schedules: Int = relay.reminders.filter { $0.profileID == profile.id && $0.action }.count
    let watches: Int = relay.watches.filter { $0.profileID == profile.id }.count
    let links: Int = desk.links.filter { $0.spec.owner == profile.id }.count
    return schedules + watches + links
  }
  /// The Mac's own apps it may use, then the apps connected through Composio.
  private var macApps: [AssistantPlace] { AssistantCardCounts.macApps(scope.destinations) }
  private var connected: [String] {
    guard scope.destinations.contains(.connectedApps) else { return [] }
    var seen = Set<String>()
    return composio.accounts.filter(\.active).map(\.app).filter { seen.insert($0).inserted }
  }
  var body: some View {
    let status: SereinStatus = relay.assistantStatus(
      profile.id, hub: hub, online: SereinSurface.online(network.online), connected: SereinSurface.connected(relay.agent),
      unread: surface.unread)
    VStack(spacing: 12) {
      AssistantMark(profile: profile, size: 40, status: status)
      VStack(spacing: 3) {
        Text(verbatim: profile.name).font(AssistantType.title).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
        Text(verbatim: job).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        if let team { Text(verbatim: team).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1) }
      }
      counts
      if !macApps.isEmpty || !connected.isEmpty { logos }
      if status == .paused {
        Text(verbatim: "Paused. Say “resume \(profile.name)” to start it again.").font(AssistantType.meta)
          .foregroundStyle(p.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        QuickReplyChip(text: "Resume") { post("Resume \(profile.name)") }
      } else {
        actions
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .assistantCard(p)
    .pressGuard(profile.id)
    .padding(.top, 4).padding(.bottom, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(profile.name) details")
    .onExitCommand(perform: close)
    .task(id: profile.id) { remembered = Self.notes(relay, profile.id) }
  }
  /// Message, the primary, and beside it a quiet Settings that opens its page in Settings ›
  /// Assistants.
  private var actions: some View {
    HStack(spacing: 8) {
      Button(action: message) {
        Text("Message").font(AssistantType.body).foregroundStyle(p.onSolid)
          .frame(maxWidth: .infinity).frame(height: 32)
          .background(p.solid, in: Capsule())
      }.buttonStyle(AssistantPressStyle())
        .help("Open \(profile.name)'s chat")
        .accessibilityLabel("Message \(profile.name)")
      Button { AssistantSettingsKey.open(profile.id) } label: {
        Text("Settings").font(AssistantType.body).foregroundStyle(p.ink)
          .padding(.horizontal, 12).frame(height: 32)
          .background(p.track, in: Capsule())
      }.buttonStyle(AssistantPressStyle())
        .fixedSize()
        .help("Open \(profile.name)'s settings")
        .accessibilityLabel("\(profile.name) settings")
    }
  }
  /// Each count is as wide as its words (at 232 points three equal columns would shrink
  /// "Remembers"); the space left sits on both sides of each divider.
  private var counts: some View {
    let apps: Int = macApps.count + connected.count
    return HStack(spacing: 0) {
      count(routines, one: "Routine", many: "Routines", words: AssistantCardCounts.routinesWords)
      countDivider
      count(remembered, one: "Remembers", many: "Remembers", words: AssistantCardCounts.remembersWords)
      countDivider
      count(apps, one: "App", many: "Apps", words: AssistantCardCounts.appsWords)
    }
  }
  private var countDivider: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      Rectangle().fill(p.line).frame(width: 1, height: 28)
      Spacer(minLength: 0)
    }
  }
  /// A count is a chip: it posts the person's words in this assistant's chat.
  private func count(_ value: Int?, one: String, many: String, words: String) -> some View {
    let number: String = value.map { "\($0)" } ?? "–"
    let label: String = AssistantCardCounts.label(value ?? 0, one: one, many: many)
    return Button { post(words) } label: {
      VStack(spacing: 2) {
        Text(number).font(AssistantType.figures).foregroundStyle(p.ink)
        Text(label).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
      }
      .padding(.horizontal, 6).frame(minHeight: 36).contentShape(Rectangle())
    }
    .buttonStyle(AssistantPressStyle())
    .help(words)
    .accessibilityLabel("\(number) \(label.lowercased())")
    .accessibilityHint(words)
  }
  /// Its apps' logos at 20 points, at most 5, then "+n".
  private var logos: some View {
    let total: Int = macApps.count + connected.count
    let shownMac: [AssistantPlace] = Array(macApps.prefix(AssistantCardCounts.maxLogos))
    let room: Int = max(0, AssistantCardCounts.maxLogos - shownMac.count)
    let shownApps: [String] = Array(connected.prefix(room))
    let more: Int = total - shownMac.count - shownApps.count
    return HStack(spacing: 6) {
      ForEach(shownMac, id: \.self) { place in
        MacAppIcon(bundleID: Self.bundleID(place), size: 20).frame(width: 20, height: 20)
      }
      ForEach(shownApps, id: \.self) { slug in
        BrandLogo(Brand.app(slug), size: 20, name: ConnectedApps.name(slug))
      }
      if more > 0 { Text("+\(more)").font(AssistantType.figures).foregroundStyle(p.secondary) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Apps: " + (macApps.map(\.label) + connected.map { ConnectedApps.name($0) }).joined(separator: ", "))
  }
  static func bundleID(_ place: AssistantPlace) -> String {
    switch place {
    case .mail: return "com.apple.mail"
    case .messages: return "com.apple.MobileSMS"
    case .calendar: return "com.apple.iCal"
    case .contacts: return "com.apple.AddressBook"
    default: return "com.apple.finder"
    }
  }
  /// Its chat, where Serein is, with the keyboard in the message bar.
  private func message() {
    guard relay.openAssistant(profile.id) else { return }
    NotificationCenter.default.post(name: SereinSurface.focus, object: nil)
    close()
  }
  /// The person's words in this assistant's chat (its host answers them). While a reply runs they
  /// wait in the queue, as words typed in the message bar do (`interrupt: false`).
  private func post(_ words: String) {
    guard relay.openAssistant(profile.id) else { return }
    relay.ask(words, interrupt: false)
  }
  /// How many notes it keeps: the active assistant's are loaded; another's are read from its folder.
  static func notes(_ relay: RelayOrchestrator, _ id: String) -> Int {
    if id == relay.team.activeID { return relay.notes.count }
    let path: String = relay.team.folder(id) + "/notes.json"
    return relay.browser.library.load([RelayNote].self, from: path)?.count ?? 0
  }
}

/// ⌥⌘↑ and ⌥⌘↓ anywhere in the window, and ↑ ↓ in the assistant list: the assistant above or
/// below in the list's order becomes the one you talk to at once (no slide: nothing in the chat
/// moves, so the swap is inside 0.12 s) and its details close. The chats next to it are loaded
/// ahead. ⇧⌘L opens the Library view. A switch that the active assistant's reply refuses still
/// says why in its toast.
@MainActor enum AssistantSwitcher {
  private static var monitor: Any?
  nonisolated static let upKey: UInt16 = 126
  nonisolated static let downKey: UInt16 = 125
  nonisolated static let libraryKey: UInt16 = 37

  static func install() {
    guard monitor == nil, !RunMode.checking else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let flags: NSEvent.ModifierFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
      let code: UInt16 = event.keyCode
      if flags == [.command, .shift] && code == AssistantSwitcher.libraryKey {
        MainActor.assumeIsolated { AssistantLibraryView.open() }
        return nil
      }
      guard flags == [.command, .option] else { return event }
      guard code == AssistantSwitcher.upKey || code == AssistantSwitcher.downKey else { return event }
      let direction: Int = code == AssistantSwitcher.upKey ? -1 : 1
      let handled: Bool = MainActor.assumeIsolated { AssistantSwitcher.step(direction) }
      return handled ? nil : event
    }
  }

  /// One step up (−1) or down (+1) the list. True when an assistant is there.
  @discardableResult static func step(_ direction: Int) -> Bool {
    guard let relay = SereinSurface.controller?.relay else { return false }
    let order: [String] = listOrder(relay)
    guard let next = AssistantSwitchOrder.neighbour(of: relay.team.activeID, step: direction, in: order) else { return false }
    let board = AssistantSidebarState.shared
    board.lastClicked = (nil, next)
    if board.detailsKey != nil { board.detailsKey = nil }
    let opened: Bool = relay.openAssistant(next)
    if opened {
      board.switched()
      preloadSoon(relay)
    }
    return true
  }

  /// The list's order (`AssistantRowRules.order`): Serein unless it is pinned, the pins, then the
  /// other assistants that show, by section (`AssistantSections.arrange` with the person's own
  /// order). Hidden rows are skipped.
  static func listOrder(_ relay: RelayOrchestrator) -> [String] {
    let hub: AgentHub = relay.agent.hub
    let online: Bool = SereinSurface.online(NetworkMonitor.shared.online)
    let connected: Bool = SereinSurface.connected(relay.agent)
    let unread: Bool = SereinSurface.main.unread
    let mainID: String? = relay.team.main?.id
    let others: [RelayProfile] = relay.team.profiles.filter { $0.id != mainID }
    let rows: [AssistantSections.Row] = others.map {
      AssistantSections.Row(
        id: $0.id, status: relay.assistantStatus($0.id, hub: hub, online: online, connected: connected, unread: unread))
    }
    let board = AssistantSidebarState.shared
    let layout: AssistantRowRules.Layout = AssistantRowRules.layout(
      main: mainID, rows: rows, marks: AssistantRowState.shared.marks, active: relay.team.activeID,
      revealed: board.revealHidden)
    let parts: [AssistantSections.Part] = AssistantSections.arrange(layout.rest, manualOrder: board.manualOrder)
    return AssistantRowRules.order(layout, parts: parts)
  }

  /// Loads the chats before and after the active one, after this frame.
  static func preloadSoon(_ relay: RelayOrchestrator) {
    Task { @MainActor in preload(relay) }
  }
  static func preload(_ relay: RelayOrchestrator) {
    let order: [String] = listOrder(relay)
    for id in AssistantSwitchOrder.around(relay.team.activeID, in: order) {
      _ = relay.knownMainThread(of: id)
    }
  }
}
