import AppKit
import SereinCore
import SwiftUI

/// Settings › Privacy in three sections: what Serein sees (the page you're viewing, cookie and
/// consent banners, sites it treats differently, sites where routine steps go ahead, sites it
/// stays signed in to, tools that sites offer),
/// what it keeps (history, task recordings, chats from Claude Code and Codex, Clear saved data…),
/// and web pages (site permissions, ads and trackers). The two switches that say what Serein sees
/// keep their whole notes in view. The keys are the old groups' keys.
struct PrivacySettings: View {
  @ObservedObject var browser: BrowserModel
  /// Clear saved data…: ReferenceSettings shows its sheet (the counts come before anything goes).
  @Binding var confirmClear: Bool
  @Environment(\.palette) private var p
  /// One page: what Serein sees, what it keeps, then web pages; every former sub-page is a section
  /// under its part (`SettingsInline`).
  var body: some View {
    // Everyday first (docs/demos/simple-settings.decision.md): what Serein sees, what macOS lets it
    // do, what you allowed for good, the sites it treats differently, history and what it keeps.
    // The rest folds under Advanced; every list that takes an approval back stays one click away.
    VStack(alignment: .leading, spacing: 32) {
      PrivacyPage(browser: browser, confirmClear: $confirmClear, part: .sees)
      ForEach([PrivacyKey.mac, PrivacyKey.allowed, PrivacyKey.sites, PrivacyKey.history], id: \.self, content: section)
      PrivacyPage(browser: browser, confirmClear: $confirmClear, part: .keeps)
      SettingsAdvanced(page: "Privacy", count: 7) {
        PrivacyPage(browser: browser, confirmClear: $confirmClear, part: .banners)
        ForEach(
          [PrivacyKey.routineSites, PrivacyKey.signIns, PrivacyKey.pageTools, PrivacyKey.chats, PrivacyKey.permissions, PrivacyKey.blocking],
          id: \.self, content: section)
      }
    }
  }
  private func section(_ key: String) -> some View {
    SettingsSection(key, title: PrivacyKey.titles[key] ?? key) { sub(key) }
  }
  @ViewBuilder private func sub(_ key: String) -> some View {
    switch key {
    case PrivacyKey.history: PrivacyHistorySettings(browser: browser)
    // From Privacy › Mac permissions: what macOS lets Serein do belongs with what Serein may do.
    case PrivacyKey.mac: MacPermissionsSettings()
    // From Assistants: every standing yes with its Ask again, and every site rule with its Remove.
    case PrivacyKey.allowed:
      if let controller = RelayController.shared {
        RelayAsksSettings(relay: controller.relay, controller: controller)
      } else {
        SereinUnavailable().frame(height: 80)
      }
    case PrivacyKey.sites:
      PrivacySubpage(title: "Sites Serein treats differently", sentence: "Sites Serein never opens, or asks about first.") {
        SettingsBlock("Sites Serein treats differently") { SiteRuleSettings() }
      }
    case PrivacyKey.routineSites:
      PrivacySubpage(title: "Routine steps go ahead on", sentence: "Sites where a task's clicks, typing and moves between pages go ahead without a card.") {
        SettingsBlock("Routine steps go ahead on") { RoutineSiteSettings() }
      }
    case PrivacyKey.signIns:
      PrivacySubpage(title: "Sites Serein stays signed in to", sentence: "Where your sign-ins stay for Serein's own work.") {
        SettingsBlock("Sites Serein stays signed in to") { KeptSignInSettings(browser: browser) }
      }
    case PrivacyKey.pageTools:
      PrivacySubpage(title: "Tools that sites offer", sentence: "Let agents use the tools a site offers, only on the sites you list.") {
        SettingsBlock("Page tools") { PageToolSettings() }
      }
    case PrivacyKey.chats:
      PrivacySubpage(title: "Chats on this Mac", sentence: "Chats from Claude Code and Codex, read on this Mac only.") {
        SettingsBlock("Chats on this Mac") { SessionDiscoverySettings() }
      }
    case PrivacyKey.permissions:
      PrivacySubpage(title: "Site permissions", sentence: "What each site may use: the camera, the microphone, your location and more.") {
        SettingsBlock("Permissions") {
          SitePermissionSettings(browser: browser)
          Divider().overlay(p.line)
          SiteListSettings()
        }
      }
    case PrivacyKey.blocking:
      PrivacySubpage(title: "Ads and trackers", sentence: "Block ads and trackers on pages in Serein.") {
        SettingsBlock("Ads and trackers") { BlockingSettings() }
      }
    default: EmptyView()
    }
  }
  static func title(_ key: String) -> String { PrivacyKey.titles[key] ?? "Privacy" }
}

/// The sub-pages of Privacy.
enum PrivacyKey {
  static let history = "history"
  static let sites = "sites"
  static let routineSites = "routine-sites"
  static let signIns = "sign-ins"
  static let pageTools = "page-tools"
  static let chats = "chats"
  static let permissions = "permissions"
  static let blocking = "blocking"
  static let mac = "mac"
  static let allowed = "allowed"
  static let titles: [String: String] = [
    mac: "Mac permissions", allowed: "Allowed without asking",
    history: "History", sites: "Sites Serein treats differently", routineSites: "Routine steps go ahead on",
    signIns: "Sites Serein stays signed in to",
    pageTools: "Tools that sites offer", chats: "Chats on this Mac", permissions: "Site permissions", blocking: "Ads and trackers",
  ]
}

