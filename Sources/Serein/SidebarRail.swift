import SereinCore
import SwiftUI

/// Serein's face where it is drawn small and still (the rail, the top of its chat when the live
/// hologram is off): the hologram's five orbits, as the header film ends on them, and the bright
/// core. It glows only where it greets. It costs nothing on screen; the live hologram stays where
/// it runs.
struct SereinHologramMark: View {
  var size: CGFloat
  /// While Serein works its orbits turn, a full turn in 14 seconds (still under Reduce Motion
  /// and in previews).
  var turning = false
  /// The halo and glow, for the welcome only; everywhere else the mark stays flat.
  var glows = false
  /// A look's own colour (the customise sheet's tiles); nil is the theme's.
  var tint: Color? = nil
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let ring = max(1, size / 30)
    let moves = turning && !reduceMotion && !previewReducedEffects && !RunMode.previewing
    ZStack {
      if glows {
        Circle().fill(RadialGradient(
          colors: [p.accent.opacity(p.isDark ? 0.42 : 0.2), p.accent.opacity(0)],
          center: .center, startRadius: 0, endRadius: size / 2))
      }
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moves)) { context in
        let angle = moves ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 14) / 14 * 360 : 0
        ZStack {
          ForEach(0..<5) { i in
            Ellipse().stroke(tint ?? p.hologramLine, lineWidth: ring).frame(width: size * 0.4, height: size * 0.86)
              .rotationEffect(.degrees(Double(i) * 36))
          }
        }.rotationEffect(.degrees(angle))
      }.shadow(color: glows ? p.accent.opacity(p.isDark ? 0.75 : 0.35) : .clear, radius: size / 18)
      Circle().fill(tint ?? p.hologramCore).frame(width: max(3, size * 0.1), height: max(3, size * 0.1))
        .shadow(color: glows ? p.accent : .clear, radius: size / 12)
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}

/// A round icon button (Serein's header): a `track` disc, the hover wash on
/// hover and the pressed wash while held.
struct RoundIconButtonStyle: ButtonStyle {
  var size: CGFloat = 32
  func makeBody(configuration: Configuration) -> some View {
    RoundIconBody(configuration: configuration, size: size)
  }
  private struct RoundIconBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @State private var hovered = false
    @Environment(\.palette) var p
    @Environment(\.isEnabled) var enabled
    var body: some View {
      configuration.label.frame(width: size, height: size)
        .background(Circle().fill(configuration.isPressed ? p.selected : hovered && enabled ? p.hover : p.track))
        .contentShape(Circle()).onHover { hovered = $0 }
        .opacity(enabled ? 1 : 0.5)
        .pressFeedback(configuration.isPressed)
    }
  }
}

/// Call in Serein's full header: a voice conversation (hold to talk, replies read aloud), and
/// End the call while one is on. The ⋯ menu's Voice Conversation is the same switch.
struct SereinCallButton: View {
  @ObservedObject var controller: RelayController
  let name: String
  @Environment(\.palette) var p
  var body: some View {
    Button { controller.callMode.toggle() } label: {
      InterfaceIcon(systemName: controller.callMode ? "phone.down.fill" : "phone.fill", size: 13)
        .foregroundStyle(controller.callMode ? p.danger : p.ink)
    }.buttonStyle(RoundIconButtonStyle(size: 30))
      .help(controller.callMode ? "End the call" : "Call \(name) · hold to talk, replies are read aloud")
      .accessibilityLabel(controller.callMode ? "End the call" : "Call \(name)")
  }
}

/// Routes sidebar requests, including old Agents requests, to Serein.
@MainActor enum SidebarPlaces {
  /// View › Serein ⌃1: the place's raw `SidebarMode` value in `mode`.
  static let go = Notification.Name("SereinSidebarGo")
  /// Shows Serein with its assistants.
  static func show(_ mode: SidebarMode, browser: BrowserModel) {
    switch mode {
    case .assistants, .serein:
      // Serein's own chat: another assistant answering there gives way first (refused mid-reply).
      if let relay = SereinSurface.controller?.relay, let main = relay.team.main, relay.team.activeID != main.id,
        !relay.openAssistant(main.id) { return }
      SereinRouter.showFull()
    }
  }
}


