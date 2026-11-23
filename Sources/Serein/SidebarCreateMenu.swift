import SereinCore
import SwiftUI

/// What the sidebar's + creates: a new Serein (another assistant, through its name card, ⌃⌘N)
/// or a team (the New team sheet). The title bar's + and the rail's + tile open these two items.
struct SidebarCreateItems: View {
  /// The tooltip and the accessibility label of either +.
  static let label = "New Serein or team"
  var body: some View {
    Button("New Serein", systemImage: "person.badge.plus") {
      NotificationCenter.default.post(name: AssistantSidebarState.newAssistant, object: nil)
    }
    Button("New team", systemImage: "person.2") { TeamSheets.shared.present(.newTeam(.home)) }
  }
}

/// The rail's + tile, under the faces: the rail has no room for the title bar's + or for the
/// list's New Serein row, so this one tile opens both items. Both open a dialog
/// (`NewSereinSheet`, `NewTeamSheet`), so the rail stays as it is.
struct RailCreateTile: View {
  var selection: Namespace.ID
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    Menu {
      SidebarCreateItems()
    } label: {
      SidebarRowLabel(SidebarCreateItems.label) {
        InterfaceIcon(systemName: "plus", size: 16).foregroundStyle(hovered ? p.ink : p.secondary)
      }
    }
    .menuStyle(.button).menuIndicator(.hidden)
    .buttonStyle(AssistantListRowStyle(selected: false, hovered: hovered, selection: selection, fitsContent: true))
    .sidebarRailCentred(true)
    .onHover { hovered = $0 }
    .help("\(SidebarCreateItems.label) · ⌃⌘N for a new Serein")
    .accessibilityLabel(SidebarCreateItems.label)
  }
}
