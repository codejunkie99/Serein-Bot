import Darwin
import Foundation
import SereinCore

/// Capture the physical target when a start is accepted, before any suspension. Executables
/// also bind to their modification/change timestamps so replacement or in-place edits cannot
/// reuse a launch plan built for the previous file. Projects bind to directory identity rather
/// than timestamps: ordinary project edits do not change the granted root.
struct AgentLaunchIdentity: Equatable {
  private let physicalPath: String
  private let device: dev_t
  private let inode: ino_t
  private let mode: mode_t
  private let size: Int64?
  private let modifiedSeconds: Int?
  private let modifiedNanos: Int?
  private let changedSeconds: Int?
  private let changedNanos: Int?

  private init(_ path: String, executable: Bool) throws {
    let physicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    var info = stat()
    guard lstat(physicalPath, &info) == 0,
      (info.st_mode & S_IFMT) == (executable ? S_IFREG : S_IFDIR),
      !executable || FileManager.default.isExecutableFile(atPath: path) else {
      throw SereinError.invalid(executable ? "The agent executable is unavailable." : "The project folder is unavailable.")
    }
    self.physicalPath = physicalPath
    device = info.st_dev; inode = info.st_ino; mode = info.st_mode
    size = executable ? info.st_size : nil
    modifiedSeconds = executable ? info.st_mtimespec.tv_sec : nil
    modifiedNanos = executable ? info.st_mtimespec.tv_nsec : nil
    changedSeconds = executable ? info.st_ctimespec.tv_sec : nil
    changedNanos = executable ? info.st_ctimespec.tv_nsec : nil
  }
  static func executable(_ path: String) throws -> Self { try Self(path, executable: true) }
  static func project(_ folder: URL) throws -> Self { try Self(folder.path, executable: false) }
  func validateExecutable(_ path: String) throws {
    guard self == (try Self.executable(path)) else {
      throw SereinError.invalid("The agent executable changed while this task was preparing. Send it again.")
    }
  }
  func validateProject(_ folder: URL) throws {
    guard self == (try Self.project(folder)) else {
      throw SereinError.invalid("The project changed before this task started.")
    }
  }
}

/// A pending start reserves its visible run immediately. Cancellation never waits for the
/// history lock: it closes the browser capability and only then reconciles any durable start.
final class AgentStartTicket: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  #if DEBUG
  private var checking = false
  func markChecking() { lock.lock(); checking = true; lock.unlock() }
  var isChecking: Bool { lock.lock(); defer { lock.unlock() }; return checking }
  #endif
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor final class BehaviorHistoryPreparation {
  var generation = UUID()
  var opening: Task<AgentHistoryStore, Error>?
  var pendingStarts = 0
  var tickets: [String: AgentStartTicket] = [:]
  var closed = false
}

enum AgentStartHistoryFailure: LocalizedError, Equatable {
  case integrity, recording
  var errorDescription: String? {
    switch self {
    case .integrity: return "The task was not started because agent history is unreadable."
    case .recording: return "The task was not started because agent history could not be saved."
    }
  }
}

/// Startup transactions are serialized off the UI actor. The original store methods retain
/// their full validation, locks and synchronization. No integrity result is cached.
enum AgentStartHistory {
  private static let queue = DispatchQueue(label: "local.serein.agent-history-start", qos: .userInitiated)

  final class Commit: @unchecked Sendable {
    let store: AgentHistoryStore
    let context: AgentHistoryRun
    private let acknowledged = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closed = false
    init(store: AgentHistoryStore, context: AgentHistoryRun) {
      self.store = store; self.context = context
    }
    func close() {
      lock.lock()
      guard !closed else { lock.unlock(); return }
      closed = true
      lock.unlock()
      acknowledged.signal()
    }
    fileprivate func waitForCommit() { acknowledged.wait() }
  }

  static func prepare(
    store: AgentHistoryStore, context: AgentHistoryRun, ticket: AgentStartTicket
  ) async throws -> Commit {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard !ticket.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        #if DEBUG
        ticket.markChecking()
        #endif
        do { try store.checkIntegrity() }
        catch { continuation.resume(throwing: AgentStartHistoryFailure.integrity); return }
        guard !ticket.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        do { try store.record(run: context, kind: .runStarted) }
        catch { continuation.resume(throwing: AgentStartHistoryFailure.recording); return }
        let commit = Commit(store: store, context: context)
        continuation.resume(returning: commit)
        // The next startup scan must not take the history lock before this run's main-actor
        // launch/reconciliation has finished. This dedicated queue never holds the store lock
        // while waiting. Stop can revoke immediately even when a UI commit is delayed.
        commit.waitForCommit()
      }
    }
  }
}

extension BrowserModel {
  /// Production launch opens/reconciles history in the background. Deterministic native
  /// fixtures retain their synchronous constructor; focused checks exercise this factory.
  func beginBehaviorHistoryPreparation() {
    guard !behaviorHistoryPreparation.closed, behaviorHistory == nil,
      behaviorHistoryPreparation.opening == nil else { return }
    let generation = behaviorHistoryPreparation.generation
    let library = library
    behaviorHistoryPreparing = true
    let opening = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let store = try AgentHistoryStore(library: library)
      try Task.checkCancellation()
      try store.recoverInterruptedRuns()
      try Task.checkCancellation()
      return store
    }
    behaviorHistoryPreparation.opening = opening
    Task { [weak self] in
      guard let self else { return }
      do { _ = try await readyBehaviorHistory(generation: generation) }
      catch {
        guard behaviorHistoryPreparation.generation == generation else {
          if behaviorHistoryPreparation.closed {
            behaviorHistoryPreparation.opening = nil
            behaviorHistoryPreparing = false
          }
          return
        }
        behaviorHistoryPreparation.opening = nil
        behaviorHistoryPreparing = false
        behaviorHistoryIssue = "Agent history is incomplete or unreadable. Its files have been preserved."
      }
    }
  }

  func readyBehaviorHistory(generation: UUID) async throws -> AgentHistoryStore {
    guard !behaviorHistoryPreparation.closed,
      behaviorHistoryPreparation.generation == generation else { throw CancellationError() }
    if let opening = behaviorHistoryPreparation.opening {
      let store = try await opening.value
      guard !behaviorHistoryPreparation.closed,
        behaviorHistoryPreparation.generation == generation else { throw CancellationError() }
      // Another waiter can have published the same store. Never replace a different writer.
      guard behaviorHistory == nil || behaviorHistory === store else { throw CancellationError() }
      behaviorHistory = store
      behaviorHistoryPreparation.opening = nil
      if behaviorHistoryPreparing { behaviorHistoryPreparing = false }
    }
    guard let store = behaviorHistory else {
      throw SereinError.invalid("Agent history is unavailable. Open Settings › AI apps to review or clear it.")
    }
    return store
  }
  func cancelBehaviorHistoryPreparation() {
    behaviorHistoryPreparation.closed = true
    behaviorHistoryPreparation.generation = UUID()
    for ticket in behaviorHistoryPreparation.tickets.values { ticket.cancel() }
    behaviorHistoryPreparation.opening?.cancel()
  }
}
