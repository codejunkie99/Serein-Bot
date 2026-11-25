#if DEBUG
import Foundation
import SereinCore

/// Hand-offs that are handed on (AssistantHandoff, HandoffLedger in SereinCore/AssistantTeams.swift):
/// the chain a link records, who may still be asked, when a link may close. Synthetic data only.
extension AssistantCoreChecks {
  static func handoffChain(_ check: Check) throws {
    typealias L = HandoffLedger
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func link(_ id: String, _ from: String, _ to: String, parent: AssistantHandoff? = nil,
              state: AssistantHandoff.State = .running) -> AssistantHandoff {
      AssistantHandoff(id: id, from: from, to: to, task: "Task", threadID: "chat-" + to, askedIn: "chat-" + from,
                       team: "", teamName: "All assistants", createdAt: now, state: state, parent: parent)
    }
    func refusal(_ ledger: L, _ parent: AssistantHandoff, to: String) -> String? {
      ledger.chainRefusal(parent: parent, fromName: parent.to, to: to, toName: to)
    }

    let root = link("r", "serein", "writer")
    let child = link("c", "writer", "editor", parent: root)
    let grandchild = link("g", "editor", "scout", parent: child)
    try check(root.rootID == nil && root.parentID == nil && root.holders == ["serein", "writer"], "A root holds its sender and its target")
    try check(child.rootID == "r" && child.parentID == "r" && child.chain == ["serein", "writer"],
      "A hand-off sent from a hand-off records its parent, its root and the chain so far")
    try check(grandchild.rootID == "r" && grandchild.parentID == "c" && grandchild.holders == ["serein", "writer", "editor", "scout"],
      "A third link keeps the first root and grows the chain in order")
    try check(AssistantHandoff.chainWords(["Serein"]) == "Serein asked you"
      && AssistantHandoff.chainWords(["Serein", "Writer"]) == "Serein asked Writer, who asked you",
      "The target's prompt says the chain in order")


    let chain = L(records: [root, child])
    try check(refusal(chain, child, to: "serein")?.contains("Reply with what you have") == true, "Work never goes back to the first sender")
    try check(refusal(chain, child, to: "writer") != nil, "Work never goes back to the assistant that asked")
    try check(refusal(chain, child, to: "editor") != nil, "An assistant never hands work to itself")
    try check(refusal(chain, child, to: "scout") == nil, "An assistant outside the chain can be asked")
    // Another task's chain the other way round: Scout holds its chat for Editor, so Editor's
    // hand-off to Scout would wait for a chat that waits for it.
    let other = link("o", "ana", "scout")
    let back = link("b", "scout", "editor", parent: other, state: .waiting)
    try check(refusal(L(records: [root, child, other, back]), child, to: "scout")?.contains("waiting on") == true,
      "Two assistants never wait on each other across tasks")
    try check(refusal(L(records: [root, child, other]), child, to: "scout") == nil, "A busy assistant that waits on nobody can be asked")

    try check(refusal(L(records: [root, child, grandchild]), grandchild, to: "ana")?.contains("\(L.maxChain) assistants") == true,
      "A fifth assistant on one task is refused")

    var wide = L(records: [root])
    for i in 1..<L.maxPerRoot { wide.records.append(link("w\(i)", "writer", "editor", parent: root, state: .done)) }
    try check(refusal(wide, root, to: "scout")?.contains("\(L.maxPerRoot) times") == true, "A ninth hand-off under one root is refused")
    wide.records.removeLast()
    try check(refusal(wide, root, to: "scout") == nil, "The eighth hand-off under one root is allowed")
    // Closed hand-offs of other tasks, newer than this task's closed parts and more than the ledger keeps.
    var long = L(records: [root])
    for i in 1..<L.maxPerRoot { long.records.append(link("w\(i)", "writer", "editor", parent: root, state: .done)) }
    for i in 0...L.kept { long.records.append(link("x\(i)", "ana", "scout", state: .done)) }
    long.trim(now: now)
    try check(refusal(long, root, to: "scout")?.contains("\(L.maxPerRoot) times") == true,
      "A ninth hand-off under one root is still refused after the ledger trims its closed records")
    long.records[0].state = .done
    long.trim(now: now)
    try check(long.records.count == L.kept, "Once a task has ended, its closed parts are trimmed like any other")

    func parentClosable(_ state: AssistantHandoff.State, reported: Bool) -> Bool {
      var ledger = L(records: [root, link("c", "writer", "editor", parent: root, state: state)])
      if reported { _ = ledger.claimReport("c") }
      return ledger.closable("r")
    }
    try check(L(records: [root]).closable("r"), "A hand-off that handed nothing on may close")
    try check(!parentClosable(.waiting, reported: true) && !parentClosable(.running, reported: true),
      "A hand-off stays open while what its target handed on is open")
    for state: AssistantHandoff.State in [.done, .failed, .expired] {
      try check(!parentClosable(state, reported: false), "A part that ended \(state.rawValue) holds its parent until its result is back")
      try check(parentClosable(state, reported: true), "A part that ended \(state.rawValue), its result back, lets its parent close")
    }
    try check(L(records: [root, child]).closable("c"), "The last link may close while its parent waits")

    var queued = L(records: [root, link("c", "writer", "editor", parent: root, state: .waiting)])
    let gone = queued.expire(now: now.addingTimeInterval(L.queueExpiry + 1))
    try check(gone.map(\.id) == ["c"] && queued.records[0].state == .running, "Only the part that waited expires, never its parent")
    _ = queued.claimReport("c")
    try check(queued.closable("r"), "An expired part, once told to its parent, lets it close")

    // Stop Everything with Serein → Writer → Editor, a part of Editor's still queued for Scout,
    // and another task's hand-off queued on its own.
    var stopped = L(records: [root, child, link("p", "editor", "scout", parent: child, state: .waiting), link("a", "ana", "planner", state: .waiting)])
    let ended = stopped.stop(now: now)
    try check(ended.map(\.id) == ["r", "c", "p"] && ended.allSatisfy { $0.state == .failed && $0.result == L.stoppedWords && $0.finishedAt == now },
      "Stop Everything ends every link of a chain, the one that only waited for its part included")
    try check(!stopped.records.contains { $0.parentID != nil && $0.reported != true }
      && stopped.running(thread: "chat-writer") == nil && stopped.running(thread: "chat-editor") == nil,
      "No stopped part is left whose result would start the hand-off above it again")
    try check(stopped.records[0].reported == true, "A stopped hand-off starts no turn in the chat that asked")
    let again = stopped.stop(now: now)
    try check(stopped.records[3].state == .waiting && again.isEmpty, "A hand-off queued on its own keeps waiting")

    let late = now.addingTimeInterval(L.stallAfter + 1)
    var waiting = L(records: [root, link("c", "writer", "editor", parent: root, state: .waiting)])
    try check(waiting.stall(now: late, live: []).isEmpty, "A hand-off that only waits on what it handed on is not stuck")
    var both = L(records: [root, child])
    try check(both.stall(now: late, live: ["chat-editor"]).map(\.id) == ["c"], "The link that works is the one that can be stuck")
    var hung = L(records: [root, child])
    try check(hung.stall(now: late, live: ["chat-writer"]).contains { $0.id == "r" }, "A hand-off whose own run shows no progress is stuck, whatever it handed on")
    waiting.records[1].state = .done
    _ = waiting.claimReport("c")
    try check(waiting.stall(now: late, live: []).map(\.id) == ["r"], "Once its parts are back, a hand-off with no progress is stuck again")

    let next = link("n", "ana", "writer", state: .waiting)
    try check(L(records: [next, root]).running(thread: "chat-writer")?.id == "r" && L(records: [next]).running(thread: "chat-writer") == nil,
      "The hand-off that holds a chat is the running one")

    let old = """
      {"records":[{"id":"old","from":"serein","to":"writer","task":"Draft it","threadID":"t1","askedIn":"t0","team":"",
      "teamName":"All assistants","createdAt":"2026-11-01T10:00:00Z","state":"running","personal":true}],"daily":{"|2026-11-01":1}}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(L.self, from: Data(old.utf8))
    let first = saved.records[0]
    try check(first.rootID == nil && first.parentID == nil && first.chain == nil && first.holders == ["serein", "writer"] && saved.closable("old"),
      "A ledger saved before chains reads as roots")
    try check(AssistantHandoff(from: "writer", to: "editor", task: "t", threadID: "t2", askedIn: "t1", team: "", teamName: "", parent: first).rootID == "old",
      "A hand-off from before chains can still be handed on")

    let offered = Set(ToolSchema.everyTool(["--team"]).compactMap { $0["name"] as? String })
    try check(offered.contains("assistant_handoff") && offered.isDisjoint(with: RelayTools.names),
      "A hand-off's own run is offered assistant_handoff and no other Relay tool")

    let step = AgentStep.label(tool: "assistant_handoff", arguments: ["to": "Scout"])
    try check(step == "Handed work to Scout" && RunNow.present(step) == "Handing work to Scout",
      "A hand-off step names its teammate, so a refused one reads Not done: Handed work to Scout")
    let done = link("d", "scout", "planner", state: .done)
    try check(HandoffRows.showsCard(done), "A finished hand-off shows its result card until the asking assistant has it")
    var shown = L(records: [done])
    try check(shown.claimReport("d").map { !HandoffRows.showsCard($0) } == true,
      "Once the asking assistant's reply has the result, the card is not shown again")

    // Report delivery (TEAMS-V2 §4.8): `claimReport` is the only writer of `reported`.
    var claims = L(records: [root, link("c", "writer", "editor", parent: root, state: .running), done])
    try check(claims.claimReport("c") == nil && claims.claimReport("r") == nil, "An open hand-off's report cannot be claimed")
    try check(claims.claimReport("d")?.reported == true, "A finished hand-off's report is claimed")
    let once = claims
    try check(claims.claimReport("d") == nil && claims == once, "A second claim of the same report is a no-op")

    // A crash with the report sealed but unclaimed: each relaunch sweeps the saved ledger, and the
    // report is delivered once over all of them.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var disk = try encoder.encode(L(records: [done, link("f", "scout", "planner", state: .failed)]))
    var delivered: [String] = []
    for _ in 0..<3 {
      var relaunched = try decoder.decode(L.self, from: disk)
      delivered += relaunched.records.filter { !$0.isOpen }.compactMap { relaunched.claimReport($0.id)?.id }
      disk = try encoder.encode(relaunched)
    }
    try check(delivered == ["d", "f"], "The launch sweep after a crash delivers each sealed report once")

    // The reader's wake turn is keyed by the report: a replay of it posts nothing.
    var posts: [String] = []
    var woken = L(records: [done])
    for _ in 0..<2 {
      if let report = woken.claimReport("d") {
        posts.append(HandoffReport(handoff: report.id, packet: 1, state: .done, summary: report.result ?? "", byHost: true).postID)
      }
    }
    try check(posts == ["handoff-report-d"], "A replayed wake turn posts nothing")
    try check(HandoffRows.showsCard(link("f", "scout", "planner", state: .failed)), "A failed hand-off keeps its card and its fixes")
  }
}
#endif
