import Darwin
import Foundation
import SereinCore

/// Explicit human choices for isolated native fixtures. This drives the real approval cards;
/// it does not change a gate, pregrant a site, or replace the confirmation implementation.
/// It ships in release builds only because `--stress` (scripts/stress.py builds `-c release`)
/// answers cards through it; a release build accepts only a marked `--stress` library.
@MainActor final class FixtureApprovals {
  struct Card {
    let title: String
    let detail: String
    let thread: String?
    let button: String
    let more: String?
    let moreName: String
    let app: String?
    let answer: ApprovalGate.HumanAnswer
    let beforeAnswer: (@MainActor () throws -> Void)?

    init(title: String, detail: String, thread: String? = nil, button: String = "Allow",
         more: String? = nil, moreName: String = "the script", app: String? = nil,
         answer: ApprovalGate.HumanAnswer = .yes,
         beforeAnswer: (@MainActor () throws -> Void)? = nil) {
      self.title = title
      self.detail = detail
      self.thread = thread
      self.button = button
      self.more = more
      self.moreName = moreName
      self.app = app
      self.answer = answer
      self.beforeAnswer = beforeAnswer
    }

    static func site(url: String, thread: String? = nil, first: Bool = true,
                     answer: ApprovalGate.HumanAnswer = .yes,
                     beforeAnswer: (@MainActor () throws -> Void)? = nil) -> Card {
      let host = TaskPass.host(url)
      return Card(title: "Serein wants to act on \(host)",
                  detail: first
                    ? "Allow this task to act on \(host). A yes covers only this task."
                    : "This task did not start on this site. A yes covers only this task.",
                  thread: thread, answer: answer, beforeAnswer: beforeAnswer)
    }

    /// A schedule's cost estimate depends on the tokens the fixture happens to count, so it is left out.
    private static func withoutEstimate(_ detail: String) -> String {
      detail.replacingOccurrences(of: #"\n(One run, likely|About \d+ runs)[^\n]*"#, with: "", options: .regularExpression)
    }
    fileprivate func matches(_ card: RelayOrchestrator.Approval) -> Bool {
      card.title == title && Self.withoutEstimate(card.detail) == Self.withoutEstimate(detail) && card.threadID == thread
        && card.button == button && card.more == more && card.moreName == moreName && card.app == app
    }
  }

  private final class Operation<Value> {
    var result: Result<Value, Error>?
  }
  private static weak var active: FixtureApprovals?
  let relay: RelayOrchestrator
  private let browser: BrowserModel
  private let ownsRelay: Bool
  private let restoreBackground: () -> Void
  private let previousOnEnd: ((AgentRun) -> Void)?
  private let previousChat: () -> Bool
  private let previousShown: () -> Bool
  private let previousQuiet: Bool
  private let previousArgumentDomain: [String: Any]?
  /// The approval level before a fixture Relay set Every step (GateSettings, in memory here).
  private let previousAutopilot: Any??
  private var operationTask: Task<Void, Never>?
  private var operationCards = Set<UUID>()
  private var closed = false

  /// The explicit invocation and an empty, regular, non-symlink marker must agree with the
  /// browser's resolved library inside a system temporary directory. No user library qualifies.
  /// The one marked-test-library check: main.swift's `--stress` gate uses it too.
  nonisolated static func isAllowed(root: URL) -> Bool {
    let arguments = CommandLine.arguments
    let stress = arguments.contains("--stress")
    #if DEBUG
    let verify = arguments.contains(where: { $0 == "--verify" || $0.hasPrefix("--verify-") })
    #else
    // Every --verify run is DEBUG-only, so a release build accepts --stress alone.
    let verify = false
    #endif
    guard stress || verify,
      let named = ProcessInfo.processInfo.environment["SEREIN_DATA_DIR"], named.hasPrefix("/")
    else { return false }
    let physical = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath() }
    let folder = physical(URL(fileURLWithPath: named, isDirectory: true))
    guard physical(root).path == folder.path else { return false }
    let temporary = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
      .map { physical($0).path }
    guard temporary.contains(where: { folder.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return false }
    let marker = folder.appendingPathComponent(stress ? ".serein-stress" : ".serein-verify")
    var info = stat()
    return lstat(marker.path, &info) == 0
      && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_size == 0
  }

