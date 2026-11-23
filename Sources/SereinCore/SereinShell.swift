import Foundation

// Pure rules for the Serein tab: which saved chats are Serein's own, and the one status word its
// row, band tab and header show. Nothing here touches the UI, so SereinChecks covers every rule.

/// Serein's own chats never show as task tabs or in chat lists: they live in the Serein surface.
public enum SereinChat {
  /// The suffix a Serein turn adds to its saved session scope (AgentModel.send, `relay: true`).
  public static let scopeMark = "|relay"
  /// Whether a saved chat is Serein's own. The persisted flag decides when it is set; older
  /// records fall back to a scope that still carries Serein's mark, then to the thread ids Serein
  /// knows (every assistant's current chat and the chats it moved on from). Scope alone is never
  /// enough to say no: a turn without the mark rewrites it.
  public static func isSerein(flag: Bool?, scope: String, id: String, known: Set<String>) -> Bool {
    if flag == true { return true }
    if known.contains(id) { return true }
    return scope.hasSuffix(scopeMark)
  }
  /// How many earlier chats Serein keeps track of; the oldest go first.
  public static let pastLimit = 500
  /// Serein's earlier chats after it leaves `leaving` (New chat, opening a past chat): the chat
  /// it leaves goes last when it is worth going back to (`keep`: it has messages and was not
  /// deleted), each id appears once, `opening` is no longer past, and the list holds at most
  /// `limit` ids.
  public static func past(_ past: [String], leaving: String, keep: Bool, opening: String? = nil,
                          limit: Int = pastLimit) -> [String] {
    var out = past.filter { $0 != leaving && $0 != opening }
    if keep { out.append(leaving) }
    if out.count > limit { out.removeFirst(out.count - limit) }
    return out
  }
}

/// What Serein is doing, in one word for its row, band tab and header (§2.1, §2.4).
public enum SereinStatus: Equatable, Sendable {
  case notConnected
  case offline
  case ready
  case replying
  /// Live tasks, Serein's and direct ones.
  case working(Int)
  case needsYou
  /// A reply arrived while Serein was not on screen.
  case unread
  /// After Stop Everything, until Serein resumes.
  case paused

  /// The most pressing state wins: Needs you › Not connected › Offline › Paused › Replying ›
  /// Working › Unread › Ready.
  public static func current(
    needsYou: Bool, connected: Bool, online: Bool, paused: Bool, replying: Bool, working: Int, unread: Bool
  ) -> SereinStatus {
    if needsYou { return .needsYou }
    if !connected { return .notConnected }
    if !online { return .offline }
    if paused { return .paused }
    if replying { return .replying }
    if working > 0 { return .working(working) }
    if unread { return .unread }
    return .ready
  }

  /// The header's words. An unread reply reads Ready there: the header is where it is read.
  public var words: String {
    switch self {
    case .notConnected: return "Not connected"
    case .offline: return "Offline"
    case .ready, .unread: return "Ready"
    case .replying: return "Replying…"
    case .working(let n): return n == 1 ? "Working on 1 thing" : "Working on \(n) things"
    case .needsYou: return "Needs you"
    case .paused: return "Paused"
    }
  }
  /// The row's trailing words, or nil when a spinner, a dot or nothing says it.
  public var rowWords: String? {
    switch self {
    case .notConnected: return "Connect"
    case .offline: return "Offline"
    case .ready, .replying, .unread: return nil
    case .working(let n): return "\(n)"
    case .needsYou: return "Needs you"
    case .paused: return "Paused"
    }
  }
  /// The words VoiceOver reads after the place: “Serein, full, Ready”.
  public var spoken: String {
    switch self {
    case .unread: return "New reply"
    default: return words
    }
  }
  /// The mini spinner shows (it is the only moving part).
  public var spins: Bool {
    switch self {
    case .replying, .working: return true
    default: return false
    }
  }
  /// The band tab shows the state as one glyph: an SF Symbol name, or nil for a spinner, a dot
  /// or nothing.
  public var glyph: String? {
    switch self {
    case .notConnected: return "bolt.slash"
    case .offline: return "wifi.slash"
    case .paused: return "pause.fill"
    default: return nil
    }
  }
  /// The VoiceOver label of the row: “Serein, <full | beside | hidden>, <state>”.
  public static func label(place: String, status: SereinStatus) -> String {
    "Serein, \(place), \(status.spoken)"
  }
}

