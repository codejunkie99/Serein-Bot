#if DEBUG
import Foundation
import SereinCore

/// The assistant list's own marks (board 12): pins, hidden rows, unread rows, the list they make,
/// Copy chat's text, the name card's words, and the row words for held actions, a failed routine
/// and Stop everything.
extension AssistantCoreChecks {
  static func rowRules(_ check: Check) throws {
    typealias R = AssistantRowRules
    typealias S = AssistantSections
    let empty = AssistantRowMarks()

    // Pins.
    let pinned = R.pinning("b", in: R.pinning("a", in: empty))
    try check(pinned.pinned == ["a", "b"], "A pin goes last in the pin order")
    try check(R.pinning("a", in: pinned).pinned == ["a", "b"], "Pinning a pinned row changes nothing")
    try check(R.unpinning("a", in: pinned).pinned == ["b"], "Unpin takes the row out of the pins")
    try check(R.ordering(pins: ["b", "x", "a"], in: pinned).pinned == ["b", "a"], "A new pin order keeps only pinned rows")
    try check(R.ordering(pins: ["b"], in: pinned).pinned == ["b", "a"], "Pins the new order leaves out keep their place after it")
    try check(R.movingPin("b", step: -1, in: ["a", "b", "c"]) == ["b", "a", "c"], "Move up swaps a pin with the one above")
    try check(R.movingPin("a", step: -1, in: ["a", "b"]) == ["a", "b"], "Move up on the first pin changes nothing")
    try check(R.pinnedOrder(["a", "gone", "b", "a"], roster: ["main", "a", "b"]) == ["a", "b"], "Pins off the roster leave, each pin shows once")

    // Hidden rows.
    let hidden = R.hiding("a", main: "main", in: pinned)
    try check(hidden.hidden == ["a"] && hidden.pinned == ["b"], "Hide takes the row out of the list and out of the pins")
    try check(R.hiding("main", main: "main", in: empty) == empty, "The main assistant never hides")
    try check(R.pinning("a", in: hidden).hidden.isEmpty, "Pinning a hidden row shows it again")
    try check(R.showing("a", in: hidden).hidden.isEmpty, "Show in sidebar takes the hide away")
    try check(!R.shows("a", hidden: ["a"], needsYou: false, active: false, revealed: false), "A hidden row is left out")
    try check(R.shows("a", hidden: ["a"], needsYou: true, active: false, revealed: false), "A hidden row shows again while it needs you")
    try check(R.shows("a", hidden: ["a"], needsYou: false, active: true, revealed: false), "A hidden row shows while its chat is open")
    try check(R.shows("a", hidden: ["a"], needsYou: false, active: false, revealed: true), "Show shows the hidden rows")

    // Unread.
    let landed = R.replyLanded("a", chatOnScreen: false, in: empty)
    try check(landed.unread == ["a"], "A reply off screen is unread")
    try check(R.replyLanded("a", chatOnScreen: true, in: empty).unread.isEmpty, "A reply in the chat on screen is read")
    try check(R.replyLanded("a", chatOnScreen: true, in: landed).unread.isEmpty, "A reply seen on screen clears the mark")
    try check(R.marking("a", unread: false, in: landed).unread.isEmpty, "Mark as read clears the mark")
    try check(R.marking("b", unread: true, in: landed).unread == ["a", "b"], "Mark as unread adds the mark")

    // The file: older files load, gone ids leave, early marks join the file's.
    let decoded = try JSONDecoder().decode(AssistantRowMarks.self, from: Data("{\"pinned\":[\"a\"]}".utf8))
    try check(decoded == AssistantRowMarks(pinned: ["a"]), "A file without every key still loads")
    let round = try JSONDecoder().decode(AssistantRowMarks.self, from: try JSONEncoder().encode(landed))
    try check(round == landed, "The marks come back as they were saved")
    let pruned = R.pruned(AssistantRowMarks(pinned: ["a", "gone"], hidden: ["gone", "b"], unread: ["gone"]), roster: ["a", "b"])
    try check(pruned == AssistantRowMarks(pinned: ["a"], hidden: ["b"], unread: []), "Ids off the roster leave every mark")
    let merged = R.merged(AssistantRowMarks(pinned: ["a"], hidden: ["c"]), AssistantRowMarks(pinned: ["c"], unread: ["b"]))
    try check(merged == AssistantRowMarks(pinned: ["a", "c"], hidden: [], unread: ["b"]), "Early marks join the file's; a pin shows")

    // The list.
    let rows: [S.Row] = [
      S.Row(id: "a", status: .ready), S.Row(id: "b", status: .working(1)), S.Row(id: "c", status: .needsYou),
      S.Row(id: "d", status: .ready), S.Row(id: "e", status: .ready),
    ]
    let marks = AssistantRowMarks(pinned: ["d", "main"], hidden: ["a", "c", "e"])
    let layout = R.layout(main: "main", rows: rows, marks: marks, active: "e", revealed: false)
    try check(layout.main == nil && layout.pinned == ["d", "main"], "A pinned main assistant sits in the pins, in pin order")
    try check(layout.rest.map(\.id) == ["b", "c", "e"], "Hidden rows leave; one that needs you or is open stays")
    try check(layout.hiddenCount == 1, "Only the rows left out count as hidden")
    let open = R.layout(main: "main", rows: rows, marks: marks, active: nil, revealed: true)
    try check(open.rest.map(\.id) == ["a", "b", "c", "e"] && open.hiddenCount == 2, "Show brings the hidden rows back and they still count")
    let plain = R.layout(main: "main", rows: rows, marks: empty, active: nil, revealed: false)
    try check(plain.main == "main" && plain.pinned.isEmpty && plain.hiddenCount == 0, "With no marks, the main row is first and nothing is hidden")
    let parts = S.arrange(layout.rest)
    try check(R.order(layout, parts: parts) == ["d", "main", "c", "b", "e"], "The switch order is the pins, then the sections")
    try check(R.order(plain, parts: S.arrange(plain.rest)).first == "main", "Unpinned, the main assistant is first")
    try check(R.hiddenWords(2) == "2 hidden · Show", "The last row says how many are hidden")

    // Copy chat.
    let chat = R.plainChat([
      R.ChatLine(who: "You", words: "Sort my mail"), R.ChatLine(who: "Inbox Zero", words: "  "),
      R.ChatLine(who: nil, words: "Asked Planner"), R.ChatLine(who: "Inbox Zero", words: "Done.\nTwo left."),
    ])
    try check(chat == "You: Sort my mail\n\nAsked Planner\n\nInbox Zero: Done.\nTwo left.", "Copy chat is Name: words, with empty messages left out")

    // The name card.
    let long = String(repeating: "a", count: RelayProfile.nameLimit + 1)
    try check(R.nameProblem(long, roster: []) == "Use a name of 40 characters or fewer.", "A name past 40 characters is too long")
    try check(R.nameProblem("writer", roster: ["Writer"]) == "Another assistant is called writer.", "A taken name, in any case, is refused")
    try check(R.nameProblem("Scout", roster: ["Writer"]) == nil && R.nameProblem("", roster: ["Writer"]) == nil, "A free or empty name has no problem")

    // The row words SPEC 2.2 adds: held actions, a failed routine, Stop everything.
    let held = AssistantRowWords.of(status: .ready, phase: nil, nextRun: "Checks at 8:00 AM", job: nil, held: 1)
    try check(held == AssistantRowWords(text: "1 thing for you", tone: .needsYou), "A held action reads 1 thing for you")
    try check(AssistantRowWords.of(status: .ready, phase: nil, nextRun: nil, job: nil, held: 3).text == "3 things for you", "Three held actions")
    try check(AssistantRowWords.of(status: .needsYou, phase: nil, nextRun: nil, job: nil, held: 2).text == "Needs you", "A waiting card wins over held actions")
    let failed = AssistantRowWords.of(status: .ready, phase: nil, nextRun: "Checks at 8:00 AM", job: nil, failed: "Clean up my inbox")
    try check(failed.tone == .failed && failed.text.hasPrefix("Could not finish Clean"), "A failed routine reads Could not finish {routine}")
    try check(failed.text.count <= AssistantRowWords.maxLine, "The failure words are cut to 28 characters")
    try check(AssistantRowWords.of(status: .working(1), phase: "Reading", nextRun: nil, job: nil, failed: "x").text == "Reading",
              "A run that works wins over the last failure")
    try check(AssistantRowWords.of(status: .paused, phase: nil, nextRun: nil, job: nil, stopped: true) == AssistantRowWords(text: "Stopped", tone: .faint),
              "Stop everything reads Stopped in faint")
    try check(AssistantRowWords.of(status: .paused, phase: nil, nextRun: nil, job: nil).text == "Paused", "Its own pause reads Paused")
  }

