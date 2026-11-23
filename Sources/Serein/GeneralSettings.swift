import AppKit
import SereinCore
import SwiftUI

/// Settings › General on one page (docs/demos/settings-one-page.decision.md): Startup and sleep,
/// Search, Downloads, Updates, and Tips and setup, each a section with its controls in view. The
/// keys are the old sub-pages'; a request for one scrolls to its section (`SettingsInline`).
struct GeneralSettings: View {
  @ObservedObject var browser: BrowserModel
  var body: some View {
    VStack(alignment: .leading, spacing: 32) {
      ForEach(GeneralKey.order, id: \.self) { key in
        SettingsSection(key, title: GeneralKey.titles[key] ?? key) { section(key) }
      }
    }
  }
  @ViewBuilder private func section(_ key: String) -> some View {
    switch key {
    case GeneralKey.startup:
      SettingsPageHeader("Startup and sleep", sentence: "Choose when Serein opens, and whether the Mac stays awake for its work.")
      SettingsBlock("Startup and sleep") { StartupSettings() }
    case GeneralKey.search: GeneralSearchSettings()
    case GeneralKey.downloads:
      SettingsPageHeader("Downloads", sentence: "Files you keep from a task, and files you save from a page.")
      SettingsBlock("Downloads") {
        DownloadsView()
        SettingsNote("A file you save from a page asks where it goes. A task's files wait until you keep them, and tasks download only if you allow it in Settings › Assistants › Task downloads.")
      }
    case GeneralKey.updates:
      SettingsPageHeader("Updates", sentence: "Which version of Serein you have, and how it updates.")
      UpdatesSettings()
    default: GeneralTipsSettings(browser: browser)
    }
  }
  static func title(_ key: String) -> String { GeneralKey.titles[key] ?? "General" }
}

/// The sub-pages of General.
enum GeneralKey {
  static let startup = "startup"
  static let search = "search"
  static let downloads = "downloads"
  static let updates = "updates"
  static let tips = "tips"
  /// The sections in page order.
  static let order = [startup, search, downloads, updates, tips]
  static let titles: [String: String] = [
    startup: "Startup and sleep", search: "Search", downloads: "Downloads", updates: "Updates", tips: "Tips and setup",
  ]
}

/// General › Search: the engine `BrowserPolicy.address` uses and agents can change (`search_engine`).
private struct GeneralSearchSettings: View {
  @AppStorage("serein.searchEngine") private var searchEngine = "DuckDuckGo"
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("Search", sentence: "Which search site opens when Serein sends a search to your browser.")
      SettingsBlock("Search") {
        HStack {
          Text("Search engine")
          Spacer()
          SettingsPopUp("Search engine", selection: $searchEngine,
            choices: ["DuckDuckGo", "Google", "Bing"].map { SettingsChoice(value: $0, label: $0) }, showsTitle: false)
        }
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
      SettingsPageHeader("Tips and setup", sentence: "Short tips while you work, and setup with Serein in its chat.")
      SettingsBlock("Guidance") {
        Toggle("Show tips", isOn: $hints.enabled)
      }
      SettingsBlock("Setup") {
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

