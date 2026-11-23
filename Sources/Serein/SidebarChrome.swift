import Combine
import SereinCore
import SwiftUI

/// One sidebar: compact navigation above the existing Serein/assistant list. Its edge drags: the
/// list widens and narrows (the pinned faces take as many columns as fit), and pulled narrower
/// than the list goes it becomes a rail of faces only, until the edge is pulled out again
/// (`SidebarWidth`). File › Toggle Sidebar (⌘\) hides it.
struct WallSidebar: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  let width: CGFloat
  @Binding var draggedWidth: CGFloat?
  @Binding var extraWidth: Double
  @Binding var rail: Bool
  var ask: () -> Void
  @Namespace private var selection
  @ObservedObject private var board = AssistantSidebarState.shared
  @Environment(\.palette) private var p
  /// The place the rail shows, saved app-wide in user defaults (`SidebarMode.key`); only the main
  /// window has a sidebar.
  @AppStorage(SidebarMode.key) private var modeRaw = SidebarMode.serein.rawValue
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  private var showsRail: Bool { draggedWidth.map { $0 <= SidebarWidth.rail } ?? rail }
  var body: some View {
    VStack(spacing: 0) {
      // The shell already insets the sidebar 8 points from the window's top and bottom edges.
      SidebarTitleBar {
        // The rail has room for the window's buttons alone.
        if !showsRail {
          Spacer(minLength: 0)
          Button { SearchPaletteCenter.shared.open = true } label: {
            InterfaceIcon(systemName: "magnifyingglass", size: 12)
          }.buttonStyle(GhostChromeStyle()).help("Search · ⌘K").accessibilityLabel("Search")
          Menu {
            SidebarCreateItems()
          } label: {
            InterfaceIcon(systemName: "plus", size: 12).foregroundStyle(p.ink.opacity(0.85))
              .frame(width: 26, height: 20).contentShape(Rectangle())
          }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(SidebarCreateItems.label).accessibilityLabel(SidebarCreateItems.label)
        }
      }.padding(.horizontal, UIStyle.chromeInset)
      SidebarPanel(mode: .serein, browser: browser, agent: agent, selection: selection)
        .padding(.horizontal, UIStyle.chromeInset).frame(maxHeight: .infinity)
      SidebarFooter(browser: browser, selection: selection).padding(.horizontal, UIStyle.chromeInset)
    }
      .frame(width: showsRail ? SidebarWidth.rail : max(width, UIStyle.sidebarUsual + SidebarWidth.extra.lowerBound))
      .frame(width: width, alignment: .leading)
      .contentShape(Rectangle())
      .clipped()
      .environment(\.sidebarRail, showsRail)
      // An assistant's details card opens and closes under its row in Serein's list.
      .animation(Motion.entering(reduceMotion), value: board.detailsKey)
      .overlay(alignment: .trailing) { sizeHandle }
      .modifier(SidebarModeCommands(modeRaw: $modeRaw, browser: browser))
  }
  private var sizeHandle: some View {
    SidebarSizeHandle(width: width, rail: showsRail, preview: { pointer in
      draggedWidth = pointer.map { SidebarWidth.dragged($0, usual: UIStyle.sidebarUsual) }
    }, settle: settle)
  }

  private func settle(_ move: SidebarWidth.Move?) {
    let now: SidebarWidth.Settled = rail ? .rail : .list(extra: SidebarWidth.clamped(extraWidth))
    let next: SidebarWidth.Settled = move.map { SidebarWidth.settle($0, from: now, usual: UIStyle.sidebarUsual) }
      ?? .list(extra: 0)
    withAnimation(reduceMotion ? nil : Motion.entering(false)) {
      draggedWidth = nil
      guard next != now else { return }
      if case .list(let extra) = next { extraWidth = Double(extra) }
      rail = next == .rail
    }
  }
}

