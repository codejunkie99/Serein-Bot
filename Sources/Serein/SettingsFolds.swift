import SereinCore
import SwiftUI

/// Which pages' Advanced folds are open, for this run of Serein: every fold starts closed, so a page
/// opens on its everyday rows (docs/demos/simple-settings.decision.md). A request for a section that
/// sits inside a fold opens it first (`ReferenceSettings.go`). `--ui-settings-advanced`,
/// `--ui-settings-scroll` and `--ui-outside-agents` open every fold in a preview.
@MainActor final class SettingsFolds: ObservableObject {
  static let shared = SettingsFolds()
  @Published private(set) var open: Set<String> = []
  private let all: Bool = {
    let arguments = CommandLine.arguments
    return ["--ui-settings-advanced", "--ui-settings-scroll", "--ui-outside-agents"].contains { arguments.contains($0) }
  }()
  func isOpen(_ page: String) -> Bool { all || open.contains(page) }
  func set(_ page: String, open on: Bool) {
    if on { open.insert(page) } else { open.remove(page) }
  }
  /// The section keys that sit inside each page's fold, by page id: a request for one opens the fold.
  static let folded: [String: Set<String>] = [
    "General": [GeneralKey.downloads, GeneralKey.tips],
    "Relay": [RelaySettingsKey.links, RelaySettingsKey.downloads, RelaySettingsKey.reminders, RelaySettingsKey.recipes],
    "Agents": [AIAppsKey.newChats, AIAppsKey.helpers, AIAppsKey.outside, "Advanced", "MCP connection"],
    "Privacy": [
      PrivacyKey.routineSites, PrivacyKey.signIns, PrivacyKey.pageTools, PrivacyKey.chats, PrivacyKey.permissions,
      PrivacyKey.blocking,
    ],
    "Passwords": [PasswordsKey.bring],
  ]
  /// Opens `page`'s fold when `section` sits inside it.
  func reveal(_ section: String, on page: String) {
    if Self.folded[page]?.contains(section) == true { set(page, open: true) }
  }
}

/// "Advanced · N" under a page's everyday rows: what the page rarely needs, folded until opened.
/// `count` is how many settings it holds, so the fold says what is inside before it opens. The
/// content appears at once; only the chevron turns.
struct SettingsAdvanced<Content: View>: View {
  /// The page's id (`SettingsCategory.id`): its fold's state lives in `SettingsFolds`.
  let page: String
  let count: Int
  var title = "Advanced"
  @ViewBuilder var content: () -> Content
  @ObservedObject private var folds = SettingsFolds.shared
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let open: Bool = folds.isOpen(page)
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    VStack(alignment: .leading, spacing: 24) {
      Button { folds.set(page, open: !open) } label: {
        HStack(spacing: 6) {
          InterfaceIcon(systemName: "chevron.right", size: 10).foregroundStyle(p.faint)
            .rotationEffect(.degrees(open ? 90 : 0))
            .animation(reduce ? nil : Motion.swap, value: open)
            .frame(width: 14)
          Text(verbatim: "\(title) · \(count)").font(UIStyle.body).foregroundStyle(p.secondary)
        }
        .padding(.vertical, 4).padding(.trailing, 8).contentShape(Rectangle())
      }
      .buttonStyle(.pressable)
      .accessibilityLabel("\(title), \(count) more settings")
      .accessibilityValue(open ? "Shown" : "Hidden")
      .accessibilityHint(open ? "Hides these settings" : "Shows these settings")
      if open { content() }
    }.id("Advanced")
  }
}

/// One line under a page saying where what left it went ("Keyboard shortcuts are under Help").
struct SettingsMovedNote: View {
  let text: String
  init(_ text: String) { self.text = text }
  @Environment(\.palette) private var p
  var body: some View {
    Text(verbatim: text).font(AssistantType.meta).foregroundStyle(p.faint)
      .fixedSize(horizontal: false, vertical: true).padding(.leading, 2)
  }
}
