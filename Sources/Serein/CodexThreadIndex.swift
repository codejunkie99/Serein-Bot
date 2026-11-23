import Foundation
import SereinCore

/// What the Codex app knows of its threads, for the Agents list: each one's name and whether it is
/// a helper another thread spawned (`ExternalSessionReader.codexThreads`). Read once per thread
/// and again after `fresh`, so the list never reads Codex's database on every draw.
@MainActor final class CodexThreadIndex {
  static let shared = CodexThreadIndex()
  struct Facts {
    var name: String?
    var helper: Bool
    var at: Date
  }
  private var known: [String: Facts] = [:]
  /// A thread's name can change in Codex; it is read again after this long.
  static let fresh: TimeInterval = 120

  /// The facts for these thread ids, reading only the ones not known or gone stale.
  func facts(_ ids: [String], now: Date = Date()) -> [String: Facts] {
    let wanted = Set(ids.filter { UUID(uuidString: $0) != nil })
    let stale = wanted.filter { known[$0].map { now.timeIntervalSince($0.at) > Self.fresh } ?? true }
    if !stale.isEmpty, !RunMode.previewing {
      let read = ExternalSessionReader.codexThreads(Array(stale), home: NSHomeDirectory())
      for id in stale {
        let found = read[id]
        known[id] = Facts(name: found?.name.flatMap(SessionIndex.userTitle), helper: found?.helper ?? false, at: now)
      }
    }
    return known.filter { wanted.contains($0.key) }
  }
}
