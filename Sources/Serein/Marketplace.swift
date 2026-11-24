import SereinCore
import SwiftUI

/// The Marketplace, open in the main window like Settings (`ShellSection.marketplace`): the card's
/// header row ("Marketplace › Apps", search, ×), its column (Apps, Teams, Plugins, then Your apps,
/// where connected apps are managed, and On this Mac) and the open page. Opened from the sidebar's Marketplace row, the rail and Add
/// app in the message box's +; closing returns to what showed before. It opens on Apps, and keeps
/// its page while Settings covers it.
/// A search on Teams filters the starters; anywhere else it searches the apps.
struct MarketplacePage: View {
  @ObservedObject var browser: BrowserModel
  var sidebarHidden = false
  var fullScreen = false
  var showSidebar: () -> Void = {}
  @ObservedObject private var textSize = TextSizeController.shared
  private var place: MarketplacePlace { browser.marketplacePlace }
  @State private var query = ""
  @Environment(\.palette) private var p
  private static let top = "marketplace.top"

  var body: some View {
    VStack(spacing: 0) {
      SettingsTabHeader(
        levels: place.levels, query: $query,
        go: { _ in if let parent = place.parent { open(parent) } },
        close: { browser.showMarketplace = false },
        sidebarHidden: sidebarHidden, fullScreen: fullScreen, showSidebar: showSidebar,
        root: "Marketplace", rootIcon: "square.grid.2x2.badge.plus", searchPrompt: "Search the Marketplace…")
      HStack(alignment: .top, spacing: 0) {
        MarketplaceColumn(selected: place.columnRow, open: open)
        ScrollViewReader { reader in
          ScrollView {
            page
              .padding(.horizontal, UIStyle.pageGutter).padding(.top, 14).padding(.bottom, 56)
              .frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity).id(Self.top)
          }
          .onChange(of: place) { _, _ in reader.scrollTo(Self.top, anchor: .top) }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).background(p.background).foregroundStyle(p.ink)
    // The pages Settings shares (Plugins, On this Mac) keep Settings' controls.
    .font(UIStyle.body).buttonStyle(QuietButton()).controlSize(.small).tint(p.solid)
    .toggleStyle(SettingsToggleStyle())
    .id(textSize.generation)
  }

  private func open(_ next: MarketplacePlace) {
    browser.marketplacePlace = next
    query = ""
  }

  @ViewBuilder private var page: some View {
    let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    switch place {
    case .teams:
      MarketplaceTeams(query: query)
    case .plugins where !searching:
      VStack(alignment: .leading, spacing: 24) {
        SettingsPageHeader("Plugins", sentence: "Skills and tools for Serein, from a folder, a link or the plugin index.") { EmptyView() }
        PluginSettings()
      }
    case .mac where !searching:
      VStack(alignment: .leading, spacing: 24) {
        SettingsPageHeader("On this Mac", sentence: "Mail, Calendar and the other apps on this Mac keep their own switches and privacy steps.") { EmptyView() }
        // These switches are gate switches: the notice Settings showed over them shows here.
        GateNotice()
        ConnectionSettings()
      }
    case .yours where !searching:
      // What Settings › Connections held for connected apps: each one's switch, tools, sign-in and
      // Remove, then Composio's key and accounts. Apps to add are on Apps.
      VStack(alignment: .leading, spacing: 24) {
        SettingsPageHeader("Your apps", sentence: "The apps you connected: turn one off, review its tools, sign out, or remove it.") { EmptyView() }
        GateNotice()
        MCPConnectionsRows()
        ComposioConnectionsRows()
      }
    default:
      MarketplaceApps(place: Binding(get: { place }, set: { open($0) }), query: query)
    }
  }
}

/// The Marketplace's column, inside the card on its own colour like Settings' page list: Apps,
/// Teams and Plugins, then Your apps (each added app with its state's dot, what needs the person
/// first) and On this Mac with how many are on.
struct MarketplaceColumn: View {
  let selected: MarketplacePlace
  let open: (MarketplacePlace) -> Void
  @ObservedObject private var model = OneClickConnect.shared
  @ObservedObject private var host = PluginHost.shared
  @ObservedObject private var failures = MarketplaceFailures.shared
  /// Composio accounts and macOS access (On this Mac's count) change outside Serein.
  @ObservedObject private var composio = ComposioApps.shared
  @ObservedObject private var watch = ConnectionWatch.shared
  @Environment(\.palette) private var p

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 1) {
        row(.apps, icon: "square.grid.2x2", trailing: "\(ConnectorCatalog.all.count)")
        row(.teams, icon: "person.2")
        row(.plugins, icon: "puzzlepiece.extension")
        Text("Your apps").font(AssistantType.meta).foregroundStyle(p.secondary)
          .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
          .accessibilityAddTraits(.isHeader)
        row(.yours, icon: "slider.horizontal.3")
        ForEach(yourApps, id: \.app.id) { entry in
          MarketplaceColumnRow(label: entry.app.name, selected: selected == .app(entry.app.id), action: { open(.app(entry.app.id)) }) {
            AppLogoTile(id: entry.app.id, name: entry.app.name, size: 18)
          } trailing: {
            StatusDot(state: entry.state)
          }
          .accessibilityValue(entry.state.title)
        }
        row(.mac, icon: "laptopcomputer", trailing: "\(macOn) on")
      }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 20)
    }
    .scrollIndicators(.never)
    .frame(width: SettingsPageList.width).frame(maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain).accessibilityLabel("Marketplace places")
  }

  private func row(_ place: MarketplacePlace, icon: String, trailing: String? = nil) -> some View {
    MarketplaceColumnRow(label: place == .yours ? "Manage apps" : place.label, selected: selected == place, action: { open(place) }) {
      InterfaceIcon(systemName: icon, size: 14).foregroundStyle(selected == place ? p.ink : p.secondary)
    } trailing: {
      if let trailing { Text(trailing).font(UIStyle.meta).foregroundStyle(p.faint).accessibilityHidden(true) }
    }
    .accessibilityValue(trailing ?? "")
  }

  /// The apps the person added, what needs them first (`MarketplaceRules.yourApps`).
  private var yourApps: [(app: ConnectorCatalog.Connector, state: ConnectionState)] {
    let states = ConnectorCatalog.all.map { (id: $0.id, state: MarketplaceStatus.of($0)) }
    let byID = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.state) })
    return MarketplaceRules.yourApps(states).compactMap { id in
      ConnectorCatalog.all.first { $0.id == id }.map { (app: $0, state: byID[id] ?? .notSetUp) }
    }
  }
  private var macOn: Int {
    Connection.allCases.filter { Connections.isOn($0) }.count + NativeConnection.allCases.filter { $0.isOn() }.count
  }
}

