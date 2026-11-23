import CoreGraphics
import Foundation

/// A chat whose assistant reached for the Mac while Accessibility was off: its one card, the line
/// the card becomes once macOS lets Serein in, and the one turn that then carries the chat on.
/// Saved in relay/mac-access.json, so the card and that turn survive a relaunch.
public struct MacAccessWait: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case waiting, granted }
  public private(set) var chats: [String: State]
  public init(chats: [String: State] = [:]) { self.chats = chats }

  /// The Mac tools that need Accessibility. `mac_script` runs through Automation and goes ahead.
  public static let tools: Set<String> = ["mac_observe", "mac_act"]
  public static let toolResult =
    "Serein is waiting for Accessibility access, so it cannot see or use Mac apps yet. A card in this chat shows the person how to turn it on, and this chat carries on by itself once it is on. Do not call Mac tools again this turn; tell the person that in one short sentence."
  /// The turn Serein starts in the chat once Accessibility is on. The chat draws it as `line`
  /// (`RelayAutomatic.Kind.macAccess`), never as these words.
  public static let followUp =
    "Accessibility is on now, so the Mac tools work. Carry on with the task they were waiting for, without asking the person to repeat it."
  public static let line = "Serein can use your Mac now"

  public func state(in chat: String) -> State? { chats[chat] }
  public var waiting: Bool { chats.values.contains(.waiting) }

  /// A tool call in `chat`. nil when it goes ahead: another tool, or Accessibility is on. Else the
  /// result the model gets, with the chat's one card up (a second call keeps the same card).
  public mutating func call(_ tool: String, chat: String, granted: Bool) -> String? {
    guard Self.tools.contains(tool), !granted, !chat.isEmpty else { return nil }
    chats[chat] = .waiting
    return Self.toolResult
  }
  /// Accessibility came on: every waiting card becomes its line. False when none waited.
  public mutating func grant() -> Bool {
    let waiting = chats.filter { $0.value == .waiting }.map(\.key)
    for chat in waiting { chats[chat] = .granted }
    return !waiting.isEmpty
  }
  /// Whether `chat`'s follow-up turn starts now: true once per grant. The chat then keeps the line
  /// as that turn's start, so its entry goes.
  public mutating func carryOn(chat: String) -> Bool {
    guard chats[chat] == .granted else { return false }
    chats[chat] = nil
    return true
  }
}

/// The small card that floats over System Settings while the person drags Serein into its
/// Accessibility list (MacAccessGuide): where it sits, and when it goes.
public enum MacAccessDragCard {
  public static let lifetime: TimeInterval = 180
  /// From the window's bottom edge, and from the screen's bottom when nothing is found.
  public static let inset: CGFloat = 16
  public static let screenBottom: CGFloat = 56

  public enum Close: Equatable, Sendable { case granted, settingsClosed, timedOut }
  /// Why the card goes now, or nil. System Settings counts as closed only once it was seen: it may
  /// still be opening when the card shows.
  public static func close(granted: Bool, settingsSeen: Bool, settingsThere: Bool, elapsed: TimeInterval) -> Close? {
    if granted { return .granted }
    if settingsSeen && !settingsThere { return .settingsClosed }
    return elapsed >= lifetime ? .timedOut : nil
  }
  /// A Quartz window rect (origin at the top left of the main display, y down) in AppKit screen
  /// coordinates (origin at its bottom left, y up). `mainHeight`: the main display's height.
  public static func appKit(_ window: CGRect, mainHeight: CGFloat) -> CGRect {
    CGRect(x: window.minX, y: mainHeight - window.maxY, width: window.width, height: window.height)
  }
  /// The card's origin: centred just inside the window's bottom edge, just below it when the
  /// window is too short, at the bottom centre of `visible` when there is no window; always
  /// kept inside `visible`, the AppKit visible frame of the screen it goes on.
  public static func origin(window: CGRect?, mainHeight: CGFloat, visible: CGRect, size: CGSize) -> CGPoint {
    guard let window else { return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + screenBottom) }
    let frame = appKit(window, mainHeight: mainHeight)
    let inside = frame.height >= size.height + 2 * inset
    let y = inside ? frame.minY + inset : frame.minY - size.height - inset
    return CGPoint(x: min(max(frame.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                   y: min(max(y, visible.minY), visible.maxY - size.height))
  }
}
