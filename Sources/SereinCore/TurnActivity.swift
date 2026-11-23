import Foundation

/// The small rules of a turn in the chat, apart from any view: what the work trail's header says,
/// how many of its steps wait behind "earlier steps", when the chat follows the reply to its end,
/// what a failed, stopped or quiet turn offers, and what the message box's button and Return do.
public enum TurnActivity {
  /// The trail's header: at work, standing still until the person answers, or done.
  public enum Header: Sendable, Equatable { case thinking, waiting, worked }

  /// A finished turn is done whatever still waits; a running one stands still while a card or a
  /// question waits on the person.
  public static func header(ended: Bool, waiting: Bool) -> Header {
    ended ? .worked : waiting ? .waiting : .thinking
  }
  /// The header's words while it waits on the person.
  public static let waitingWords = "Waiting on you"

  /// How many steps the trail shows while the turn runs.
  public static let liveLimit = 6
  /// The steps behind the trail's "earlier steps" row: all but the newest `liveLimit` while the
  /// turn runs, none once the person opened them or the turn ended (a finished trail lists all).
  public static func earlierSteps(total: Int, live: Bool, opened: Bool) -> Int {
    live && !opened ? max(0, total - liveLimit) : 0
  }
  /// The row's words: "3 earlier steps".
  public static func earlierWords(_ count: Int) -> String {
    count == 1 ? "1 earlier step" : "\(count) earlier steps"
  }

  /// A scroll up of more than this many points from the end stops the chat following the reply.
  public static let detachAfter: Double = 24
  /// Scrolling back down to within this many points of the end starts it again.
  public static let attachWithin: Double = 150
  /// Whether the chat follows the reply to its end after one reading of the scroll view.
  /// `gap`: how far the chat's end is below the view's foot. `moved`: how far the reader moved
  /// since the last reading, up negative. A reply that grows moves nothing, so it never detaches
  /// by itself, and it never re-attaches a reader who has scrolled away.
  public static func follows(_ following: Bool, gap: Double, moved: Double) -> Bool {
    if gap <= 1 { return true }
    if following { return !(moved < 0 && gap > detachAfter) }
    return moved > 0 && gap <= attachWithin
  }

  // MARK: A turn that did not finish

  /// How a turn that is not a plain success shows in the chat. `failed`: it ended with a cause.
  /// `stopped`: the person ended it, which is no error. `slow`: it runs, and nothing has come yet.
  public enum Trouble: Sendable, Equatable { case failed, stopped, slow }
  /// What the person can press on a turn's line.
  public enum Action: Sendable, Equatable { case details, retry, keepWaiting, stop }
  /// The actions of each line, in the order drawn. Details only with a cause to show; Try again
  /// only for words the person wrote (`canRetry`); a quiet turn offers no retry, since it still runs.
  public static func actions(_ trouble: Trouble, hasCause: Bool = false, canRetry: Bool = true) -> [Action] {
    switch trouble {
    case .failed: return (hasCause ? [.details] : []) + (canRetry ? [.retry] : [])
    case .stopped: return canRetry ? [.retry] : []
    case .slow: return [.keepWaiting, .stop]
    }
  }

  /// The longest cause a failed turn's Details shows.
  public static let causeLimit = 600
  /// A failure's cause for Details: trimmed, cut at `causeLimit` characters with "…", nil when empty.
  public static func cause(_ raw: String?) -> String? {
    let text: String = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    return text.count <= causeLimit ? text : String(text.prefix(causeLimit)) + "…"
  }

  /// A turn sent again says which try it is, so it never reads as a first success: "Try 2". The
  /// first try says nothing.
  public static func tryWords(_ number: Int) -> String? {
    number > 1 ? "Try \(number)" : nil
  }

  /// How long a turn may show nothing before the chat offers to keep waiting or stop.
  public static let slowAfter: Double = 20
  /// Whether that offer shows: the turn has run `slowAfter` seconds with no step and no reply
  /// word, nothing waits on the person, and they have not chosen to keep waiting.
  public static func slowReply(elapsed: Double, steps: Int, replied: Bool, waiting: Bool, keptWaiting: Bool) -> Bool {
    elapsed >= slowAfter && steps == 0 && !replied && !waiting && !keptWaiting
  }

  // MARK: The message box

  /// What the one send button does now. `stop` draws whenever a turn runs and the box is empty.
  public enum SendButton: Sendable, Equatable { case send, queue, stop, disabled }
  public static func sendButton(hasWords: Bool, working: Bool) -> SendButton {
    hasWords ? (working ? .queue : .send) : working ? .stop : .disabled
  }
  /// Stop stays in sight when it cannot act (another assistant's routine, a turn still starting
  /// elsewhere): disabled, never hidden.
  public static func sendActs(_ button: SendButton, canStop: Bool) -> Bool {
    switch button {
    case .send, .queue: return true
    case .stop: return canStop
    case .disabled: return false
    }
  }
  /// How long the button's pictures crossfade, in seconds. Opacity only.
  public static let sendSwap: Double = 0.12

  /// What Return does with words typed now, most pressing first: it answers a question that
  /// waits, waits behind a card the person has yet to answer, waits behind the reply (which
  /// ⌥Return can cut short, `interrupts`), sends what is attached, or sends.
  public enum ReturnDoes: Sendable, Equatable { case answers, queuesBehindCard, queues(interrupts: Bool), sendsAttached, sends }
  public static func returnDoes(question: Bool, working: Bool, cardWaits: Bool, replyingHere: Bool, attached: Bool) -> ReturnDoes {
    if question { return .answers }
    if working { return cardWaits ? .queuesBehindCard : .queues(interrupts: replyingHere) }
    return attached ? .sendsAttached : .sends
  }
  /// The box's placeholder for each; nil keeps the chat's own words ("Ask or tell … anything").
  public static func placeholder(_ does: ReturnDoes) -> String? {
    switch does {
    case .answers: return "Type your answer, Return sends it"
    case .queuesBehindCard: return "Answer the card first. Return queues this"
    case .queues(let interrupts): return interrupts ? "Return sends this, ⌥Return stops and sends it" : "Return sends this at the next step"
    case .sendsAttached: return "Add words, or Return to send"
    case .sends: return nil
    }
  }

  /// A queued message taken back for editing joins what is already typed, after it, so neither is lost.
  public static func editing(queued: String, draft: String) -> String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? queued : draft + "\n" + queued
  }

  /// One draft for each assistant: leaving one keeps what was typed to it (nothing kept for an
  /// empty box), and the box takes what was typed to the one opened.
  public static func swapDraft(_ drafts: inout [String: String], leaving: String, typed: String, opening: String) -> String {
    drafts[leaving] = typed.isEmpty ? nil : typed
    return drafts[opening] ?? ""
  }
}
