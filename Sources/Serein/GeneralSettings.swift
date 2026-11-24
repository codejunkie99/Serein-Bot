import AppKit
import SereinCore
import SwiftUI

/// Settings › General (docs/demos/simple-settings.decision.md): how Serein looks (the theme and the
/// text size, from the old Appearance page), Startup and sleep, Search and Updates in view; then
/// Advanced, which folds Darken pages, Serein's look, Keyboard shortcuts, Downloads and Tips and
/// setup. Serein's look and Keyboard shortcuts open as sub-pages. Each card keeps its old key as its
/// id, so a request for one scrolls to it (`SettingsInline`) after its fold opens (`SettingsFolds`).
struct GeneralSettings: View {
  @ObservedObject var browser: BrowserModel
  @Environment(\.settingsNavigation) private var nav
  var body: some View {
    switch nav.key(0) {
    case GeneralKey.keyboard?:
      VStack(alignment: .leading, spacing: 24) {
        SettingsPageHeader("Keyboard shortcuts", sentence: "The keys for each menu command.")
        KeyboardSettings()
      }
    case GeneralKey.look?: SereinLookPage()
    default: page
    }
  }
  private var page: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsRowList("Appearance") { AppearanceRows() }.id(GeneralKey.appearance)
      SettingsBlock("Startup and sleep") { StartupSettings() }.id(GeneralKey.startup)
      GeneralSearchSettings().id(GeneralKey.search)
      UpdatesSettings().id(GeneralKey.updates)
      SettingsAdvanced(page: "General", count: 6) {
        SettingsRowList {
          DarkenPagesRow()
          SettingsSummaryRow(title: "Serein's look", answer: "The hologram, and the look Serein wears", open: { nav.push(GeneralKey.look) }) {
            SettingsGlyphTile(systemName: "sparkles")
          }
          SettingsSummaryRow(title: "Keyboard shortcuts", answer: "The keys for each menu command", open: { nav.push(GeneralKey.keyboard) }) {
            SettingsGlyphTile(systemName: "keyboard")
          }
        }
        SettingsBlock("Downloads") {
          DownloadsView()
          SettingsNote("A file you save from a page asks where it goes. A task's files wait until you keep them, and tasks download only if you allow it in Settings › Assistants › Advanced.")
        }.id(GeneralKey.downloads)
        GeneralTipsSettings(browser: browser).id(GeneralKey.tips)
      }
    }
  }
  static func title(_ key: String) -> String { GeneralKey.pages[key] ?? GeneralKey.titles[key] ?? "General" }
}

/// The parts of General: its cards (sections a request scrolls to) and its two sub-pages.
enum GeneralKey {
  static let appearance = "appearance"
  static let startup = "startup"
  static let search = "search"
  static let downloads = "downloads"
  static let updates = "updates"
  static let tips = "tips"
  static let keyboard = "keyboard"
  static let look = "look"
  /// The cards, by key: a request for one scrolls to it.
  static let titles: [String: String] = [
    appearance: "Appearance", startup: "Startup and sleep", search: "Search", downloads: "Downloads", updates: "Updates",
    tips: "Tips and setup",
  ]
  /// The sub-pages, which open in the page's place: the old Keyboard page and Appearance's Serein's look.
  static let pages: [String: String] = [keyboard: "Keyboard shortcuts", look: "Serein's look"]
}

/// General › Search: the engine `BrowserPolicy.address` uses and agents can change (`search_engine`).
private struct GeneralSearchSettings: View {
  @AppStorage("serein.searchEngine") private var searchEngine = "DuckDuckGo"
  var body: some View {
    SettingsRowList("Search") {
      SettingsChoiceRow(
        title: "Search engine", answer: "Opens when Serein sends a search to your browser", selection: $searchEngine,
        choices: ["DuckDuckGo", "Google", "Bing"].map { SettingsChoice(value: $0, label: $0) }
      ) {
        SettingsGlyphTile(systemName: "magnifyingglass")
      }
    }
  }
}

/// General › Tips and setup: Show tips, and setup again in Serein's chat (SereinChatSetup): the
/// AI app and model there, then Serein helps with the rest. Setup happens in the conversation, so
/// there is no separate getting-started guide to show again.
private struct GeneralTipsSettings: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject private var hints = HintCenter.shared
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsBlock("Tips and setup") {
        Toggle("Show tips", isOn: $hints.enabled)
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Set up with Serein")
            Text("Choose your AI app and model in the chat, then ask Serein to help with the rest.")
              .role(.meta)
          }
          Spacer()
          Button("Run setup again") {
            browser.showSettings = false
            dismiss()
            DispatchQueue.main.async {
              guard let relay = RelayOrchestrator.shared else { return }
              SereinRouter.home()
              SereinRouter.bringWindowForward?()
              SereinChatSetup.shared.restart(relay)
            }
          }
        }
      }
    }
  }
}

