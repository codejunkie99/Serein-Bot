#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// Verifies the shared swarm message board, unlimited autonomous team policy, zero-permission
/// upgrade rules, end-to-end `peer_swarm` over `Engines`, `GenericACPDriver` + ACP steering,
/// `LaunchContract.warmTags`, and `HarnessStuck.isLoopbackAddress`.
extension AssistantCoreChecks {
  static func swarmBoard(_ check: Check) throws {
    try checkBoardInterleavings(check)
    try checkAutoTeamPolicy(check)
    try checkAllowAllUpgrade(check)
    try checkPeerSwarmTools(check)
    try checkPeerSwarmExecution(check)
    try checkGenericACPAndSteer(check)
    try checkWarmTagsAndLoopback(check)
  }

  // MARK: - SwarmBoard interleavings & monitor

  private static func checkBoardInterleavings(_ check: Check) throws {
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    // Permute completion orders of two workers and confirm `@verifier` sees both `#seq` items
    // regardless of which worker finished first.
    for order in [["alpha", "beta"], ["beta", "alpha"]] {
      var board = SwarmBoard()
      board.register(name: "coordinator", role: .coordinator, workspace: .inherit, at: base)
      board.register(name: "alpha", role: .worker, workspace: .worktree, at: base)
      board.register(name: "beta", role: .worker, workspace: .readOnly, at: base)
      board.register(name: "verifier", role: .verifier, workspace: .readOnly, at: base)

      let b1 = board.post(author: "coordinator", text: "@alpha Write patch A", kind: .brief, at: base.addingTimeInterval(1))
      let b2 = board.post(author: "coordinator", text: "@beta Audit tests", kind: .brief, at: base.addingTimeInterval(2))
      try check(b1.seq == 1 && b2.seq == 2, "Board assigns monotonic sequence numbers")
      try check(board.members["alpha"]?.state == .working && board.members["beta"]?.state == .working, "Mentioned workers wake into working")

      try check(
        board.unread(since: 0, for: "alpha", mentionsOnly: true).map(\.seq) == [b1.seq],
        "Mention-filtered unread returns only briefs targeting alpha")
      try check(
        board.unread(since: 0, for: "beta", mentionsOnly: true).map(\.seq) == [b2.seq],
        "Mention-filtered unread returns only briefs targeting beta")

      var doneSeqs: [Int] = []
      var t: TimeInterval = 10
      for w in order {
        t += 5
        let p = board.post(author: w, text: "@verifier [done] Slice \(w) complete", kind: .done, at: base.addingTimeInterval(t))
        doneSeqs.append(p.seq)
      }
      try check(board.members["verifier"]?.state == .working, "Completion @verifier wakes verifier")
      let fetched = board.posts(seqs: doneSeqs)
      try check(fetched.count == 2 && Set(fetched.map(\.author)) == Set(["alpha", "beta"]), "Exact #seq fetch retrieves both worker posts under \(order)")

      // Verifier requests revision from alpha; verifier goes back to waiting, alpha wakes up.
      let v1 = board.post(author: "verifier", text: "@alpha Add boundary check for #\(doneSeqs[0])", at: base.addingTimeInterval(30))
      try check(board.members["verifier"]?.state == .waiting && board.members["alpha"]?.state == .working, "Verifier rejection sleeps verifier and wakes alpha")

      // While alpha is working, monitor does not report a stall.
      try check(
        SwarmMonitor.stallTarget(board: board, now: base.addingTimeInterval(600), idleAfter: 120) == nil,
        "Monitor stays quiet while any worker is working")

      // If alpha goes waiting without replying to v1 and idle threshold passes, monitor targets alpha.
      board.setState("alpha", to: .waiting, at: base.addingTimeInterval(40))
      try check(
        SwarmMonitor.stallTarget(board: board, now: base.addingTimeInterval(40 + 120), idleAfter: 120) == "alpha",
        "Monitor targets the quiet @mentioned worker past idleAfter")

      // Alpha answers, verifier approves, coordinator posts [done], monitor clears.
      let r1 = board.post(author: "alpha", text: "@verifier [done] Added boundary check (answers #\(v1.seq))", kind: .done, at: base.addingTimeInterval(50))
      _ = board.post(author: "verifier", text: "@coordinator APPROVED #\(r1.seq)", kind: .update, at: base.addingTimeInterval(60))
      board.post(author: "coordinator", text: "[done] Shipped verified result.", kind: .done, at: base.addingTimeInterval(70))
      try check(board.finished, "Coordinator [done] without mentions marks the board finished")
      try check(
        SwarmMonitor.stallTarget(board: board, now: base.addingTimeInterval(1_000), idleAfter: 60) == nil,
        "Monitor returns nil once board is finished")
    }
  }

