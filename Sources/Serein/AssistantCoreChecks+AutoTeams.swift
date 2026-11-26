#if DEBUG
import Foundation
import SereinCore

/// Teams assistants make on their own (`AutoTeams`): no card, every member admitted
/// by `AutoTeamPolicy`, and the end of the root task stops what was made for it and nothing else.
extension AssistantCoreChecks {
  static func autoTeams(_ check: Check) throws {
    let serein = RelayProfile(name: "Serein")
    let writer = RelayProfile(name: "Writer")
    var roster = RelayTeam(profiles: [serein, writer], activeID: serein.id)
    var teams = AutoTeams()
    func member(_ name: String, _ role: String) -> [String: Any] {
      ["name": name, "role": role, "persona": "", "canUse": ["web", "connectedApps"], "instructions": ""]
    }
    func propose(_ name: String, _ members: [[String: Any]], lead: String = "") throws -> AutoTeams.Admission {
      let parsed = try TeamProposal.parse(
        ["name": name, "members": members, "lead": lead], person: Set(AssistantPlace.allCases), team: roster, keepTaken: true)
      let admission = teams.admit(parsed, roster: roster, createdBy: serein.id, root: teams.turnRoot(), activeChain: [serein.id])
      guard !admission.proposal.members.isEmpty else { return admission }
      guard let made = roster.addingTeam(admission.proposal) else { throw SereinError.invalid("FAIL: auto teams: roster takes the team") }
      roster = made.team
      teams.seat(admission, created: made.created)
      return admission
    }
    func id(_ name: String) -> String { roster.profile(named: name)?.id ?? "" }
    func handoff(_ id: String, to: String, _ state: AssistantHandoff.State = .running, parent: AssistantHandoff? = nil) -> AssistantHandoff {
      AssistantHandoff(
        id: id, from: parent?.to ?? serein.id, to: to, task: "Part of the trip", threadID: "chat-" + to, askedIn: "main",
        team: "", teamName: "Trip", state: state, parent: parent)
    }

    let schema = RelayTools.tools.first { $0["name"] as? String == "team_make" }
    try check((schema?["description"] as? String)?.contains("with no card") == true,
      "auto teams: team_make tells the model it is saved with no card")

    // Turn 1 makes a team: two members admitted, three refused with reasons, all in one call.
    let rootA = teams.turnRoot()
    let first = try propose(
      "Trip",
      [member("Scout", "research"), member("Booker", "booking"), member("Second", "Research"), member("Nameless", " "),
       member("Serein", "lead"), member("Writer", "copy")], lead: "Second")
    try check(first.proposal.members.map(\.name) == ["Scout", "Booker"],
      "auto teams: a proposal creates its admitted members at once, with no card or ask")
    try check(roster.teams.last?.memberIDs == [id("Scout"), id("Booker")] && roster.teams.last?.leadID == nil,
      "auto teams: the team holds the created members, and a refused lead is dropped")
    let reasons = Dictionary(uniqueKeysWithValues: first.rejected.map { ($0.member, $0.reason) })
    try check(reasons["Second"]?.contains("already owns the role") == true,
      "auto teams: a second member with the same role on the same root task is refused with the reason")
    try check(reasons["Nameless"]?.contains("Role is required") == true, "auto teams: a member with no role is refused with the reason")
    try check(reasons["Serein"]?.contains("Cycle") == true,
      "auto teams: the assistant making the team can't join it: a cycle against the active chain is refused with the reason")
    try check(reasons["Writer"]?.contains("already an assistant's name") == true,
      "auto teams: a member named like another assistant is refused alone, with the reason")
    let made = [id("Scout"), id("Booker")].compactMap { member in roster.profiles.first { $0.id == member } }
    try check(made.count == 2 && made.allSatisfy { $0.scope?.apps == [] && $0.scope?.destinations == [.web] },
      "auto teams: created members start with zero connected apps")
    try check(teams.bots.map(\.id) == made.map(\.id) && teams.bots.allSatisfy { $0.createdBy == serein.id && $0.parentTaskID == rootA },
      "auto teams: each created member carries createdBy and its parent (root) task")
    try check(try propose("Trip two", [member("Scout two", "RESEARCH")]).rejected.count == 1,
      "auto teams: a later team for the same root task can't take a role already filled")

    // The turn hands work to the team; Scout hands part on to Booker. Another hand-off has no team.
    let a1 = handoff("a1", to: id("Scout"))
    teams.link(chain: a1.id)
    let a2 = handoff("a2", to: id("Booker"), .waiting, parent: a1)
    let lone = handoff("lone", to: writer.id)
    var ledger = [a1, a2, lone]
    try check(teams.turnEnded(cancelled: false, handoffs: ledger).isEmpty && teams.bots.count == 2,
      "auto teams: a turn that ends done keeps its root task alive while a hand-off it sent is open")

    // Turn 2 makes another team and is stopped: its root task ends and everything under it stops.
    let rootB = teams.turnRoot()
    _ = try propose("Review", [member("Critic", "review")])
    let b1 = handoff("b1", to: id("Critic"))
    teams.link(chain: b1.id)
    let b2 = handoff("b2", to: id("Scout"), .waiting, parent: b1)
    ledger += [b1, b2]
    try check(rootB != rootA && teams.root(of: b2) == rootB && teams.root(of: a2) == rootA && teams.root(of: lone) == "lone",
      "auto teams: every hand-off belongs to the root task whose turn sent its chain")
    let cancelled = teams.turnEnded(cancelled: true, handoffs: ledger)
    try check(cancelled.handoffs == ["b1", "b2"] && cancelled.teammates == [id("Critic")],
      "auto teams: a stopped root task cancels its teammates and every hand-off under it, and nothing else")
    try check(teams.bots.map(\.parentTaskID) == [rootA, rootA], "auto teams: the other root task's teammates stay")
    ledger = ledger.map { ["b1", "b2"].contains($0.id) ? handoff($0.id, to: $0.to, .failed) : $0 }

    // Turn 1's work finishes: its root task ends, and its teammates stop.
    try check(teams.settle(ledger).isEmpty, "auto teams: a root task with a hand-off open does not end")
    ledger = ledger.map { $0.id == "a1" ? handoff("a1", to: $0.to, .done) : $0 }
    try check(teams.settle(ledger).isEmpty, "auto teams: a part still queued under a finished hand-off keeps its root task open")
    ledger = ledger.map { $0.id == "a2" ? handoff("a2", to: $0.to, .done, parent: a1) : $0 }
    let finished = teams.settle(ledger)
    try check(finished.teammates == [id("Scout"), id("Booker")] && finished.handoffs.isEmpty && teams.bots.isEmpty,
      "auto teams: a root task that ends done stops its teammates")
    try check(teams.settle(ledger).isEmpty && teams.stopAll(ledger).isEmpty, "auto teams: an ended root task stops nothing twice")

    // Stop Everything: every root task ends, the running turn's too; a hand-off with no team does not.
    let night = teams.turnRoot()
    _ = try propose("Night", [member("Owl", "watch")])
    let n1 = handoff("n1", to: id("Owl"), .waiting)
    teams.link(chain: n1.id)
    _ = try propose("Day", [member("Lark", "lookout")])
    // Lark's chat holds a hand-off from outside any team, so Lark keeps working on that one.
    let elsewhere = handoff("elsewhere", to: id("Lark"))
    try check(teams.root(of: n1) == night && teams.bots.count == 2, "auto teams: the running turn's teams share its root task")
    let all = teams.stopAll(ledger + [n1, elsewhere])
    try check(all.handoffs == ["n1"] && !all.handoffs.contains("lone") && !all.handoffs.contains("elsewhere"),
      "auto teams: Stop Everything cancels every hand-off under a root task and none outside one")
    try check(all.teammates == [id("Owl")], "auto teams: Stop Everything stops every teammate whose chat no other task holds")
    try check(teams.bots.isEmpty && teams.turn == nil, "auto teams: after Stop Everything no root task is left")
  }
}
#endif