/// The rail follows the main view; View › Serein ⌃1 and Agents ⌃2 show a place, as
/// the rail does; File › New Serein… ⌃⌘N shows Serein's list and opens the New Serein dialog.
private struct SidebarModeCommands: ViewModifier {
  @Binding var modeRaw: String
  @ObservedObject var browser: BrowserModel
  func body(content: Content) -> some View {
    content
      // History, Saved and the like leave the rail where it was.
      .onAppear { follow(browser.section) }
      .onChange(of: browser.section) { _, section in follow(section) }
      .onReceive(Self.activeAssistant) { _ in follow(browser.section) }
      .onReceive(NotificationCenter.default.publisher(for: SidebarPlaces.go)) { note in
        guard let raw = note.userInfo?["mode"] as? String, let place = SidebarMode(rawValue: raw)?.place else { return }
        modeRaw = place.rawValue
        SidebarPlaces.show(place, browser: browser)
      }
      // A dragged tab springs Serein's list open and lets it go again; New team and the like show
      // it. The main view stays.
      .onReceive(NotificationCenter.default.publisher(for: SidebarModeSwitch.showAssistants)) { _ in
        modeRaw = SidebarMode.serein.rawValue
      }
      .onReceive(NotificationCenter.default.publisher(for: AssistantSidebarState.newAssistant)) { _ in
        modeRaw = SidebarMode.serein.rawValue
        AssistantSidebarState.shared.startNaming()
      }
  }
  /// A preview sets the place for its screen and never writes the person's settings. Another
  /// assistant's chat full is one of your agents, so the Agents list stays.
  private func follow(_ section: String) {
    guard !RunMode.previewing, var place = SidebarMode.mode(for: section) else { return }
    place = place.place
    if place.rawValue != modeRaw { modeRaw = place.rawValue }
  }
  /// Who answers in Serein's surface, as it changes: the rail follows it.
  private static var activeAssistant: AnyPublisher<String, Never> {
    guard let relay = SereinSurface.controller?.relay else { return Empty().eraseToAnyPublisher() }
    return relay.$team.map(\.activeID).removeDuplicates().eraseToAnyPublisher()
  }
}

/// A sidebar section's heading: a click folds it to this line. Chats has a persistent size
/// toggle; sections with a hide action offer it on hover.
struct SidebarSectionHeading: View {
  var title: String
  var count: Int
  @Binding var folded: Bool
  var hovered: Bool
  var hide: (() -> Void)? = nil
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Button {
      setFolded(!folded)
    } label: {
      HStack(spacing: 6) {
        Text(title).font(UIStyle.meta).foregroundStyle(p.secondary)
        Text("\(count)").font(UIStyle.microMono).foregroundStyle(p.faint)
        if folded || hovered {
          InterfaceIcon(systemName: folded ? "chevron.right" : "chevron.down", size: 9).foregroundStyle(p.faint)
        }
        Spacer(minLength: 0)
      }.contentShape(Rectangle())
    }.buttonStyle(.pressable)
      .accessibilityAddTraits(.isHeader)
      .accessibilityLabel("\(title), \(count)").accessibilityValue(folded ? "Collapsed" : "Expanded")
    if let hide {
      Button("Hide", action: hide).buttonStyle(QuietButton()).font(UIStyle.micro)
        .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
        .help("Hide \(title). Settings › Appearance shows it again.").accessibilityLabel("Hide \(title)")
    } else {
      Button { setFolded(!folded) } label: {
        InterfaceIcon(systemName: folded ? "arrow.up.left.and.arrow.down.right" : "minus", size: 11)
          .frame(width: 12, height: 12)
      }.buttonStyle(QuietButton())
        .help(folded ? "Expand session history" : "Minimize session history to its heading")
        .accessibilityLabel(folded ? "Expand sessions" : "Minimize sessions")
    }
  }
  private func setFolded(_ value: Bool) {
    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { folded = value }
  }
}

/// Sizes and folds the sidebar remembers.
enum SidebarSizes {
  /// The chat list's height after a drag; 0 is its own height (up to 360 points).
  static let chatsHeightKey = "serein.sidebarChatsHeight"
  static let chatsFoldedKey = "serein.sidebar.chatsFolded"
}

/// Drag updates are transient. Only release, double-click and accessibility adjustments settle the edge.
private struct SidebarSizeHandle: View {
  let width: CGFloat
  let rail: Bool
  let preview: (CGFloat?) -> Void
  let settle: (SidebarWidth.Move?) -> Void
  @State private var startWidth: CGFloat?
  @GestureState private var dragging = false
  @State private var hovered = false
  @Environment(\.palette) var p

