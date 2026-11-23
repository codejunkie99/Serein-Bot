#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The app's bridge to Engines, with a fake Claude Code registered only here: a send runs as an
/// engine turn with the shared prompt, a refusal reaches the chat and `dispatch`, words handed
/// back are kept, helpers answer through Engines, and a delegated task holds the team tools
/// only while its run lasts.
@MainActor func checkEngineWiring(browser: BrowserModel, agent: AgentModel, root: URL, check: (Bool, String) throws -> Void) async throws {
  let fm = FileManager.default
  let records = RunRecords(root: root.appendingPathComponent("engine-wiring-runs"))
  let script = WiringScript()
  let processes = PeerProcesses()
  let engines = Engines(drivers: [script], host: processes, records: records, tickEvery: .seconds(3_600))
  let peers = Peers(engines: engines, host: FakePeerHost())
  let (savedEngines, savedPeers) = (agent.hub.engines, agent.hub.peers)
  agent.hub.engines = engines
  agent.hub.peers = peers
  defer {
    agent.hub.engines = savedEngines
    agent.hub.peers = savedPeers
  }
  func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    return condition()
  }
  // Outside the library: assistants never work inside Serein's own data.
  let folder = fm.temporaryDirectory.appendingPathComponent("engine-wiring-\(UUID().uuidString)").resolvingSymlinksInPath()
  try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: folder) }
  let project = Project(name: "engine-wiring", path: folder.path, source: .added)
  browser.projects.append(project)
  agent.clear()
  agent.provider = .claude
  agent.pin(.claude, executable: "/usr/bin/true")
  // File modes need a probed version (HarnessVersionGate): this one is at Claude Code's floor.
  let probed = HarnessRegistry.shared.snapshot(.claude)
  var floor = HarnessSnapshot(instance: HarnessInstance(driver: .claude), status: .ready)
  floor.version = HarnessDriver.claude.minimumCLIVersion
  HarnessRegistry.shared.assume(.claude, floor)
  defer { HarnessRegistry.shared.assume(.claude, probed) }
  agent.mode = .research

  // 1. A send on a CLI with a driver is an engine turn: its reply shows in the thread.
  agent.send("Say ready")
  try check(
    await until(15) { !agent.running } && agent.error == nil
      && agent.messages.last?.text.contains("claude says: Say ready") == true && processes.spawned.count == 1,
    "A send on a CLI with a driver runs through Engines and its reply shows in the thread")
  let sent = try script.requests.last.unwrapped("The fake CLI got no turn")
  try check(
    sent.prompt.stable.hasPrefix(TaskPrompt.core(served: Set(sent.browser?.tools ?? [])) + "\n\n" + WiringScript.addition)
      && !sent.prompt.stable.contains("Mode: ") && sent.prompt.volatile.contains("Mode: \(TaskMode.research.rawValue)"),
    "The turn's stable prompt is the shared core, then the CLI's own lines; the mode rides in the volatile part")
  try check(sent.access == .web && sent.browser != nil && sent.stepBudget != nil, "A research turn runs with web access, the browser server and a step budget")

  // A secure card that outlasts its tool call parks the turn: it waits for the person, not failed.
  // A shell call still waiting on a host card when the turn ends parks it too; the person's later
  // answer sends one follow-up turn.
  agent.send("SHELLCARD then end")
  let carded = try await until(5) { script.requests.last?.prompt.message.contains("SHELLCARD") == true }
    ? script.requests.last.unwrapped("No turn") : nil
  if let carded {
    let ask = PayGuard.Ask(task: carded.taskID, thread: carded.thread.id, host: "api.stripe.com", reason: .named, command: nil)
    let call = Task { await browser.secureCards.ask(ask) }
    _ = await until(2) { browser.secureCards.openHost(task: carded.taskID) != nil }
    call.cancel()
    _ = await call.value
  }
  try check(
    await until(10) { !agent.running } && agent.hub.latest(for: agent.conversationID)?.record.outcome == .waiting
      && agent.hub.latest(for: agent.conversationID)?.record.summary == SecureCard.parkSummary(host: "api.stripe.com"),
    "A turn that ends with a host card open waits for the person, naming the host")
  let before = script.requests.count
  browser.intelligenceAgent = agent
  if let card = browser.secureCards.hosts.first { browser.secureCards.answerHost(card.id, allowed: true) }
  let followUp = PayGuard.followUp(host: "api.stripe.com", allowed: true)
  try check(
    await until(10) { !agent.running && script.requests.count > before }
      && script.requests.dropFirst(before).map(\.prompt.message).filter { $0.contains(followUp) }.count == 1,
    "The person's later answer sends exactly one follow-up turn")
  _ = await until(10) { !agent.running }
  try check(script.requests.count == before + 1, "And no other turn")

  // 2. Words sent while the CLI cannot take them come back for the next turn.
  agent.send("HOLD and wait")
  try check(await until(10) { agent.hub.run(for: agent.conversationID)?.engineTurn?.started == true }, "A held turn started in Engines")
  let held = try agent.hub.run(for: agent.conversationID).unwrapped("No run for the held turn")
  var back: [String] = []
  agent.hub.steer(held, "and then this") { back += $0 }
  try check(await until(5) { back == ["and then this"] }, "Words the CLI hands back go back to the composer, never dropped")
  agent.cancel()
  try check(await until(10) { !agent.running }, "Stop ends an engine turn")

  // 3. Helpers answer through Engines.
  let answer = try await StructuredAgent(engines: engines).run(executable: "/usr/bin/true", provider: .claude, model: "", prompt: "Return ok")
  try check(answer == "claude says: Return ok", "A helper request on a CLI with a driver is answered through Engines")
  try check(script.requests.last?.access == .answer && script.requests.last?.browser == nil, "A helper turn is a pure answer with no browser")

  // 4. A delegated task's turn holds the team tools while it runs, and loses them when it ends.
  let target = AgentModel.DispatchTarget(mode: .project, provider: .claude, projectID: project.id, edits: true, initiator: .delegated)
  let thread = try await agent.dispatch("HOLD the task", into: nil, create: true, as: target)
  let task = try (agent.hub.run(for: thread)?.engineRequest).unwrapped("The task did not run through Engines")
  var taskFolder: String?
  if case .task(let url) = task.access { taskFolder = url.standardizedFileURL.path }
  try check(taskFolder == folder.standardizedFileURL.path, "A delegated project task runs as a task in its project")
  let during = await peers.handle(.stop(run: nil), task: task.taskID)
  try check(!during.isError, "A running task's agent holds the team tools")
  agent.hub.run(for: thread).map { agent.hub.stop($0) }
  try check(await until(10) { agent.hub.run(for: thread) == nil }, "The task stopped")
  var after = await peers.handle(.stop(run: nil), task: task.taskID)
  for _ in 0..<250 where !after.isError {
    try? await Task.sleep(nanoseconds: 20_000_000)
    after = await peers.handle(.stop(run: nil), task: task.taskID)
  }
  try check(after.isError, "Once the task's run ends its agent holds no team tools")

  // 5. A refusal before any process starts ends the run with its reason, and fails `dispatch`.
  script.refuse = true
  defer { script.refuse = false }
  let spawned = processes.spawned.count
  do {
    _ = try await agent.dispatch("Anything", into: nil, create: true, as: target)
    try check(false, "A refused engine turn fails dispatch")
  } catch {
    try check(
      error.localizedDescription == "Claude Code cannot run this kind of task." && processes.spawned.count == spawned,
      "A refused engine turn fails dispatch with the refusal's words, and nothing started")
  }
  agent.clear()
  agent.provider = .claude
  agent.mode = .research
  agent.send("Say ready")
  try check(
    await until(10) { !agent.running } && agent.error == "Claude Code cannot run this kind of task.",
    "A refused engine turn shows its reason in the thread")
  agent.clear()
  await engines.shutdown()
}

