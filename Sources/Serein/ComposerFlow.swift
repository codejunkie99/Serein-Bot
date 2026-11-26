import AppKit
import Combine
import Network
import SereinCore
import SwiftUI

/// Whether this Mac has a usable network path. Tasks sent while it is down wait for it to return.
@MainActor final class NetworkMonitor: ObservableObject {
  static let shared = NetworkMonitor()
  @Published private(set) var online = true
  /// A hotspot or Low Data Mode, where a large download shouldn't start by itself.
  @Published private(set) var metered = false
  /// A real path assessment has arrived; initial defaults cannot authorize a large download.
  @Published private(set) var known = false
  private let monitor = NWPathMonitor()
  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let up = path.status == .satisfied
      let costly = path.isExpensive || path.isConstrained
      Task { @MainActor in
        self?.online = up
        self?.metered = costly
        self?.known = true
      }
    }
    monitor.start(queue: DispatchQueue(label: "serein.network-path"))
  }
}

/// The composer's send flow around `AgentModel`: messages queued behind a running step, tasks
/// held while offline, remembered project access, and thread actions (Retry, copy, move).
/// It calls only the public surface of `AgentModel` and `AgentHub`.
@MainActor final class ComposerFlow: ObservableObject {
  @Published private(set) var queue = MessageQueue()
  @Published private(set) var offline = OfflineQueue()
  @Published private(set) var online = true
  /// Test hook: forces the offline path without touching the network.
  var forceOffline = false
  private weak var agent: AgentModel?
  private weak var browser: BrowserModel?
  private var library: Library?
  private var memory = AccessMemory()
  private var cancellables = Set<AnyCancellable>()
  private var handledFailures = Set<String>()
  private var lastProject: String?
  private var lastThread = ""
  /// Chips captured with each queued message and held task, by item id. Held tasks keep theirs
  /// in memory only, so pictures and page text are never written to disk with them.
  private var captured: [String: ComposerContext.Chips] = [:]
  /// Held tasks written since Serein launched. Only these go out by themselves on reconnect;
  /// tasks kept from an earlier session wait for Send (`HeldTaskPolicy`).
  @Published private(set) var heldThisSession = Set<String>()
  /// Tasks kept from an earlier session, waiting for Send, Edit or Discard.
  var restoredTasks: [PendingTask] {
    HeldTaskPolicy.restored(offline, heldThisSession: heldThisSession)
  }
  /// The project whose remembered "Allow project edits" turned the toggle on in this thread.
  @Published private(set) var prefilledEdits: String?

  init(agent: AgentModel) { self.agent = agent }

  func start(browser: BrowserModel) {
    guard let agent, library == nil else { return }
    self.browser = browser
    library = browser.library
    offline = OfflineQueue.load(from: browser.library)
    memory = AccessMemory.load(from: browser.library)
    online = NetworkMonitor.shared.online
    lastProject = agent.projectID
    lastThread = agent.conversationID
    NetworkMonitor.shared.$online.removeDuplicates().sink { [weak self] up in
      let back = up && self?.online == false
      self?.online = up
      self?.settle()
      // Back online: tasks written this session go by themselves; the ones kept from an
      // earlier session wait for Send, and a toast says they are ready (after settle has run).
      if back { DispatchQueue.main.async { DispatchQueue.main.async { self?.announceReady() } } }
    }.store(in: &cancellables)
    // A thread's step ended, or the user moved to another thread: send what is waiting.
    agent.$running.removeDuplicates().sink { [weak self] _ in self?.settle() }.store(in: &cancellables)
    agent.$conversationID.removeDuplicates().sink { [weak self] _ in self?.settle() }
      .store(in: &cancellables)
    // A held edit-approval answer went out (or was dropped): what was queued behind it may go,
    // even when the answer itself started no step.
    NotificationCenter.default.publisher(for: EditReview.heldAnswerSettled)
      .sink { [weak self] _ in
        self?.settle()
        DispatchQueue.main.async { self?.drainTasks() }
      }.store(in: &cancellables)
    Publishers.CombineLatest4(
      agent.$projectID, agent.$allowActions, agent.$allowProjectEdits, agent.$conversationID
    ).dropFirst().sink { [weak self] _ in
      DispatchQueue.main.async { self?.accessChanged() }
    }.store(in: &cancellables)
  }

  /// An OpenCode turn on a provider connection at this Mac or the local network needs no internet,
  /// so its sends are never held as offline.
  private var sendsLocally: Bool {
    guard let agent, agent.provider.driver == .opencode,
      let c = ProviderRun.connection(forModel: agent.model, wire: .openai, in: ProviderStore.shared.enabled)
    else { return false }
    return ProviderAddress.isHere(c.baseURL)
  }
  var isOnline: Bool { (online || sendsLocally) && !forceOffline }

  /// The toast once the network is back, while tasks written offline wait for Send.
  static func readyWords(_ count: Int) -> String {
    count == 1 ? "1 task you wrote offline is ready to send" : "\(count) tasks you wrote offline are ready to send"
  }
  static let readyToastID = "offline-ready"
  private func announceReady() {
    let tasks = restoredTasks
    guard isOnline, let first = tasks.first else { return }
    showReadyToast(count: tasks.count, first: first.id)
  }
  private func showReadyToast(count: Int, first: String?, duration: TimeInterval? = 8) {
    ToastCenter.shared.show(Self.readyWords(count), id: Self.readyToastID, actionTitle: "Show", duration: duration, opaque: true) {
      [weak self] in self?.showReady(first)
    }
  }
  /// Show on the back-online toast opens Serein's chat, which lists the held tasks on request.
  private func showReady(_ id: String?) {
    SereinRouter.show()
  }
  /// `--ui-offline-ready-toast`: the toast as the network comes back with a task waiting (in
  /// memory only; nothing is queued or sent).
  func previewReadyToast() {
    guard CommandLine.arguments.contains("--ui-preview"), CommandLine.arguments.contains("--ui-offline-ready-toast") else { return }
    showReadyToast(count: 1, first: nil, duration: nil)
  }

