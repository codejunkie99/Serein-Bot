#if DEBUG
import Foundation
import SereinCore

/// Harness budget checks: the step budget, the skill offer, and each fix's own
/// part (late answers, built-ins, history, process groups, saved text) in its own file.
extension AssistantCoreChecks {
  static func harnessBudget(_ check: Check) throws {
    try stepBudget(check)
    try skillOffer(check)
    try lateAnswer(check)
    try harnessBuiltIns(check)
    try pastedHistory(check)
    try launchSweep(check)
    try savedTextFilter(check)
  }

  static func stepBudget(_ check: Check) throws {
    try check(
      StepBudget.limit(.person) == 200 && StepBudget.limit(.unattended) == 60 && StepBudget.limit(.helper) == 60
        && StepBudget.Kind.allCases.allSatisfy { StepBudget.limits[$0] != nil },
      "A turn the person started gets 200 steps, an unattended turn and a helper run 60, all from one table")
    try check(
      StepBudget.Kind.allCases.allSatisfy { kind in
        let limit = StepBudget.limit(kind)
        return !StepBudget.over(steps: limit, kind: kind, asking: false) && StepBudget.over(steps: limit + 1, kind: kind, asking: false)
      },
      "Each kind runs its whole budget and stops on the call after it")
    try check(
      !StepBudget.over(steps: 201, kind: .person, asking: true) && !StepBudget.over(steps: 61, kind: .unattended, asking: true)
        && StepBudget.over(steps: 202, kind: .person, asking: false),
      "A card waiting on the person holds the count; the next call after the answer stops the turn")
    // Resume is a new turn, and the count is the turn's own (RunRecord.toolCount starts at 0).
    try check(
      !StepBudget.over(steps: RunRecord(threadID: "t", provider: "claude", model: "", effort: "", mode: "answer",
                                        projectID: nil, projectName: nil, title: "").toolCount + 1,
                       kind: .person, asking: false),
      "Resume starts with the whole budget again")
    try check(
      StepBudget.kind(initiator: nil, relay: false, unattended: false) == .person
        && StepBudget.kind(initiator: .relay, relay: true, unattended: false) == .person
        && StepBudget.kind(initiator: .relay, relay: true, unattended: true) == .unattended
        && ([.scheduled, .watch, .webhook, .ask] as [AgentHistoryRun.Initiator]).allSatisfy { StepBudget.kind(initiator: $0, relay: false, unattended: false) == .unattended }
        && StepBudget.kind(initiator: .delegated, relay: false, unattended: false) == .helper
        && StepBudget.kind(initiator: .handoff, relay: false, unattended: false) == .helper
        && StepBudget.kind(initiator: .relay, relay: false, unattended: false) == .unattended,
      "The person's own turns get the person's budget; routines, watches and Serein's scheduled turns the unattended one; agent_start and hand-offs the helper one")
    try check(
      StepBudget.line(200) == "Stopped after 200 steps." && RelayStopNotice.steps(60).text == "Stopped after 60 steps.",
      "The turn ends with one line naming its budget, in Serein's chat too")
  }

  static func skillOffer(_ check: Check) throws {
    func offers(_ outcome: RunRecord.Outcome = .done, steps: Int = 8, kind: StepBudget.Kind = .person,
                turn: String = "t2", offeredFor: String? = nil, closed: Bool = false) -> Bool {
      SkillOffer.offers(outcome: outcome, steps: steps, kind: kind, turn: turn, offeredFor: offeredFor, closed: closed)
    }
    try check(!offers(steps: 7) && offers(steps: 8), "Seven tool calls are not offered as a skill; eight are")
    try check(!offers(.stopped) && !offers(.stuck) && !offers(.waiting) && !offers(.running),
              "Only a turn that finished done is offered")
    try check(!offers(kind: .unattended) && !offers(kind: .helper), "Never on an unattended turn or a helper run")
    try check(!offers(offeredFor: "t1") && offers(offeredFor: "t2") && !offers(closed: true),
              "Once per chat: the turn it went to keeps it, a later turn gets none, and a dismissed or saved chat none")
    try check(SkillOffer.words == "Save how I did this as a skill?", "The offer's words")
  }
}
#endif