  // MARK: - Unlimited AutoTeamPolicy

  private static func checkAutoTeamPolicy(_ check: Check) throws {
    var records: [AutoTeamPolicy.BotRecord] = []
    for i in 1...10 {
      let teamID = "team-\((i - 1) / 3 + 1)"
      let decision = AutoTeamPolicy.admit(
        id: "bot-\(i)", role: "specialist-\(i)", createdBy: "coordinator", parentTaskID: teamID,
        existing: records, activeChain: ["coordinator"])
      guard case .admit(let rec) = decision else {
        try check(false, "Unlimited AutoTeamPolicy admits bot \(i) across team \(teamID)")
        return
      }
      try check(rec.createdBy == "coordinator" && rec.connectedApps.isEmpty, "Bot \(i) records creator and starts with zero connected apps")
      records.append(rec)
    }
    try check(records.count == 10, "AutoTeamPolicy admits more than 2 bots and more than 1 team without artificial caps")

    let dup = AutoTeamPolicy.admit(
      id: "bot-dup", role: "SPECIALIST-1", createdBy: "bot-2", parentTaskID: "team-1",
      existing: records, activeChain: ["coordinator", "bot-2"])
    if case .reject = dup {
      try check(true, "Duplicate active role on the same task is rejected case-insensitively")
    } else {
      try check(false, "Duplicate active role must be rejected")
    }

    let cycle = AutoTeamPolicy.admit(
      id: "bot-2", role: "fresh-role", createdBy: "bot-3", parentTaskID: "team-2",
      existing: records, activeChain: ["coordinator", "bot-2", "bot-3"])
    if case .reject = cycle {
      try check(true, "Cycle in activeChain is rejected")
    } else {
      try check(false, "Cycle in activeChain must be rejected")
    }
  }

  // MARK: - Allow all upgrade migration

  private static func checkAllowAllUpgrade(_ check: Check) throws {
    try check(ApprovalLevel.newInstallDefault == .proactive, "New installs default to Allow all (.proactive)")
    try check(ApprovalLevel.resolve(stored: nil) == .everyStep, "Unreadable/missing stored approval still fails closed to .everyStep")

    let upgraded = AssistantMigration.allowAllUpgrade(stored: ApprovalLevel.riskyOnly.rawValue, userSet: false, migrated: false)
    try check(upgraded?.previous == .riskyOnly, "One-time upgrade preserves previous level for Undo")
    try check(
      upgraded?.writes == [
        .string(AssistantMigration.autopilotKey, ApprovalLevel.proactive.rawValue),
        .bool(ApprovalLevel.allowAllMigratedKey, true),
        .bool(ApprovalLevel.defaultedKey, true),
      ],
      "One-time upgrade writes .proactive and migration flags")
    try check(
      AssistantMigration.allowAllUpgrade(stored: ApprovalLevel.everyStep.rawValue, userSet: true, migrated: false) == nil,
      "User-selected approval level is respected and not overwritten")
    try check(
      AssistantMigration.allowAllUpgrade(stored: ApprovalLevel.proactive.rawValue, userSet: false, migrated: true) == nil,
      "Allow all migration is idempotent once migrated")
  }

  // MARK: - peer_swarm parsing & plan Codable