/// A Privacy sub-page: its title and sentence over its content.
private struct PrivacySubpage<Content: View>: View {
  let title: String
  let sentence: String
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader(title, sentence: sentence)
      content()
    }
  }
}

private struct PrivacyPage: View {
  enum Part { case sees, keeps, banners }
  @ObservedObject var browser: BrowserModel
  @Binding var confirmClear: Bool
  let part: Part
  /// Privacy › Let Serein see the page you are viewing (the page chip).
  @GateStorage(SereinPageChip.shareKey, unreadable: false) private var sharePage = true
  /// Privacy › Most private choice by default (cookie and consent overlays on task pages).
  @GateStorage(BrowserModel.mostPrivateKey) private var mostPrivate = true
  @AppStorage(TaskRecordings.keepKey) private var taskRecordingDays = 0
  @ObservedObject private var gates = GateWatch.shared
  private static let recordingChoices: [SettingsChoice<Int>] = [
    SettingsChoice(value: 0, label: "Until quit"), SettingsChoice(value: 1, label: "1 day"), SettingsChoice(value: 7, label: "7 days"),
  ]
  var body: some View {
    switch part {
    case .sees: SettingsRowList("What Serein sees") { sees }
    case .banners: SettingsRowList("On task pages") { banners }
    case .keeps:
      SettingsRowList("What Serein keeps", note: "Messages are kept on this Mac. What you send goes to your chosen AI app.") { keeps }
    }
  }
  @ViewBuilder private var sees: some View {
    SettingsSwitchRow(
      title: "The page you're viewing",
      answer: "Serein sees the page’s title and site, never a private page’s. It reads the page only when your question needs it, and it acts on the page only after you say yes.",
      isOn: Binding(get: { sharePage }, set: { on in
        sharePage = on
        SereinPageChip.shared.refresh()
      }),
      label: "Let Serein see the page you are viewing"
    ) {
      SettingsGlyphTile(systemName: "macwindow")
    }
  }
  /// Under Advanced: the choice Serein makes on a cookie or consent banner.
  @ViewBuilder private var banners: some View {
    SettingsSwitchRow(
      title: "Cookie and consent banners",
      answer: "Serein picks the option that shares the least, such as Reject all, and the task shows what it chose. It never accepts all cookies without asking you.",
      isOn: $mostPrivate, label: "Most private choice by default",
      info: "When a cookie, consent or survey banner covers a page a task works on, Serein picks the option that shares the least, such as Reject all, and the task shows what it chose. It never accepts all cookies without asking you."
    ) {
      SettingsGlyphTile(systemName: "hand.raised")
    }
  }
  @ViewBuilder private var keeps: some View {
    SettingsChoiceRow(
      title: "Task recordings", answer: "They stay on this Mac and are never shown to the AI.",
      selection: $taskRecordingDays, choices: Self.recordingChoices,
      info: "Record this task is in a task’s Options. Recordings stay on this Mac and are never shown to the AI. Unsaved ones are deleted after this time, or when Serein quits for Until quit; Save… keeps a copy where you choose. The pictures of Serein's computer in a task's steps are kept for the same time."
    ) {
      SettingsGlyphTile(systemName: "record.circle")
    }
    SettingsSummaryRow(
      title: "Clear saved data…", answer: "History, downloads, cookies, passages, chats and more. Counts show before anything goes.",
      danger: true, hint: "Opens the choice of what to clear", open: { confirmClear = true }
    ) {
      SettingsGlyphTile(systemName: "trash")
    }
  }
}

/// Privacy › History: save history, organize it (sends excerpts to your AI app), kept passages,
/// the local library, how long it is kept, and the sites never saved. Private pages and the pages
/// tasks work on never appear in it.
private struct PrivacyHistorySettings: View {
  @ObservedObject var browser: BrowserModel
  @GateStorage(FeaturePolicy.key(.timeline), unreadable: false) private var autoTimeline = false
  @AppStorage("serein.retentionDays") private var retentionDays = 0
  @GateStorage(BrowserTab.excludedSitesKey) private var excludedSites = ""
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsPageHeader("History", sentence: "What Serein keeps of the pages you open here, and for how long.")
      SettingsBlock("History") {
        Toggle("Save history", isOn: $browser.historyEnabled)
        Toggle("Organize history automatically", isOn: $autoTimeline)
        KeptSettingsRow()
        SettingsNote("When on, saved page excerpts go to your AI app after a pause. Uses its allowance.")
        SettingsNote("Your visits, page titles, and up to 8,000 characters of page text stay in your local library. Private pages and the pages tasks work on never appear in your history.")
      }
      SettingsBlock("Local library") {
        HStack {
          Text("Storage")
          Spacer()
          Button("Show in Finder") { NSWorkspace.shared.open(browser.library.root) }
        }
        SettingsPopUp("Keep history", selection: $retentionDays, choices: [
          SettingsChoice(value: 0, label: "Forever"), SettingsChoice(value: 30, label: "30 days"),
          SettingsChoice(value: 90, label: "90 days"), SettingsChoice(value: 365, label: "1 year"),
        ])
        Button("Delete older history now") { browser.applyRetention() }
        TextField("Do not save these sites (comma separated)", text: $excludedSites)
          .textFieldStyle(.plain).textInputCursor().padding(8)
          .background(p.track, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      }
    }
  }
}
