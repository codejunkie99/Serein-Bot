#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// Swarm writers never share a folder at once: in a git repo each writer works in its own
/// worktree and its changes reach the owner's folder only after sign-off; outside git, writers in
/// one folder take turns while readers run beside them.
extension AssistantCoreChecks {
  static func swarmWriters(_ check: Check) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("swarm-writers-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    let plain = root.appendingPathComponent("plain", isDirectory: true)
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    try fm.createDirectory(at: plain, withIntermediateDirectories: true)
    try (1...10).map(String.init).joined(separator: "\n").appending("\n").write(to: repo.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    try git(repo, "init", "-q")
    try git(repo, "add", "-A")
    try git(repo, "commit", "-q", "-m", "start")

    let log = WriterLog()
    let world = WriterWorld(log: log)
    let notes = SwarmWriterNotes()
    let top = PeerCaller(thread: ThreadKey("writers-top"), cli: .codex, access: .project(folder: repo, level: .full))
    let plainTop = PeerCaller(thread: ThreadKey("writers-plain"), cli: .codex, access: .project(folder: plain, level: .full))

    try world.run { peers, host in
      await peers.register(task: "writers-top", caller: top)
      await peers.register(task: "writers-plain", caller: plainTop)

      // 1. Two writers, different files and different lines of one file, verifier signs off.
      let signed = await peers.handle(.swarm(PeerSwarmRequest(
        goal: "Two slices",
        workers: [
          PeerSwarmWorker(name: "w1", agent: .claude, task: "ID=a1 PUT:a.txt=alpha LINE:shared.txt:1=ONE", write: true),
          PeerSwarmWorker(name: "w2", agent: .codex, task: "ID=a2 PUT:b.txt=beta LINE:shared.txt:10=TEN", write: true),
        ],
        verifier: .grok, rounds: 1)), task: "writers-top")
      let a1 = log.entry("a1"), a2 = log.entry("a2")
      notes.check(signed.text.contains("The swarm verifier approved the final result."), "Signed-off swarm reports approval")
      notes.check(
        a1 != nil && a2 != nil && a1?.folder != repo.path && a2?.folder != repo.path && a1?.folder != a2?.folder,
        "Each git writer works in its own folder, never the owner's (w1 \(a1?.folder ?? "-"), w2 \(a2?.folder ?? "-"))")
      notes.check(a1?.linkedWorktree == true && a2?.linkedWorktree == true, "Each writer's folder is a linked git worktree")
      let verifierPrompt = host.callees.first { $0.prompt.message.contains("the read-only verifier") }?.prompt.message ?? ""
      notes.check(verifierPrompt.contains("+alpha") && verifierPrompt.contains("+beta"), "Verifier is shown each writer's real diff")
      notes.check(
        read(repo, "a.txt") == "alpha" && read(repo, "b.txt") == "beta"
          && lines(repo, "shared.txt").first == "ONE" && lines(repo, "shared.txt").dropLast().last == "TEN",
        "After sign-off the owner's folder holds both writers' changes, the shared file's included")
      notes.check(signed.text.contains("Merged the changes of w1, w2"), "Result names the merged writers")
      notes.check(git(in: repo, "worktree", "list").split(separator: "\n").count == 1, "Cleanly merged worktrees are removed")
      notes.check(!git(in: repo, "status", "--porcelain").contains(".serein"), "Swarm worktrees stay out of the owner's git status")

      // 2. Both writers change the same line, no verifier: the first lands, the second is kept.
      let clash = await peers.handle(.swarm(PeerSwarmRequest(
        goal: "Same line",
        workers: [
          PeerSwarmWorker(name: "w1", agent: .claude, task: "ID=b1 LINE:shared.txt:5=FIVE-A", write: true),
          PeerSwarmWorker(name: "w2", agent: .codex, task: "ID=b2 LINE:shared.txt:5=FIVE-B", write: true),
        ],
        verifier: nil, rounds: 1)), task: "writers-top")
      let shared = (try? String(contentsOf: repo.appendingPathComponent("shared.txt"), encoding: .utf8)) ?? ""
      notes.check(lines(repo, "shared.txt").dropFirst(4).first == "FIVE-A" && !shared.contains("<<<<<<<"), "First writer merges; no conflict markers reach the owner's file")
      let keptPath = log.entry("b2").map { URL(fileURLWithPath: $0.folder) }
      notes.check(
        clash.text.contains("w2's changes stay in") && keptPath.map { clash.text.contains($0.path) } == true
          && keptPath.map { lines($0, "shared.txt").dropFirst(4).first == "FIVE-B" } == true,
        "A conflicting writer's worktree is kept with its work and named in the result")

      // 3. The verifier never signs off: nothing merges and every worktree is kept and named.
      let refused = await peers.handle(.swarm(PeerSwarmRequest(
        goal: "Refused NO-SIGNOFF",
        workers: [PeerSwarmWorker(name: "w1", agent: .claude, task: "ID=c1 PUT:c.txt=gamma", write: true)],
        verifier: .grok, rounds: 1)), task: "writers-top")
      let c1 = log.entry("c1").map { URL(fileURLWithPath: $0.folder) }
      notes.check(
        read(repo, "c.txt") == nil && c1.map { read($0, "c.txt") == "gamma" && refused.text.contains($0.path) } == true
          && refused.text.contains("the verifier did not approve"),
        "Without sign-off nothing merges and the kept worktree is reported")

      // 4. Outside git, writers sharing the folder run one at a time; a reader is not held back.
      _ = await peers.handle(.swarm(PeerSwarmRequest(
        goal: "Plain folder",
        workers: [
          PeerSwarmWorker(name: "w1", agent: .claude, task: "ID=d1 SLOW PUT:n1.txt=x", write: true),
          PeerSwarmWorker(name: "w2", agent: .codex, task: "ID=d2 SLOW PUT:n2.txt=y", write: true),
          PeerSwarmWorker(name: "r1", agent: .opencode, task: "ID=d3 SLOW", write: false),
        ],
        verifier: nil, rounds: 1)), task: "writers-plain")
      if let d1 = log.entry("d1"), let d2 = log.entry("d2"), let d3 = log.entry("d3") {
        notes.check(d1.folder == plain.path && d2.folder == plain.path, "Non-git writers work in the owner's folder")
        notes.check(d1.end <= d2.start || d2.end <= d1.start, "Non-git writers in one folder never overlap in time")
        notes.check(d3.start < max(d1.end, d2.end) && d3.end > min(d1.start, d2.start), "A reader runs beside the writers")
      } else {
        notes.check(false, "Every plain-folder worker ran")
      }
    }

    // 5. Stop mid-run: the writer's worktree is kept and named, never dropped without a word.
    try world.run(inline: .milliseconds(500)) { peers, _ in
      await peers.register(task: "writers-top", caller: top)
      let held = await peers.handle(.swarm(PeerSwarmRequest(
        goal: "Stopped",
        workers: [PeerSwarmWorker(name: "w1", agent: .claude, task: "ID=e1 PUT:e.txt=held HOLD", write: true)],
        verifier: nil, rounds: 1)), task: "writers-top")
      notes.check(held.text.contains("still working"), "A held swarm yields before it is stopped")
      _ = await peers.handle(.stop(run: nil), task: "writers-top")
      var after = ""
      for _ in 0..<40 where !after.contains("the swarm was stopped") {
        try? await Task.sleep(for: .milliseconds(100))
        after = await peers.handle(.wait(runs: [], seconds: 1), task: "writers-top").text
      }
      let e1 = log.entry("e1").map { URL(fileURLWithPath: $0.folder) }
      notes.check(
        after.contains("the swarm was stopped") && e1.map { after.contains($0.path) && read($0, "e.txt") == "held" } == true
          && read(repo, "e.txt") == nil,
        "A stopped swarm keeps the writer's worktree with its work and names it in the result")
    }
    for (passed, label) in notes.all { try check(passed, label) }
  }

  @discardableResult
  private static func git(_ dir: URL, _ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Serein", "-c", "user.email=checks@serein.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-C", dir.path] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SereinError.invalid("FAIL: git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static func git(in dir: URL, _ arguments: String...) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", dir.path] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func read(_ dir: URL, _ name: String) -> String? {
    try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
  }

  private static func lines(_ dir: URL, _ name: String) -> [String] {
    (read(dir, name) ?? "").components(separatedBy: "\n")
  }
}

private final class SwarmWriterNotes: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [(Bool, String)] = []
  var all: [(Bool, String)] { lock.withLock { items } }
  func check(_ passed: Bool, _ label: String) { lock.withLock { items.append((passed, label)) } }
}

