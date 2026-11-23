import AppKit
import Foundation
import SereinCore

/// One turn's file changes and approvals, shown as cards in its thread.
struct TurnReview: Codable, Identifiable, Equatable {
  enum State: Codable, Equatable {
    /// Saving the "before" snapshot; the CLI has not started yet.
    case snapshotting
    case running
    /// Saving the "after" snapshot and counting changes.
    case finishing
    case ready
    case refused(String)
    case notGit
    case failed(String)
    /// Not tracked (edits were off); kept only for its approvals.
    case none
  }
  enum Resolution: String, Codable { case allowedOnce, alwaysAllowed, denied }
  var id: String
  var threadID: String
  var messageID: String?
  var projectID: String?
  var projectName: String
  var folder: String
  var root: String?
  var state: State
  var before: String?
  var after: String?
  var files: [DiffFile] = []
  var undone = false
  var approvals: [PendingApproval] = []
  var resolution: Resolution?
  var endedAt: Date?
  /// Untracked files never saved in either snapshot (secrets, files over 5 MB).
  var skipped: [String]?
  /// Another turn edited the same repository while this one ran, so its changes are mixed in.
  var overlapped: Bool?
  var tracked: Bool { state == .ready && before != nil && after != nil }
  var inProgress: Bool { [.snapshotting, .running, .finishing].contains(state) }
}

/// Owns per-turn snapshots (via `GitTurns`, off the main thread), Undo/Redo, the ⌘Z toast and
/// one-shot / always edit approvals. Snapshots live as private git refs; nothing is committed.
///
/// Git work for one repository (its resolved root, not the folder) runs strictly in order: a new
/// turn's "before" snapshot waits for the previous turn's "after" snapshot, and a stopped turn's
/// "after" snapshot waits for its process group to exit.
@MainActor final class EditReview: ObservableObject {
  static let shared = EditReview()
  static let path = "sessions/turn-reviews.json"
  static let keep = 80
  @Published private(set) var reviews: [TurnReview] = []
  /// Reviews with a git operation in flight.
  @Published private(set) var busy = Set<String>()
  /// Latest refusal or result line per review.
  @Published var notes: [String: String] = [:]
  /// Why an answer to an edit approval did not reach its task, shown on that approval card.
  @Published private(set) var answerNotes: [String: String] = [:]
  @Published var toast: Toast?
  struct Toast: Equatable {
    var reviewID: String
    var threadID: String
    var text: String
  }
  private var library: Library?
  /// Threads whose next turn may edit once ("Allow once").
  private var oneShot = Set<String>()
  /// Answers given while their thread was working, applied when its step ends (HeldAnswers).
  @Published private(set) var held = HeldAnswers<TurnReview.Resolution>()
  /// The model a held answer goes through when it is applied.
  private weak var heldAgent: AgentModel?
  private var toastTask: Task<Void, Never>?
  /// The last queued git job per repository root.
  private var chains: [String: Task<Void, Never>] = [:]
  /// Reviews of deleted threads still finishing; dropped with their refs when done.
  private var discarding = Set<String>()

  func configure(_ library: Library?) {
    guard self.library == nil, let library else { return }
    self.library = library
    var saved = library.load([TurnReview].self, from: Self.path) ?? []
    for i in saved.indices where saved[i].inProgress {
      saved[i].state = .failed(EditTrackingCopy.interrupted)
    }
    reviews = saved
    prune()
    save()
    pruneRefs()
  }

  /// Synthetic UI previews only: shows these cards without any snapshot work.
  func seedPreview(_ items: [TurnReview]) { reviews = items }

  func review(for messageID: String) -> TurnReview? {
    reviews.last { $0.messageID == messageID }
  }

  // MARK: Run lifecycle (called by AgentHub)

