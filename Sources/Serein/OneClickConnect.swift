import SereinCore
import SwiftUI

/// Connects one of `ConnectorCatalog`'s apps with a single press: the same steps as Settings ›
/// Connections › Add an MCP Server, run in order (find the server and its sign-in, sign in in the
/// browser, list its tools, turn it on), with the tool review's defaults. Every call asks first
/// by its risk; the first read's card offers "Always allow reads from <App>", after which a read
/// asks only as the first call after outside content. The person can review the tools or remove
/// the app in Settings.
/// An app that signs in with a key (GitHub, Slack) takes the token the person pastes in
/// `KeyConnectSheet` instead of the browser step (`connect(_:key:)`); an app that signs in through
/// Composio (HubSpot) opens Composio's sign-in, and needs Connected apps (Composio) turned on.
@MainActor final class OneClickConnect: ObservableObject {
  static let shared = OneClickConnect()
  enum Step: Equatable {
    case working(String)
    case done
    case failed(String)
  }
  /// By connector id; nothing while it has not been pressed this launch.
  @Published private(set) var steps: [String: Step] = [:]

  /// The plugin id its connection gets (`MCPServerConnection.id`).
  static func pluginID(_ connector: ConnectorCatalog.Connector) -> String? {
    URL(string: connector.url).flatMap(MCPServerConnection.id(for:))
  }
  func isConnected(_ connector: ConnectorCatalog.Connector) -> Bool {
    if let app = connector.signIn.composioApp,
      ComposioApps.shared.accounts.contains(where: { $0.app == app && $0.active })
    {
      return true
    }
    guard let id = Self.pluginID(connector) else { return false }
    return PluginHost.shared.packages.contains { $0.id == id }
  }

  /// Whether the chat's `connect_app` offers this catalog app's pill. A key app gives way to
  /// Composio's browser sign-in while Composio is on (as before it was in the catalog), unless it
  /// is already connected by its key; a Composio app always goes through Composio's own pill.
  func offeredInChat(_ connector: ConnectorCatalog.Connector) -> Bool {
    switch connector.signIn {
    case .browser: return true
    case .key: return isConnected(connector) || !ComposioApps.available
    case .composio: return false
    }
  }

  static func composioOffMessage(_ name: String) -> String {
    "\(name) connects through Composio. Turn on Connected apps (Composio) in Marketplace › Your apps first."
  }

  func connect(_ connector: ConnectorCatalog.Connector) {
    if case .working = steps[connector.id] { return }
    if isConnected(connector) {
      steps[connector.id] = .done
      return
    }
    switch connector.signIn {
    case .browser: break
    case .key(let key):
      // The token comes from KeyConnectSheet, through connect(_:key:).
      steps[connector.id] = .failed("Paste a \(key.name) to connect \(connector.name).")
      return
    case .composio(let app):
      connectThroughComposio(connector, app: app)
      return
    }
    let host = PluginHost.shared
    steps[connector.id] = .working("Opening \(connector.name)…")
    Task {
      var draft: PluginHost.Draft?
      do {
        var found = try await host.draft(connector.url)
        found.name = connector.name
        draft = found
        guard found.canSignIn else { throw SereinError.invalid("\(connector.name) did not offer a sign-in Serein can use.") }
        steps[connector.id] = .working("Sign in to \(connector.name) in your browser…")
        try await PluginSignIn.run(plugin: found.id, name: connector.name, serverURL: found.url, expectedHost: found.signInHost)
        found.auth = .oauth
        draft = found
        steps[connector.id] = .working("Turning on \(connector.name)…")
        let tools = try await host.review(found)
        try await host.connect(found, review: tools)
        steps[connector.id] = .done
      } catch {
        if let draft, !isConnected(connector) { host.discard(draft) }
        steps[connector.id] = .failed(error.localizedDescription)
      }
    }
  }

  /// A key app with the token the person pasted: its shape is checked first; then the token goes
  /// to the Keychain under the connection's id and nowhere else, the tools are listed with it, and
  /// the connection turns on with the review's defaults. A token that fails leaves the Keychain.
  func connect(_ connector: ConnectorCatalog.Connector, key raw: String) {
    guard let key = connector.signIn.key else { return connect(connector) }
    if case .working = steps[connector.id] { return }
    if let problem = key.problem(raw) {
      steps[connector.id] = .failed(problem)
      return
    }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = MCPServerConnection.address(connector.url), let id = MCPServerConnection.id(for: url) else {
      steps[connector.id] = .failed("\(connector.name)'s address is not one Serein connects to.")
      return
    }
    let host = PluginHost.shared
    if host.packages.contains(where: { $0.id == id }) {
      steps[connector.id] = .done
      return
    }
    let draft = PluginHost.Draft(url: url, id: id, name: connector.name, auth: .token, canSignIn: false)
    steps[connector.id] = .working("Checking your \(key.name) with \(connector.name)…")
    PluginHost.saveOAuth(plugin: id, tokens: nil)
    PluginHost.saveSecret(token, plugin: id, name: MCPServerConnection.tokenName)
    Task {
      do {
        let tools = try await host.review(draft)
        steps[connector.id] = .working("Turning on \(connector.name)…")
        try await host.connect(draft, review: tools)
        steps[connector.id] = .done
      } catch {
        if !isConnected(connector) { host.discard(draft) }
        steps[connector.id] = .failed(error.localizedDescription)
      }
    }
  }