  private static func checkPeerSwarmTools(_ check: Check) throws {
    let parsed = PeerTools.parse("peer_swarm", [
      "goal": "Ship feature",
      "workers": [
        ["name": "Coder", "agent": "codex", "task": "Implement core", "write": true],
        ["name": "Auditor", "agent": "codex", "task": "Inspect edge cases"],
      ],
      "verifier": "codex",
      "rounds": 2,
    ])
    guard case .success(.swarm(let req)) = parsed else {
      try check(false, "peer_swarm parses same-CLI workers and verifier")
      return
    }
    try check(req.workers.count == 2 && req.workers[0].write && !req.workers[1].write && req.verifier == .codex,
      "peer_swarm preserves write flags and verifier")

    let dupWorker = PeerTools.parse("peer_swarm", [
      "goal": "Ship feature",
      "workers": [
        ["name": "Alpha", "agent": "codex", "task": "one"],
        ["name": "alpha", "agent": "claude", "task": "two"],
      ],
    ])
    if case .failure = dupWorker {
      try check(true, "Duplicate swarm worker names are refused")
    } else {
      try check(false, "Duplicate swarm worker names must be refused")
    }

    let plan = SwarmPlan(
      goal: .init(title: "Ship", line: "Ship feature"),
      tasks: ["coder": "Implement core", "verifier": "Check"],
      threads: [SwarmPlan.Thread(id: "t-1", title: "Execute", goal: "Build", tasks: ["coder"])])
    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(SwarmPlan.self, from: data)
    try check(decoded == plan, "SwarmPlan round-trips cleanly through Codable")
  }

  // MARK: - End-to-end peer_swarm over real Engines

  private static func checkPeerSwarmExecution(_ check: Check) throws {
    let folder = URL(fileURLWithPath: "/tmp/swarm-checks")
    let top = PeerCaller(thread: ThreadKey("swarm-top"), cli: .codex, access: .project(folder: folder, level: .full))
    try swarmWorld(check) { world, notes in
      let peers = world.peers
      await peers.register(task: "swarm-top", caller: top)

      // 1. Same-CLI swarm (3 codex workers + 1 read-only codex verifier) with one revision round.
      let sameCLI = PeerSwarmRequest(
        goal: "Verify same-CLI swarm",
        workers: [
          PeerSwarmWorker(name: "w1", agent: .codex, task: "SWARM-NEEDS-REV", write: true),
          PeerSwarmWorker(name: "w2", agent: .codex, task: "Inspect docs", write: false),
          PeerSwarmWorker(name: "w3", agent: .codex, task: "Inspect logs", write: false),
        ],
        verifier: .codex, rounds: 2)
      let reply = await peers.handle(.swarm(sameCLI), task: "swarm-top")
      notes.check(!reply.isError && reply.text.contains("The swarm verifier approved the final result."),
        "Same-CLI swarm (codex x4) runs, revises on verifier feedback, and reaches approval")

      let w1First = world.host.callees.first { $0.cli == .codex && $0.prompt.message.contains("You are 'w1'") }
      let w2First = world.host.callees.first { $0.cli == .codex && $0.prompt.message.contains("You are 'w2'") }
      let verifierCall = world.host.callees.first { $0.prompt.message.contains("You are the read-only verifier") }
      notes.check(w1First?.access == .project(folder: folder, level: .full), "Write worker inherits writable access")
      notes.check(w2First?.access == .project(folder: folder, level: .review), "Non-write worker is downgraded to .review")
      notes.check(verifierCall?.access == .project(folder: folder, level: .review), "Verifier is downgraded to .review")

      // 2. Multi-provider swarm without verifier.
      let multi = PeerSwarmRequest(
        goal: "Cross-provider summary",
        workers: [
          PeerSwarmWorker(name: "writer", agent: .claude, task: "Summarize code", write: false),
          PeerSwarmWorker(name: "checker", agent: .grok, task: "Check docs", write: false),
        ],
        verifier: nil, rounds: 1)
      let multiReply = await peers.handle(.swarm(multi), task: "swarm-top")
      notes.check(!multiReply.isError && multiReply.text.contains("Swarm completed."),
        "Multi-provider swarm completes cleanly without verifier")

      // 3. peer_stop cancels an active holding swarm cleanly.
      let held = PeerSwarmRequest(
        goal: "Stop test",
        workers: [PeerSwarmWorker(name: "holder", agent: .opencode, task: "SWARM-HOLD", write: false)],
        verifier: nil, rounds: 1)
      let waitingReply = await peers.handle(.swarm(held), task: "swarm-top")
      notes.check(waitingReply.text.contains("still working"), "Long-running swarm yields with peer_wait guidance")
      let stopped = await peers.handle(.stop(run: nil), task: "swarm-top")
      notes.check(stopped.text.contains("stopped"), "peer_stop cancels the swarm coordinator and its workers")

      // 4. callerEnded evicts settled runs for the caller.
      await peers.callerEnded(top.thread)
      await peers.register(task: "swarm-top", caller: top)
      let afterCleanup = await peers.handle(.wait(runs: [], seconds: 1), task: "swarm-top")
      notes.check(afterCleanup.text == "No team runs of yours are open.", "callerEnded evicts settled runs for the caller")
    }
  }