  /// Five or more held drafts can be inspected without reading or writing a real queue.
  func previewReadyTasks(_ tasks: [PendingTask]) {
    guard CommandLine.arguments.contains("--ui-preview"), CommandLine.arguments.contains("--ui-ready-to-send") else { return }
    var seeded = OfflineQueue()
    for task in tasks { seeded.add(task) }
    heldThisSession = []
    offline = seeded
  }

  // MARK: Sending

  /// Called at the top of `AgentModel.send`. Returns true when the task was kept for later, with
  /// the chips it was sent with (`nil`: the composer's chips, which go with it).
  func holdIfOffline(
    _ prompt: String, chips: ComposerContext.Chips? = nil, plan: Bool? = nil
  ) -> Bool {
    guard let agent, SendGate.decide(online: isOnline) == .holdOffline else { return false }
    let task = PendingTask(
      threadID: agent.conversationID, prompt: prompt, provider: agent.provider.rawValue,
      mode: agent.mode.rawValue, projectID: agent.projectID, model: agent.model,
      effort: agent.effort, allowActions: agent.allowActions,
      allowProjectEdits: agent.allowProjectEdits, plan: plan ?? ComposerContext.shared.planMode)
    if offline.add(task), persistOffline() {
      if agent.draft.trimmingCharacters(in: .whitespacesAndNewlines) == prompt { agent.draft = "" }
      agent.error = nil
      heldThisSession.insert(task.id)
      captured[task.id] = chips ?? ComposerContext.shared.take()
    } else {
      agent.error = "Couldn't save the task for later. Try again when you're back online."
    }
    return true
  }
  func cancelOffline(_ id: String) {
    offline.cancel(id)
    persistOffline()
    releaseCaptured(id)
  }
  private func releaseCaptured(_ id: String) {
    if let chips = captured.removeValue(forKey: id) { ComposerContext.release(chips) }
  }
  @discardableResult private func persistOffline() -> Bool {
    guard let library else { return false }
    do {
      try offline.save(to: library)
      return true
    } catch { return false }
  }

