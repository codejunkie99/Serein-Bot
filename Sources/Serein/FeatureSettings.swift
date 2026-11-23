import SereinCore
import SwiftUI

/// One switch per background feature that sends data to the user's agent provider.
struct FeatureSettings: View {
  @Environment(\.palette) private var p
  @State private var enabled: [AgentFeature: Bool] = [:]

  /// What each feature sends, and roughly how often. Shown under its switch.
  static func detail(_ feature: AgentFeature) -> String {
    switch feature {
    case .routing:
      return "Sends your request, the last three messages, the active page address and your listed projects (name, folder, notes, branch, recent commits and session titles) to pick where it goes. Once per task; light use."
    case .timeline: return "Sends the day's page addresses, titles and excerpts after a pause. Moderate use."
    case .proofreading:
      return "Sends a short dictated phrase when the recognizer is unsure, or your whole draft when you choose Proofread dictated text. Light use."
    case .recall: return "Sends your description and matching history excerpts when you search. Light use."
    case .outcome: return "Sends a finished task's last message to write a one-line result. Light use."
    case .projectGrouping:
      return "Sends the names and short README or manifest excerpts of your listed projects. Only when you ask in the Projects map, or for new projects when you turn that on there. Light use."
    }
  }
  var body: some View {
    SettingsGroup("What runs in the background") {
      HStack(spacing: 6) {
        Text("Text helpers use your selected Claude Code, Codex or OpenCode model. Other harnesses use an available Claude Code or Codex helper. Journal file search requires Claude Code or Codex.").role(.meta)
        InfoPopoverButton(
          text: "Private pages and pages with password or card fields are never sent. Each switch takes effect right away.",
          label: "What is never sent")
      }
      ForEach(AgentFeature.allCases, id: \.self) { feature in
        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            feature.title,
            isOn: Binding(
              get: { enabled[feature] ?? FeaturePolicy.isEnabled(feature) },
              set: {
                enabled[feature] = $0
                FeaturePolicy.set(feature, $0)
              }))
          Text(Self.detail(feature)).role(.meta).fixedSize(horizontal: false, vertical: true)
        }
      }
    }.onAppear {
      enabled = Dictionary(
        uniqueKeysWithValues: AgentFeature.allCases.map { ($0, FeaturePolicy.isEnabled($0)) })
    }
  }
}
