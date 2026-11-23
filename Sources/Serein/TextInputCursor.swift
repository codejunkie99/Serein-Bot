import AppKit
import SwiftUI

extension View {
  /// Plain SwiftUI fields can leave the arrow over their empty area or placeholder.
  func textInputCursor() -> some View { modifier(TextInputCursor()) }
}

private struct TextInputCursor: ViewModifier {
  @Environment(\.isEnabled) private var enabled
  @State private var inside = false
  func body(content: Content) -> some View {
    content.onContinuousHover { phase in
      switch phase {
      case .active:
        inside = true
        if enabled { NSCursor.iBeam.set() }
      case .ended:
        inside = false
        NSCursor.arrow.set()
      }
    }.onDisappear { if inside { NSCursor.arrow.set() } }
  }
}