  /// How words sent now reach the step that runs in `thread` (`RunSteering.path`). An engine
  /// that cannot read them now (`codex exec`, another app's own chat) takes them with its next turn.
  func stepPath(_ thread: String, carriesContext: Bool = false) -> RunSteering.Path {
    guard let agent, let run = agent.hub.run(for: thread), agent.hub.takesWords(run) else { return .nextTurn }
    return RunSteering.path(
      agent.hub.steerWire(run), carriesContext: carriesContext,
      othersWaiting: run.steering.hasReturnedLines || !queue.items(for: thread).isEmpty, byPerson: true)
  }
  /// The open chat's path for what is typed and attached now.
  var stepPath: RunSteering.Path {
    guard let agent else { return .nextTurn }
    return stepPath(agent.conversationID, carriesContext: !ComposerContext.shared.current.isEmpty)
  }
  /// Words a run took and never read wait ahead of the thread's others, for its next turn.
  private func steer(_ run: AgentRun, _ text: String) {
    let thread = run.spec.threadID
    agent?.hub.steer(run, text) { [weak self] unread in self?.queue.requeue(unread, thread: thread) }
  }
  /// Return while a step runs: the words go into the step where its engine reads them now, else
  /// with the next turn, which starts when this one ends. Nothing is stopped.
  func addToStep() {
    guard let agent, stepPath == .intoTurn, let run = agent.hub.run(for: agent.conversationID) else { return queueDraft() }
    let text = agent.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    agent.draft = ""
    agent.error = nil
    steer(run, text)
  }
  private func queueDraft() {
    guard let agent else { return }
    if let item = queue.enqueue(
      agent.draft, thread: agent.conversationID, plan: ComposerContext.shared.planMode)
    {
      agent.draft = ""
      agent.error = nil
      // The chips attached now go with this message, not with whatever is sent next.
      captured[item.id] = ComposerContext.shared.take()
    } else if !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      agent.error = "This thread already has \(MessageQueue.maxPerThread) messages waiting."
    }
  }
  func removeQueued(_ id: String) {
    queue.remove(id)
    releaseCaptured(id)
  }
  /// Drops every message queued in a thread, with the chips captured for them; returns how many.
  @discardableResult func clearQueue(_ thread: String) -> Int {
    let items = queue.items(for: thread)
    for item in items { releaseCaptured(item.id) }
    queue.removeAll(thread: thread)
    return items.count
  }
  /// Option-Return: stop the current step and send this message now. `chips` nil: the
  /// composer's chips.
  func interruptAndSend(
    _ text: String, chips: ComposerContext.Chips? = nil, plan: Bool? = nil
  ) {
    guard let agent else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard agent.running else {
      agent.send(trimmed, chips: chips, plan: plan)
      return
    }
    agent.draft = ""
    agent.cancel()
    agent.send(InterruptedFeedback.wrap(trimmed), chips: chips, plan: plan)
    if !agent.running { agent.draft = trimmed }
  }
  /// Sends one queued message now, with the chips captured when it was queued. A running step
  /// is stopped first.
  func sendQueuedNow(_ id: String) {
    guard let agent, let item = queue.items.first(where: { $0.id == id }) else { return }
    queue.remove(id)
    let chips = captured.removeValue(forKey: id) ?? .empty
    if agent.running {
      interruptAndSend(item.text, chips: chips, plan: effectivePlan(item.plan))
    } else {
      agent.send(item.text, chips: chips, plan: effectivePlan(item.plan))
    }
  }
  /// Waiting messages go out in the stricter of their saved plan mode and the thread's now.
  private func effectivePlan(_ stored: Bool?) -> Bool {
    QueuePolicy.plan(stored: stored, threadPlan: ComposerContext.shared.planMode)
  }
  // MARK: replies to a task Serein started (its view, never AgentModel's current chat)

  /// The model and effort chosen in a task view's Options for that task's next reply. Kept here,
  /// not in the view, so switching Serein full ⇄ beside keeps them.
  @Published private(set) var taskChoices: [String: (model: String?, effort: String?)] = [:]
  func setTaskChoice(_ id: String, model: String?, effort: String?) {
    let current = taskChoices[id]
    taskChoices[id] = (model ?? current?.model, effort ?? current?.effort)
  }
  /// Why a reply to a task could not go (now, when its step ended, or on Try Again), by thread;
  /// the task view's composer shows it. A held reply stays held.
  @Published private(set) var taskReplyError: [String: String] = [:]
  func setTaskReplyError(_ id: String, _ message: String?) {
    if taskReplyError[id] != message { taskReplyError[id] = message }
  }
  /// A reply is held for the task while it is not working, because its last step was stopped or
  /// failed: it waits for you (“Not sent”), as a task tab's queue does.
  func taskReplyStuck(_ id: String) -> Bool {
    guard let agent, agent.hub.run(for: id) == nil, !queue.items(for: id).isEmpty else { return false }
    return !QueuePolicy.shouldDrain(after: lastOutcome(id))
  }
  /// Threads whose next held reply is being sent now, so it never goes twice.
  private var drainingTasks: Set<String> = []
  /// A reply from a task's view in the Serein surface. Not running: it goes now. While its step
  /// runs, Return holds it for when the step ends (`interrupt` false) and ⌥Return stops the step
  /// and sends now, as the task composer does. Returns nil once sent or held, else why not.
  /// `sameRequest`: the words are the task's last request going again, so when they go now the
  /// journal reads its finished steps (`StepJournal`). Held behind other replies, they go as new.
  func replyToTask(
    _ id: String, text: String, model: String? = nil, effort: String? = nil, interrupt: Bool, sameRequest: Bool = false
  ) async -> String? {
    guard let agent else { return "Serein is not ready." }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if model != nil || effort != nil { setTaskChoice(id, model: model, effort: effort) }
    var prompt = trimmed
    if let run = agent.hub.run(for: id) {
      guard interrupt else {
        if stepPath(id) == .intoTurn {
          steer(run, trimmed)
          return nil
        }
        return queue.enqueue(trimmed, thread: id) == nil
          ? "This task already has \(MessageQueue.maxPerThread) replies waiting." : nil
      }
      agent.hub.stop(run)
      prompt = InterruptedFeedback.wrap(trimmed)
    } else if !queue.items(for: id).isEmpty {
      // Replies still held (the last step stopped or failed): this one goes after them, in the
      // order you wrote them, and the first goes now.
      guard queue.enqueue(trimmed, thread: id) != nil else {
        return "This task already has \(MessageQueue.maxPerThread) replies waiting."
      }
      drainTask(id, force: true)
      return nil
    }
    let journal = sameRequest ? agent.browser?.stepJournal : nil
    journal?.sendAgain(id)
    let refused = await dispatchToTask(id, [prompt])
    if refused != nil { journal?.settle(id) }
    return refused
  }
  /// A card's answer for a task (PersonStep, SecureCard): a steer into the running turn, kept
  /// behind it past the cap, or one follow-up turn. A task the person stopped is not revived by
  /// it (R11). Returns nil once delivered or dropped, else why it could not go.
  func deliver(_ id: String, text: String) async -> String? {
    guard let agent else { return "Serein is not ready." }
    guard let run = agent.hub.run(for: id) else {
      // shortcut: a turn that ended with a card open still records done until U2's `waiting`
      // outcome lands, so only stopped drops the answer; drop on done too once it does (R11).
      if case .stopped? = lastOutcome(id) { return nil }
      return await replyToTask(id, text: text, interrupt: false)
    }
    if stepPath(id) == .intoTurn {
      steer(run, text)
    } else {
      queue.keep(text, thread: id)
    }
    return nil
  }
  /// Edit and rerun in a task's view: the task is rewound to before the message
  /// (`AgentModel.rewind`), then the new words go as its next reply, so every step asks again.
  /// Why it could not go shows in the task's composer, as for any reply.
  func rerunTask(_ id: String, from messageID: String, text: String) {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, let agent, let cleared = agent.rewind(messageID, in: id) else { return }
    MessageEdit.announce(cleared: cleared)
    Task {
      let refused = await replyToTask(id, text: prompt, interrupt: false)
      setTaskReplyError(id, refused)
    }
  }
  /// Takes a held reply back (× on its chip).
  func removeTaskReply(_ id: String) { queue.remove(id) }
  /// `words`: the replies that go as one turn, each its own bubble.
  private func dispatchToTask(_ id: String, _ words: [String]) async -> String? {
    guard let agent, let thread = agent.conversations.first(where: { $0.id == id }) else {
      return "This task has no chat to reply in."
    }
    let choice = taskChoices[id]
    let target = AgentModel.DispatchTarget(
      written: words.count > 1 ? AgentMessage.written(words, attached: []) : nil, mode: thread.mode, provider: thread.provider, model: choice?.model ?? thread.model ?? "",
      effort: choice?.effort ?? thread.effort ?? "medium", projectID: thread.projectID, actions: true,
      edits: RelayOrchestrator.shared?.child(id)?.edits ?? false, mac: thread.mode == .anywhere)
    do {
      _ = try await agent.dispatch(RelaySteering.prompt(words, tags: false), into: id, as: target)
      return nil
    } catch {
      return error.localizedDescription
    }
  }
  /// A task Serein started ended a step while it was not AgentModel's current chat: its held
  /// replies go as one turn, after any edit-approval answer held for it (which starts the next
  /// step first). They leave the queue only once sent; if it cannot go (Serein is choosing where to
  /// send, the AI app is missing), it stays first in line and the task view says why. A direct
  /// task's queue is not drained here: it goes from its own tab (`drainQueue`), with the plan mode,
  /// chips and access it was queued with.
  /// `force` (Send now on a reply held after a stopped or failed step) sends it anyway.
  func drainTask(_ id: String, force: Bool = false) {
    guard let agent, id != agent.conversationID, RelayOrchestrator.shared?.isChild(id) == true,
      agent.hub.run(for: id) == nil, !drainingTasks.contains(id),
      !EditReview.shared.held.isHolding(thread: id), queue.next(for: id) != nil,
      force || QueuePolicy.shouldDrain(after: lastOutcome(id))
    else { return }
    drainingTasks.insert(id)
    let burst = queue.items(for: id)
    Task {
      let refused = await dispatchToTask(id, burst.map(\.text))
      drainingTasks.remove(id)
      if let refused {
        taskReplyError[id] = refused
      } else {
        for item in burst { queue.remove(item.id) }
        taskReplyError[id] = nil
      }
    }
  }
  /// `--ui-task-held`: a reply held for the task in view; with `error`, one that could not go
  /// when its step ended (in memory only).
  func previewHeldReply(_ id: String, error: String?) {
    guard CommandLine.arguments.contains("--ui-preview") else { return }
    _ = queue.enqueue("Also check the guest checkout", thread: id)
    if let error { taskReplyError[id] = error }
  }
  /// The task view's “Try again” on a held reply that could not go, and “Send now” on one held
  /// after a stopped or failed step: the first held reply goes now.
  func retryTaskReply(_ id: String) {
    taskReplyError[id] = nil
    drainTask(id, force: true)
  }
  /// Every task Serein started with held replies that is not the current chat (a held edit
  /// answer settled).
  private func drainTasks() {
    guard let agent else { return }
    for id in Set(queue.items.map(\.threadID)) where id != agent.conversationID { drainTask(id) }
  }

  /// Whether the selected thread's queue is waiting on a stopped or failed step.
  var queueHeld: Bool {
    guard let agent, !agent.running, !queue.items(for: agent.conversationID).isEmpty else {
      return false
    }
    return !QueuePolicy.shouldDrain(after: lastOutcome(agent.conversationID))
  }
  private func lastOutcome(_ thread: String) -> RunRecord.Outcome? {
    agent?.hub.latest(for: thread)?.record.outcome
  }

  /// Runs after anything that could free the composer: a step ended, the network came back,
  /// or another thread was opened. Deferred a tick so the model has finished updating.
  private func settle() {
    DispatchQueue.main.async { [weak self] in

      guard let self, let agent = self.agent, !agent.running else { return }
      self.keepFailedTurnIfOffline(agent)
      // A held task goes out by itself only in the thread it was written in, when that thread
      // is open, and only if it was held in this session. Others wait as "Ready to send" rows.
      if let task = self.offline.tasks.first(where: {
        HeldTaskPolicy.autoSends(
          $0, heldThisSession: self.heldThisSession, online: self.isOnline, openThread: agent.conversationID)
      }) {
        self.resume(task)
        return
      }
      self.drainQueue(agent)
    }
  }
  private func drainQueue(_ agent: AgentModel) {
    let thread = agent.conversationID
    // An edit-approval answer given during the step goes first (EditReview applies it as the
    // step ends); the queued message follows when that step ends.
    guard !EditReview.shared.held.isHolding(thread: thread) else { return }
    guard queue.next(for: thread) != nil,
      QueuePolicy.shouldDrain(after: lastOutcome(thread))
    else { return }
    // Everything waiting goes as one turn, each message its own bubble, through the first that
    // carries chips: those are the turn's chips, never what is attached now.
    let burst = queue.popBurst(for: thread) { captured[$0.id]?.isEmpty == false }
    let chips = burst.compactMap { captured.removeValue(forKey: $0.id) }.last ?? .empty
    // Sending clears the composer; give the user's unsent words back.
    let kept = agent.draft
    agent.send(
      RelaySteering.prompt(burst.map(\.text), tags: false), chips: chips,
      plan: effectivePlan(burst.contains { $0.plan == true }), written: burst.map(\.text))
    if !kept.isEmpty { agent.draft = kept }
  }
  /// A step that failed because the connection dropped is kept to send again on reconnect.
  private func keepFailedTurnIfOffline(_ agent: AgentModel) {
    guard !sendsLocally, !isOnline, let run = agent.hub.latest(for: agent.conversationID),
      run.record.outcome == .stuck, SendGate.looksOffline(run.error),
      handledFailures.insert(run.id).inserted,
      let prompt = ThreadActions.lastRequest(agent.messages.map { ($0.role, $0.text) })
    else { return }
    let task = PendingTask(
      threadID: agent.conversationID, prompt: prompt, provider: agent.provider.rawValue,
      mode: agent.mode.rawValue, projectID: agent.projectID, model: agent.model,
      effort: agent.effort, allowActions: agent.allowActions,
      allowProjectEdits: agent.allowProjectEdits, replacesFailedTurn: true,
      plan: ComposerContext.shared.planMode)
    if offline.add(task) {
      persistOffline()
      heldThisSession.insert(task.id)
      captured[task.id] = .empty
    }
  }
  /// Sends a waiting task in the open thread it was written in, once the composer is free. It
  /// goes out with that thread's current settings and access as the user sees them now; the
  /// grants saved with the task are never restored.
  private func resume(_ task: PendingTask, userAsked: Bool = false) {
    guard let agent, agent.conversationID == task.threadID else { return }
    // On its own, it never goes out over what the user is typing; it tries again when the
    // composer is empty. When the user pressed Send, their draft is kept.
    let draft = agent.draft
    guard userAsked || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    // A step of the failed turn has an unknown outcome: it never goes again by itself, only on
    // the person's Send, where the step asks first (`StepJournal`).
    if !userAsked, task.replacesFailedTurn == true, case .waits? = agent.browser?.stepJournal.resend(task.threadID) { return }
    _ = offline.take(task.id)
    persistOffline()
    let chips = captured.removeValue(forKey: task.id) ?? .empty
    if task.replacesFailedTurn == true {
      resendDroppingFailedTurn(task.prompt, chips: chips, plan: effectivePlan(task.plan))
    } else {
      agent.send(task.prompt, chips: chips, plan: effectivePlan(task.plan))
    }
    if !agent.running && agent.error != nil && draft.isEmpty {
      agent.draft = task.prompt
    } else if !draft.isEmpty {
      agent.draft = draft
    }
  }
  /// "Send" on a ready task from another thread: the user opens that thread (or a new one when
  /// it is gone) and the task goes out there, with that thread's settings as they are now.
  func sendReady(_ id: String) {
    guard let agent, let browser, !agent.running,
      let task = offline.tasks.first(where: { $0.id == id })
    else { return }
    if agent.conversationID != task.threadID {
      if let thread = agent.conversations.first(where: { $0.id == task.threadID }) {
        agent.openConversation(thread)
      } else {
        if !agent.messages.isEmpty { agent.clear() }
        // The thread no longer exists: the task now belongs to this new one.
        offline.retarget(task.id, thread: agent.conversationID)
      }
      browser.section = ShellSection.thread
    }
    guard let moved = offline.tasks.first(where: { $0.id == id }) else { return }
    resume(moved, userAsked: true)
  }

  /// "Edit" on a ready task: its words go back into that thread's composer and the row goes.
  func editReady(_ id: String) {
    guard let agent, let browser, let task = offline.tasks.first(where: { $0.id == id }) else { return }
    // The task's own thread, when it still exists; a thread that is gone edits here instead.
    if agent.conversationID != task.threadID,
      let thread = agent.conversations.first(where: { $0.id == task.threadID })
    {
      guard !agent.running else {
        browser.notice = "Wait for the running task, then edit this one."
        return
      }
      agent.openConversation(thread)
      browser.section = ShellSection.thread
    }
    let current = agent.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    agent.draft = current.isEmpty ? task.prompt : current + "\n" + task.prompt
    if var chips = captured.removeValue(forKey: id) {
      // Joins what is already attached instead of replacing it.
      let mine = ComposerContext.shared.take()
      chips.page = chips.page ?? mine.page
      chips.selection = chips.selection ?? mine.selection
      chips.console = chips.console ?? mine.console
      chips.elements = mine.elements + chips.elements
      chips.tabs = mine.tabs + chips.tabs
      chips.pictures = mine.pictures + chips.pictures
      chips.documents = mine.documents + chips.documents
      ComposerContext.shared.put(chips)
    }
    offline.cancel(id)
    persistOffline()
  }

  // MARK: Remembered access

  /// Remembers "Allow project edits" per project and offers it again as a visible default in a
  /// new or reopened thread. Website clicks and typing are never remembered: they start off in
  /// every thread.
  private func accessChanged() {
    guard let agent else { return }
    let project = agent.projectID
    let threadMoved = agent.conversationID != lastThread
    let moved = project != lastProject || threadMoved
    if threadMoved { EditReview.shared.dropOneShot(thread: lastThread) }
    lastProject = project
    lastThread = agent.conversationID
    if moved { prefilledEdits = nil }
    guard let project, agent.mode == .project || agent.mode == .auto else { return }
    if moved {
      let remembered = memory.access(for: project)?.edits == true
      if (remembered || ProjectEditApprovals.isAllowed(project)) && !agent.allowProjectEdits {
        agent.allowProjectEdits = true
        prefilledEdits = project
      }
    } else {
      if !agent.allowProjectEdits { prefilledEdits = nil }
      if memory.record(AccessMemory.remembering(edits: agent.allowProjectEdits), project: project),
        let library
      {
        try? memory.save(to: library)
      }
    }
  }
  /// Turns off a remembered "Allow project edits" from the composer row.
  func declinePrefilledEdits() {
    guard let agent else { return }
    prefilledEdits = nil
    agent.allowProjectEdits = false
  }

  // MARK: Threads

  var canRetry: Bool {
    guard let agent, !agent.messages.isEmpty else { return false }
    let outcome = lastOutcome(agent.conversationID)
    if outcome == nil { return !agent.running && agent.error != nil }
    return ThreadActions.canRetry(outcome: outcome, running: agent.running)
  }
  func retry() {
    guard canRetry, let agent,
      let prompt = ThreadActions.lastRequest(agent.messages.map { ($0.role, $0.text) })
    else { return }
    resendDroppingFailedTurn(prompt)
  }
  /// Sends `prompt` again with the failed turn removed from the transcript, restoring it if the
  /// send does not start.
  private func resendDroppingFailedTurn(
    _ prompt: String, chips: ComposerContext.Chips? = nil, plan: Bool? = nil
  ) {
    guard let agent else { return }
    let saved = agent.messages
    var kept = saved
    if kept.last?.role == "assistant" { kept.removeLast() }
    if kept.last?.role == "you" { kept.removeLast() }
    agent.messages = kept
    agent.error = nil
    // The same request, sent again: the steps it finished are read from the journal, not run.
    let journal = agent.browser?.stepJournal
    journal?.sendAgain(agent.conversationID)
    agent.send(prompt, chips: chips, plan: plan)
    if !agent.running {
      journal?.settle(agent.conversationID)
      agent.messages = saved
    }
  }

  /// "Continue in a copy": a new thread that starts from a short summary. The original stays as is.
  func continueInCopy(project: Project? = nil, native: Bool = true) {
    guard let agent, let browser, !agent.messages.isEmpty else { return }
    // A chat its own app answers goes on in that app's own copy, as a Codex chat does.
    if project == nil, LinkedSessions.continueInCopy(agent: agent, browser: browser) { return }
    if native, project == nil,
      Self.codexNativeCopy(
        agent: agent, browser: browser,
        fallback: { [weak self] in self?.continueInCopy(native: false) })
    {
      return
    }
    agent.saveConversation()
    // Own-setup results stay out of a summary on Serein's side (OwnSetup.forkSide).
    let side = OwnSetup.forkSide(agent.messages, side: \.own)
    let turns = side.messages.map { ($0.role, $0.contextText) }
    let original = agent.conversations.first { $0.id == agent.conversationID }
    let summary = ThreadActions.forkSummary(title: original?.title ?? "this thread", turns: turns)
    var copy = Conversation(
      id: UUID().uuidString, title: String(summary.prefix(100)),
      messages: [AgentMessage(role: "assistant", text: summary, own: side.own ? true : nil)], provider: agent.provider,
      mode: project == nil ? agent.mode : .project, projectID: project?.id ?? agent.projectID,
      remoteID: nil, scope: "", updatedAt: Date(), autoRouting: false, model: agent.model,
      effort: agent.effort,
      draft: project == nil ? nil : ThreadActions.lastRequest(turns), lastMessageAt: Date())
    // A copy of a chat that read personal data starts from its summary: still marked.
    copy.readPersonal = agent.inheritedPersonal(original)
    start(copy, agent: agent, browser: browser)
  }

  /// "Continue from here" and "Fork from here" on a line of a task's session log
  /// (SessionLogSheet): a new task whose record ends at that line. Continue starts from the log's
  /// lines up to it, in one message as a copy's summary is; Fork copies the messages themselves,
  /// each under a new id and without pictures. The new task gets only what a new one gets (no
  /// native session, link, draft, plan, permission or shared tab; opening it sets grants from the
  /// person's remembered choices), and what it copied reaches a model only inside the untrusted
  /// previous-conversation block of a fresh session (RunContext). The personal-read mark carries
  /// over, as for every copy.
  func continueFromLog(_ id: String, through entryID: String, fork: Bool) {
    guard let agent, let browser else { return }
    if id == agent.conversationID { agent.saveConversation() }
    let record = SessionFiles.record(id, agent: agent)
    guard let original = agent.conversations.first(where: { $0.id == id }),
      let cut = SessionFiles.log(record).cut(at: entryID), record.indices.contains(cut.message)
    else {
      ToastCenter.shared.show("That line is no longer in this task's log.")
      return
    }
    var kept = Array(record[...cut.message])
    if let steps = cut.steps {
      // Cut at a step or card: that turn's later steps and its answer had not happened yet.
      let last = kept.count - 1
      kept[last].activities = Array((kept[last].activities ?? []).prefix(steps))
      kept[last].text = ""
    }
    let messages: [AgentMessage]
    if fork {
      messages = kept.map { message in
        var copy = message
        copy.id = UUID().uuidString
        copy.images = nil
        copy.condensed = nil
        return copy
      }
    } else {
      // Own-setup results stay out of a copy on Serein's side (OwnSetup.forkSide), as in Continue in a copy.
      let side = OwnSetup.forkSide(kept, side: \.own)
      messages = [AgentMessage(role: "assistant", text: SessionFiles.log(side.messages).context(title: original.title),
                               own: side.own ? true : nil)]
    }
    var copy = Conversation(
      id: UUID().uuidString, title: fork ? original.title : String((messages.first?.text ?? original.title).prefix(100)),
      messages: messages, provider: original.provider, mode: original.mode, projectID: original.projectID,
      remoteID: nil, scope: "", updatedAt: Date(), autoRouting: false, model: original.model,
      effort: original.effort, lastMessageAt: Date())
    copy.readPersonal = agent.inheritedPersonal(original)
    start(copy, agent: agent, browser: browser)
  }

  /// A copy goes first in the chat list, is saved, and opens.
  private func start(_ copy: Conversation, agent: AgentModel, browser: BrowserModel) {
    agent.conversations.insert(copy, at: 0)
    do { try browser.library.save(agent.conversations, to: "sessions/threads.json") } catch {
      agent.error = error.localizedDescription
    }
    agent.openConversation(copy)
  }

  /// Deletes threads, stopping any task still running in them first.
  @discardableResult func deleteThreads(_ ids: Set<String>) -> Int {
    guard let agent else { return 0 }
    var count = 0
    for id in ids {
      if let run = agent.hub.run(for: id) { agent.hub.stop(run) }
      clearQueue(id)
      // Tasks held for a deleted thread never go out.
      for task in offline.tasks where task.threadID == id { cancelOffline(task.id) }
      let before = agent.conversations.count
      agent.deleteThread(id)
      if agent.conversations.count < before { count += 1 }
    }
    // Their undo snapshots and refs go too.
    EditReview.shared.forget(threads: ids)
    return count
  }
}

