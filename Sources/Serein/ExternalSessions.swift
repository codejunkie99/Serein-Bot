import Combine
import SereinCore
import SwiftUI

@MainActor final class ExternalSessionStore: ObservableObject {
  static let shared = ExternalSessionStore()
  @Published private(set) var sessions: [ExternalSession] = []
  /// The helpers each running session started (its subagents), by the session's id.
  @Published private(set) var subagents: [String: [ExternalSubagent]] = [:]
  private static let key = "serein.externalSessions.enabled"
  @Published var enabled = UserDefaults.standard.object(forKey: key) as? Bool ?? true {
    didSet {
      guard enabled != oldValue else { return }
      UserDefaults.standard.set(enabled, forKey: Self.key)
      if enabled { start() } else { stop(); update([]); onStopped?() }
    }
  }
  var working: Int { sessions.filter { $0.state == .running }.count }
  var waiting: Int { sessions.filter { $0.state == .needsUser }.count }
  var open: Int { sessions.filter { $0.state == .open }.count }
  /// Every finished scan, changed or not (SessionStatusTexts). Real scans only: `update` from a
  /// check or a preview never reaches it.
  var onScan: (([ExternalSession]) -> Void)?
  /// The person turned watching off.
  var onStopped: (() -> Void)?

  /// No timer: the session folders' file events (SessionLogWatcher), each session process's exit,
  /// and Serein becoming active start a scan. A scan asked for during one runs once after it.
  private var watcher: SessionLogWatcher?
  private var exits: [Int32: DispatchSourceProcess] = [:]
  private var observers: [NSObjectProtocol] = []
  private var reader = ExternalSessionReader()
  private var helperReader = ExternalSubagentReader()
  private var scanning = false
  private var again = false

  func start() {
    guard enabled, watcher == nil, !RunMode.automated, !RunMode.stress else { return }
    // Past sessions have their own watcher (SessionHistoryStore).
    // Running sessions come from the process scan, so each batch is done once it is scanned.
    let watcher = SessionLogWatcher { [weak self] batch in
      self?.scan()
      SessionLogWatcher.commit(batch, key: "serein.sessionLogEventID")
    }
    self.watcher = watcher
    watcher.start()
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scan() }
      },
      center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.watcher?.stop() }
      },
    ]
    scan()
  }

  private func stop() {
    watcher?.stop()
    watcher = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    exits.values.forEach { $0.cancel() }
    exits = [:]
  }

  func scan() {
    guard enabled, watcher != nil else { return }
    if scanning {
      again = true
      return
    }
    scanning = true
    let registry = HarnessRegistry.shared
    let executables = Dictionary(uniqueKeysWithValues: registry.snapshots.compactMap { driver, snapshot in
      snapshot.path.map { (driver, $0) }
    })
    let current = reader
    let currentHelpers = helperReader
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        var reader = current
        var helperReader = currentHelpers
        let processes = HarnessProcessDiscovery.snapshot(executables: executables)
        let sessions = reader.snapshot(processes: processes, executables: executables)
        let helpers = helperReader.read(sessions)
        return (reader, sessions, helperReader, helpers)
      }.value
      guard let self else { return }
      scanning = false
      reader = result.0
      helperReader = result.2
      guard enabled, watcher != nil else { return }
      update(result.1)
      onScan?(result.1)
      if subagents != result.3 { subagents = result.3 }
      watchExits(result.1)
      watcher?.follow(Set(result.1.compactMap(\.log)))
      if again {
        again = false
        scan()
      }
    }
  }

  /// A session leaves the list the moment its process exits.
  private func watchExits(_ sessions: [ExternalSession]) {
    let live = Set(sessions.compactMap(\.pid))
    for (pid, source) in exits where !live.contains(pid) {
      source.cancel()
      exits[pid] = nil
    }
    for pid in live where exits[pid] == nil {
      let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
      source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
      source.resume()
      exits[pid] = source
    }
  }

  func update(_ current: [ExternalSession], subagents helpers: [String: [ExternalSubagent]]? = nil) {
    if sessions != current { sessions = current }
    if let helpers, subagents != helpers { subagents = helpers }
    if current.isEmpty, !subagents.isEmpty { subagents = [:] }
  }
}
