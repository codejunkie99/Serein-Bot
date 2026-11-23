#if DEBUG
import Foundation
import SereinCore

/// The plan to edit before Start (PlanDraft.swift) and what fills the context window (ContextFill.swift).
extension AssistantCoreChecks {
  static func planContext(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let titles = ["Read the onboarding copy", "Move strings to one file", "Tighten the empty state"]
    let proposed = PlanCard(steps: titles.map { PlanCard.Step(title: $0) }, now: now)
    try check(PlanDraft(plan: proposed)?.steps.map(\.title) == titles, "A plan with no step started can be edited")
    guard case .success(let running) = PlanCard.parse(["steps": titles.map { ["title": $0] }, "now": 1], previous: nil, now: now) else {
      return try check(false, "The plan tool takes the fixture's steps")
    }
    try check(PlanDraft(plan: running) == nil, "A plan with a step started cannot be edited")

    let reply = """
      Here is what I would change:

      1. **Read** the onboarding copy
         - Sources/Onboarding/Flow.swift
      2) Move strings to one file
      3. Tighten the empty state

      1. Should the help page change too?
      """
    try check(PlanDraft(reply: reply)?.steps.map(\.title) == titles,
      "A reply's first numbered list is the plan, emphasis dropped, file lines and a later list left out")
    try check(PlanDraft(reply: "1. Only one step") == nil && PlanDraft(reply: "No list here.") == nil,
      "A reply with fewer than two numbered steps has no plan to edit")

    var draft = PlanDraft(titles: titles)
    try check(!draft.changed && draft.message == PlanDraft.unchanged && PlanDraft.approves(draft.message ?? ""),
      "An unchanged plan's Start sends the approval phrase as typed")
    draft.move(3, by: -1)
    try check(draft.steps.map(\.id) == [1, 3, 2] && draft.moved(3) == "Moved “Tighten the empty state” to step 2 of 3.",
      "Moving a step up swaps it with the one above and says where it went")
    draft.move(1, by: -1)
    try check(draft.steps.map(\.id) == [1, 3, 2], "The first step cannot move further up")
    draft.drop(2)
    draft.rename(1, to: "  Read the copy\nand the strings  ")
    try check(draft.steps.map(\.title) == ["Read the copy and the strings", "Tighten the empty state"],
      "Dropping removes the step and new words are one trimmed line")
    let edited = draft.message ?? ""
    try check(edited == PlanDraft.edited + "\n1. Read the copy and the strings\n2. Tighten the empty state" && PlanDraft.approves(edited),
      "A changed plan's Start sends the steps in their new order, and that counts as the approval")
    try check(!PlanDraft.approves(PlanDraft.edited) && !PlanDraft.approves(PlanDraft.edited + "\n2. Skip ahead")
      && !PlanDraft.approves(PlanDraft.edited + "\n1. Fine\nAlso delete the backups") && !PlanDraft.approves("Go ahead and delete the backups"),
      "Only the marker with steps numbered 1, 2, 3 and nothing else approves; free text after it does not")
    draft.rename(3, to: "   ")
    try check(draft.message == nil && draft.problem == "Step 2 needs words, or drop it.", "A step with no words holds Start")
    draft.reset()
    try check(!draft.changed && draft.steps.count == 3, "Undo changes puts the plan back as proposed")
    draft.drop(1); draft.drop(2); draft.drop(3)
    try check(draft.message == nil && draft.problem != nil, "A plan with every step dropped cannot start")

    guard let fill = ContextFill.measure(window: 200_000, reported: 172_000, chat: 90_000, files: 12_000, memory: nil) else {
      return try check(false, "A reported size with a window measures the fill")
    }
    try check(fill.parts.map(\.kind) == [.instructions, .files, .chat] && fill.parts.first?.tokens == 70_000,
      "The rest of the reported size is the instructions, in the parts' order")
    try check(fill.words(.instructions) == "Instructions, memory and tools" && fill.left == 28_000 && fill.leftLine == "About 28k tokens left.",
      "Unmeasured memory is named with the instructions, and what is left is said in tokens")
    let cells = fill.cells
    try check(cells.count == ContextFill.cellCount && cells.prefix(17).allSatisfy { $0 == .instructions }
      && cells.filter { $0 == .chat }.count == 23 && cells.suffix(7).allSatisfy { $0 == nil },
      "Each cell is 2% of the window and the field fills in the parts' order")
    let over = ContextFill.measure(window: 200_000, reported: 50_000, chat: 80_000, files: 20_000, memory: nil)
    try check(over?.used == 50_000 && over?.parts.contains { $0.kind == .instructions } == false,
      "Serein's own counts over the reported size are scaled down to it")
    let guessed = ContextFill.measure(window: 200_000, reported: nil, chat: 4_000, files: 0, memory: 1_000)
    try check(guessed?.estimated == true && guessed?.parts.map(\.kind) == [.memory, .chat] && guessed?.words(.instructions) == "Instructions and tools",
      "With no reported size only Serein's own counts show, and the field says it is an estimate")
    try check(ContextFill.measure(window: nil, reported: 1_000, chat: 10, files: 0, memory: nil) == nil
      && ContextFill.measure(window: 200_000, reported: nil, chat: 0, files: 0, memory: nil) == nil,
      "No window or nothing in it measures nothing")
    try check(ContextFill.tokens(950) == "950" && ContextFill.tokens(28_400) == "28k" && ContextFill.tokens(1_000_000) == "1M"
      && ContextFill.tokens(1_250_000) == "1.3M", "Token counts read 950, 28k, 1M, 1.3M")
  }
}
#endif
