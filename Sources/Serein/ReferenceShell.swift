import SereinCore
import SwiftUI

struct ReferenceShell: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @State private var wall = true
  @AppStorage("serein.compact") private var compact = false
  /// Keep Serein beside tabs: while anything but Serein is the main view, Serein is docked on the
  /// right (⌘J, Hide and Keep beside change it; a peek never does).
  @AppStorage(RelayController.columnKey) private var relayColumn = true
  /// Serein's placement (peek, place), observed apart from the draft so typing never redraws
  /// the shell.
  @ObservedObject private var placement = SereinSurface.main.placement
  /// The assistant inspector at the content card's trailing edge (AssistantInspector.swift).
  @ObservedObject private var inspector = AssistantInspector.shared
  /// A sub-thread open over its parent changes the header's title and Back.
  @ObservedObject private var subThread = SubThreadFocus.shared
  private var surface: SereinSurface { .main }
  /// Serein beside's width (`serein.assistant.width`, first seeded from the task panel's). Read
  /// once; a resize writes it through the preview- and check-safe setter. Previews and checks
  /// start at the default width, whatever this Mac saved.
  @State private var besideWidth: Double? = RelayOrchestrator.persists
    ? SereinLayout.seed(
      width: UserDefaults.standard.double(forKey: SereinLayout.widthKey),
      taskPanel: UserDefaults.standard.double(forKey: SereinLayout.seedWidthKey))
    : nil
  @State private var draggedSidebarWidth: CGFloat?
  @AppStorage(UIStyle.sidebarExtraKey) private var sidebarExtra = 0.0
  @AppStorage(UIStyle.sidebarRailKey) private var sidebarRail = UIStyle.sidebarRailDefault
  private var wallWidth: CGFloat {
    draggedSidebarWidth ?? (sidebarRail ? SidebarWidth.rail : UIStyle.sidebarUsual + SidebarWidth.clamped(sidebarExtra))
  }
  @ObservedObject private var textSize = TextSizeController.shared
  private let onboardingPreview = ["setup"].contains(
    CommandLine.arguments.drop(while: { $0 != "--ui-preview" }).dropFirst().first ?? "")
  /// The "setup" preview opens the flow on its agent step.
  private let setupPreview =
    CommandLine.arguments.drop(while: { $0 != "--ui-preview" }).dropFirst().first == "setup"
  /// Legacy tour screens remain available only as explicit synthetic previews. Normal setup
  /// is the first run’s connect and Mac access pages (FirstRunPages.swift).
  @State private var showBrowserOnboarding = false
  @Environment(\.accessibilityReduceMotion) var systemReduceMotion
  @Environment(\.sereinReducedEffects) var previewReducedEffects
  var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  @Environment(\.palette) var p
  @ObservedObject private var chrome = WindowChrome.shared
  @ObservedObject private var connect = SereinConnect.shared
  /// Sign in as … › 1Password… or Bitwarden… (PasswordManagers.begin).
  @ObservedObject private var managers = PasswordManagers.shared
  var showWall: Bool { wall && !compact }
  /// Serein is meant to be beside the main view (kept beside or a peek). The window's room
  /// decides the rest (`SereinLayout.place`); this drives the animation, so a resize that
  /// pushes Serein aside never slides.
  var besideIntent: Bool {
    (relayColumn || surface.peek) && !compact && browser.section != ShellSection.serein
  }
  /// Hiding the sidebar (its toggle, ⌘\).
  func hideSidebar() { wall = false }
  /// Where Serein is, for this window width.
  func placement(_ window: CGFloat) -> ShellPlacement {
    let room = Double(besideRoom(window))
    let place = SereinLayout.place(
      section: browser.section, besideOn: relayColumn, peek: surface.peek, compact: compact,
      room: room, minWidth: Double(TaskDock.minWidth))
    return ShellPlacement(
      place: place, fits: SereinLayout.fits(compact: compact, room: room, minWidth: Double(TaskDock.minWidth)))
  }
  /// The shell's slide, or none with Reduce Motion.
  private var shellCurve: Animation? { reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.25) }
  /// The shell's layers, overlays and sheets. Apart from `body`'s event handlers, so neither chain
  /// of modifiers is too long for the type checker.
  private var shellLayers: some View {
    ZStack {
      GeometryReader { geometry in
        VStack(spacing: 0) {
        HStack(spacing: 0) {
          if showWall {
            WallSidebar(browser: browser, agent: agent, width: wallWidth,
                        draggedWidth: $draggedSidebarWidth, extraWidth: $sidebarExtra, rail: $sidebarRail,
                        ask: { SereinRouter.show() })
              .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
          }
          // Serein beside: its chat, or a task it started (`SereinTaskView`).
          let layout = placement(geometry.size.width)
          let beside = layout.place == .beside && SereinSurface.controller != nil
          // The inspector sits inside the content card, except beside, where it is its own card
          // after Serein's, so the chat stays to its left.
          contentCard(pane: !beside, window: geometry.size.width)
            .padding(.leading, showWall ? 0 : UIStyle.chromeInset)
            .padding(.trailing, UIStyle.chromeInset)
          if beside {
            let room = besideRoom(geometry.size.width)
            SereinSurfaceView(style: .side, browser: browser, agent: agent)
              .frame(width: CGFloat(SereinLayout.width(saved: besideWidth, room: Double(room), minWidth: Double(TaskDock.minWidth))))
              .chromeCard()
              .overlay(alignment: .leading) {
                PanelResizeHandle(
                  width: Binding(
                    get: { CGFloat(SereinLayout.width(saved: besideWidth, room: Double(room), minWidth: Double(TaskDock.minWidth))) },
                    set: { besideWidth = Double($0) }),
                  label: "Serein width"
                ) {
                  if let besideWidth { RelayOrchestrator.setSetting(besideWidth, forKey: SereinLayout.widthKey) }
                }.offset(x: -6)
              }
              .padding(.trailing, UIStyle.chromeInset)
              .transition(reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity))
            if inspector.open, let id = inspector.assistantID, let relay = SereinSurface.controller?.relay {
              // Its edge stops where Serein beside would no longer fit beside the page.
              let widest = baseRoom(geometry.size.width) - UIStyle.chromeInset - TaskDock.minWidth - CGFloat(SereinLayout.pageMinWidth)
              inspectorPane(
                relay: relay, id: id, width: inspector.width,
                range: AssistantInspector.minWidth...max(AssistantInspector.minWidth, min(AssistantInspector.maxWidth, widest)),
                separated: false)
                .chromeCard()
                .padding(.trailing, UIStyle.chromeInset)
            }
          }
        }.padding(.top, UIStyle.chromeInset).padding(.bottom, UIStyle.chromeInset)
        }
        .onChange(of: placement(geometry.size.width), initial: true) { old, new in
          placed(old, new, room: baseRoom(geometry.size.width))
        }
        // The room before the inspector, so opening it from beside can show Serein full first.
        .onChange(of: baseRoom(geometry.size.width), initial: true) { _, room in inspector.shellRoom = room }
      }.ignoresSafeArea()
    }.id(textSize.generation)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .coordinateSpace(name: AgentBubbleLayer.space)
      .overlayPreferenceValue(ComposerDropdownAnchorKey.self) { anchors in
        ComposerDropdownLayer(agent: agent, browser: browser, anchors: anchors)
      }
      // Serein's own "…" menus draw here, over every card (SereinMenu.swift).
      .overlay { SereinMenuLayer() }
      .overlay { TabZoneGhost() }
      .overlay { SearchPaletteLayer(browser: browser, agent: agent) }
      .coordinateSpace(name: SereinMenuCenter.space)
      .background(AmbientBackground())
      .overlay(alignment: .bottom) { ToastStack() }
      .foregroundStyle(p.ink).font(UIStyle.font(13)).environment(\.palette, p)
      .ignoresSafeArea()
      .animation(shellCurve, value: showWall)
      .animation(shellCurve, value: besideIntent)
      .animation(shellCurve, value: inspector.open)
      .sheet(item: $managers.request) { request in
        ManagerSignInSheet(request: request).environment(\.palette, p)
      }
      .sheet(isPresented: $showBrowserOnboarding) {
        SetupFlow(
          browser: browser, agent: agent,
          profiles: nil,
          startAt: SetupStep(rawValue: UIPreview.setupStep ?? "") ?? .agent
        ) {
          showBrowserOnboarding = false
        }.environment(\.palette, p)
      }
  }
  var body: some View {
    shellLayers
      .onAppear {
        if onboardingPreview { showBrowserOnboarding = true }
        // The Working strip reads the run ledger's last day, again only when a record is written.
        SereinTray.shared.attach(hub: agent.hub, browser: browser)
      }
      // Over the rail the window's three buttons centre on its column.
      .onChange(of: showWall && sidebarRail, initial: true) { _, onRail in chrome.onRail = onRail }
      // A task starting never moves the main view: only the user's own clicks do.
      .onChange(of: agent.running) { _, _ in
        ShellProbe.runningChanges += 1
      }
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SereinShowSetup"))) { _ in
        guard let relay = RelayOrchestrator.shared else { return }
        browser.showSettings = false
        SereinRouter.home()
        SereinChatSetup.shared.restart(relay)
      }
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SereinPreviewModels"))) { _ in
        // `--ui-work-on`: the composer's + picker in place of the model menu.
        if CommandLine.arguments.contains("--ui-preview") {
          let kind: ComposerDropdown.Kind = CommandLine.arguments.contains("--ui-work-on") ? .workOn : .modelAndTraits
          ComposerDropdown.shared.open = ComposerDropdown.Target(kind: kind, owner: "")
        }
      }
      .onChange(of: browser.showAgent) { _, show in
        if show {
          // Older callers asking for the composer: Serein's, filled, never sent.
          SereinRouter.show()
          browser.showAgent = false
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: Notification.Name("SereinImportProject"))
      ) { note in
        if let value = note.object as? ProjectWithConversation {
          agent.acceptImported(value, browser: browser)
        }
      }
      // ⌘E, File › Ask Serein: Serein's chat, focused, or, with no room for Serein beside the
      // page (Compact Mode, a narrow window), the in-window bar. Nothing is sent.
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SereinAsk"))) { _ in
        SereinRouter.askFromKeyboard()
      }
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SereinWall"))) { _ in
        if showWall { hideSidebar() } else { wall = true }
      }
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SereinPointStarted"))) {
        _ in
        ComposerDropdown.shared.close()
      }
      // Serein shown: its reply is read, so the row's dot goes.
      .onChange(of: browser.section) { old, section in
        HistoryNavigation.shared.changed(from: old, to: section)
        if section == ShellSection.serein { SereinSurface.main.unread = false }
      }
      .onChange(of: browser.section, initial: true) { _, section in
        if section == ShellSection.thread { agent.showThreadTab(agent.conversationID) }
      }
      .onChange(of: agent.conversationID) { _, id in
        if browser.section == ShellSection.thread { agent.showThreadTab(id) }
      }
  }
}
/// What the mounted shell has seen (checks): the no-yank check proves the shell's own
/// `agent.running` observer ran while the page stayed in view.
@MainActor enum ShellProbe {
  static var runningChanges = 0
}

