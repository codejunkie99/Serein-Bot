import Foundation
import SereinCore

/// One task's line of browser socket calls. The socket serves calls side by side, and an agent's
/// helper sends read-only calls together; ToolTurns decides which may run (read-only calls on
/// different tabs together, a call on the same tab after the one before it, an action alone), and
/// this resumes each waiting call when its turn comes. A call that waits longer than `limit` does
/// not run at all, so an answer the caller has given up on never acts later.
@MainActor final class ToolGate {
  /// Told to the agent when a call's turn did not come in time.
  static let timedOut =
    "An earlier step of this task is still running, so this step did not start. Run it again when that step ends."
  /// Well inside the socket's answer wait (`SocketServer.answerWait`), so the call still has time
  /// to run.
  nonisolated static let limit: TimeInterval = 15
  private var turns = ToolTurns()
  private var next = 0
  private var waiting: [Int: CheckedContinuation<Bool, Never>] = [:]

  /// Waits for the call's turn. Returns its id for `leave`, or nil when the turn did not come
  /// within `limit` seconds.
  func enter(write: Bool, tab: String?, limit: TimeInterval = ToolGate.limit) async -> Int? {
    next += 1
    let id = next
    if turns.request(id: id, write: write, tab: tab) { return id }
    let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      waiting[id] = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
        self?.expire(id)
      }
    }
    return started ? id : nil
  }
  /// The call ended; the calls it held back start.
  func leave(_ id: Int) { resume(turns.finish(id: id)) }
  /// No call runs or waits.
  var isIdle: Bool { turns.isIdle }

  private func expire(_ id: Int) {
    guard let continuation = waiting.removeValue(forKey: id) else { return }
    continuation.resume(returning: false)
    resume(turns.cancel(id: id))
  }
  private func resume(_ ids: [Int]) {
    for id in ids { waiting.removeValue(forKey: id)?.resume(returning: true) }
  }
}

/// A socket call's place in its task's line (BrowserModel.enterToolTurn).
struct ToolTurn {
  let task: String
  let gate: ToolGate
  let id: Int
}
enum ToolEntry {
  /// No valid capability: `handle` refuses the call, as before.
  case unchecked
  case turn(ToolTurn)
  case timedOut
}

/// The socket call the running task serves, bound around `BrowserModel.handle` and an outside
/// agent's tool call. Every ask inside it closes before the caller gives up (`CallWindow`), and
/// the call's reply then says nobody answered in time.
@MainActor final class SocketCall {
  let clock: CallClock
  var window: CallWindow { clock.window }
  /// The call has replied: a task it started that asks later is no longer part of it.
  private var replied = false
  /// A card inside the call closed for time.
  private(set) var unanswered = false
  /// The caller's CLI waits on one tool call at least a secure card's life
  /// (`BrowserModel.longCards`): a card raised in the call holds it, so it may live that long.
  var longCards = false
  init(clock: CallClock) { self.clock = clock }

  /// The window a card that starts now gets.
  func cardWindow() -> CallWindow {
    if longCards { clock.hold() }
    return window
  }

  /// The call the running task serves, until that call replies.
  static var live: SocketCall? { SocketCalls.current.flatMap { $0.replied ? nil : $0 } }

  /// How long an ask that starts now may wait: `life`, cut to what the call has left. Nil when
  /// nothing is left; the call then answers that nobody replied in time.
  func life(_ life: TimeInterval) -> TimeInterval? {
    guard let left = cardWindow().cardLife(life, now: Date()) else {
      unanswered = true
      return nil
    }
    return left
  }
  /// The answer a step stands on: a yes that came after the call stopped waiting runs nothing.
  func settle(_ human: ApprovalGate.HumanAnswer) -> ApprovalGate.HumanAnswer {
    let settled = window.settle(human, at: Date())
    if settled != human { unanswered = true }
    return settled
  }
  /// A card in this call closed because the call stopped waiting for it.
  func closedUnanswered() { unanswered = true }
  /// Whether the caller still waits; once it does not, the call answers that nobody replied in time.
  func waiting() -> Bool {
    if window.open(at: Date()) { return true }
    unanswered = true
    return false
  }
  /// What the caller hears: the handler's reply, or that nobody answered in time.
  func reply(_ response: [String: Any]) -> [String: Any] {
    replied = true
    return CallWindow.reply(response, unanswered: unanswered)
  }
}
/// Which socket call the running task serves; `Task {}` inherits it, so `SocketCall.live`
/// drops a call once it has replied.
enum SocketCalls {
  @TaskLocal static var current: SocketCall?
}
