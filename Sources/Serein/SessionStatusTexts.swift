import AppKit
import SereinCore
import SwiftUI

/// Host-written notices, never model input. The tracker and outbox are one atomic checkpoint;
/// the notice's stable message id closes the crash window between chat delivery and dequeue.
/// A session waiting on the person is not a chat message: it is `waiting`, which the row at the
/// foot of Serein's chat shows while it is true (`WaitingSessionsRow`), with a notification. A
/// turn that ended with no report is a row on one "Sessions finished" card (`postFinish`).
@MainActor final class SessionStatusTexts: ObservableObject {
  static let shared = SessionStatusTexts()
  /// Sessions in other apps waiting on the person, by id, with when the wait became news.
  @Published private(set) var waiting: [String: Date] = [:]
  static let enabledKey = "serein.sessionStatus.enabled"
  static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
  static let checkpointPath = "sessions/status-updates.json"
  var enabledOverride: Bool?
  private static let retryWhileBusy: TimeInterval = 15
  /// How long the finished chat may take to read; a long session's file can take a while.
  private static let reportWait: Duration = .seconds(20)
  private static let explanationWait: Duration = .seconds(60)

  private struct Held: Codable {
    var id = UUID().uuidString
    var words: String
    var waitingSession: String?
    var about: String? = nil
    var reel: ReportReel? = nil
    var event: SessionStatusTracker.Event? = nil
    var needsReport = false
    var sourceVersion: TimeInterval?
    var finishedAt: Date?
    /// The session's own title, as its app lists it: what the fallback names when no report comes.
    /// Kept only while the person lets Serein read their chats.
    var title: String? = nil
    /// A readable final reply that contains no news; persist that decision across restarts.
    var quiet: Bool? = nil
    /// Its words are the turn's report, not the fallback: it posts as its own message. A finish
    /// without one is a row on the "Sessions finished" card.
    var reported: Bool? = nil
  }
  private struct Checkpoint: Codable {
    var tracker: SessionStatusTracker
    var held: [Held]
    /// Absent in checkpoints from before the row.
    var waiting: [String: Date]? = nil
  }
  private weak var relay: RelayOrchestrator?
  private var tracker = SessionStatusTracker()
  private var held: [Held] = []
  private var wake: Task<Void, Never>?
  private var reportTask: Task<Void, Never>?
  private var reportDeadline: Task<Void, Never>?
  private var generation = UUID()
  private var unreadableCheckpoint = false
  private var observed = false
  #if DEBUG
  var holdDeliveryForChecks = false
  var watchingForChecks: Bool?
  #endif