  /// Saves the "before" snapshot, then calls `ready` on the main actor (always, even on refusal).
  func begin(_ run: AgentRun, folder: URL, library: Library?, ready: @escaping () -> Void) {
    configure(library)
    let id = run.id
    upsert(
      TurnReview(
        id: id, threadID: run.spec.threadID, projectID: run.spec.projectID,
        projectName: run.spec.projectName ?? folder.lastPathComponent, folder: folder.path,
        state: .snapshotting))
    Task { @MainActor in
      let probe = await Task.detached(priority: .userInitiated) { GitTurns.probe(folder: folder) }.value
      guard var current = self.reviews.first(where: { $0.id == id }) else { return ready() }
      switch probe {
      case .noGit: current.state = .refused(EditTrackingCopy.noGit)
      case .notGit: current.state = .notGit
      case .refused(let copy): current.state = .refused(copy)
      case .repo(let found):
        current.root = found.root.path
        if current.endedAt != nil {
          // Stopped before the CLI started: nothing changed.
          current.state = .none
        } else {
          let others = self.reviews.filter {
            $0.id != id && $0.root == found.root.path
              && ($0.state == .running || ($0.state == .snapshotting && $0.endedAt == nil))
          }
          if !others.isEmpty {
            // Another turn edits this repository right now; neither turn's changes stand alone.
            current.state = .refused(EditTrackingCopy.sharedProject)
            for var other in others {
              other.overlapped = true
              self.upsert(other)
            }
          } else {
            self.upsert(current)
            await self.enqueue(found.root.path) {
              await self.snapshotBefore(id: id, repo: found)
            }.value
            ready()
            return
          }
        }
      }
      self.upsert(current)
      self.finishDiscarding(id)
      ready()
    }
  }

  private func snapshotBefore(id: String, repo: GitTurns) async {
    // Stopped while waiting for an earlier turn in this repository.
    guard var current = reviews.first(where: { $0.id == id }), current.endedAt == nil else {
      if var current = reviews.first(where: { $0.id == id }) {
        current.state = .none
        upsert(current)
      }
      finishDiscarding(id)
      return
    }
    let outcome = await Task.detached(priority: .userInitiated) { () -> Result<GitTurns.Snapshot, StateFailure> in
      do {
        let snapshot = try repo.capture()
        try repo.keep(snapshot.tree, run: id, name: "before")
        return .success(snapshot)
      } catch GitTurns.Failure.refused(let copy) {
        return .failure(StateFailure(.refused(copy)))
      } catch {
        return .failure(StateFailure(.failed(EditTrackingCopy.snapshotFailed)))
      }
    }.value
    guard let latest = reviews.first(where: { $0.id == id }) else { return }
    current = latest
    switch outcome {
    case .success(let snapshot):
      current.before = snapshot.tree
      current.skipped = snapshot.skipped.isEmpty ? nil : snapshot.skipped
      // Stopped while the snapshot was saved: the CLI never ran, so nothing changed.
      current.state = current.endedAt == nil ? .running : .none
    case .failure(let failure): current.state = failure.state
    }
    upsert(current)
    finishDiscarding(id)
  }

  /// Called when the run ends: attaches the turn to its last message and saves "after".
  func end(_ run: AgentRun) {
    configure(nil)
    let anchor = run.transcript.last?.id
    var review =
      reviews.first { $0.id == run.id }
      ?? TurnReview(
        id: run.id, threadID: run.spec.threadID, projectID: run.spec.projectID,
        projectName: run.spec.projectName ?? "this project", folder: run.folder?.path ?? "",
        state: .none)
    review.messageID = anchor
    review.endedAt = Date()
    review.approvals = run.approvals
    defer { stepEnded(run) }
    guard review.state == .running, let root = review.root, let before = review.before else {
      if review.approvals.isEmpty && review.state == .none {
        reviews.removeAll { $0.id == run.id }
        save()
      } else {
        upsert(review)
      }
      return
    }
    review.state = .finishing
    upsert(review)
    let id = run.id
    let threadID = run.spec.threadID
    // Late writes of a stopped CLI land in this turn's "after" snapshot.
    let turn = run.harnessTurn
    let skippedBefore = review.skipped ?? []
    enqueue(root) {
      await turn?.settled(timeout: 120)
      let outcome = await Task.detached(priority: .userInitiated) {
        Self.snapshotAfter(root: root, before: before, run: id, skippedBefore: skippedBefore)
      }.value
      guard var current = self.reviews.first(where: { $0.id == id }) else { return }
      switch outcome {
      case .success(let (after, files, skipped)):
        current.after = after
        current.files = files
        current.skipped = skipped.isEmpty ? nil : skipped
        current.state = .ready
        if !files.isEmpty && !self.discarding.contains(id) {
          self.showToast(
            Toast(
              reviewID: id, threadID: threadID,
              text: DiffStat.headline(files) + " in \(current.projectName)."))
        }
      case .failure(let failure): current.state = failure.state
      }
      self.upsert(current)
      self.finishDiscarding(id)
    }
  }

