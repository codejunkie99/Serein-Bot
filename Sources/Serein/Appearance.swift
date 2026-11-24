import AppKit
import SereinCore
import SwiftUI

/// Settings › General: System (default), Light or Dark. The choice sets `NSApp.appearance`;
/// windows, sheets, popovers and web views inherit it, and SwiftUI views pick the matching
/// `Palette` from their effective color scheme (see `EnvironmentValues.palette`). With System,
/// a change in macOS's own appearance flows through live.
@MainActor final class AppearanceController: ObservableObject {
  static let shared = AppearanceController()
  static let changed = Notification.Name("SereinAppearanceChanged")
  @Published private(set) var preference: AppearancePreference
  @Published private(set) var scheme: AppearanceScheme = .dark
  var palette: Palette { Palette(scheme) }
  private var observation: NSKeyValueObservation?
  /// Previews pass `--appearance` and never write the user's choice.
  private var persists = true

  private init() {
    preference = AppearancePreference(
      stored: UserDefaults.standard.string(forKey: AppearancePreference.defaultsKey))
  }

  /// Call once at launch, before the first window is created.
  func start(override: AppearancePreference? = nil) {
    if let override {
      preference = override
      persists = false
    }
    apply()
    observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
      Task { @MainActor in AppearanceController.shared.refresh() }
    }
  }

  func set(_ preference: AppearancePreference) {
    guard preference != self.preference else { return }
    self.preference = preference
    if persists { UserDefaults.standard.set(preference.rawValue, forKey: AppearancePreference.defaultsKey) }
    apply()
  }

  private func apply() {
    switch preference {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    refresh()
  }

  private func refresh() {
    let effectiveDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let next = preference.resolve(systemIsDark: effectiveDark)
    guard next != scheme || observation == nil else { return }
    scheme = next
    for window in NSApp.windows {
      // Windows that pinned an appearance before this choice follow it again.
      if window.appearance != nil { window.appearance = nil }
      window.invalidateShadow()
    }
    NotificationCenter.default.post(name: Self.changed, object: nil)
    // Web pages re-evaluate "Darken light webpages", which only applies in dark.
    NotificationCenter.default.post(name: Notification.Name("SereinDarkPagesChanged"), object: nil)
  }
}

/// Settings › General picker.
struct AppearancePicker: View {
  @ObservedObject private var appearance = AppearanceController.shared
  @Environment(\.palette) var p
  var body: some View {
    Picker("Appearance", selection: Binding(get: { appearance.preference }, set: { appearance.set($0) })) {
      ForEach(AppearancePreference.allCases, id: \.self) { Text($0.label).tag($0) }
    }.pickerStyle(.segmented).labelsHidden().fixedSize()
      .accessibilityLabel("Appearance")
  }
}
