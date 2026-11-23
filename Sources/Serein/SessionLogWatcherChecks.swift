#if DEBUG
import Foundation
import SereinCore

/// `--verify-session-watch`: the watcher on a temporary folder. A first start reads everything;
/// a write arrives within 2 s; steady writes still arrive every 2 s; a write made while it was
/// stopped arrives on the next start, from the FSEvents journal, and so does one still waiting
/// to be applied when it stopped.
@MainActor func checkSessionLogWatcher() async throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("serein-session-watch-" + UUID().uuidString)
    .resolvingSymlinksInPath()
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  let key = "serein.sessionLogEventID.check"
  UserDefaults.standard.removeObject(forKey: key)
  defer {
    try? fm.removeItem(at: root)
    UserDefaults.standard.removeObject(forKey: key)
  }
  var batches: [(Date, SessionLogWatcher.Batch)] = []
  func watcher() -> SessionLogWatcher {
    SessionLogWatcher(roots: [root.path], eventKey: key) {
      batches.append((Date(), $0))
      SessionLogWatcher.commit($0, key: key)
    }
  }
  func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
  func saw(_ name: String, after start: Date) -> Date? {
    batches.first { $0.0 >= start && $0.1.paths.contains { $0.hasSuffix("/" + name) } }?.0
  }
  func check(_ ok: Bool, _ what: String) throws {
    guard ok else { throw SereinError.invalid(what) }
    print("PASS: \(what)")
  }

  var first = watcher()
  first.start()
  try await wait(1)
  try check(batches.contains { $0.1.full }, "a first start with no saved place reads everything")

  let wrote = Date()
  try Data("{}\n".utf8).write(to: root.appendingPathComponent("a.jsonl"))
  try await wait(2.5)
  let arrived = saw("a.jsonl", after: wrote)
  try check(arrived.map { $0.timeIntervalSince(wrote) <= 2.2 } == true, "a write arrives within 2 s")

  // A file kept open (a Codex rollout) reports each write through the followed file.
  first.follow([root.appendingPathComponent("a.jsonl").path])
  let steady = Date()
  let handle = try FileHandle(forWritingTo: root.appendingPathComponent("a.jsonl"))
  for _ in 0..<20 {
    handle.seekToEndOfFile()
    handle.write(Data("{}\n".utf8))
    try await wait(0.2)
  }
  try handle.close()
  // Writes for 4 s: flushes come at most 2 s apart while they continue.
  let flushes = batches.filter { $0.0 > steady }.map { $0.0.timeIntervalSince(steady) }
  let gaps = zip([0] + flushes, flushes).map { $1 - $0 }
  try check(flushes.count >= 2 && gaps.prefix(2).allSatisfy { $0 <= 2.2 }, "steady writes to an open file arrive at least every 2 s")

  first.stop()
  try await wait(0.5)
  try Data("{}\n".utf8).write(to: root.appendingPathComponent("while-closed.jsonl"))
  try await wait(1.5)
  let reopened = Date()
  first = watcher()
  first.start()
  try await wait(2.5)
  try check(saw("while-closed.jsonl", after: reopened) != nil, "a write made while stopped arrives on the next start")

  // Serein quits inside the 0.5 s wait: the write was received but never applied.
  try await wait(1)
  try Data("{}\n".utf8).write(to: root.appendingPathComponent("at-quit.jsonl"))
  try await wait(0.3)
  first.stop()
  try check(saw("at-quit.jsonl", after: reopened) == nil, "a write inside the wait is not applied before the stop")
  let again = Date()
  first = watcher()
  first.start()
  try await wait(2.5)
  try check(saw("at-quit.jsonl", after: again) != nil, "a write still waiting when it stopped arrives on the next start")
  first.stop()
}
#endif