  init(browser: BrowserModel, agent supplied: AgentModel? = nil) throws {
    guard Self.isAllowed(root: browser.library.root) else {
      throw SereinError.invalid("Fixture approvals require a marked temporary verification or stress library.")
    }
    guard Self.active == nil else { throw SereinError.invalid("A fixture approval session is already active.") }
    if let shared = RelayOrchestrator.shared, shared.browser !== browser {
      throw SereinError.invalid("The fixture cannot borrow another browser's Relay.")
    }
    let ownsRelay = RelayOrchestrator.shared == nil
    // A new fixture Relay asks on every step regardless of the user's saved preference. A
    // fixture run never opens GateSettings, so this value stays in memory and is put back at the
    // end; a borrowed Relay keeps its chosen policy.
    let defaults = UserDefaults.standard
    let previousArgumentDomain = ownsRelay ? defaults.volatileDomain(forName: UserDefaults.argumentDomain) : nil
    let previousAutopilot: Any?? = ownsRelay ? .some(GateSettings.shared.object(forKey: RelayOrchestrator.autopilotKey)) : nil
    if ownsRelay { GateSettings.shared.set(false, forKey: RelayOrchestrator.autopilotKey) }
    let agent = RelayOrchestrator.shared?.agent ?? supplied ?? AgentModel(browser: browser, discoverProviders: false)
    let previousOnEnd = ownsRelay ? agent.hub.onEnd : nil
    let relay = RelayOrchestrator.shared ?? RelayOrchestrator.start(agent: agent, browser: browser)
    let restoreBackground: () -> Void
    do { restoreBackground = try relay.suspendForFixtureApprovals() }
    catch {
      if ownsRelay {
        RelayOrchestrator.releaseFixtureRelay(relay)
        agent.hub.onEnd = previousOnEnd
      }
      if let previousArgumentDomain {
        defaults.setVolatileDomain(previousArgumentDomain, forName: UserDefaults.argumentDomain)
      }
      if let previousAutopilot { GateSettings.shared.set(previousAutopilot, forKey: RelayOrchestrator.autopilotKey) }
      throw error
    }
    self.browser = browser
    self.ownsRelay = ownsRelay
    self.previousOnEnd = previousOnEnd
    self.relay = relay
    self.restoreBackground = restoreBackground
    self.previousArgumentDomain = previousArgumentDomain
    self.previousAutopilot = previousAutopilot
    previousChat = relay.chatOnScreen
    previousShown = relay.chatShown
    previousQuiet = RelayOrchestrator.quietForChecks
    relay.chatOnScreen = { true }
    relay.chatShown = { true }
    RelayOrchestrator.quietForChecks = true
    Self.active = self
  }

  /// Run one operation and answer only its finite ordered list of exact cards. A missing,
  /// unexpected, or unused card fails the fixture; a timeout never supplies consent.
  func perform<Value>(expecting expected: [Card], timeout: TimeInterval = 10,
                      _ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
    guard !closed, Self.isAllowed(root: browser.library.root), operationTask == nil,
      relay.approvals.isEmpty, !relay.consentWaiting, relay.questionForms.isEmpty,
      timeout > 0, timeout <= 60, expected.allSatisfy({ $0.answer == .yes || $0.answer == .no })
    else { throw SereinError.invalid("The fixture approval operation is not isolated or has invalid expectations.") }
    let state = Operation<Value>()
    let tasksBefore = Set(browser.tasks.keys)
    let runsBefore = Set(relay.agent.hub.runs.map(\.id))
    let task = Task { @MainActor in
      do { state.result = .success(try await operation()) }
      catch { state.result = .failure(error) }
    }
    operationTask = task
    var answered = 0
    let deadline = Date().addingTimeInterval(timeout)
    defer {
      operationTask = nil
      operationCards.removeAll()
    }
    do {
      while true {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let cards = relay.approvals
        operationCards.formUnion(cards.map(\.id))
        if !cards.isEmpty {
          guard cards.count == 1, answered < expected.count,
            let card = cards.first, expected[answered].matches(card)
          else {
            throw SereinError.invalid("Unexpected fixture approval at \(answered + 1): \(cards.map { $0.title + " / " + $0.detail })")
          }
          let choice = expected[answered]
          try choice.beforeAnswer?()
          card.answer(choice.answer)
          answered += 1
        }
        if let result = state.result {
          guard answered == expected.count else {
            throw SereinError.invalid("Fixture operation left \(expected.count - answered) approval expectations unused: \(result)")
          }
          return try result.get()
        }
        guard Date() < deadline else {
          throw SereinError.invalid("Fixture approval operation timed out after \(answered) of \(expected.count) expected cards.")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
    } catch {
      task.cancel()
      // The operation starts with no cards and background work suspended. Decline any
      // card it added even if cancellation happened before the next polling turn.
      for card in relay.approvals { card.answer(.no) }
      for run in relay.agent.hub.runs where !runsBefore.contains(run.id) && run.isActive { relay.agent.hub.stop(run) }
      for id in Set(browser.tasks.keys).subtracting(tasksBefore) { browser.endTask(id) }
      throw error
    }
  }

  /// Close only this helper's fixture work. A borrowed Relay keeps its prior callbacks and
  /// background schedule; an owned Relay is released without touching an unrelated session.
  func close() {
    guard !closed else { return }
    closed = true
    operationTask?.cancel()
    for card in relay.approvals where operationCards.contains(card.id) { card.answer(.no) }
    // Successful operations hand their tasks to the caller, which owns their lifetime.
    // Failed operations revoke only the new tasks they created in perform().
    relay.chatOnScreen = previousChat
    relay.chatShown = previousShown
    RelayOrchestrator.quietForChecks = previousQuiet
    if ownsRelay {
      RelayOrchestrator.releaseFixtureRelay(relay)
      relay.agent.hub.onEnd = previousOnEnd
    } else {
      restoreBackground()
    }
    if let previousArgumentDomain {
      UserDefaults.standard.setVolatileDomain(previousArgumentDomain, forName: UserDefaults.argumentDomain)
    }
    if let previousAutopilot { GateSettings.shared.set(previousAutopilot, forKey: RelayOrchestrator.autopilotKey) }
    if Self.active === self { Self.active = nil }
  }
}