// MARK: Views

/// Queued messages and tasks waiting for a connection, shown in the composer.
struct ComposerFlowRows: View {
  @ObservedObject var agent: AgentModel
  @ObservedObject private var flow: ComposerFlow
  @Environment(\.palette) var p
  init(agent: AgentModel) {
    self.agent = agent
    _flow = ObservedObject(wrappedValue: agent.flow)
  }
  var queued: [QueuedMessage] { flow.queue.items(for: agent.conversationID) }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let run = agent.hub.run(for: agent.conversationID) { SteeringRows(run: run) }
      ForEach(queued) { item in
        row(
          item.text,
          caption: (flow.queueHeld
            ? "Held. The last step didn't finish." : RunSteering.nextStep + ".")
            + (item.plan == true ? " Plan first." : ""),
          sendLabel: "Send now", send: { flow.sendQueuedNow(item.id) },
          remove: { flow.removeQueued(item.id) })
      }
      ForEach(flow.offline.tasks) { task in
        if !flow.isOnline {
          row(
            task.prompt,
            caption: (flow.heldThisSession.contains(task.id)
              ? "Sends when you're back online." : "Kept from your last session. Send it once you're back online.")
              + (task.plan == true ? " Plan first." : ""),
            sendLabel: nil, send: nil,
            edit: { flow.editReady(task.id) }, remove: { flow.cancelOffline(task.id) })
        } else if task.threadID != agent.conversationID {
          row(
            task.prompt,
            caption: flow.heldThisSession.contains(task.id)
              ? "Ready to send. Written in another thread." : "Ready to send. Kept from your last session.",
            sendLabel: "Open and send", send: { flow.sendReady(task.id) },
            edit: { flow.editReady(task.id) }, remove: { flow.cancelOffline(task.id) })
        } else {
          row(
            task.prompt,
            caption: flow.heldThisSession.contains(task.id)
              ? "Ready to send." : "Ready to send. Kept from your last session.",
            sendLabel: "Send", send: { flow.sendReady(task.id) },
            edit: { flow.editReady(task.id) }, remove: { flow.cancelOffline(task.id) })
        }
      }
      if let project = flow.prefilledEdits, agent.allowProjectEdits, agent.projectID == project,
        !agent.running
      {
        HStack(spacing: 8) {
          InterfaceIcon(systemName: "pencil", size: 12).foregroundStyle(p.secondary)
          Text("Project edits are on, as you chose for this project.").role(.meta)
          Spacer(minLength: 8)
          Button("Turn off") { flow.declinePrefilledEdits() }.buttonStyle(QuietButton())
        }.padding(8).background(p.panel, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
          .accessibilityElement(children: .combine)
      }
      if JevOfferRow.fits(agent) { JevOfferRow() }
      if agent.running && !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(verbatim: RunSteering.hint(flow.stepPath, app: agent.provider.name)).role(.meta)
      }
    }.padding(.horizontal, 14).padding(
      .bottom,
      queued.isEmpty && flow.offline.tasks.isEmpty && flow.prefilledEdits == nil && !agent.running
        && !JevOfferRow.visible(agent)
        ? 0 : 8)
  }
  func row(
    _ text: String, caption: String, sendLabel: String?, send: (() -> Void)?,
    edit: (() -> Void)? = nil, remove: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: 8) {
      InterfaceIcon(systemName: "clock", size: 12).foregroundStyle(p.secondary).padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(text).font(UIStyle.body).lineLimit(2)
        Text(caption).role(.meta)
      }
      Spacer(minLength: 8)
      if let sendLabel, let send {
        Button(sendLabel, action: send).buttonStyle(QuietButton())
      }
      if let edit {
        Button("Edit", action: edit).buttonStyle(QuietButton())
          .help("Put these words back in the composer")
      }
      Button(action: remove) { InterfaceIcon(systemName: "xmark", size: 11) }
        .buttonStyle(QuietButton()).accessibilityLabel(edit == nil ? "Remove waiting message" : "Discard")
        .help(edit == nil ? "Remove" : "Discard")
    }.padding(8).background(p.panel, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
      .accessibilityElement(children: .contain)
  }
}

