import SereinCore
import SwiftUI

/// Settings' sub-pages (board 15): a page can push a sub-page into the same column. `path` holds
/// the keys after the page's id: "Relay/<assistant id>/routines" is the page Relay with the path
/// [<assistant id>, "routines"]. ReferenceSettings owns the path, draws the back link above the
/// sub-page and makes Esc go back one level; a page reads where it is and pushes through this.
struct SettingsNavigation {
  var path: [String] = []
  var push: (String) -> Void = { _ in }
  var pop: () -> Void = {}
  /// Opens another sub-page of the same page by its whole path ([] is the page itself).
  var go: ([String]) -> Void = { _ in }
  /// The key at `depth`, or nil: in [id, "routines"], key(0) is the id and key(1) "routines".
  func key(_ depth: Int) -> String? { path.indices.contains(depth) ? path[depth] : nil }
}
private struct SettingsNavigationKey: EnvironmentKey { static let defaultValue = SettingsNavigation() }
extension EnvironmentValues {
  var settingsNavigation: SettingsNavigation {
    get { self[SettingsNavigationKey.self] }
    set { self[SettingsNavigationKey.self] = newValue }
  }
}

/// A Settings page's title (`UIStyle.title`, 20 semibold, as every page title) over its one
/// sentence (13, secondary) that says what to do there, with an optional control at the trailing
/// edge. Inside a `SettingsSection` (what used to be a sub-page) the section draws the heading,
/// so this draws only its sentence.
struct SettingsPageHeader<Trailing: View>: View {
  let title: String
  var sentence: String
  @ViewBuilder var trailing: () -> Trailing
  @Environment(\.palette) private var p
  init(_ title: String, sentence: String = "", @ViewBuilder trailing: @escaping () -> Trailing) {
    self.title = title
    self.sentence = sentence
    self.trailing = trailing
  }
  @Environment(\.settingsSectionTitle) private var section
  var body: some View {
    if section != nil {
      if !sentence.isEmpty {
        Text(verbatim: sentence).font(AssistantType.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true).padding(.top, -6).padding(.leading, 2)
      }
    } else {
      page
    }
  }
  private var page: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: title).font(UIStyle.title).foregroundStyle(p.ink).lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        if !sentence.isEmpty {
          Text(verbatim: sentence).font(AssistantType.body).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      trailing()
    }
  }
}
extension SettingsPageHeader where Trailing == EmptyView {
  init(_ title: String, sentence: String = "") {
    self.init(title, sentence: sentence) { EmptyView() }
  }
}

/// "‹ Assistants" above a sub-page (12, secondary, the look of the task header's "‹ Serein").
/// VoiceOver reads "Back to Assistants". Esc does the same (ReferenceSettings gives it the key).
struct SettingsBackLink: View {
  let title: String
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p
  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        InterfaceIcon(systemName: "chevron.left", size: 11)
        Text(verbatim: title).font(AssistantType.meta).lineLimit(1)
      }
      .foregroundStyle(hovered ? p.ink : p.secondary)
      .frame(height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.pressable)
    .onHover { hovered = $0 }
    .help("Back to \(title) · Esc")
    .accessibilityLabel("Back to \(title)")
  }
}

/// The titles the back link reads: the title of the sub-page `key` on page `category`, for the
/// sub-page one level under it. Each page with sub-pages names its own.
@MainActor enum SettingsTitles {
  static func title(_ key: String, in category: String) -> String {
    switch category {
    case "General": return GeneralSettings.title(key)
    case "Relay": return RelaySettings.title(key)
    case "Agents": return AIAppsSettings.title(key)
    case "Passwords": return key == PasswordsKey.bring ? "Bring from your browser" : "Vault"
    case "Privacy": return PrivacySettings.title(key)
    default: return key
    }
  }
}

/// One page, sections (docs/demos/settings-one-page.decision.md): what used to open as a sub-page
/// sits on its page as a section, under a heading in 15 regular `ink` (size, not weight, sets it
/// apart). Its `key` is the old sub-page's key, so a request for that sub-page scrolls here. A
/// caption inside that only repeats the heading is left out (`settingsSectionTitle`).
struct SettingsSection<Content: View>: View {
  let key: String
  let title: String
  @ViewBuilder var content: () -> Content
  @Environment(\.palette) private var p
  init(_ key: String, title: String, @ViewBuilder content: @escaping () -> Content) {
    self.key = key
    self.title = title
    self.content = content
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: title).font(UIStyle.font(15)).foregroundStyle(p.ink).padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: 16, content: content)
        .environment(\.settingsSectionTitle, title)
    }.id(key)
  }
}
private struct SettingsSectionTitleKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
  /// The heading of the `SettingsSection` this view sits in, if any.
  var settingsSectionTitle: String? {
    get { self[SettingsSectionTitleKey.self] }
    set { self[SettingsSectionTitleKey.self] = newValue }
  }
}
extension View {
  /// Whether a caption only repeats the section heading it sits under.
  func repeatsSection(_ caption: String, _ section: String?) -> Bool {
    guard let section else { return false }
    return caption.caseInsensitiveCompare(section) == .orderedSame
  }
}

/// Which sub-page keys are sections of their page now, and what a request for one opens: the page
/// (or the list item's page) scrolled to that section. A list item's own page (an assistant, an AI
/// app) is still a page of its own.
@MainActor enum SettingsInline {
  static func isSection(_ key: String, page: String, under parent: [String]) -> Bool {
    switch (page, parent.count) {
    // General's cards scroll into view; its Keyboard shortcuts and Serein's look are sub-pages.
    case ("General", 0): return GeneralKey.titles[key] != nil
    case ("Passwords", 0): return key == PasswordsKey.bring
    case ("Privacy", 0): return PrivacyKey.titles[key] != nil
    case ("Relay", 0): return RelaySettingsKey.titles[key] != nil
    case ("Relay", 1): return RelaySettingsKey.titles[parent[0]] == nil && AssistantSettingsKey.all.contains(key)
    case ("Agents", 0): return AIAppsKey.titles[key] != nil
    default: return false
    }
  }
  /// `path` up to its first section key, and that key: ["history"] on Privacy is the page itself,
  /// scrolled to History; ["abc", "apps"] on Relay is abc's page, scrolled to Apps it can use.
  static func split(_ path: [String], page: String) -> (path: [String], section: String?) {
    for (index, key) in path.enumerated() where isSection(key, page: page, under: Array(path.prefix(index))) {
      return (Array(path.prefix(index)), key)
    }
    return (path, nil)
  }
}