  /// Runs `work` after every earlier git job for the same repository root.
  @discardableResult
  private func enqueue(_ root: String, _ work: @escaping @MainActor () async -> Void) -> Task<
    Void, Never
  > {
    let previous = chains[root]
    let task = Task { @MainActor in
      await previous?.value
      await work()
    }
    chains[root] = task
    Task { @MainActor in
      await task.value
      if self.chains[root] == task { self.chains[root] = nil }
    }
    return task
  }

  nonisolated private static func snapshotAfter(
    root: String, before: String, run: String, skippedBefore: [String]
  ) -> Result<(String, [DiffFile], [String]), StateFailure> {
    guard let git = GitTurns.locateGit() else {
      return .failure(StateFailure(.refused(EditTrackingCopy.noGit)))
    }
    let repo = GitTurns(git: git, root: URL(fileURLWithPath: root))
    do {
      // The limits were checked before the turn; a turn that adds huge files still gets its card.
      let snapshot = try repo.capture(maxBytes: .max, maxFiles: .max)
      try repo.keep(snapshot.tree, run: run, name: "after")
      // A file left out of either snapshot is never shown, undone or redone.
      var skipped = skippedBefore
      for path in snapshot.skipped where !skipped.contains(path) { skipped.append(path) }
      let left = Set(skipped)
      let files = try repo.numstat(before, snapshot.tree).filter { !left.contains($0.path) }
      return .success((snapshot.tree, files, skipped))
    } catch {
      return .failure(StateFailure(.failed(EditTrackingCopy.snapshotFailed)))
    }
  }

  struct StateFailure: Error {
    var state: TurnReview.State
    init(_ state: TurnReview.State) { self.state = state }
  }

  // MARK: Undo and redo

  /// Restores the turn's files to before (undo) or after (redo) it, refusing with clear copy.
  /// The files must be exactly as the turn left them (undo) or found them (redo); any later edit,
  /// including the user's own, refuses and changes nothing.
  func perform(_ action: TurnUndo.Action, reviewID: String, hub: AgentHub) {
    guard let review = reviews.first(where: { $0.id == reviewID }), !busy.contains(reviewID) else {
      return
    }
    // Any run in this thread or project, including a later turn, blocks the files.
    let running =
      review.inProgress || hub.run(for: review.threadID) != nil
      || reviews.contains { $0.inProgress && $0.root != nil && $0.root == review.root }
    if let refusal = TurnUndo.refusal(
      action, running: running, tracked: review.tracked, files: review.files.count,
      undone: review.undone)
    {
      notes[reviewID] = refusal
      return
    }
    guard let root = review.root, let before = review.before, let after = review.after else { return }
    let paths = review.files.map(\.path)
    busy.insert(reviewID)
    notes[reviewID] = nil
    if toast?.reviewID == reviewID { toast = nil }
    enqueue(root) {
      let message = await Task.detached(priority: .userInitiated) {
        Self.restore(action, root: root, before: before, after: after, paths: paths)
      }.value
      self.busy.remove(reviewID)
      guard let i = self.reviews.firstIndex(where: { $0.id == reviewID }) else { return }
      if let message {
        self.notes[reviewID] = message
      } else {
        self.reviews[i].undone = action == .undo
        self.notes[reviewID] =
          action == .undo
          ? "Restored these files to how they were before this turn."
          : "Applied this turn's changes again."
        self.save()
      }
    }
  }

  /// nil on success, otherwise user-facing copy.
  nonisolated private static func restore(
    _ action: TurnUndo.Action, root: String, before: String, after: String, paths: [String]
  ) -> String? {
    guard let git = GitTurns.locateGit() else { return EditTrackingCopy.noGit }
    let repo = GitTurns(git: git, root: URL(fileURLWithPath: root))
    do {
      // The files must still be exactly as the turn left them (undo) or found them (redo).
      let expected = action == .undo ? after : before
      let current = try repo.snapshot()
      let changed = try repo.changedPaths(expected, current)
      if let copy = TurnUndo.conflictCopy(
        TurnUndo.conflicts(turnFiles: paths, changedSince: changed), action: action)
      {
        return copy
      }
      try repo.restore(action == .undo ? before : after, paths: paths)
      return nil
    } catch GitTurns.Failure.refused(let copy) {
      return copy
    } catch {
      return EditTrackingCopy.restoreFailed
    }
  }

