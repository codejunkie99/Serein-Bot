import Foundation

/// What Serein does with a window a page opens (`window.open`, a `target=_blank` link). WebKit
/// passes every one to Serein (`javaScriptCanOpenWindowsAutomatically`), and a page may open one
/// only right after the person used that tab: sign-in scripts (Google, Apple) often open their
/// window after a short network step, which WebKit's own blocker no longer counts as the click.
public enum PopupPolicy {
  public enum Decision: Equatable, Sendable { case open, offer, block }
  /// Opens within this many seconds of the person's click or activation key in the tab.
  public static let recent: TimeInterval = 10
  /// After that, offers the window in a notice up to this many seconds; later it is blocked
  /// with no notice, so a page cannot fill the screen with notices.
  public static let later: TimeInterval = 60
  /// Return, keypad Enter and Space: the keys that press a focused button or link. Typing in a
  /// field is not input for a window.
  public static let activationKeys: Set<UInt16> = [36, 49, 76]
  /// A mouse-down (`keyCode` nil) or an activation key is the person's input.
  public static func counts(keyCode: UInt16?) -> Bool { keyCode.map(activationKeys.contains) ?? true }
  /// `sinceInput`: seconds since the person's last click or activation key in the tab (an agent's
  /// clicks are page events, not input); nil when there was none. One input opens one window:
  /// the tab forgets the input when a window opens.
  public static func decide(sinceInput: TimeInterval?) -> Decision {
    guard let since = sinceInput, since >= 0 else { return .block }
    if since <= recent { return .open }
    return since <= later ? .offer : .block
  }
}