  private static func swarmWorld(_ check: Check, _ body: @escaping @Sendable (SwarmWorld, SwarmNotes) async throws -> Void) throws {
    let records = RunRecords(root: FileManager.default.temporaryDirectory.appendingPathComponent("swarm-checks-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: records.root) }
    let processes = PeerProcesses()
    let drivers: [any Driver] = [HarnessDriver.claude, .codex, .grok, .opencode].map(SwarmScript.init)
    let engines = Engines(drivers: drivers, host: processes, records: records, sleep: { _ in await Task.yield() }, tickEvery: .seconds(3_600))
    var limits = Peers.Limits()
    limits.inlineCap = .milliseconds(450)
    let host = FakePeerHost()
    let world = SwarmWorld(peers: Peers(engines: engines, host: host, limits: limits), host: host)
    let done = DispatchSemaphore(value: 0)
    let box = SwarmBox()
    let notes = SwarmNotes()
    Task {
      do { try await body(world, notes) } catch { box.error = error }
      await engines.shutdown()
      done.signal()
    }
    guard done.wait(timeout: .now() + 30) == .success else { throw SereinError.invalid("FAIL: swarm check timed out") }
    if let error = box.error { throw error }
    for (passed, label) in notes.all { try check(passed, label) }
  }

  // MARK: - GenericACPDriver, ACPSession steer, warmTags & loopback

  private static func checkGenericACPAndSteer(_ check: Check) throws {
    let customSpec = ACPAgentSpec(
      cli: .grok, arguments: ["acp", "--fast"], cardWait: .seconds(250),
      model: .setModel, modelFlag: "--model", steerMethod: "session/steer", supportsCancelResumeSteer: true)
    let driver = GenericACPDriver(customSpec)
    let req = TurnRequest(
      thread: ThreadKey("generic-acp"), cli: .grok, executable: URL(fileURLWithPath: "/usr/bin/true"),
      access: .answer, prompt: TurnPrompt(stable: "", volatile: "", message: "hi", recovery: nil),
      model: "grok-4", effort: nil, resume: nil, browser: nil, taskID: "t")
    let contract = try driver.contract(for: req, network: ShellNetwork.Plan(port: 0))
    try check(
      contract.arguments == ["acp", "--fast", "--model", "grok-4"] && contract.sandboxProfile != nil,
      "GenericACPDriver derives launch arguments, modelFlag, and fileGuard sandbox profile from ACPAgentSpec")
    try check(
      ACPDialect(cli: .grok).steerMethod == nil && !ACPDialect(cli: .grok).supportsCancelResumeSteer,
      "Built-in ACPDialect defaults preserve steers == false when steer capability is absent")

    // Live ACP steer verification over a fake ACP binary:
    // Case A: agent advertises agentCapabilities.steer = true -> engines.steer returns .steered.
    // Case B: agent has no capability, GenericACPDriver sets supportsCancelResumeSteer: true -> cancel-and-handback.
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("acp-steer-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let bin = dir.appendingPathComponent("fake-acp")
    let script = #"""
    #!/usr/bin/env python3
    import json, os, sys
    DIR = "\#(dir.path)"
    ADVERTISE = "--advertise-steer" in sys.argv
    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()
    def record(name, val):
        with open(os.path.join(DIR, name), "a") as f:
            f.write(json.dumps(val) + "\n")
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        msg = json.loads(line)
        mid = msg.get("id")
        method = msg.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": False, "promptCapabilities": {"image": False}, "steer": ADVERTISE}
            }})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s-1"}})
        elif method == "session/set_model":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/prompt":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "s-1",
                "update": {"sessionUpdate": "tool_call", "toolCallId": "tc-1", "name": "look", "kind": "read", "status": "in_progress"}
            }})
            while True:
                nline = sys.stdin.readline()
                if not nline:
                    break
                n = json.loads(nline)
                nm = n.get("method")
                if nm:
                    record("notifications", nm)
                if nm == "session/steer":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                    break
                if nm == "session/cancel":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}})
                    break
    """#
    try script.write(to: bin, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

    // Case A: dynamic advertisement with supportsCancelResumeSteer: false.
    let advertisedDriver = GenericACPDriver(ACPAgentSpec(
      cli: .grok, arguments: ["--advertise-steer"], cardWait: .seconds(60), supportsCancelResumeSteer: false))
    let recA = RunRecords(root: dir.appendingPathComponent("runsA"))
    let enginesA = Engines(
      drivers: [advertisedDriver], host: SereinProcessHost(records: recA), records: recA,
      sleep: { try? await Task.sleep(for: min($0, .milliseconds(50))) }, tickEvery: .seconds(3_600))
    let reqA = TurnRequest(
      thread: ThreadKey("adv"), cli: .grok, executable: bin, access: .project(folder: dir, level: .commands),
      prompt: TurnPrompt(stable: "", volatile: "", message: "go", recovery: nil), model: nil, effort: nil, resume: nil, browser: nil, taskID: "ta")
    let steerResultA: (SteerOutcome?, StopReason?) = try acpBlocking {
      let handle = try await enginesA.send(reqA)
      var outcome: SteerOutcome?
      var reason: StopReason?
      for await event in handle.events {
        if case .toolStarted = event, outcome == nil {
          outcome = await enginesA.steer(reqA.thread, "nudge")
        } else if case .ended(let end) = event {
          reason = end.stopReason
        }
      }
      await enginesA.shutdown()
      return (outcome, reason)
    }
    try check(steerResultA.0 == .steered && steerResultA.1 == .endTurn,
      "ACP agent advertising capabilities.steer receives session/steer and returns .steered")

    // Case B: GenericACPDriver cancel-and-resume steer when agent has no steer method.
    let cancelSteerDriver = GenericACPDriver(ACPAgentSpec(
      cli: .grok, arguments: ["--cancel-steer"], cardWait: .seconds(60), supportsCancelResumeSteer: true))
    let recB = RunRecords(root: dir.appendingPathComponent("runsB"))
    let enginesB = Engines(
      drivers: [cancelSteerDriver], host: SereinProcessHost(records: recB), records: recB,
      sleep: { try? await Task.sleep(for: min($0, .milliseconds(50))) }, tickEvery: .seconds(3_600))
    let reqB = TurnRequest(
      thread: ThreadKey("cancel-steer"), cli: .grok, executable: bin, access: .project(folder: dir, level: .commands),
      prompt: TurnPrompt(stable: "", volatile: "", message: "go", recovery: nil), model: nil, effort: nil, resume: nil, browser: nil, taskID: "tb")
    let steerResultB: (SteerOutcome?, StopReason?) = try acpBlocking {
      let handle = try await enginesB.send(reqB)
      var outcome: SteerOutcome?
      var reason: StopReason?
      for await event in handle.events {
        if case .toolStarted = event, outcome == nil {
          outcome = await enginesB.steer(reqB.thread, "redirect")
        } else if case .ended(let end) = event {
          reason = end.stopReason
        }
      }
      await enginesB.shutdown()
      return (outcome, reason)
    }
    let notesLog = (try? String(contentsOf: dir.appendingPathComponent("notifications"), encoding: .utf8)) ?? ""
    try check(
      steerResultB.0 == .handedBack("redirect") && steerResultB.1 == .stopped && notesLog.contains("session/cancel"),
      "GenericACPDriver cancel-resume steer cancels active prompt via session/cancel and hands words back")
  }

  private static func checkWarmTagsAndLoopback(_ check: Check) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-warm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    var driver = CodexDriver(inherited: [:], home: home.path)
    driver.checkConfigLayers = false
    let req1 = TurnRequest(
      thread: ThreadKey("c1"), cli: .codex, executable: URL(fileURLWithPath: "/usr/bin/true"),
      access: .project(folder: home, level: .full),
      prompt: TurnPrompt(stable: "", volatile: "", message: "one", recovery: nil),
      model: nil, effort: nil, resume: nil, browser: nil, taskID: "t1")
    let req2 = TurnRequest(
      thread: ThreadKey("c2"), cli: .codex, executable: URL(fileURLWithPath: "/usr/bin/true"),
      access: .project(folder: home, level: .review),
      prompt: TurnPrompt(stable: "", volatile: "", message: "one", recovery: nil),
      model: nil, effort: nil, resume: nil, browser: nil, taskID: "t2")
    let c1 = try driver.contract(for: req1, network: ShellNetwork.Plan(port: 0))
    let c2 = try driver.contract(for: req2, network: ShellNetwork.Plan(port: 0))
    try check(c1.environment["SEREIN_CODEX_THREAD"] == nil && c2.environment["SEREIN_CODEX_THREAD"] == nil,
      "CodexDriver keeps synthetic thread hash out of child environment")
    try check(c1.warmTags["codexThread"] != nil && c1.warmTags["codexThread"] != c2.warmTags["codexThread"],
      "CodexDriver tracks thread config hash via LaunchContract.warmTags")
    try check(c1.warmKey.changed(from: c2.warmKey).contains("tag:codexThread"),
      "LaunchContract.warmTags invalidates warmKey across distinct thread configs")

    try check(HarnessStuck.isLoopbackAddress("127.0.0.1"), "127.0.0.1 counts as loopback")
    try check(HarnessStuck.isLoopbackAddress("::1") && HarnessStuck.isLoopbackAddress("[::1]"), "IPv6 loopback counts as loopback")
    try check(HarnessStuck.isLoopbackAddress(" LOCALHOST "), "localhost counts as loopback case-insensitively")
    try check(!HarnessStuck.isLoopbackAddress("api.anthropic.com") && !HarnessStuck.isLoopbackAddress("8.8.8.8"),
      "External hosts do not count as loopback")
  }
}

private struct SwarmWorld: Sendable {
  let peers: Peers
  let host: FakePeerHost
}

private final class SwarmBox: @unchecked Sendable {
  var error: Error?
}

private final class SwarmNotes: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [(Bool, String)] = []
  var all: [(Bool, String)] { lock.withLock { items } }
  func check(_ passed: Bool, _ label: String) { lock.withLock { items.append((passed, label)) } }
}

private struct SwarmScript: Driver {
  let cli: HarnessDriver
  let cardWait = Duration.seconds(118)
  init(_ cli: HarnessDriver) { self.cli = cli }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(request, arguments: [], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    let mode = try ModeCheck.verify(contract.expectedMode, reported: ["approvalPolicy": "never"], argv: contract.argv).get()
    return SwarmSession(cli: cli, mode: mode)
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class SwarmSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation
  private let cli: HarnessDriver

  init(cli: HarnessDriver, mode: VerifiedMode) {
    self.cli = cli
    self.mode = mode
    (wire, continuation) = AsyncStream<WireEvent>.makeStream()
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    let asked = prompt.message
    continuation.yield(.accepted)
    if asked.contains("SWARM-HOLD") {
      continuation.yield(.text("holding"))
      return
    }
    let reply: String
    if asked.contains("You are the read-only verifier") {
      reply = asked.contains("round 2") ? "\(PeerTools.approved) verified all slices." : "NEEDS FIX: @w1 missing edge test"
    } else if asked.contains("Revise your slice") {
      reply = "revised slice for \(cli.rawValue)"
    } else {
      reply = "completed slice by \(cli.rawValue)"
    }
    continuation.yield(.text(reply))
    continuation.yield(.turnDone(.endTurn))
  }

  func steer(_ text: String) async -> SteerOutcome { .steered }
}
#endif
