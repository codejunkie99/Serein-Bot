import AppKit
import SereinCore
import SwiftUI

/// Connects a one-click app that signs in with a token the person makes
/// (`ConnectorCatalog.SignIn.key`, GitHub and Slack): where to make it, the steps there, and one
/// secure field. Serein checks the token's shape first, then `OneClickConnect.connect(_:key:)`
/// keeps it in the Keychain and sends it only to the app's own server. The token never enters a
/// chat, a prompt or a log, and the field is emptied once it is sent.
struct KeyConnectSheet: View {
  let connector: ConnectorCatalog.Connector
  @ObservedObject private var model = OneClickConnect.shared
  @ObservedObject private var host = PluginHost.shared
  @Environment(\.palette) private var p
  @Environment(\.dismiss) private var dismiss
  @State private var token = ""
  @State private var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        AppLogoTile(id: connector.id, name: connector.name, size: 34)
        Text("Connect \(connector.name)").font(UIStyle.bodyStrong).foregroundStyle(p.ink).accessibilityAddTraits(.isHeader)
      }
      if let key = connector.signIn.key {
        Text(
          "\(connector.name) connects with a \(key.name) you make. Serein keeps it in your Keychain on this Mac and sends it only to \(serverHost)."
        ).role(.meta).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(key.steps.enumerated()), id: \.offset) { index, step in
            Text("\(index + 1). \(step)").font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
          }
        }
        if let page = URL(string: key.page), page.scheme == "https", let pageHost = page.host {
          Button("Open \(pageHost)") { NSWorkspace.shared.open(page) }.buttonStyle(QuietButton())
            .help(key.page)
        }
        SecureField(key.placeholder, text: $token).textFieldStyle(.serein).onSubmit { submit(key) }
          .accessibilityLabel("\(connector.name) \(key.name)")
          .disabled(working)
        status
        HStack {
          Spacer()
          Button("Cancel") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
          Button("Connect") { submit(key) }.buttonStyle(PrimaryButton())
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
        }
      }
    }
    .padding(20).frame(width: 480)
    .background(p.background)
    .onChange(of: model.isConnected(connector)) { _, connected in
      if connected { dismiss() }
    }
    .onDisappear { token = "" }
  }

  @ViewBuilder private var status: some View {
    if let problem {
      Text(problem).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
    } else {
      switch model.steps[connector.id] {
      case .working(let words)?:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(words).font(UIStyle.meta).foregroundStyle(p.secondary)
        }
      case .failed(let why)?:
        Text(why).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
      default:
        EmptyView()
      }
    }
  }

  private var working: Bool {
    if case .working = model.steps[connector.id] { return true }
    return false
  }
  private var serverHost: String { URL(string: connector.url)?.host ?? connector.url }

  private func submit(_ key: ConnectorCatalog.KeySignIn) {
    problem = key.problem(token)
    guard problem == nil, !working else { return }
    model.connect(connector, key: token)
    token = ""
  }
}
