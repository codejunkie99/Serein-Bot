import SereinCore
import SwiftUI

/// Where an assistant's computer runs, picked on its own page (the side panel's gear) under its AI
/// app and model, the same way: the place's logo and name, and a list of every place with whether
/// it is ready. A place
/// that still needs a key, Docker or a machine opens its row in Settings › Serein's computer. A
/// move deletes the computer where it is now (`ComputerHost.setPlace`), so it asks first.
struct ComputerPlacePicker: View {
  @ObservedObject var computer: ComputerHost.Computer
  let name: String
  /// The settings row (title, answer, chevron) instead of the stand-alone pill.
  var asRow = false
  @ObservedObject private var host = ComputerHost.shared
  @State private var open = false
  @State private var hovered = false
  @State private var moving: ComputerPlace?
  @Environment(\.palette) var p

  private var placeName: String {
    computer.place.isOwn ? host.placeName(computer) : ComputerPlaceLogo.shortName(computer.place)
  }

  var body: some View {
    trigger
    .popover(isPresented: $open, arrowEdge: asRow ? .trailing : .bottom) {
      ComputerPlaceList(current: computer.place, currentName: host.placeName(computer)) { place in
        open = false
        if place != computer.place { moving = place }
      }
      .environment(\.palette, p)
    }
    // Nothing moves across: the computer where it is now is deleted first.
    .confirmationDialog(
      "Move \(name)'s computer to \(moving?.label ?? "another place")?",
      isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }), titleVisibility: .visible
    ) {
      Button("Move Computer", role: .destructive) {
        if let place = moving { Task { await host.setPlace(place, for: computer) } }
        moving = nil
      }
    } message: {
      if computer.place == .unavailable {
        Text(ComputerPlace.unavailableMove)
      } else {
        Text(verbatim: "Its computer on \(host.placeName(computer)) is deleted first, and with it \(host.lossList(computer)). The new one starts empty. \(name) keeps its chats, memory and routines.")
      }
    }
  }

  @ViewBuilder private var trigger: some View {
    if asRow {
      SettingsSummaryRow(title: "Runs on", answer: placeName, hint: "Shows the places its computer can run",
        open: { open = true }) {
        ComputerPlaceLogo(place: computer.place, size: 18)
          .frame(width: 30, height: 30)
          .background(p.track, in: RoundedRectangle(cornerRadius: 7))
      }
    } else {
      pill
    }
  }

  private var pill: some View {
    Button { open = true } label: {
      HStack(spacing: 10) {
        ComputerPlaceLogo(place: computer.place, size: 20)
        VStack(alignment: .leading, spacing: 1) {
          Text("Runs on").font(UIStyle.micro).foregroundStyle(p.secondary)
          Text(verbatim: placeName).font(UIStyle.metaStrong).foregroundStyle(p.ink)
            .lineLimit(1).truncationMode(.tail)
        }
        Spacer(minLength: 4)
        InterfaceIcon(systemName: "chevron.up.chevron.down", size: 11).foregroundStyle(p.secondary)
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(hovered ? p.selected : p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      .contentShape(RoundedRectangle(cornerRadius: UIStyle.controlRadius))
    }
    .buttonStyle(.pressable)
    .onHover { hovered = $0 }
    .help("Choose where \(name)'s computer runs")
    .accessibilityLabel("\(name)'s computer runs on \(host.placeName(computer))")
    .accessibilityHint("Shows the places it can run")
  }
}

/// The places, one row each: logo, name, a status line, and a check on the current one.
private struct ComputerPlaceList: View {
  let current: ComputerPlace
  let currentName: String
  var pick: (ComputerPlace) -> Void
  @ObservedObject private var e2b = E2BAccount.shared
  @ObservedObject private var daytona = DaytonaAccount.shared
  @Environment(\.palette) var p

  private struct Choice: Identifiable {
    let place: ComputerPlace
    let name: String
    let status: String
    let ready: Bool
    var id: String { place.rawValue }
  }

  private var choices: [Choice] {
    let docker: Bool = DockerSocket.installed()
    let vm: Bool = VirtualMachineComputer.supported
    var rows: [Choice] = [
      Choice(place: .builtIn, name: ComputerPlaceLogo.shortName(.builtIn), status: vm ? "This Mac · free" : "Not on this Mac", ready: vm),
      Choice(place: .docker, name: "Docker", status: docker ? "This Mac · free" : "Install Docker", ready: docker),
      Choice(place: .e2b, name: "E2B", status: e2b.hasKey ? "Your account · paid" : "Add key", ready: e2b.hasKey),
      Choice(place: .daytona, name: "Daytona", status: daytona.hasKey ? "Your account · paid" : "Add key",
             ready: daytona.hasKey),
    ]
    // The person's own machine is reached through Connect in Settings, never picked here.
    rows.append(current.isOwn
      ? Choice(place: current, name: currentName, status: "SSH", ready: true)
      : Choice(place: .ownMachine, name: "Your own machine", status: "Connect in Settings", ready: false))
    return rows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Runs on").font(UIStyle.micro).foregroundStyle(p.secondary)
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
      ForEach(choices) { choice in
        PlaceRow(place: choice.place, name: choice.name, status: choice.status, ready: choice.ready,
                 chosen: choice.place == current) {
          if choice.ready {
            pick(choice.place)
          } else {
            pick(current)
            TeamSheets.openSettings(TeamSheets.settingsPage(.computer))
          }
        }
      }
    }
    .padding(6)
    .frame(width: 300)
  }
}