  func attach(_ relay: RelayOrchestrator) {
    self.relay = relay
    let url = relay.browser.library.root.appendingPathComponent(Self.checkpointPath)
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(Checkpoint.self, from: Data(contentsOf: url))
        tracker = saved.tracker; held = saved.held
        waiting = saved.waiting ?? [:]
        // A question queued as a chat text before the row: it waits in the row instead.
        for id in held.compactMap(\.waitingSession) where waiting[id] == nil { waiting[id] = Date() }
        held.removeAll { $0.waitingSession != nil }
      } catch {
        // Do not overwrite pending evidence with an empty queue if it cannot be decoded.
        unreadableCheckpoint = true
        relay.agent.error = "Serein could not restore pending AI-app updates: " + error.localizedDescription
      }
    }
    ExternalSessionStore.shared.onScan = { [weak self] sessions in self?.observe(sessions) }
    ExternalSessionStore.shared.onStopped = { [weak self] in self?.stopped() }
    drain()
  }

  /// Explicitly disabling watching/updates clears their queue, unlike a pause or app restart.
  func stopped() {
    generation = UUID()
    reportTask?.cancel(); reportTask = nil
    reportDeadline?.cancel(); reportDeadline = nil
    wake?.cancel(); wake = nil
    tracker = SessionStatusTracker(); held = []; waiting = [:]
    _ = checkpoint()
  }

  /// `--ui-session-status`: a session shown waiting in the row without the tracker. UI previews only.
  func previewWaiting(_ id: String, since: Date) {
    guard CommandLine.arguments.contains("--ui-preview") else { return }
    waiting[id] = since
  }

  func observe(_ sessions: [ExternalSession], now: Date = Date()) {
    guard !unreadableCheckpoint else { return }
    guard enabledOverride ?? Self.enabled else { stopped(); return }
    observed = true
    // An answered (or closed) session leaves the row at once.
    let still = waiting.filter { id, _ in sessions.contains { $0.id == id && $0.state == .needsUser } }
    if still.count != waiting.count { waiting = still }
    tracker.observe(sessions.filter { !ProjectChatIndex.isTemporary($0.cwd) && $0.parent == nil }, now: now)
    step(now: now)
  }

  func taskFinished(_ run: AgentRun, now: Date = Date()) {
    guard let relay, speaks(relay), !relay.agent.isSereinThread(run.spec.threadID) else { return }
    let event = SessionStatusTracker.Event(
      kind: .finished, sessionID: run.spec.threadID, app: run.spec.provider.name,
      folder: SessionStatusWords.place(run.folder?.path, home: NSHomeDirectory()))
    hold(SessionStatusWords.text([event]), waitingSession: nil)
    drain()
  }

  private func step(now: Date = Date()) {
    guard enabledOverride ?? Self.enabled else { stopped(); return }
    let events = tracker.due(now: now, isAlive: Self.isAlive, isWatching: watching)
    for event in events {
      if event.kind == .needsYou {
        // The row says it while it is true; the notification brings the person back to it.
        waiting[event.sessionID] = now
        if let relay, speaks(relay) { notify(event, relay: relay) }
      } else {
        let source = ExternalSessionStore.shared.sessions.first { $0.id == event.sessionID && $0.state == .open }
        // A title can quote the chat, so it is named only while the person lets Serein read chats.
        let title = SessionReading.allowed ? ExternalSessionStore.shared.sessions.first { $0.id == event.sessionID }?.title : nil
        held.append(Held(id: event.id, words: Self.fallback(event, title: title, finishedAt: now), about: Self.place(event),
          event: event, needsReport: true, sourceVersion: source.map(Self.version), finishedAt: now,
          title: title))
      }
    }
    drain()
  }

  private func speaks(_ relay: RelayOrchestrator) -> Bool {
    !RelayController.previewing && !RelayOrchestrator.quietForChecks && !relay.state.paused
      && relay.team.main != nil && (enabledOverride ?? Self.enabled)
  }

  /// When the session last changed: for Claude Code, its last message (its bookkeeping lines move
  /// the file's time after every turn, `TranscriptClock`); for the others, the file's time.
  static func version(_ session: ExternalSession) -> TimeInterval {
    let message = session.driver == .claude ? session.log.flatMap(TranscriptClock.lastMessage(path:)) : nil
    return (message ?? session.updatedAt).timeIntervalSinceReferenceDate
  }

  static func place(_ event: SessionStatusTracker.Event) -> String { event.app + "|" + (event.folder ?? "") }

  /// When its report can't be read: what finished, where and for how long (the turn's own length,
  /// to when it ended, not to when Serein noticed), from the session list
  /// alone (its title, folder and times; nothing from the chat itself).
  nonisolated static func fallback(_ event: SessionStatusTracker.Event, title: String? = nil, finishedAt: Date? = nil) -> String {
    SessionStatusWords.finished(app: event.app, title: title, folder: event.folder, minutes: minutes(event, finishedAt: finishedAt))
  }

  /// The turn's own length, to when it ended (not to when Serein noticed); nil when unknown.
  nonisolated static func minutes(_ event: SessionStatusTracker.Event, finishedAt: Date?) -> Double? {
    event.startedAt.flatMap { start in (event.endedAt ?? finishedAt).map { max(0, $0.timeIntervalSince(start)) / 60 } }
  }

  /// A finish with no report, as its row on the "Sessions finished" card.
  private static func row(_ item: Held, event: SessionStatusTracker.Event) -> SessionFinish {
    SessionFinish(id: item.id, sessionID: event.sessionID, app: event.app, title: item.title, folder: event.folder,
      minutes: minutes(event, finishedAt: item.finishedAt), endedAt: event.endedAt ?? item.finishedAt ?? Date())
  }

  @discardableResult private func checkpoint() -> Bool {
    guard !unreadableCheckpoint, let relay else { return false }
    do {
      try relay.browser.library.save(Checkpoint(tracker: tracker, held: held, waiting: waiting), to: Self.checkpointPath)
      return true
    } catch {
      relay.agent.error = "Serein could not save pending AI-app updates: " + error.localizedDescription
      return false
    }
  }

  private func drain() {
    guard checkpoint() else { scheduleWake(); return }
    flush()
    prepareReport()
    scheduleWake()
  }

  private func prepareReport() {
    guard reportTask == nil, let first = held.first, first.needsReport, let event = first.event,
      let relay, speaks(relay) else { return }
    #if DEBUG
    if holdDeliveryForChecks { return }
    #endif
    let token = generation
    func matchesSource() -> Bool {
      guard let stamp = first.sourceVersion else {
        // Codex removes a completed turn from its active list. Its saved native id still
        // identifies the report; the file's timestamp below prevents reading a newer turn.
        return event.sessionID.hasPrefix("codex:")
          && !ExternalSessionStore.shared.sessions.contains { $0.id == event.sessionID }
      }
      return ExternalSessionStore.shared.sessions.contains {
        $0.id == event.sessionID && $0.state == .open && Self.version($0) == stamp
      }
    }
    // A stalled reader must not prevent the completion (or the notices behind it) from landing.
    reportDeadline = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.explanationWait)
      guard !Task.isCancelled, let self, generation == token,
        let index = held.firstIndex(where: { $0.id == first.id && $0.needsReport }) else { return }
      reportTask?.cancel(); reportTask = nil; reportDeadline = nil
      held[index].needsReport = false
      drain()
    }
    reportTask = Task { @MainActor [weak self] in
      let report = SessionReading.allowed && matchesSource()
        ? await Self.report(event, browser: relay.browser, finishedAt: first.finishedAt) : nil
      guard let self, !Task.isCancelled, generation == token,
        let index = held.firstIndex(where: { $0.id == first.id && $0.needsReport }) else { return }
      // Recheck revocation after the transcript read. The fallback carries no transcript text.
      if SessionReading.allowed, matchesSource(), let report {
        held[index].words = report.text
        held[index].quiet = report.text.isEmpty
        held[index].reel = report.reel
        held[index].reported = true
        if let reel = report.reel {
          ReportReelMaker.remember(reel, project: event.folder, library: relay.browser.library)
        }
      }
      held[index].needsReport = false
      reportDeadline?.cancel(); reportDeadline = nil
      reportTask = nil
      drain()
    }
  }

  private func notify(_ event: SessionStatusTracker.Event, relay: RelayOrchestrator) {
    let session = ExternalSessionStore.shared.sessions.first { $0.id == event.sessionID }
    guard !(session?.pid.map(watching) ?? false),
      let main = relay.team.main, let thread = relay.existingThread(of: main.id) else { return }
    TaskNotifications.shared.post(threadID: thread, title: main.name, body: SessionStatusWords.notification([event]))
  }

  private func hold(_ words: String, waitingSession: String?, about: String? = nil, reel: ReportReel? = nil) {
    held.append(Held(words: words, waitingSession: waitingSession, about: about, reel: reel))
  }

  private func flush() {
    guard let relay, speaks(relay), !SereinChatSetup.shared.isActive(in: relay),
      let main = relay.team.main, let thread = relay.existingThread(of: main.id) else { return }
    #if DEBUG
    if holdDeliveryForChecks { return }
    #endif
    let sessions = ExternalSessionStore.shared.sessions
    // Answered questions expire; completed work remains queued until the chat can save it.
    if observed {
      held.removeAll { item in
        item.waitingSession.map { id in !sessions.contains { $0.id == id && $0.state == .needsUser } } ?? false
      }
    }
    if !SessionReading.allowed {
      for index in held.indices where held[index].event?.kind == .finished {
        held[index].words = Self.fallback(held[index].event!, finishedAt: held[index].finishedAt)
        held[index].title = nil
        held[index].reel = nil
        held[index].reported = nil
      }
    }
    guard checkpoint() else { return }
    while let next = held.first, !next.needsReport {
      if next.waitingSession != nil, !observed { return }
      if next.quiet == true {
        held.removeFirst()
        guard checkpoint() else { return }
        continue
      }
      let alreadyPosted: Bool
      if let event = next.event, event.kind == .finished, next.reported != true {
        // Nothing to tell but that it ended: a row on the card, not a line of its own.
        let row = Self.row(next, event: event)
        alreadyPosted = relay.agent.hasFinish(row.id, into: thread)
        guard relay.agent.postFinish(row, into: thread) == true else { return }
      } else {
        alreadyPosted = relay.agent.hasNotice(next.id, into: thread)
        guard relay.agent.postNotice(next.words, into: thread, waitingSession: next.waitingSession,
          about: next.about, reel: next.reel, id: next.id) == true else { return }
      }
      held.removeFirst()
      guard checkpoint() else { return }
      if !alreadyPosted, let event = next.event { notify(event, relay: relay) }
      relay.objectWillChange.send()
    }
  }

  #if DEBUG
  func holdForChecks(_ words: String, waitingSession: String?) { hold(words, waitingSession: waitingSession); _ = checkpoint() }
  func detachForChecks() {
    generation = UUID(); wake?.cancel(); wake = nil; reportTask?.cancel(); reportTask = nil
    reportDeadline?.cancel(); reportDeadline = nil
    ExternalSessionStore.shared.onScan = nil; ExternalSessionStore.shared.onStopped = nil
  }
  #endif

  /// A finished turn interpreted by a tool-free model from the request, report and action record,
  /// with its reel (`ReportReel`): git's line counts, its test runs, and the media it wrote in its
  /// project during the turn. Nil when its transcript cannot be read in time or says nothing. The
  /// chat's own pictures never show: they are often the person's screenshots, and not news.
  static func report(_ event: SessionStatusTracker.Event, browser: BrowserModel, finishedAt: Date? = nil) async -> (text: String, reel: ReportReel?)? {
    let current = ExternalSessionStore.shared.sessions.first { $0.id == event.sessionID }
    let session: ExternalSession
    if let current {
      guard current.state == .open else { return nil }
      session = current
    } else {
      guard finishedAt != nil, event.sessionID.hasPrefix("codex:"),
        UUID(uuidString: String(event.sessionID.dropFirst(6))) != nil else { return nil }
      session = ExternalSession(id: event.sessionID, driver: .codex, title: "", cwd: nil, state: .open, updatedAt: Date())
    }
    guard let link = SessionOpen.link(for: session) else { return nil }
    // Reading a chat only: the installed Codex will do, even while Serein does not run tasks on it.
    let codex = HarnessRegistry.shared.executable(Provider(.codex))
      ?? HarnessRegistry.shared.snapshots[.codex].flatMap { $0.installed ? $0.path : nil }
    let reading = Task { try await LinkedSessionMonitor.read(link, codex: codex) }
    let timeout = Task { try? await Task.sleep(for: reportWait); reading.cancel() }
    defer { timeout.cancel() }
    guard let history = try? await reading.value, !history.working else { return nil }
    if let finishedAt {
      if let path = history.path {
        // A newer turn must not stand in for this one; Claude Code's own stamps say when its chat
        // last changed, since its bookkeeping lines move the file's time after every turn.
        let stamped = session.driver == .claude ? TranscriptClock.lastMessage(path: path) : nil
        guard let changed = stamped ?? ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date),
          changed <= finishedAt else { return nil }
      } else if current == nil { return nil }
    }
    let start = history.messages.lastIndex(where: { $0.role == "you" }).map { $0 + 1 } ?? 0
    let turn = history.messages[start...]
    let answer = turn.last(where: { !$0.text.isEmpty })?.text ?? ""
    let activities = turn.flatMap(\.activities)
    // An unreadable report still needs a fallback; a readable courtesy needs no notification.
    guard !answer.isEmpty || !activities.isEmpty else { return nil }
    let request = history.messages.last(where: { $0.role == "you" })?.text ?? ""
    let evidence = CompletionExplanation.Evidence(request: request, answer: answer, activities: activities, goalState: session.goal)
    guard let text = await CompletionNarrator.explain(evidence, app: event.app, folder: event.folder,
      agent: RelayOrchestrator.shared?.agent) else { return nil }
    if text.isEmpty { return ("", nil) }
    let reel = await ReportReelMaker.make(
      app: event.app, project: event.folder, cwd: session.cwd, since: event.startedAt, until: Date(),
      activities: activities, library: browser.library)
    return (text, reel)
  }

  private func scheduleWake() {
    wake?.cancel()
    guard !unreadableCheckpoint else { return }
    let retry = held.isEmpty ? nil : Date().addingTimeInterval(Self.retryWhileBusy)
    guard let next = [tracker.nextDue, retry].compactMap({ $0 }).min() else { wake = nil; return }
    let delay = max(0.5, next.timeIntervalSinceNow)
    wake = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.step()
    }
  }

  private func watching(_ pid: Int32) -> Bool {
    #if DEBUG
    if let watchingForChecks { return watchingForChecks }
    #endif
    return Self.isWatching(pid)
  }

  nonisolated private static func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  /// The app holding the session is the one in front, so the person can already see it.
  private static func isWatching(_ pid: Int32) -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
    return pid == front || HarnessProcessDiscovery.ancestors(pid).contains(front)
  }
}

