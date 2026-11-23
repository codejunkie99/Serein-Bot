#if DEBUG
import Foundation
import SereinCore

@MainActor private final class AgentStartBarrier {
  var reached = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    reached = true
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() { let pending = waiting; waiting.removeAll(); pending.forEach { $0.resume() } }
}

@MainActor private final class AgentStartHeartbeat {
  private var task: Task<Void, Never>?
  private(set) var stamps: [UInt64] = []
  func start() {
    stamps = [DispatchTime.now().uptimeNanoseconds]
    task = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 2_000_000) } catch { return }
        self?.stamps.append(DispatchTime.now().uptimeNanoseconds)
      }
    }
  }
  func stop() { task?.cancel(); task = nil }
  var maximumGap: Double {
    zip(stamps, stamps.dropFirst()).map { Double($0.1 - $0.0) / 1_000_000 }.max() ?? 0
  }
}

/// Content-free generated histories, private fixtures and harmless shell processes only.
@MainActor func checkAgentStartPerformance() async throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("serein-start-performance-\(UUID().uuidString)")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  try Data("Synthetic startup fixtures only.\n".utf8).write(to: root.appendingPathComponent(".serein-start-performance"))
  defer { try? fm.removeItem(at: root) }
  var checks = 0
  func check(_ value: Bool, _ reason: String) throws {
    guard value else { throw SereinError.invalid("Agent startup check: " + reason) }
    checks += 1
  }
  func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    try check(predicate(), "asynchronous startup finished before the fixture deadline")
  }
  func ms(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
  let libraryRoot = root.appendingPathComponent("library")
  let original = try AgentHistoryStore(library: Library(root: libraryRoot))
  let fixtureRuns = (0..<100).map { _ in
    AgentHistoryRun(id: UUID(), threadID: UUID().uuidString, projectID: nil,
      harness: .codex, harnessVersion: "0.115.0", model: "synthetic", mode: .answer,
      permission: .supervised, grants: .init())
  }
  try await Task.detached {
    for index in 0..<10_000 {
      try original.record(run: fixtureRuns[index % fixtureRuns.count],
        kind: index >= 9_900 ? .runEnded : .toolReported, source: .harness,
        tool: index >= 9_900 ? nil : .other, outcome: index >= 9_900 ? .done : nil)
    }
  }.value
  let baselineProbe = AgentStartHeartbeat()
  baselineProbe.start()
  try await Task.sleep(nanoseconds: 6_000_000)
  let baseline = try ms { try original.checkIntegrity() }
  try await Task.sleep(nanoseconds: 6_000_000)
  baselineProbe.stop()
  let baselineGap = baselineProbe.maximumGap

  // Exercise the production asynchronous constructor and interruption recovery explicitly;
  // the general verification harness otherwise deliberately keeps synchronous fixture setup.
  let unfinished = AgentHistoryRun(id: UUID(), threadID: UUID().uuidString, projectID: nil,
    harness: .codex, harnessVersion: nil, model: "", mode: .answer,
    permission: .supervised, grants: .init())
  try original.record(run: unfinished, kind: .runStarted)
  let openingProbe = AgentStartHeartbeat()
  openingProbe.start()
  var openedBrowser: BrowserModel!
  let constructorCall = try ms { openedBrowser = try BrowserModel(root: libraryRoot, prepareHistoryAsynchronously: true) }
  let browser = openedBrowser!
  defer { browser.shutdown() }
  do { try browser.clearBehaviorHistory(); throw SereinError.invalid("Opening history was cleared") }
  catch { try check(browser.behaviorHistoryPreparing && error.localizedDescription.contains("preparation"),
    "Clear cannot erase an opening/recovering history") }
  let readinessHub = AgentHub()
  readinessHub.browser = browser
  defer { readinessHub.beforePreparedLaunch = nil; readinessHub.stopAll() }
  let readinessGate = AgentStartBarrier()
  readinessHub.beforePreparedLaunch = { await readinessGate.wait() }
  let readinessTask = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
  let readinessMarker = root.appendingPathComponent("provider-before-readiness")
  let readinessSpec = RunSpec(threadID: UUID().uuidString, provider: .codex, executable: "/bin/sh",
    model: "", effort: "low", mode: .research, projectID: nil, projectName: nil,
    title: "Synthetic before history readiness", scope: "synthetic", autoRouting: false,
    grants: RunGrants(), limits: .init(hard: 60, idle: 60))
  let readinessRun = try readinessHub.startPreparing(readinessSpec, task: readinessTask,
    folder: browser.library.root, prompt: "", transcript: [], revalidate: { _ in })
  readinessRun.harnessTurn = CheckProcessTurn(run: readinessRun, hub: readinessHub,
    arguments: ["-c", "printf started > \"$1\"; sleep 60", "serein-start-check", readinessMarker.path],
    folder: browser.library.root)
  readinessRun.setGrant(.act, true, browser: browser, agent: nil)
  readinessRun.setGrant(.mac, true, browser: browser, agent: nil)
  try check(readinessRun.pendingHistoryGrants.count == 2 && browser.behaviorHistoryPreparing,
    "Grant changes made before history readiness remain buffered on the pending run")
  let store = try await browser.readyBehaviorHistory(generation: browser.behaviorHistoryPreparation.generation)
  try await Task.sleep(nanoseconds: 6_000_000)
  openingProbe.stop()
  let recovered = try await Task.detached { try store.archive(runID: unfinished.id).events }.value
  try check(recovered.filter { $0.kind == .interrupted }.count == 1,
    "Async recovery records one interrupted observation before the writer is published")
  try check(openingProbe.stamps.count > 10 && openingProbe.maximumGap < max(40, baselineGap * 0.6),
    "Opening/recovery leaves the main actor responsive")

  try await until { readinessGate.reached }
  readinessGate.release()
  try await until { fm.fileExists(atPath: readinessMarker.path) }
  let readinessEvents = try await Task.detached { try store.archive(runID: UUID(uuidString: readinessRun.id)!).events }.value
  try check(readinessEvents.first?.kind == .runStarted && readinessEvents.filter { $0.kind == .grantChanged }.count == 2
    && browser.tasks[readinessRun.taskID]?.allowActions == true && browser.tasks[readinessRun.taskID]?.allowMac == true,
    "Grants from before readiness reconcile durably after runStarted and before provider launch")
  readinessHub.stop(readinessRun)
  try await until { readinessRun.startupTask == nil }

  let hub = AgentHub()
  hub.browser = browser
  var mirroredPhases: [String] = []
  hub.onTranscript = { mirroredPhases.append($0.phase) }
  defer { hub.beforePreparedLaunch = nil; hub.stopAll() }
  func launch(_ label: String, thread: String = UUID().uuidString,
              on owner: AgentHub? = nil, projectFolder: URL? = nil,
              authorize: @escaping (AgentRun) throws -> Void = { _ in }) throws -> (AgentRun, BrowserTask, URL) {
    let owner = owner ?? hub
    let task = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false)
    let marker = root.appendingPathComponent("provider-" + label)
    var grants = RunGrants()
    grants.edits = projectFolder != nil
    let spec = RunSpec(threadID: thread, provider: .codex, executable: "/bin/sh", model: "",
      effort: "low", mode: projectFolder == nil ? .research : .project,
      projectID: projectFolder == nil ? nil : UUID().uuidString, projectName: projectFolder?.lastPathComponent,
      title: "Synthetic " + label,
      scope: "synthetic-fixed-session", autoRouting: false, grants: grants, limits: .init(hard: 60, idle: 60))
    do {
      let folder = projectFolder ?? browser.library.root
      let run = try owner.startPreparing(spec, task: task,
        folder: folder, prompt: "", transcript: [], revalidate: authorize)
      // The CLI starts once history is ready, after this returns.
      run.harnessTurn = CheckProcessTurn(run: run, hub: owner,
        arguments: ["-c", "printf started > \"$1\"; sleep 60", "serein-start-check", marker.path], folder: folder)
      return (run, task, marker)
    } catch { browser.endTask(task.capability.task); throw error }
  }
  func events(_ run: AgentRun) async throws -> [AgentHistoryEvent] {
    try await Task.detached { try store.archive(runID: UUID(uuidString: run.id)!).events }.value
  }
  func settled(_ run: AgentRun) async throws { try await until { run.startupTask == nil } }

  let barrier = AgentStartBarrier()
  hub.beforePreparedLaunch = { await barrier.wait() }
  let currentProbe = AgentStartHeartbeat()
  currentProbe.start()
  var mainCall = 0.0
  var accepted: (AgentRun, BrowserTask, URL)!
  mainCall = try ms { accepted = try launch("grants") }
  let (a, taskA, markerA) = accepted!
  try await until { barrier.reached }
  currentProbe.stop()
  try check(!fm.fileExists(atPath: markerA.path) && a.isActive && hub.active.count == 1,
    "Preflight reserves a visible running slot without starting the provider")
  do {
    _ = try await browser.handle(["task": taskA.capability.task, "token": taskA.capability.token,
      "name": "list_tabs", "arguments": [:]])
    throw SereinError.invalid("Pending capability executed a browser call")
  } catch { try check(error.localizedDescription.contains("expired"), "A pending token cannot bypass the history gate") }
  let beforeLaunch = try await events(a)
  try check(beforeLaunch.first?.kind == .runStarted, "Run start is synchronized before provider launch")
  do { _ = try launch("duplicate", thread: a.spec.threadID); throw SereinError.invalid("Duplicate start accepted") }
  catch { try check(error.localizedDescription.contains("already running"), "Duplicate sends cannot reserve the same thread twice") }
  let previousEdits = GateSettings.shared.object(forKey: AgentModel.AccessToggle.edits.rawValue)
  defer {
    GateSettings.shared.set(previousEdits, forKey: AgentModel.AccessToggle.edits.rawValue)
    WebTaskGrant.shared.revoke(thread: a.spec.threadID)
  }
  a.setGrant(.act, true, browser: browser, agent: nil)
  a.setGrant(.mac, true, browser: browser, agent: nil)
  a.setGrant(.edits, true, browser: browser, agent: nil)
  a.setGrant(.signIns, true, browser: browser, agent: nil)
  barrier.release()
  try await until { fm.fileExists(atPath: markerA.path) }
  let grantEvents = try await events(a)
  try check(grantEvents.filter { $0.kind == .grantChanged }.count == 4,
    "Every pending grant toggle is durable before the provider can launch")
  try check(mirroredPhases.contains("Starting Codex"), "The selected-thread mirror receives asynchronous provider startup phases")
  try check(grantEvents.first?.run.grants.edits == false && grantEvents.first?.run.grants.signIns == false
    && grantEvents.contains { $0.grant == .edits && $0.effect == .nextTurn }
    && grantEvents.contains { $0.grant == .signIns && $0.effect == .nextTurn }
    && browser.tasks[a.taskID]?.allowActions == true && browser.tasks[a.taskID]?.allowMac == true,
    "Fixed process grants and immediate browser grants remain distinct")
  try check(currentProbe.stamps.count > 10 && currentProbe.maximumGap < max(40, baselineGap * 0.6),
    "The full startup scan no longer occupies the main actor in an uncontended fixture")

  // Preserve and measure the original lock semantics under another run's synchronous write.
  hub.beforePreparedLaunch = nil
  let (concurrent, _, concurrentMarker) = try launch("concurrent")
  try await until { concurrent.startTicket?.isChecking == true }
  try await Task.sleep(nanoseconds: 10_000_000)
  let contention = ms { _ = browser.recordBehavior(a.behaviorContext!, .toolReported, source: .harness, tool: .other) }
  try await until { fm.fileExists(atPath: concurrentMarker.path) }
  hub.stop(concurrent)
  try await settled(concurrent); try await settled(a)

  let (stopScanner, _, stopScanMarker) = try launch("bound-stop-scanner")
  try await until { stopScanner.startTicket?.isChecking == true }
  try await Task.sleep(nanoseconds: 10_000_000)
  let stoppedFile = taskA.file
  let stopStarted = DispatchTime.now().uptimeNanoseconds
  let unlinkObserver = Task.detached { () -> UInt64? in
    let deadline = Date().addingTimeInterval(5)
    while FileManager.default.fileExists(atPath: stoppedFile.path), Date() < deadline {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return FileManager.default.fileExists(atPath: stoppedFile.path) ? nil : DispatchTime.now().uptimeNanoseconds
  }
  let stopContention = ms { hub.stop(a) }
  let revokedAt = await unlinkObserver.value
  let revocationDelay = revokedAt.map { Double($0 - stopStarted) / 1_000_000 } ?? .infinity
  try check(browser.tasks[a.taskID] == nil && !fm.fileExists(atPath: taskA.file.path)
    && revocationDelay < max(40, stopContention * 0.6),
    "A bound Stop unlinks its capability before waiting for another startup scan's audit lock")
  try await until { fm.fileExists(atPath: stopScanMarker.path) }
  hub.stop(stopScanner)
  try await settled(stopScanner)

  let capacityGate = AgentStartBarrier()
  hub.beforePreparedLaunch = { await capacityGate.wait() }
  let reservations = try (0..<3).map { try launch("capacity-\($0)") }
  try await until { capacityGate.reached }
  try check(hub.active.count == AgentHub.maxConcurrent, "Pending starts count toward the three-run capacity")
  do { _ = try launch("capacity-overflow"); throw SereinError.invalid("Capacity overflow accepted") }
  catch { try check(error.localizedDescription.contains("3 tasks"), "The fourth pending start is refused") }
  for (run, _, _) in reservations { hub.stop(run) }
  try check(reservations.allSatisfy { browser.tasks[$0.0.taskID] == nil }, "Stop revokes all pending capabilities immediately")
  do { try browser.clearBehaviorHistory(); throw SereinError.invalid("In-flight reconciliation was cleared") }
  catch { try check(error.localizedDescription.contains("preparation"), "Clear waits for durable startup reconciliation after Stop") }
  capacityGate.release()
  for (run, _, marker) in reservations {
    try await settled(run)
    try check(!fm.fileExists(atPath: marker.path) && run.record.outcome == .stopped,
      "Stopped preflight cannot later launch a provider")
    let recorded = try await events(run)
    if recorded.contains(where: { $0.kind == .runStarted }) {
      try check(recorded.map(\.kind).suffix(2) == [.capabilityRevoked, .runEnded],
        "A start written before Stop is followed by revocation and the stopped outcome")
    }
  }

  // An authorization suspension cannot reuse a revoked token or a stale launch policy.
  for label in ["revoked", "token-changed", "policy-changed", "generation-changed"] {
    let gate = AgentStartBarrier()
    hub.beforePreparedLaunch = { await gate.wait() }
    var allowed = true
    let (run, task, marker) = try launch(label) { _ in
      if !allowed { throw SereinError.invalid("Synthetic launch policy revoked") }
    }
    try await until { gate.reached }
    switch label {
    case "revoked": browser.endTask(run.taskID)
    case "token-changed":
      var changed = task.capability; changed.token = UUID().uuidString
      try changed.write(to: task.file)
    case "policy-changed": allowed = false
    default: browser.behaviorHistoryPreparation.generation = UUID()
    }
    gate.release()
    try await settled(run)
    try check(!fm.fileExists(atPath: marker.path) && run.record.outcome == .stuck,
      "Live revalidation refuses \(label) after the await")
  }

  // The same production acceptance identities reject same-path replacement, in-place edits,
  // and symlink retargeting. Tests use only new executable scripts and empty directories.
  for label in ["executable-replaced", "executable-edited", "executable-symlink", "project-symlink", "project-replaced"] {
    let fixture = root.appendingPathComponent(label)
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    let executable = fixture.appendingPathComponent("agent")
    let alternate = fixture.appendingPathComponent("alternate")
    let project = fixture.appendingPathComponent("project")
    let alternateProject = fixture.appendingPathComponent("alternate-project")
    for file in [executable, alternate] {
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    for folder in [project, alternateProject] { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
    let executableLink = fixture.appendingPathComponent("agent-link")
    let projectLink = fixture.appendingPathComponent("project-link")
    try fm.createSymbolicLink(at: executableLink, withDestinationURL: executable)
    try fm.createSymbolicLink(at: projectLink, withDestinationURL: project)
    let acceptedExecutable = try AgentLaunchIdentity.executable(executableLink.path)
    let acceptedProject = try AgentLaunchIdentity.project(projectLink)
    let gate = AgentStartBarrier()
    hub.beforePreparedLaunch = { await gate.wait() }
    let (run, _, marker) = try launch(label) { _ in
      try acceptedExecutable.validateExecutable(executableLink.path)
      try acceptedProject.validateProject(projectLink)
    }
    try await until { gate.reached }
    switch label {
    case "executable-replaced":
      try fm.removeItem(at: executable); try fm.copyItem(at: alternate, to: executable)
    case "executable-edited": try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
    case "executable-symlink":
      try fm.removeItem(at: executableLink); try fm.createSymbolicLink(at: executableLink, withDestinationURL: alternate)
    case "project-symlink":
      try fm.removeItem(at: projectLink); try fm.createSymbolicLink(at: projectLink, withDestinationURL: alternateProject)
    default: try fm.removeItem(at: project); try fm.createDirectory(at: project, withIntermediateDirectories: false)
    }
    gate.release()
    try await settled(run)
    try check(!fm.fileExists(atPath: marker.path) && run.record.outcome == .stuck,
      "The accepted physical launch identity refuses \(label)")
  }

  let importGate = AgentStartBarrier()
  hub.beforePreparedLaunch = { await importGate.wait() }
  let fixedThread = UUID().uuidString
  var selectedThread = fixedThread
  let (importedRun, _, importMarker) = try launch("import-and-thread", thread: fixedThread)
  try await until { importGate.reached }
  let archive = try AgentHistoryArchive(issuerID: UUID(), events: [])
  _ = try await Task.detached { try store.importArchive(archive.encoded()) }.value
  selectedThread = UUID().uuidString
  importGate.release()
  try await until { fm.fileExists(atPath: importMarker.path) }
  try check(importedRun.initialSpec.threadID == fixedThread && importedRun.spec.scope == "synthetic-fixed-session"
    && selectedThread != fixedThread && store.issuerID == original.issuerID,
    "A selected-thread change or isolated import never changes the accepted run/session identity")
  hub.stop(importedRun); try await settled(importedRun)

  hub.beforePreparedLaunch = nil
  var transient: AgentHub? = AgentHub()
  transient?.browser = browser
  weak var releasedHub = transient
  let (orphan, _, orphanMarker) = try launch("released-owner", on: transient!)
  let attachment = try TurnAttachments.makeFolder(root: ComposerContext.attachmentRoot)
  let orphanLibrary = root.appendingPathComponent("orphan-library-context")
  let orphanRuntime = root.appendingPathComponent("orphan-runtime")
  for folder in [orphanLibrary, orphanRuntime] { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
  orphan.attachments = attachment; orphan.libraryContext = orphanLibrary; orphan.runtimeDirectory = orphanRuntime
  defer { TurnAttachments.remove(attachment, root: ComposerContext.attachmentRoot) }
  transient = nil
  try await settled(orphan)
  try check(releasedHub == nil && !fm.fileExists(atPath: orphanMarker.path) && browser.tasks[orphan.taskID] == nil,
    "A released owner reconciles its commit and cannot deadlock the global startup queue")
  try check(!fm.fileExists(atPath: attachment.path) && !fm.fileExists(atPath: orphanLibrary.path)
    && !fm.fileExists(atPath: orphanRuntime.path) && orphan.record.outcome == .stopped,
    "A released owner ends its metadata and releases every private startup resource")

  // Drop the owner after EditReview schedules its off-main project probe. The callback must
  // close a bound run even though its startup task has already released the queue transaction.
  let snapshotFolder = root.appendingPathComponent("snapshot-owner-project")
  try fm.createDirectory(at: snapshotFolder, withIntermediateDirectories: false)
  var snapshotOwner: AgentHub? = AgentHub()
  snapshotOwner?.browser = browser
  var snapshotPhases: [String] = []
  snapshotOwner?.onTranscript = { snapshotPhases.append($0.phase) }
  weak var releasedSnapshotOwner = snapshotOwner
  snapshotOwner?.afterPreparedSnapshotScheduled = { snapshotOwner = nil }
  let (snapshotOrphan, _, snapshotMarker) = try launch("released-snapshot-owner", on: snapshotOwner!, projectFolder: snapshotFolder)
  let snapshotRuntime = root.appendingPathComponent("snapshot-owner-runtime")
  try fm.createDirectory(at: snapshotRuntime, withIntermediateDirectories: false)
  snapshotOrphan.runtimeDirectory = snapshotRuntime
  try await until { !snapshotOrphan.isActive }
  try await settled(snapshotOrphan)
  let snapshotEvents = try await events(snapshotOrphan)
  let fixtureLibrary = browser.library
  let terminalRuns = await Task.detached { fixtureLibrary.runs() }.value
  try check(releasedSnapshotOwner == nil && !fm.fileExists(atPath: snapshotMarker.path)
    && browser.tasks[snapshotOrphan.taskID] == nil && !fm.fileExists(atPath: snapshotRuntime.path),
    "A released snapshot owner revokes its bound capability and releases resources")
  try check(snapshotEvents.map(\.kind).suffix(2) == [.capabilityRevoked, .runEnded]
    && terminalRuns.first(where: { $0.id == snapshotOrphan.id })?.outcome == .stopped
    && snapshotPhases.contains(where: { $0.hasPrefix("Saving a snapshot") }),
    "A snapshot orphan persists both its ledger end and terminal run-log metadata")

  let log = browser.library.root.appendingPathComponent("agent-history/events.jsonl")
  let valid = try Data(contentsOf: log)
  let handle = try FileHandle(forWritingTo: log)
  try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"torn\":".utf8)); try handle.close()
  let (torn, _, tornMarker) = try launch("torn-history")
  try await settled(torn)
  try check(!fm.fileExists(atPath: tornMarker.path) && torn.record.outcome == .stuck,
    "Every start performs full validation; a torn history cannot start a provider")
  try valid.write(to: log)
  browser.behaviorHistoryIssue = nil
  try await Task.detached { try store.checkIntegrity() }.value

  let quitGate = AgentStartBarrier()
  hub.beforePreparedLaunch = { await quitGate.wait() }
  let (quit, _, quitMarker) = try launch("quit")
  try await until { quitGate.reached }
  hub.stopAllForQuit()
  browser.shutdown()
  quitGate.release()
  try await settled(quit)
  try check(browser.behaviorHistoryPreparation.closed && !fm.fileExists(atPath: quitMarker.path)
    && browser.tasks.isEmpty && browser.behaviorHistoryPreparation.pendingStarts == 0,
    "Quit closes pending starts, revokes first and finishes transaction cleanup")

  let closing = try BrowserModel(root: root.appendingPathComponent("closing-library"), prepareHistoryAsynchronously: true)
  let opening = closing.behaviorHistoryPreparation.opening
  closing.shutdown()
  _ = try? await opening?.value
  try await until { closing.behaviorHistoryPreparation.opening == nil }
  try check(closing.behaviorHistory == nil && closing.behaviorHistoryPreparation.closed,
    "A shutdown factory cannot publish its recovered writer into a closed browser")
  print(String(format: "BENCH: synthetic 10k history; original main-actor integrity %.2f ms / heartbeat max gap %.2f ms; pending-start call %.3f ms / heartbeat max gap %.2f ms; async production constructor %.2f ms / open-recovery heartbeat max gap %.2f ms; concurrent synchronous ledger write %.2f ms; bound Stop %.2f ms, capability unlink %.2f ms (original lock retained)",
    baseline, baselineGap, mainCall, currentProbe.maximumGap, constructorCall, openingProbe.maximumGap, contention, stopContention, revocationDelay))
  print("PASS: \(checks) synthetic startup readiness, durability, grant, cancellation, capacity, identity and shutdown checks")
}
#endif
