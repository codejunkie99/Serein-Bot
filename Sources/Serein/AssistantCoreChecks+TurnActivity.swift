#if DEBUG
import Foundation
import SereinCore

/// A turn in the chat: the trail's header, its earlier steps, and when the chat follows the reply.
extension AssistantCoreChecks {
  static func turnActivity(_ check: Check) throws {
    try check(TurnActivity.header(ended: false, waiting: false) == .thinking, "A running turn's trail says Thinking")
    try check(TurnActivity.header(ended: false, waiting: true) == .waiting, "A card or question that waits stops the trail on the person")
    try check(TurnActivity.header(ended: true, waiting: true) == .worked, "A finished turn's trail says Worked, whatever still waits")

    try check(TurnActivity.earlierSteps(total: 6, live: true, opened: false) == 0, "Six live steps all show")
    try check(TurnActivity.earlierSteps(total: 9, live: true, opened: false) == 3, "The live trail keeps its newest six and counts the rest")
    try check(TurnActivity.earlierSteps(total: 9, live: true, opened: true) == 0, "Opened, the earlier steps all show")
    try check(TurnActivity.earlierSteps(total: 9, live: false, opened: false) == 0, "A finished trail lists every step")
    try check(TurnActivity.earlierWords(1) == "1 earlier step" && TurnActivity.earlierWords(3) == "3 earlier steps",
      "The earlier steps row counts in plain words")

    try check(TurnActivity.follows(true, gap: 40, moved: 0), "A reply that grows keeps the chat following")
    try check(TurnActivity.follows(true, gap: 20, moved: -20), "A scroll up of 24 points or less still follows")
    try check(!TurnActivity.follows(true, gap: 30, moved: -30), "A scroll up of more than 24 points detaches")
    try check(!TurnActivity.follows(false, gap: 400, moved: 0), "A growing reply never pulls a detached reader back")
    try check(!TurnActivity.follows(false, gap: 120, moved: -10), "Scrolling up near the end stays detached")
    try check(!TurnActivity.follows(false, gap: 200, moved: 40), "Scrolling down stays detached while the end is over 150 points away")
    try check(TurnActivity.follows(false, gap: 140, moved: 40), "Coming back within 150 points of the end re-attaches")
    try check(TurnActivity.follows(false, gap: 0, moved: 0), "At the end the chat follows")

    try check(TurnActivity.actions(.failed, hasCause: true) == [.details, .retry], "A failed turn offers Details, then Try again")
    try check(TurnActivity.actions(.failed, hasCause: false) == [.retry], "With no cause to show there is no Details")
    try check(TurnActivity.actions(.failed, hasCause: true, canRetry: false) == [.details],
      "A turn the person did not write offers no Try again")
    try check(TurnActivity.actions(.stopped) == [.retry], "A stopped turn offers Try again and no Details: it is no error")
    try check(TurnActivity.actions(.slow) == [.keepWaiting, .stop], "A quiet turn offers to keep waiting or stop")

    try check(TurnActivity.cause("  \n ") == nil && TurnActivity.cause(nil) == nil, "An empty cause is none")
    try check(TurnActivity.cause(" timed out \n") == "timed out", "A cause is trimmed")
    let long: String = String(repeating: "a", count: 601)
    try check(TurnActivity.cause(String(long.dropLast())) == String(long.dropLast()), "A cause of 600 characters is whole")
    try check(TurnActivity.cause(long) == String(repeating: "a", count: 600) + "…", "A longer cause is cut at 600 characters")

    try check(TurnActivity.tryWords(1) == nil && TurnActivity.tryWords(0) == nil, "The first try says nothing")
    try check(TurnActivity.tryWords(2) == "Try 2" && TurnActivity.tryWords(3) == "Try 3", "A turn sent again says which try it is")

    try check(!TurnActivity.slowReply(elapsed: 19.9, steps: 0, replied: false, waiting: false, keptWaiting: false),
      "Under 20 seconds nothing is offered")
    try check(TurnActivity.slowReply(elapsed: 20, steps: 0, replied: false, waiting: false, keptWaiting: false),
      "After 20 seconds with no step and no reply word the chat offers to wait or stop")
    try check(!TurnActivity.slowReply(elapsed: 60, steps: 1, replied: false, waiting: false, keptWaiting: false), "A step is a sign of work")
    try check(!TurnActivity.slowReply(elapsed: 60, steps: 0, replied: true, waiting: false, keptWaiting: false), "So is a reply word")
    try check(!TurnActivity.slowReply(elapsed: 60, steps: 0, replied: false, waiting: true, keptWaiting: false),
      "A turn that waits on the person is not slow")
    try check(!TurnActivity.slowReply(elapsed: 60, steps: 0, replied: false, waiting: false, keptWaiting: true),
      "Keep waiting takes the offer away")

    try check(TurnActivity.sendButton(hasWords: true, working: false) == .send, "Words and no turn: Send")
    try check(TurnActivity.sendButton(hasWords: true, working: true) == .queue, "Words while a turn runs: Queue")
    try check(TurnActivity.sendButton(hasWords: false, working: true) == .stop, "An empty box while a turn runs: Stop")
    try check(TurnActivity.sendButton(hasWords: false, working: false) == .disabled, "An empty box and no turn: nothing to press")
    try check(TurnActivity.sendActs(.stop, canStop: true) && !TurnActivity.sendActs(.stop, canStop: false),
      "Stop that cannot act is disabled, not another button")
    try check(TurnActivity.sendActs(.queue, canStop: false) && !TurnActivity.sendActs(.disabled, canStop: true),
      "Queue always acts, and an empty idle box never does")
    try check(TurnActivity.sendSwap == 0.12, "The button's pictures crossfade over 120 ms")

    let does = TurnActivity.returnDoes
    try check(does(true, true, true, true, true) == .answers, "A question that waits comes first: Return answers it")
    try check(does(false, true, true, true, false) == .queuesBehindCard, "Behind a card, Return queues until it is answered")
    try check(does(false, true, false, true, false) == .queues(interrupts: true), "During a reply here, Return queues and ⌥Return cuts in")
    try check(does(false, true, false, false, false) == .queues(interrupts: false), "Behind a routine elsewhere, Return only queues")
    try check(does(false, false, false, false, true) == .sendsAttached, "With a chip and no words, Return sends the chip")
    try check(does(false, false, false, false, false) == .sends, "Idle, Return sends")
    try check(TurnActivity.placeholder(.sends) == nil, "Idle keeps the chat's own placeholder")
    let phrases: [TurnActivity.ReturnDoes] = [.answers, .queuesBehindCard, .queues(interrupts: true), .queues(interrupts: false), .sendsAttached]
    try check(phrases.allSatisfy { TurnActivity.placeholder($0)?.contains("Return") == true }, "Every other placeholder names Return")
    try check(Set(phrases.compactMap(TurnActivity.placeholder)).count == phrases.count, "Each state has its own words")

    try check(TurnActivity.editing(queued: "also trains", draft: "  ") == "also trains", "Edit puts a queued message in an empty box")
    try check(TurnActivity.editing(queued: "also trains", draft: "and buses") == "and buses\nalso trains",
      "Edit keeps what is already typed")

    var drafts: [String: String] = [:]
    try check(TurnActivity.swapDraft(&drafts, leaving: "main", typed: "to main", opening: "writer") == "", "A new assistant's box starts empty")
    try check(TurnActivity.swapDraft(&drafts, leaving: "writer", typed: "to writer", opening: "main") == "to main",
      "Coming back restores the words left unsent")
    try check(TurnActivity.swapDraft(&drafts, leaving: "main", typed: "", opening: "writer") == "to writer" && drafts["main"] == nil,
      "An empty box leaves no draft behind")
  }
}
#endif