  /// One file's diff for the expanded row.
  func patch(reviewID: String, path: String) async -> (text: String, truncated: Bool)? {
    guard let review = reviews.first(where: { $0.id == reviewID }), let root = review.root,
      let before = review.before, let after = review.after
    else { return nil }
    return await Task.detached(priority: .userInitiated) {
      guard let git = GitTurns.locateGit() else { return nil }
      return try? GitTurns(git: git, root: URL(fileURLWithPath: root)).patch(before, after, path: path)
    }.value
  }

  /// "Initialize git here": runs only when the user presses the button.
  func initializeGit(reviewID: String) {
    guard let review = reviews.first(where: { $0.id == reviewID }), review.state == .notGit else {
      return
    }
    let folder = URL(fileURLWithPath: review.folder)
    busy.insert(reviewID)
    Task.detached(priority: .userInitiated) {
      let message: String
      if let git = GitTurns.locateGit() {
        do {
          try GitTurns.initialize(folder: folder, git: git)
          message = "Git is set up. Changes from the next turn can be reviewed and undone."
        } catch {
          message = "Git couldn't be set up in this folder."
        }
      } else {
        message = EditTrackingCopy.noGit
      }
      await MainActor.run {
        self.busy.remove(reviewID)
        self.notes[reviewID] = message
      }
    }
  }

  // MARK: Approvals

  /// True when this turn may edit because the user chose "Allow once" for it. The grant is spent
  /// here whether or not the turn is a project turn. "Always allow" works through the thread's
  /// own "Allow project edits" toggle, which it turns on, so the toggle always tells the truth.
  func editsGranted(thread: String, projectID: String?) -> Bool {
    oneShot.remove(thread) != nil && projectID != nil
  }

  /// An unused "Allow once" never follows the user into another thread or a later message.
  func dropOneShot(thread: String) {
    oneShot.remove(thread)
  }

  /// Edit and rerun: nothing answered for the replaced turns reaches the rerun. An unused "Allow once"
  /// and an answer held for the thread go (as Stop drops it), and the replaced turns' open edit
  /// approvals close as declined without sending anything; their cards are no longer in the chat.
  func rewound(thread: String, keeping kept: Set<String>) {
    oneShot.remove(thread)
    if let waiting = held.byThread[thread] {
      held.discard(thread: thread)
      answerNotes[waiting.reviewID] = "You edited a message, so your answer was not sent. Answer again if it still applies."
      heldSettled()
    }
    var changed = false
    for i in reviews.indices where reviews[i].threadID == thread && reviews[i].resolution == nil
      && !reviews[i].approvals.isEmpty && !(reviews[i].messageID.map(kept.contains) ?? false) {
      reviews[i].resolution = .denied
      changed = true
    }
    if changed { save() }
  }

  /// The user's answer to an edit approval. The buttons are never disabled: while the review's
  /// thread works, the answer is held (a later one replaces it) and applied when that thread's
  /// step ends, into that thread wherever the user is by then. Stop discards it.
  func resolve(reviewID: String, _ resolution: TurnReview.Resolution, agent: AgentModel, reply: String = "") {
    guard let review = reviews.first(where: { $0.id == reviewID }) else { return }
    answerNotes[reviewID] = nil
    let working = agent.hub.run(for: review.threadID) != nil
      || (review.threadID == agent.conversationID && agent.running)
    heldAgent = agent
    let answer = HeldAnswers<TurnReview.Resolution>.Answer(
      reviewID: reviewID, threadID: review.threadID, resolution: resolution, reply: reply)
    guard held.answer(answer, threadWorking: working) == .now else { return }
    apply(answer, agent: agent)
  }

