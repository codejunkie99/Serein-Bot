import Foundation

/// Who joins a room (`Staffing.decide`, `Workroom`, `Reach`; Staffing.swift, Workroom.swift) under
/// every order of seat asks, makes, archives, a maker narrowed later (`renarrow`) and Undo of a make
/// (`Staffing.make`, `RelayTeam.undoing`). A make is applied by `Staffing.make`, the reducer the
/// shell's `assistant_make` and `assistant_handoff` run; a seat is appended under its asker with its
/// ledger row, as the shell's launch does (`RelayOrchestrator.seat(for:target:in:)`).
struct StaffingWorld: Encodable, Equatable {
  var room: Workroom
  var team: RelayTeam
  var archived: [String] = []
  var ledger = HandoffLedger()
  /// Makes not yet undone, newest last: the roster before and after each.
  var journal: [Made] = []
  /// Profiles narrowed since they were seated: `renarrow`'s `now`.
  var narrowed: [String: Reach] = [:]
  /// `decide` said make and `Staffing.make` refused it: the person would read the wrong reason.
  var makeRefusedAfterYes = false

  struct Made: Encodable, Equatable {
    var before: RelayTeam
    var after: RelayTeam
  }

  static let base = Date(timeIntervalSince1970: 1_800_000_000)
  static let person = AssistantScope(
    destinations: [.web, .mail, .mac, .project, .connectedApps], apps: ["composio:gmail", "composio:slack"])
  static let seatsCap = 4

  static var start: StaffingWorld {
    let named = [
      RelayProfile(id: "main", name: "Serein", createdAt: base),
      RelayProfile(id: "w", name: "Writer", createdAt: base, scope: AssistantScope(destinations: [.web, .mail], apps: ["composio:gmail"])),
      RelayProfile(id: "c", name: "Coder", createdAt: base, scope: AssistantScope(destinations: [.mac, .project, .web])),
    ]
    let room = Workroom(id: "r1", root: .chat(thread: "main-main", message: "m1"), lead: "main", thread: "main-main",
                        reach: Reach.ofPerson(person), now: base)
    return StaffingWorld(room: room, team: RelayTeam(profiles: named, activeID: "main"))
  }

  /// `a` is no wider than `b`: its places and apps inside, its Never sites a superset.
  static func within(_ a: Reach, _ b: Reach) -> Bool {
    let apps: Bool
    switch (a.scope.apps, b.scope.apps) {
    case (_, nil): apps = true
    case (nil, _): apps = false
    case let (x?, y?): apps = Set(x).isSubset(of: y)
    }
    return a.scope.destinations.isSubset(of: b.scope.destinations) && Set(b.scope.neverSites).isSubset(of: a.scope.neverSites) && apps
  }

  /// Applies a verdict for `seat` asking for `wanted`; nil when refused or not applicable.
  func asking(_ wanted: Staffing.Wanted, by seat: Workroom.Seat) -> StaffingWorld? {
    let verdict = Staffing.decide(wanted, by: seat, in: room, team: team, archived: Set(archived), ledger: ledger, now: Self.base)
    var next = self
    switch (verdict, wanted) {
    case (.seat(let reach), .teammate(let id)):
      next.seat(id, reach: reach, under: seat)
    case (.make(let reach, let lineage), .newAssistant(let draft)):
      let id = "m\(room.made.count + 1)"
      guard case .success(let plan) = Staffing.make(draft, reach: reach, lineage: lineage, team: team, id: id, now: Self.base) else {
        next.makeRefusedAfterYes = true
        return next
      }
      next.journal.append(Made(before: team, after: plan.team))
      next.team = plan.team
      next.room.recordMade(id)
      next.seat(id, reach: reach, under: seat)
    default:
      return nil
    }
    return next
  }

  private mutating func seat(_ who: String, reach: Reach, under seat: Workroom.Seat) {
    let parent = seat.handoff.flatMap { h in ledger.records.first { $0.id == h } }
    let row = AssistantHandoff(id: "h\(ledger.records.count + 1)", from: seat.who, to: who, task: "task", threadID: "seat-" + room.nextSeatID,
                               askedIn: seat.thread, team: "", teamName: "All assistants", createdAt: Self.base, parent: parent)
    ledger.admit(row, now: Self.base)
    room.seats.append(Workroom.Seat(id: room.nextSeatID, who: who, thread: row.threadID, reach: reach, parent: seat.id, handoff: row.id))
    // The shell runs `renarrow` before every seat's run.
    room.renarrow(narrowed)
  }

