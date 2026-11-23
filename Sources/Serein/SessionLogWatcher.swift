import CoreServices
import Foundation
import SereinCore

/// Watches every harness's session folder with FSEvents (no polling) and reports changed paths,
/// plus each file named in `follow(_:)` with a kqueue source: FSEvents reports a written file
/// when it is closed, and Codex keeps its rollout open for the whole session.
/// 0.5 s after the last change and never more than 2 s after the first, so a session that writes
/// steadily still refreshes about every 2 s. Its place in the FSEvents journal is saved, so a new
/// launch first receives what changed while Serein was closed: macOS keeps that journal, and no
/// Serein process runs meanwhile. `full` is true when the journal could not say which files
/// changed (a dropped history, a first launch), and the reader must look at everything.
/// The place is saved only when the reader calls `commit(_:key:)` after it applied a batch, so a
/// batch still waiting, or being read, when Serein quits arrives again on the next launch.
@MainActor final class SessionLogWatcher {
  struct Batch {
    var paths: Set<String>
    var full: Bool
    /// The journal's place after this batch (0: none, such as writes seen only by `follow`).
    var through: FSEventStreamEventId = 0
  }
  nonisolated static let delay: TimeInterval = 0.5
  static let maximumDelay: TimeInterval = 2
  /// Where the place in the journal is saved (checks use their own).
  let eventKey: String

  let roots: [String]
  private let onChange: (Batch) -> Void
  private var stream: FSEventStreamRef?
  private var pending = Batch(paths: [], full: false)
  private var pendingThrough: FSEventStreamEventId = 0
  private var firstPending: Date?
  private var flush: Task<Void, Never>?
  private var files: [String: DispatchSourceFileSystemObject] = [:]
  /// The stream is being made off the main thread (`start`).
  private var starting = false

  /// The session folders that exist on this Mac, from each harness's session store.
  nonisolated static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
    existing(HarnessDriver.allCases.compactMap { $0.sessionStore?.root.replacingOccurrences(of: "~", with: home) })
  }
  /// `folders` that exist, once each, in order.
  nonisolated static func existing(_ folders: [String]) -> [String] {
    Array(Set(folders)).filter { FileManager.default.fileExists(atPath: $0) }.sorted()
  }

  init(
    roots: [String] = SessionLogWatcher.defaultRoots(), eventKey: String = "serein.sessionLogEventID",
    onChange: @escaping (Batch) -> Void
  ) {
    self.roots = roots
    self.eventKey = eventKey
    self.onChange = onChange
  }

  func start() {
    guard stream == nil, !starting, !roots.isEmpty else { return }
    let saved = UserDefaults.standard.object(forKey: eventKey) as? NSNumber
    // No saved place: nothing to catch up on, but the reader looks at everything once, which
    // covers the journal up to now.
    if saved == nil {
      pendingThrough = FSEventsGetCurrentEventId()
      add([], full: true)
    }
    let since = saved.map { FSEventStreamEventId($0.uint64Value) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    let roots = self.roots
    let info = Opaque(Unmanaged.passUnretained(self).toOpaque())
    starting = true
    // FSEventStreamCreate opens each root, and a root on another volume (a session folder linked
    // to an external drive) waits there while macOS asks the person to allow it. Never on the
    // main thread, so the window opens while the question waits.
    Task.detached(priority: .utility) { [weak self] in
      let created = Self.makeStream(roots: roots, info: info, since: since)
      guard let self else { return created.release() }
      await self.adopt(created)
    }
  }

  /// A pointer handed between threads unchanged: the stream, or this watcher for its callback.
  private struct Opaque: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
    init(_ pointer: UnsafeMutableRawPointer?) { self.pointer = pointer }
  }
  private struct Created: @unchecked Sendable {
    let stream: FSEventStreamRef?
    /// A stream that was made but is no longer wanted.
    func release() {
      guard let stream else { return }
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }
  private nonisolated static func makeStream(roots: [String], info: Opaque, since: FSEventStreamEventId) -> Created {
    var context = FSEventStreamContext(version: 0, info: info.pointer, retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
      guard let info else { return }
      let watcher = Unmanaged<SessionLogWatcher>.fromOpaque(info).takeUnretainedValue()
      let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
      let lost =
        UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
          | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
          | kFSEventStreamEventFlagRootChanged)
      let full = (0..<count).contains { flags[$0] & lost != 0 }
      let last = count > 0 ? ids[count - 1] : 0
      MainActor.assumeIsolated { watcher.received(list, full: full, lastID: last) }
    }
    let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
    return Created(stream: FSEventStreamCreate(nil, callback, &context, roots as CFArray, since, delay / 5, UInt32(flags)))
  }
  /// The stream made off the main thread, unless the watcher was stopped meanwhile.
  private func adopt(_ created: Created) {
    guard starting else { return created.release() }
    starting = false
    guard let stream = created.stream else {
      add([], full: true)
      return
    }
    FSEventStreamSetDispatchQueue(stream, .main)
    if !FSEventStreamStart(stream) {
      created.release()
      add([], full: true)
      return
    }
    self.stream = stream
  }

  /// Reports every write to these files (the live sessions' logs) as it happens.
  func follow(_ paths: Set<String>) {
    for (path, source) in files where !paths.contains(path) {
      source.cancel()
      files[path] = nil
    }
    for path in paths where files[path] == nil {
      let fd = open(path, O_EVTONLY | O_CLOEXEC)
      guard fd >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
      source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.add([path], full: false) } }
      source.setCancelHandler { close(fd) }
      source.resume()
      files[path] = source
    }
  }

  func stop() {
    flush?.cancel()
    flush = nil
    starting = false
    follow([])
    guard let stream else { return }
    // The saved place stays at the last applied batch: what was waiting arrives on the next start.
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  private func received(_ paths: [String], full: Bool, lastID: FSEventStreamEventId) {
    pendingThrough = max(pendingThrough, lastID)
    add(paths, full: full)
  }

  /// Saves the journal's place after `batch`, once the reader has applied it. Batches are applied
  /// in order, so the place is saved as it is: after an FSEvents reset (a new Mac) it must go down.
  static func commit(_ batch: Batch, key: String) {
    guard batch.through != 0 else { return }
    UserDefaults.standard.set(NSNumber(value: batch.through), forKey: key)
  }

  private func add(_ paths: [String], full: Bool) {
    pending.paths.formUnion(paths)
    pending.full = pending.full || full
    let now = Date()
    let first = firstPending ?? now
    firstPending = first
    let wait = max(0, min(Self.delay, Self.maximumDelay - now.timeIntervalSince(first)))
    flush?.cancel()
    flush = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      var batch = self.pending
      batch.through = self.pendingThrough
      self.pending = Batch(paths: [], full: false)
      self.firstPending = nil
      self.flush = nil
      self.onChange(batch)
    }
  }
}
