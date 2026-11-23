#if DEBUG
import Foundation
import SereinCore
@testable import SereinEngines

/// The app's side of Engines over fake CLIs: a chat thread keeps one warm process across its
/// turns, a team-tools callee gets the access the hub gives its own CLI, and a fallback helper is
/// never a signed-out CLI.
extension AssistantCoreChecks {
  static func bridge(_ check: Check) throws {
    try MainActor.assumeIsolated {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appendingPathComponent("engine-bridge-\(UUID().uuidString)").resolvingSymlinksInPath()
      let folder = root.appendingPathComponent("project")
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: root) }
      let browser = try BrowserModel(root: root.appendingPathComponent("library"))
      defer { browser.shutdown() }
      let agent = AgentModel(browser: browser, discoverProviders: false)
      let log = BridgeLog()
      let engines = Engines(
        drivers: [HarnessDriver.claude, .codex, .grok].map { BridgeDriver(cli: $0, log: log) }, host: PeerProcesses(),
        records: RunRecords(root: root.appendingPathComponent("runs")), tickEvery: .seconds(3_600))
      agent.hub.engines = engines
      let registry = HarnessRegistry.shared
      let saved = [HarnessDriver.claude, .codex, .grok].map { ($0, registry.snapshot(Provider($0))) }
      defer { for (driver, snapshot) in saved { registry.assume(driver, snapshot) } }
      @MainActor func ready(_ driver: HarnessDriver, signedIn: Bool = true) {
        var snapshot = HarnessSnapshot(instance: HarnessInstance(driver: driver), status: .ready)
        snapshot.installed = true
        snapshot.path = "/usr/bin/true"
        snapshot.version = driver.minimumCLIVersion
        snapshot.signedIn = signedIn
        registry.assume(driver, snapshot)
      }
      for driver in [HarnessDriver.claude, .codex, .grok] { ready(driver) }
      @MainActor func until(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
      }
      @MainActor func wait<T>(_ body: @escaping @MainActor () async -> T) -> T? {
        let box = BridgeBox<T>()
        Task { @MainActor in box.value = await body() }
        _ = until(20) { box.value != nil }
        return box.value
      }

      // A chat thread's turns share one browser task, so its warm CLI stays.
      agent.clear()
      agent.provider = .claude
      agent.pin(.claude, executable: "/usr/bin/true")
      agent.mode = .answer
      let actions = agent.allowActions
      defer { agent.allowActions = actions }
      let thread = agent.conversationID
      var requests: [TurnRequest?] = []
      for word in ["one", "two"] {
        agent.send("Say \(word)")
        try check(until(15) { !agent.running } && agent.error == nil, "bridge: chat turn '\(word)' ends without an error")
        requests.append(agent.hub.latest(for: thread)?.engineRequest)
      }
      let opened = { log.opens.filter { $0.thread.id == thread }.count }
      try check(
        requests[0]?.browser != nil && requests[0]?.browser?.arguments == requests[1]?.browser?.arguments
          && requests[0]?.taskID == requests[1]?.taskID,
        "bridge: a chat's second turn starts with the same browser capability as its first")
      try check(opened() == 1 && log.sent.filter { $0.thread.id == thread }.count == 2, "bridge: two turns on one chat thread run in one warm process")
      let kept = requests[0]?.taskID ?? ""
      agent.allowActions = !actions
      agent.send("Say three")
      try check(until(15) { !agent.running } && agent.error == nil, "bridge: chat turn 'three' ends without an error")
      let changed = agent.hub.latest(for: thread)?.engineRequest
      try check(
        changed?.taskID != kept && browser.tasks[kept] == nil && opened() == 2,
        "bridge: a turn with other browser grants gets a new task, the parked one ends, and a new process starts")
      agent.clear()

