import Foundation
import SereinCore
import SereinEngines

/// A turn of a CLI that has a driver. Engines owns the process, its mode, the step budget, the
/// finish grace and the loop and silence watches; this shows the turn in its run and ends the
/// run in the words and outcomes the other launch paths use. The hub keeps the mode's time
/// limits, Edit Review, the judge and the end hooks.
/// What the loop does after a turn ends.
enum Continue {
  /// A resend carries the journal line (R19).
  case send(TurnRequest)
  /// A card is open; the slot is released.
  case wait
  /// No task stops (M6): the run waits on a reset or a person card and carries on after it.
  case recover(Recovery)
  case end(StopNote.End)
}

/// What a run that cannot go on now waits on instead of ending stuck.
enum Recovery: Equatable {
  /// A usage limit: the run carries on by itself after the reset.
  case reset(Date?)
  /// A step only the person can do (sign in, update, fix a key): a non-blocking card whose Done
  /// carries the task on.
  case card(title: String, detail: String)
}

@MainActor final class EngineTurn: HarnessTurn {
  private weak var run: AgentRun?
  private weak var hub: AgentHub?
  private let engines: Engines
  private let peers: Peers
  let request: TurnRequest
  /// Engines took the turn; words sent now may reach it.
  private(set) var started = false
  /// The run ended on screen at the finish call while Engines still closes the turn.
  private var detached = false
  private var ended = false
  /// Engines closed the turn: after Stop, the CLI's whole group is gone.
  private var closed = false
  private var openTools = Set<String>()
  private var toolsAtSend = 0
  private var cut: StopNote.Next?
  private(set) var work: Task<Void, Never>?

  init(run: AgentRun, hub: AgentHub, request: TurnRequest) {
    self.run = run
    self.hub = hub
    engines = hub.engines
    peers = hub.peers
    self.request = request
  }

  /// A tool call is open: a card it opened may hold it longer than the mode's idle limit.
  var toolOpen: Bool { !openTools.isEmpty }

  /// A delegated task's agent may call other agents (PeerTools) until its run ends.
  var callsPeers: Bool {
    switch request.access {
    case .task, .project: return true
    default: return false
    }
  }

  func start() {
    work = Task { [self] in
      defer { closed = true }
      if callsPeers {
        await peers.register(
          task: request.taskID, caller: PeerCaller(thread: request.thread, cli: request.cli, access: request.access))
      }
      var next: TurnRequest? = request
      while var sending = next {
        next = nil
        sending.secretsOpen = hub?.browser?.allowsAll(task: sending.taskID) == true
        sending.widened = PathGrants.shared.roots(
          task: sending.taskID, home: FileManager.default.homeDirectoryForCurrentUser, library: AgentAccess.defaultRoot)
        let handle: TurnHandle
        do {
          handle = try await engines.send(sending)
        } catch {
          if let refusal = error as? EngineRefusal, let again = await self.next(before: refusal, sent: sending) {
            next = again
            continue
          }
          refuse(error)
          hub?.engineSettled(self)
          return
        }
        if !started {
          started = true
          run?.resolveStart(nil)
        }
        toolsAtSend = run?.record.toolCount ?? 0
        for await event in handle.events {
          guard case .ended(let end) = event else {
            receive(event)
            continue
          }
          switch await self.next(after: end, sent: sending) {
          case .send(let again): next = again
          case .wait: finish(end, .wait)
          case .recover(let recovery): finish(end, .recover(recovery))
          case .end(let stop): finish(end, .end(stop))
          }
        }
      }
      hub?.engineSettled(self)
    }
  }

