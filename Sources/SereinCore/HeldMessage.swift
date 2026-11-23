import CoreGraphics
import Foundation

// Pure rules for a message Serein could not answer yet (F10, F12): no AI app is connected, or
// the Mac is offline. The message is held, not lost. It sends by itself when what held it clears
// within 30 minutes of being written; after that it waits for Send now or Discard, so an old
// question never runs late by surprise. A turn the AI app's usage limit stopped is held too, on
// its own clock (UsageLimit). Nothing here touches the UI, so SereinChecks covers it.

/// One message held back, with why and when it was written.
public struct HeldMessage: Equatable, Sendable, Identifiable, Codable {
  public enum Reason: String, Equatable, Sendable, Codable {
    /// No AI app is connected: Serein has nothing to think with.
    case noAI
    /// The Mac is offline.
    case offline
    /// The AI app's usage limit stopped the turn (`UsageLimit`): it waits for the reset time, or
    /// for Continue now.
    case usageLimit
  }
  public var id: String
  public var text: String
  public var at: Date
  public var reason: Reason
  /// A usage-limit hold's chat and the reset time Serein sends it at (nil: none named, or it
  /// already went once). Optional, so a held.json written before them decodes.
  public var threadID: String?
  public var resetsAt: Date?
  public init(id: String = UUID().uuidString, text: String, at: Date, reason: Reason, threadID: String? = nil,
              resetsAt: Date? = nil) {
    self.id = id
    self.text = text
    self.at = at
    self.reason = reason
    self.threadID = threadID
    self.resetsAt = resetsAt
  }

  /// A held message sends by itself only within this long of being written.
  public static let window: TimeInterval = 30 * 60

  /// Why a message would be held now, or nil when it can go. No AI app comes first, as it does in
  /// the status (Not connected › Offline): being back online does not help without one.
  public static func reason(connected: Bool, online: Bool) -> Reason? {
    if !connected { return .noAI }
    if !online { return .offline }
    return nil
  }

  /// What happens to a held message now.
  public enum Next: Equatable, Sendable {
    /// Still held, for this reason.
    case wait(Reason)
    /// What held it cleared in time: it sends now.
    case send
    /// Written more than 30 minutes ago: it waits for Send now or Discard.
    case stale
  }
  public static func next(_ held: HeldMessage, connected: Bool, online: Bool, now: Date) -> Next {
    // A usage-limit hold keeps its own time (the reset), never the 30-minute rule.
    if held.reason == .usageLimit { return .wait(.usageLimit) }
    if now.timeIntervalSince(held.at) > window { return .stale }
    if let reason = reason(connected: connected, online: online) { return .wait(reason) }
    return .send
  }

  // MARK: copy

  /// The chip under a held bubble written more than 30 minutes ago: it no longer sends by itself.
  public static let staleChip = "Not sent"
  /// The chip under the held bubble: what happens next (`staleChip` once it is stale).
  public static func chip(_ next: Next) -> String {
    switch next {
    case .wait(let reason): return chip(reason)
    case .send: return "Sending"
    case .stale: return staleChip
    }
  }
  /// The chip under the held bubble while it waits.
  public static func chip(_ reason: Reason) -> String {
    switch reason {
    case .noAI: return "Waiting to send"
    case .offline: return "Sends when you are back online"
    case .usageLimit: return UsageLimit.chip
    }
  }
  /// Serein's own line under it (written by Serein, not by a model).
  public static func waitingLine(_ reason: Reason) -> String {
    switch reason {
    case .noAI: return "I cannot think yet. Connect an AI app and I will answer this."
    case .offline: return "You are offline. Serein sends this when you are back."
    // The chat names the app and the reset time instead (`UsageLimit.line`).
    case .usageLimit: return "Your AI app reached its usage limit."
    }
  }
  /// The line when what held it clears in time and the message goes.
  public static func sendingLine(_ reason: Reason) -> String {
    switch reason {
    case .noAI: return "Connected. Answering your message now."
    case .offline: return "You are back online. Answering your message now."
    case .usageLimit: return "Continuing your message now."
    }
  }
  /// The line for a message written more than 30 minutes ago.
  public static func staleLine(_ text: String, limit: Int = 80) -> String {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let short = words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    return "You asked this earlier: “\(short)”"
  }
  /// What the ⌥Space bar's reply card says for a message it held.
  public static func barLine(_ reason: Reason) -> String {
    switch reason {
    case .noAI: return "Serein needs an AI app to think with."
    case .offline: return "You are offline. Serein sends this when you are back."
    case .usageLimit: return "Your AI app reached its usage limit. Open Serein's chat to continue."
    }
  }
}

/// Where a question for the user (an approval, a form) shows, so it reaches them wherever they
/// are (F7): in Serein's chat when it is on screen; in the ⌥Space bar when that is up; in the chat
/// with the slim line when Serein's window is in front but its chat is not; else in the bar
/// without taking the keyboard, with a notification. A full-screen app gets only the
/// notification. The alert is the last resort, when no screen can show the bar.
public enum ApprovalPlacement: Equatable, Sendable {
  /// In Serein's chat, where the user is looking.
  case inline
  /// In the ⌥Space bar's reply card: the bar opens for it, without taking the keyboard, and a
  /// notification says Serein needs you (the user is in another app).
  case bar
  /// In the ⌥Space bar's reply card, already on screen: the user is looking at it, so no
  /// notification.
  case barUp
  /// In Serein's chat, with the slim line “Serein is waiting for your OK · Show” and the row's
  /// “Needs you”. Nothing switches by itself.
  case waitingLine
  /// Only a notification; the card waits in Serein's chat.
  case notificationOnly
  /// The alert: no screen can show the bar.
  case alert

  /// `chatVisible`: Serein's chat is on screen though another app is in front (side by side).
  /// The card is already in view there, so the bar would only cover it with a second copy; a
  /// notification says Serein needs you instead.
  public static func place(chatOnScreen: Bool, barShown: Bool, windowKey: Bool, frontFullScreen: Bool,
                           screenAvailable: Bool, chatVisible: Bool = false) -> ApprovalPlacement {
    if chatOnScreen { return .inline }
    if barShown { return .barUp }
    if windowKey { return .waitingLine }
    if chatVisible { return .notificationOnly }
    if !screenAvailable { return .alert }
    if frontFullScreen { return .notificationOnly }
    return .bar
  }
  /// The bar shows the card (`show(focus: false)`) for these.
  public var showsBar: Bool { self == .bar || self == .barUp }
  /// A notification says Serein needs you for these: the user is in another app (never while the
  /// bar is already up in front of them).
  public var notifies: Bool { self == .bar || self == .notificationOnly }

  /// A window covers a whole screen (a full-screen app): its bounds hold one screen's frame, give
  /// or take a point. Both in the same coordinates (top-left origin, as CGWindowList reports).
  public static func covers(window: CGRect, screens: [CGRect]) -> Bool {
    screens.contains { screen in
      window.insetBy(dx: -1, dy: -1).contains(screen) && screen.width > 0 && screen.height > 0
    }
  }
}