/// One row of the Marketplace's column: a glyph or logo, the label, and a count or a state, 30
/// high; the open place on `selected`, the rest washing on hover.
private struct MarketplaceColumnRow<Leading: View, Trailing: View>: View {
  let label: String
  let selected: Bool
  let action: () -> Void
  @ViewBuilder var leading: () -> Leading
  @ViewBuilder var trailing: () -> Trailing
  @State private var hovered = false
  @Environment(\.palette) private var p
  @Environment(\.reducesMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        leading().frame(width: 18)
        Text(verbatim: label).font(selected ? UIStyle.bodyStrong : UIStyle.body).foregroundStyle(p.ink).lineLimit(1)
        Spacer(minLength: 4)
        trailing()
      }
      .padding(.horizontal, 10).frame(height: 30)
      .background(
        RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous)
          .fill(selected ? p.selected : (hovered ? p.hover : .clear))
      )
      .contentShape(RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous))
    }
    .buttonStyle(.pressable)
    .onHover { inside in
      if reduceMotion { hovered = inside } else { withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
    }
    .accessibilityLabel(label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// An added app's state as a 7-point dot: `success` working, `warning` needing attention, a
/// hollow `faint` ring off, `faint` while testing. Its words are the row's accessibility value.
private struct StatusDot: View {
  let state: ConnectionState
  @Environment(\.palette) private var p
  var body: some View {
    Group {
      switch state {
      case .working: Circle().fill(p.success)
      case .needsAttention: Circle().fill(p.warning)
      case .testing: Circle().fill(p.faint)
      default: Circle().strokeBorder(p.faint, lineWidth: 1.5)
      }
    }
    .frame(width: 7, height: 7).help(state.line).accessibilityHidden(true)
  }
}

/// The Marketplace's Teams: the starter teams this person can use (`TeamStarter.offered`), each
/// opening New team on its starter, which shows the team before anything is added; New team
/// opens the sheet's start.
struct MarketplaceTeams: View {
  let query: String
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      SettingsPageHeader("Teams", sentence: "Starter teams of two assistants. Each shows its assistants and what they would use before you add it.") {
        Button { TeamSheets.shared.present(.newTeam(.home)) } label: { Label("New team", systemImage: "plus") }
      }
      if let relay = SereinSurface.controller?.relay {
        MarketplaceStarters(relay: relay, query: query)
      } else {
        SereinUnavailable()
      }
    }
  }
}

private struct MarketplaceStarters: View {
  @ObservedObject var relay: RelayOrchestrator
  let query: String
  @Environment(\.palette) private var p
  private var starters: [TeamStarter] {
    let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let offered = TeamStarter.offered(person: relay.personPlaces)
    guard !words.isEmpty else { return offered }
    return offered.filter { starter in
      ([starter.name, starter.line] + starter.members.map(\.name)).contains { $0.localizedCaseInsensitiveContains(words) }
    }
  }
  var body: some View {
    if starters.isEmpty {
      Text("No starter team matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”. New team makes one of your own.")
        .font(UIStyle.meta).foregroundStyle(p.secondary)
    } else {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
        ForEach(starters) { starter in
          StarterCard(starter: starter) { TeamSheets.shared.present(.newTeam(.starter(starter.id))) }
        }
      }
    }
  }
}
