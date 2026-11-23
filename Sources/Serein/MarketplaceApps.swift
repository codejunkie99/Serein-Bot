import SereinCore
import SwiftUI

/// The Marketplace's app pages: Apps (Recommended for you, then each group's first four with See
/// all), a group's every app, a search, and the page of an app the person added. "Recommended for
/// you" is what the person's AI chats use (`WorkspaceScan`), shown only once they let Serein read
/// those chats. The apps on this Mac keep Settings' own switches and privacy steps (the column's
/// On this Mac). Under a search, the official MCP Registry can be searched too
/// (`MCPRegistrySearch`, only on the person's press): its servers are nobody's reviewed apps, so
/// each says who published it or that it is a community server, asks for trust first, and then
/// goes through Add an MCP Server's full sign-in and tool review. Add custom opens that review for
/// any address.
struct MarketplaceApps: View {
  @Binding var place: MarketplacePlace
  let query: String
  @ObservedObject private var model = OneClickConnect.shared
  @ObservedObject private var host = PluginHost.shared
  @ObservedObject private var registry = MCPRegistrySearch.shared
  /// A Composio app's state, and a sign-in that finished while Serein was away, redraw at once.
  @ObservedObject private var composio = ComposioApps.shared
  @ObservedObject private var watch = ConnectionWatch.shared
  /// The registry server waiting for the person's trust.
  @State private var trusting: MCPRegistry.Server?
  /// The address whose Add an MCP Server review is open: a registry server's, or empty for Add custom.
  @State private var adding: AddressRequest?
  @State private var registryNote: String?
  /// The key app whose token sheet is open (GitHub, Slack).
  @State private var keyFor: ConnectorCatalog.Connector?
  @Environment(\.palette) private var p
  @State private var recommended: [ConnectorCatalog.Connector] = []
  /// Why an added connection's test from here failed, shared with the column's dots.
  @ObservedObject private var failed = MarketplaceFailures.shared