      // A team-tools callee: the hub's verdict and level for its own CLI in the caller's folder.
      browser.projects.append(Project(name: "engine-bridge", path: folder.path, source: .added))
      let peers = Peers(engines: engines, host: AppPeerHost(browser: browser, engines: engines))
      @MainActor func ask(_ callee: HarnessDriver, from access: Access) -> (reply: PeerReply?, request: TurnRequest?) {
        let task = "bridge-\(UUID().uuidString)"
        let reply = wait {
          await peers.register(task: task, caller: PeerCaller(thread: ThreadKey(task), cli: .codex, access: access))
          return await peers.handle(.ask(agents: [callee], question: "Say ok"), task: task)
        }
        return (reply, log.opens.last { $0.thread.id.hasPrefix(task + ">") })
      }
      let grok = ask(.grok, from: .task(folder: folder))
      guard case .refused(let refusal) = registry.verdict(Provider(.grok), mode: "project", edits: true, permission: .auto) else {
        return try check(false, "bridge: the hub refuses Grok in a project folder")
      }
      try check(
        grok.reply?.text.contains("grok: failed") == true && grok.reply?.text.contains(refusal) == true && grok.request == nil,
        "bridge: a callee the hub refuses in a project folder is refused there too, before any process starts")
      let claude = ask(.claude, from: .task(folder: folder))
      try check(
        claude.reply?.text.contains("claude: answered") == true && claude.request?.access == .project(folder: folder, level: .commands),
        "bridge: a delegated task's callee runs at Commands, not Full, in a project without the Full access confirmation")
      let edits = ask(.claude, from: .project(folder: folder, level: .edits))
      try check(edits.request?.access == .project(folder: folder, level: .edits), "bridge: a callee never gets more than its caller's level")
      try check(
        (try? AppPeerHost.access(.claude, within: .web, projects: browser.projects)) == nil,
        "bridge: no callee runs outside a project task")

      // The fallback helper (and the judge it serves) skips a signed-out CLI.
      let held = (agent.provider, agent.available)
      defer { (agent.provider, agent.available) = held }
      agent.available = [.claude: "/usr/bin/true", Provider(.codex): "/usr/bin/true"]
      agent.provider = Provider(.gemini)
      ready(.claude, signedIn: false)
      try check(
        agent.helperProvider == Provider(.codex) && agent.hub.helper?()?.0 == Provider(.codex),
        "bridge: with Claude Code signed out, the helper and the judge use the signed-in Codex")
      ready(.codex, signedIn: false)
      try check(
        agent.helperExecutable == nil && agent.hub.helper?() == nil, "bridge: with every fallback signed out, no helper starts")
      _ = wait { await engines.shutdown() }
    }
  }
}

private final class BridgeBox<T>: @unchecked Sendable {
  var value: T?
}

private final class BridgeLog: @unchecked Sendable {
  private let lock = NSLock()
  private var opened: [TurnRequest] = []
  private var turns: [TurnRequest] = []
  var opens: [TurnRequest] { lock.withLock { opened } }
  var sent: [TurnRequest] { lock.withLock { turns } }
  func open(_ request: TurnRequest) { lock.withLock { opened.append(request) } }
  func send(_ request: TurnRequest) { lock.withLock { turns.append(request) } }
}

/// A CLI that answers "<cli> says: <message>"; the log keeps each process start and each turn.
private struct BridgeDriver: Driver {
  let cli: HarnessDriver
  let log: BridgeLog
  let cardWait = Duration.seconds(118)

  func contract(for request: TurnRequest, network: ShellNetwork.Plan) throws -> LaunchContract {
    LaunchContract(request, arguments: [], environment: [:], expectedMode: .reports(["approvalPolicy": "never"]), network: network)
  }

  func open(_ process: EngineProcess, contract: LaunchContract, request: TurnRequest) async throws -> any EngineSession {
    log.open(request)
    let mode = try ModeCheck.verify(contract.expectedMode, reported: ["approvalPolicy": "never"], argv: contract.argv).get()
    return BridgeSession(cli: cli, log: log, mode: mode)
  }

  func probe(executable: URL) async -> Readiness { .ready(version: "1") }
}

private final class BridgeSession: EngineSession, @unchecked Sendable {
  let mode: VerifiedMode
  let wire: AsyncStream<WireEvent>
  private let continuation: AsyncStream<WireEvent>.Continuation
  private let cli: HarnessDriver
  private let log: BridgeLog

  init(cli: HarnessDriver, log: BridgeLog, mode: VerifiedMode) {
    self.cli = cli
    self.log = log
    self.mode = mode
    (wire, continuation) = AsyncStream<WireEvent>.makeStream()
  }

  func send(_ prompt: TurnPrompt, request: TurnRequest) async throws {
    log.send(request)
    continuation.yield(.accepted)
    continuation.yield(.text("\(cli.rawValue) says: \(prompt.message)"))
    continuation.yield(.turnDone(.endTurn))
  }

  func steer(_ text: String) async -> SteerOutcome { .steered }
}
#endif
