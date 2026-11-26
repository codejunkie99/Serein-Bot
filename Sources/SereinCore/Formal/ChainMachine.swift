import Foundation

/// Hand-off chains (`HandoffLedger`, AssistantTeams.swift) under every order of sends, starts, run
/// ends, result deliveries, Stop Everything, a relaunch and a day going by.
enum ChainMachine {
  static let config = HandoffWorld.Config(
    assistants: ["serein", "a", "b", "c"], rows: 4, crashes: 1, expiry: true, replays: false, finishes: true, roots: 1)
  /// Sends and starts only, so the chain gets deep sooner. Five assistants, so the depth limit
  /// (`HandoffLedger.maxChain` holders) binds before the no-repeat rule does. Nothing counts rows
  /// per task or per assistant; the model stops at `depthRows`.
  static let depthRows = 6
  static let capConfig = HandoffWorld.Config(
    assistants: ["serein", "a", "b", "c", "d"], rows: depthRows, crashes: 0, expiry: false,
    replays: false, finishes: false, roots: 1)

  /// The mention storm: the person tags both bots and every run that ends done tags everyone else,
  /// results turns too. No cap counts the rows: the loop and depth checks shape the tree, and the
  /// model stops at `depthRows`.
  static let mentionConfig = HandoffWorld.Config(
    assistants: ["serein", "a", "b"], rows: depthRows, crashes: 1, expiry: false, replays: false,
    finishes: true, roots: 1, mentions: true)

  static var machine: FormalMachine<HandoffWorld> { machine(config, name: "chain", bounds: "4 assistants, 1 root, 4 rows, 1 relaunch, 1 day") }
  static var mentionMachine: FormalMachine<HandoffWorld> {
    var m = machine(mentionConfig, name: "mentions", bounds: "3 assistants, 1 person message tagging a, every done run tags everyone, \(depthRows) rows, 1 relaunch")
    m.invariants += [
      ("nobody tags itself", { w in w.ledger.records.allSatisfy { $0.from != $0.to } }),
      ("a tagged root never gets a wake turn", { w in w.wakes.keys.allSatisfy { id in w.record(id)?.mention == nil } }),
      ("each reply is posted at most once", { w in Set(w.posted).count == w.posted.count }),
      ("a report is claimed at most once", { w in w.claims.values.allSatisfy { $0 <= 1 } }),
    ]
    m.eventually.append(("every tagged reply lands and is claimed", { w in
      w.ledger.records.allSatisfy { !$0.isOpen && $0.reported == true }
    }))
    return m
  }
  static var capMachine: FormalMachine<HandoffWorld> {
    machine(capConfig, name: "chain-caps", bounds: "5 assistants, 1 root, \(depthRows) rows, sends only")
  }

  static func machine(_ c: HandoffWorld.Config, name: String, bounds: String) -> FormalMachine<HandoffWorld> {
    FormalMachine(
      name: name, bounds: bounds, start: HandoffWorld(), steps: HandoffWorld.steps(c),
      invariants: [
        ("no assistant holds one task twice", { w in w.ledger.records.allSatisfy { Set($0.holders).count == $0.holders.count } }),
        ("at most \(HandoffLedger.maxChain) holders on one task", { w in
          w.ledger.records.allSatisfy { $0.holders.count <= HandoffLedger.maxChain }
        }),
        ("a parent closes only after its children", { w in
          w.ledger.records.allSatisfy { p in
            let children = w.ledger.records.filter { $0.parentID == p.id }
            return p.isOpen || children.allSatisfy { !$0.isOpen && (p.state != .done || $0.reported == true) }
          }
        }),
        ("one hand-off holds a chat at a time", { w in
          let held = w.ledger.records.filter { $0.state == .running }.map(\.threadID)
          return Set(held).count == held.count
        }),
      ],
      transitions: [
        ("Stop Everything leaves nothing running", { _, label, after in
          label != "Stop Everything" || (after.live.isEmpty && !after.ledger.records.contains { $0.state == .running })
        }),
        ("a closed hand-off never opens again", { before, _, after in
          before.ledger.records.allSatisfy { r in r.isOpen || after.record(r.id).map { !$0.isOpen } ?? true }
        }),
      ],
      eventually: [("every admitted row ends", { w in w.ledger.records.allSatisfy { !$0.isOpen } })],
      key: \.key)
  }
}