/// Where Serein is in a window right now (§2.1).
public enum SereinPlace: Equatable, Sendable {
  /// Serein is the main view.
  case full
  /// Docked on the right, beside the tab in view (kept beside, or a peek).
  case beside
  /// Not on screen: Hide was chosen, and nothing asked from this tab.
  case hidden
  /// Beside would leave the page too narrow (or Compact Mode is on): it stepped aside.
  case noRoom
  /// The word VoiceOver reads after “Serein”: full, beside or hidden.
  public var spoken: String {
    switch self {
    case .full: return "full"
    case .beside: return "beside"
    case .hidden, .noRoom: return "hidden"
    }
  }
  /// Serein's chat is on screen (full or beside).
  public var shows: Bool { self == .full || self == .beside }
}

/// One change of Serein's placement. A nil field is left as it is: `besideOn == nil` never
/// writes the saved choice (`serein.relay.column`).
public struct SereinMove: Equatable, Sendable {
  public enum Target: Equatable, Sendable {
    /// The main view stays.
    case stay
    /// Serein full.
    case full
    /// Back to the tab that was in view before Serein full.
    case back
  }
  public var target: Target
  public var peek: Bool?
  public var besideOn: Bool?
  public init(target: Target = .stay, peek: Bool? = nil, besideOn: Bool? = nil) {
    self.target = target
    self.peek = peek
    self.besideOn = besideOn
  }
}

/// ⌘J's menu title, whether it can run, and what it does.
public struct SereinSwitch: Equatable, Sendable {
  public var title: String
  public var enabled: Bool
  public var move: SereinMove
}

/// The placement rules: full or beside, peek, Hide and the narrow-window rule (§2.1). Pure, so
/// SereinChecks covers every case; the shell, the router and the menus only read them.
public enum SereinLayout {
  /// The page never gets narrower than this beside Serein.
  public static let pageMinWidth = 420.0
  /// Serein beside's width when nothing is saved, and its widest.
  public static let defaultWidth = 380.0
  public static let maxWidth = 520.0
  /// Beside's width, saved once resized (seeded from the retired task panel's width).
  public static let widthKey = "serein.assistant.width"
  public static let seedWidthKey = "serein.taskPanel.width"

  /// Where Serein is. `room` is the width the page and Serein beside share (the window less the
  /// sidebar and the gaps); `minWidth` is Serein beside's narrowest.
  public static func place(section: String, besideOn: Bool, peek: Bool, compact: Bool, room: Double, minWidth: Double) -> SereinPlace {
    if section == ShellSection.serein { return .full }
    // Settings and the Marketplace need the card's width for their own list and page; Serein
    // waits until they close.
    if section == ShellSection.settings || section == ShellSection.marketplace || (!besideOn && !peek) { return .hidden }
    if !fits(compact: compact, room: room, minWidth: minWidth) { return .noRoom }
    return .beside
  }
  /// Serein beside fits: not Compact Mode, and the page keeps at least 420 points beside its
  /// narrowest width.
  public static func fits(compact: Bool, room: Double, minWidth: Double) -> Bool {
    !compact && room - minWidth >= pageMinWidth
  }
  /// Serein beside's width: the saved one, never under `minWidth` or over 520, and narrowed so
  /// the page keeps 420 points.
  public static func width(saved: Double?, room: Double, minWidth: Double) -> Double {
    let wanted = min(maxWidth, max(minWidth, saved.flatMap { $0 > 0 ? $0 : nil } ?? defaultWidth))
    return max(minWidth, min(wanted, room - pageMinWidth))
  }
  /// The first width: the saved beside width, else the task panel's, else 380.
  public static func seed(width: Double?, taskPanel: Double?) -> Double? {
    if let width, width > 0 { return width }
    if let taskPanel, taskPanel > 0 { return taskPanel }
    return nil
  }