  /// A step ended in a thread with a held answer: apply it now, or drop it when the step was
  /// stopped. Runs after the hub has finished with the run, so the thread reads as idle.
  private func stepEnded(_ run: AgentRun) {
    let thread = run.spec.threadID
    guard held.isHolding(thread: thread) else { return }
    let stopped = run.record.outcome == .stopped
    Task { @MainActor in
      // Another step already started in the thread (the user sent one): wait for that one.
      // A queued message waits for the held answer (ComposerFlow.drainQueue).
      guard let agent = self.heldAgent, agent.hub.run(for: thread) == nil else { return }
      let waiting = self.held.byThread[thread]
      guard let answer = self.held.stepEnded(thread: thread, stopped: stopped) else {
        // Stop drops the answer: the card says so, rather than looking unanswered.
        if stopped, let waiting {
          self.answerNotes[waiting.reviewID] = "You stopped the task, so your answer was not sent. Answer again when you continue it."
        }
        self.heldSettled()
        return
      }
      self.apply(answer, agent: agent)
    }
  }

  /// A held answer was applied or dropped: a message queued behind it may go now (ComposerFlow
  /// drains when the thread is idle, so this is safe when the answer started a step).
  static let heldAnswerSettled = Notification.Name("SereinHeldAnswerSettled")
  private func heldSettled() {
    NotificationCenter.default.post(name: Self.heldAnswerSettled, object: nil)
  }

  private func apply(_ answer: HeldAnswers<TurnReview.Resolution>.Answer, agent: AgentModel) {
    defer { heldSettled() }
    guard let i = reviews.firstIndex(where: { $0.id == answer.reviewID }) else { return }
    let review = reviews[i]
    let resolution = answer.resolution
    let message: String
    if let browser = agent.hub.browser,
      let id = UUID(uuidString: answer.reviewID),
      let context = (try? browser.behaviorHistory?.archive(runID: id).events)?.last?.run {
      browser.recordBehavior(context, .approvalResolved,
        effect: .nextTurn,
        decision: resolution == .denied ? .denied : resolution == .allowedOnce ? .allowedOnce : .alwaysAllowed)
    }
    switch resolution {
    case .allowedOnce, .alwaysAllowed:
      if resolution == .alwaysAllowed, let projectID = review.projectID {
        ProjectEditApprovals.allow(projectID)
        if agent.projectID == projectID { agent.allowProjectEdits = true }
      }
      oneShot.insert(review.threadID)
      message = ApprovalReplies.allowOnce
    case .denied:
      message = ApprovalReplies.deny(review.approvals.map(\.label), reply: answer.reply)
    }
    if review.threadID == agent.conversationID {
      // Sending clears the composer; keep whatever the user was typing. The reply carries no
      // context chips: they belong to the user's next message.
      let draft = agent.draft
      agent.send(message, chips: .empty)
      if agent.draft.isEmpty { agent.draft = draft }
      // Spent by the send above when it started a turn; otherwise it must not linger.
      oneShot.remove(review.threadID)
      if agent.running {
        markResolved(answer.reviewID, resolution)
      } else if agent.error != nil {
        // The send was refused: the card stays open, and says why nothing happened.
        answerNotes[answer.reviewID] = "Serein could not send your answer. Try again."
      }
      return
    }
    // Another thread: the answer goes into that thread, as it was set up, without touching the
    // chat the user is in (AgentModel.dispatch swaps it in and back).
    guard let thread = agent.conversations.first(where: { $0.id == review.threadID }) else {
      oneShot.remove(review.threadID)
      answerNotes[review.id] = "This task’s chat is gone, so your answer was not sent."
      return
    }
    let projectID = thread.projectID ?? review.projectID
    // The resumed step gets no more than the thread's last step had: a task Serein started keeps
    // its own setup (an answer task never acts); any other thread keeps the browser actions and
    // Mac grants it ran with.
    let child = RelayOrchestrator.shared?.child(review.threadID)
    let grants = agent.hub.latest(for: review.threadID)?.spec.grants
    let target = AgentModel.DispatchTarget(
      mode: thread.mode, provider: thread.provider, model: thread.model ?? "", effort: thread.effort ?? "medium",
      projectID: projectID, actions: (child != nil && thread.mode != .answer) || grants?.actions == true,
      edits: child?.edits == true || ProjectEditApprovals.isAllowed(projectID),
      mac: thread.mode == .anywhere && (child != nil || grants?.mac == true),
      permission: thread.permission.flatMap(RunPermissionMode.init(rawValue:)) ?? .supervised)
    let reviewID = answer.reviewID
    Task { @MainActor in
      defer { self.oneShot.remove(review.threadID) }
      do {
        _ = try await agent.dispatch(message, into: review.threadID, as: target)
        self.markResolved(reviewID, resolution)
      } catch {
        // The card opens again, so the answer can be given once more.
        self.answerNotes[reviewID] = "Serein could not send your answer. Try again."
      }
      self.heldSettled()
    }
  }