  var body: some View {
    Rectangle().fill(hovered || dragging ? p.borderStrong : Color.clear)
      .frame(width: 2).frame(width: 8).contentShape(Rectangle())
      .onHover { hovered = $0 }
      .onChange(of: hovered || dragging) { _, active in
        if active { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .onDisappear {
        if hovered || dragging { NSCursor.pop() }
        startWidth = nil
        preview(nil)
      }
      .onTapGesture(count: 2) { settle(nil) }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .updating($dragging) { _, active, _ in active = true }
          .onChanged { value in
            let start = startWidth ?? width
            startWidth = start
            preview(start + value.translation.width)
          }
          .onEnded { value in
            guard let startWidth else { return }
            self.startWidth = nil
            settle(.width(startWidth + value.translation.width))
          }
      )
      .onChange(of: dragging) { _, active in
        if !active, startWidth != nil {
          startWidth = nil
          preview(nil)
        }
      }
      .help("Sidebar width · double-click for the usual size")
      .accessibilityElement().accessibilityLabel("Sidebar width")
      .accessibilityValue(rail ? "Faces only" : "\(Int(width)) points")
      .accessibilityAdjustableAction { settle(.step(up: $0 == .increment)) }
  }
}

/// The rounded card at the top of the sidebar: Serein's daily drawing, with the window's
/// traffic lights placed on it by `WindowChrome` and, at its right edge, the hide-sidebar toggle.
struct SidebarHeaderCard: View {
  @ObservedObject var browser: BrowserModel
  var hideSidebar: () -> Void
  @Environment(\.palette) var p
  @Environment(\.accessibilityReduceTransparency) var systemReduceTransparency
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var opaque: Bool { systemReduceTransparency || previewReducedEffects }
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: UIStyle.headerCardRadius, style: .continuous)
    ZStack(alignment: .topLeading) {
      SidebarHeaderMedia().frame(maxWidth: .infinity).frame(height: UIStyle.headerCardHeight)
        .clipShape(shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentBubbleLayer.space)) } action: {
          WindowChrome.shared.headerCardFrame = $0
        }
        .overlay(shape.strokeBorder(p.borderStrong.opacity(0.8), lineWidth: UIStyle.hairline))
      // On the row of the traffic lights (their centres are 21 points below the card's top),
      // at the card's right edge, with or without the lights.
      SidebarHideButton(
        hide: hideSidebar,
        onFilm: SidebarHeaderMedia.showsFilm(reducedEffects: previewReducedEffects)
      )
        .padding(.top, 11).padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}

/// The sidebar's top row: the traffic lights' gutter, then its actions, as in a Mac app's title
/// bar. File › Toggle Sidebar (⌘\) hides the sidebar; the content toolbar's Show sidebar brings
/// it back. The rail is no wider than the lights, so there the row is only their height.
struct SidebarTitleBar<Trailing: View>: View {
  @ViewBuilder var trailing: Trailing
  @ObservedObject private var chrome = WindowChrome.shared
  @Environment(\.sidebarRail) private var rail
  var body: some View {
    HStack(spacing: 6) {
      if !chrome.fullScreen, !rail {
        Color.clear.frame(width: UIStyle.trafficLightGutter - UIStyle.chromeInset).accessibilityHidden(true)
      }
      trailing
    }
    // Centred on the traffic lights: their centres sit 21 points below the sidebar's top inset.
    .frame(maxWidth: .infinity).frame(height: 2 * (UIStyle.trafficLightInsetY + 7))
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentBubbleLayer.space)) } action: {
        WindowChrome.shared.headerCardFrame = $0
      }
  }
}

/// The hide-sidebar toggle at the right edge of the header card: a bare ghost icon drawn straight
/// on the card art, like the lights themselves. The content toolbar's Show sidebar brings it back.
private struct SidebarHideButton: View {
  var hide: () -> Void
  /// The film is dark in both appearances. The glyph is white on it; dark ink did not show there
  /// in the light appearance.
  var onFilm = false
  @Environment(\.palette) var p
  var body: some View {
    Button(action: hide) {
      InterfaceIcon(systemName: "sidebar.left", size: 14)
        .foregroundStyle(onFilm ? Color.white.opacity(0.9) : p.ink.opacity(0.85))
    }.buttonStyle(GhostChromeStyle(onFilm: onFilm))
      .help("Hide sidebar · ⌘\\").accessibilityLabel("Hide sidebar")
  }
}

