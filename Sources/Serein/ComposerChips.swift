import SereinCore
import SwiftUI

/// “Serein asks before” in the composer's words (the owner's, 2026-11-18), in the order its chip
/// lists them. The value is the one Settings and the menu set (`RelayOrchestrator.level`).
extension ApprovalLevel {
  static let composerChoices: [ApprovalLevel] = [.proactive, .riskyOnly, .everyStep]
  var composerTitle: String {
    switch self {
    case .proactive: return "Allow all"
    case .riskyOnly: return "Auto"
    case .everyStep: return "Manual"
    }
  }
  var composerHint: String {
    switch self {
    case .proactive: return "Everything runs. Payments and passwords go to the secure card."
    case .riskyOnly: return "Asks only before risky steps."
    case .everyStep: return "Asks before each step."
    }
  }
  /// The confirmation that guards switching to Allow all, as Only risky steps has its own.
  static let allowAllConfirmTitle = "Let Serein go ahead with every step?"
  static func allowAllConfirmBody(killLabel: String) -> String {
    "Serein and the tasks it starts go ahead without asking. Payments and passwords go to a secure card you fill, and it never touches password managers or Serein itself. \(killLabel) stops everything."
  }
}

/// What Serein asks before, beside the model in its message bar. A pick goes through
/// `RelayController.setLevel`, so a freer level still shows its confirmation first.
struct ComposerPermissionChip: View {
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  var quiet = false
  var body: some View {
    let level = relay.level
    ComposerChip(quiet: quiet,
      label: "Permission mode", value: level.composerTitle, help: "What Serein asks before: " + level.composerHint,
      choices: ApprovalLevel.composerChoices, selected: level, title: { $0.composerTitle }, hint: { $0.composerHint }
    ) { controller.setLevel($0) }
  }
}

/// The active assistant's effort, beside its model: only the levels that model's app lists, and
/// no chip when it lists none.
struct ComposerEffortChip: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var registry = HarnessRegistry.shared
  /// Under the bar the effort reads quieter than the model and the mode around it.
  var quiet = false
  @MainActor static func levels(_ relay: RelayOrchestrator) -> [String] {
    let engine = relay.assistantEngine(relay.team.active)
    return EffortLadder.levels(engine.provider, engine.model)
  }
  var body: some View {
    let levels = Self.levels(relay)
    if !levels.isEmpty {
      let id = relay.team.activeID
      let effort = relay.assistantEngine(relay.team.active).effort
      ComposerChip(quiet: quiet, dim: quiet,
        label: "Effort", value: EffortLadder.label(effort), help: "How hard \(relay.team.activeName) thinks",
        choices: levels, selected: effort, title: { EffortLadder.label($0) }, hint: { _ in nil }
      ) { relay.setEffort($0, for: id) }
    }
  }
}

/// A chip in Serein's message bar drawn as the model pill beside it is (`ModelPill`): its value and
/// a chevron, opening a short list with the current choice checked.
private struct ComposerChip<Choice: Hashable>: View {
  /// Words alone under Serein's message bar: no chevron, a 24-point press area.
  var quiet = false
  /// In `secondary`, not `ink`.
  var dim = false
  let label: String
  let value: String
  let help: String
  let choices: [Choice]
  let selected: Choice
  let title: (Choice) -> String
  let hint: (Choice) -> String?
  let choose: (Choice) -> Void
  @State private var open = false
  @Environment(\.palette) private var p
  var body: some View {
    Button { open.toggle() } label: {
      HStack(spacing: 4) {
        Text(value).font(UIStyle.meta).foregroundStyle(dim ? p.secondary : p.ink).lineLimit(1)
        if !quiet { InterfaceIcon(systemName: "chevron.down", size: 9).foregroundStyle(p.faint) }
      }.padding(.horizontal, quiet ? 4 : 7).frame(height: quiet ? 24 : UIStyle.wide(18)).contentShape(Rectangle())
    }.buttonStyle(AssistantPressStyle()).fixedSize()
      .help(help).accessibilityLabel(label).accessibilityValue(value)
      .popover(isPresented: $open, arrowEdge: .bottom) { list.environment(\.palette, p) }
  }
  private var list: some View {
    let dark = p.isDark
    return VStack(alignment: .leading, spacing: 2) {
      ForEach(choices, id: \.self) { choice in
        let on = choice == selected
        let words = hint(choice)
        Button {
          open = false
          // After the popover closes: a freer level's confirmation is a modal alert.
          DispatchQueue.main.async { choose(choice) }
        } label: {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(title(choice)).font(UIStyle.font(13)).foregroundStyle(KeelPicker.text(dark))
              if let words {
                Text(words).font(UIStyle.font(11)).foregroundStyle(KeelPicker.muted(dark))
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            Spacer(minLength: 8)
            InterfaceIcon(systemName: "checkmark", size: 11).foregroundStyle(KeelPicker.text(dark)).opacity(on ? 1 : 0)
          }.padding(.horizontal, 10).padding(.vertical, 6)
            .background(on ? KeelPicker.wash(dark, 0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.pressable)
          .accessibilityLabel(title(choice)).accessibilityHint(words ?? "")
          .accessibilityAddTraits(on ? .isSelected : [])
      }
    }.padding(6).frame(width: UIStyle.wide(hint(selected) == nil ? 160 : 260)).background(KeelPicker.surface(dark))
  }
}