  /// ⌘J. From Serein full: back to your tab, with beside turned on (“Back to Your Tab” when
  /// there is no room there; disabled with no tab). From a tab with Serein beside, or with no
  /// room: Serein full. From a tab with Serein hidden: beside turns on.
  public static func afterSwitch(place: SereinPlace, fits: Bool, hasTab: Bool) -> SereinSwitch {
    switch place {
    case .full:
      guard hasTab else { return SereinSwitch(title: "Show Serein Beside", enabled: false, move: SereinMove()) }
      return fits
        ? SereinSwitch(title: "Show Serein Beside", enabled: true, move: SereinMove(target: .back, peek: false, besideOn: true))
        : SereinSwitch(title: "Back to the Page", enabled: true, move: SereinMove(target: .back, peek: false))
    case .beside, .noRoom:
      return SereinSwitch(title: "Show Serein Full", enabled: true, move: SereinMove(target: .full, peek: false))
    case .hidden:
      return fits
        ? SereinSwitch(title: "Show Serein Beside", enabled: true, move: SereinMove(peek: false, besideOn: true))
        : SereinSwitch(title: "Show Serein Full", enabled: true, move: SereinMove(target: .full, peek: false))
    }
  }

  /// A click on the Serein row or band tab.
  public enum RowClick: Equatable, Sendable {
    /// Serein is already full: its composer takes the keyboard.
    case focusComposer
    case showFull
  }
  public static func rowClick(place: SereinPlace) -> RowClick { place == .full ? .focusComposer : .showFull }

  /// Asking from a tab (⌘E, the toolbar's Serein button, the slim line's Show): Serein beside
  /// stays; hidden peeks beside this tab only. It never writes the saved choice. With no room
  /// Serein shows full (until the in-window bar takes that case). While the task panel holds the
  /// right side it stays open and Serein shows full (until tasks move into Serein).
  public static func askFromHidden(place: SereinPlace, fits: Bool, panelOpen: Bool = false) -> SereinMove {
    switch place {
    case .full: return SereinMove()
    case .beside: return panelOpen ? SereinMove(target: .full) : SereinMove()
    case .hidden: return fits && !panelOpen ? SereinMove(peek: true) : SereinMove(target: .full)
    case .noRoom: return SereinMove(target: .full)
    }
  }
  /// Hide (× in the side header): turns beside off, or, during a peek, only ends the peek.
  public static func hide(peeking: Bool) -> SereinMove {
    peeking ? SereinMove(peek: false) : SereinMove(peek: false, besideOn: false)
  }
  /// Undo after Hide puts back what Hide changed.
  public static func undoHide(peeking: Bool) -> SereinMove {
    peeking ? SereinMove(peek: true) : SereinMove(besideOn: true)
  }
  /// Keep beside (only while peeking): the peek becomes the saved choice.
  public static let keepBeside = SereinMove(peek: false, besideOn: true)
  /// Another tab or section selected, or Esc in an empty composer beside: the peek ends.
  public static let endPeek = SereinMove(peek: false)
  /// The peek is on screen: Serein beside only because something asked from this tab.
  public static func peeking(peek: Bool, besideOn: Bool) -> Bool { peek && !besideOn }

  /// The out-of-room toast: beside stepped aside while it held something to lose sight of.
  public static func movedAside(from old: SereinPlace, to new: SereinPlace, draft: Bool, waiting: Bool) -> Bool {
    old == .beside && new == .noRoom && (draft || waiting)
  }
  /// The toolbar's and the band's Serein button: a tab is in view and Serein is not beside.
  public static func buttonShows(place: SereinPlace) -> Bool { place == .hidden || place == .noRoom }
  /// Its help, by what a click does: peek beside, or Serein full (no room, or the task panel on
  /// the right).
  public static func buttonHelp(place: SereinPlace, fits: Bool, panelOpen: Bool = false) -> String {
    if place == .noRoom || !fits { return "Not enough room beside this page · ⌘J shows Serein full" }
    return panelOpen ? "Show Serein full · ⌘E" : "Show Serein beside this tab · ⌘E"
  }
  /// A task view's Put beside button (help, then VoiceOver label), by what ⌘J does there: beside
  /// your tab, or only back to it when there is no room.
  public static func putBeside(fits: Bool) -> (help: String, label: String) {
    fits ? ("Show Serein beside your tab · ⌘J", "Show Serein beside your tab") : ("Back to your tab · ⌘J", "Back to your tab")
  }
  /// Its VoiceOver label, from the same rule as its help.
  public static func buttonLabel(place: SereinPlace, fits: Bool, panelOpen: Bool = false) -> String {
    askFromHidden(place: place, fits: fits, panelOpen: panelOpen).target == .full ? "Show Serein full" : "Show Serein beside this tab"
  }
}