/// Hover-only plate for controls drawn directly on the header-card art: invisible at rest,
/// the hover wash (opaque panel under reduced transparency) on hover, selected while pressed.
struct GhostChromeStyle: ButtonStyle {
  /// On the dark film the plate is a light wash, in both appearances.
  var onFilm = false
  func makeBody(configuration: Configuration) -> some View {
    GhostChromeBody(configuration: configuration, onFilm: onFilm)
  }
  private struct GhostChromeBody: View {
    let configuration: ButtonStyleConfiguration
    let onFilm: Bool
    @State private var hovered = false
    @Environment(\.palette) var p
    @Environment(\.accessibilityReduceTransparency) var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) var systemReduceMotion
    @Environment(\.sereinReducedEffects) var previewReducedEffects
    var opaque: Bool { systemReduceTransparency || previewReducedEffects }
    var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
    var body: some View {
      configuration.label.frame(width: 26, height: 20)
        .background {
          RoundedRectangle(cornerRadius: 6)
            .fill(
              // On the film the plate is a light wash; with Reduce Transparency it is a solid grey.
              onFilm
                ? (configuration.isPressed || hovered
                  ? (opaque
                    ? Color(white: configuration.isPressed ? 0.34 : 0.24)
                    : Color.white.opacity(configuration.isPressed ? 0.26 : 0.16))
                  : .clear)
                : configuration.isPressed ? p.selected
                : hovered ? (opaque ? p.panel : p.hover) : .clear)
        }
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
  }
}

/// The pages Serein is using, as indented rows under its row: the favicon, the title, and the
/// mini spinner while it works there. A click opens the page. At most three show, then “N more”,
/// which expands in place. Their lifetime follows the agent tab board: the pages of the last
/// eight finished tasks stay, and one nobody looked at for ten minutes unloads until opened.
/// Pages a task handed you (a sign-in, a check), until you close them.
struct HandedPageRows: View {
  @ObservedObject var browser: BrowserModel
  var selection: Namespace.ID
  var body: some View {
    ForEach(browser.tabs) { tab in
      SidebarTabRow(
        tab: tab, browser: browser, selection: selection, selected: browser.rowSelected(tab),
        select: { browser.show(tab) }, close: { browser.close(tab, remember: false) })
    }
  }
}

