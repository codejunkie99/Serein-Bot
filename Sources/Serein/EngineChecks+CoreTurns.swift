#if DEBUG
import Darwin
import Foundation
import SereinCore
@testable import SereinEngines

/// Turns through Engines and the real process host, with `/bin/sh` as the CLI and a driver that
/// reads its lines.
extension AssistantCoreChecks {
  static func engineCoreTurns(_ check: Check) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("core-turns-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let records = RunRecords(root: root)

    func request(_ thread: String, _ message: String, access: Access = .answer) -> TurnRequest {
      TurnRequest(
        thread: ThreadKey(thread), cli: .codex, executable: URL(fileURLWithPath: "/bin/sh"), access: access,
        prompt: TurnPrompt(stable: "", volatile: "", message: message, recovery: nil), model: nil, effort: nil, resume: nil,
        browser: nil, taskID: thread)
    }
    func run(_ driver: LineDriver, _ requests: [TurnRequest]) throws -> [[EngineEvent]] {
      let engines = Engines(drivers: [driver], host: SereinProcessHost(records: records), records: records, tickEvery: .seconds(3_600))
      return try blocking {
        var turns: [[EngineEvent]] = []
        for request in requests {
          var seen: [EngineEvent] = []
          for await event in try await engines.send(request).events { seen.append(event) }
          turns.append(seen)
        }
        await engines.shutdown()
        return turns
      }
    }

    // codex exec prints its last answer and turn.completed, then exits at once.
    let exec = LineDriver(script: "read line; echo accepted; echo \"said $line\"; echo done", readDelay: .milliseconds(300))
    let drained = try run(exec, [request("drain", "hi")])
    try check(
      drained.first?.last == .ended(TurnEnd(.endTurn)) && drained.first?.contains(.text("said hi")) == true,
      "A CLI that exits right after its last words still ends the turn with them")

    // A one-shot session (codex exec) that stays up after its turn must not take a second one.
    let oneShot = LineDriver(script: "while read line; do echo accepted; echo \"pid $$\"; echo done; done", reusable: false)
    let twice = try run(oneShot, [request("once", "a"), request("once", "b")])
    let pids = twice.map { $0.compactMap { if case .text(let text) = $0 { return text }; return nil } }
    try check(
      twice.count == 2 && twice.allSatisfy { $0.last == .ended(TurnEnd(.endTurn)) } && pids[0].count == 1 && pids[0] != pids[1],
      "A second turn on a one-shot session's thread starts a new process")

    // The person's own config and MCP servers never run where the turn can write or browse: the
    // turn runs there on Serein's setup instead.
    let folder = root.appendingPathComponent("own", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let browser = BrowserServer(command: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], tools: [])
    for (index, (access, browses, own)) in [
      (Access.ownSetup(folder: folder), false, true), (.answer, false, false), (.library(folder), false, false),
      (.project(folder: folder, level: .review), false, false), (.answer, true, false), (.web, false, false),
      (.task(folder: folder), false, false), (.project(folder: folder, level: .edits), false, false),
      (.project(folder: folder, level: .commands), false, false), (.project(folder: folder, level: .full), false, false),
    ].enumerated() {
      var asked = request("own-\(index)", "hi", access: access)
      if browses { asked.browser = browser }
      let driver = LineDriver(script: "read line; echo accepted; echo \"own=$SEREIN_OWN_SETUP\"; echo done")
      let events = (try? run(driver, [asked]))?.first ?? []
      try check(
        events.last == .ended(TurnEnd(.endTurn)) && events.contains(.text("own=\(own ? 1 : 0)")),
        "Own setup \(own ? "runs" : "gives way to Serein's setup and the turn runs") at \(access.level)\(browses ? " with the browser" : "")")
    }

    let asking = LineDriver(script: "read line; echo accepted; echo declined; echo done")
    for (name, access, shown) in [
      ("a task", Access.task(folder: folder), false), ("Full", .project(folder: folder, level: .full), false),
      ("Commands", .project(folder: folder, level: .commands), true), ("Review", .project(folder: folder, level: .review), true),
    ] {
      let events = try run(asking, [request("declined-\(name)", "hi", access: access)]).first ?? []
      let declined = events.contains { if case .declined = $0 { return true }; return false }
      try check(
        declined == shown && events.contains(.permissionAnswered(allowed: false)) == !shown
          && events.last == .ended(TurnEnd(.endTurn)),
        "A declined ask \(shown ? "reaches the caller" : "is only history, never an approval") in \(name)")
    }
  }
}

/// `/bin/sh -c <script>`; the prompt's message goes on stdin as one line.
private final class LineDriver: Driver, @unchecked Sendable {
  let cli = HarnessDriver.codex
  let cardWait = Duration.seconds(118)
  let script: String
  /// Time the driver takes over each line, as a real one parsing and forwarding does.
  let readDelay: Duration
  let reusable: Bool

  init(script: String, readDelay: Duration = .zero, reusable: Bool = true) {
    self.script = script
    self.readDelay = readDelay
    self.reusable = reusable
  }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(
      request, arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin", "SEREIN_OWN_SETUP": request.ownSetup ? "1" : "0"],
      expectedMode: .nothing(flagOnArgv: ["-c"]),
      network: .open)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    switch ModeCheck.verify(contract.expectedMode, reported: [:], argv: contract.argv) {
    case .failure(let reason): throw reason
    case .success(let mode): return LineSession(process, mode: mode, readDelay: readDelay, reusable: reusable)
    }
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

/// `accepted` and `done` are the turn's start and end; any other line is text.
private final class LineSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  let reusable: Bool
  private let process: EngineProcess

  init(_ process: EngineProcess, mode: VerifiedMode, readDelay: Duration, reusable: Bool) {
    self.mode = mode
    self.reusable = reusable
    self.process = process
    let (wire, out) = AsyncStream<WireEvent>.makeStream()
    self.wire = wire
    Task {
      for await line in process.lines {
        try? await Task.sleep(for: readDelay)
        switch String(decoding: line, as: UTF8.self) {
        case "accepted": out.yield(.accepted)
        case "done": out.yield(.turnDone(.endTurn))
        case "declined": out.yield(.declined(PendingApprovalValue(id: "d1", tool: "Bash", target: "rm -rf build")))
        case let text: out.yield(.text(text))
        }
      }
      out.finish()
    }
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    try process.send(line: Data(prompt.message.utf8))
  }

  func steer(_ text: String) async -> SteerOutcome { .handedBack(text) }
}
#endif
