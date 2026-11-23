import Foundation

/// Which language Apple Speech listens for. Pure so the choice can be checked without a microphone.
public enum TalkLanguage {
  public static let defaultsKey = "serein.talk.language"
  /// Follow the language of the keyboard input source when Apple Speech supports it on this Mac.
  public static let automatic = "auto"
  /// Use the system language (the default).
  public static let system = "system"

  /// `en_US` and `en-US` name the same locale.
  public static func canonical(_ id: String) -> String {
    id.replacingOccurrences(of: "_", with: "-")
  }
  private static func language(of id: String) -> String {
    canonical(id).split(separator: "-").first.map { $0.lowercased() } ?? ""
  }

  /// The supported identifier that best matches `candidate`: the same locale, else the same
  /// language (preferring the same script/region prefix, then the shortest identifier).
  public static func match(_ candidate: String, in supported: [String]) -> String? {
    let wanted = canonical(candidate).lowercased()
    guard !wanted.isEmpty else { return nil }
    if let exact = supported.first(where: { canonical($0).lowercased() == wanted }) { return exact }
    let code = language(of: candidate)
    let sameLanguage = supported.filter { language(of: $0) == code }.sorted {
      let a = canonical($0).lowercased(), b = canonical($1).lowercased()
      let ap = wanted.hasPrefix(a) || a.hasPrefix(wanted), bp = wanted.hasPrefix(b) || b.hasPrefix(wanted)
      if ap != bp { return ap }
      if a.count != b.count { return a.count < b.count }
      return a < b
    }
    return sameLanguage.first
  }

  /// The locale to recognize in, or nil when nothing on this Mac supports any wanted language.
  /// - preference: a locale identifier, `automatic` or `system` (anything else counts as `system`).
  /// - supported: locales Apple Speech can recognize on this Mac without the network.
  /// - system: the user's preferred languages in order.
  /// - keyboard: languages of the current keyboard input source.
  public static func resolve(
    preference: String, supported: [String], system: [String], keyboard: [String]
  ) -> String? {
    guard !supported.isEmpty else { return nil }
    if preference == automatic {
      for language in keyboard { if let hit = match(language, in: supported) { return hit } }
    } else if preference != Self.system, !preference.isEmpty,
      let hit = match(preference, in: supported)
    {
      return hit
    }
    for language in system { if let hit = match(language, in: supported) { return hit } }
    return nil
  }

  /// Picker choices: the system language, Automatic, then every supported locale by name.
  public struct Choice: Equatable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
      self.id = id
      self.title = title
    }
  }
  public static func choices(supported: [(id: String, name: String)]) -> [Choice] {
    var seen = Set<String>()
    let locales = supported.compactMap { item -> Choice? in
      let id = canonical(item.id)
      return seen.insert(id.lowercased()).inserted ? Choice(id: id, title: item.name) : nil
    }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    return [
      Choice(id: system, title: "System language"),
      Choice(id: automatic, title: "Automatic (follows the keyboard)"),
    ] + locales
  }
}

// MARK: Recording history

public struct TalkRecording: Codable, Equatable, Identifiable {
  /// The file stem; the audio is `<id>.caf` beside the index.
  public var id: String
  public var date: Date
  public var duration: TimeInterval
  public var text: String
  public init(id: String, date: Date, duration: TimeInterval, text: String) {
    self.id = id
    self.date = date
    self.duration = duration
    self.text = text
  }
}

/// The kept recordings and what was recognized in them, stored as `index.json` beside the audio.
public struct TalkRecordingStore {
  public static let retentionDays = 30
  public var directory: URL
  public init(directory: URL) { self.directory = directory }
  private var indexURL: URL { directory.appendingPathComponent("index.json") }
  public func audioURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".caf") }

  private func loadIndex() -> [TalkRecording] {
    guard let data = try? Data(contentsOf: indexURL) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([TalkRecording].self, from: data)) ?? []
  }
  private func saveIndex(_ entries: [TalkRecording]) {
    prepareDirectory()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(entries) {
      try? data.write(to: indexURL, options: .atomic)
      Self.protect(indexURL)
    }
  }
  /// Creates the folder readable only by the user (0700), tightening one that already exists.
  public func prepareDirectory() {
    let manager = FileManager.default
    try? manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
  /// Makes a recording or the index readable only by the user (0600).
  public static func protect(_ file: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// Newest first. Entries whose audio is gone are dropped; audio saved before the index existed is
  /// listed with its file date and no text.
  public func entries() -> [TalkRecording] {
    let manager = FileManager.default
    var byID = [String: TalkRecording]()
    for entry in loadIndex() where manager.fileExists(atPath: audioURL(entry.id).path) {
      byID[entry.id] = entry
    }
    let files =
      (try? manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for url in files where url.pathExtension == "caf" {
      let id = url.deletingPathExtension().lastPathComponent
      guard byID[id] == nil else { continue }
      let date =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? Date()
      byID[id] = TalkRecording(id: id, date: date, duration: 0, text: "")
    }
    return byID.values.sorted { $0.date > $1.date }
  }

  public func add(_ entry: TalkRecording) {
    var all = loadIndex().filter { $0.id != entry.id }
    all.append(entry)
    saveIndex(all)
  }
  public func remove(_ id: String) {
    try? FileManager.default.removeItem(at: audioURL(id))
    saveIndex(loadIndex().filter { $0.id != id })
  }
  public func removeAll() {
    try? FileManager.default.removeItem(at: directory)
  }

  /// The ids older than the retention window at `now`.
  public static func expired(
    _ entries: [TalkRecording], now: Date = Date(), days: Int = retentionDays
  ) -> [String] {
    let cutoff = now.addingTimeInterval(-Double(days) * 86400)
    return entries.filter { $0.date < cutoff }.map(\.id)
  }
  @discardableResult
  public func purge(now: Date = Date(), days: Int = retentionDays) -> Int {
    let old = Self.expired(entries(), now: now, days: days)
    for id in old { remove(id) }
    return old.count
  }

}
