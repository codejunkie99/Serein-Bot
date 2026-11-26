import SereinCore
import SwiftUI

/// What the Appearance page held, now parts of Settings › General
/// (docs/demos/simple-settings.decision.md): the theme and the text size as General's first rows
/// (`AppearanceRows`), Darken pages a task shows you under Advanced (`DarkenPagesRow`), and Serein's
/// look as a sub-page (`SereinLookPage`). The keys are the ones the old groups used
/// (`serein.darkPages`).
struct AppearanceRows: View {
  var body: some View {
    SettingsListRow(name: "Theme", status: "System follows your Mac", expandable: false) {
      SettingsGlyphTile(systemName: "circle.lefthalf.filled")
    } trailing: {
      AppearancePicker()
    } live: {
      EmptyView()
    } details: {
      EmptyView()
    }
    SettingsListRow(name: "Text size", status: "Everything in Serein", expandable: false) {
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

/// General › Advanced: darken the light pages a task shows while Serein is dark.
struct DarkenPagesRow: View {
  @AppStorage("serein.darkPages") private var darkPages = true
  var body: some View {
    SettingsSwitchRow(
      title: "Darken pages a task shows you", answer: "Only while Serein is dark",
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

/// General › Serein's look, a sub-page: the hologram in every state, the look Serein wears, and who
/// may change it.
struct SereinLookPage: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Serein's look", sentence: "The hologram in every state, the look Serein wears, and who may change it.")
      if let controller = RelayController.shared {
        RelayLookSettings(relay: controller.relay, controller: controller)
      } else {
        SereinUnavailable().frame(height: 120)
      }
    }
  }
}

/// The key Serein's look had as a section of the old Appearance page; it is General's sub-page now
/// (`GeneralKey.look` is the same word, so "Appearance/look" still opens it).
enum AppearanceKey {
  static let look = "look"
}
