import SereinCore
import SwiftUI

/// Settings › Appearance on one page: Appearance, Text size, Darken pages a task shows you, then
/// Serein's look as a section (moved here from Settings › Serein). The keys are the ones the old groups used
/// (`serein.darkPages`).
struct AppearanceSettings: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 32) {
      AppearancePage()
      SettingsSection(AppearanceKey.look, title: "Serein's look") {
        SettingsPageHeader("Serein's look", sentence: "The hologram in every state, the look Serein wears, and who may change it.")
        if let controller = RelayController.shared {
          RelayLookSettings(relay: controller.relay, controller: controller)
        } else {
          SereinUnavailable().frame(height: 120)
        }
      }
    }
  }
  static func title(_ key: String) -> String { AppearanceKey.titles[key] ?? "Appearance" }
}

/// The sub-pages of Appearance.
enum AppearanceKey {
  static let look = "look"
  static let titles: [String: String] = [look: "Serein's look"]
}

private struct AppearancePage: View {
  @AppStorage("serein.darkPages") private var darkPages = true
  var body: some View {
    SettingsRowList {
      SettingsListRow(name: "Appearance", status: "System follows your Mac's own setting", expandable: false) {
        SettingsGlyphTile(systemName: "circle.lefthalf.filled")
      } trailing: {
        AppearancePicker()
      } live: {
        EmptyView()
      } details: {
        EmptyView()
      }
      textSize
      SettingsSwitchRow(
        title: "Darken pages a task shows you", answer: "Only while Serein is dark.",
        isOn: Binding(get: { darkPages }, set: { on in
          darkPages = on
          NotificationCenter.default.post(name: Notification.Name("SereinDarkPagesChanged"), object: nil)
        }),
        info: "While Serein is dark, adapts light page backgrounds. While it is light, pages keep their own colors. Turn this off for color-sensitive work."
      ) {
        SettingsGlyphTile(systemName: "moon")
      }
    }
  }
  private var textSize: some View {
    SettingsListRow(
      name: "Text size", status: "Everything in Serein.",
      expandable: false
    ) {
      SettingsGlyphTile(systemName: "textformat.size")
    } trailing: {
      TextSizeSlider()
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
  }
}
