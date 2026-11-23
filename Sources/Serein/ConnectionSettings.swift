import AppKit
import SereinCore
import SwiftUI

/// Settings › Connections, three lists: the apps on this Mac (Mail and Messages here, Calendar,
/// Reminders, Contacts and Notes in NativeConnectionsRows), each with its own icon; online apps
/// through Composio (ComposioConnectionsRows), each with its logo; and apps connected by their MCP
/// server's address (MCPConnectionsRows). A row shows what Serein may do and what macOS allows,
/// its switch turns it on (after the privacy line) or off, and its chevron opens its settings.
/// Reading Messages is its own switch, with the conversations and days it covers.
struct ConnectionSettings: View {
  /// Only the apps on this Mac, for the Marketplace (its On this Mac page and searches).
  var macOnly = false
  @GateStorage(Connections.key(.mail)) private var mail = false
  @GateStorage(Connections.key(.messages)) private var messages = false
  @GateStorage(Connections.messagesReadKey) private var readMessages = false
  @GateStorage(MacFiles.wholeMacKey) private var readsWholeMac = true
  @GateStorage(LocalExecution.key) private var execution = LocalExecution.newInstallDefault.rawValue
  @GateStorage(Connections.daysKey) private var days = 7
  @GateStorage(Connections.scheduledKey(.mail)) private var mailScheduled = false
  @GateStorage(Connections.scheduledKey(.messages)) private var messagesScheduled = false
  @State private var chosen = Set(Connections.chosenChats())
  /// What macOS says about Automation for each app; missing while it cannot say (the app is closed).
  @State private var automation: [Connection: AutomationState] = [:]
  @State private var fullDisk = false
  @State private var chats: [MessagesStore.Chat] = []
  /// Bumped when the privacy alert is cancelled, so the switch the person flipped redraws as off.
  @State private var declined = 0
  @Environment(\.palette) var p

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        if !macOnly { SettingsCaption("On this Mac", info: ConnectionStatusWords.onThisMacInfo) }
        VStack(spacing: 0) {
          row(.mail, on: mail, divider: false)
          row(.messages, on: messages)
          // Calendar, Reminders, Contacts and Notes (NativeConnection).
          NativeConnectionsRows()
        }.frame(maxWidth: .infinity, alignment: .leading).card(p)
      }
      wholeMac
      if !macOnly {
        // Apps that connect in one click, with no key (OneClickConnect.swift).
        OneClickConnectorRows()
        // Apps connected through Composio (ComposioApps).
        ComposioConnectionsRows()
        // Apps connected by their MCP server's address (MCPConnectionsSettings.swift).
        MCPConnectionsRows()
      }
    }
    .task(id: "\(mail)|\(messages)|\(readMessages)") { await refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await refresh() }
    }
  }

  /// "On", "Off" or "Blocked by macOS". What the app may do is behind the chevron.
  private func status(_ connection: Connection, on: Bool) -> String {
    var blocked = false
    if case .denied = automation[connection] { blocked = true }
    return ConnectionStatusWords.words(isOn: on, blockedByMacOS: blocked)
  }
  private func tint(_ connection: Connection, on: Bool) -> Color? {
    guard on else { return nil }
    if case .denied = automation[connection] { return p.warning }
    return p.success
  }

  private func row(_ connection: Connection, on: Bool, divider: Bool = true) -> some View {
    SettingsListRow(
      name: connection.label, status: status(connection, on: on), statusTint: tint(connection, on: on),
      divider: divider, expandable: on
    ) {
      MacAppIcon(bundleID: connection.bundleID, fallback: connection == .mail ? "envelope" : "bubble.left")
    } trailing: {
      // On asks first (the privacy line); off applies at once.
      SettingsRowSwitch(label: "Use \(connection.label)", isOn: Binding(
        get: { on }, set: { wanted in if wanted { turnOn(connection) } else { turn(connection, false) } }))
    } live: {
      EmptyView()
    } details: {
      Text(connection.allowed).role(.meta).fixedSize(horizontal: false, vertical: true)
      permission(connection)
      Toggle("Scheduled tasks may use this", isOn: connection == .mail ? $mailScheduled : $messagesScheduled)
        .accessibilityLabel("Scheduled tasks may use \(connection.label)")
      SettingsNote(connection == .mail
        ? "Off by default. When on, schedules and alerts may search and read Mail, and save at most one draft per thread in a run. They never send, move or delete. Webhooks never use Mail."
        : "Off by default. When on, schedules and alerts may read the conversations you chose below. They never send. Webhooks never use Messages.")
      if connection == .messages { reading }
    }
    .id("\(connection.rawValue)-\(declined)")
  }

  /// The Automation line for the app, with the way to fix a denial.
  @ViewBuilder private func permission(_ connection: Connection) -> some View {
    let app = connection.app
    switch automation[connection] {
    case .allowed:
      Text("macOS lets Serein control \(app).").role(.meta).foregroundStyle(p.success)
    case .denied:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        InterfaceIcon(systemName: "exclamationmark.triangle", size: 12).foregroundStyle(p.warning)
        Text("macOS is not letting Serein control \(app). Turn on \(app) under Serein in Privacy & Security › Automation.")
          .role(.meta).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Open System Settings") { MacAccess.openSettings(.automation) }.buttonStyle(QuietButton())
      }.accessibilityElement(children: .combine)
    case .undetermined:
      Text("macOS asks whether Serein may control \(app) the first time Serein uses it.").role(.meta)
    case nil:
      Text("macOS says whether Serein may control \(app) only while \(app) is open.").role(.meta)
    }
  }

  /// "Let Serein read my whole Mac" (`MacFiles`): Serein's own read-only file tools.
  @ViewBuilder private var wholeMac: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsCaption("Your files")
      VStack(alignment: .leading, spacing: 10) {
        Toggle("Let Serein read my whole Mac", isOn: Binding(
          get: { readsWholeMac },
          set: { on in
            guard on else { readsWholeMac = false; return }
            if confirm(MacFiles.consentTitle, MacFiles.consent, button: "Allow Reading") {
              readsWholeMac = true
            }
          }))
        SettingsNote("Read-only. What Serein reads goes to your AI app. Full Disk Access stops macOS asking about Desktop, Documents and Downloads.")
        if readsWholeMac {
          Button("Open Full Disk Access") { MacAccess.openSettings(.fullDisk) }.buttonStyle(QuietButton())
        }
        Divider().padding(.vertical, 2)
        runCommands
      }.padding(14).frame(maxWidth: .infinity, alignment: .leading).card(p)
    }
  }

  /// Execution on this computer (LocalExecution): Never, Ask every time or Always (the default).
  @ViewBuilder private var runCommands: some View {
    SettingsPopUp("Run commands on this Mac", selection: Binding(
      get: { LocalExecution.Mode(rawValue: execution) ?? LocalExecution.newInstallDefault },
      set: { mode in
        guard mode == .always else { execution = mode.rawValue; return }
        if confirm("Let Serein run commands without asking?",
          "Serein runs shell commands on this Mac as you, without a card. Commands that delete, take root, change the system or run downloads still ask every time, and keychains, cookies, browser data, Mail, Messages, keys and Serein's own files stay closed. Scheduled runs may run commands too.",
          button: "Always Allow") {
          execution = mode.rawValue
        }
      }), choices: LocalExecution.Mode.allCases.map { SettingsChoice(value: $0, label: $0.label) })
    SettingsNote("Deleting, sudo and system changes always ask. Keychains, cookies, browser data, Mail and Messages stay closed.")
  }

  /// "Let Serein read Messages": off by default, Full Disk Access, the days and the chats.
  @ViewBuilder private var reading: some View {
    Toggle("Let Serein read Messages", isOn: Binding(
      get: { readMessages },
      set: { on in
        guard on else { readMessages = false; return }
        if confirm("Let Serein read Messages?", "Serein reads only the conversations you choose here, only the last days you pick, and never attachments. It needs Full Disk Access, which also lets Serein and the AI apps it starts open your other private files. " + Connections.privacyLine, button: "Allow Reading") {
          readMessages = true
        }
      }))
    SettingsNote("Reading needs Full Disk Access, which also lets Serein and the AI apps it starts open your other private files. Remove Serein from Full Disk Access when you turn reading off. Sending does not need it.")
    if readMessages {
      if !fullDisk {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          InterfaceIcon(systemName: "exclamationmark.triangle", size: 12).foregroundStyle(p.warning)
          Text("Serein can't open your Messages yet. Drag Serein into Full Disk Access, then come back here. Nothing is read until then.")
            .role(.meta).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button("Open System Settings") { MacAccess.openSettings(.fullDisk) }.buttonStyle(QuietButton())
        }.accessibilityElement(children: .combine)
      } else {
        HStack {
          Text("Read the last")
          Spacer()
          SettingsPopUp("Days of Messages Serein may read", selection: $days,
            choices: Connections.dayChoices.map { SettingsChoice(value: $0, label: "\($0) day\($0 == 1 ? "" : "s")") }, showsTitle: false)
        }
        Text("Conversations Serein may read").font(UIStyle.body)
        if chats.isEmpty {
          Text("No conversations found in Messages.").role(.meta)
        }
        ForEach(chats) { chat in
          Toggle(chat.name, isOn: Binding(
            get: { chosen.contains(chat.id) },
            set: { on in
              if on { chosen.insert(chat.id) } else { chosen.remove(chat.id) }
              GateSettings.shared.set(Array(chosen).sorted(), forKey: Connections.chatsKey)
            }))
        }
      }
    }
  }

  private func turnOn(_ connection: Connection) {
    guard confirm("Turn on \(connection.label)?", Connections.privacyLine, button: "Turn On") else {
      declined += 1
      return
    }
    turn(connection, true)
  }
  /// Off takes effect on the next call: every tool checks the switch, and a waiting card checks it again.
  private func turn(_ connection: Connection, _ on: Bool) {
    switch connection {
    case .mail: mail = on
    case .messages:
      messages = on
      if !on { readMessages = false }
    }
  }
  private func confirm(_ title: String, _ detail: String, button: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// macOS's answers and the chats, read off the main thread (each can block for a moment).
  @MainActor private func refresh() async {
    let path = MessagesStore.path(home: FileManager.default.homeDirectoryForCurrentUser)
    let reads = messages && readMessages
    let picked = Array(chosen)
    let found = await Task.detached { () -> ([Connection: AutomationState], Bool, [MessagesStore.Chat]) in
      var states: [Connection: AutomationState] = [:]
      for connection in Connection.allCases {
        states[connection] = MacAccess.automationState(bundleID: connection.bundleID)
      }
      let disk = FullDiskAccessNotice.canOpen(URL(fileURLWithPath: path))
      guard disk, reads else { return (states, disk, []) }
      var list = MessagesStore.chats(at: path) ?? []
      // A chosen chat older than the recent ones stays listed, so it can be turned off.
      let missing = picked.filter { id in !list.contains { $0.id == id } }
      for (id, name) in (MessagesStore.names(at: path, chats: missing) ?? [:]).sorted(by: { $0.value < $1.value }) {
        list.append(MessagesStore.Chat(id: id, name: name))
      }
      return (states, disk, list)
    }.value
    automation = found.0
    fullDisk = found.1
    chats = found.2
  }
}
