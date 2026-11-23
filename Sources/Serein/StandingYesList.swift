import SereinCore
import SwiftUI

/// Every standing yes in one list (`StandingYes`), under the choices of “Serein asks before”:
/// in Settings › Assistants › Asks first, and in the popover every approval card opens, so the
/// person reaches it from the chat too. Each row has Ask again. Nothing shows while there is none.
struct StandingYesList: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var gates = GateWatch.shared
  @ObservedObject private var plugins = PluginHost.shared
  @Environment(\.palette) private var p

  private var rows: [StandingYes.Row] {
    let projects: [(id: String, name: String)] = ProjectEditApprovals.all().map { id in
      (id: id, name: relay.browser.projects.first { $0.id == id }?.name ?? "Removed project")
    }
    let reads: [(id: String, name: String)] = plugins.packages
      .filter { plugins.states[$0.id]?.reads == true }.map { (id: $0.id, name: $0.name) }
    return StandingYes.rows(
      sites: RoutineGrants.sites(), rules: SiteRules.all(), projects: projects, reads: reads,
      commands: LocalExecution.mode())
  }

  var body: some View {
    let rows: [StandingYes.Row] = rows
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Goes ahead without asking").role(.meta).accessibilityAddTraits(.isHeader)
        ForEach(rows) { row in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title).font(UIStyle.body).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
              if row.asksFirst { Text("This site is set to ask first, so it asks.").role(.meta) }
            }
            Spacer(minLength: 8)
            Button("Ask again") { askAgain(row) }.buttonStyle(QuietButton())
              .accessibilityLabel("Ask again for \(row.title)")
          }
        }
      }
    }
  }

  private func askAgain(_ row: StandingYes.Row) {
    // A connection's reads live with the connection; the rest are in the gate file.
    if !StandingYes.askAgain(row), let package = plugins.packages.first(where: { $0.id == row.key }) {
      plugins.setReads(package, false)
    }
  }
}
