import Foundation

/// No queue (`SideSeat`, Sources/Serein/RelaySideSeats.swift): the person's messages to one chat
/// under every order of sends, side seats starting and ending, report posts, the chat's own turn
/// ending, running long and moving to the background, delegated runs taking the shared cap, and a
/// relaunch at any point. Each step copies one shell function and runs the shipped reducers
/// (`SideSeat.free`, `SideSeat.moves`, `HandoffLedger.admit`, `claimReport`).
struct SeatWorld: Codable, Equatable {
  struct Front: Codable, Equatable {
    var message: String
    /// Past `SideSeat.foregroundLimit`.
    var long = false
    /// A background seat took it; the stop that frees the chat has not landed yet.
    var moved = false
  }
  var sent: [String] = []
  /// The chat's own turn, answering one message.
  var front: Front?
  var ledger = HandoffLedger()
  var delegated = 0
  /// Posts a busy chat holds until its turn ends (`deliverAnswer` into `desk.facts`): a relaunch loses them.
  var held: [String] = []
  /// Posts saved in the chat.
  var chat: [String] = []
  /// Messages whose "a side seat isn't free" line posted.
  var notices: [String] = []
  /// Messages whose own turn a relaunch ended unmoved: that loss predates this machine (a quit
  /// ends the chat's turn), so they are left out of "answered".
  var quit: [String] = []
  var relaunches = 0

  static let t0 = Date(timeIntervalSince1970: 0)
  static func frontPost(_ message: String) -> String { "front-" + message }

  var key: String { (try? String(data: seatEncoder.encode(self), encoding: .utf8)) ?? "" }
  var seated: Int { ledger.records.filter { $0.side != nil && $0.state == .running }.count }
  var free: Bool { SideSeat.free(seated: seated, delegated: delegated) }
  /// Every post that answers `message`, held or saved.
  func answers(_ message: String) -> Int {
    let ids = [Self.frontPost(message)] + ledger.records.filter { $0.mention?.post == message }.map { HandoffReport.postID($0.id) }
    return ids.reduce(0) { n, id in n + chat.filter { $0 == id }.count + held.filter { $0 == id }.count }
  }

  /// `sendHandoff` for a side seat, then the `startWaitingHandoffs` it runs.
  mutating func seat(_ message: String, _ side: AssistantHandoff.Side) {
    var row = AssistantHandoff(
      id: "r\(ledger.records.count)", from: "serein", to: "serein", task: message, threadID: "seat-r\(ledger.records.count)",
      askedIn: "chat", team: "", teamName: "", createdAt: Self.t0)
    row.mention = .byPerson(message: message)
    row.side = side
    let starts = free
    ledger.admit(row, now: Self.t0)
    if starts { ledger.records[ledger.records.count - 1].state = .running } else { notices.append(message) }
  }
  /// `postReport` through `channelPost`: once in the chat; held while the chat's turn runs.
  mutating func post(_ id: String) -> Bool {
    if chat.contains(id) { return true }
    if front != nil {
      if !held.contains(id) { held.append(id) }
      return false
    }
    chat.append(id)
    return true
  }
  /// The chat's turn ended: what it held lands (`landTurnFacts`).
  mutating func land() {
    chat += held.filter { !chat.contains($0) }
    held = []
  }

  struct Config {
    var messages = 3
    var relaunches = 1
    var delegated = 2
  }

