import Foundation
import SereinCore

/// The work ledger (relay/work.sqlite, SereinCore/WorkLedger.swift) for links. There is one
/// ledger instance: `openWork` (RelayOrchestrator.swift) opens it once, off the main thread, runs
/// the one launch recovery, keeps it in `work` for every move, and hands the same instance to
/// `AssistantDesk.ledger`, where the link receiver (RelayHookServer) writes an admitted delivery
/// before it answers 200. A link's turn is a scheduled turn with that row (`enqueueLink`), so it
/// starts, ends and stops like every other one (`startWork`, `finishWork`, `stopEverything`).
extension RelayOrchestrator {
  static let workFile = "relay/work.sqlite"

  /// The receiver needs the ledger: it opens at launch (`openWork`), so this only waits for that
  /// open; the receiver starts again once the ledger is there.
  func openWorkLedger() {
    guard desk.ledger == nil, work != nil else { return }
    desk.ledger = work?.store
  }

  /// One move of a ledger row, in order with every other ledger write, off the main thread.
  func moveWork(_ id: Int64, _ transition: WorkLedger.Transition, note: String? = nil) {
    guard let work else { return }
    work.post { ledger in _ = try ledger.move(id, transition, note: note) }
  }

  /// The id of the scheduled turn a link row starts.
  static func linkTurnID(_ row: Int64) -> String { "link-\(row)" }
}
