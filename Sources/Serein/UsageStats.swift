import AppKit
import Combine
import SereinCore
import UniformTypeIdentifiers

/// One local aggregate store, outside the library context supplied to agents.
@MainActor final class UsageStats: ObservableObject {
  static let shared = UsageStats()
  static let enabledKey = "serein.localUsageEnabled"
  @Published private(set) var ledger = LocalUsageLedger()
  @Published private(set) var status: String?
  @Published private(set) var isPreview = false
  private var library: Library?
  private weak var browser: BrowserModel?
  private var timer: Timer?
  private var watches: [AnyCancellable] = []
  private var clock = UsageActivityClock()
  private var downloadCounter = LocalDownloadCounter()
  private var lastActivity: Date?
  private var lastSave: TimeInterval = 0
  private var dirty = false
  private var blocked = false
  private var pauses: Set<String> = []
  private var enabled = true

  func start(browser: BrowserModel) {
    self.browser = browser
    if CommandLine.arguments.contains("--ui-preview") {
      isPreview = true
      seedPreview()
      return
    }
    // Synthetic check/stress runs do not collect usage or mutate real defaults.
    guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return }
    library = browser.library
    let folder = browser.library.root.appendingPathComponent("usage")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory
      else { throw SereinError.invalid("Usage folder must be a regular directory") }
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      let file = folder.appendingPathComponent("summary.json")
      if FileManager.default.fileExists(atPath: file.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular
        else { throw SereinError.invalid("Usage record must be a regular file") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 128_000, let saved = browser.library.load(LocalUsageLedger.self, from: "usage/summary.json"), saved.isValid
        else { blocked = true; status = "Stored usage could not be read. Reset usage to start a new record."; return }
        ledger = saved
      }
    } catch { blocked = true; status = "Local usage is unavailable: \(error.localizedDescription)"; return }
    UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    refreshEnabled()
    watches.append(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshEnabled() })
    downloadCounter = LocalDownloadCounter(alreadyComplete:
      Set(DownloadCenter.shared.items.filter { $0.state == .complete }.map(\.id)))
    watches.append(DownloadCenter.shared.$items.sink { [weak self] items in
      guard let self else { return }
      refreshEnabled()
      for item in items where item.state == .complete {
        guard downloadCounter.completed(id: item.id, isPrivate: item.isPrivate, enabled: enabled && !blocked) else { continue }
        ledger.recordDownload(bytes: max(item.received, item.total))
        dirty = true
      }
      if dirty { save() }
    })
    let workspace = NSWorkspace.shared.notificationCenter
    for (reason, pause, resume) in [
      ("system", NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
      ("display", NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
      ("session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification),
    ] {
      watches.append(workspace.publisher(for: pause).receive(on: RunLoop.main).sink { [weak self] _ in
        self?.pauses.insert(reason); self?.clock = UsageActivityClock(); self?.save()
      })
      watches.append(workspace.publisher(for: resume).receive(on: RunLoop.main).sink { [weak self] _ in
        self?.pauses.remove(reason); self?.clock = UsageActivityClock()
      })
    }
    timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sample() }
    }
  }

  private func refreshEnabled() {
    let value = UserDefaults.standard.bool(forKey: Self.enabledKey)
    if value != enabled {
      save()
      enabled = value
      clock = UsageActivityClock()
      lastActivity = nil
    }
  }

  private func sample() {
    refreshEnabled()
    guard enabled, !blocked else { return }
    let idle = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    let privateBrowsing = browser?.active?.privateMode == true
    let eligible = NSApp.isActive && NSApp.keyWindow != nil && pauses.isEmpty
      && !privateBrowsing && idle.isFinite && idle < 60
    let uptime = ProcessInfo.processInfo.systemUptime
    let seconds = clock.sample(at: uptime, eligible: eligible)
    if seconds > 0 {
      let now = Date()
      let newSession = lastActivity == nil || now.timeIntervalSince(lastActivity!) >= 1800
      ledger.recordActivity(seconds: seconds, endingAt: now, newSession: newSession)
      lastActivity = now
      dirty = true
    }
    if uptime - lastSave >= 60 { save() }
  }

  private func save() {
    guard dirty, !blocked, let library else { return }
    do {
      try library.save(ledger, to: "usage/summary.json")
      dirty = false
      lastSave = ProcessInfo.processInfo.systemUptime
      status = nil
    } catch { status = "Usage could not be saved: \(error.localizedDescription)" }
  }

  func reset() {
    ledger = LocalUsageLedger()
    blocked = false
    clock = UsageActivityClock()
    lastActivity = nil
    dirty = true
    if let library {
      do {
        let folder = library.root.appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: folder,
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw SereinError.invalid("Usage folder must be a regular directory") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      } catch { blocked = true; status = "Usage could not be reset: \(error.localizedDescription)"; return }
    }
    save()
    if status == nil, timer == nil, let browser { start(browser: browser) }
  }

  func finish() { save(); timer?.invalidate() }

  func export() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Serein-usage.json"
    panel.begin { [weak self] result in
      guard result == .OK, let url = panel.url else { return }
      Task { @MainActor in
        guard let self else { return }
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          encoder.dateEncodingStrategy = .iso8601
          try encoder.encode(self.ledger).write(to: url, options: .atomic)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
          self.status = "Exported daily usage totals."
        } catch { self.status = "Export failed: \(error.localizedDescription)" }
      }
    }
  }

  private func seedPreview() {
    let now = Date(), calendar = Calendar.autoupdatingCurrent
    ledger = LocalUsageLedger(startedAt: calendar.date(byAdding: .day, value: -65, to: now)!)
    for offset in 0..<60 {
      let date = calendar.date(byAdding: .day, value: -offset, to: now)!
      guard offset % 6 != 5 else { continue }
      let minutes = (offset < 7 ? 42 : 28) + (offset * 7 % 36)
      for index in 0..<(minutes * 6) {
        ledger.recordActivity(seconds: 10, endingAt: date.addingTimeInterval(Double(-index * 10)), newSession: index == 0)
      }
      for _ in 0..<(offset % 4) { ledger.recordDownload(bytes: 24_000_000, at: date) }
    }
  }
}