struct SereinChildRows: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var board: AgentTabBoard
  var selection: Namespace.ID
  /// Assistants mode: only the pages this assistant's tasks use (the board records the owner
  /// when a run registers); nil lists every page under the Serein row.
  var owner: String? = nil
  /// The name the help and VoiceOver use ("Writer is using this page").
  var name = "Serein"
  /// Where the site icon starts: 28 points under an assistant's row, 10 among the tabs.
  var indent: CGFloat = 28
  /// The assistants whose pages show under their own rows (Serein's tile leaves them out).
  var except: Set<String> = []
  @State private var expanded = false
  @Environment(\.palette) var p
  static let shown = 3
  var body: some View {
    let entries = board.entries.filter { entry in
      let assistant: String? = board.runs[entry.taskID]?.assistant
      return (owner == nil || assistant == owner) && !except.contains(assistant ?? "")
    }
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(expanded ? entries : Array(entries.prefix(Self.shown))) { entry in
          SereinChildRow(tab: entry.tab, browser: browser, board: board, selection: selection,
                         selected: browser.section == ShellSection.agent && board.focused == entry.id, name: name,
                         indent: indent)
        }
        if !expanded && entries.count > Self.shown {
          Button { expanded = true } label: {
            Text("\(entries.count - Self.shown) more").font(UIStyle.meta).foregroundStyle(p.secondary)
              .padding(.leading, indent + 8).frame(height: 24).frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }.buttonStyle(.pressable).help("Show every page \(name) is using")
            .accessibilityLabel("\(entries.count - Self.shown) more pages \(name) is using")
        }
      }.padding(.top, 2).accessibilityElement(children: .contain).accessibilityLabel("Pages \(name) is using")
    }
  }
}
private struct SereinChildRow: View {
  @ObservedObject var tab: BrowserTab
  @ObservedObject var browser: BrowserModel
  @ObservedObject var board: AgentTabBoard
  var selection: Namespace.ID
  var selected: Bool
  var name = "Serein"
  var indent: CGFloat = 28
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    let working = board.isWorking(tab.id)
    let ended = board.info(tab.id)?.ended == true
    // Typed apart from the long chain of modifiers below, which the type checker handles better.
    let pageHost: String = URL(string: tab.address)?.host ?? tab.address
    let helpText: LocalizedStringKey = working ? "\(name) is using this page" : "\(name) used this page · \(pageHost)"
    let stateText: LocalizedStringKey = working ? "\(name) is using this page"
      : board.unseen.contains(tab.id) ? "\(name) used this page, new result" : "\(name) used this page"
    Button { browser.viewAgentTab(tab) } label: {
      HStack(spacing: 8) {
        SiteIcon(tab: tab)
        Text(tab.title.isEmpty ? (URL(string: tab.address)?.host ?? "\(name)’s page") : tab.title)
          .font(UIStyle.font(13, weight: selected ? .medium : .regular)).foregroundStyle(p.ink)
          .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
        if working { ProgressView().controlSize(.mini).frame(width: 12, height: 12).accessibilityHidden(true) }
        else if board.unseen.contains(tab.id) { Circle().fill(p.accent).frame(width: 6, height: 6).accessibilityHidden(true) }
      }.padding(.leading, indent).padding(.trailing, 8)
    }.buttonStyle(SidebarRowStyle(selected: selected, hovered: hovered, selection: selection))
      .onHover { hovered = $0 }
      .help(helpText)
      .accessibilityLabel("\(name)’s page: \(tab.title)")
      .accessibilityValue(stateText)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .contextMenu {
        // While Serein works there, taking the page stops its work, as the band row and banner say.
        Button(working ? "Let Me Use It" : "Keep This Page") { browser.takeOver(tab) }
        Button("Close Page") { board.dismiss(tab.id) }.disabled(!ended)
      }
  }
}