private struct PlaceRow: View {
  let place: ComputerPlace
  let name: String
  let status: String
  let ready: Bool
  let chosen: Bool
  var action: () -> Void
  @State private var hovered = false
  @Environment(\.palette) var p
  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        ComputerPlaceLogo(place: place, size: 22).opacity(ready ? 1 : 0.55)
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: name).font(UIStyle.metaStrong).foregroundStyle(p.ink).lineLimit(1)
          Text(verbatim: status).font(UIStyle.micro).foregroundStyle(ready ? p.secondary : p.warning).lineLimit(1)
        }
        Spacer(minLength: 4)
        if chosen {
          InterfaceIcon(systemName: "checkmark", size: 12).foregroundStyle(p.accent)
        } else if !ready {
          InterfaceIcon(systemName: "arrow.up.forward", size: 11).foregroundStyle(p.secondary)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(hovered ? p.selected : .clear, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      .contentShape(RoundedRectangle(cornerRadius: UIStyle.controlRadius))
    }
    .buttonStyle(.pressable)
    .onHover { hovered = $0 }
    .accessibilityLabel(name)
    .accessibilityValue(chosen ? "Chosen, \(status)" : status)
    .accessibilityHint(ready ? "Moves the computer here" : "Opens Settings to set it up")
  }
}

/// A place's mark: the provider's logo, Serein's for the built-in computer, a terminal for SSH.
struct ComputerPlaceLogo: View {
  static func shortName(_ place: ComputerPlace) -> String {
    switch place {
    case .builtIn: return "Built-in"
    case .macOS: return "Virtual Mac"
    case .docker: return "Docker"
    case .e2b: return "E2B"
    case .daytona: return "Daytona"
    case .ownDesktop, .ownMachine: return "Your machine"
    case .unavailable: return place.label
    }
  }
  let place: ComputerPlace
  var size: CGFloat = 18
  @Environment(\.palette) var p
  var body: some View {
    switch place {
    case .docker: BrandLogo(.docker, size: size)
    case .e2b: BrandLogo(.e2b, size: size)
    case .daytona: BrandLogo(.daytona, size: size)
    case .builtIn: InterfaceIcon(systemName: "serein.mark", size: size).foregroundStyle(p.accent).frame(width: size, height: size)
    case .macOS:
      InterfaceIcon(systemName: "desktopcomputer", size: size * 0.8).foregroundStyle(p.secondary).frame(width: size, height: size)
    case .ownDesktop, .ownMachine:
      InterfaceIcon(systemName: "terminal", size: size * 0.7).foregroundStyle(p.secondary).frame(width: size, height: size)
    case .unavailable: InterfaceIcon(systemName: "exclamationmark.triangle", size: size * 0.8).foregroundStyle(p.accent).frame(width: size, height: size)
    }
  }
}
