import Foundation

/// Swarms (`Swarm`, Sources/Serein/RelaySwarm.swift): one lead row and its seats under every order
/// of seats starting, ending, crashing, running past the time cap and ending late, delegated runs
/// taking the shared cap, the lead's merged turn, a stop and a relaunch. Each step copies one
/// shell function and runs the shipped reducers (`Swarm.routes`, `Swarm.width`, `SideSeat.free`,
/// `HandoffLedger.swarmWaits`, `late`, `closable`, `claimReport`).
struct SwarmWorld: Codable, Equatable {
  /// The registry the swarm started on (`Config.registries`); nil before it starts.
  var registry: Int?
  var ledger = HandoffLedger()
  var delegated = 0
  /// Seat threads whose run is alive (the lead's merged turn is `merging`).
  var alive: [String] = []
  /// Seats the clock took past `Swarm.timeCap`.
  var past: [String] = []
  var merging = false
  var merges = 0
  /// Posts saved in the origin chat.
  var chat: [String] = []
  /// `claimReport` calls that claimed, per row.
  var claims: [String: Int] = [:]
  var stopped = false
  var relaunches = 0

  static let t0 = Date(timeIntervalSince1970: 0)
  static let lead = "L"

  var key: String { (try? String(data: swarmEncoder.encode(self), encoding: .utf8)) ?? "" }
  var seats: [AssistantHandoff] { ledger.records.filter { $0.side == .swarm } }
  var seated: Int { ledger.records.filter { $0.side?.takesSeat == true && $0.state == .running }.count }
  var free: Bool { SideSeat.free(seated: seated, delegated: delegated) }
  func index(_ id: String) -> Int { ledger.records.firstIndex { $0.id == id } ?? -1 }

  mutating func claim(_ id: String) {
    if ledger.claimReport(id) != nil { claims[id, default: 0] += 1 }
  }
  /// `closeHandoff` → `landReport`: a seat's report lands with no post; the lead's posts once.
  mutating func close(_ id: String, _ state: AssistantHandoff.State) {
    let i = index(id)
    guard i >= 0, ledger.records[i].isOpen else { return }
    ledger.records[i].state = state
    ledger.records[i].result = state == .done ? "answer" : "failed"
    ledger.records[i].posted = false
    if ledger.records[i].side != .swarm, !chat.contains(HandoffReport.postID(id)) { chat.append(HandoffReport.postID(id)) }
    ledger.records[i].posted = true
  }
  /// `finishHandoff` for a run that ended in `thread`: nothing when its row already closed.
  mutating func finish(thread: String, _ state: AssistantHandoff.State) {
    guard let record = ledger.running(thread: thread), ledger.closable(record.id) else { return }
    close(record.id, state)
    // deliverHandoffReports: a tagged root's report is its answer, claimed once it landed.
    if record.side == .swarmLead { claim(record.id) }
  }
  /// `startWaitingHandoffs`: each waiting seat, oldest first, under the cap.
  mutating func startWaiting() {
    for i in ledger.records.indices where ledger.records[i].state == .waiting && ledger.records[i].side == .swarm && free {
      ledger.records[i].state = .running
      ledger.records[i].startedAt = Self.t0
      alive.append(ledger.records[i].threadID)
    }
  }

  struct Config {
    /// Each registry the swarm may start on: three plans and a key with the most left, and two
    /// plans and a key (fewer models than asked).
    var registries: [ModelRegistry] = {
      func row(_ engine: String, _ cost: ModelRoute.CostClass = .yourPlan, left: ModelRegistry.Remaining = .unknown) -> ModelRegistry.Row {
        .init(route: ModelRoute(provider: engine, model: engine + "-model", costClass: cost, caps: [.tools], installed: true, reason: nil),
              provider: engine, remaining: left)
      }
      let key = row("openrouter", .yourKey, left: .fraction(1))
      return [
        ModelRegistry(rows: [key, row("claude", left: .fraction(0.2)), row("codex"), row("gemini", left: .fraction(0.6))]),
        ModelRegistry(rows: [key, row("claude"), row("codex", left: .limited(until: t0.addingTimeInterval(3_600))), row("gemini")]),
      ]
    }()
    var delegated = 2
    var relaunches = 1
  }

