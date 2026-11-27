#if DEBUG
import Foundation
import SereinCore

/// Swarms (`Swarm`, RelaySwarm.swift): the pick from the hidden registry, then real swarms on a
/// Relay over a throwaway library. Seats are driven through the ledger and the shell's own close,
/// sweep and delivery, so no AI app runs.
extension AssistantCoreChecks {
  static func swarm(_ check: Check) throws {
    let claude = Provider.claude.rawValue, codex = Provider.codex.rawValue, gemini = Provider(.gemini).rawValue
    let opencode = Provider(.opencode).rawValue
    func row(_ engine: String, _ model: String, _ cost: ModelRoute.CostClass = .yourPlan, _ left: ModelRegistry.Remaining = .unknown,
             installed: Bool = true, modelTokens: Int = 0) -> ModelRegistry.Row {
      ModelRegistry.Row(route: ModelRoute(provider: engine, model: model, costClass: cost, caps: [.tools], installed: installed, reason: nil),
                        provider: engine, remaining: left, modelTokens5h: modelTokens)
    }
    let key = row(opencode, "serein-openrouter/openai/gpt-5", .yourKey, .fraction(1))
    let three = ModelRegistry(rows: [key, row(claude, "opus"), row(codex, "gpt-5"), row(gemini, "pro")])
    let two = ModelRegistry(rows: [key, row(claude, "opus"), row(codex, "gpt-5")])
    let tools = ModelRegistry.Need(tools: true)
    func names(_ routes: [ModelRoute]) -> [String] { routes.map(\.provider) }

    try check(names(Swarm.routes(three, need: tools, width: 3)) == [claude, codex, gemini],
      "swarm: three plans beside a key give three distinct models and no key")
    try check(names(Swarm.routes(two, need: tools, width: 3)) == [claude, codex],
      "swarm: two plans beside a key give two seats, never a repeat or the key")
    let used = ModelRegistry(rows: [row(claude, "opus", .yourPlan, .fraction(0.2)), row(codex, "gpt-5", .yourPlan, .fraction(0.9)), row(gemini, "pro")])
    try check(names(Swarm.routes(used, need: tools, width: 2)) == [gemini, codex],
      "swarm: usage left orders the pick (unknown counts as full, then 0.9 before 0.2)")
    let models = ModelRegistry(rows: [row(claude, "opus", modelTokens: 900), row(claude, "sonnet", modelTokens: 100)])
    try check(Swarm.routes(models, need: tools, width: 1).map(\.model) == ["sonnet"],
      "swarm: on one provider, the model that spent fewer tokens lately goes first")
    try check(Swarm.routes(ModelRegistry(rows: [key, row(claude, "opus", installed: false)]), need: tools, width: 3).isEmpty,
      "swarm: a route that bills each use or is not installed is never picked")
    try check(Swarm.width(asked: 3, routes: 2) == 2 && Swarm.width(asked: 5, routes: 4) == 3
        && Swarm.width(asked: 3, routes: 0) == 0,
      "swarm: the width is what was asked, at most three, one per route, with no cap per task")

    var tally = UsageTally()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    tally.noteSpent(UsageTally.modelKey(claude, "opus"), 700, at: now)
    let built = ModelRegistry.build(routes: [row(claude, "opus").route, row(claude, "sonnet").route], provider: \.provider,
                                    tally: tally, limited: [:], failed: [:], now: now)
    try check(built.rows.map(\.modelTokens5h) == [700, 0], "swarm: the registry reads each model's own spend")

    try MainActor.assumeIsolated {
      guard RelayOrchestrator.shared == nil else {
        try check(false, "swarm: no Relay runs before this suite starts one")
        return
      }
      let files = FileManager.default
      let root = files.temporaryDirectory.appendingPathComponent("serein-swarm-\(UUID().uuidString)", isDirectory: true)
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? files.removeItem(at: root) }
      let browser = try BrowserModel(root: root)
      try files.createDirectory(
        at: browser.library.root.appendingPathComponent("relay", isDirectory: true), withIntermediateDirectories: true)
      let agent = AgentModel(browser: browser, discoverProviders: false)
      // Installed for the pick; nothing here starts them. OpenCode too, so only the pay rule drops the key.
      for engine in [Provider.claude, .codex, Provider(.gemini), Provider(.opencode)] { agent.available[engine] = "/nonexistent/serein-check-" + engine.rawValue }
      let relay = RelayOrchestrator.start(agent: agent, browser: browser)
      defer { RelayOrchestrator.releaseForChecks(relay) }
      defer { relay.stopEverything(pause: true) }
      relay.networkOnline = { true }
      let lead = relay.profile(id: relay.team.activeID)
      let chat = relay.threadID

      @MainActor func saved() -> [AgentMessage] {
        chat == agent.conversationID ? agent.messages : agent.conversations.first { $0.id == chat }?.messages ?? []
      }
      @MainActor func count(_ id: String) -> Int { saved().filter { $0.id == id }.count }
      @MainActor func row(_ id: String) -> AssistantHandoff? { relay.handoffLedger.records.first { $0.id == id } }
      @MainActor func run(_ id: String, startedAt: Date = Date()) {
        guard let i = relay.handoffLedger.records.firstIndex(where: { $0.id == id }) else { return }
        relay.handoffLedger.records[i].state = .running
        relay.handoffLedger.records[i].startedAt = startedAt
        relay.handoffsStarting.remove(relay.handoffLedger.records[i].threadID)
      }
      /// A seat's run ends: its row closes, then results go back, as `finishHandoff` does.
      @MainActor func end(_ id: String, _ state: AssistantHandoff.State = .done) {
        run(id)
        relay.closeHandoff(id, state, result: state == .done ? "Seat answer " + id : "It could not finish.")
        relay.deliverHandoffReports()
      }
      /// The lead's merged turn, once launched, ends with its one answer.
      @MainActor func merge(_ holder: AssistantHandoff) {
        relay.handoffsStarting.remove(holder.threadID)
        relay.closeHandoff(holder.id, .done, result: "Merged answer " + holder.id)
        relay.deliverHandoffReports()
      }
      @MainActor func ask(_ words: String) -> String {
        var message = AgentMessage(role: "you", text: words)
        message.id = "swarm-ask-" + UUID().uuidString
        relay.post(message, into: chat)
        return message.id
      }
      @MainActor func start(_ count: Int, _ registry: ModelRegistry) -> (seats: [AssistantHandoff], line: String)? {
        guard case .started(let seats, let line) = relay.startSwarm("Compare the plans", count: count, lead: lead, parent: nil, chat: chat,
                                                                  registry: registry) else { return nil }
        return (seats, line)
      }
      /// The merged answer and nothing else of the swarm's in the chat, once each.
      @MainActor func answered(_ holder: AssistantHandoff, _ seats: [AssistantHandoff], re message: String) -> Bool {
        let answer = saved().filter { $0.id == HandoffReport.postID(holder.id) }
        return answer.count == 1 && answer[0].from == lead.id && answer[0].re == message && answer[0].notice != true
          && answer[0].text.contains("Merged answer") && row(holder.id)?.reported == true
          && seats.allSatisfy { seat in count(HandoffReport.postID(seat.id)) == 0 && count(RelayOrchestrator.handoffPostID(seat.id)) == 0
            && row(seat.id)?.reported == true }
      }

      // 1. Three plans: three seats on three models, one line, then one merged answer.
      let first = ask("Which plan should I pick?")
      let longTask = "Compare the three annual plans across price, team seat limits, export formats, offline support, audit logs, and migration effort; return one recommendation table with concrete trade-offs. REQUIREMENT_TAIL_9876"
      guard case .started(let longSeats, _) = relay.startSwarm(longTask, count: 3, lead: lead, parent: nil, chat: chat, registry: three),
        let holderID = longSeats.first?.parentID, let holder = row(holderID)
      else {
        try check(false, "swarm: three plans start a swarm")
        return
      }
      let swarm = (seats: longSeats, line: "")
      let routes = swarm.seats.compactMap(\.route)
      try check(Set(routes.map(\.provider)) == [claude, codex, gemini] && routes.count == 3 && holder.side == .swarmLead
          && swarm.seats.allSatisfy { $0.side == .swarm && $0.parentID == holder.id },
        "swarm: a swarm of three gets three distinct models under one lead row [\(routes)]")
      let line = saved().filter { $0.id == "swarm-" + swarm.seats[0].id }
      try check(line.count == 1 && line[0].from == lead.id && line[0].re == first && line[0].notice == true
          && line[0].text == "Asked 3 models at once: opus, gpt-5 and pro.",
        "swarm: its one line answers the person's message, from the lead [\(line.map(\.text))]")
      end(swarm.seats[0].id)
      end(swarm.seats[1].id, .failed)
      try check(!relay.handoffsStarting.contains(holder.threadID) && row(swarm.seats[0].id)?.reported != true,
        "swarm: the merged turn waits while a seat is out, and the results wait with it")
      end(swarm.seats[2].id)
      let mergePrompt = relay.resultsPrompt(holder, swarm.seats.compactMap { row($0.id) })
      try check(mergePrompt.contains("The original task:\n" + longTask) && mergePrompt.contains("REQUIREMENT_TAIL_9876"),
        "swarm: the lead's merge prompt carries the full original task beyond 120 characters")
      try check(relay.handoffsStarting.contains(holder.threadID) && swarm.seats.allSatisfy { row($0.id)?.reported == true },
        "swarm: once every seat is back, even a failed one, the lead's one merged turn starts with every result")
      merge(holder)
      relay.closeHandoff(holder.id, .done, result: "Merged answer again")
      _ = relay.landReport(row(holder.id) ?? holder)
      relay.sweepHandoffs()
      try check(answered(holder, swarm.seats, re: first),
        "swarm: one merged answer lands once, as the lead's reply, and no seat's words post")

      // 2. Two plans: two seats, said in its line, and it still finishes.
      let second = ask("Draft the toast")
      guard let small = start(3, two), let smallHolder = small.seats.first.flatMap({ $0.parentID }).flatMap(row) else {
        try check(false, "swarm: two plans start a swarm")
        return
      }
      try check(small.seats.count == 2 && Set(small.seats.compactMap(\.route?.provider)) == [claude, codex]
          && small.line.hasSuffix("Only 2 of 3 could take a seat now."),
        "swarm: with only two models it seats two and says so [\(small.line)]")
      small.seats.forEach { end($0.id) }
      merge(smallHolder)
      try check(answered(smallHolder, small.seats, re: second), "swarm: a swarm of two still finishes with one answer")

      // 3. A late seat: the sweep closes it with what it had; its run's late end posts nothing.
      let third = ask("Plan the trip")
      guard let slow = start(2, three), let slowHolder = slow.seats.first.flatMap({ $0.parentID }).flatMap(row) else {
        try check(false, "swarm: a third swarm starts")
        return
      }
      end(slow.seats[1].id)
      run(slow.seats[0].id, startedAt: Date().addingTimeInterval(-Swarm.timeCap - 60))
      relay.sweepHandoffs()
      try check(row(slow.seats[0].id)?.result?.hasPrefix(Swarm.lateWords) == true && relay.handoffsStarting.contains(slowHolder.threadID),
        "swarm: a seat past the time cap closes, and the merged turn goes on without it")
      var spec = RunSpec(threadID: slow.seats[0].threadID, provider: .claude, executable: "/usr/bin/false", model: "opus", effort: "low",
        mode: .answer, projectID: nil, projectName: nil, title: "Check", scope: "", autoRouting: false, grants: RunGrants(),
        limits: RunLimits(hard: 600, idle: 600))
      spec.initiator = .handoff
      let late = AgentRun(spec: spec, taskID: "swarm-late", transcript: [AgentMessage(role: "assistant", text: "LATE SEAT WORDS 2718")])
      try check(relay.finishHandoff(late), "swarm: the late run's end is the hand-off's")
      _ = relay.postReport(row(slow.seats[0].id) ?? slow.seats[0])
      merge(slowHolder)
      try check(answered(slowHolder, slow.seats, re: third) && !saved().contains { $0.text.contains("LATE SEAT WORDS 2718") },
        "swarm: a late seat does not double-post, and its words never reach the chat")

      // 4. The usage tap counts each seat's tokens against its model.
      late.record.tokens = 1_234
      relay.tallyUsage(late)
      try check(relay.usageTally.tokens(UsageTally.modelKey(claude, "opus"), now: Date()) == 1_234,
        "swarm: a seat's tokens count against its model in the registry")

      // 5. At the cap: two delegated runs hold seats, so two of three wait, said in its line, and none is lost.
      var held: [String] = []
      for k in 0..<2 {
        var busy = AssistantHandoff(from: lead.id, to: lead.id, task: "busy \(k)", threadID: "seat-swarm-busy-\(k)", askedIn: chat,
                                    team: "", teamName: "", state: .running)
        busy.side = .busy
        relay.handoffLedger.admit(busy, now: Date())
        held.append(busy.id)
      }
      let fourth = ask("Sum up my week")
      guard let capped = start(3, three), let cappedHolder = capped.seats.first.flatMap({ $0.parentID }).flatMap(row) else {
        try check(false, "swarm: a swarm at the cap starts")
        return
      }
      try check(capped.seats.count == 3 && capped.line.hasSuffix("2 wait for a free seat and start when one frees."),
        "swarm: at the cap, the swarm waits with a notice [\(capped.line)]")
      for id in held {
        guard let i = relay.handoffLedger.records.firstIndex(where: { $0.id == id }) else { continue }
        relay.handoffLedger.records[i].state = .done
        _ = relay.handoffLedger.claimReport(id)
      }
      end(capped.seats[0].id)
      relay.startWaitingHandoffs()
      try check(capped.seats.dropFirst().allSatisfy { relay.handoffsStarting.contains($0.threadID) },
        "swarm: the waiting seats start once seats free")
      capped.seats.dropFirst().forEach { end($0.id) }
      merge(cappedHolder)
      try check(answered(cappedHolder, capped.seats, re: fourth), "swarm: a swarm that waited loses nothing and answers once")

      // 6. Refusals seat nothing.
      let rows = relay.handoffLedger.records.count
      guard case .refused(let none) = relay.startSwarm("Again", count: 3, lead: lead, parent: nil, chat: chat, registry: ModelRegistry(rows: [key])),
        case .refused(let deep) = relay.startSwarm("Again", count: 3, lead: lead, parent: capped.seats[0], chat: chat, registry: three)
      else {
        try check(false, "swarm: no route, and a seat's own swarm, are refused")
        return
      }
      try check(none == Swarm.noRouteWords && deep == Swarm.deepWords && relay.handoffLedger.records.count == rows,
        "swarm: only a key left, or a seat asking, seats nothing [\(none) | \(deep)]")
    }
  }
}
#endif