  static func steps(_ w: StaffingWorld) -> [(label: String, next: StaffingWorld)] {
    var out: [(label: String, next: StaffingWorld)] = []
    if w.room.seats.count < seatsCap {
      for seat in w.room.seats where seat.closedAt == nil {
        for id in ["main", "w", "c"] + w.room.made {
          if let n = w.asking(.teammate(id), by: seat) { out.append(("\(seat.id) (\(seat.who)) seats \(id)", n)) }
        }
        let draft = AssistantDraft(name: "New \(w.room.made.count + 1)", job: "Helps with one part.", places: [.web, .mac])
        if let n = w.asking(.newAssistant(draft), by: seat) { out.append(("\(seat.id) (\(seat.who)) makes m\(w.room.made.count + 1)", n)) }
      }
    }
    for id in ["w"] + w.room.made where !w.archived.contains(id) && w.team.profiles.contains(where: { $0.id == id }) {
      var n = w
      n.archived = (w.archived + [id]).sorted()
      out.append(("\(id) is archived", n))
    }
    for who in Set(w.room.seats.map(\.who)).sorted() where w.narrowed[who] == nil {
      var n = w
      n.narrowed[who] = Reach.ofPerson(AssistantScope(destinations: [.web], apps: []))
      n.room.renarrow(n.narrowed)
      out.append(("\(who) is narrowed to the Web", n))
    }
    if let last = w.journal.last, let restored = w.team.undoing(before: last.before, after: last.after) {
      var n = w
      n.team = restored
      n.journal.removeLast()
      out.append(("Undo the make of \(last.after.profiles.last?.id ?? "?")", n))
    }
    return out
  }
}

enum StaffingMachine {
  static var machine: FormalMachine<StaffingWorld> {
    FormalMachine(
      name: "staffing", bounds: "3 on the roster, \(StaffingWorld.seatsCap) seats, makes with no count up to the seats, archive, narrow, Undo",
      start: StaffingWorld.start,
      steps: StaffingWorld.steps,
      invariants: [
        ("seat reach within its parent's, within the ceiling", { w in
          let byID = Dictionary(uniqueKeysWithValues: w.room.seats.map { ($0.id, $0) })
          return w.room.seats.allSatisfy { s in
            let above = s.parent.flatMap { byID[$0]?.reach } ?? w.room.ceiling
            return StaffingWorld.within(s.reach, above) && StaffingWorld.within(above, w.room.ceiling)
          }
        }),
        ("seat reach within its assistant's narrowed reach", { w in
          w.room.seats.allSatisfy { s in w.narrowed[s.who].map { StaffingWorld.within(s.reach, $0) } ?? true }
        }),
        ("a make the rule allows always applies", { w in !w.makeRefusedAfterYes }),
        ("every make is on the roster and in the room's record", { w in
          let made = w.team.profiles.filter { $0.lineage?.madeIn == w.room.id }.map(\.id)
          return made.allSatisfy(w.room.made.contains)
        }),
        ("no chain holds an assistant twice or runs past the depth limit", { w in
          w.ledger.records.allSatisfy { r in
            let holders = r.holders
            return Set(holders).count == holders.count && holders.count <= HandoffLedger.maxChain
          }
        }),
        ("a made assistant carries its lineage and no connected apps", { w in
          w.room.made.allSatisfy { id in
            w.team.profiles.first { $0.id == id }.map { $0.lineage?.madeIn == w.room.id && $0.scope?.apps == [] } ?? true
          }
        }),
      ],
      transitions: [
        ("an archived assistant is never seated", { before, _, after in
          after.room.seats.dropFirst(before.room.seats.count).allSatisfy { !before.archived.contains($0.who) }
        }),
        ("Undo restores the roster exactly", { before, label, after in
          !label.hasPrefix("Undo") || before.journal.last.map { after.team == $0.before } == true
        }),
      ])
  }
}
