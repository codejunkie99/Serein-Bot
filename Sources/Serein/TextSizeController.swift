import AppKit
import SereinCore
import SwiftUI

/// The one text size (Settings › Appearance): scales Serein's type through `UIStyle.textScale`
/// and every open webpage through its page zoom. Changing it bumps `generation`, which the
/// shell uses to rebuild its view tree so every font picks up the new size at once.
@MainActor final class TextSizeController: ObservableObject {
  static let shared = TextSizeController()
  @Published private(set) var scale: Double
  @Published private(set) var generation = 0
  private init() {
    let stored = UserDefaults.standard.double(forKey: TextSize.defaultsKey)
    scale = stored > 0 ? TextSize.snap(stored) : TextSize.standard
    UIStyle.textScale = scale
  }
  /// Reads the stored size before the first window is built.
  static func load() { _ = shared }
  /// Applies a size. While the slider is being dragged the fonts and pages follow but the view
  /// trees are left alone; `commit` (drag end) rebuilds them, so the drag is never interrupted.
  func set(_ value: Double, commit: Bool = true) {
    let next = TextSize.snap(value)
    if next != scale {
      scale = next
      UIStyle.textScale = next
      UserDefaults.standard.set(next, forKey: TextSize.defaultsKey)
      BrowserContext.browser?.tabs.forEach { $0.applyStoredZoom() }
      pendingRebuild = true
    }
    if commit, pendingRebuild {
      pendingRebuild = false
      generation += 1
    }
  }
  private var pendingRebuild = false
}

/// Settings › Appearance › Text size: a slider from 90% to 160%, the live percentage, and a
/// reset to 100% when it is anything else.
struct TextSizeSlider: View {
  @ObservedObject private var controller = TextSizeController.shared
  @Environment(\.palette) var p
  var body: some View {
    HStack(spacing: 10) {
      Slider(
        value: Binding(get: { controller.scale }, set: { controller.set($0, commit: false) }),
        in: TextSize.range, step: TextSize.step,
        onEditingChanged: { editing in if !editing { controller.set(controller.scale) } }
      ).frame(width: 160).controlSize(.small)
        .accessibilityLabel("Text size").accessibilityValue(TextSize.percent(controller.scale))
      Text(TextSize.percent(controller.scale)).font(UIStyle.microMono).foregroundStyle(p.secondary)
        .frame(width: 44, alignment: .trailing)
      Button("Reset") { controller.set(TextSize.standard) }.buttonStyle(QuietButton())
        .disabled(controller.scale == TextSize.standard).help("Back to 100%")
    }.fixedSize()
  }
}
