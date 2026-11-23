import Foundation
import SereinCore
import SwiftUI

/// A connection a turn in Serein's chat needed and did not have: its AI app, Mail or Messages
/// (off, reading off, Full Disk Access, or Automation refused), Calendar, Reminders, Contacts or
/// Notes (off, or not allowed by macOS), connected apps (off, or no account for the app) or an
/// MCP server that is off. Read from the refusal the model already gets (`of`), so the model's
/// words stay as they are; the card under the reply is UI only (`ConnectNeedCard`).
enum ConnectNeed: Hashable {
  case aiApp(Provider)
  /// The AI app refused its own key on `model` (OpenCode only, `OpenCodeKeyCard`).
  case aiKey(Provider, model: String, KeyFailure)
  case connection(Connection)
  case messagesReading
  case fullDisk
  case automation(Connection)
  /// `macOS`: the switch is on and macOS has not given Serein access.
  case native(NativeConnection, macOS: Bool)
  case connectedApps
  /// A Composio app (its slug) with no ready account.
  case app(String)
  /// An MCP server connected by address (its package id and name) that is off or held for review.
  case server(id: String, name: String)
  /// The dispatch refusal when the assistant's AI app is missing (AgentModel.dispatch).
  static let noAIApp = "Serein needs an AI app for this. Connect one in Settings › AI apps."
  /// The dispatch refusal when the assistant's AI app is signed out (AgentModel.dispatch).
  @MainActor static func signedOut(_ provider: Provider) -> String {
    "\(provider.name) is signed out. Sign in to \(provider.name) to continue."
  }

  /// The connection a tool refusal names, by the exact words the refusal is made of, while the
  /// connection is still missing. Words count only from the connection's own tool, which Serein
  /// writes them for: a plugin's or a server's text (its tool names hold `__`) never matches.
  /// nil for every other refusal.
  @MainActor static func of(tool: String, arguments: [String: Any], refusal: String) -> ConnectNeed? {
    if let own = Connections.Tool(rawValue: tool) {
      let connection = own.connection
      if refusal == Connections.offRefusal(connection), !Connections.isOn(connection) { return .connection(connection) }
      if refusal == Connections.automationRefusal(connection) { return .automation(connection) }
      if own == .messagesRead {
        if refusal == Connections.readingOffRefusal, !Connections.readsMessages() { return .messagesReading }
        if refusal == Connections.fullDiskRefusal { return .fullDisk }
      }
    }
    if let connection = NativeConnection.of(tool: tool) {
      if refusal == connection.turnedOff, !connection.isOn() { return .native(connection, macOS: false) }
      // Notes is refused only on macOS's own denial, which nothing here can read without asking.
      if refusal == connection.noAccess, connection == .notes || NativeConnections.access(connection) != .allowed {
        return .native(connection, macOS: true)
      }
    }
    if ConnectedApps.toolNames.contains(tool) {
      if refusal == ConnectedApps.offMessage, !ComposioApps.available { return .connectedApps }
      if let app = ConnectedApps.appSlug(arguments["app"] as? String), refusal == ConnectedApps.noAccountMessage(app) {
        return .app(app)
      }
    }
    // A server's tool called while the server is off (turned off, or held when its tools changed).
    let host = PluginHost.shared
    if tool.contains("__"),
      let package = host.packages.first(where: { candidate in
        guard let manifest = candidate.manifest else { return false }
        return manifest.tools?.contains { manifest.qualified($0.name) == tool } == true
      }),
      host.isConnection(package), !host.isEnabled(package)
    {
      return .server(id: package.id, name: package.name)
    }
    return nil
  }

  @MainActor var name: String {
    switch self {
    case .aiApp(let provider), .aiKey(let provider, _, _): return provider.name
    case .connection(let connection), .automation(let connection): return connection.label
    case .messagesReading, .fullDisk: return "Messages"
    case .native(let connection, _): return connection.label
    case .connectedApps: return "Connected apps"
    case .app(let slug): return ConnectedApps.name(slug)
    case .server(_, let name): return name
    }
  }
  @MainActor var title: String {
    switch self {
    case .messagesReading: return "Serein needs to read Messages for this"
    case .fullDisk: return "Serein needs Full Disk Access to read Messages"
    case .automation(let connection): return "Serein needs to control \(connection.app) for this"
    default: return "Serein needs \(name) for this"
    }
  }
  /// Where the button goes, in plain words.
  @MainActor var detail: String {
    switch self {
    case .aiApp(let provider):
      return provider.driver == nil
        ? "Turn it on in Settings › AI apps." : "Serein opens \(provider.name)'s own sign-in. It never sees your password."
    case .fullDisk: return "Drag Serein into Full Disk Access in System Settings."
    case .automation(let connection):
      return "macOS is not letting Serein control \(connection.app). Turn on \(connection.app) under Serein in Privacy & Security › Automation."
    case .native(let connection, true): return "macOS has not given Serein access to \(connection.label)."
    case .app: return "Connect an account in Settings › Connections."
    case .server: return "Its tools changed or it was turned off. Review it in Settings › Connections."
    default: return "Turn it on in Settings › Connections."
    }
  }
  @MainActor var button: String {
    switch self {
    case .aiApp(let provider):
      return HarnessParse.signInTitle(provider.name, action: HarnessPrimaryAction.of(HarnessRegistry.shared.snapshot(provider)))
    case .messagesReading: return "Turn on Reading"
    case .fullDisk, .automation: return "Open System Settings"
    case .native(let connection, true): return "Allow \(connection.label)"
    case .app: return "Connect \(name)"
    case .server: return "Review \(name)"
    default: return "Turn on \(name)"
    }
  }
  @MainActor var done: String {
    switch self {
    case .messagesReading: return "Reading Messages is on"
    case .fullDisk: return "Serein can read Messages"
    case .automation(let connection): return "macOS lets Serein control \(connection.app)"
    case .connectedApps: return "Connected apps are on"
    case .app: return "\(name) is connected"
    default: return "\(name) is on"
    }
  }
  var icon: String {
    switch self {
    case .aiApp, .aiKey: return "terminal"
    case .connection(.mail), .automation(.mail): return "envelope"
    case .connection, .automation, .messagesReading, .fullDisk: return "bubble.left.and.bubble.right"
    case .native(.calendar, _): return "calendar"
    case .native(.reminders, _): return "checklist"
    case .native(.contacts, _): return "person.crop.circle"
    case .native(.notes, _): return "note.text"
    case .connectedApps, .app, .server: return "square.grid.2x2"
    }
  }