  static func steps(_ c: Config) -> (SwarmWorld) -> [(label: String, next: SwarmWorld)] {
    { w in
      var out: [(String, SwarmWorld)] = []
      func step(_ label: String, _ change: (inout SwarmWorld) -> Void) {
        var n = w
        change(&n)
        out.append((label, n))
      }
      guard w.registry != nil else {
        // startSwarm from the lead's own turn: its lead row, then a seat per route picked.
        for (r, registry) in c.registries.enumerated() {
          step("swarm starts on registry \(r)") { n in
            n.registry = r
            let routes = Swarm.routes(registry, need: .init(tools: true), width: Swarm.cap)
            var lead = AssistantHandoff(id: lead, from: "serein", to: "serein", task: "t", threadID: "seat-L", askedIn: "chat",
                                        team: "", teamName: "", createdAt: t0, state: .running)
            lead.side = .swarmLead
            lead.mention = .byPerson(message: "m")
            n.ledger.admit(lead, now: t0)
            for (k, route) in routes.prefix(Swarm.width(asked: Swarm.cap, routes: routes.count, underRoot: 1)).enumerated() {
              var seat = AssistantHandoff(id: "s\(k)", from: "serein", to: "serein", task: "t", threadID: "seat-s\(k)", askedIn: "seat-L",
                                          team: "", teamName: "", createdAt: t0, parent: lead)
              seat.side = .swarm
              seat.route = AssistantRoute(provider: route.provider, model: route.model)
              n.ledger.admit(seat, now: t0)
              n.startWaiting()
            }
          }
        }
        if w.delegated < c.delegated { step("delegated run starts") { $0.delegated += 1 } }
        return out
      }
      for seat in w.seats {
        let id = seat.id, thread = seat.threadID, live = w.alive.contains(thread)
        if seat.state == .waiting, w.free {
          step("\(id) starts") { n in
            n.ledger.records[n.index(id)].state = .running
            n.ledger.records[n.index(id)].startedAt = t0
            n.alive.append(thread)
          }
        }
        if live {
          // Its run ends: done, or late after the sweep closed it, when it closes nothing.
          step("\(id)'s run ends") { n in
            n.alive.removeAll { $0 == thread }
            n.finish(thread: thread, .done)
          }
          step("\(id)'s run crashes") { $0.alive.removeAll { $0 == thread } }
        }
        if seat.state == .running, !w.past.contains(id) { step("\(id) runs past the time cap") { $0.past.append(id) } }
        // sweepHandoffs: a late seat closes with what it had; a running one with no run closes failed.
        if seat.state == .running, w.past.contains(id),
          w.ledger.late(now: t0.addingTimeInterval(Swarm.timeCap)).contains(where: { $0.id == id }) {
          step("sweep closes \(id), late") { $0.close(id, .failed) }
        }
        if seat.state == .running, !live, w.ledger.closable(id) { step("sweep closes \(id), its run gone") { $0.close(id, .failed) } }
      }
      // deliverChainResults: every result under the lead, in one turn, once no seat is open.
      let due = w.seats.filter { !$0.isOpen && $0.reported != true }.map(\.id)
      if !due.isEmpty {
        let lead = w.ledger.records[w.index(lead)]
        if lead.state != .running {
          step("results drop, the lead closed") { n in for id in due { n.claim(id) } }
        } else if !w.merging, !w.ledger.swarmWaits(lead.id) {
          step("lead's merged turn starts") { n in
            for id in due { n.claim(id) }
            n.merges += 1
            n.merging = true
          }
        }
      }
      if w.merging {
        step("lead's merged turn ends") { n in
          n.merging = false
          n.finish(thread: "seat-L", .done)
        }
        step("lead's merged turn crashes") { $0.merging = false }
      }
      let lead = w.ledger.records[w.index(lead)]
      if lead.state == .running, !w.merging, w.ledger.closable(lead.id) {
        step("sweep closes the lead, its run gone") { n in
          n.close(SwarmWorld.lead, .failed)
          n.claim(SwarmWorld.lead)
        }
      }
      // stopSeats: the lead closes and its open seats with it (a running one when its run ends).
      if !w.stopped, lead.isOpen {
        step("person stops the swarm") { n in
          n.stopped = true
          n.close(SwarmWorld.lead, .failed)
          n.claim(SwarmWorld.lead)
          for seat in n.seats where seat.state == .waiting || (seat.state == .running && !n.alive.contains(seat.threadID)) {
            n.close(seat.id, .failed)
            n.claim(seat.id)
          }
        }
      }
      if w.delegated < c.delegated { step("delegated run starts") { $0.delegated += 1 } }
      if w.delegated > 0 {
        step("delegated run ends") { $0.delegated -= 1 }
      }
      if w.relaunches < c.relaunches {
        step("relaunch") { n in
          n.relaunches += 1
          n.alive = []
          n.merging = false
          n.delegated = 0
        }
      }
      return out
    }
  }
}

private let swarmEncoder: JSONEncoder = {
  let e = JSONEncoder()
  e.outputFormatting = .sortedKeys
  return e
}()

enum SwarmMachine {
  static let config = SwarmWorld.Config()
  static let answer = HandoffReport.postID(SwarmWorld.lead)

  static var machine: FormalMachine<SwarmWorld> {
    FormalMachine(
      name: "swarm",
      bounds: "1 lead, registries of 3 and 2 plans beside a key, cap \(SideSeat.cap), up to 2 delegated runs, late and crashed seats, 1 stop, 1 relaunch",
      start: SwarmWorld(), steps: SwarmWorld.steps(config),
      invariants: [
        ("at most \(Swarm.cap) seats run at once", { w in w.seated <= Swarm.cap }),
        ("each seat reports at most once", { w in w.claims.values.allSatisfy { $0 <= 1 } }),
        ("the lead gets at most one merged turn", { w in w.merges <= 1 }),
        ("the merged answer posts at most once, and no seat's words post", { w in
          w.chat.filter { $0 == answer }.count <= 1 && w.chat.allSatisfy { $0 == answer }
        }),
        ("seats run on distinct models, never one that bills each use, as many as can take one", { w in
          guard let r = w.registry else { return true }
          let routes = w.seats.compactMap(\.route).map { $0.provider + ":" + $0.model }
          let usable = config.registries[r].rows.filter { !LimitFailover.billsEachUse($0.route) && $0.usable(.init(tools: true)) }
          return Set(routes).count == routes.count && routes.count == min(Swarm.cap, usable.count)
            && !w.seats.contains { $0.route?.provider == "openrouter" }
        }),
      ],
      transitions: [
        ("a seat starts only when one is free", { before, _, after in after.seated <= before.seated || before.free }),
        ("the merged turn starts only once every seat is back", { _, label, after in
          label != "lead's merged turn starts" || !after.seats.contains(where: \.isOpen)
        }),
      ],
      eventually: [("the merged answer posts exactly once", { w in
        w.registry != nil && !w.merging && w.alive.isEmpty
          && w.chat.filter { $0 == answer }.count == 1
          && w.ledger.records.allSatisfy { !$0.isOpen && $0.reported == true }
      })],
      key: \.key)
  }
}
