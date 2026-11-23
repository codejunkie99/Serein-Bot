import CoreServices
import Foundation
import SereinCore

/// Tells the registry, through FSEvents and with no polling, when a harness may list other models
/// or has an update: its CLI was updated (the link or the installed file changed), its model file
/// changed its model ids, its own update check recorded a newer release, or it signed in or out
/// (ModelSources has the files per harness). Only enabled harnesses are watched; a change
/// re-checks that harness alone, two seconds after the last event, so an install that writes many
/// files counts once.
@MainActor final class ModelSourceWatcher {
  static let shared = ModelSourceWatcher()
  enum Change { case cli, models, version, signIn }
  /// Called once per settled change.
  var onChange: ((HarnessDriver, Change) -> Void)?

  private struct Source {
    var driver: HarnessDriver
    var link: String
    var real: String
    var models: String?
    var latest: String?
    var signIn: String?
    /// Each watched file with the change it stands for, strongest first.
    var files: [(String, Change)] {
      [(link, .cli)] + [models.map { ($0, .models) }, latest.map { ($0, .version) }, signIn.map { ($0, .signIn) }]
        .compactMap { $0 }
    }
  }
  private var sources: [HarnessDriver: Source] = [:]
  /// Last fingerprint per file: link target, size and date for a CLI; the model ids for a model
  /// file; the version for a newest-release file.
  private var prints: [String: Int] = [:]
  private var folders: [String] = []
  private var stream: FSEventStreamRef?
  private var waits: [HarnessDriver: Task<Void, Never>] = [:]

  /// Watches a harness's CLI and files (nil executable: stop watching it). `environment` is the
  /// one its probes and runs get, so a CODEX_HOME set for Codex is the folder watched.
  func watch(_ driver: HarnessDriver, executable: String?, environment: [String: String] = [:]) {
    guard let executable else {
      sources[driver] = nil
      rearm()
      return
    }
    let home = NSHomeDirectory()
    let files = ModelSources.files(driver, environment: environment, home: home)
    let source = Source(
      driver: driver, link: Self.resolved(executable), real: SessionHistory.real(executable),
      models: files.models.map(Self.resolved), latest: files.latest.map(Self.resolved),
      signIn: ModelSources.signInFile(driver, environment: environment, home: home).map(Self.resolved))
    sources[driver] = source
    Task { await remember(source) }
    rearm()
  }

  private func remember(_ source: Source) async {
    for (file, kind) in source.files where prints[file] == nil {
      prints[file] = await Self.fingerprint(file, kind, source.driver)
    }
  }

  private func rearm() {
    let wanted = Set(sources.values.flatMap { s in
      [s.real] + s.files.map(\.0)
    }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }).filter {
      FileManager.default.fileExists(atPath: $0)
    }.sorted()
    guard wanted != folders else { return }
    folders = wanted
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    guard !wanted.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<ModelSourceWatcher>.fromOpaque(info).takeUnretainedValue()
      let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
      MainActor.assumeIsolated { watcher.events(changed) }
    }
    let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, wanted as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
        UInt32(flags))
    else { return }
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  /// Folders hold other files too (Codex writes its sessions next to its cache): only events on a
  /// watched file, or on a folder that holds the installed CLI, count. Changes seen together are
  /// settled together, so an install that also rewrites the model file counts once.
  private var seen: [HarnessDriver: Set<Change>] = [:]
  private func events(_ paths: [String]) {
    for (driver, source) in sources {
      var kinds = Set<Change>()
      if paths.contains(where: { $0 == source.link || $0 == source.real || source.real.hasPrefix($0 + "/") }) {
        kinds.insert(.cli)
      }
      if let file = source.models, paths.contains(file) { kinds.insert(.models) }
      if let file = source.latest, paths.contains(file) { kinds.insert(.version) }
      if let file = source.signIn, paths.contains(file) { kinds.insert(.signIn) }
      guard !kinds.isEmpty else { continue }
      seen[driver, default: []].formUnion(kinds)
      waits[driver]?.cancel()
      waits[driver] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.settle(source)
      }
    }
  }

  /// The strongest real change wins: a new CLI re-checks everything, new model ids list again,
  /// a newer release only re-checks the version, a sign-in or sign-out re-checks the app.
  private func settle(_ source: Source) async {
    let kinds = seen.removeValue(forKey: source.driver) ?? []
    waits[source.driver] = nil
    var changes: [Change] = []
    for (file, kind) in source.files {
      guard kinds.contains(kind) else { continue }
      if await changed(file, kind, source.driver) { changes.append(kind) }
    }
    if let first = changes.first { onChange?(source.driver, first) }
  }

  private func changed(_ file: String, _ kind: Change, _ driver: HarnessDriver) async -> Bool {
    let now = await Self.fingerprint(file, kind, driver)
    defer { prints[file] = now }
    return prints[file] != nil && prints[file] != now
  }

  /// FSEvents reports real paths: a file under a linked folder (a dotfiles ~/.codex, or /var →
  /// /private/var) is watched by its real folder, with its own name kept (a CLI link stays the
  /// link). The file itself may not exist yet.
  nonisolated static func resolved(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return SessionHistory.real(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
  }

  nonisolated static func fingerprint(_ file: String, _ kind: Change, _ driver: HarnessDriver) async -> Int {
    await Task.detached(priority: .utility) {
      // A sign-in file holds the app's credentials: only its size and date count, like a CLI's.
      if kind != .cli && kind != .signIn {
        guard let data = FileManager.default.contents(atPath: file) else { return 0 }
        if kind == .models { return ModelSources.ids(driver, data).hashValue }
        return ModelSources.latest(driver, data).hashValue
      }
      let real = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
      let attributes = try? FileManager.default.attributesOfItem(atPath: real)
      var hasher = Hasher()
      hasher.combine(real)
      hasher.combine((attributes?[.size] as? NSNumber)?.intValue)
      hasher.combine((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970)
      return hasher.finalize()
    }.value
  }
}