  /// Turn on: the Settings page where the person turns it on (with that page's own privacy line
  /// and card), or the macOS prompt or System Settings pane the connection already uses. Never a
  /// tab, and nothing else is turned on here. An AI app starts its own Connect job instead (the
  /// install, sign-in or update in Serein's terminal sheet, SereinConnect).
  @MainActor func open() {
    switch self {
    case .aiApp(let provider):
      // Any harness: its own Connect job (install, sign-in or update). A local model has none.
      if let driver = provider.driver { SereinConnect.shared.start(driver) } else { TeamSheets.openSettings(("Agents", "Settings › AI apps")) }
    case .fullDisk: MacAccess.openSettings(.fullDisk)
    case .automation: MacAccess.openSettings(.automation)
    case .native(let connection, true):
      // macOS asks once; after that only its System Settings pane changes the answer.
      if connection != .notes, NativeConnections.access(connection) == .notAsked {
        Task { _ = await NativeConnections.request(connection) }
      } else {
        NativeConnections.openSettings(connection)
      }
    default: TeamSheets.openSettings(TeamSheets.settingsPage(.connectedApps))
    }
  }

  /// Whether it is there now. The macOS answers can block for a moment, so they are read off the
  /// main thread, as the Settings rows read them.
  @MainActor func ready(agent: AgentModel) async -> Bool {
    switch self {
    case .aiApp(let provider): return agent.canThink(provider)
    case .aiKey: return false
    case .connection(let connection): return Connections.isOn(connection)
    case .messagesReading: return Connections.readsMessages()
    case .fullDisk:
      let path = MessagesStore.path(home: FileManager.default.homeDirectoryForCurrentUser)
      return await Task.detached { FullDiskAccessNotice.canOpen(URL(fileURLWithPath: path)) }.value
    case .automation(let connection):
      let bundleID = connection.bundleID
      // macOS cannot say while the app is closed (nil); only a known denial keeps the card.
      let state = await Task.detached { MacAccess.automationState(bundleID: bundleID) }.value
      return state != .denied
    case .native(let connection, let macOS):
      guard connection.isOn() else { return false }
      guard macOS else { return true }
      if connection == .notes { return await Task.detached { NativeConnections.notesAccess() }.value != .denied }
      return NativeConnections.access(connection) == .allowed
    case .connectedApps: return ComposioApps.available
    case .app(let slug):
      return ComposioApps.available && ComposioApps.shared.accounts.contains { $0.app == slug && $0.active }
    case .server(let id, _):
      return PluginHost.shared.packages.first { $0.id == id }.map { PluginHost.shared.isEnabled($0) } ?? false
    }
  }
}

/// One card under Serein's reply per connection the person's message needed: “Serein needs Mail
/// for this” with Turn on Mail (`ConnectNeed.open`). It follows the connection while on screen;
/// once it is there it reads “Mail is on” with Continue, which sends the same message again once
/// as a new message of the person's (`RelayOrchestrator.continueAfterConnect`): a new turn, so
/// every step asks again and nothing from the earlier turn is resumed.
@MainActor struct ConnectNeedCard: View {
  let need: ConnectNeed
  /// The person's message the card holds.
  let words: String
  @ObservedObject var relay: RelayOrchestrator
  @State private var ready = false
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        InterfaceIcon(systemName: ready ? "checkmark" : need.icon, size: 13)
          .foregroundStyle(ready ? p.success : p.secondary).padding(.top, 2).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(ready ? need.done : need.title).font(UIStyle.bodyStrong).fixedSize(horizontal: false, vertical: true)
          Text(ready ? "Continue sends “\(String(words.prefix(80)))” again. Every step still asks you." : need.detail)
            .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        if ready {
          Button("Continue") { relay.continueAfterConnect() }.buttonStyle(PrimaryButton()).fixedSize()
            .help("Send your message again, as a new message")
        } else {
          Button(need.button) { need.open() }.buttonStyle(PrimaryButton()).fixedSize()
            .help(need.detail)
        }
      }
    }.padding(12)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .overlay(RoundedRectangle(cornerRadius: UIStyle.panelRadius).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(ready ? need.done : need.title)
      .task { await watch() }
  }
  /// Follows the connection while the card is on screen, as the Settings rows follow macOS.
  private func watch() async {
    while !Task.isCancelled {
      ready = await need.ready(agent: relay.agent)
      try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
  }
}
