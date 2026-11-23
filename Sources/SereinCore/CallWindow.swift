import Foundation

/// A tool call that reaches Serein over its socket is answered within `SocketServer.answerWait`,
/// after which the caller is told it failed. A card raised inside that call closes before then,
/// as a no, so a late Allow can never run an action the caller already gave up on. Pure, so it
/// is checked.
public struct CallWindow: Equatable, Sendable {
  /// Kept back so the call's no still reaches the caller before the socket gives up.
  public static let margin: TimeInterval = 8
  /// The last moment an answer still reaches the call.
  public let answerBy: Date

  public init(start: Date, wait: TimeInterval = SocketServer.answerWait) {
    answerBy = start.addingTimeInterval(wait - Self.margin)
  }

  /// Whether an answer given at `now` still reaches the call.
  public func open(at now: Date) -> Bool { now < answerBy }

  /// How long an ask that starts at `now` may wait: its own `life`, cut to what the call has
  /// left. Nil once the call has nothing left: no card shows and nothing runs.
  public func cardLife(_ life: TimeInterval, now: Date) -> TimeInterval? {
    let left = answerBy.timeIntervalSince(now)
    return left > 0 ? min(life, left) : nil
  }

  /// The answer a step stands on: a yes given after the window is no answer, so it runs nothing.
  public func settle(_ answer: ApprovalGate.HumanAnswer, at now: Date) -> ApprovalGate.HumanAnswer {
    answer == .yes && !open(at: now) ? .timeout : answer
  }

  /// What the caller hears when a card in its call closed unanswered.
  public static let unansweredResult =
    "The person did not answer in time, so nothing was done. Ask again if it is still needed."
  /// What the closed card says under its word.
  public static let unansweredLine = "No answer in time. Nothing was done."

  /// The call's reply once a card in it closed unanswered: an error says so in place of its own
  /// words, and any other reply carries the line beside what it already holds.
  public static func reply(_ response: [String: Any], unanswered: Bool) -> [String: Any] {
    guard unanswered else { return response }
    var out = response
    if out["error"] != nil { out["error"] = unansweredResult } else { out["unanswered"] = unansweredResult }
    return out
  }
}

/// When one socket call must answer. A secure card that holds the call moves this out once, to
/// `SecureCard.heldWait` from the call's start, and the server's wait follows it. Read from the
/// server's thread and the main actor.
public final class CallClock: @unchecked Sendable {
  public let start: Date
  private let lock = NSLock()
  private var held = false
  public init(start: Date = Date()) { self.start = start }

  public var wait: TimeInterval { lock.withLock { held ? SecureCard.heldWait : SocketServer.answerWait } }
  /// The moment the server stops waiting for the handler.
  public var deadline: Date { start.addingTimeInterval(wait) }
  public var window: CallWindow { CallWindow(start: start, wait: wait) }
  public func hold() { lock.withLock { held = true } }
}
