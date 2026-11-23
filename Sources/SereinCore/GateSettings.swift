import Foundation

/// Where a policy reads and writes the person's settings: `GateSettings` for every switch and
/// consent that loosens a gate, UserDefaults for plain preferences. The policies take one, so
/// SereinChecks can hand them a scratch UserDefaults suite.
public protocol SettingsStore: AnyObject {
  func object(forKey key: String) -> Any?
  func set(_ value: Any?, forKey key: String)
  func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}

extension SettingsStore {
  public func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
  public func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
  public func string(forKey key: String) -> String? { object(forKey: key) as? String }
  public func stringArray(forKey key: String) -> [String]? { (object(forKey: key) as? [Any])?.compactMap { $0 as? String } }
  public func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
}

/// Every switch and consent that loosens a gate, in one 0600 file in Serein's Library,
/// `relay/gates.json`. UserDefaults goes through cfprefsd, which a harness's shell may reach
/// (`defaults write`); every harness profile denies the whole Library
/// (`AgentFileGuard.sereinPrivateRoots`), so only Serein writes this file. Plain preferences
/// (windows, the sidebar, appearance) stay in UserDefaults. A file that is there but cannot be
/// read gives no value at all, so each switch reads as its safest value, and nothing is written
/// over it until it reads again. Until `open` (SereinChecks, UI previews and checks) the values
/// live in memory only.
public final class GateSettings: SettingsStore, @unchecked Sendable {
  public static let shared = GateSettings()
  public static let path = "relay/gates.json"
  /// Posted after every change, for the views that show a switch and the caches that read one.
  public static let changed = Notification.Name("SereinGateSettingsChanged")
  /// Set in the file once `migrate` moved the old UserDefaults values; after that a value written
  /// to UserDefaults is never read.
  static let migratedKey = "serein.gates.migrated"

  private let lock = NSLock()
  private var file: URL?
  private var values: [String: Any] = [:]
  private var broken = false
  private var failed = false

  /// Reads the file in `root` (Serein's Library) and saves every change there from now on.
  public func open(root: URL) {
    let url = root.appendingPathComponent(Self.path)
    lock.lock()
    file = url
    values = [:]
    broken = false
    if FileManager.default.fileExists(atPath: url.path) {
      if let data = try? Data(contentsOf: url), let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        values = read
      } else {
        broken = true
      }
    }
    lock.unlock()
    NotificationCenter.default.post(name: Self.changed, object: self)
  }

  /// The file once `open` named it (for Show in Finder); nil while values live in memory only.
  public var fileURL: URL? {
    lock.lock(); defer { lock.unlock() }
    return file
  }

  /// The file is there but could not be read: every switch is at its safest value, and changes
  /// are not saved.
  public var unreadable: Bool {
    lock.lock(); defer { lock.unlock() }
    return broken
  }
  /// The last change could not be saved: it holds in memory until Serein quits. The next save
  /// that works writes it too, since the file is written whole.
  public var saveFailed: Bool {
    lock.lock(); defer { lock.unlock() }
    return failed
  }

  public func object(forKey key: String) -> Any? {
    lock.lock(); defer { lock.unlock() }
    return broken ? nil : values[key]
  }
  /// nil removes the value. False when it was not kept: the file cannot be read, the value is not
  /// one JSON can hold, or the change could not be saved (it then holds for this launch only).
  @discardableResult public func update(_ value: Any?, forKey key: String) -> Bool {
    // Every write of a standing-yes list passes here, so the cap holds whoever adds to it.
    let value: Any? = StandingYes.capped(value, forKey: key)
    if let value, !JSONSerialization.isValidJSONObject([key: value]) { return false }
    lock.lock()
    guard !broken else {
      lock.unlock()
      // A switch the person flipped redraws back to the value that holds.
      NotificationCenter.default.post(name: Self.changed, object: self)
      return false
    }
    var next = values
    next[key] = value
    values = next
    let saved = save(next)
    failed = !saved
    lock.unlock()
    NotificationCenter.default.post(name: Self.changed, object: self)
    return saved
  }
  public func set(_ value: Any?, forKey key: String) { update(value, forKey: key) }
  public func removeObject(forKey key: String) { update(nil, forKey: key) }

  /// Once per Library: the value of each of `keys` in `defaults` moves into the file and then
  /// leaves `defaults`; so do the string values of every default whose name starts with a
  /// prefix in `maps`, gathered as one map under its key (names made per site, for example).
  /// Nothing moves before `open`, while the file cannot be read, or when the file cannot be
  /// written (the next launch tries again).
  public func migrate(_ keys: [String], maps: [String: String] = [:], from defaults: UserDefaults) {
    lock.lock()
    guard file != nil, !broken, values[Self.migratedKey] == nil else {
      lock.unlock()
      return
    }
    var next = values
    for key in keys where next[key] == nil {
      if let value = defaults.object(forKey: key), JSONSerialization.isValidJSONObject([key: value]) { next[key] = value }
    }
    var gathered: [String] = []
    let all = maps.isEmpty ? [:] : defaults.dictionaryRepresentation()
    for (mapKey, prefix) in maps where next[mapKey] == nil {
      let found = all.filter { $0.key.hasPrefix(prefix) }.compactMapValues { $0 as? String }
      if !found.isEmpty { next[mapKey] = found }
      gathered += found.keys
    }
    next[Self.migratedKey] = 1
    let saved = save(next)
    if saved { values = next }
    lock.unlock()
    guard saved else { return }
    for key in keys + gathered { defaults.removeObject(forKey: key) }
    NotificationCenter.default.post(name: Self.changed, object: self)
  }

  /// Writes `next` whole, atomically, 0600 in a 0700 folder. Called with the lock held. True in
  /// memory-only mode.
  private func save(_ next: [String: Any]) -> Bool {
    guard let file else { return true }
    guard JSONSerialization.isValidJSONObject(next) else { return false }
    do {
      let folder = file.deletingLastPathComponent()
      let fm = FileManager.default
      try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let data = try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: file, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return true
    } catch {
      return false
    }
  }
}