private extension Optional {
  func unwrapped(_ why: String) throws -> Wrapped {
    guard let self else { throw SereinError.invalid("FAIL: " + why) }
    return self
  }
}

/// A fake Claude Code: answers "claude says: <message>", ends a second later on SHELLCARD,
/// keeps working on HOLD, hands back every
/// word sent mid-turn, and refuses before starting when asked.
private final class WiringScript: Driver, @unchecked Sendable {
  static let addition = "WIRING-CHECK: this CLI's own lines."
  let cli = HarnessDriver.claude
  let cardWait = Duration.seconds(118)
  let promptAddition = WiringScript.addition
  private let lock = NSLock()
  private var seen: [TurnRequest] = []
  private var refusing = false
  var requests: [TurnRequest] { lock.withLock { seen } }
  var refuse: Bool {
    get { lock.withLock { refusing } }
    set { lock.withLock { refusing = newValue } }
  }

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    if refuse { throw EngineRefusal.cliCannot(request.access) }
    lock.withLock { seen.append(request) }
    return LaunchContract(request, arguments: [], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    WiringSession(mode: try ModeCheck.verify(contract.expectedMode, reported: ["approvalPolicy": "never"], argv: contract.argv).get())
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class WiringSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation

  init(mode: VerifiedMode) {
    self.mode = mode
    (wire, continuation) = AsyncStream<WireEvent>.makeStream()
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    continuation.yield(.accepted)
    if prompt.message.contains("SHELLCARD") {
      continuation.yield(.text("calling a payment service"))
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      continuation.yield(.turnDone(.endTurn))
      return
    }
    if prompt.message.contains("HOLD") {
      continuation.yield(.text("working on it"))
      return
    }
    continuation.yield(.text("claude says: \(prompt.message)"))
    continuation.yield(.turnDone(.endTurn))
  }

  func steer(_ text: String) async -> SteerOutcome { .handedBack(text) }
}
#endif
