import Foundation

/// Report delivery (`HandoffLedger.claimReport`, TEAMS-V2 §4.8): every way a closed hand-off's
/// result reaches a chat, with a relaunch at any point and deliveries replayed for any id.
enum ReportMachine {
  static let config = HandoffWorld.Config(
    assistants: ["serein", "a", "b"], rows: 3, crashes: 1, expiry: true, replays: true, finishes: true, roots: 3)

  static var machine: FormalMachine<HandoffWorld> {
    FormalMachine(
      name: "report", bounds: "3 assistants, 3 rows, 1 relaunch, 1 day, replays of every id", start: HandoffWorld(),
      steps: HandoffWorld.steps(config),
      invariants: [
        ("a report is claimed only once sealed", { w in w.ledger.records.allSatisfy { $0.reported != true || !$0.isOpen } }),
        ("a report is claimed at most once", { w in w.claims.values.allSatisfy { $0 <= 1 } }),
        ("no reader turn before the claim", { w in w.unclaimedReads == 0 }),
        ("each report is shown at most once, relaunch and sweep included", { w in w.readerTurns.values.allSatisfy { $0 <= 1 } }),
        ("one wake turn per report", { w in w.wakes.values.allSatisfy { $0 <= 1 } }),
      ],
      transitions: [
        ("a replayed or repeated wake turn changes nothing", { before, label, after in
          !(label.hasPrefix("replayed delivery") || label.hasPrefix("wake turn"))
            || after.wakes != before.wakes || after == before
        }),
      ],
      eventually: [("every ended hand-off's report is claimed", { w in
        w.ledger.records.allSatisfy { !$0.isOpen && $0.reported == true }
      })],
      key: \.key)
  }
}
