import SereinCore
import SwiftUI

extension View {
  func sereinHintAnchor(_ id: HintID, when present: Bool) -> some View {
    anchorPreference(key: HintAnchorKey.self, value: .bounds) {
      HintAnchorKey.Value(targets: present ? [id: $0] : [:])
    }
  }
  /// Attach to the ScrollView, not its content; only these transcript tips are clipped by it.
  func sereinHintViewport(_ ids: [HintID]) -> some View {
    transformAnchorPreference(key: HintAnchorKey.self, value: .bounds) { value, anchor in
      for id in ids { value.viewports[id] = anchor }
    }
  }
}

/// Typing in a task view is observed independently of the shell's layout and per-task drafts.
@MainActor final class GuidanceTaskInput: ObservableObject {
  static let shared = GuidanceTaskInput()
  @Published private(set) var hasText = false
  private var owner: String?
  func set(_ text: String, owner: String) {
    self.owner = owner
    let value = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if hasText != value { hasText = value }
  }
  func clear(owner: String) {
    guard self.owner == owner else { return }
    self.owner = nil
    if hasText { hasText = false }
  }
}

/// The most recent answered approval provides the anchor and the ordinary approval chooser.
struct SereinApprovalHintAnchor: View {
  @State private var choosing = false
  @Environment(\.palette) private var p
  var body: some View {
    Color.clear.frame(maxWidth: .infinity).frame(height: 2)
      .sereinHintAnchor(.asksBefore)
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SereinHintChooseApprovals"))) { _ in
        if SereinSurface.main.chatShowing, RelayController.shared?.panelShown != true { choosing = true }
      }
      .popover(isPresented: $choosing) {
        if let controller = RelayController.shared {
          VStack(alignment: .leading, spacing: 12) {
            Text("Serein asks before").font(UIStyle.bodyStrong)
            AskBeforeControl(relay: controller.relay, controller: controller)
          }.padding(16).frame(width: 320).environment(\.palette, p)
        }
      }
  }
}