/// Words sent into the step that runs and not read yet: dimmed, until their bubble joins the chat.
struct SteeringRows: View {
  @ObservedObject var run: AgentRun
  @Environment(\.palette) var p
  var body: some View {
    ForEach(run.steering.pendingDisplay, id: \.id) { line in
      VStack(alignment: .leading, spacing: 2) {
        Text(line.shown).font(UIStyle.body).lineLimit(2)
        Text(verbatim: run.steering.waitsForNextTurn(line) ? "Waiting for the next reply" : RunSteering.sent(app: run.spec.provider.name)).role(.meta)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .background(p.panel, in: RoundedRectangle(cornerRadius: UIStyle.controlRadius)).opacity(0.6)
        .accessibilityElement(children: .combine)
    }
  }
}

/// Retry, Continue in a copy and Send to another project, under a thread's messages.
struct ThreadActionsBar: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject private var flow: ComposerFlow
  @Environment(\.palette) var p
  /// The thread's session log is open (SessionLogSheet).
  @State private var logOpen = false
  init(browser: BrowserModel, agent: AgentModel) {
    self.browser = browser
    self.agent = agent
    _flow = ObservedObject(wrappedValue: agent.flow)
  }
  var body: some View {
    if !agent.running && !agent.messages.isEmpty {
      // In the narrow task panel the labels give way to icons (names stay in help and VoiceOver).
      ViewThatFits(in: .horizontal) {
        bar.labelStyle(.titleAndIcon)
        bar.labelStyle(.iconOnly)
      }.sheet(isPresented: $logOpen) {
        SessionLogSheet(id: agent.conversationID, agent: agent) { logOpen = false }.environment(\.palette, p)
      }
    }
  }
  var bar: some View {
      HStack(spacing: 4) {
        if flow.canRetry {
          Button { flow.retry() } label: {
            Label("Retry", systemImage: "arrow.clockwise").font(UIStyle.meta)
          }.buttonStyle(QuietButton()).help("Send the last request again")
        }
        // A chat its own app answers: a copy where its CLI can make one; another project could not
        // run it.
        if !agent.repliesInApp { copyActions } else if canCopyInApp { copyButton }
        Button { logOpen = true } label: {
          Label("Session log", systemImage: "list.bullet.rectangle").font(UIStyle.meta)
        }.buttonStyle(QuietButton()).help("Read this task's steps, cards and outputs in order, and continue or fork from any of them")
        Spacer(minLength: 0)
      }.foregroundStyle(p.secondary)
  }
  var canCopyInApp: Bool {
    agent.link.flatMap { HarnessDriver(rawValue: $0.driver) }.map(HarnessCommands.copies) ?? false
  }
  var copyButton: some View {
    Button { flow.continueInCopy() } label: {
      Label("Continue in a copy", systemImage: "arrow.triangle.branch").font(UIStyle.meta)
    }.buttonStyle(QuietButton())
      .help(agent.repliesInApp ? "Go on in a copy of this chat. The original stays as it is." : "Start a new thread from a short summary. This one stays as it is.")
  }
  @ViewBuilder var copyActions: some View {
        copyButton
        Menu {
          ForEach(browser.listedProjects.filter { $0.id != agent.projectID }) { project in
            Button(project.name) { flow.continueInCopy(project: project) }
          }
        } label: {
          Label("Send to another project…", systemImage: "folder").font(UIStyle.meta)
        }.composerMenu().fixedSize().disabled(browser.listedProjects.filter { $0.id != agent.projectID }.isEmpty)
          .help("Open a copy in another project, with your last request ready to send")
  }
}