/// Where Serein is in the main window, as the shell lays it out.
struct ShellPlacement: Equatable {
  var place: SereinPlace
  var fits: Bool
}

extension ReferenceShell {

  /// The width the page and a panel on the right share: the window less the sidebar (or its
  /// inset), the gaps between the cards and the assistant inspector while it shows.
  func besideRoom(_ window: CGFloat) -> CGFloat { baseRoom(window) - inspector.room }
  /// The same before the inspector: the window less the sidebar (or its inset) and the gaps.
  func baseRoom(_ window: CGFloat) -> CGFloat {
    window - (showWall ? wallWidth : UIStyle.chromeInset) - 3 * UIStyle.chromeInset
  }
  /// The content card's width: the window less the sidebar (or its inset) and the trailing inset.
  func cardWidth(_ window: CGFloat) -> CGFloat {
    window - (showWall ? wallWidth : UIStyle.chromeInset) - UIStyle.chromeInset
  }
  /// The inspector inside the content card: its saved width, narrowed so Serein's chat (or the
  /// page) keeps 420 points; under 320 only when the chat would otherwise drop below the
  /// composer's 352. 1030-point window with the sidebar: the card is 790, the pane its default 320
  /// and the chat 470.
  func cardPaneWidth(_ window: CGFloat) -> CGFloat {
    let card = cardWidth(window)
    return max(min(AssistantInspector.minWidth, card - TaskDock.minWidth), min(inspector.width, card - CGFloat(SereinLayout.pageMinWidth)))
  }
  /// The inspector with its resize edge, which drags the width shown within `range`.
  /// `separated` draws its leading line inside the content card; beside, it is a card of its own.
  func inspectorPane(
    relay: RelayOrchestrator, id: String, width: CGFloat, range: ClosedRange<CGFloat>, separated: Bool
  ) -> some View {
    InspectorPane(relay: relay, id: id, browser: browser, separated: separated)
      .frame(width: width)
      .overlay(alignment: .leading) {
        PanelResizeHandle(
          width: Binding(get: { width }, set: { inspector.width = $0 }), label: "Details width", range: range
        ) { inspector.saveWidth() }.offset(x: separated ? -4 : -6)
      }
      .transition(reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity))
  }
  /// The shell's placement changed: the surface learns it (chatOnScreen, the menus and the
  /// Serein buttons read it there). Beside stepping aside for lack of room, holding a draft or a
  /// waiting answer, says where Serein went.
  /// `room` is the shell's room before the inspector: when the pane is what pushed Serein beside
  /// out (a narrower window, a wider pane), Serein shows full instead, to the left of the pane,
  /// as `AssistantInspector.show` does. Only that change: ⌘J's Back to Your Tab still leaves full.
  func placed(_ old: ShellPlacement, _ new: ShellPlacement, room: CGFloat) {
    if old.place == .beside, new.place == .noRoom, inspector.open,
      SereinLayout.fits(compact: compact, room: Double(room), minWidth: Double(TaskDock.minWidth))
    {
      SereinRouter.home()
      return
    }
    if placement.place != new.place { placement.place = new.place }
    if placement.fits != new.fits { placement.fits = new.fits }
    let relay = RelayOrchestrator.shared
    let waiting = relay.map { !$0.approvals.isEmpty || !$0.questionForms.isEmpty || $0.consentWaiting } ?? false
    let draft = !surface.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !surface.attachments.isEmpty
    if SereinLayout.movedAside(from: old.place, to: new.place, draft: draft, waiting: waiting)
    {
      ToastCenter.shared.show(
        "Serein moved out of the way. Press ⌘J to show it full.", id: "serein-moved", duration: 8, opaque: true)
    }
  }
  /// The one rounded content card: header row, optional horizontal tabs, the section, then the
  /// page-memory and notice lines.
  func contentCard(pane: Bool, window: CGFloat) -> some View {
    contentStack(pane: pane, window: window)
      // Connecting an AI app from Serein (its own sheet, apart from Settings and setup).
      .sheet(isPresented: Binding(get: { connect.presented }, set: { if !$0 { connect.dismiss() } })) {
        SereinConnectSheet(agent: agent).environment(\.palette, p)
      }
      // The New team sheet and the assistant editor (AssistantSidebar.swift: TeamSheets), also
      // from Settings › Assistants › Teams, which opens in this card.
      .modifier(TeamSheetHost(active: true, p: p))
  }
  @ViewBuilder private func contentStack(pane: Bool, window: CGFloat) -> some View {
    if browser.section == ShellSection.settings {
      settingsPage
    } else if browser.section == ShellSection.marketplace {
      marketplacePage
    } else {
      sectionStack(pane: pane, window: window)
    }
  }
  /// Settings, open like a tab: it fills the card with its header row, page list and page. With
  /// the sidebar hidden its header row clears the traffic lights and holds Show sidebar.
  private var settingsPage: some View {
    ReferenceSettings(
      browser: browser, agent: agent, sidebarHidden: !showWall, fullScreen: chrome.fullScreen,
      showSidebar: {
        wall = true
        compact = false
      }
    ).frame(maxWidth: .infinity, maxHeight: .infinity).chromeCard()
  }
  /// The Marketplace, open like Settings: its header row, column and page fill the card.
  private var marketplacePage: some View {
    MarketplacePage(
      browser: browser, sidebarHidden: !showWall, fullScreen: chrome.fullScreen,
      showSidebar: {
        wall = true
        compact = false
      }
    ).frame(maxWidth: .infinity, maxHeight: .infinity).chromeCard()
  }
  private func sectionStack(pane: Bool, window: CGFloat) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        // The header row tops the chat or page only, so its centred name pill moves with the chat
        // when the inspector opens beside it, and the inspector runs the card's full height.
        VStack(spacing: 0) {
          header
          // Serein's chat waits on an answer and is not on screen (hidden, out of room, a task's
          // view): one line says so, and Show brings Serein where it lives.
          if let relay = SereinSurface.controller?.relay { SereinWaitingLine(relay: relay) }
          switch browser.section {
          case ShellSection.serein: SereinSurfaceView(style: .full, browser: browser, agent: agent)
          // Goals, Automations and History have no page: Serein's chat reads and changes them with
          // its tools (goal_list, reminder_list, watch_list, sessions_list, session_read…). Any
          // older route to them opens the chat.
          case ShellSection.board, ShellSection.automations, ShellSection.todo, ShellSection.waiting,
               ShellSection.history, ShellSection.chats, ShellSection.today, ShellSection.projects:
            Color.clear.onAppear { SereinRouter.home() }
          case ShellSection.sites: SitesWorkspace(browser: browser)
          case ShellSection.saved: LibraryView(browser: browser, agent: agent, kind: "saved")
          case ShellSection.agents: Color.clear.onAppear { browser.section = ShellSection.serein }
          case ShellSection.thread: ThreadWorkspace(browser: browser, agent: agent)
          case ShellSection.agent: AgentTabPane(browser: browser, agent: agent)
          default:
            // A page a task handed you, to finish a sign-in or a check. With none left, Serein.
            if browser.section == ShellSection.browser, let tab = browser.active {
              AgentWorkBanner(browser: browser, tab: tab)
              BrowserPane(tab: tab)
            } else {
              Color.clear.onAppear { browser.section = ShellSection.serein }
            }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
          // A failure or an answer to something the person just did: a toast, not a strip across
          // the window. Cleared once shown, so the same words can show again.
          .onChange(of: browser.notice) { _, notice in
            guard let notice else { return }
            ToastCenter.shared.show(notice, opaque: true)
            browser.notice = nil
          }
        // The assistant inspector: to the right of Serein's chat (or of the page), inside the card,
        // resized from its leading edge (beside, it is its own card instead).
        if pane, inspector.open, let id = inspector.assistantID, let relay = SereinSurface.controller?.relay {
          let widest = cardWidth(window) - CGFloat(SereinLayout.pageMinWidth)
          inspectorPane(
            relay: relay, id: id, width: cardPaneWidth(window),
            range: AssistantInspector.minWidth...max(AssistantInspector.minWidth, min(AssistantInspector.maxWidth, widest)),
            separated: true)
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).chromeCard()
  }

  /// The sections whose first row is the browser toolbar (with its Serein button).
  /// The card's first row. With the sidebar hidden it starts after the traffic lights (which
  /// `WindowChrome` keeps at the same spot) and a Show sidebar button, like Safari.
  var header: some View {
    HStack(spacing: 6) {
      if !showWall {
        Color.clear.frame(width: chrome.fullScreen ? 4 : UIStyle.trafficLightGutter)
          .accessibilityHidden(true)
        Button {
          wall = true
          compact = false
        } label: {
          InterfaceIcon(systemName: "sidebar.left", size: 16)
        }.buttonStyle(ToolbarIconButton()).help("Show sidebar").accessibilityLabel("Show sidebar")
      }
      switch browser.section {
      case ShellSection.serein:
        if let controller = SereinSurface.controller {
          SereinHeaderSlot(controller: controller, browser: browser, agent: agent)
            .padding(.leading, showWall ? 14 : 4)
        } else {
          HStack(spacing: 8) {
            SereinMark(size: 16)
            Text("Serein").font(UIStyle.font(14, weight: .semibold))
            Spacer()
          }.padding(.leading, showWall ? 14 : 4)
        }
      case ShellSection.thread:
        let sub = subThread.open?.shown
        HStack(spacing: 8) {
          Button {
            if sub != nil { subThread.close() } else { SereinRouter.home() }
          } label: {
            Label("Back", systemImage: "chevron.left").font(UIStyle.meta)
          }.buttonStyle(QuietButton()).foregroundStyle(p.secondary).fixedSize()
            .help(sub.map { "Back to \($0.parentTitle)" } ?? "Back")
          // Under the title; beside it where two lines would overflow the header (Compact Mode, or
          // text above 115%).
          let stacked = !compact && UIStyle.textScale <= 1.15
          let titleLayout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
          titleLayout {
            if let sub {
              Text(verbatim: sub.helper.title).font(UIStyle.bodyStrong).lineLimit(1).truncationMode(.tail)
              // The parent's engine, then whose sub-thread it is.
              HStack(spacing: 6) {
                ModelPill(agent: agent)
                Text(verbatim: "Sub-thread of " + sub.parentTitle).font(UIStyle.meta).foregroundStyle(p.secondary)
                  .lineLimit(1).truncationMode(.middle)
              }
            } else {
              Text(agent.messages.isEmpty ? "New task" : agent.openThreadItem(agent.conversationID).map(ProjectChatIndex.title) ?? "Task")
                .font(UIStyle.bodyStrong).lineLimit(1).truncationMode(.tail)
              // The engine of this chat; a pick switches this chat only.
              ModelPill(agent: agent)
            }
          }.frame(maxWidth: 420, alignment: .leading)
          Spacer()
          Button { agent.summarizeOutcome() } label: {
            InterfaceIcon(systemName: "checklist")
          }.buttonStyle(QuietButton()).disabled(agent.running || agent.messages.isEmpty)
            .help("Summarize how this task went").accessibilityLabel("Summarize outcome")
          Button { agent.clear() } label: {
            InterfaceIcon(systemName: "square.and.pencil")
          }.buttonStyle(QuietButton())
            .help("New chat").accessibilityLabel("New chat")
        }.padding(.leading, showWall ? 12 : 0)
      case ShellSection.agent:
        AgentAddressField(board: browser.agentTabs).padding(.leading, showWall ? 12 : 4)
      case ShellSection.sites:
        Text("Pages").font(UIStyle.bodyStrong).padding(.leading, 12)
        Spacer()
      case ShellSection.agents:
        EmptyView()
      case ShellSection.saved:
        HStack(spacing: 12) {
          Button { SereinRouter.home() } label: { Label("Back", systemImage: "chevron.left") }
            .buttonStyle(QuietButton())
          Text("Saved passages").font(UIStyle.bodyStrong)
          Spacer()
        }.padding(.leading, 12)
      default:
        HandedPageHeader(browser: browser).padding(.leading, showWall ? 12 : 4)
      }
      // With the sidebar hidden, its Serein row is out of reach: the petal shows Serein.
      if !showWall && browser.section != ShellSection.serein {
        Button { SereinRouter.show() } label: {
          SereinMark(size: 16).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(QuietButton()).help("Show Serein · ⌘E").accessibilityLabel("Show Serein")
      }
    }.padding(.trailing, 10).frame(height: compact ? 34 : UIStyle.headerHeight)
      .background(p.background)
      // Serein's chat opens with its picture and name right under this row: no rule between them.
      .overlay(alignment: .bottom) {
        if browser.section != ShellSection.serein { Rectangle().fill(p.line).frame(height: 1) }
      }
      .zIndex(10)
  }
}

/// The agent tab's address, read-only: the tab belongs to the agent until the user keeps it.
struct AgentAddressField: View {
  @ObservedObject var board: AgentTabBoard
  @Environment(\.palette) var p
  var body: some View {
    let tab = board.focused.flatMap { board.entry($0)?.tab }
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "globe", size: 13).foregroundStyle(p.secondary)
      Text(tab.map { URL(string: $0.address)?.host ?? $0.address } ?? "Serein’s page")
        .font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 4)
      Text("Serein’s page").font(UIStyle.micro).foregroundStyle(p.secondary)
    }.padding(.horizontal, 10).frame(height: 32).frame(maxWidth: .infinity)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius))
      .accessibilityElement(children: .combine).accessibilityLabel("Address of Serein’s page")
  }
}