  /// What the stop table says after a turn ends (R5, R28): the next request, a wait on the
  /// person, or the end. Replaces the resume-once rebuild and the per-reason endings.
  private func next(after end: TurnEnd, sent: TurnRequest) async -> Continue {
    guard let run, let hub, run.isActive, !detached else { return .end(.done) }
    if let id = end.sessionID { run.noteSession(id, hub: hub) }
    var tried = run.record.tried ?? Tried()
    defer { run.record.tried = tried }
    let resent = tried.continuations > 0
    if resent, end.stopReason != .stopped {
      tried.quiet = run.record.toolCount == toolsAtSend ? tried.quiet + 1 : 0
      if tried.quiet >= Tried.quietLimit { return .end(.stuck(routes: tried.notes, nextAction: Self.quiet)) }
    }
    let step: StopNote.Next
    if let cut, end.stopReason == .stopped {
      // The hub's limit cut the turn and already counted it (AgentHub.check).
      self.cut = nil
      step = cut
    } else {
      step = await judged(
        StopNote.next(after: end.stopReason, finish: nil, tried: &tried, cardOpen: holdsCard(sent.taskID),
          app: run.spec.provider.name),
        end: end, tried: &tried)
    }
    guard run.isActive, !detached else { return .end(.done) }
    switch step {
    case .tell(let line):
      var again = sent
      again.resume = end.sessionID ?? sent.resume
      if again.resume == nil { again.prompt.message = sent.prompt.message + "\n\n" + line }
      else { again.prompt.message = Self.joined(line, journalLine()) }
      return .send(again)
    case .freshSession:
      var again = sent
      again.resume = nil
      again.prompt.message = Self.joined(sent.prompt.recovery ?? sent.prompt.message, StopNote.line(for: end.stopReason, app: run.spec.provider.name), journalLine())
      again.prompt.recovery = nil
      return .send(again)
    case .retry:
      try? await Task.sleep(for: .seconds(2 * tried.retries))
      return run.isActive && !detached ? .send(sent) : .end(.done)
    case .waitForPerson: return .wait
    case .otherApp, .waitForReset:
      // The relay's turns keep its failover and limit hold, which read a stuck run's error
      // (RelayLimitFailover); every other run waits on its solution.
      if relayOwned(run) { return .end(.stuck(routes: tried.notes, nextAction: "")) }
      if case .modelRejected = end.stopReason, sent.model != nil {
        var again = sent
        again.model = nil
        return .send(again)
      }
      return Self.recovery(end.stopReason, provider: run.spec.provider, limit: run.usageLimit).map(Continue.recover)
        ?? .end(.stuck(routes: tried.notes, nextAction: ""))
    case .end(let stop): return .end(stop)
    }
  }

  /// A secure card, person step or host card waits on the person for this task (M1): the turn
  /// that ends now goes to waitForPerson, never done, the judge or stuck.
  private func holdsCard(_ task: String) -> Bool {
    guard let cards = hub?.browser?.secureCards else { return false }
    return cards.holdsCard(task: task) || cards.openHost(task: task) != nil
  }

  /// A refusal before any process started: retried once when the thread was busy, else it ends
  /// the run as before.
  private func next(before refusal: EngineRefusal, sent: TurnRequest) async -> TurnRequest? {
    guard let run, run.isActive, !detached else { return nil }
    var tried = run.record.tried ?? Tried()
    defer { run.record.tried = tried }
    guard case .retry = StopNote.next(before: refusal, tried: &tried, app: run.spec.provider.name) else { return nil }
    try? await Task.sleep(for: .seconds(2))
    return run.isActive ? sent : nil
  }

  /// A task's turn that ended by itself, without finish: the judge reads what is left (R6).
  private func judged(_ step: StopNote.Next, end: TurnEnd, tried: inout Tried) async -> StopNote.Next {
    guard case .end(.done) = step, end.stopReason == .endTurn, callsPeers, let run, let hub,
      run.reportedOutcome == nil, run.approvals.isEmpty, FeaturePolicy.isEnabled(.outcome)
    else { return step }
    let reading = await hub.judgeLeft(run.currentTurnResponse ?? "", spec: run.spec)
    tried.judge = reading
    switch reading {
    case .nothingLeft:
      return step
    case .left(let left):
      return StopNote.next(.workLeft, tried: &tried, cardOpen: false, line: StopNote.line(.workLeft, left: Judge.fenced(left)))
    case .unknown:
      return StopNote.next(.judgeUnknown, tried: &tried, cardOpen: false, line: Judge.unknownLine)
    }
  }

