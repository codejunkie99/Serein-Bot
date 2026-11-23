#if DEBUG
import Foundation
import SereinCore

/// A followed chat file is read from where the last read ended (AppendedTail), and a change in
/// agent history lists again only the folders it touched (SessionIndex.touched and sessions).
extension AssistantCoreChecks {
  static func lazyLoadTranscripts(_ check: Check) throws {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("serein-lazy-transcripts-\(UUID().uuidString)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }

    // MARK: Appended lines

    let file = folder.appendingPathComponent("chat.jsonl")
    func bytes(_ text: String) -> Data { Data(text.utf8) }
    /// Writes in place: the same file, as an app that truncates and rewrites it.
    func rewrite(_ text: String) throws {
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: bytes(text))
    }
    func append(_ text: String) throws {
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: bytes(text))
    }
    try bytes("{\"a\":1}\n{\"b\":2}\n").write(to: file)
    let tail = AppendedTail()
    let first = try tail.read(file.path)
    try check(
      first.whole && first.data == bytes("{\"a\":1}\n{\"b\":2}\n") && !first.omitsEarlier,
      "The first read of a followed chat file takes all of it")

    try append("{\"c\":3}\n{\"d\":")
    let second = try tail.read(file.path)
    try check(
      !second.whole && second.added == bytes("{\"c\":3}\n")
        && second.data == bytes("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"),
      "A later read takes only the lines written since, and a line still being written is not parsed")
    try append("4}\n")
    let third = try tail.read(file.path)
    try check(
      !third.whole && third.added == bytes("{\"d\":4}\n")
        && third.data == bytes("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n{\"d\":4}\n"),
      "The held line is taken once its newline comes, and only once")

    try append("{\"e\":5}")
    let fourth = try tail.read(file.path)
    try append("\n")
    let fifth = try tail.read(file.path)
    try check(
      fourth.added.isEmpty && fourth.data == bytes("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n{\"d\":4}\n{\"e\":5}")
        && fifth.added == bytes("{\"e\":5}\n")
        && fifth.data == bytes("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n{\"d\":4}\n{\"e\":5}\n"),
      "A last line that is already whole JSON shows before its newline, and still shows once after it")

    try rewrite("{\"x\":1}\n")
    let shrunk = try tail.read(file.path)
    try check(shrunk.whole && shrunk.data == bytes("{\"x\":1}\n"), "A chat file that shrank is read whole again")

    try bytes("{\"y\":1}\n{\"y\":2}\n").write(to: file, options: .atomic)
    let replaced = try tail.read(file.path)
    try check(
      replaced.whole && replaced.data == bytes("{\"y\":1}\n{\"y\":2}\n"),
      "A chat file replaced by another one is read whole again")

    try rewrite("{\"zz\":1}\n{\"z\":2}\n{\"z\":3}\n")
    let rewritten = try tail.read(file.path)
    try check(
      rewritten.whole && rewritten.data == bytes("{\"zz\":1}\n{\"z\":2}\n{\"z\":3}\n"),
      "A chat file rewritten in place to a longer one is read whole again, not joined to the old lines")

    let long = folder.appendingPathComponent("long.jsonl")
    try bytes("{\"a\":1}\n{\"b\":2}\n").write(to: long)
    let small = AppendedTail(limit: 10)
    let cut = try small.read(long.path)
    let longHandle = try FileHandle(forWritingTo: long)
    try longHandle.seekToEnd()
    try longHandle.write(contentsOf: bytes("{\"c\":3}\n"))
    try longHandle.close()
    let moved = try small.read(long.path)
    try check(
      cut.omitsEarlier && cut.data == bytes("{\"b\":2}\n") && moved.omitsEarlier && moved.data == bytes("{\"c\":3}\n"),
      "Past its limit a followed file keeps only its newest whole lines and says earlier ones are left out")

    // MARK: Session discovery

