import Foundation
import SereinCore
import SereinEngines

/// Bounded, no-tool requests (routing, the turn judge, tab groups, proofreading) on the user's
/// harness, through Engines.
final class StructuredAgent: @unchecked Sendable {
  private let engines: Engines
  init(engines: Engines = .shared) { self.engines = engines }
  private let lock = NSLock()
  /// Stops the engine thread answering the current request; main actor only.
  private var stopper: (@MainActor () -> Void)?
  private var cancelled = false
  /// The current `run`; a callback from an older one (cancelled when a newer one began) is stale.
  private var generation = 0
  func cancel() {
    let stop = lock.withLock {
      cancelled = true
      return stopper
    }
    Task { @MainActor in stop?() }
  }

  /// Starts what the next request on `provider` needs, with no model call.
  @MainActor static func prewarm(_ provider: Provider, executable: String?, model: String) {
    guard let executable, let cli = provider.driver, Engines.shared.runs(cli), configProblem(cli) == nil,
      let request = try? helperRequest(cli, executable: executable, model: model, prompt: "", thread: helperThread(cli))
    else { return }
    Task { try? await Engines.shared.prewarm(request) }
  }

  /// Why `provider` cannot answer helper requests, or nil. Grok's and Cursor's own config files
  /// count first (configProblem).
  @MainActor static func refusal(_ provider: Provider) -> String? {
    guard let driver = provider.driver, HelperWire.drivers.contains(driver) else {
      return "\(provider.rawValue) cannot answer Serein's helper requests."
    }
    if let problem = configProblem(driver) { return problem }
    if driver == .grok { return nil }
    let verdict = HarnessRegistry.shared.verdict(provider, mode: "answer", edits: false, permission: .supervised)
    return verdict.allowed ? nil : verdict.reason ?? "\(driver.displayName) cannot answer here."
  }
  /// True when `provider` can answer helper requests.
  @MainActor static func offered(_ provider: Provider) -> Bool { refusal(provider) == nil }

  func run(executable: String, provider: Provider, model: String, prompt: String) async throws -> String {
    let id = lock.withLock {
      generation += 1
      cancelled = false
      stopper = nil
      return generation
    }
    // A later cancel must not reach a thread this request has finished with.
    defer { lock.withLock { if generation == id { stopper = nil } } }
    return try await withTaskCancellationHandler(
      operation: {
        // The fixed launch arguments below need a CLI new enough to know them; refuse with the
        // update instruction instead of the CLI's own argument error.
        if let driver = provider.driver, driver.minimumCLIVersion != nil {
          // A CLI below the floor may be updating itself in the background: wait for it.
          if let update = await MainActor.run(body: { HarnessRegistry.shared.autoUpdate(driver) }) { await update.value }
          let version = await MainActor.run { HarnessRegistry.shared.snapshot(provider)?.version }
          if let reason = HarnessVersionGate.refusal(driver: driver, version: version, mode: "answer") {
            throw SereinError.invalid(reason)
          }
        }
        if let cli = provider.driver, engines.runs(cli) {
          if let problem = await MainActor.run(body: { Self.configProblem(cli) }) { throw SereinError.invalid(problem) }
          var model = model
          // With no model OpenCode answers on its own default, which may be paid: the one it lists runs instead.
          if cli == .opencode, model.split(separator: "/", maxSplits: 1).count != 2 {
            let listed = await MainActor.run { HarnessRegistry.shared.models(provider) }
            guard let pick = listed.first(where: \.isDefault) ?? listed.first else {
              throw SereinError.invalid("OpenCode lists no model yet. Connect a provider in OpenCode, for example your free DeepSeek model.")
            }
            model = pick.id
          }
          return try await engineAnswer(cli, executable: executable, model: model, prompt: prompt, run: id)
        }
        throw SereinError.invalid("\(provider.rawValue) cannot answer Serein's helper requests.")
      }, onCancel: { self.cancel() })
  }

  /// Helpers share one warm thread per CLI. A request that finds it busy (still opening, or
  /// answering an earlier request such as the last turn's judge when the next turn ends quickly)
  /// waits for it up to `sharedWait`, then gets a thread of its own, closed after.
  private func engineAnswer(_ cli: HarnessDriver, executable: String, model: String, prompt: String, run id: Int) async throws -> String {
    func ask(_ thread: ThreadKey) async throws -> String {
      let stopped = lock.withLock {
        guard generation == id else { return true }
        stopper = { @MainActor [engines] in Task { await engines.stop(thread) } }
        return cancelled
      }
      guard !stopped, !Task.isCancelled else { throw CancellationError() }
      let request = try await MainActor.run { try Self.helperRequest(cli, executable: executable, model: model, prompt: prompt, thread: thread) }
      return try await engines.ask(request)
    }
    let deadline = ContinuousClock.now + Self.sharedWait
    while true {
      do {
        return AgentPrivacy.redact(try await ask(Self.helperThread(cli)))
      } catch EngineRefusal.threadBusy where ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      } catch EngineRefusal.threadBusy {
        break
      }
    }
    let own = ThreadKey("helper:\(cli.rawValue):\(UUID().uuidString)")
    defer { Task { [engines] in await engines.close(own) } }
    return AgentPrivacy.redact(try await ask(own))
  }

  /// Why Grok's or Cursor's own config files keep helper requests off it, or nil. Read again
  /// after five seconds, so a change there counts before the next request.
  @MainActor static func configProblem(_ cli: HarnessDriver) -> String? {
    let read: () -> String?
    switch cli {
    case .grok:
      read = {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"] ?? NSHomeDirectory() + "/.grok"
        return GrokPreflight.problem(config: try? String(contentsOfFile: home + "/config.toml", encoding: .utf8))
      }
    case .cursor:
      // A helper may start before the first probe has read these files.
      read = { CursorPreflight.problem(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment, isolated: true) }
    default:
      return nil
    }
    if let last = configChecks[cli], Date().timeIntervalSince(last.at) < 5 { return last.problem }
    let problem = read()
    configChecks[cli] = (Date(), problem)
    return problem
  }
  @MainActor private static var configChecks: [HarnessDriver: (at: Date, problem: String?)] = [:]
  /// Checks change config files between requests.
  @MainActor static func forgetConfigChecks() { configChecks = [:] }
  /// A few short answers' worth: past it the shared thread is taken as stuck, and a process of
  /// its own (a cold start, about 3 s for `opencode acp`) is the faster way.
  private static let sharedWait: Duration = .seconds(15)

  private static func helperThread(_ cli: HarnessDriver) -> ThreadKey { ThreadKey("helper:\(cli.rawValue)") }

  @MainActor private static func helperRequest(_ cli: HarnessDriver, executable: String, model: String, prompt: String, thread: ThreadKey) throws -> TurnRequest {
    var request = TurnRequest(
      thread: thread, cli: cli, executable: URL(fileURLWithPath: executable), access: .answer,
      prompt: TurnPrompt(stable: HelperWire.instructions, volatile: "", message: AgentPrivacy.redact(prompt), recovery: nil),
      model: model.isEmpty ? nil : model, effort: nil, resume: nil, browser: nil, taskID: "")
    try HarnessRegistry.shared.prepare(&request, ownSetup: false)
    return request
  }
}
