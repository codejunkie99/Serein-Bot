import SereinCore
import SwiftUI

/// Online apps (Composio), one card: Composio's row (paste a key; then Refresh and Turn off in its
/// ⋯ menu), a row per connected app with its logo and Disconnect…, chips with each suggested app's
/// logo that open Composio's hosted sign-in in the default browser, what Serein may do with them,
/// the scheduled-tasks switch and the blocked tools. Off until a key answers.
struct ComposioConnectionsRows: View {
  @ObservedObject private var apps = ComposioApps.shared
  @Environment(\.palette) private var p
  @State private var key = ""
  @State private var other = ""
  @State private var status: String?
  @State private var busy = false
  @State private var changes = ComposioApps.changesAllowed
  @State private var unattended = ComposioApps.unattendedAllowed
  @State private var blocked = ComposioApps.blocked
  @State private var blockDraft = ""
  @State private var leaving: ConnectedApps.Account?

  @State private var typing = false

  /// Suggested apps not connected yet, offered as chips.
  private var offered: [(slug: String, name: String)] {
    ConnectedApps.suggested.filter { app in !apps.accounts.contains { $0.app == app.slug } }
  }

  private var connectLine: String {
    if let waiting = apps.waitingFor {
      return "Finish signing in to \(ConnectedApps.name(waiting)) in your browser. This list updates by itself."
    }
    return "Connect an app · the sign-in opens in your default browser, on Composio's page, never in an agent's tab."
  }
  private var composioStatus: String {
    guard apps.on else { return "Off · connects Gmail, Slack, Notion and more" }
    let count: Int = apps.accounts.count
    return "Key works · \(count) app" + (count == 1 ? "" : "s") + " connected"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsCaption("Online apps", info: ConnectedApps.privacyText)
      VStack(spacing: 0) {
        SettingsListRow(
          name: "Composio",
          status: composioStatus,
          statusTint: apps.on ? p.success : nil, divider: false, expandable: false
        ) {
          BrandLogo(.composio)
        } trailing: {
          if apps.on {
            Menu {
              Button("Refresh") { refresh() }.disabled(busy)
              Divider()
              Button("Turn Off and Remove the Key") { turnOff() }
                .accessibilityHint("Removes your Composio key from this Mac")
            } label: {
              InterfaceIcon(systemName: "ellipsis", size: 14).foregroundStyle(p.secondary)
                .frame(width: 28, height: 24).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
              .help("Refresh, or turn off").accessibilityLabel("Composio actions")
          }
        } live: {
          if !apps.on { setup.padding(.leading, 42) }
        } details: {
          EmptyView()
        }
        if apps.on { connected }
      }.frame(maxWidth: .infinity, alignment: .leading).settingsCard()
      if let status { Text(status).role(.meta).fixedSize(horizontal: false, vertical: true).padding(.leading, 2) }
    }
    .controlSize(.small)
    .task {
      apps.forgetFailedRead()
      guard apps.on else { return }
      do { try await apps.refresh() } catch { status = error.localizedDescription }
    }
    .confirmationDialog(
      "Disconnect \(leaving.map { ConnectedApps.name($0.app) } ?? "this app")?",
      isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }), titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) { if let leaving { disconnect(leaving) } }
      Button("Cancel", role: .cancel) { leaving = nil }
    } message: {
      Text("Composio deletes this connection and revokes its sign-in. Serein can no longer use it.")
    }
  }

  // MARK: before a key

  @ViewBuilder private var setup: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(ConnectedApps.setupText).role(.meta).fixedSize(horizontal: false, vertical: true)
      Text(ConnectedApps.privacyText).role(.meta).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        SecureField("Paste your Composio API key", text: $key)
          .textFieldStyle(.serein)
          .onSubmit(turnOn)
          .accessibilityLabel("Composio API key")
        Button("Turn On", action: turnOn).buttonStyle(PrimaryButton()).disabled(key.isEmpty || busy)
      }
      HStack(spacing: 4) {
        Text("Your key stays in this Mac's Keychain and goes only to Composio.").role(.micro)
        Link("Get a key", destination: URL(string: "https://dashboard.composio.dev")!).font(UIStyle.font(12))
      }
    }
  }

  // MARK: with a key

  @ViewBuilder private var connected: some View {
    ForEach(apps.accounts) { account in
      SettingsListRow(
        name: ConnectedApps.name(account.app) + (account.label.isEmpty ? "" : " · \(account.label)"),
        status: account.statusWords,
        expandable: false
      ) {
        BrandLogo(Brand.app(account.app), name: ConnectedApps.name(account.app))
      } trailing: {
        Button("Disconnect…") { leaving = account }
          .buttonStyle(QuietButton()).disabled(busy)
          .accessibilityLabel("Disconnect \(ConnectedApps.name(account.app))")
      } live: {
        EmptyView()
      } details: {
        EmptyView()
      }
    }
    // Connect: one chip per suggested app, with its logo; the sign-in opens in the browser.
    VStack(alignment: .leading, spacing: 10) {
      Text(connectLine).role(.meta).fixedSize(horizontal: false, vertical: true)
      // The last chip (an empty slug) is "Another app…", which opens the name field.
      FlowChips(items: offered.map(\.slug) + [""]) { slug in
        if slug.isEmpty { anotherChip } else { connectChip(slug) }
      }
      if typing {
        HStack(spacing: 8) {
          TextField("Its Composio name, such as linear", text: $other)
            .textFieldStyle(.serein).onSubmit(connectOther)
            .accessibilityLabel("Composio name of the app to connect")
          Button("Connect…", action: connectOther).buttonStyle(QuietButton())
            .disabled(busy || apps.waitingFor != nil || other.isEmpty)
        }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }

    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("What Serein may do")
        Spacer()
        Picker("What Serein may do", selection: $changes) {
          Text("Read").tag(false)
          Text("Read and change").tag(true)
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
          .onChange(of: changes) { _, on in GateSettings.shared.set(on, forKey: ComposioApps.changesKey) }
      }
      SettingsNote(changes
        ? "Searching and reading run without asking. Sending, creating, changing or deleting asks you every time, with exactly what will be sent; never on Autopilot."
        : "Serein only searches and reads. Other assistants need Connected apps in what they can use, and only read.")
      Toggle("Scheduled tasks may use these", isOn: $unattended).toggleStyle(SettingsToggleStyle())
        .onChange(of: unattended) { _, on in GateSettings.shared.set(on, forKey: ComposioApps.unattendedKey) }
      SettingsNote("Off by default. When on, schedules and watches may only read. Webhooks never use connected apps.")
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .overlay(alignment: .top) { Rectangle().fill(p.line).frame(height: 1) }

    SettingsListRow(name: "Blocked tools", status: blocked.isEmpty ? "None" : blocked.joined(separator: ", ")) {
      SettingsGlyphTile(systemName: "hand.raised")
    } trailing: {
      EmptyView()
    } live: {
      EmptyView()
    } details: {
      ForEach(blocked, id: \.self) { slug in
        HStack(spacing: 8) {
          Text(slug).font(UIStyle.monoMeta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          Button("Unblock") { saveBlocked(blocked.filter { $0 != slug }) }
            .buttonStyle(QuietButton()).accessibilityLabel("Unblock \(slug)")
        }
      }
      HStack(spacing: 8) {
        TextField("Block a tool, such as GMAIL_SEND_EMAIL", text: $blockDraft)
          .textFieldStyle(.serein).onSubmit(block)
          .accessibilityLabel("Tool to block")
        Button("Block", action: block).buttonStyle(QuietButton()).disabled(ConnectedApps.toolSlug(blockDraft) == nil)
      }
    }
  }

  /// A suggested app with its logo.
  private func connectChip(_ slug: String) -> some View {
    Button {
      connect(slug)
    } label: {
      HStack(spacing: 6) {
        BrandLogo(Brand.app(slug), size: 16, name: ConnectedApps.name(slug))
        Text(ConnectedApps.name(slug)).font(UIStyle.meta)
      }.padding(.horizontal, 10).padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.line)).contentShape(RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.pressable).disabled(busy || apps.waitingFor != nil)
      .help("Sign in to \(ConnectedApps.name(slug)) in your browser")
      .accessibilityLabel("Connect \(ConnectedApps.name(slug))")
  }
  private var anotherChip: some View {
    Button { typing.toggle() } label: {
      Text("Another app…").font(UIStyle.meta).foregroundStyle(p.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.line)).contentShape(RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.pressable).accessibilityLabel("Connect another app by its Composio name")
  }

  // MARK: actions

  private func turnOn() {
    guard !key.isEmpty, !busy else { return }
    busy = true
    status = "Checking the key…"
    Task { @MainActor in
      defer { busy = false }
      do {
        try await apps.turnOn(key: key)
        key = ""
        changes = ComposioApps.changesAllowed
        unattended = ComposioApps.unattendedAllowed
        status = "Works. Connect an app below."
      } catch {
        status = "That key did not work: \(error.localizedDescription)"
      }
    }
  }
  private func connectOther() {
    guard !other.isEmpty else { return }
    connect(other)
  }
  private func turnOff() {
    let removed = apps.turnOff()
    changes = false
    unattended = false
    status = removed
      ? "Turned off. Your key is removed from this Mac; apps you did not disconnect stay connected at Composio."
      : "Turned off, but Serein could not remove the key from the Keychain. Remove serein.composio in Keychain Access."
  }
  private func connect(_ app: String) {
    status = nil
    // Not `busy`: the sign-in can take minutes, and `waitingFor` already holds the button.
    Task { @MainActor in
      do {
        try await apps.connect(app: app)
        other = ""
      } catch { status = error.localizedDescription }
    }
  }
  private func disconnect(_ account: ConnectedApps.Account) {
    leaving = nil
    busy = true
    Task { @MainActor in
      defer { busy = false }
      do {
        try await apps.disconnect(account)
        status = "\(ConnectedApps.name(account.app)) is disconnected and its sign-in revoked."
      } catch { status = error.localizedDescription }
    }
  }
  private func refresh() {
    busy = true
    Task { @MainActor in
      defer { busy = false }
      do { try await apps.refresh(); status = nil } catch { status = error.localizedDescription }
    }
  }
  private func block() {
    guard ConnectedApps.toolSlug(blockDraft) != nil else { return }
    saveBlocked(blocked + [blockDraft])
    blockDraft = ""
  }
  private func saveBlocked(_ slugs: [String]) {
    ComposioApps.setBlocked(slugs)
    blocked = ComposioApps.blocked
  }
}
