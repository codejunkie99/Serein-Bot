import SereinCore
import SwiftUI

/// One row per connection on this Mac (Calendar, Reminders, Contacts, Notes), in the "On this Mac"
/// card: the app's own icon, whether it is on and what macOS allows, and its switch. Turning one
/// on shows the privacy line first, then macOS asks. The chevron opens what Serein may do and the
/// scheduled-tasks switch. Rows follow macOS while on screen.
@MainActor struct NativeConnectionsRows: View {
  @State private var on: Set<NativeConnection> = Set(NativeConnection.allCases.filter { $0.isOn() })
  @State private var scheduled: Set<NativeConnection> = Set(NativeConnection.allCases.filter { $0.scheduledOn() })
  @State private var states: [NativeConnection: NativeConnections.Access] = [:]
  @State private var confirming: NativeConnection?
  /// Connections this build could not ask macOS about (no usage text in its Info.plist).
  @State private var cannotAsk: Set<NativeConnection> = []
  @Environment(\.palette) var p

  var body: some View {
    VStack(spacing: 0) {
      ForEach(NativeConnection.allCases, id: \.self) { connection in
        row(connection)
      }
    }
    .task {
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }
    }
    .confirmationDialog(
      "Turn on \(confirming?.label ?? "")?",
      isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      titleVisibility: .visible
    ) {
      Button("Turn On") {
        if let connection = confirming { Task { await turnOn(connection) } }
        confirming = nil
      }
    } message: {
      Text(NativeConnection.privacyLine)
    }
  }

  private func row(_ connection: NativeConnection) -> some View {
    let isOn = on.contains(connection)
    let state = states[connection] ?? .notAsked
    var tint: Color?
    if isOn && state == .denied { tint = p.warning }
    if isOn && state == .allowed { tint = p.success }
    return SettingsListRow(
      name: connection.label, status: status(isOn: isOn, state: state, connection), statusTint: tint, expandable: isOn
    ) {
      MacAppIcon(bundleID: bundleID(connection), fallback: icon(connection))
    } trailing: {
      // On shows what Serein reads, then macOS asks; off applies at once.
      SettingsRowSwitch(label: "Use \(connection.label)", isOn: Binding(
        get: { isOn }, set: { wanted in if wanted { confirming = connection } else { turnOff(connection) } }))
        .help(isOn ? "Serein stops using \(connection.label) now" : "Shows what Serein reads, then macOS asks you")
    } live: {
      if cannotAsk.contains(connection) {
        Text("This build can't ask macOS. Use the packaged app (scripts/build.sh).")
          .font(UIStyle.micro).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 42)
      }
      // The fix for a denial shows without opening the row.
      if isOn && state == .denied {
        HStack {
          Text("macOS is not letting Serein use \(connection.label).").role(.meta)
          Spacer()
          Button("Open System Settings") { NativeConnections.openSettings(connection) }.buttonStyle(QuietButton())
            .help("The exact pane in System Settings")
            .accessibilityLabel("Open System Settings for \(connection.label)")
        }.padding(.leading, 42)
      }
    } details: {
      Text(connection.may).role(.meta).fixedSize(horizontal: false, vertical: true)
      Toggle("Scheduled tasks may use this", isOn: Binding(
        get: { scheduled.contains(connection) },
        set: { allowed in
          connection.setScheduled(allowed)
          if allowed { scheduled.insert(connection) } else { scheduled.remove(connection) }
        }))
        .accessibilityLabel("Scheduled tasks may use \(connection.label)")
      SettingsNote("Off by default. When on, schedules and alerts may only read \(connection.label), and each read still asks you. Webhooks never use it.")
    }
  }

  /// The Mac app whose icon the row shows.
  private func bundleID(_ connection: NativeConnection) -> String {
    switch connection {
    case .calendar: return "com.apple.iCal"
    case .reminders: return "com.apple.reminders"
    case .contacts: return "com.apple.AddressBook"
    case .notes: return "com.apple.Notes"
    }
  }
  private func icon(_ connection: NativeConnection) -> String {
    switch connection {
    case .calendar: return "calendar"
    case .reminders: return "checklist"
    case .contacts: return "person.crop.circle"
    case .notes: return "note.text"
    }
  }
  private func status(isOn: Bool, state: NativeConnections.Access, _ connection: NativeConnection) -> String {
    ConnectionStatusWords.words(isOn: isOn, blockedByMacOS: state == .denied)
  }

  private func turnOn(_ connection: NativeConnection) async {
    // A build without the usage text cannot ask macOS: the switch stays off and the row says why.
    guard NativeConnections.describedInBundle(connection) else {
      cannotAsk.insert(connection)
      return
    }
    cannotAsk.remove(connection)
    connection.setOn(true)
    on.insert(connection)
    states[connection] = await NativeConnections.request(connection)
  }
  private func turnOff(_ connection: NativeConnection) {
    connection.setOn(false)
    on.remove(connection)
  }
  /// What macOS allows now; Notes is read off the main thread.
  private func refresh() async {
    for connection in NativeConnection.allCases where connection != .notes {
      states[connection] = NativeConnections.access(connection)
    }
    states[.notes] = await Task.detached(priority: .utility) { NativeConnections.notesAccess() }.value
  }
}