/// The sidebar's rail, under the title bar: Serein (with its crew) and Agents, the two places the
/// panel beside it lists one at a time, then History; Settings and the person's initial at its
/// foot. A click shows that place and its list. Serein's button carries its state as a dot (amber
/// Needs you, accent a reply you have not seen or one on its way) and counts the tasks at work; a
/// dragged tab held on it springs its list open (AssistantDrop).
struct SidebarRail: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var mode: SidebarMode
  var choose: (SidebarMode) -> Void
  @ObservedObject private var hub: AgentHub
  @ObservedObject private var drop = AssistantDrop.shared
  @ObservedObject private var chatSetup = SereinChatSetup.shared
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var network = NetworkMonitor.shared
  @Environment(\.palette) var p
  init(browser: BrowserModel, agent: AgentModel, mode: SidebarMode, choose: @escaping (SidebarMode) -> Void) {
    self.browser = browser
    self.agent = agent
    self.mode = mode
    self.choose = choose
    hub = agent.hub
  }
  var body: some View {
    let relay = SereinSurface.controller?.relay
    VStack(spacing: 8) {
      if let relay {
        marked(on: mode == .serein) {
        SereinRailButton(relay: relay, agent: agent, hub: hub, selected: mode == .serein, online: network.online,
                         unread: surface.unread, lit: drop.springing) { choose(.serein) }
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentBubbleLayer.space)) } action: {
            AssistantDrop.shared.switchFrame = $0
          }
        }
      } else {
        Button { choose(.serein) } label: { InterfaceIcon(systemName: SereinRailButton.symbol, size: 16) }
          .buttonStyle(RailButtonStyle(selected: mode == .serein)).help(SidebarMode.serein.help)
          .accessibilityLabel("Serein").accessibilityAddTraits(mode == .serein ? .isSelected : [])
      }
      Rectangle().fill(p.line).frame(width: 22, height: 1).padding(.vertical, 4).accessibilityHidden(true)
      Spacer(minLength: 8)
      Button { browser.showMarketplace = true } label: { InterfaceIcon(systemName: "square.grid.2x2.badge.plus", size: 16) }
        .buttonStyle(RailButtonStyle(selected: browser.showMarketplace)).help("Marketplace").accessibilityLabel("Marketplace")
      Button { browser.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 15)) }
        .buttonStyle(RailButtonStyle(selected: false)).help("Settings").accessibilityLabel("Settings")
      if let name = chatSetup.state.personName, let initial = name.first {
        Text(String(initial).uppercased()).font(UIStyle.font(12, weight: .semibold)).foregroundStyle(.white)
          .frame(width: 28, height: 28).background(p.userBubble, in: Circle())
          .help("Serein calls you \(name)").accessibilityLabel("You: \(name)").padding(.top, 2)
      }
    }.frame(width: 52).padding(.bottom, 6)
      .accessibilityElement(children: .contain).accessibilityLabel("Places")
      .onAppear {
        // The name lives with the chat setup, read from the library once (never while drawing).
        if let relay { _ = chatSetup.personName(relay) }
      }
  }
  /// A rail button across the rail's width, with a 3-point ink bar on the rail's leading edge
  /// beside its icon while its place shows (rounded on its inner side, like a tab marker).
  private func marked<Content: View>(on: Bool, @ViewBuilder _ content: () -> Content) -> some View {
    content().frame(width: 52)
      .overlay(alignment: .topLeading) {
        if on {
          UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2, style: .continuous)
            .fill(p.ink).frame(width: 3, height: 20).padding(.top, 7).allowsHitTesting(false).accessibilityHidden(true)
        }
      }
  }
}
/// Serein's rail button: the chats place, with Serein's state as a dot.
private struct SereinRailButton: View {
  static let symbol = "bubble.left"
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  let selected: Bool
  let online: Bool
  let unread: Bool
  /// A dragged tab waits on it.
  var lit = false
  let action: () -> Void
  @ObservedObject private var tray = SereinTray.shared
  @ObservedObject private var rowState = AssistantRowState.shared
  @Environment(\.palette) var p
  var body: some View {
    let status = SereinSurface.status(relay: relay, agent: agent, hub: hub, online: online, unread: unread)
    let name = relay.team.main?.name ?? RelayTeam.mainName
    // A row of Serein's list marked unread lights the dot too, and its words name whose reply it is
    // ("New reply from Scout"), as the sidebar's switch did.
    let marked: String? = relay.team.profiles.first { rowState.unread.contains($0.id) }?.name
    let extra: String = marked.flatMap { AssistantBoard.words(.unread($0)) }.map { " · " + $0 } ?? ""
    Button(action: action) {
      // A place, drawn like the rail's other places. Serein's face is its row and its chat's top.
      InterfaceIcon(systemName: Self.symbol, size: 16)
        .overlay(alignment: .topTrailing) {
          if let dot = dot(status) ?? (marked != nil ? p.accent : nil) {
            Circle().fill(dot).frame(width: 8, height: 8).overlay(Circle().strokeBorder(p.sidebar, lineWidth: 1.5))
              .offset(x: 3, y: -3)
          }
        }
    }.buttonStyle(RailButtonStyle(selected: selected, lit: lit))
      .help("\(name) · \(SidebarMode.serein.shortcut) · \(status.spoken)\(extra)")
      .accessibilityLabel(name).accessibilityValue(status.spoken + extra)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .contextMenu { SereinRowMenuItems(name: name) }
  }
  private func dot(_ status: SereinStatus) -> Color? {
    switch status {
    case .needsYou: return p.warning
    case .unread, .replying: return p.accent
    default: return nil
    }
  }
}
/// A rail button: a 34-point target, the raised plate while its place
/// is listed, the hover and pressed washes otherwise (`lit`: the hover wash while a dragged tab
/// waits on it).
private struct RailButtonStyle: ButtonStyle {
  var selected: Bool
  var lit = false
  func makeBody(configuration: Configuration) -> some View {
    RailBody(configuration: configuration, selected: selected, lit: lit)
  }
  private struct RailBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let lit: Bool
    @State private var hovered = false
    @Environment(\.palette) var p
    var body: some View { icon.onHover { hovered = $0 } }
    private var icon: some View {
      let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
      return configuration.label.foregroundStyle(selected ? p.ink : p.secondary)
        .frame(width: 34, height: 34).contentShape(shape)
        .background {
          ZStack {
            if selected {
              shape.fill(p.raised).shadow(color: p.shadow(0.45), radius: 2.5, y: 1)
            } else if configuration.isPressed {
              shape.fill(p.selected)
            } else if hovered || lit {
              shape.fill(p.hover)
            }
          }
        }
    }
  }
}
/// The panel beside the rail, with no title row (the rail says where you are): Serein lists its
/// row, the pages it uses, its crew and what is coming up; Agents the overview, New task, the
/// tasks at work and every AI app with its task chats; Browser New tab, the pinned tiles, the pages
/// Serein uses and the tabs.
struct SidebarPanel: View {
  let mode: SidebarMode
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var selection: Namespace.ID
  @ObservedObject private var updates = Updates.shared
  var body: some View {
    VStack(spacing: 0) {
      switch mode {
      case .assistants: AgentsPanelList(browser: browser, agent: agent, hub: agent.hub, selection: selection)
      case .serein:
        SidebarPanelScroll {
          if let relay = SereinSurface.controller?.relay {
            SereinPanelList(relay: relay, browser: browser, agent: agent, hub: agent.hub, selection: selection)
          } else {
            SereinTabRow(browser: browser, agent: agent, selection: selection)
          }
        }
      }
      if updates.pending != nil { UpdateButton(wide: true).padding(.top, 8) }
    }.padding(.bottom, 6)
  }
}