  /// R19: the steps of this chat's request whose outcome is unknown. Nothing is replayed.
  private func journalLine() -> String? {
    guard let journal = hub?.browser?.stepJournal, let request = journal.request(request.thread.id) else { return nil }
    return StopNote.journalLine(StepJournal.stuck(request.entries).map(\.tool))
  }

  private static func joined(_ parts: String?...) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// The hub's time limit cut this turn: the table's answer, already counted, for when it ends.
  func cut(_ next: StopNote.Next) {
    cut = next
    interrupt()
  }

  /// Waits until Engines has closed the turn, so Edit Review's "after" snapshot holds the writes
  /// a stopped or detached CLI makes on its way out.
  func settled(timeout: TimeInterval) async {
    let deadline = Date().addingTimeInterval(timeout)
    while work != nil, !closed, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
  }

  func interrupt() {
    guard !ended else { return }
    Task { [engines, thread = request.thread] in await engines.stop(thread) }
  }

  /// The finish call ended the run on screen. Engines closes the turn within its grace; the
  /// thread's next turn waits for that (AgentHub.launch).
  func detach() {
    detached = true
    run?.keepsTask = true
  }

  private func receive(_ event: EngineEvent) {
    guard let run, let hub, run.isActive, !detached else { return }
    switch event {
    case .session(let id, _): run.noteSession(id, hub: hub)
    case .text(let text): run.noteText(text)
    case .thinking(let text): run.noteThinking(text)
    // The split waits for the next text (as on the old path), so a turn's last message stays its answer.
    case .newMessage: run.messageStarted = true
    case .retrying: run.noteRetry()
    case .toolStarted(let id, let name, let detail):
      // Counted only: Engines cuts the turn at its step budget (`.stepLimit`).
      run.record.lastEventAt = Date()
      run.record.toolCount += 1
      openTools.insert(id)
      let activity = HarnessEvents.activity(name: name, detail: detail, folder: run.folder?.path)
      run.phase = activity.now
      run.track(activity, id: id)
    case .toolEnded(let id, let result):
      run.record.lastEventAt = Date()
      openTools.remove(id)
      if result != .ok { run.failStep(id, "Failed") }
    case .declined(let asked):
      let approval = PendingApproval(id: asked.id, tool: asked.tool, target: asked.target)
      run.recordBehavior(.permissionAnswered, decision: .denied)
      run.reportBehaviorApprovals([approval])
      run.approvals.append(approval)
    case .permissionAnswered(let allowed):
      run.recordBehavior(.permissionAnswered, decision: allowed ? .allowedOnce : .denied)
    case .notice(let text):
      run.phase = text
    case .limitReached(let limit):
      // Kept only if the turn then fails (AgentHub.finish); the exact reset beats the error's words.
      run.usageLimit = limit
    case .waiting(let text):
      run.phase = text
      run.record.lastEventAt = Date()
    case .usage(let input, let output, let cached):
      run.record.tokens = input + output
      if input + (cached ?? 0) > 0 { run.contextTokens = input + (cached ?? 0) }
    case .context(let used, _, _):
      run.contextTokens = used
    case .commands, .ended:
      break
    }
    hub.onTranscript?(run)
  }

