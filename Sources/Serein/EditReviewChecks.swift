#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// A fake project turn (a shell script, no provider) edits two files in a temporary repository.
  /// The changes card must count them, Undo must restore the bytes, Redo must reapply them and a
  /// later user edit must block Undo.
  @MainActor static func editReview(browser: BrowserModel, agent: AgentModel) async throws
    -> [String]
  {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    guard let git = GitTurns.locateGit() else {
      return ["SKIP: git is not available for the edit review check"]
    }
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("serein-edit-check-" + UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    try GitTurns.initialize(folder: folder, git: git)
    let a = folder.appendingPathComponent("notes.txt")
    let b = folder.appendingPathComponent("src/new.swift")
    let original = Data("alpha\nbeta\ngamma\n".utf8)
    try original.write(to: a)

    let hub = agent.hub
    let store = EditReview.shared
    let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
    let threadID = "check-edits-" + UUID().uuidString
    let spec = RunSpec(
      threadID: threadID, provider: .claude, executable: "/bin/sh", model: "", effort: "low",
      mode: .project, projectID: nil, projectName: "Edit check", title: "Edit two files",
      scope: "", autoRouting: false,
      grants: RunGrants(edits: true, projectName: "Edit check"),
      limits: RunLimits(hard: 60, idle: 60))
    // Changes one line and adds one, then creates a two-line file.
    let script =
      "printf 'alpha\\nBETA\\ngamma\\ndelta\\n' > notes.txt && mkdir -p src && printf 'let a = 1\\nlet b = 2\\n' > src/new.swift"
    let run: AgentRun
    do {
      run = try hub.start(
        spec, task: task, arguments: ["-c", script], folder: folder, prompt: "",
        transcript: [AgentMessage(role: "you", text: "Edit two files")])
    } catch {
      browser.endTask(task.capability.task)
      throw error
    }
    for _ in 0..<1200 {
      if !run.isActive, let r = store.reviews.first(where: { $0.id == run.id }), !r.inProgress { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let review = store.reviews.first(where: { $0.id == run.id }) else {
      throw SereinError.invalid("FAIL: No review recorded for the fake turn")
    }
    try check(
      review.state == .ready && review.messageID == run.transcript.last?.id,
      "Edit turn is snapshotted before and after and anchored to its message")
    let byPath = Dictionary(uniqueKeysWithValues: review.files.map { ($0.path, $0) })
    try check(
      review.files.count == 2 && byPath["notes.txt"]?.added == 2 && byPath["notes.txt"]?.removed == 1
        && byPath["src/new.swift"]?.added == 2 && byPath["src/new.swift"]?.removed == 0,
      "Changes card counts 2 files, +2 −1 and +2 −0")
    try check(store.toast?.reviewID == run.id, "Undo toast offered after the turn")
    let patch = await store.patch(reviewID: run.id, path: "notes.txt")
    try check(patch?.text.contains("+BETA") == true, "Expanded diff shows the change")
    let edited = try Data(contentsOf: a)
    let added = try Data(contentsOf: b)

    func settle() async throws {
      for _ in 0..<1200 {
        if !store.busy.contains(run.id) { return }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
    }
    store.perform(.undo, reviewID: run.id, hub: hub)
    try await settle()
    try check(
      (try? Data(contentsOf: a)) == original && !fm.fileExists(atPath: b.path)
        && !fm.fileExists(atPath: b.deletingLastPathComponent().path)
        && store.reviews.first(where: { $0.id == run.id })?.undone == true,
      "Undo restores the exact bytes and removes the added file")
    store.perform(.undo, reviewID: run.id, hub: hub)
    try check(store.notes[run.id] == TurnUndo.alreadyUndone, "Undo twice is refused")
    store.perform(.redo, reviewID: run.id, hub: hub)
    try await settle()
    try check(
      (try? Data(contentsOf: a)) == edited && (try? Data(contentsOf: b)) == added
        && store.reviews.first(where: { $0.id == run.id })?.undone == false,
      "Redo reapplies the turn byte for byte")
    try Data("alpha\nmine\n".utf8).write(to: a)
    store.perform(.undo, reviewID: run.id, hub: hub)
    try await settle()
    try check(
      store.notes[run.id]?.contains("notes.txt changed after this turn") == true
        && (try? Data(contentsOf: a)) == Data("alpha\nmine\n".utf8) && fm.fileExists(atPath: b.path),
      "A later user edit blocks Undo and nothing is touched")
    try check(
      !fm.fileExists(atPath: folder.appendingPathComponent(".git/index").path)
        && !fm.fileExists(atPath: folder.appendingPathComponent(".git/refs/stash").path),
      "The user's index and stash are untouched")
    hub.dismiss(run)
    store.toast = nil
    results += try await editReviewHeld(browser: browser, agent: agent)
    results += try await editReviewHardening(browser: browser, agent: agent, git: git)
    return results
  }

  /// An answer given to an edit approval while its task is still working is held, then applied
  /// into that task's own thread when the step ends, while the user stays in another chat (fake
  /// turns and a fake Claude Code; no provider is called).
  @MainActor static func editReviewHeld(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    let label = "An early edit answer is held, then applied into its own thread when the step ends, while you are in another chat"
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("serein-held-check-" + UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let cli = folder.appendingPathComponent("claude")
    try "#!/bin/sh\nhead -n 1 > /dev/null\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
    chmod(cli.path, 0o755)
    let hub = agent.hub
    let store = EditReview.shared
    let threadID = "check-held-" + UUID().uuidString
    let saved = agent.available[.claude]
    agent.available[.claude] = cli.path
    agent.conversations.append(Conversation(
      id: threadID, title: "Held answer check", messages: [AgentMessage(role: "you", text: "Edit the notes")],
      provider: .claude, mode: .answer, projectID: nil, remoteID: nil, scope: "", updatedAt: Date()))
    var runs: [AgentRun] = []
    defer {
      agent.available[.claude] = saved
      for run in runs { hub.dismiss(run) }
      for run in hub.runs where run.spec.threadID == threadID && !run.isActive { hub.dismiss(run) }
      agent.conversations.removeAll { $0.id == threadID }
      store.forget(threads: [threadID])
    }
    func start(_ script: String, approvals: [PendingApproval] = []) throws -> AgentRun {
      let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
      let spec = RunSpec(
        threadID: threadID, provider: .claude, executable: "/bin/sh", model: "", effort: "low",
        mode: .answer, projectID: nil, projectName: "Held check", title: "Fake turn",
        scope: "", autoRouting: false, grants: RunGrants(), limits: RunLimits(hard: 60, idle: 60))
      do {
        let run = try hub.start(
          spec, task: task, arguments: ["-c", script], folder: folder, prompt: "",
          transcript: [AgentMessage(role: "you", text: "Edit the notes")])
        run.approvals = approvals
        runs.append(run)
        return run
      } catch {
        browser.endTask(task.capability.task)
        throw error
      }
    }
    func wait(_ seconds: Double, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    // A turn that ends asking to edit, then a second step that keeps the thread working.
    let asked = try start("exit 0", approvals: [PendingApproval(id: "held-1", tool: "Edit", target: "notes.txt")])
    try await wait(20) { !asked.isActive && store.reviews.contains { $0.id == asked.id } }
    let working = try start("sleep 1.5")
    let userThread = agent.conversationID
    let userDraft = agent.draft
    store.resolve(reviewID: asked.id, .allowedOnce, agent: agent)
    let heldWhileWorking = store.held.held(reviewID: asked.id)?.resolution == .allowedOnce
      && hub.latest(for: threadID) === working
    try await wait(30) {
      guard let latest = hub.latest(for: threadID), latest !== working, latest !== asked else { return false }
      return !latest.isActive
    }
    let applied = hub.latest(for: threadID)
    if let applied, !runs.contains(where: { $0 === applied }) { runs.append(applied) }
    let sentThere = applied.map { $0 !== working && $0 !== asked
      && $0.transcript.contains { $0.role == "you" && $0.text.contains(ApprovalReplies.allowOnce) } } ?? false
    let resolved = store.reviews.first { $0.id == asked.id }?.resolution == .allowedOnce
    if !(heldWhileWorking && sentThere && resolved && !store.held.isHolding(thread: threadID)
      && agent.conversationID == userThread && userThread != threadID && agent.draft == userDraft)
    {
      throw SereinError.invalid(
        "FAIL: \(label) [held: \(heldWhileWorking), sent there: \(sentThere), resolved: \(resolved), note: \(store.answerNotes[asked.id] ?? store.notes[asked.id] ?? "none")]")
    }
    return ["PASS: " + label]
  }

  /// Wave-3 review fixes, end to end with fake turns (shell scripts, no provider):
  /// a repository whose own config names a filter that would create a marker never runs it during
  /// snapshots or undo; a stopped turn's "after" snapshot waits for its process group and the next
  /// turn waits for that snapshot, so neither is refused and their files stay apart; deleting the
  /// thread drops the turns' refs.
  @MainActor static func editReviewHardening(browser: BrowserModel, agent: AgentModel, git: String)
    async throws -> [String]
  {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label) }
      results.append("PASS: " + label)
    }
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("serein-filter-check-" + UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    try GitTurns.initialize(folder: folder, git: git)
    let marker = fm.temporaryDirectory.appendingPathComponent("serein-filter-marker-" + UUID().uuidString)
    defer { try? fm.removeItem(at: marker) }
    let touch = "sh -c 'touch \(marker.path); cat'"
    let configURL = folder.appendingPathComponent(".git/config")
    let config = try String(contentsOf: configURL, encoding: .utf8)
      + "[filter \"evil\"]\n\tclean = \(touch)\n\tsmudge = \(touch)\n\trequired = true\n"
    try config.write(to: configURL, atomically: true, encoding: .utf8)
    try "* filter=evil\n".write(
      to: folder.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    let notes = folder.appendingPathComponent("notes.txt")
    try Data("alpha\n".utf8).write(to: notes)

    let hub = agent.hub
    let store = EditReview.shared
    let threadID = "check-hardening-" + UUID().uuidString
    func start(_ script: String) throws -> AgentRun {
      let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
      let spec = RunSpec(
        threadID: threadID, provider: .claude, executable: "/bin/sh", model: "", effort: "low",
        mode: .project, projectID: nil, projectName: "Filter check", title: "Fake turn",
        scope: "", autoRouting: false,
        grants: RunGrants(edits: true, projectName: "Filter check"),
        limits: RunLimits(hard: 60, idle: 60))
      do {
        return try hub.start(
          spec, task: task, arguments: ["-c", script], folder: folder, prompt: "",
          transcript: [AgentMessage(role: "you", text: "Fake turn")])
      } catch {
        browser.endTask(task.capability.task)
        throw error
      }
    }
    func settled(_ run: AgentRun) async throws -> TurnReview? {
      for _ in 0..<1200 {
        if !run.isActive, let r = store.reviews.first(where: { $0.id == run.id }), !r.inProgress {
          return r
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      return store.reviews.first { $0.id == run.id }
    }

    // 1. Filters never run.
    let first = try start("printf 'alpha\\nbeta\\n' > notes.txt")
    let review = try await settled(first)
    store.perform(.undo, reviewID: first.id, hub: hub)
    for _ in 0..<1200 where store.busy.contains(first.id) {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try check(
      review?.state == .ready && review?.files.map(\.path) == ["notes.txt"]
        && (try? Data(contentsOf: notes)) == Data("alpha\n".utf8)
        && !fm.fileExists(atPath: marker.path),
      "A repository's own clean and smudge filters never run during snapshots or undo")
    hub.dismiss(first)

    // 2. Stop, then send at once: the stopped turn's snapshot waits for its process group, and the
    // next turn waits for that snapshot.
    let stopped = try start(
      "trap 'sleep 0.4; echo late > late.txt; exit 0' TERM; echo > started.txt; sleep 30 & wait")
    // Stop only once the script has set its trap.
    let started = folder.appendingPathComponent("started.txt")
    for _ in 0..<1200 where !fm.fileExists(atPath: started.path) {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    hub.stop(stopped)
    let next = try start("echo b > b.txt")
    let stoppedReview = try await settled(stopped)
    let nextReview = try await settled(next)
    try check(
      stoppedReview?.state == .ready && stoppedReview?.files.map(\.path) == ["late.txt", "started.txt"]
        && nextReview?.state == .ready && nextReview?.files.map(\.path) == ["b.txt"]
        && stoppedReview?.overlapped != true,
      "A stopped turn's snapshot waits for its processes and the next turn waits for it"
        + (stoppedReview?.files.map(\.path) == ["late.txt", "started.txt"]
          ? "" : " (stopped: \(String(describing: stoppedReview?.state)) \(stoppedReview?.files.map(\.path) ?? []), next: \(String(describing: nextReview?.state)) \(nextReview?.files.map(\.path) ?? []))"))

    // 3. Deleting the thread drops its turns and their refs.
    store.forget(threads: [threadID])
    let refs = folder.appendingPathComponent(".git/refs/serein/turns")
    var gone = false
    for _ in 0..<600 {
      let left = (try? fm.contentsOfDirectory(atPath: refs.path)) ?? []
      if left.isEmpty { gone = true; break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try check(
      gone && !store.reviews.contains { $0.threadID == threadID } && !fm.fileExists(atPath: marker.path),
      "Deleting a thread drops its undo snapshots")
    hub.dismiss(stopped)
    hub.dismiss(next)
    store.toast = nil
    return results
  }
}
#endif
