#if DEBUG
import Foundation
import SereinCore

/// Unit A16: the plan card (PlanCard.swift).
extension AssistantCoreChecks {
  static func plan(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let five: [[String: Any]] = [
      ["title": "Ask Planner for the days"], ["title": "Ask Scout for hotels"], ["title": "Make the plan"],
      ["title": "Check every number"], ["title": "Send to the group", "effect": "send"],
    ]
    func problem(_ result: Result<PlanCard, PlanCard.Problem>) -> PlanCard.Problem? {
      if case .failure(let value) = result { return value }
      return nil
    }
    func card(_ result: Result<PlanCard, PlanCard.Problem>) -> PlanCard? {
      if case .success(let value) = result { return value }
      return nil
    }
    try check(problem(PlanCard.parse(["steps": [["title": "One"]]], previous: nil, now: now)) == .tooFew, "A plan has at least 2 steps")
    let eight: [[String: Any]] = (1...8).map { ["title": "Step \($0)"] }
    try check(problem(PlanCard.parse(["steps": eight], previous: nil, now: now)) == .tooMany, "A plan has at most 7 steps")
    let long = String(repeating: "a", count: 41)
    try check(problem(PlanCard.parse(["steps": [["title": "Fine"], ["title": long]]], previous: nil, now: now)) == .tooLong(step: 2), "A title has at most 40 characters")
    try check(problem(PlanCard.parse(["steps": [["title": "Call the webhook"], ["title": "Fine"]]], previous: nil, now: now)) == .plainWords(step: 1), "A title has no feature words")
    try check(problem(PlanCard.parse(["now": 1], previous: nil, now: now)) == .noPlan, "A move needs steps first")

    guard var live = card(PlanCard.parse(["steps": five, "now": 1], previous: nil, now: now)) else {
      try check(false, "Five steps make a plan")
      return
    }
    try check(live.current == 0 && live.steps[0].state == .current, "now starts a step")
    try check(live.asksFirst(4, gateAsked: false) && !live.asksFirst(1, gateAsked: false) && live.asksFirst(1, gateAsked: true), "Send, buy and delete steps ask first, and so does a step where the gate asked")
    if let moved = card(PlanCard.parse(["now": 3], previous: live, now: now.addingTimeInterval(20))) {
      try check(moved.steps[0].state == .done && moved.steps[1].state == .skipped && moved.current == 2, "Starting a later step ends the one that ran and skips those never started")
      live = moved
    } else {
      try check(false, "A plan moves forward")
    }
    try check(problem(PlanCard.parse(["now": 1], previous: live, now: now)) == .backwards, "A step that ended cannot start again")
    try check(problem(PlanCard.parse(["steps": five], previous: live, now: now)) == .backwards, "Steps cannot be replaced once one has started")
    try check(problem(PlanCard.parse(["done": 9], previous: live, now: now)) == .backwards, "A step that does not exist is refused")
    live.waitForPerson(now: now)
    try check(live.steps[2].state == .waiting, "A card during a step makes it wait for the person")
    live.answered(allowed: false, now: now)
    try check(live.steps[2].state == .declined, "A no marks the step declined")

    try check(PlanCard.elapsed(12) == "12s" && PlanCard.elapsed(64) == "1m 04s" && PlanCard.elapsed(3_720) == "1h 02m", "Elapsed time reads 12s, 1m 04s, 1h 02m")
    var all = card(PlanCard.parse(["steps": five], previous: nil, now: now))
    for step in 1...5 {
      all = all.flatMap { card(PlanCard.parse(["done": step], previous: $0, now: now)) }
    }
    try check(all?.folded(seconds: 130) == "Did 5 steps in 2m 10s.", "A finished plan folds to one sentence")
    let running = card(PlanCard.parse(["steps": five, "now": 3], previous: nil, now: now))
    let failed = running.flatMap { card(PlanCard.parse(["failed": 3, "now": 4], previous: $0, now: now)) }
    try check(failed?.folded(seconds: 30) == "Stopped at step 3 of 5: Make the plan.", "A failed plan says where it stopped")
    try check(failed?.steps[2].state == .failed && failed?.current == 3, "A failed step stays failed when the next one starts")
    var partial = card(PlanCard.parse(["steps": five, "done": [1, 2, 3], "now": 4], previous: nil, now: now))
    partial?.end(now: now.addingTimeInterval(300))
    try check(partial?.folded(seconds: 300) == "Did 3 of 5 steps.", "A plan that ended early says how far it got")
    try check(partial?.idle(now: now.addingTimeInterval(400)) == false, "An ended plan is not idle")
    try check(card(PlanCard.parse(["steps": five], previous: nil, now: now))?.folded(seconds: 0) == "Proposed a plan of 5 steps.",
      "A plan no step of which started folds as proposed, not as done")
    let quiet = card(PlanCard.parse(["steps": five, "now": 1], previous: nil, now: now))
    try check(quiet?.idle(now: now.addingTimeInterval(PlanCard.idleFold)) == true, "Five minutes without a move folds the plan")
  }
}
#endif
