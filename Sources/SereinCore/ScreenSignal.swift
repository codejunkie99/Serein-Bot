import Foundation

/// What Serein shows over every app: a glow around the screen's edge while one of its runs works
/// in a Mac app or a web page. What Serein is doing is in its chat (`RunTrail`), not over other apps.
public enum ScreenSignal {
  /// One of Serein's runs at work.
  public struct Work: Equatable, Sendable {
    /// The newest thing it did was a step in a Mac app or a web page (`holdsControls`).
    public var controls: Bool
    public init(controls: Bool) { self.controls = controls }
  }
  public struct Shown: Equatable, Sendable {
    public var glow: Bool
    public init(glow: Bool = false) { self.glow = glow }
  }

  /// Board tools that operate a Mac app or a web page. Serein's own computer (`computer_*`) is
  /// another machine, and Mail, Calendar and connected apps are reached without their windows.
  static let controlTools: Set<String> = [
    "mac_observe", "mac_act", "mac_script",
    "open_tab", "open", "navigate", "go", "read", "find", "click", "fill", "type", "select", "hover", "scroll", "key",
    "back", "wait", "screenshot", "close_tab", "close", "upload", "click_point", "page_tool",
    "list_tabs", "tabs", "do", "repl",
  ]

  /// A run holds the controls from its first Mac or page step until it ends or turns to other
  /// work: its newest board step is one of `controlTools`, and nothing it did outside the board
  /// (`otherAt`, its newest command, edit or search) is newer. A step that failed or was refused
  /// did nothing, and a run that waits on the person (`waiting`) cannot act.
  public static func holdsControls(tool: String?, at: Date?, failed: Bool = false, waiting: Bool = false, otherAt: Date?) -> Bool {
    guard let tool, let at, !failed, !waiting, controlTools.contains(tool) else { return false }
    return otherAt.map { $0 <= at } ?? true
  }

  /// The glow is on while any run holds the controls, whatever the hologram says (a card on one
  /// task leaves another at work), and off when paused.
  public static func resolve(state: RelayLook.State, work: [Work]) -> Shown {
    Shown(glow: state != .dormant && work.contains(where: \.controls))
  }
}
