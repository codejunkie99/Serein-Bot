#if DEBUG
import Foundation
import SereinCore

/// The Permissions view's dial (AutonomyDial, AskBeforeControl): what each level shows is what the door does.
extension AssistantCoreChecks {
  static func affectDial(_ check: Check) throws {
    typealias D = AutonomyDial
    func ids(_ place: D.Place, _ level: ApprovalLevel) -> [String] { D.actions(place, at: level).map(\.id) }

    let floor = ["pay", "terminal", "password", "passwordApps"]
    try check(
      ApprovalLevel.allCases.allSatisfy { level in
        ids(.alone, level) == D.actions.filter { D.decision($0, at: level).runs }.map(\.id)
      }
        && ids(.alone, .everyStep) == ["read", "navigate", "answer"]
        && ids(.alone, .riskyOnly) == D.actions.map(\.id).filter { !floor.contains($0) }
        && ids(.alone, .proactive) == ids(.alone, .riskyOnly),
      "Each level's On its own list is exactly the actions the door runs at that level: reads alone at Every step")

    let hardStops: [String] = D.actions.filter(D.locked).map(\.id)
    try check(
      ids(.alwaysAsks, .everyStep) == ["pay"] && ids(.alwaysAsks, .riskyOnly) == ["pay"]
        && ids(.never, .everyStep) == ["terminal", "password", "passwordApps"]
        && ids(.never, .riskyOnly) == ids(.never, .everyStep)
        && hardStops == floor && ids(.asks, .riskyOnly).isEmpty,
      "Hard stops never move with the level: paying is the person's card, Terminal and passwords are never Serein's")
    try check(D.actions.filter(D.locked).allSatisfy { $0.risk != .low }, "No locked action reads Low risk")

    // The two task rows judge the effects a real dispatch gets (agent_start, TodoBook).
    let answerEffect: ApprovalGate.Effect = MainActor.assumeIsolated {
      RelayToolHost.runEffect(AgentModel.DispatchTarget(mode: .answer, provider: .claude, actions: false))
    }
    let taskEffect: ApprovalGate.Effect = MainActor.assumeIsolated {
      RelayToolHost.runEffect(AgentModel.DispatchTarget(mode: .research, provider: .claude, actions: true))
    }
    try check(
      D.actions.first { $0.id == "answer" }?.probe.effect == answerEffect
        && D.actions.first { $0.id == "task" }?.probe.effect == taskEffect,
      "The dial's task rows carry the effects agent_start gives an answer-only run and a run that acts")

    try check(
      D.announcement(at: .riskyOnly) == "Only risky steps. On its own: 16. Asks first: 1."
        && D.announcement(at: .everyStep) == "Every step. On its own: 3. Asks first: 14.",
      "A level change is read out with how many actions go ahead on their own and how many ask first")
  }
}
#endif