    let claudeRoot = folder.appendingPathComponent("claude")
    let codexRoot = folder.appendingPathComponent("codex")
    let projectA = claudeRoot.appendingPathComponent("-work-a")
    let projectB = claudeRoot.appendingPathComponent("-work-b")
    let day = codexRoot.appendingPathComponent("2026/11/15")
    let nextDay = codexRoot.appendingPathComponent("2026/11/16")
    for made in [projectA, projectB, day, nextDay] { try fm.createDirectory(at: made, withIntermediateDirectories: true) }
    let mapped = SessionIndex.touched(
      [
        projectA.appendingPathComponent("s.jsonl").path, projectA.appendingPathComponent("s/subagents/agent-1.jsonl").path,
        day.appendingPathComponent("rollout-x.jsonl").path, nextDay.path + "/",
      ], claudeRoot: claudeRoot, codexRoot: codexRoot)
    try check(
      mapped?.claude == [projectA.path] && mapped?.codex == [day.path, nextDay.path]
        && SessionIndex.touched([claudeRoot.path], claudeRoot: claudeRoot, codexRoot: codexRoot) == nil
        && SessionIndex.touched(["/elsewhere/x.jsonl"], claudeRoot: claudeRoot, codexRoot: codexRoot) == nil,
      "A history event names the Claude Code project folder or Codex day folder it falls in; a root or an outside path asks for a full pass")

    var minute = 0.0
    func claude(_ project: URL, _ title: String) throws {
      let url = project.appendingPathComponent("s.jsonl")
      try bytes(
        "{\"type\":\"user\",\"cwd\":\"/work/\(project.lastPathComponent)\",\"sessionId\":\"\(project.lastPathComponent)\","
          + "\"message\":{\"role\":\"user\",\"content\":\"\(title)\"}}\n"
      ).write(to: url)
      minute += 1
      try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000 + minute * 60)], ofItemAtPath: url.path)
    }
    func codex(_ folder: URL, _ id: String, _ title: String) throws {
      try bytes(
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/work/\(id)\",\"timestamp\":\"2026-11-15T10:00:00Z\"}}\n"
          + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(title)\"}}\n"
      ).write(to: folder.appendingPathComponent("rollout-\(id).jsonl"))
    }
    func titles(_ sessions: [DiscoveredSession]) -> Set<String> { Set(sessions.map(\.title)) }
    try claude(projectA, "Fix A")
    try claude(projectB, "Fix B")
    try codex(day, "c1", "Fix C")
    var scan = SessionIndex.Scan()
    let launch = SessionIndex.sessions(claudeRoot: claudeRoot, codexRoot: codexRoot, touched: nil, scan: &scan)
    try check(titles(launch) == ["Fix A", "Fix B", "Fix C"], "The pass at launch reads every history folder")

    try claude(projectA, "Fix A again")
    try claude(projectB, "Fix B again")
    try codex(nextDay, "c2", "Fix D")
    let event = SessionIndex.touched(
      [projectA.appendingPathComponent("s.jsonl").path, nextDay.appendingPathComponent("rollout-c2.jsonl").path],
      claudeRoot: claudeRoot, codexRoot: codexRoot)
    let afterEvent = SessionIndex.sessions(claudeRoot: claudeRoot, codexRoot: codexRoot, touched: event, scan: &scan)
    try check(
      titles(afterEvent) == ["Fix A again", "Fix B", "Fix C", "Fix D"],
      "A history event re-reads only the folders it touched and keeps what the last pass found in the others")

    try fm.removeItem(at: day)
    let allTouched = SessionIndex.touched(
      [projectB.appendingPathComponent("s.jsonl").path, day.path], claudeRoot: claudeRoot, codexRoot: codexRoot)
    let caughtUp = SessionIndex.sessions(claudeRoot: claudeRoot, codexRoot: codexRoot, touched: allTouched, scan: &scan)
    var fresh = SessionIndex.Scan()
    let full = SessionIndex.sessions(claudeRoot: claudeRoot, codexRoot: codexRoot, touched: nil, scan: &fresh)
    try check(
      titles(caughtUp) == ["Fix A again", "Fix B again", "Fix D"] && caughtUp == full,
      "Once its events name every changed folder, a pass finds what a full pass finds, a removed folder's chats gone")
  }
}
#endif
