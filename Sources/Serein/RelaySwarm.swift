import Foundation
import SereinCore

/// Swarms (`Swarm`, SereinCore/Swarm.swift): `swarm_start` seats up to three copies of the lead,
/// each on a different model the hidden registry picks by usage left. The seats are hand-off rows
/// under one parent, so the seat cap, the packet and `claimReport` are the hand-off's own. When
/// every seat is back (or past `Swarm.timeCap`), the parent gets one merged results turn
/// (`deliverChainResults`), and only its answer posts in the chat.
extension RelayOrchestrator {
  enum SwarmStart {
    /// Nothing was seated: the words the lead follows.
    case refused(String)
    case started(seats: [AssistantHandoff], line: String)
  }

  /// The routes a swarm may seat now: the registry's (or `registry`), only an AI app that thinks
  /// for Serein on this Mac, with Serein's tools, never one that bills each use (`Swarm.routes`).
  func swarmRoutes(width: Int, registry: ModelRegistry? = nil) -> [ModelRoute] {
    let rows = (registry ?? modelRegistry()).rows.filter {
      let engine = Provider(rawValue: $0.route.provider)
      return engine.thinksForSerein && agent.available[engine] != nil
    }
    return Swarm.routes(ModelRegistry(rows: rows), need: .init(tools: true), width: width)
  }

  /// `lead` fans `task` out to a swarm. `parent`: the hand-off whose run asks, from the chat it
  /// holds; its next turn is the merged one. Without one (Serein's or an assistant's own turn in
  /// `chat`), a lead row holds the seats and its merged answer posts as the lead's reply to the
  /// person's message. Seats past the free seat cap wait, and the swarm's line says so.
  func startSwarm(_ task: String, count: Int, lead: RelayProfile, parent: AssistantHandoff?, chat: String,
                  registry: ModelRegistry? = nil) -> SwarmStart {
    if parent?.side == .swarm { return .refused(Swarm.deepWords) }
    let routes = swarmRoutes(width: min(count, Swarm.cap), registry: registry)
    let width = Swarm.width(asked: count, routes: routes.count)
    guard width > 0 else { return .refused(Swarm.noRouteWords) }

    let holder = parent ?? openSwarmLead(task, lead: lead, chat: chat)
    var seats: [AssistantHandoff] = []
    for route in routes.prefix(width) {
      seats.append(sendHandoff(
        from: lead, to: lead, task: task, team: "", teamName: "All assistants", parent: holder, how: .auto, side: .swarm,
        route: AssistantRoute(provider: route.provider, model: route.model)))
    }
    // Seats past the free cap wait in the queue (`startWaitingHandoffs`); the line counts them.
    let waiting = seats.filter { record in handoffLedger.records.first { $0.id == record.id }?.state == .waiting
      && !handoffsStarting.contains(record.threadID) }.count
    let line = Swarm.line(models: seats.compactMap(\.route).map(Self.routeName), asked: count, waiting: waiting)
    var post = AgentMessage(role: "assistant", text: line, notice: true)
    post.id = "swarm-" + (seats.first?.id ?? holder.id)
    post.from = lead.id
    post.re = holder.mention?.post ?? Self.handoffPostID(holder.id)
    channelPost(post, into: originChat(holder))
    return .started(seats: seats, line: line)
  }

  /// The row that holds a swarm started from a turn of the lead's own: running from the start
  /// with no run of its own, it waits for its seats, then takes their results as its one turn.
  /// It answers the person's message (or the swarm's line), so its report is the lead's reply.
  private func openSwarmLead(_ task: String, lead: RelayProfile, chat: String) -> AssistantHandoff {
    var record = AssistantHandoff(
      from: lead.id, to: lead.id, task: task, threadID: "", askedIn: chat, team: "", teamName: "All assistants", state: .running)
    record.threadID = Self.seatThread(record.id)
    record.startedAt = record.createdAt
    record.progressAt = record.createdAt
    record.side = .swarmLead
    let message = lastPersonMessage(chat) ?? "handoff-" + record.id
    record.mention = .byPerson(message: message)
    if agent.readsPersonal(thread: chat) { record.personal = true }
    record = pack(record, root: .chat(thread: chat, message: message), sender: agent.hub.run(for: chat))
    handoffLedger.admit(record, now: Date())
    saveHandoffs()
    return record
  }

  /// A seat's model as the chat names it.
  static func routeName(_ route: AssistantRoute) -> String {
    route.model.isEmpty ? Provider(rawValue: route.provider).name : route.model
  }
}

extension RelayToolHost {
  /// `swarm_start {task, count}`: the calling assistant (a hand-off's target from its run, else the
  /// turn's own) fans `task` out to up to three seats of itself on different models, with no card.
  /// A refusal is the sentence the model follows.
  func swarmStart(_ a: [String: Any], handoffChat: String? = nil) async throws -> [String: Any] {
    let parent = handoffChat.flatMap { relay.handoffLedger.running(thread: $0) }
    let lead: RelayProfile
    if handoffChat != nil {
      guard let target = relay.team.profiles.first(where: { $0.id == parent?.to }) else {
        throw SereinError.invalid("That hand-off is no longer open, so no swarm started.")
      }
      lead = target
    } else {
      lead = relay.profile(id: frame.profile)
    }
    guard let task = (a["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else {
      throw SereinError.invalid("task is required: everything a seat needs, since it does not see this chat.")
    }
    guard task.count <= HandoffLedger.taskLimit else {
      throw SereinError.invalid("The task is longer than \(HandoffLedger.taskLimit) characters. Shorten it and start the swarm again.")
    }
    let count = (a["count"] as? NSNumber)?.intValue ?? Swarm.cap
    switch relay.startSwarm(task, count: max(count, 1), lead: lead, parent: parent, chat: parent?.threadID ?? frame.thread) {
    case .refused(let words):
      return ["carry_on": words, "note": "Nothing changed. Follow these words; do not ask the person."]
    case .started(let seats, let line):
      let next = parent == nil ? "Tell the user in one line that it started, then end this turn. The merged answer posts in the chat on its own."
        : "Every seat's answer starts your next turn here, together. End this turn in one line."
      return [
        "seats": seats.map { ["seat": $0.id, "model": $0.route.map(RelayOrchestrator.routeName) ?? "", "state": $0.state.rawValue] },
        "posted": line, "note": next,
      ]
    }
  }
}
