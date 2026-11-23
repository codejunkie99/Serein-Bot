import CryptoKit
import Foundation

/// The three rules between the model and a computer's screen, in one state: what the model has
/// seen since the screen last changed hands. Look again after a hand-back, "screen unchanged"
/// for a repeated picture, and a warning on the third identical step. It is a value owned by one
/// ComputerHost.Computer and changed only by the model's own steps, a hand-back and a new holder:
/// the live view's poller never touches it, so "unchanged" always means unchanged since the last
/// picture the model was sent.
public struct StepGuard: Sendable {
  public static let unchangedWindow: TimeInterval = 30
  public static let repeatLimit = 3
  public enum Kind: Sendable, Equatable { case look, screenAct, other }
  static let looks: Set<String> = ["computer_screenshot", "computer_tree", "computer_zoom"]
  static let screenActs: Set<String> = [
    "computer_click", "computer_type", "computer_key", "computer_scroll", "computer_set_value", "computer_steps", "computer_open_url",
    "computer_run",
  ]
  public static func kind(_ tool: String) -> Kind {
    looks.contains(tool) ? .look : screenActs.contains(tool) ? .screenAct : .other
  }

  /// What the person did while they had the screen; set at hand-back, cleared by the next look.
  public private(set) var handedBack: String?
  /// The CAPTCHAs (FreshRead.checkID) an ask closed on: a tree that still shows one opens no
  /// new ask, so a solved check left on the page never stops the task.
  public var hadChecks: Set<String> = []
  /// An uncut read of a window: a CAPTCHA the person had there that it no longer shows is gone, so
  /// a new one in its place asks again.
  public mutating func saw(_ read: FreshRead) {
    guard !read.cut else { return }
    let shown = read.botChecks, window = "\(read.window)\u{0}"
    hadChecks = hadChecks.filter { !$0.hasPrefix(window) || shown.contains($0) }
  }
  /// The last picture the model was sent: its SHA-256 and when.
  private var sent: (sha256: String, at: Date)?
  /// The last screen step (StepJournal.key) and how many times in a row.
  private var last: (key: String, count: Int)?

  public init() {}

  /// Before a step: nil to go, or why it waits. A screen step waits while the person is asked to
  /// take control, and after a hand-back until the model looks again. A look always goes.
  public func refusal(tool: String, asking: Bool) -> String? {
    guard Self.kind(tool) == .screenAct else { return nil }
    if asking {
      return "The user is asked to take control of Serein's computer now. Keep working on anything else; Serein sends you a message when they hand it back, and a computer_tree that no longer shows the check that a person is there closes the ask too."
    }
    if let handedBack {
      return "The person had Serein's computer and handed it back; while they had it, they \(handedBack). Look again first with computer_tree or computer_screenshot, then act."
    }
    return nil
  }

  /// After a step ran: a look clears the hand-back and says what the person did; a screen step
  /// counts repeats and warns at the limit. Looks and other tools do not break a run of repeats.
  public mutating func ran(_ tool: String, _ arguments: [String: Any], into result: inout [String: Any]) {
    switch Self.kind(tool) {
    case .look:
      if let handedBack {
        result["note"] = "The person took over Serein's computer and handed it back. While they had it, they \(handedBack)."
        self.handedBack = nil
      }
    case .screenAct:
      let key = StepJournal.key(tool: tool, arguments: arguments)
      let count = last?.key == key ? (last?.count ?? 0) + 1 : 1
      last = (key, count)
      if count >= Self.repeatLimit {
        result["warning"] = "This is the same step \(count) times in a row. The screen may not be reacting: look again, or try another way."
      }
    case .other:
      break
    }
  }

  /// A picture about to go to the model: true means answer "screen unchanged" instead. Only when
  /// its bytes are the last sent picture's and that went under 30 seconds ago (Cua Driver's PNG
  /// is byte-stable for an unchanged screen). A sent picture starts the window again; an
  /// "unchanged" answer does not.
  public mutating func unchanged(png: Data, now: Date) -> Bool {
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    if let sent, sent.sha256 == hash, now.timeIntervalSince(sent.at) < Self.unchangedWindow { return true }
    sent = (hash, now)
    return false
  }
  /// Seconds since the last picture the model was sent.
  public func sentAgo(_ now: Date) -> Int? { sent.map { Int(now.timeIntervalSince($0.at)) } }

  /// Hand-back: the next screen step must look first, and the next picture is always sent whole.
  public mutating func handBack(summary: String) {
    handedBack = summary
    sent = nil
    last = nil
  }
}