  private func finish(_ end: TurnEnd, _ next: Continue) {
    ended = true
    guard let run, let hub, run.isActive, !detached else { return }
    let name = run.spec.provider.name
    switch next {
    case .send:
      return
    case .recover(let recovery):
      wait(on: recovery, run: run, hub: hub)
      return
    case .wait:
      // A card is still open (a secure card, or a host card a shell call waits on): the task waits
      // for the person, and the card's answer sends the follow-up turn. It holds no slot (R4).
      run.reportedOutcome = .waiting
      run.reportedSummary = hub.browser?.secureCards.openHost(task: request.taskID).map(SecureCard.parkSummary) ?? Self.parked
      run.keepsTask = true
      hub.complete(run, code: 0, diagnostic: "")
      return
    case .end(.done):
      run.keepsTask = true
      hub.complete(run, code: 0, diagnostic: "")
      return
    case .end(.stoppedByPerson):
      hub.stop(run)
      hub.notifyEnded(run)
      return
    case .end(.stuck):
      break
    }
    // Stuck: the run ends with Serein's own words for why.
    switch end.stopReason {
    case .endTurn, .finished:
      fail(Self.workLeft(run.record.tried?.judge))
    case .stepLimit(let limit):
      hub.stopAtStepLimit(run, limit: limit)
    case .maxTokens:
      hub.stopCutShort(run, line: Self.lengthLimit)
    case .loop(let tool):
      hub.stopCutShort(run, line: Self.repeating(tool))
    case .stuck(let seconds):
      fail(TurnFailure.stoppedAnswering(name, minutes: max(1, seconds / 60)))
    case .stopped:
      fail(Self.limitText)
    case .usageLimit(let text), .offline(let text), .failed(let text), .resumeFailed(let text):
      fail(text)
    case .signIn(let text):
      fail(HarnessParse.asksSignIn(text) ? text : "\(name) is not signed in. Sign in again. \(text)")
    case .keyFailure(let text):
      fail(KeyFailure.of(text) != nil ? text : "API key not valid: \(text)")
    case .modelRejected(let text):
      fail(HarnessParse.modelRejected(text) ? text : "Unknown model: \(text)")
    case .refusal:
      fail("\(name) declined this request.")
    case .declined(let step):
      fail("\(name)'s own rules declined \(step).")
    case .modeMismatch(let setting, let expected, let reported):
      fail("\(name) did not start in the mode Serein asked for (\(setting): expected \(expected), got \(reported ?? "nothing")). Nothing ran.")
    }
  }

  private func fail(_ message: String) {
    guard let run, let hub else { return }
    if run.error == nil { run.error = message }
    hub.complete(run, code: 0, diagnostic: "")
  }

  /// Relay's own run, a run it started or a hand-off: the relay's failover and hold answer it.
  private func relayOwned(_ run: AgentRun) -> Bool {
    run.spec.relay || hub?.browser.map { $0.relayTask(run.taskID, $0.tasks[run.taskID]) != nil } == true
  }

  /// The run ends waiting on `recovery`, never stuck, and the task carries on after it (M6).
  private func wait(on recovery: Recovery, run: AgentRun, hub: AgentHub) {
    ended = true
    if !started {
      started = true
      run.resolveStart(nil)
    }
    let thread = run.spec.threadID
    switch recovery {
    case .reset(let at):
      run.reportedSummary = Self.limitWait(run.spec.provider.name, at)
      let wait = at.map { max(0, $0.timeIntervalSinceNow) } ?? LimitFailover.unknownResetWait
      // shortcut: the wait lives in memory; a relaunch drops it and the run waits for the person's
      // reply. Persist it with the relay's limit holds if runs outside the relay need it kept.
      Task { [weak hub] in
        try? await Task.sleep(for: .seconds(wait + 30))
        _ = await hub?.browser?.intelligenceAgent?.flow.deliver(thread, text: Self.limitReset)
      }
    case .card(let title, let detail):
      run.reportedSummary = title
      RelayOrchestrator.shared?.personCard(UUID(), title, detail, button: "Done", thread: thread) { [weak hub] yes, _ in
        guard yes else { return }
        Task { _ = await hub?.browser?.intelligenceAgent?.flow.deliver(thread, text: Self.personDone) }
      }
    }
    run.reportedOutcome = .waiting
    run.keepsTask = true
    hub.complete(run, code: 0, diagnostic: "")
  }