  /// Composio's hosted sign-in for the app, in the person's browser (`ComposioApps.connect`).
  private func connectThroughComposio(_ connector: ConnectorCatalog.Connector, app: String) {
    guard ComposioApps.available else {
      steps[connector.id] = .failed(Self.composioOffMessage(connector.name))
      return
    }
    steps[connector.id] = .working("Sign in to \(connector.name) in your browser…")
    Task {
      do {
        // An account Composio already has counts: no second sign-in for it.
        try? await ComposioApps.shared.refresh()
        if isConnected(connector) {
          steps[connector.id] = .done
          return
        }
        try await ComposioApps.shared.connect(app: app)
        steps[connector.id] = isConnected(connector) ? .done : .failed("The sign-in did not finish. Try again.")
      } catch {
        steps[connector.id] = .failed(error.localizedDescription)
      }
    }
  }
}

/// A one-click app in the chat: its logo and Connect {App}, then where it is, then connected.
/// `carryOn` runs once it is connected, to go on with what the person asked.
struct OneClickConnectPill: View {
  let connector: ConnectorCatalog.Connector
  var carryOn: (() -> Void)? = nil
  @ObservedObject private var model = OneClickConnect.shared
  @ObservedObject private var host = PluginHost.shared
  @ObservedObject private var composio = ComposioApps.shared
  @ObservedObject private var watch = ConnectionWatch.shared
  @Environment(\.palette) private var p
  @State private var carried = false
  @State private var keyFor: ConnectorCatalog.Connector?

  var body: some View {
    let connected = model.isConnected(connector)
    HStack(spacing: 12) {
      AppLogoTile(id: connector.id, name: connector.name, size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text(connector.name).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
        Group {
          switch (connected, model.steps[connector.id]) {
          case (true, _): Text("Connected").foregroundStyle(p.secondary)
          case (false, .working(let words)?): Text(words).foregroundStyle(p.secondary)
          case (false, .failed(let why)?): Text(why).foregroundStyle(p.danger)
          default: Text(connector.does).foregroundStyle(p.secondary)
          }
        }.font(AssistantType.meta).lineLimit(2)
      }.frame(maxWidth: .infinity, alignment: .leading)
      switch (connected, model.steps[connector.id]) {
      case (true, _):
        Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(p.accent).accessibilityHidden(true)
      case (false, .working?): ProgressView().controlSize(.small).accessibilityHidden(true)
      case (false, .failed?): Button("Try again") { start() }.buttonStyle(PillButton(kind: .quiet, small: true))
      default:
        Button("Connect") { start() }.buttonStyle(PillButton(kind: .solid, small: true))
          .accessibilityLabel("Connect \(connector.name)")
      }
    }
    .padding(10)
    .frame(maxWidth: 340)
    .background(p.overlay, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.line, lineWidth: 1))
    .onChange(of: connected) { _, now in
      guard now, !carried else { return }
      carried = true
      carryOn?()
    }
    .sheet(item: $keyFor) { app in KeyConnectSheet(connector: app) }
    .accessibilityElement(children: .contain)
    .onAppear {
      // `--ui-serein-github-sheet` (UI preview only): the token sheet open, for a capture.
      guard CommandLine.arguments.contains("--ui-preview"), CommandLine.arguments.contains("--ui-serein-github-sheet"),
        connector.signIn.key != nil
      else { return }
      keyFor = connector
    }
  }
  private func start() {
    if connector.signIn.key != nil { keyFor = connector } else { model.connect(connector) }
  }
}

/// An app's logo on a light rounded tile with a thin edge, as app stores and Grok Bot show them,
/// so dark marks (Vercel, Linear) stay visible in dark mode. With no logo, its first letter.
struct AppLogoTile: View {
  let id: String
  let name: String
  var size: CGFloat = 40
  @Environment(\.palette) private var p
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    ZStack {
      if let brand = Brand.app(id) {
        shape.fill(Palette.light.background)
        BrandLogo(brand, size: size * 0.6, name: name).environment(\.palette, .light)
      } else {
        shape.fill(p.track)
        Text(String(name.prefix(1)).uppercased()).font(UIStyle.font(size * 0.42, weight: .semibold)).foregroundStyle(p.ink)
      }
    }
    .frame(width: size, height: size)
    .overlay(shape.strokeBorder(p.line, lineWidth: 1))
    .accessibilityHidden(true)
  }
}