  private func markResolved(_ reviewID: String, _ resolution: TurnReview.Resolution) {
    guard let i = reviews.firstIndex(where: { $0.id == reviewID }) else { return }
    reviews[i].resolution = resolution
    save()
  }

  /// Synthetic UI previews only: an answer held for the review's working thread.
  func seedHeldPreview(reviewID: String, threadID: String, _ resolution: TurnReview.Resolution) {
    _ = held.answer(.init(reviewID: reviewID, threadID: threadID, resolution: resolution), threadWorking: true)
  }

  // MARK: Deleting threads

  /// Forgets the reviews of deleted threads and deletes their snapshot refs. Reviews still
  /// finishing are dropped as soon as their git work ends.
  func forget(threads: Set<String>) {
    guard !threads.isEmpty else { return }
    configure(nil)
    for thread in threads {
      oneShot.remove(thread)
      held.discard(thread: thread)
    }
    if let toast, threads.contains(toast.threadID) { self.toast = nil }
    let gone = reviews.filter { threads.contains($0.threadID) }
    for review in gone where review.inProgress { discarding.insert(review.id) }
    let done = gone.filter { !$0.inProgress }
    let ids = Set(done.map(\.id))
    reviews.removeAll { ids.contains($0.id) }
    for id in ids {
      notes[id] = nil
      answerNotes[id] = nil
    }
    save()
    dropRefs(done)
  }

  private func finishDiscarding(_ id: String) {
    guard discarding.contains(id), let review = reviews.first(where: { $0.id == id }),
      !review.inProgress
    else { return }
    discarding.remove(id)
    reviews.removeAll { $0.id == id }
    notes[id] = nil
    answerNotes[id] = nil
    if toast?.reviewID == id { toast = nil }
    save()
    dropRefs([review])
  }

  private func dropRefs(_ dropped: [TurnReview]) {
    let roots = dropped.compactMap { r in r.root.map { (r.id, $0) } }
    guard !roots.isEmpty else { return }
    for (id, root) in roots {
      enqueue(root) {
        await Task.detached(priority: .utility) {
          guard let git = GitTurns.locateGit() else { return }
          GitTurns(git: git, root: URL(fileURLWithPath: root)).drop(run: id)
        }.value
      }
    }
  }

  /// At launch: deletes snapshot refs of turns no longer listed (pruned past the newest 80, or
  /// from deleted threads) in every repository Serein still knows.
  private func pruneRefs() {
    let kept = Set(reviews.map { TurnPaths.refComponent($0.id) })
    for root in Set(reviews.compactMap(\.root)) {
      enqueue(root) {
        await Task.detached(priority: .utility) {
          guard let git = GitTurns.locateGit() else { return }
          let repo = GitTurns(git: git, root: URL(fileURLWithPath: root))
          for run in repo.keptRuns() where !kept.contains(run) { repo.drop(run: run) }
        }.value
      }
    }
  }

  // MARK: Storage

  private func showToast(_ toast: Toast) {
    self.toast = toast
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      if !Task.isCancelled, self?.toast == toast { self?.toast = nil }
    }
  }

  private func upsert(_ review: TurnReview) {
    if let i = reviews.firstIndex(where: { $0.id == review.id }) {
      reviews[i] = review
    } else {
      reviews.append(review)
    }
    prune()
    save()
  }

  private func prune() {
    guard reviews.count > Self.keep else { return }
    let dropped = reviews.prefix(reviews.count - Self.keep).filter { !$0.inProgress }
    let ids = Set(dropped.map(\.id))
    reviews.removeAll { ids.contains($0.id) }
    dropRefs(Array(dropped))
  }

  private func save() {
    try? library?.save(reviews, to: Self.path)
  }
}