  static func steps(_ c: Config) -> (SeatWorld) -> [(label: String, next: SeatWorld)] {
    { w in
      var out: [(String, SeatWorld)] = []
      func step(_ label: String, _ change: (inout SeatWorld) -> Void) {
        var n = w
        change(&n)
        out.append((label, n))
      }
      // ask(): an idle chat starts its turn; a busy one seats the message (`startSideSeat`).
      if w.sent.count < c.messages {
        let m = "m\(w.sent.count)"
        step("person sends \(m)") { n in
          n.sent.append(m)
          if n.front == nil { n.front = Front(message: m) } else { n.seat(m, .busy) }
        }
      }
      for (i, r) in w.ledger.records.enumerated() {
        // startWaitingHandoffs: a side seat starts only under the cap.
        if r.state == .waiting, w.free { step("seat \(r.id) starts") { $0.ledger.records[i].state = .running } }
        // finishHandoff → closeHandoff: saved closed, its post owed.
        if r.state == .running {
          step("seat \(r.id) ends") { n in
            n.ledger.records[i].state = .done
            n.ledger.records[i].result = "answer"
            n.ledger.records[i].posted = false
          }
        }
        // landReport from closeHandoff, the sweep's owed posts, or deliverHandoffReports' claim.
        if !r.isOpen, r.posted == false || r.reported != true {
          step("post \(r.id)") { n in
            guard n.post(HandoffReport.postID(r.id)) else { return }
            n.ledger.records[i].posted = true
            _ = n.ledger.claimReport(r.id)
          }
        }
      }
      if let f = w.front {
        if !f.moved {
          step("turn on \(f.message) ends") { n in
            n.chat.append(frontPost(f.message))
            n.front = nil
            n.land()
          }
        }
        if !f.long { step("turn on \(f.message) runs past the limit") { $0.front?.long = true } }
        // moveLongTurn: guarded by the shipped decision, then the seat, then the stop.
        let moved = w.ledger.records.contains { $0.side == .background && $0.mention?.post == f.message }
        let now = t0.addingTimeInterval(f.long ? SideSeat.foregroundLimit : 0)
        if SideSeat.moves(startedAt: t0, now: now, moved: moved), w.free {
          step("turn on \(f.message) moves to the background") { n in
            n.seat(f.message, .background)
            n.front?.moved = true
          }
        }
        if f.moved {
          step("moved turn on \(f.message) stops") { n in
            n.front = nil
            n.land()
          }
        }
      }
      if w.delegated < c.delegated { step("delegated run starts") { $0.delegated += 1 } }
      if w.delegated > 0 { step("delegated run ends") { $0.delegated -= 1 } }
      // A quit and the launch sweep: memory goes, runs go, a seat with no run closes failed.
      if w.relaunches < c.relaunches {
        step("relaunch") { n in
          n.relaunches += 1
          n.held = []
          if let f = n.front, !f.moved { n.quit.append(f.message) }
          n.front = nil
          n.delegated = 0
          for i in n.ledger.records.indices where n.ledger.records[i].state == .running {
            n.ledger.records[i].state = .failed
            n.ledger.records[i].result = "Serein closed while it worked, so it did not finish."
            n.ledger.records[i].posted = false
          }
        }
      }
      return out
    }
  }
}

private let seatEncoder: JSONEncoder = {
  let e = JSONEncoder()
  e.outputFormatting = .sortedKeys
  return e
}()

enum SeatMachine {
  static let config = SeatWorld.Config()

  static var machine: FormalMachine<SeatWorld> {
    FormalMachine(
      name: "seats", bounds: "1 chat, 3 person messages, cap \(SideSeat.cap), up to 2 delegated runs, 1 relaunch",
      start: SeatWorld(), steps: SeatWorld.steps(config),
      invariants: [
        ("no message is lost", { w in
          w.sent.allSatisfy { m in
            w.front?.message == m || w.quit.contains(m) || w.answers(m) > 0 || w.ledger.records.contains { $0.mention?.post == m }
          }
        }),
        ("every message is answered at most once, the background move included", { w in w.sent.allSatisfy { w.answers($0) <= 1 } }),
        ("one background seat per message", { w in
          let moved = w.ledger.records.filter { $0.side == .background }.compactMap(\.mention?.post)
          return Set(moved).count == moved.count
        }),
        ("no post is in the chat twice", { w in Set(w.chat).count == w.chat.count }),
        ("at most \(SideSeat.cap) side seats run", { w in w.seated <= SideSeat.cap }),
        ("a message waiting for a seat says so", { w in
          w.ledger.records.allSatisfy { $0.state != .waiting || w.notices.contains($0.mention?.post ?? "") }
        }),
        ("a report is claimed only once it is in the chat", { w in
          w.ledger.records.allSatisfy { $0.reported != true || w.chat.contains(HandoffReport.postID($0.id)) }
        }),
      ],
      transitions: [
        ("a side seat starts only when one is free", { before, label, after in
          after.seated <= before.seated || before.free
        }),
      ],
      eventually: [("every message is answered exactly once", { w in
        w.held.isEmpty && w.front == nil
          && w.sent.allSatisfy { w.quit.contains($0) || w.answers($0) == 1 }
          && w.ledger.records.allSatisfy { !$0.isOpen && $0.reported == true && $0.posted == true }
      })],
      key: \.key)
  }
}