  struct AddressRequest: Identifiable {
    let id = UUID()
    let address: String
  }
  /// The words that find the apps on this Mac in a search.
  private static let macWords = ["mail", "gmail", "outlook", "icloud", "messages", "calendar", "google calendar", "reminders", "contacts", "notes"]

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      if searching.isEmpty, case .app(let id) = place, let app = ConnectorCatalog.all.first(where: { $0.id == id }) {
        appPage(app)
      } else {
        header
        VStack(alignment: .leading, spacing: 26) { lists }
      }
    }
    // The token sheet on its own holder, apart from Add an MCP Server's: one sheet per view.
    .background(Color.clear.sheet(item: $keyFor) { app in KeyConnectSheet(connector: app) })
    .task { await recommend() }
    .onChange(of: query) { _, now in
      registry.clear(unless: now)
      registryNote = nil
    }
    .confirmationDialog(
      "Connect a server nobody has reviewed?",
      isPresented: Binding(get: { trusting != nil }, set: { if !$0 { trusting = nil } }),
      titleVisibility: .visible, presenting: trusting
    ) { server in
      Button("I trust this server") {
        trusting = nil
        // After the dialog has gone, so the sheet is not refused while it closes.
        DispatchQueue.main.async { adding = AddressRequest(address: server.url) }
      }
      Button("Cancel", role: .cancel) { trusting = nil }
    } message: { server in
      Text(Self.trustWords(server))
    }
    .sheet(item: $adding) { request in
      MCPAddServerSheet(address: request.address) { note in
        adding = nil
        registryNote = note
      }
    }
  }

  // MARK: Pages

  private var header: some View {
    let (title, sentence): (String, String) = {
      if !searching.isEmpty { return ("Apps", "Apps that match “\(searching)”.") }
      if case .category(let category) = place {
        return (category.title, "\(ConnectorCatalog.all.filter { $0.category == category }.count) apps")
      }
      return ("Apps", "\(ConnectorCatalog.all.count) apps your assistants can use. Any other app with an MCP server connects by its address.")
    }()
    return SettingsPageHeader(title, sentence: sentence) {
      Button { adding = AddressRequest(address: "") } label: {
        Label("Add custom", systemImage: "plus")
      }.help("Add any app with an MCP server by its address").accessibilityLabel("Add custom: an MCP server by its address")
    }
  }

  @ViewBuilder private var lists: some View {
    if !searching.isEmpty {
      ForEach(ConnectorCatalog.Category.allCases, id: \.self) { category in
        let apps = shown(category)
        if !apps.isEmpty { section(category.title, apps: apps) }
      }
      if showsMac {
        VStack(alignment: .leading, spacing: 10) {
          Text("On this Mac").font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
          ConnectionSettings(macOnly: true)
        }
      }
      if nothingFound {
        Text("No app matches “\(searching)”. Any app with an MCP server connects by its address: choose Add custom.")
          .font(UIStyle.meta).foregroundStyle(p.secondary)
      }
      if MCPRegistry.searchURL(searching) != nil { registrySection }
    } else if case .category(let category) = place {
      grid(ConnectorCatalog.all.filter { $0.category == category })
    } else {
      if !recommended.isEmpty { section("Recommended for you", apps: recommended) }
      ForEach(ConnectorCatalog.Category.allCases, id: \.self) { category in
        let apps = ConnectorCatalog.all.filter { $0.category == category }
        let preview = MarketplaceRules.preview(apps)
        section(category.title, apps: preview.shown, count: apps.count, seeAll: preview.more ? category : nil)
      }
    }
  }

  /// An added app's own page, from Your apps: its state, what to do about it, and how it signs in
  /// and where it runs.
  private func appPage(_ app: ConnectorCatalog.Connector) -> some View {
    let state = shownState(app)
    return VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 16) {
        AppLogoTile(id: app.id, name: app.name, size: 56)
        VStack(alignment: .leading, spacing: 2) {
          Text(app.name).font(UIStyle.title).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
          Text(app.does).font(UIStyle.body).foregroundStyle(p.secondary)
        }
      }
      if state != .notSetUp {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: state.needsAttention ? "exclamationmark.triangle" : state == .working ? "checkmark" : "circle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(state.needsAttention ? p.warning : state == .working ? p.success : p.faint)
            .accessibilityHidden(true)
          Text(state.line).font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.rowRadius, style: .continuous))
      }
      HStack(spacing: 8) {
        appActions(app, state: state)
        if state != .notSetUp {
          Button("Manage in Settings") { RelayController.shared?.openSettings("Connections") }
            .help("Settings › Connections: its tools, its sign-in and Remove")
        }
      }
      Rectangle().fill(p.line).frame(height: UIStyle.hairline)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        fact("Signs in with", Self.signInWords(app))
        GridRow {
          Text("Runs at").font(UIStyle.meta).foregroundStyle(p.secondary)
          Text(URL(string: app.url)?.host ?? app.url).font(UIStyle.mono(12)).foregroundStyle(p.ink).textSelection(.enabled)
        }
        fact("Group", app.category.title)
      }
    }.frame(maxWidth: 600, alignment: .leading)
  }
  @ViewBuilder private func appActions(_ app: ConnectorCatalog.Connector, state: ConnectionState) -> some View {
    switch (state, model.steps[app.id]) {
    case (.testing, _), (.notSetUp, .working?):
      ProgressView().controlSize(.small).accessibilityLabel("\(app.name): \(state.title)")
    case (.working, _):
      if let package = package(app) {
        Button("Turn off") { host.setEnabled(package, false) }.disabled(host.busy != nil)
      }
    case (.off, _), (.needsAttention, _):
      Button(state == .off ? "Turn on" : "Try again") { turnOn(app) }.buttonStyle(PrimaryButton())
    default:
      Button("Connect \(app.name)") { start(app) }.buttonStyle(PrimaryButton())
    }
  }
  private func fact(_ name: String, _ value: String) -> some View {
    GridRow {
      Text(name).font(UIStyle.meta).foregroundStyle(p.secondary)
      Text(value).font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
    }
  }
  /// How an app signs in, in the words of its page.
  static func signInWords(_ app: ConnectorCatalog.Connector) -> String {
    switch app.signIn {
    case .browser: return "Your browser, on \(app.name)'s own sign-in page."
    case .key(let key): return "A \(key.name) you make in \(app.name), kept in the Keychain."
    case .composio: return "Composio's sign-in, once Composio is on in Settings › Connections."
    }
  }

  /// Connect: a key app asks for its token first; a Composio app with Composio off opens
  /// Settings › Connections, where Composio is turned on (closing Settings comes back here); any
  /// other app connects at once.
  private func start(_ app: ConnectorCatalog.Connector) {
    switch app.signIn {
    case .key: keyFor = app
    case .composio where !ComposioApps.available: RelayController.shared?.openSettings("Connections")
    default: model.connect(app)
    }
  }
  /// What the row adds after what the app does, for an app that signs in another way.
  static func signInNote(_ app: ConnectorCatalog.Connector) -> String {
    switch app.signIn {
    case .browser: return ""
    case .key(let key): return " · with a \(key.name)"
    case .composio: return " · through Composio"
    }
  }

  // MARK: The MCP Registry

  private var registrySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("MCP Registry").font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
        Spacer()
        if case .searching = registry.state { ProgressView().controlSize(.small).accessibilityLabel("Searching the MCP Registry") }
      }
      switch registry.state {
      case .found(let words, let servers) where words == MCPRegistry.normalizedQuery(searching):
        if servers.isEmpty {
          Text("The registry has no server Serein can connect to for “\(words)”.").font(UIStyle.meta).foregroundStyle(p.secondary)
        } else {
          LazyVGrid(columns: Self.columns, spacing: 8) {
            ForEach(servers) { server in registryTile(server) }
          }
        }
      case .failed(let words) where words == MCPRegistry.normalizedQuery(searching):
        HStack {
          Text("Serein couldn't reach the MCP Registry.").font(UIStyle.meta).foregroundStyle(p.secondary)
          Spacer()
          Button("Try again") { registry.search(searching) }
        }
      case .searching:
        Text("Searching the MCP Registry…").font(UIStyle.meta).foregroundStyle(p.secondary)
      default:
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("Servers anyone can publish, not reviewed by Serein. Searching sends “\(MCPRegistry.normalizedQuery(searching))” to registry.modelcontextprotocol.io.")
            .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button("Search the registry") { registry.search(searching) }
        }
      }
      if let registryNote {
        Text(registryNote).font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func registryTile(_ server: MCPRegistry.Server) -> some View {
    HStack(spacing: 12) {
      AppLogoTile(id: "registry", name: server.title, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(server.title).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1)
        Text(Self.sourceWords(server)).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1)
        if !server.summary.isEmpty {
          Text(server.summary).font(UIStyle.meta).foregroundStyle(p.faint).lineLimit(1)
        }
      }.help(server.url)
      Spacer(minLength: 8)
      if let package = registryPackage(server) {
        let state = host.connectionState(package)
        Label(state.title, systemImage: state == .working ? "checkmark" : "circle.dashed").labelStyle(.titleAndIcon).font(UIStyle.meta)
          .foregroundStyle(state.needsAttention ? p.warning : p.secondary).help(state.line)
      } else {
        capsule("Review") { trusting = server }
          .accessibilityLabel("Review \(server.title) from the MCP Registry")
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 8)
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .hoverWash(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  /// "Published by notion.com", or "Community · example.dev" for anyone else; never reviewed.
  static func sourceWords(_ server: MCPRegistry.Server) -> String {
    let source = server.publisher.map { "Published by \($0)" } ?? "Community · \(server.host)"
    return source + " · not reviewed" + (server.needsKey ? " · needs a key" : "")
  }
  static func trustWords(_ server: MCPRegistry.Server) -> String {
    "“\(server.title)” is listed in the public MCP Registry as \(server.name) and runs at \(server.host). "
      + (server.publisher == nil ? "Its publisher is not \(server.host)'s owner as far as the registry knows. " : "")
      + "Serein has not checked it. Next you sign in and see every tool it offers; nothing is on until you connect it."
  }
  private func registryPackage(_ server: MCPRegistry.Server) -> PluginPackage? {
    host.packages.first { host.states[$0.id]?.address == server.url }
  }

  // MARK: Parts

  private static let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

  /// A group: its name and count, See all when it has more than it shows, then its apps.
  private func section(_ title: String, apps: [ConnectorCatalog.Connector], count: Int? = nil, seeAll: ConnectorCatalog.Category? = nil) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(title).font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
        if let count { Text("\(count)").font(UIStyle.meta).foregroundStyle(p.faint).accessibilityLabel("\(count) apps") }
        Spacer(minLength: 8)
        if let seeAll, let count {
          Button { place = .category(seeAll) } label: {
            HStack(spacing: 3) {
              Text("See all \(count)")
              Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }.font(UIStyle.meta).foregroundStyle(p.secondary)
          }.buttonStyle(.pressable).accessibilityLabel("See all \(count) \(title) apps")
        }
      }.padding(.horizontal, 10)
      grid(apps)
    }
  }
  private func grid(_ apps: [ConnectorCatalog.Connector]) -> some View {
    LazyVGrid(columns: Self.columns, spacing: 8) {
      ForEach(apps) { app in tile(app) }
    }
  }

  private func tile(_ app: ConnectorCatalog.Connector) -> some View {
    HStack(spacing: 12) {
      AppLogoTile(id: app.id, name: app.name, size: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1)
        let line: ConnectionState = shownState(app)
        Text(line == .notSetUp || line == .working ? app.does + Self.signInNote(app) : line.line).font(UIStyle.meta)
          .foregroundStyle(line.needsAttention ? p.warning : p.secondary).lineLimit(1).help(line.line)
      }
      Spacer(minLength: 8)
      let state = shownState(app)
      switch (state, model.steps[app.id]) {
      case (.working, _):
        Label(state.title, systemImage: "checkmark").labelStyle(.titleAndIcon).font(UIStyle.meta).foregroundStyle(p.secondary)
      case (.testing, _), (.notSetUp, .working?):
        ProgressView().controlSize(.small).help(model.steps[app.id].flatMap(Self.stepWords) ?? state.title)
          .accessibilityLabel("\(app.name): \(state.title)")
      case (.off, _), (.needsAttention, _):
        capsule(state == .off ? "Turn on" : "Try again") { turnOn(app) }.help(state.line)
          .accessibilityLabel("\(app.name): \(state.line). \(state == .off ? "Turn on" : "Try again")")
      default:
        capsule("Connect", plus: true) { start(app) }.accessibilityLabel("Connect \(app.name)")
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 8)
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .hoverWash(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }
  /// A row's action: a 28-point capsule on `track`.
  private func capsule(_ words: String, plus: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if plus { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
        Text(words)
      }.font(UIStyle.meta).foregroundStyle(p.ink)
        .padding(.horizontal, 14).frame(height: 28)
        .background(p.track, in: Capsule())
        .contentShape(Capsule())
    }.buttonStyle(AssistantPressStyle())
  }

  // MARK: Its state

  private func shownState(_ app: ConnectorCatalog.Connector) -> ConnectionState {
    MarketplaceStatus.of(app)
  }
  private func package(_ app: ConnectorCatalog.Connector) -> PluginPackage? {
    guard let id = OneClickConnect.pluginID(app) else { return nil }
    return host.packages.first { $0.id == id }
  }
  private static func stepWords(_ step: OneClickConnect.Step) -> String? {
    if case .working(let words) = step { return words }
    return nil
  }
  /// Off or needing attention: an added connection turns on only through its test (the server's
  /// own tool list, as reviewed); an app not added yet connects again from the start.
  private func turnOn(_ app: ConnectorCatalog.Connector) {
    guard let package = package(app) else {
      failed.reasons[app.id] = nil
      start(app)
      return
    }
    let state = host.connectionState(package)
    guard state.allows(.turnOn) else { return }
    failed.reasons[app.id] = nil
    Task {
      do { try await host.enable(package) } catch {
        if !host.isEnabled(package) { failed.reasons[app.id] = state.next(.turnOn).next(.testFailed(reason: error.localizedDescription)) }
      }
    }
  }

  // MARK: What shows

  private var searching: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private func matches(_ app: ConnectorCatalog.Connector) -> Bool {
    searching.isEmpty || app.name.localizedCaseInsensitiveContains(searching) || app.does.localizedCaseInsensitiveContains(searching)
      || app.words.contains { $0.localizedCaseInsensitiveContains(searching) }
  }
  private func shown(_ category: ConnectorCatalog.Category) -> [ConnectorCatalog.Connector] {
    ConnectorCatalog.all.filter { $0.category == category && matches($0) }
  }
  private var showsMac: Bool {
    Self.macWords.contains { $0.contains(searching.lowercased()) }
  }
  private var nothingFound: Bool {
    !showsMac && ConnectorCatalog.Category.allCases.allSatisfy { shown($0).isEmpty }
  }

  /// What the person's chats use and is not connected yet, once they let Serein read those chats.
  private func recommend() async {
    // A preview shows made-up picks: this Mac's real chats must not reach a capture.
    guard !RunMode.previewing else { recommended = Array(ConnectorCatalog.all.prefix(4)); return }
    guard SessionReading.allowed else { return }
    let files = WorkspaceScan.recentFiles
    let home = SessionReading.home
    let (chats, configured) = await Task.detached(priority: .utility) { WorkspaceScan.counts(files: files, home: home) }.value
    let names = WorkspaceSignals.suggestions(chats: chats, configured: configured, connected: [], limit: 8).map(\.name)
    recommended = names.compactMap(ConnectorCatalog.find).filter { !model.isConnected($0) }.prefix(4).map { $0 }
  }
}

/// One catalog app's plain state, for the Apps page and the column's Your apps: an added
/// connection's own (`PluginHost.connectionState`), a Composio account's, or this launch's attempt
/// to connect it.
@MainActor enum MarketplaceStatus {
  static func of(_ app: ConnectorCatalog.Connector) -> ConnectionState {
    if let failure = MarketplaceFailures.shared.reasons[app.id] { return failure }
    let host = PluginHost.shared
    let model = OneClickConnect.shared
    if let id = OneClickConnect.pluginID(app), let package = host.packages.first(where: { $0.id == id }) {
      return host.connectionState(package)
    }
    if model.isConnected(app) { return .working }
    if case .failed(let why)? = model.steps[app.id] { return ConnectionState.of(on: false, testing: false, problem: why) }
    return .notSetUp
  }
}

/// Why an added connection's test from the Marketplace failed, by connector id, until the next
/// try: one record for the app page, its row and the column's dot.
@MainActor final class MarketplaceFailures: ObservableObject {
  static let shared = MarketplaceFailures()
  @Published var reasons: [String: ConnectionState] = [:]
}
