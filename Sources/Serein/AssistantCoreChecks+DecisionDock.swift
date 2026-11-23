#if DEBUG
import Foundation
import SereinCore

/// The dock above Serein's composer: which asks it holds, and in what order.
extension AssistantCoreChecks {
  static func decisionDock(_ check: Check) throws {
    let now = Date()
    let approval = RelayOrchestrator.Approval(title: "Click Send in Mail", detail: "This sends it.", button: "Allow", threadID: nil) { _ in }
    let trip = TeamProposal(name: "Trip", members: [], lead: nil)
    let team = RelayOrchestrator.Approval(title: "Create the team “Trip”?", detail: "", button: "Create team", threadID: nil,
      proposal: RelayOrchestrator.TeamProposalDraft(proposal: trip, shown: RelayTeam(profiles: [], activeID: ""))) { _ in }
    let session = ExternalSession(id: "check.dock", driver: .claude, title: "Sign-in fix", cwd: "/synthetic/shop-web",
                                  state: .needsUser, updatedAt: now)
    let open = DecisionAsk.open(approvals: [team, approval], waiting: [(session, now.addingTimeInterval(-60))])
    try check(open.map(\.id) == ["waiting:check.dock", "approval:\(approval.id)"],
      "The dock pages oldest first, and leaves a team proposal in the transcript")

    // Serein's own questions wait inside its reply; once answered they read as one chip per answer.
    let items = RelayOrchestrator.answeredItems([
      RelayQuestion(id: "flight", label: "Which flight?", choices: ["TAP 8:05 — direct, $380", "Ryanair 6:30"]),
      RelayQuestion(id: "notes", label: "Anything else?"),
      RelayQuestion(id: "cols", label: "Columns?", columns: ["Name"]),
    ], ["flight": "TAP 8:05 — direct, $380", "notes": "  ", "cols": "Name, Price — USD"])
    try check(items.map(\.answer) == ["TAP 8:05", nil, "Name, Price — USD"],
      "An answer chip shows a choice's title, nothing for a skipped question, and columns as given")
    try check(items[0].choices.count == 2, "An answer chip keeps the choices it can be changed to")

    var said = AgentMessage(role: "assistant", text: "Claude Code needs you in shop-web.", notice: true)
    said.waitingSession = "check.dock"
    var done = session
    done.id = "check.done"
    done.state = .running
    var answered = said
    answered.waitingSession = "check.done"
    let waiting = DecisionAsk.waiting([said, answered], sessions: [session, done])
    try check(waiting.map(\.0.id) == ["check.dock"], "Only a session that still needs you is in the dock")
  }
}
#endif