/// Serein's row: the hologram, the main assistant's name and its state (static words in secondary
/// text, a dot, or the mini spinner). It shares the selection pill with the tab rows; a click
/// always shows Serein full, and a click while full focuses its composer. Serein's panel shows it
/// only while no assistant runs in the window; otherwise `SereinContactRow` is the main assistant's
/// row.
struct SereinTabRow: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var selection: Namespace.ID
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var network = NetworkMonitor.shared
  var body: some View {
    if let relay = SereinSurface.controller?.relay {
      SereinTabRowBody(relay: relay, browser: browser, agent: agent, hub: agent.hub, selection: selection,
                       online: network.online, unread: surface.unread)
    } else {
      // No assistant in this window: the row is still there, as the band tab is, with no state.
      SereinTabRowLabel(browser: browser, status: nil, selection: selection)
    }
  }
}
private struct SereinTabRowBody: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  /// The status reads the run ledger (a task waiting on you), which loads after launch.
  @ObservedObject private var tray = SereinTray.shared
  var selection: Namespace.ID
  let online: Bool
  let unread: Bool
  var body: some View {
    let whole = SereinSurface.status(relay: relay, agent: agent, hub: hub, online: online, unread: unread)
    SereinTabRowLabel(browser: browser, status: whole, selection: selection,
                      name: relay.team.main?.name ?? RelayTeam.mainName)
  }
}
private struct SereinTabRowLabel: View {
  @ObservedObject var browser: BrowserModel
  /// nil when no assistant runs in this window: no trailing state, and none in its label.
  let status: SereinStatus?
  var selection: Namespace.ID
  /// The main assistant's name (Settings › Assistants can rename it).
  var name: String = RelayTeam.mainName
  @State private var hovered = false
  @ObservedObject private var surface = SereinSurface.main.placement
  @Environment(\.palette) var p
  @Environment(\.sidebarRail) private var rail
  var body: some View {
    // Serein's row marks Serein's own chat, not one of its task views.
    let selected = browser.section == ShellSection.serein && surface.view == .chat
    let row = Button {
      // A click first makes the main assistant the active one (Serein's row is Serein's chat).
      if let relay = RelayOrchestrator.shared, let main = relay.team.main, relay.team.activeID != main.id,
        !relay.openAssistant(main.id) { return }
      SereinRouter.showFull()
    } label: {
      if rail {
        // The rail has no room for the name: the mark alone, as on Serein's contact row there.
        SereinHologramMark(size: AssistantMetrics.railFace)
          .frame(width: AssistantMetrics.railTile.width, height: AssistantMetrics.railTile.height)
      } else {
        HStack(spacing: 10) {
          SereinHologramMark(size: 18).frame(width: 16, height: 16)
          Text(name).font(UIStyle.font(13, weight: selected ? .medium : .regular)).foregroundStyle(p.ink)
            .lineLimit(1).truncationMode(.tail).layoutPriority(0)
          Spacer(minLength: 4)
          if status?.spins == true { ProgressView().controlSize(.mini) }
          if status == .needsYou { Circle().fill(p.warning).frame(width: 6, height: 6) }
          if status == .unread { Circle().fill(p.accent).frame(width: 6, height: 6) }
          if let words = status?.rowWords {
            Text(words).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
          }
        }.padding(.leading, 10).padding(.trailing, 8)
      }
    }
    Group {
      if rail {
        row.buttonStyle(AssistantListRowStyle(selected: selected, hovered: hovered, selection: selection, fitsContent: true))
          .sidebarRailCentred(true)
      } else {
        row.buttonStyle(SidebarRowStyle(selected: selected, hovered: hovered, selection: selection))
      }
    }
      .onHover { hovered = $0 }
      .sereinHintAnchor(.sereinRow)
      .help("\(name) · ⌘E to ask · ⌘J full or beside")
      .accessibilityLabel(status.map { "\(name), \(selected ? "full" : surface.place.spoken), \($0.spoken)" } ?? name)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .contextMenu {
        SereinRowMenuItems(name: name)
      }
  }
}

/// Serein's own menu items, on its contact card and on the main assistant's row: Ask, ⌘J's
/// item, New Chat, Resume and Stop Everything.
struct SereinRowMenuItems: View {
  var name: String
  var body: some View {
    Button("Ask \(name)") { SereinRouter.show() }.keyboardShortcut("e", modifiers: .command)
    // ⌘J's own item, titled and acting as ⌘J does now (Show Serein Full, Show Serein
    // Beside or Back to Your Tab), so its hint never teaches the wrong result. No item with
    // no tab to go back to; a click on the card itself always shows Serein full.
    let switching = SereinRouter.switchState
    if switching.enabled {
      Button(switching.title) { SereinRouter.toggleFullBeside() }.keyboardShortcut("j", modifiers: .command)
    }
    if RelayOrchestrator.shared?.state.paused == true {
      Button("Resume \(name)") { RelayOrchestrator.shared?.resume() }
    }
    if RelayOrchestrator.shared?.working == true || !(SereinRouter.agent?.hub.active.isEmpty ?? true) {
      Button("Stop Everything") { RelayController.shared?.killSwitch() }
    }
  }
}