extension View {
  /// A content plane: inset rounded card with a soft shadow.
  func chromeCard() -> some View { modifier(ChromeCard()) }
}
private struct ChromeCard: ViewModifier {
  @Environment(\.palette) var p
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: UIStyle.contentRadius, style: .continuous)
    content.background(p.background).clipShape(shape)
      .background(shape.fill(p.background).shadow(color: p.shadow(0.35), radius: 10, y: 2))
  }
}

struct ThreadWorkspace: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  /// In the docked task panel: the header shows status and actions, and the reply box is
  /// the panel's own composer.
  var panel = false
  /// The chat's older messages, built above its newest ones as the person scrolls up.
  @StateObject private var pages = EarlierPages()
  @ObservedObject private var focus = SubThreadFocus.shared
  @Environment(\.palette) var p
  var body: some View {
    if !panel, let open = focus.open {
      // A sub-thread over its parent: the parent's header above, its transcript and box here.
      SubagentTranscriptView(shown: open.shown, continueWith: open.continueWith,
                             options: { TaskOptionsRow(browser: browser, agent: agent, owner: "", readOnly: true) })
        .id(open.shown.id)
        .onChange(of: agent.conversationID) { _, _ in if !focus.isParent(agent) { focus.close() } }
    } else {
      thread
    }
  }
  private var thread: some View {
    VStack(spacing: 0) {
      // The status pill names the state; the question must stay visible at every width. A finished
      // task has no question: its answer is right below, so nothing repeats it up here.
      if let outcome = agent.outcomeSummary, outcome.kind != "done" {
        // Question above, choices below: a narrow panel can't share one row between them.
        HStack(alignment: .top, spacing: 8) {
          VStack(alignment: .leading, spacing: 8) {
            Text(outcome.question).font(UIStyle.body).fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
            if !outcome.choices.isEmpty {
              // One row when the choices fit, otherwise one per line.
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { outcomeChoices(outcome.choices) }
                VStack(alignment: .leading, spacing: 4) { outcomeChoices(outcome.choices) }
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          Button {
            agent.outcomeSummary = nil
          } label: {
            InterfaceIcon(systemName: "xmark")
          }.buttonStyle(QuietButton()).accessibilityLabel("Dismiss outcome")
        }.padding(panel ? 10 : 14).background(p.panel)
      }
      if NewTaskFolders.applies(agent, panel: panel) {
        // A new task: where it works, in the middle; the box stays at the bottom.
        NewTaskFolders(browser: browser, agent: agent).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
      GeometryReader { geometry in
        ScrollViewReader { proxy in
          ScrollView {
            // Native selectable blocks need stable measured heights when a disclosure or
            // the composer changes height; lazy estimates can keep relaying out the scroll.
            // So only the newest part of a long chat is in this layout; the older messages are
            // built above it, outside it (EarlierPages).
            let messages: [AgentMessage] = agent.messages
            let start: Int = pages.liveStart(in: messages, thread: agent.conversationID, newest: TranscriptWindow.newest)
            let shown = Array(messages[start...])
            let breaks: Set<String> = ChatTurns.breaks(messages, from: start)
            let latestCopyID = messages.last(where: { !$0.text.isEmpty })?.id
            let userWidth: CGFloat = max(0, min(geometry.size.width, UIStyle.composerWidth) - 32) * 0.8
            VStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
              if panel && agent.messages.isEmpty && agent.mode == .page { PageThreadEmpty(browser: browser) }
              if let link = agent.link {
                LinkedSourceLine(monitor: agent.linked, link: link, project: browser.projects.first { $0.id == agent.projectID }?.name)
              }
              if start > 0 {
                EarlierMessagesRegion(pages: pages, rows: EarlierRows(thread: agent.conversationID, messages: messages, liveStart: start) { index in
                  olderRow(messages, index, userWidth: userWidth)
                })
              }
              ForEach(Array(shown.enumerated()), id: \.element.id) { offset, message in
                threadRow(message, after: start + offset > 0 ? messages[start + offset - 1] : nil, breaks: breaks,
                          latestCopyID: latestCopyID, userWidth: userWidth, live: true)
              }
              if agent.outcomeSummary == nil {
                TaskAttentionNotice(id: agent.conversationID, hub: agent.hub) {
                  DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
              }
              // Another app's turn on a linked chat, as a run of Serein's own would show.
              if agent.link != nil { LinkedSessionNote(monitor: agent.linked, link: agent.link) }
              // What this chat's task downloaded, kept or deleted by the person (TaskShelf).
              TaskShelfSection(thread: agent.conversationID)
              // Continue in a copy and Send to another project, right under the last reply.
              if !panel { ThreadActionsBar(browser: browser, agent: agent) }
              Color.clear.frame(height: 1).id("bottom")
            }.padding(.horizontal, 16).padding(.vertical, panel ? 16 : 24).frame(maxWidth: UIStyle.composerWidth)
              .frame(maxWidth: .infinity)
              // A short chat still starts at the top of the view.
              .frame(minHeight: geometry.size.height, alignment: .top)
          }.modifier(TranscriptOpensAtEnd(thread: agent.conversationID))
          .onChange(of: agent.messages.last?.text) { _, _ in
            proxy.scrollTo("bottom", anchor: .bottom)
          }
          // A linked chat's new turn scrolls into view with the turn's own motion.
          .onChange(of: agent.messages.count) { _, _ in
            if agent.link != nil { withAnimation(LinkedMotion.arrive) { proxy.scrollTo("bottom", anchor: .bottom) } }
          }
        }
      }
      }
      // This chat's task working in a Mac app in the background, with Stop.
      MacBackgroundLine(thread: agent.conversationID, full: !panel)
      ThreadSessionNote(agent: agent)
      InterruptedRunBanner(agent: agent)
      ModelSwitchBanner(agent: agent)
      if panel {
        PanelComposer(browser: browser, agent: agent).padding(.horizontal, 12).padding(.bottom, 12)
      } else {
        TaskComposer(browser: browser, agent: agent,
          placeholder: agent.messages.isEmpty ? "Write the first message" :
            "Reply to \(agent.provider.name)" + (browser.projects.first { $0.id == agent.projectID }.map { " in \($0.name)" } ?? ""),
          acceptsComposerFocus: !panel
        ).frame(
          maxWidth: UIStyle.composerWidth
        ).padding(.horizontal, panel ? 12 : 16).padding(.bottom, panel ? 12 : 16)
      }
    }.overlay(alignment: .bottom) { TurnUndoToast(agent: agent) }
  }
  /// One message of the chat: its turn gap and time line, then the message, or its condensed
  /// divider. `live` rows are in the chat's own layout and carry the newest run and edit reviews;
  /// older rows are built outside it (EarlierPages) and show a review only when one exists.
  @ViewBuilder private func threadRow(_ message: AgentMessage, after previous: AgentMessage?, breaks: Set<String>,
                                      latestCopyID: String?, userWidth: CGFloat, live: Bool) -> some View {
    TurnLead(message: message, after: previous, breaks: breaks)
    if let range = message.condensed {
      CondensedDivider(summary: message, range: range, userWidth: userWidth)
        .environment(\.chatFolder, chatFolder)
    } else {
      // The newest turn carries its run: thinking time, reasoning and steps. It sits
      // above the reply, or after the request when the run ended without one.
      let isLastMessage = message.id == agent.messages.last?.id
      let run = live && isLastMessage ? agent.hub.latest(for: agent.conversationID) : nil
      // Another app's chat is rewritten by its next read: no Edit there.
      let edit: ((String) -> Void)? = message.role == "you" && agent.link == nil
        ? { text in agent.rerun(message.id, text: text) } : nil
      MessageHoverControls(alwaysVisible: message.id == latestCopyID) { showsCopy in
        VStack(alignment: .leading, spacing: AssistantMetrics.turnInnerGap) {
          if message.role != "you", let run { ThreadRunTrace(browser: browser, run: run, compact: { _ = agent.compactNow(run.spec.threadID) }) }
          if message.role == "you" || !message.text.isEmpty || !(message.images ?? []).isEmpty
            || message.activities?.isEmpty == false
            || run?.isActive != true
          {
            ThreadMessageContent(
              message: message,
              placeholder: message.text.isEmpty ? agent.replyPlaceholder(browser: browser) : "",
              userWidth: userWidth,
              showsCopy: showsCopy, palette: p, showsActivities: run?.steps.isEmpty != false,
              edit: edit,
              changedFiles: { MessageEdit.laterFileChanges(from: message.id, in: agent.messages) }
            ).equatable()
              .environment(\.chatFolder, chatFolder)
          }
          if message.role == "you", let run { ThreadRunTrace(browser: browser, run: run, compact: { _ = agent.compactNow(run.spec.threadID) }) }
          if live || EditReview.shared.review(for: message.id) != nil { TurnReviewSlot(agent: agent, messageID: message.id) }
        }
      }.transition(live ? LinkedMotion.enter(reduce: reduceMotion) : .identity)
    }
  }
  /// `messages[index]` as an older row (EarlierPages): drawn again when the message, its place in
  /// a turn, Edit or the width changes.
  private func olderRow(_ messages: [AgentMessage], _ index: Int, userWidth: CGFloat) -> EarlierRow {
    let message = messages[index]
    let previous: AgentMessage? = index > 0 ? messages[index - 1] : nil
    // Checked on every update of the chat, so only what is cheap to compare: the turn gap and
    // time line follow from the message before.
    let key = ThreadOlderKey(message: message, previous: previous, editable: agent.link == nil,
                             undo: message.condensed != nil && !agent.running,
                             review: EditReview.shared.review(for: message.id) != nil, width: userWidth)
    return EarlierRow(key: EarlierRowKey(key)) {
      let breaks: Set<String> = ChatTurns.breaks(messages, from: index, through: index)
      return AnyView(threadRow(message, after: previous, breaks: breaks, latestCopyID: nil, userWidth: userWidth, live: false))
    }
  }
  private var chatFolder: URL? {
    browser.projects.first { $0.id == agent.projectID }.map { URL(fileURLWithPath: $0.path) }
  }
  func outcomeChoices(_ choices: [String]) -> some View {
    ForEach(choices, id: \.self) { choice in
      Button(choice) { agent.draft = choice }.buttonStyle(QuietButton())
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// What an older row of a thread draws from (`ThreadWorkspace.olderRow`).
private struct ThreadOlderKey: Equatable {
  let message: AgentMessage
  let previous: AgentMessage?
  let editable: Bool
  let undo: Bool
  let review: Bool
  let width: CGFloat
}

/// Unchanged replies keep their native text and selection while the composer or another
/// reply changes. Run traces and edit review observe their own live state outside this leaf.
struct ThreadMessageContent: View, Equatable {
  let message: AgentMessage
  let placeholder: String
  let userWidth: CGFloat
  let showsCopy: Bool
  let palette: Palette
  /// The live run trace already shows these steps; saved/imported messages use the disclosure.
  var showsActivities = true
  /// Edit and rerun with the saved words (MessageEdit); nil where the chat is read only. Only
  /// whether it is set takes part in `==`: it acts on this message, which `==` compares.
  var edit: ((String) -> Void)? = nil
  /// Read when the editor opens (MessageEdit.laterFileChanges); like `edit`, it reads the live
  /// chat for this message, so it stays out of `==`.
  var changedFiles: () -> Bool = { false }
  @State private var editing = false

  static func == (a: Self, b: Self) -> Bool {
    a.message == b.message && a.placeholder == b.placeholder && a.userWidth == b.userWidth
      && a.showsCopy == b.showsCopy && a.palette == b.palette && a.showsActivities == b.showsActivities
      && (a.edit == nil) == (b.edit == nil)
  }

  var body: some View {
    if message.role == "you" {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        if editing, let edit {
          MessageEditor(text: message.text, attached: message.attached?.isEmpty == false,
                        changedFiles: changedFiles(),
                        save: { editing = false; edit($0); return nil }, cancel: { editing = false })
            .frame(maxWidth: userWidth, alignment: .trailing)
        } else {
          // Serein's own chat's bubble, its actions beside it so they leave no gap under it.
          if !message.text.isEmpty {
            HStack(alignment: .bottom, spacing: 6) {
              HStack(spacing: 2) {
                if edit != nil { MessageEditButton(isVisible: showsCopy) { editing = true } }
                MessageShortcutButton(text: message.text, isVisible: showsCopy)
                MessageCopyButton(text: message.text, isVisible: showsCopy)
              }
              PersonBubble(text: message.text)
                // Read when the message is drawn; a change of assistant shows when the chat reopens.
                .environment(\.personBubbleTint, palette.assistantTint(SereinSurface.controller?.relay.team.active?.colour))
                // The hover buttons are hidden from VoiceOver on older messages; these keep Save and Edit reachable.
                .accessibilityAction(named: "Save as shortcut") { ShortcutBook.offer(message.text) }
                .accessibilityActions { if edit != nil { Button("Edit message") { editing = true } } }
            }.frame(maxWidth: userWidth, alignment: .trailing)
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 6) {
        // The screenshots the agent took during the turn, before its answer.
        ForEach(message.images ?? [], id: \.self) { MessageImage(source: $0, alt: "Screenshot") }
        let words: String = message.text.isEmpty ? placeholder : message.text
        // The reply's Copy hangs beside a last bubble, and sits under a last table or code block.
        let endsInBubble: Bool = messageCachedBubbles(words).last?.kind == .words
        if !message.text.isEmpty || ((message.images ?? []).isEmpty && (message.activities ?? []).isEmpty) {
          // Short paragraphs in Serein's bubbles; code, tables and documents keep the column.
          let cited = messageCachedCitations(words)
          ReplyPieces(text: words) { piece, isLast in
            if piece.kind == .words {
              SereinReplyBubble(text: piece.text, tail: isLast) {
                MessageContent(text: piece.text, showsCopyButton: showsCopy, read: message.read, cited: cited)
              } accessory: {
                if isLast && !message.text.isEmpty { MessageCopyButton(text: message.text, isVisible: showsCopy) }
              }
            } else {
              MessageContent(text: piece.text, showsCopyButton: showsCopy, read: message.read, cited: cited)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }.environment(\.messageMetrics, .bubble)
        }
        // Choices Serein made on a page by itself, such as a cookie banner's most private option.
        ForEach((message.activities ?? []).filter { $0.tool == AgentRun.choiceTool }) { choice in
          HStack(spacing: 6) {
            InterfaceIcon(systemName: "hand.raised", size: 12).foregroundStyle(palette.secondary)
            Text(verbatim: choice.label).font(UIStyle.meta).foregroundStyle(palette.ink)
              .lineLimit(1).truncationMode(.middle)
          }.padding(.horizontal, 10).frame(height: 26)
            .background(palette.track, in: Capsule())
            .help(choice.label)
            .accessibilityElement(children: .ignore).accessibilityLabel(choice.label)
        }
        if showsActivities, let activities = message.activities?.filter({ $0.tool != AgentRun.choiceTool }),
          !activities.isEmpty
        {
          TranscriptActivityView(activities: activities)
        }
        if !message.text.isEmpty && !endsInBubble { MessageCopyButton(text: message.text, isVisible: showsCopy) }
      }
    }
  }
}
