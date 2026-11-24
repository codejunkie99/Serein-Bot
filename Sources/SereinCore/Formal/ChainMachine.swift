import Foundation

/// Hand-off chains (`HandoffLedger`, AssistantTeams.swift) under every order of sends, starts, run
/// ends, result deliveries, Stop Everything, a relaunch and a day going by.
enum ChainMachine {
  static let config = HandoffWorld.Config(
    assistants: ["serein", "a", "b", "c"], rows: 4, crashes: 1, expiry: true, replays: false, finishes: true, roots: 1)
  /// Sends and starts only, so the caps are reached sooner. Five assistants, so the holder cap
  /// binds before the no-repeat rule does, and four would run out of open slots (3 each) before
  /// the per-root cap. One row past that cap.
  static let capConfig = HandoffWorld.Config(
    assistants: ["serein", "a", "b", "c", "d"], rows: HandoffLedger.maxPerRoot + 1, crashes: 0, expiry: false,
    replays: false, finishes: false, roots: 1)

  static var machine: FormalMachine<HandoffWorld> { machine(config, name: "chain", bounds: "4 assistants, 1 root, 4 rows, 1 relaunch, 1 day") }
  static var capMachine: FormalMachine<HandoffWorld> {
    machine(capConfig, name: "chain-caps", bounds: "5 assistants, 1 root, \(HandoffLedger.maxPerRoot + 1) rows, sends only")
  }

  static func machine(_ c: HandoffWorld.Config, name: String, bounds: String) -> FormalMachine<HandoffWorld> {
    FormalMachine(
      name: name, bounds: bounds, start: HandoffWorld(), steps: HandoffWorld.steps(c),
      invariants: [
        ("no assistant holds one task twice", { w in w.ledger.records.allSatisfy { Set($0.holders).count == $0.holders.count } }),
        ("at most \(HandoffLedger.maxChain) holders on one task", { w in
          w.ledger.records.allSatisfy { $0.holders.count <= HandoffLedger.maxChain }
        }),
        ("at most \(HandoffLedger.maxPerRoot) rows per root", { w in
          Dictionary(grouping: w.ledger.records, by: { $0.rootID ?? $0.id }).values.allSatisfy { $0.count <= HandoffLedger.maxPerRoot }
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