/// Row background: Grok's active wash when selected (shared across rows so it glides), wash on hover,
/// a deeper wash while pressed. Assistant rows and team headers wear the same one.
struct SidebarRowStyle: ButtonStyle {
  var selected: Bool
  var hovered: Bool
  var pinned = false
  var selection: Namespace.ID
  /// A colour over the raised pill while the row is selected (the Agents list's current session).
  var selectedWash: Color? = nil
  /// A colour behind the row at rest (a task waiting on you).
  var restingWash: Color? = nil
  func makeBody(configuration: Configuration) -> some View {
    RowBody(configuration: configuration, selected: selected, hovered: hovered, pinned: pinned, selection: selection,
            selectedWash: selectedWash, restingWash: restingWash)
  }
  private struct RowBody: View {
    let configuration: ButtonStyleConfiguration
    var selected: Bool
    var hovered: Bool
    var pinned = false
    var selection: Namespace.ID
    var selectedWash: Color? = nil
    var restingWash: Color? = nil
    @Environment(\.palette) var p
    var body: some View {
      configuration.label.frame(height: UIStyle.sidebarRowHeight).contentShape(Rectangle())
        .background {
          ZStack {
            if selected {
              // Grok's selected row: the flat active wash, no lift.
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(p.selected)
                .overlay {
                  if let selectedWash { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selectedWash) }
                }
                .matchedGeometryEffect(id: "sidebar-selection", in: selection)
            } else if let restingWash {
              RoundedRectangle(cornerRadius: 12, style: .continuous).fill(restingWash)
            }
            if configuration.isPressed {
              RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.selected)
            } else if hovered && !selected {
              RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.hover)
            } else if pinned && !selected {
              RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.accent.opacity(0.10))
            }
            if pinned {
              HStack {
                Capsule().fill(p.accent).frame(width: 2, height: 14)
                Spacer()
              }.padding(.leading, 3)
            }
          }
        }
    }
  }
}