/// Settings › AI apps: choose threads to delete.
struct ThreadDeletionSettings: View {
  @ObservedObject var agent: AgentModel
  @State private var open = false
  @Environment(\.palette) var p
  var body: some View {
    SettingsGroup("Threads") {
      HStack {
        Text("\(agent.listedConversations.count) saved")
        Spacer()
        Button("Delete Threads…") { open = true }.disabled(agent.listedConversations.isEmpty)
      }
      SettingsNote("Codex and Claude Code keep their own session logs, and Projects opens them again.")
    }.sheet(isPresented: $open) {
      ThreadDeletionSheet(agent: agent) { open = false }.environment(\.palette, p)
    }
  }
}

struct ThreadDeletionSheet: View {
  @ObservedObject var agent: AgentModel
  var close: () -> Void
  @State private var selection = Set<String>()
  @State private var result: String?
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Delete threads").role(.section)
      Text("Choose the threads to remove from Serein. Tasks still running in them stop.").role(.meta)
      List(agent.listedConversations, selection: $selection) { thread in
        HStack {
          Text(thread.title).lineLimit(1)
          Spacer()
          if agent.hub.run(for: thread.id) != nil { Text("Running").role(.meta) }
          Text(thread.updatedAt, style: .date).font(UIStyle.microMono).foregroundStyle(p.faint)
        }.tag(thread.id)
      }.frame(height: 280).scrollContentBackground(.hidden)
      if let result { Text(result).role(.meta) }
      HStack {
        Button("Select all") { selection = Set(agent.listedConversations.map(\.id)) }
        Spacer()
        Button("Done", action: close)
        Button("Delete \(shown.count)") {
          // Only what the list shows: Serein's own chats are never deleted from here.
          let n = agent.flow.deleteThreads(shown)
          selection = []
          result = "Deleted \(n) thread\(n == 1 ? "" : "s")."
        }.buttonStyle(PrimaryButton()).disabled(shown.isEmpty)
      }
    }.padding(20).frame(width: UIStyle.wide(460)).background(p.panel)
  }
  /// The selection, limited to the chats the list shows.
  private var shown: Set<String> { selection.intersection(agent.listedConversations.map(\.id)) }
}
