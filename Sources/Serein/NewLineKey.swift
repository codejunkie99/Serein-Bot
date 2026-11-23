import AppKit
import SwiftUI

/// Shift-Return starts a new line at the cursor in a message field whose Return sends, as in
/// Messages and Slack. Return alone still sends; ⌥Return keeps whatever the field gives it.
extension View {
  func shiftReturnNewLine() -> some View {
    onKeyPress(keys: [.return], phases: .down) { press in
      guard press.modifiers.contains(.shift), !press.modifiers.contains(.option), !press.modifiers.contains(.command)
      else { return .ignored }
      // The field editor inserts the line break where the cursor is, replacing any selection.
      NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
      return .handled
    }
  }
}
