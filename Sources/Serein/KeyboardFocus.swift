import AppKit
import SwiftUI

/// The keyboard's ring on a control that draws its own chrome (`ButtonSurface`, `PillButton`, the
/// settings switch), which a custom button style otherwise goes without: `UIStyle.focusRing`
/// points of `focus`, as far again outside the control's shape, shown only while the control
/// holds the keyboard. `focus` clears 3:1 on every plane (`ThemeTokens.iconPairs`). It appears
/// and goes at once: nothing about it moves.
private struct FocusRing<S: InsettableShape>: ViewModifier {
  var shape: S
  @Environment(\.isFocused) private var focused
  @Environment(\.palette) private var p
  func body(content: Content) -> some View {
    content
      .overlay {
        shape.inset(by: -UIStyle.focusRing * 2).strokeBorder(p.focus, lineWidth: UIStyle.focusRing)
          .opacity(focused ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
      }
  }
}
extension View {
  func keyboardFocusRing<S: InsettableShape>(_ shape: S) -> some View { modifier(FocusRing(shape: shape)) }
}

extension NSAlert {
  /// A destructive confirm, after its buttons are added: the first button (Delete, Clear) is drawn
  /// as destructive and loses Return, and the keyboard rests on the last (Cancel), which takes
  /// Return. A stray Return or Space never deletes.
  func cancelByDefault() {
    guard let destructive = buttons.first, let cancel = buttons.last, destructive !== cancel else { return }
    destructive.hasDestructiveAction = true
    destructive.keyEquivalent = ""
    cancel.keyEquivalent = "\r"
    window.initialFirstResponder = cancel
  }
}