/// The part of the panel that scrolls. A list keeps anything pinned below it outside this.
struct SidebarPanelScroll<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.top, 2).padding(.bottom, 12)
    }.scrollIndicators(.automatic).frame(maxHeight: .infinity)
      // Where a carried tab may land on a row (AssistantDrop).
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentBubbleLayer.space)) } action: {
        AssistantDrop.shared.listFrame = $0
      }
  }
}


/// Serein's list, its crew in one place: Serein's tile, which is the main assistant's row (its
/// state, its details card under it, the pages it and your own tasks use, its computer); the teams
/// as contacts; the assistant list (`AssistantSidebarList`: pins, sections, hidden rows, the row
/// menu, each row's details card, pages and computer, New assistant); then Coming up, the next
/// three reminders and scheduled requests. Their work shows inside Serein's one conversation and in
/// Now beside it.
struct SereinPanelList: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  var selection: Namespace.ID
  @ObservedObject private var tray = SereinTray.shared
  @ObservedObject private var placement = SereinSurface.main.placement
  @ObservedObject private var board = AssistantSidebarState.shared
  @ObservedObject private var drag = AssistantDragController.shared
  @Environment(\.palette) private var p
  /// The rail keeps the pictures: Serein, the three places, the teams and the assistants' faces.
  /// The pages they use, New assistant and Coming up need the list.
  @Environment(\.sidebarRail) private var rail
  var body: some View {
    let mainID: String? = relay.team.main?.id
    let upcoming = relay.reminders
      .filter { !rail && !TodoBoard.isReminder($0.id) && $0.paused != true && $0.due > Date() }
      .sorted { $0.due < $1.due }.prefix(3)
    VStack(alignment: .leading, spacing: 2) {
      SereinContactRow(relay: relay, browser: browser, agent: agent, selection: selection)
      if !rail {
        HandedPageRows(browser: browser, selection: selection)
        // The pages Serein and your own tasks use; every other assistant's show under its row.
        SereinChildRows(browser: browser, board: browser.agentTabs, selection: selection,
                        except: Set(relay.team.profiles.map(\.id).filter { $0 != mainID }))
      }
      // A caption only over a crew; a first run sees no headings, and Add an assistant once Serein can think.
      let crew: Bool = !relay.team.teams.isEmpty || relay.team.profiles.count > 1
      if crew { SidebarCaption("Assistants").padding(.top, 10) }
      // The rest of the crew: the teams as contacts, then every other assistant in the list.
      VStack(alignment: .leading, spacing: 2) {
        ForEach(relay.team.teams, id: \.id) { group in
          TeamContactRow(relay: relay, group: group, selection: selection,
                         selected: relay.activeTeamID == group.id && browser.section == ShellSection.serein && placement.view == .chat,
                         dropping: drag.drag?.over == "team:\(group.id)" && drag.refusal(over: "team:\(group.id)", relay: relay) == nil) {
            _ = relay.openTeam(group.id)
            SereinRouter.showFull()
          }
            .contextMenu { TeamMenuItems(relay: relay, group: group) { AssistantConfirm.renameTeam(relay, group) } }
        }
        AssistantSidebarList(browser: browser, agent: agent, selection: selection, includesMain: false)
        if !rail, SereinSurface.connected(agent) { NewAssistantRow(selection: selection) }
        // The rail has room for neither that row nor the title bar's +: one + tile opens both.
        if rail { RailCreateTile(selection: selection) }
      }
      .padding(.top, crew ? 0 : 10)
      // Rows dragged from the list below land on the teams here.
      .coordinateSpace(name: AssistantDragController.space)
      .onPreferenceChange(AssistantRowFrameKey.self) { drag.frames = $0 }
      if !upcoming.isEmpty {
        SidebarCaption("Coming up").padding(.top, 10)
        ForEach(Array(upcoming), id: \.id) { reminder in
          SidebarReminderRow(reminder: reminder)
        }
      }
    }
  }
  /// As Messages dates a conversation: the time today, Yesterday, the weekday this week, else the date.
  static func when(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

/// A section's name in a panel, in small capitals: Recent, Coming up, Working now… The rail has
/// no room for the name and draws a hairline in its place.
struct SidebarCaption: View {
  let title: String
  init(_ title: String) { self.title = title }
  @Environment(\.palette) var p
  @Environment(\.sidebarRail) private var rail
  var body: some View {
    if rail {
      SidebarRailLine()
    } else {
      Text(title).font(UIStyle.font(11.5, weight: .medium)).foregroundStyle(p.faint)
        .lineLimit(1).padding(.horizontal, 10).frame(height: UIStyle.wide(22), alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader).accessibilityLabel(title)
    }
  }
}




/// A reminder or scheduled request coming up: a bell (repeat for one that repeats), its words
/// and when. A click opens Settings › Serein, which lists them all.
private struct SidebarReminderRow: View {
  let reminder: RelayReminder
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    let when = SidebarRemindersWhen.when(reminder.due)
    Button { RelayController.shared?.openSettings("Relay") } label: {
      HStack(spacing: 10) {
        InterfaceIcon(systemName: reminder.repeats == .none ? "bell" : "repeat", size: 13)
          .foregroundStyle(p.secondary).frame(width: 16)
        Text(reminder.text).font(UIStyle.font(13)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 4)
        Text(when).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
      }.padding(.leading, 10).padding(.trailing, 8).frame(height: UIStyle.sidebarRowHeight)
        .background(hovered ? p.hover : .clear, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
        .contentShape(Rectangle())
    }.buttonStyle(.pressable).onHover { hovered = $0 }
      .help("\(reminder.text) · \(when) · Runs on this Mac while it is awake and Serein is open · Settings › Serein lists them all")
      .accessibilityLabel("\(reminder.action ? "Scheduled" : "Reminder"): \(reminder.text), \(when)")
  }
}
/// When a schedule comes due, in few words: “4:00 PM” today, “Tue 8:00 AM” this week, else “Nov 2”.
enum SidebarRemindersWhen {
  static func when(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return time }
    if date.timeIntervalSinceNow < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

/// A team in Serein's list: its pictures and name, on an ordinary row.
private struct TeamContactRow: View {
  @ObservedObject var relay: RelayOrchestrator
  let group: AssistantGroup
  var selection: Namespace.ID
  let selected: Bool
  /// An assistant dragged from the list is over this row and may join.
  var dropping = false
  let open: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p
  @Environment(\.sidebarRail) private var rail
  var body: some View {
    Button(action: open) {
      if rail {
        TeamFaceStack(relay: relay, group: group, size: AssistantMetrics.railFace * 0.62, ground: selected ? p.selected : p.sidebar, limit: 2, counts: false)
          .frame(width: AssistantMetrics.railTile.width, height: AssistantMetrics.railTile.height)
      } else {
        HStack(spacing: AssistantMetrics.listRowGap) {
          TeamFaceStack(relay: relay, group: group, size: AssistantMetrics.listFace * 0.62, ground: selected ? p.selected : p.sidebar, limit: 2, counts: false)
            .frame(width: AssistantMetrics.listFace)
          Text(verbatim: group.name).font(UIStyle.font(12.5)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, AssistantMetrics.listRowPaddingH).padding(.vertical, AssistantMetrics.listRowPaddingV)
      }
    }
    .buttonStyle(AssistantListRowStyle(selected: selected, hovered: hovered || dropping, selection: selection, fitsContent: rail))
    .sidebarRailCentred(rail)
    .help(rail ? group.name : "")
    .background {
      GeometryReader { geometry in
        Color.clear.preference(key: AssistantRowFrameKey.self,
                               value: ["team:\(group.id)": geometry.frame(in: .named(AssistantDragController.space))])
      }
    }
    .onHover { hovered = $0 }
    .accessibilityLabel(group.name)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// Serein's two actions on the sidebar's title bar, drawn like the hide-sidebar toggle beside the
/// lights (bare 14-point glyphs on the hover plate): Search, which opens the Search palette
/// (`SearchPaletteCenter`), and New Serein, which opens the New Serein dialog.
struct SidebarSereinActions: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @Environment(\.palette) var p
  var body: some View {
    HStack(spacing: 2) {
      Button { SearchPaletteCenter.shared.open = true } label: { glyph("magnifyingglass") }
        .buttonStyle(GhostChromeStyle()).help("Search · ⌘K").accessibilityLabel("Search")
      Button {
        NotificationCenter.default.post(name: AssistantSidebarState.newAssistant, object: nil)
      } label: { glyph("plus") }
        .buttonStyle(GhostChromeStyle()).help("New Serein · ⌃⌘N").accessibilityLabel("New Serein")
    }
  }
  private func glyph(_ symbol: String) -> some View {
    // The glass draws heavier than the plus at the same size: a point smaller evens them.
    InterfaceIcon(systemName: symbol, size: symbol == "magnifyingglass" ? 13 : 14).foregroundStyle(p.ink.opacity(0.85))
  }
}

/// Serein, the person's own assistant, at the top of its list, drawn as a row of the assistant
/// list: the drawn hologram mark (its orbits turn while it works), a status dot and its name. Words
/// appear only for a state nothing else shows (Paused); help and VoiceOver always say the state.
/// The live hologram is the picture at the top of its chat (`SereinChatTop`). Its right-click menu adds the row menu's items (Mark as unread, Copy
/// chat, Choose AI app…, Settings…, Rename…), a row's unread mark lights the dot at its end,
/// VoiceOver's Open details opens its details card, and it takes the same drops as an assistant
/// row (AssistantDrop).
private struct SereinContactRow: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var selection: Namespace.ID
  @ObservedObject private var surface = SereinSurface.main.placement
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var rowState = AssistantRowState.shared
  @ObservedObject private var board = AssistantSidebarState.shared
  @State private var hovered = false
  @Environment(\.palette) var p
  @Environment(\.sidebarRail) private var rail
  private var choosing: Binding<Bool> {
    Binding(
      get: { board.choosingApp != nil && board.choosingApp == relay.team.main?.id },
      set: { open in if !open, board.choosingApp == relay.team.main?.id { board.choosingApp = nil } })
  }
  var body: some View {
    let status = SereinSurface.status(relay: relay, agent: agent, hub: agent.hub, online: network.online, unread: SereinSurface.main.unread)
    let main: RelayProfile? = relay.team.main
    // A row's unread mark (Mark as unread, or a reply that landed while its chat was away).
    let marked: Bool = main.map { rowState.unread.contains($0.id) } ?? false
    let showing = browser.section == ShellSection.serein && surface.view == .chat && relay.team.activeID == relay.team.main?.id
      && relay.activeTeamID == nil
    let name = relay.team.main?.name ?? RelayTeam.mainName
    // The rail draws the mark alone, at the faces' size.
    let face: CGFloat = rail ? AssistantMetrics.railFace : AssistantMetrics.listFace
    let mark = SereinHologramMark(size: face, turning: status.spins)
      .overlay(alignment: .bottomTrailing) {
        if let dot = faceDot(status) {
          Circle().fill(dot).frame(width: face * 0.28, height: face * 0.28)
            .padding(1).background(showing ? p.selected : p.sidebar, in: Circle())
            .offset(x: 1, y: 1)
        }
      }
    Button { SidebarPlaces.show(.serein, browser: browser) } label: {
      if rail {
        mark.frame(width: AssistantMetrics.railTile.width, height: AssistantMetrics.railTile.height)
      } else {
        HStack(spacing: AssistantMetrics.listRowGap) {
          mark
          HStack(spacing: 6) {
            Text(name).font(UIStyle.font(12.5)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
            if status == .paused {
              Text(status.words).font(UIStyle.font(11)).foregroundStyle(p.secondary)
                .lineLimit(1).truncationMode(.tail)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          if status == .unread || marked {
            Circle().fill(p.accent).frame(width: 8, height: 8).frame(width: 24, height: 24).accessibilityHidden(true)
          }
        }.padding(.horizontal, AssistantMetrics.listRowPaddingH).padding(.vertical, AssistantMetrics.listRowPaddingV)
      }
    }
    .buttonStyle(AssistantListRowStyle(selected: showing, hovered: hovered, selection: selection, fitsContent: rail))
    .sidebarRailCentred(rail)
    .onHover { hovered = $0 }
      .help("\(name) · \(status.spoken)").accessibilityLabel(name)
      .accessibilityValue(marked && status != .unread ? "\(status.spoken), unread" : status.spoken)
      .accessibilityAddTraits(showing ? .isSelected : [])
      .accessibilityAction(named: "Open details") { if let id = relay.team.main?.id { AssistantInspector.shared.show(id) } }
      .contextMenu {
        SereinRowMenuItems(name: name)
        if let main {
          Divider()
          AssistantRowMenuNative(items: rowItems(main))
        }
      }
      .popover(isPresented: choosing, arrowEdge: .trailing) {
        if let main { AssistantAppPicker(relay: relay, profile: main) { board.choosingApp = nil }.environment(\.palette, p) }
      }
      .modifier(MainAssistantDrop(id: main?.id))
  }
  /// The row menu's items for the main assistant, without Pin: this row always leads the list.
  /// Rename… opens its details on the right, where its name is.
  private func rowItems(_ main: RelayProfile) -> [SereinMenuItem] {
    let id: String = main.id
    return AssistantRowMenu.items(relay: relay, profile: main) { AssistantInspector.shared.show(id, tab: .details) }
      .filter { $0.title != "Pin" && $0.title != "Unpin" } + AssistantRowMenu.sereinItems(relay: relay)
  }
  /// As on every assistant row (`AssistantRowFace`): an unread reply lights the row's end instead.
  private func faceDot(_ status: SereinStatus) -> Color? {
    if status.spins { return p.success }
    return status == .needsYou ? p.warning : nil
  }
}

/// The main assistant's drops on Serein's row: files, a link, text or a tab open its chat with
/// them, as on every assistant row (AssistantDrop, key "main"); no hand-off, since it is Serein.
private struct MainAssistantDrop: ViewModifier {
  let id: String?
  @ViewBuilder func body(content: Content) -> some View {
    if let id {
      content.modifier(AssistantDropModifier(key: "main", target: .assistant(id, team: nil)))
    } else {
      content
    }
  }
}

/// A team contact's right-click menu: open its chat, rename, add an assistant, its lead,
/// Duplicate, Export and Delete. (Team headers left the assistant list; teams show as contacts.)
struct TeamMenuItems: View {
  @ObservedObject var relay: RelayOrchestrator
  let group: AssistantGroup
  var rename: () -> Void
  var body: some View {
    Button("Open Team Chat") { relay.openTeam(group.id) }
    Button("Rename…", action: rename)
    Menu("Add Assistant") {
      ForEach(relay.team.profiles.filter { !group.memberIDs.contains($0.id) }) { profile in
        Button(profile.name) { relay.addToTeam(profile.id, group.id) }
      }
      Divider()
      Button("New Serein…") { NotificationCenter.default.post(name: AssistantSidebarState.newAssistant, object: nil) }
    }
    Menu("Lead") {
      ForEach(group.memberIDs, id: \.self) { id in
        Toggle(relay.profileName(id), isOn: Binding(get: { group.leadID == id }, set: { if $0 { relay.setLead(id, of: group.id) } }))
      }
      Divider()
      Toggle("No Lead", isOn: Binding(get: { group.leadID == nil }, set: { if $0 { relay.setLead(nil, of: group.id) } }))
    }
    Button("Duplicate Team…") { TeamSheets.shared.present(.newTeam(.duplicate(group.id))) }
    Button("Export Team…") { relay.exportTeam(group.id) }
    Divider()
    Button("Delete Team…", role: .destructive) { AssistantConfirm.deleteTeam(relay, group) }
  }
}