  /// The solution a turn's stop reason has: wait for the reset, or a person card.
  static func recovery(_ reason: StopReason, provider: Provider, limit: UsageLimit?) -> Recovery? {
    let name = provider.name
    switch reason {
    case .usageLimit: return .reset(limit?.resetsAt)
    case .signIn: return signIn(name)
    case .keyFailure:
      return .card(title: "Check \(name)'s API key", detail: "\(name) refused its API key, so this task waits. Fix the key, then press Done and Serein carries on.")
    case .modelRejected:
      return .card(title: "Choose another model for \(name)", detail: "\(name) refused the chosen model, so this task waits. Pick another model, then press Done and Serein carries on.")
    default: return nil
    }
  }
  /// The solution a refusal before launch has: a person card, or nil when only a new request helps.
  static func recovery(_ refusal: EngineRefusal, provider: Provider) -> Recovery? {
    let name = provider.name
    switch refusal {
    case .notReady(.needsSignIn): return signIn(name)
    case .needsRepair(let why): return .card(title: "Fix \(name)", detail: why + " Then press Done and Serein carries on.")
    case .versionTooOld, .notReady(.needsUpdate):
      return .card(title: "Update \(name)", detail: text(refusal, name: provider) + " Then press Done and Serein carries on.")
    case .notReady(.missing):
      return .card(title: "Install \(name)", detail: "\(name) is not installed, so this task waits. Install it, then press Done and Serein carries on.")
    case .cliCannot, .threadBusy, .notReady(.broken), .notReady(.ready): return nil
    }
  }
  private static func signIn(_ name: String) -> Recovery {
    .card(title: "Sign in to \(name)", detail: "\(name) is signed out, so this task waits. Sign in to it, then press Done and Serein carries on.")
  }
  static func limitWait(_ app: String, _ at: Date?) -> String {
    "\(app) hit its usage limit. Serein carries on " + (at.map { "after \(UsageLimit.when($0, now: Date()))." } ?? "once it resets.")
  }
  static let limitReset = "The usage limit has reset. Carry on with the task from where you stopped."
  static let personDone = "I did the step you asked for. Carry on with the task from where you stopped."

  /// Engines refused before any process started: a person card when the person can fix it, else stuck.
  private func refuse(_ error: Error) {
    ended = true
    guard let run, let hub, run.isActive else { return }
    if let refusal = error as? EngineRefusal, !relayOwned(run), let recovery = Self.recovery(refusal, provider: run.spec.provider) {
      wait(on: recovery, run: run, hub: hub)
      return
    }
    let message = (error as? EngineRefusal).map { Self.text($0, name: run.spec.provider) } ?? error.localizedDescription
    hub.stop(run, outcome: .stuck, message: message)
    hub.notifyEnded(run)
  }

  static let parked = "Waiting for you to finish the secure card."
  static let quiet = "Three turns in a row ran no step."
  static let limitText = "Stopped at the time limit for this kind of task, after Serein asked it to carry on."
  static func workLeft(_ reading: Judge.Reading?) -> String {
    if case .left(let left) = reading { return "Ended with work left: \(left)" }
    return "Ended without saying the task was done."
  }
  static let lengthLimit = "Stopped: the reply reached the model's length limit."
  static func repeating(_ tool: String) -> String { "Stopped: it kept repeating the same \(tool) step." }

  static func text(_ refusal: EngineRefusal, name provider: Provider) -> String {
    let name = provider.name
    switch refusal {
    case .cliCannot: return "\(name) cannot run this kind of task."
    case .versionTooOld(let have, let need): return "\(name) \(have) is too old for this task. Update it to \(need) or later."
    case .notReady(.missing): return "\(name) is not installed."
    case .notReady(.needsSignIn): return ConnectNeed.signedOut(provider)
    case .notReady(.needsUpdate(let have, let need)): return "\(name) \(have) is too old for this task. Update it to \(need) or later."
    case .notReady(.broken(let why)): return why
    case .notReady(.ready): return "\(name) could not start this task."
    case .threadBusy: return "That thread is still working. Wait for it or stop it first."
    case .needsRepair(let why): return why
    }
  }
}