  /// Pointer motion is continuous, including the gap between the two resting layouts.
  static func sidebarWidth(_ check: Check) throws {
    typealias W = SidebarWidth
    func drag(_ width: CGFloat, from now: W.Settled = .list(extra: 0)) -> W.Settled {
      W.settle(.width(width), from: now, usual: 244)
    }
    for usual: CGFloat in [220, 244, 300] {
      let maximum = usual + W.extra.upperBound
      let samples = Array(stride(from: W.rail, through: maximum, by: 0.5))
      try check((samples + samples.reversed()).allSatisfy { W.dragged($0, usual: usual) == $0 },
                "The sidebar stays under the pointer through collapse and reversal at usual width \(usual)")
      try check(W.dragged(-50, usual: usual) == W.rail && W.dragged(900, usual: usual) == maximum,
                "The edge stops at the rail and at the widest list")
      let midpoint = (W.rail + usual + W.extra.lowerBound) / 2
      try check(W.settle(.width(midpoint - 0.5), from: .list(extra: 0), usual: usual) == .rail
                && W.settle(.width(midpoint), from: .rail, usual: usual) == .list(extra: W.extra.lowerBound),
                "Release chooses the closer resting width; a tie opens the list")
    }
    try check(drag(300) == .list(extra: 56), "A release within the list range keeps the pointer width")
    try check(drag(900) == .list(extra: 168), "The list stops 168 points over its usual width")
    try check(drag(198) == .list(extra: -44), "A release just below the narrowest list settles back two points")
    try check(drag(90) == .rail, "A release near the rail settles six points to the rail")
    try check(drag(260, from: .rail) == .list(extra: 16), "Pulled further, the edge follows the pointer again")
    try check(W.settle(.step(up: false), from: .list(extra: 0), usual: 244) == .list(extra: -20), "A step narrows the list by 20")
    try check(W.settle(.step(up: false), from: .list(extra: -30), usual: 244) == .list(extra: -44), "A step stops at the narrowest list")
    try check(W.settle(.step(up: false), from: .list(extra: -44), usual: 244) == .rail, "A step down from the narrowest list is the rail")
    try check(W.settle(.step(up: false), from: .rail, usual: 244) == .rail, "The rail is the narrowest")
    try check(W.settle(.step(up: true), from: .rail, usual: 244) == .list(extra: -44), "A step up from the rail is the narrowest list")
    try check(W.settle(.step(up: true), from: .list(extra: 160), usual: 244) == .list(extra: 168), "A step stops at the widest list")
    try check(W.rail >= 79, "The rail keeps room for the window's three buttons")
  }
}
#endif