/// One browser or agent tab: status bar, site icon, title and close.
struct SidebarTabRow: View {
  @ObservedObject var tab: BrowserTab
  @ObservedObject var browser: BrowserModel
  var selection: Namespace.ID
  var selected: Bool
  var select: () -> Void
  var close: (() -> Void)?
  @State private var hovered = false
  @Environment(\.palette) var p
  var host: String { URL(string: tab.address)?.host ?? "this tab" }
  var body: some View {
    let state = browser.agentState(for: tab)
    let showClose = close != nil && (hovered || selected)
    ZStack(alignment: .leading) {
      Button(action: select) {
        HStack(spacing: 10) {
          SiteIcon(tab: tab)
          if tab.ext.pinned {
            InterfaceIcon(systemName: "pin.fill", size: 10).foregroundStyle(p.accent)
              .accessibilityLabel("Pinned")
          }
          Text(tab.sleeping && !tab.sleepingTitle.isEmpty ? tab.sleepingTitle
            : tab.title.isEmpty ? (tab.address.isEmpty ? "New tab" : tab.address) : tab.title)
            .font(UIStyle.font(13, weight: selected ? .medium : .regular))
            .foregroundStyle(tab.sleeping ? p.secondary : p.ink)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          if tab.loading && state?.working != true {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
              .accessibilityLabel("Loading")
          }
          Color.clear.frame(width: showClose ? 18 : 0)
        }.padding(.leading, 10).padding(.trailing, 6)
      }.buttonStyle(SidebarRowStyle(selected: selected, hovered: hovered, pinned: tab.ext.pinned, selection: selection))
        .accessibilityLabel(state == nil ? "Browser tab: \(tab.title)" : "Serein’s page: \(tab.title)")
        .accessibilityValue(accessibilityValue(state))
        .accessibilityAddTraits(selected ? .isSelected : [])
      if let status = state?.status {
        AgentStatusBar(status: status).frame(height: 16).padding(.horizontal, 2)
          .frame(height: UIStyle.sidebarRowHeight).padding(.leading, 1)
          .help(status == .working ? "Serein is using this page" : "Serein used this page · \(status.word)")
          .accessibilityHidden(true)
      }
      if showClose, let close {
        HStack {
          Spacer()
          Button(action: close) {
            InterfaceIcon(systemName: "xmark", size: 10).foregroundStyle(p.secondary)
              .frame(width: 18, height: 18).contentShape(Rectangle())
          }.buttonStyle(QuietButton()).help("Close tab")
            .accessibilityLabel("Close tab: \(tab.title)")
        }.padding(.trailing, 2)
      }
    }
    .onHover { hovered = $0 }
    .help(tab.address)
  }
  func accessibilityValue(_ state: TabAgentState?) -> String {
    var parts = [tab.address]
    if tab.ext.pinned { parts.append("Pinned") }
    if tab.privateMode && state == nil { parts.append("Private") }
    if tab.sleeping { parts.append("Sleeping") }
    if let state {
      parts.append(state.status.map { $0 == .working ? "Serein is using this page" : "Serein used this page, \($0.spoken)" } ?? "Yours now")
      if browser.agentTabs.unseen.contains(tab.id) { parts.append("new result") }
    }
    return parts.filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

/// Whether the pointer is over the open status bubble, so leaving the row does not close it.
@MainActor enum BubbleHover { static var inside = false }

/// The sidebar's foot: one row for the person (their initial and name) that opens a menu holding
/// Settings, the Marketplace and Usage. In the rail, the face alone.
struct SidebarFooter: View {
  @ObservedObject var browser: BrowserModel
  var selection: Namespace.ID
  @State private var hovered = false
  @Environment(\.palette) private var p
  @Environment(\.sidebarRail) private var rail

  var body: some View {
    VStack(spacing: 2) {
      Rectangle().fill(p.line).frame(height: UIStyle.hairline).padding(.horizontal, 6).padding(.bottom, 6)
      // Serein's own dropdown (SereinMenu.swift), like every menu in the app; it opens upward here.
      SereinMenuButton("Account and settings", help: "Settings, Marketplace and usage", width: 250, leading: true,
                       previewNotification: "SereinPreviewAccountMenu") {
        SereinMenuItem.header(personName)
        SereinMenuItem.action("Settings", icon: "gearshape", shortcut: "⌘,") { browser.showSettings = true }
        SereinMenuItem.action("Marketplace", icon: "square.grid.2x2") { browser.showMarketplace = true }
        SereinMenuItem.divider
        SereinMenuItem.action("Usage", icon: "gauge.with.dots.needle.33percent") { openSettings("Usage") }
      } label: {
        SidebarRowLabel(personName) { face }.lineLimit(1).truncationMode(.middle)
          .contentShape(Rectangle())
      }
      .buttonStyle(AssistantListRowStyle(selected: browser.showSettings || browser.showMarketplace, hovered: hovered,
                                         selection: selection, fitsContent: rail))
      .sidebarRailCentred(rail)
      .onHover { hovered = $0 }
      .accessibilityValue(personName)
    }.padding(.bottom, 8)
  }

  private var personName: String {
    let name = NSFullUserName().trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "You" : name
  }
  private var face: some View {
    let side: CGFloat = rail ? 22 : AssistantMetrics.listFace
    return Text(String(personName.prefix(1)).uppercased()).font(UIStyle.font(rail ? 11 : 10, weight: .semibold))
      .foregroundStyle(p.ink).frame(width: side, height: side).background(p.track, in: Circle())
  }
  /// The way the composer's commands open a Settings page (ComposerCommands), also when Settings
  /// already shows.
  private func openSettings(_ section: String) {
    UserDefaults.standard.set(section, forKey: "serein.settingsSection")
    browser.requestedSettingsSection = section
    browser.showSettings = true
  }
}

/// An icon row of the sidebar (the Spaces, History, Marketplace, Settings): its icon and its
/// name; in the rail the icon alone on its plate.
struct SidebarRowLabel<Icon: View>: View {
  var title: String
  @ViewBuilder var icon: Icon
  @Environment(\.palette) private var p
  @Environment(\.sidebarRail) private var rail
  init(_ title: String, @ViewBuilder icon: () -> Icon) {
    self.title = title
    self.icon = icon()
  }
  var body: some View {
    if rail {
      icon.frame(width: AssistantMetrics.railTile.width, height: AssistantMetrics.railIconHeight)
    } else {
      HStack(spacing: AssistantMetrics.listRowGap) {
        icon.frame(width: AssistantMetrics.listFace)
        Text(title).font(UIStyle.font(12.5)).foregroundStyle(p.ink)
        Spacer(minLength: 0)
      }.padding(.horizontal, AssistantMetrics.listRowPaddingH)
    }
  }
}

/// The hairline between the rail's groups, where the list has a caption.
struct SidebarRailLine: View {
  @Environment(\.palette) private var p
  var body: some View {
    Rectangle().fill(p.line).frame(height: UIStyle.hairline).padding(.horizontal, 14).padding(.vertical, 6)
      .accessibilityHidden(true)
  }
}

extension View {
  /// A rail tile sits in the middle of the rail's one column.
  func sidebarRailCentred(_ rail: Bool) -> some View { frame(maxWidth: rail ? .infinity : nil) }
}