/// Where and when each fake CLI turn ran, by its `ID=` tag.
private final class WriterLog: @unchecked Sendable {
  struct Entry {
    var folder: String
    var start: Date
    var end: Date
    /// The folder's `.git` is a file, as in a linked worktree, not the repository's own folder.
    var linkedWorktree: Bool
  }
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  func entry(_ id: String) -> Entry? { lock.withLock { entries[id] } }
  func record(_ id: String, _ entry: Entry) { lock.withLock { entries[id] = entry } }
}

private struct WriterWorld: Sendable {
  let log: WriterLog

  func run(inline: Duration = .seconds(30), _ body: @escaping @Sendable (Peers, FakePeerHost) async -> Void) throws {
    let records = RunRecords(root: FileManager.default.temporaryDirectory.appendingPathComponent("swarm-writers-runs-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: records.root) }
    let drivers: [any Driver] = [HarnessDriver.claude, .codex, .grok, .opencode].map { WriterScript(cli: $0, log: log) }
    let engines = Engines(drivers: drivers, host: PeerProcesses(), records: records, sleep: { _ in await Task.yield() }, tickEvery: .seconds(3_600))
    var limits = Peers.Limits()
    limits.inlineCap = inline
    let host = FakePeerHost()
    let peers = Peers(engines: engines, host: host, limits: limits)
    let done = DispatchSemaphore(value: 0)
    Task {
      await body(peers, host)
      await engines.shutdown()
      done.signal()
    }
    guard done.wait(timeout: .now() + 90) == .success else { throw SereinError.invalid("FAIL: swarm writers check timed out") }
  }
}

/// A fake CLI that edits the folder it was given: `PUT:<file>=<text>` writes a file,
/// `LINE:<file>:<n>=<text>` replaces line n, `SLOW` takes a moment, `HOLD` works until stopped.
/// The verifier approves unless told `NO-SIGNOFF`.
private struct WriterScript: Driver {
  let cli: HarnessDriver
  let log: WriterLog
  let cardWait = Duration.seconds(118)

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(request, arguments: [], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    let mode = try ModeCheck.verify(contract.expectedMode, reported: ["approvalPolicy": "never"], argv: contract.argv).get()
    return WriterSession(mode: mode, log: log)
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class WriterSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation
  private let log: WriterLog

  init(mode: VerifiedMode, log: WriterLog) {
    self.mode = mode
    self.log = log
    (wire, continuation) = AsyncStream<WireEvent>.makeStream()
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    let asked = prompt.message
    continuation.yield(.accepted)
    if asked.contains("the read-only verifier") {
      continuation.yield(.text(asked.contains("NO-SIGNOFF") ? "NEEDS FIX: not yet." : "\(PeerTools.approved) checked the diffs."))
      continuation.yield(.turnDone(.endTurn))
      return
    }
    let folder = request.access.folder ?? URL(fileURLWithPath: "/nonexistent")
    let tokens = asked.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
    let start = Date()
    if tokens.contains("SLOW") { try? await Task.sleep(for: .milliseconds(400)) }
    for token in tokens {
      if token.hasPrefix("PUT:"), let eq = token.firstIndex(of: "=") {
        let name = String(token[token.index(token.startIndex, offsetBy: 4)..<eq])
        try? String(token[token.index(after: eq)...]).write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
      } else if token.hasPrefix("LINE:"), let eq = token.firstIndex(of: "=") {
        let spot = token[token.index(token.startIndex, offsetBy: 5)..<eq].split(separator: ":")
        guard spot.count == 2, let n = Int(spot[1]) else { continue }
        let file = folder.appendingPathComponent(String(spot[0]))
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if lines.indices.contains(n - 1) { lines[n - 1] = String(token[token.index(after: eq)...]) }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
      }
    }
    if let tag = tokens.first(where: { $0.hasPrefix("ID=") }) {
      var directory: ObjCBool = false
      let linked = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path, isDirectory: &directory) && !directory.boolValue
      log.record(String(tag.dropFirst(3)), .init(folder: folder.path, start: start, end: Date(), linkedWorktree: linked))
    }
    if tokens.contains("HOLD") {
      continuation.yield(.text("holding"))
      return
    }
    continuation.yield(.text("done"))
    continuation.yield(.turnDone(.endTurn))
  }

  func steer(_ text: String) async -> SteerOutcome { .steered }
}
#endif
