import Foundation
import SQLite3

public enum BrowserBookmarkFormat: String, Sendable {
  case chromiumJSON
  case safariPlist
  case firefoxSQLite
  case arcSidebarJSON
  case html
}

public struct BrowserImportProfile: Identifiable, Hashable, Sendable {
  public let id: String
  public let browser: String
  public let profile: String
  public let directory: URL
  public let bookmarks: URL?
  public let history: URL?
  public let bookmarkFormat: BrowserBookmarkFormat?

  public init(
    browser: String, profile: String, directory: URL, bookmarks: URL?, history: URL?,
    bookmarkFormat: BrowserBookmarkFormat?
  ) {
    self.browser = browser
    self.profile = profile
    self.directory = directory
    self.bookmarks = bookmarks
    self.history = history
    self.bookmarkFormat = bookmarkFormat
    id = browser + "|" + directory.standardizedFileURL.path
  }
}

public enum BrowserProfileScanner {
  private struct ChromiumFamily {
    let name: String
    let paths: [String]
    let arcSidebar: Bool
  }

  private static let chromiumFamilies = [
    ChromiumFamily(name: "Google Chrome", paths: ["Google/Chrome"], arcSidebar: false),
    ChromiumFamily(name: "Chromium", paths: ["Chromium"], arcSidebar: false),
    ChromiumFamily(name: "Microsoft Edge", paths: ["Microsoft Edge"], arcSidebar: false),
    ChromiumFamily(name: "Brave", paths: ["BraveSoftware/Brave-Browser"], arcSidebar: false),
    ChromiumFamily(name: "Vivaldi", paths: ["Vivaldi"], arcSidebar: false),
    ChromiumFamily(name: "Opera", paths: ["com.operasoftware.Opera"], arcSidebar: false),
    ChromiumFamily(
      name: "Comet",
      paths: [
        "Comet", "Perplexity/Comet", "com.perplexity.comet", "com.perplexity.comet/User Data",
      ],
      arcSidebar: false),
    ChromiumFamily(
      name: "Arc", paths: ["Arc/User Data", "company.thebrowser.Browser"], arcSidebar: true),
  ]

  public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> [BrowserImportProfile]
  {
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    var profiles: [BrowserImportProfile] = []
    profiles += safariProfiles(home: home)
    profiles += firefoxProfiles(support: support)
    for family in chromiumFamilies {
      for path in family.paths {
        profiles += chromiumProfiles(
          browser: family.name, root: support.appendingPathComponent(path, isDirectory: true),
          allowArcSidebar: family.arcSidebar)
      }
    }
    if !profiles.contains(where: { $0.browser == "Arc" }) {
      let arc = support.appendingPathComponent("Arc", isDirectory: true)
      let sidebar = existing(arc.appendingPathComponent("StorableSidebar.json"))
      if let sidebar {
        profiles.append(
          BrowserImportProfile(
            browser: "Arc", profile: "Pinned and saved tabs", directory: arc,
            bookmarks: sidebar, history: nil, bookmarkFormat: .arcSidebarJSON))
      }
    }
    return unique(profiles).sorted {
      ($0.browser.localizedCaseInsensitiveCompare($1.browser) == .orderedSame)
        ? $0.profile.localizedCaseInsensitiveCompare($1.profile) == .orderedAscending
        : $0.browser.localizedCaseInsensitiveCompare($1.browser) == .orderedAscending
    }
  }

  public static func profiles(in folder: URL, browserName: String = "Custom browser")
    -> [BrowserImportProfile]
  {
    var result = directProfiles(browser: browserName, root: folder, allowArcSidebar: true)
    let userData = folder.appendingPathComponent("User Data", isDirectory: true)
    result += directProfiles(browser: browserName, root: userData, allowArcSidebar: true)
    result += firefoxDirectoryProfiles(browser: browserName, root: folder)
    if result.isEmpty {
      let safariBookmarks = existing(folder.appendingPathComponent("Bookmarks.plist"))
      let safariHistory = existing(folder.appendingPathComponent("History.db"))
      let html = existing(folder.appendingPathComponent("bookmarks.html"))
      let bookmarks = safariBookmarks ?? html
      let format: BrowserBookmarkFormat? =
        safariBookmarks != nil ? .safariPlist : html != nil ? .html : nil
      if bookmarks != nil || safariHistory != nil {
        result.append(
          BrowserImportProfile(
            browser: browserName, profile: folder.lastPathComponent, directory: folder,
            bookmarks: bookmarks, history: safariHistory, bookmarkFormat: format))
      }
    }
    return unique(result)
  }

  private static func safariProfiles(home: URL) -> [BrowserImportProfile] {
    let roots = [
      home.appendingPathComponent("Library/Safari", isDirectory: true),
      home.appendingPathComponent(
        "Library/Containers/com.apple.Safari/Data/Library/Safari", isDirectory: true),
    ]
    var result: [BrowserImportProfile] = []
    for root in roots where isDirectory(root) {
      result += safariProfile(root, name: "Default")
      let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
      for folder in childDirectories(profiles) {
        result += safariProfile(folder, name: folder.lastPathComponent)
      }
    }
    return result
  }

  private static func safariProfile(_ root: URL, name: String) -> [BrowserImportProfile] {
    let bookmarks = existing(root.appendingPathComponent("Bookmarks.plist"))
    let history = existing(root.appendingPathComponent("History.db"))
    guard bookmarks != nil || history != nil else { return [] }
    return [
      BrowserImportProfile(
        browser: "Safari", profile: name, directory: root, bookmarks: bookmarks,
        history: history, bookmarkFormat: bookmarks == nil ? nil : .safariPlist)
    ]
  }

  private static func firefoxProfiles(support: URL) -> [BrowserImportProfile] {
    firefoxDirectoryProfiles(
      browser: "Firefox",
      root: support.appendingPathComponent("Firefox/Profiles", isDirectory: true))
  }

  private static func firefoxDirectoryProfiles(browser: String, root: URL) -> [BrowserImportProfile]
  {
    let candidates = isDirectory(root) ? childDirectories(root) + [root] : []
    return candidates.compactMap { folder in
      let places = existing(folder.appendingPathComponent("places.sqlite"))
      guard let places else { return nil }
      return BrowserImportProfile(
        browser: browser, profile: folder.lastPathComponent, directory: folder,
        bookmarks: places, history: places, bookmarkFormat: .firefoxSQLite)
    }
  }

  private static func chromiumProfiles(
    browser: String, root: URL, allowArcSidebar: Bool
  ) -> [BrowserImportProfile] {
    guard isDirectory(root) else { return [] }
    return directProfiles(browser: browser, root: root, allowArcSidebar: allowArcSidebar)
  }

  private static func directProfiles(
    browser: String, root: URL, allowArcSidebar: Bool
  ) -> [BrowserImportProfile] {
    guard isDirectory(root) else { return [] }
    let names = chromiumProfileNames(root: root)
    var folders = [root]
    folders += childDirectories(root).filter {
      $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ")
    }
    return folders.compactMap { folder in
      var bookmarkURL = existing(folder.appendingPathComponent("Bookmarks"))
      var format: BrowserBookmarkFormat? = bookmarkURL == nil ? nil : .chromiumJSON
      if bookmarkURL == nil, allowArcSidebar {
        let candidates = [
          folder.appendingPathComponent("StorableSidebar.json"),
          root.deletingLastPathComponent().appendingPathComponent("StorableSidebar.json"),
          root.appendingPathComponent("StorableSidebar.json"),
        ]
        bookmarkURL = candidates.compactMap(existing).first
        if bookmarkURL != nil { format = .arcSidebarJSON }
      }
      let history = existing(folder.appendingPathComponent("History"))
      guard bookmarkURL != nil || history != nil else { return nil }
      let key = folder.lastPathComponent
      let fallback = folder == root ? "Default" : key
      return BrowserImportProfile(
        browser: browser, profile: names[key] ?? fallback, directory: folder,
        bookmarks: bookmarkURL, history: history, bookmarkFormat: format)
    }
  }

  private static func chromiumProfileNames(root: URL) -> [String: String] {
    let url = root.appendingPathComponent("Local State")
    guard let data = try? boundedData(url, limit: 8_000_000),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profile = json["profile"] as? [String: Any],
      let cache = profile["info_cache"] as? [String: Any]
    else { return [:] }
    return cache.reduce(into: [:]) { result, item in
      guard let value = item.value as? [String: Any], let name = value["name"] as? String,
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      result[item.key] = name
    }
  }

  private static func unique(_ profiles: [BrowserImportProfile]) -> [BrowserImportProfile] {
    var seen = Set<String>()
    return profiles.filter { seen.insert($0.id).inserted }
  }

  private static func childDirectories(_ root: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]))?.filter(isDirectory) ?? []
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
      .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
  }

  private static func existing(_ url: URL) -> URL? {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values?.isRegularFile == true && values?.isSymbolicLink != true ? url : nil
  }
}

public struct BrowserImportPreview: Sendable {
  public let profile: BrowserImportProfile
  public var bookmarks: [Mark]
  public var visits: [Visit]
  public var skipped: Int
  public var messages: [String]

  public init(
    profile: BrowserImportProfile, bookmarks: [Mark] = [], visits: [Visit] = [], skipped: Int = 0,
    messages: [String] = []
  ) {
    self.profile = profile
    self.bookmarks = bookmarks
    self.visits = visits
    self.skipped = skipped
    self.messages = messages
  }
}

public enum BrowserDataReader {
  public static func read(
    _ profile: BrowserImportProfile, includeBookmarks: Bool, includeHistory: Bool,
    cancelled: () -> Bool = { false }
  ) throws -> BrowserImportPreview {
    var result = BrowserImportPreview(profile: profile)
    if includeBookmarks, let url = profile.bookmarks, let format = profile.bookmarkFormat {
      switch format {
      case .firefoxSQLite:
        result.messages.append("Up to 10,000 most recent bookmarks per Firefox profile.")
      case .html:
        result.messages.append("Bookmark HTML files must be 10 MB or smaller.")
      default:
        result.messages.append("Bookmark files must be 64 MB or smaller.")
      }
      do {
        let parsed: ([Mark], Int)
        switch format {
        case .chromiumJSON: parsed = try chromiumBookmarks(url, cancelled: cancelled)
        case .safariPlist: parsed = try safariBookmarks(url, cancelled: cancelled)
        case .firefoxSQLite: parsed = try firefoxBookmarks(url, cancelled: cancelled)
        case .arcSidebarJSON: parsed = try arcBookmarks(url, cancelled: cancelled)
        case .html: parsed = try htmlBookmarks(url, cancelled: cancelled)
        }
        result.bookmarks = parsed.0
        result.skipped += parsed.1
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.messages.append("Bookmarks: " + error.localizedDescription)
      }
    }
    if includeHistory, let url = profile.history {
      result.messages.append("Up to 10,000 most recent history visits per profile.")
      do {
        let parsed = try history(url, cancelled: cancelled)
        result.visits = parsed.0
        result.skipped += parsed.1
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.messages.append("History: " + error.localizedDescription)
      }
    }
    return result
  }

  public static func history(
    _ source: URL, cancelled: () -> Bool = { false }
  ) throws -> ([Visit], Int) {
    try withSQLiteSnapshot(source) { db in
      let queries = [
        "SELECT u.url, u.title, (v.visit_time/1000000.0)-11644473600 FROM visits v JOIN urls u ON u.id=v.url ORDER BY v.visit_time DESC LIMIT 10000",
        "SELECT url, title, (last_visit_time/1000000.0)-11644473600 FROM urls ORDER BY last_visit_time DESC LIMIT 10000",
        "SELECT p.url,p.title,v.visit_date/1000000.0 FROM moz_historyvisits v JOIN moz_places p ON p.id=v.place_id ORDER BY v.visit_date DESC LIMIT 10000",
        "SELECT url,title,last_visit_date/1000000.0 FROM moz_places WHERE last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 10000",
        "SELECT i.url,v.title,v.visit_time+978307200 FROM history_visits v JOIN history_items i ON i.id=v.history_item ORDER BY v.visit_time DESC LIMIT 10000",
      ]
      for query in queries {
        if let result = try visitRows(db, query: query, cancelled: cancelled) { return result }
      }
      throw SereinError.invalid("Not a supported Chromium, Firefox or Safari history database")
    }
  }

  public static func chromiumBookmarks(
    _ url: URL, cancelled: () -> Bool = { false }
  ) throws -> ([Mark], Int) {
    let data = try boundedData(url, limit: 64_000_000)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let roots = json["roots"] as? [String: Any]
    else { throw SereinError.invalid("Not a Chromium bookmarks file") }
    var output: [Mark] = []
    var skipped = 0
    walkJSON(roots, cancelled: cancelled) { value in
      guard let address = value["url"] as? String else { return }
      guard (try? BrowserPolicy.url(address)) != nil else {
        skipped += 1
        return
      }
      output.append(
        Mark(
          title: cleanTitle(value["name"] as? String, fallback: address), url: address, quote: ""))
    }
    if cancelled() { throw CancellationError() }
    return deduplicateMarks(output, skipped: skipped)
  }

  public static func safariBookmarks(
    _ url: URL, cancelled: () -> Bool = { false }
  ) throws -> ([Mark], Int) {
    let data = try boundedData(url, limit: 64_000_000)
    let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    var output: [Mark] = []
    var skipped = 0
    walkAny(root, cancelled: cancelled) { value in
      guard let address = value["URLString"] as? String else { return }
      guard (try? BrowserPolicy.url(address)) != nil else {
        skipped += 1
        return
      }
      let dictionaryTitle = (value["URIDictionary"] as? [String: Any])?["title"] as? String
      output.append(
        Mark(
          title: cleanTitle(dictionaryTitle ?? value["Title"] as? String, fallback: address),
          url: address, quote: ""))
    }
    if cancelled() { throw CancellationError() }
    return deduplicateMarks(output, skipped: skipped)
  }

  public static func arcBookmarks(
    _ url: URL, cancelled: () -> Bool = { false }
  ) throws -> ([Mark], Int) {
    let data = try boundedData(url, limit: 64_000_000)
    let root = try JSONSerialization.jsonObject(with: data)
    var output: [Mark] = []
    var skipped = 0
    walkAny(root, cancelled: cancelled) { value in
      let address = (value["savedURL"] ?? value["url"] ?? value["URL"]) as? String
      guard let address else { return }
      guard (try? BrowserPolicy.url(address)) != nil else {
        skipped += 1
        return
      }
      let title = (value["savedTitle"] ?? value["title"] ?? value["name"]) as? String
      output.append(Mark(title: cleanTitle(title, fallback: address), url: address, quote: ""))
    }
    if cancelled() { throw CancellationError() }
    guard !output.isEmpty else {
      throw SereinError.invalid("No supported Arc saved-tab records found")
    }
    return deduplicateMarks(output, skipped: skipped)
  }

  public static func htmlBookmarks(
    _ url: URL, cancelled: () -> Bool = { false }
  ) throws -> ([Mark], Int) {
    let data = try boundedData(url, limit: 10_000_000)
    let text = String(decoding: data, as: UTF8.self)
    let expression = try NSRegularExpression(
      pattern: "<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
      options: [.caseInsensitive, .dotMatchesLineSeparators])
    let ns = text as NSString
    var output: [Mark] = []
    var skipped = 0
    for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      if cancelled() { throw CancellationError() }
      let address = decodeHTML(ns.substring(with: match.range(at: 1)))
      guard (try? BrowserPolicy.url(address)) != nil else {
        skipped += 1
        continue
      }
      let title = decodeHTML(
        ns.substring(with: match.range(at: 2)).replacingOccurrences(
          of: "<[^>]+>", with: "", options: .regularExpression))
      output.append(Mark(title: cleanTitle(title, fallback: address), url: address, quote: ""))
    }
    return deduplicateMarks(output, skipped: skipped)
  }

  public static func firefoxBookmarks(
    _ source: URL, cancelled: () -> Bool = { false }
  ) throws -> ([Mark], Int) {
    try withSQLiteSnapshot(source) { db in
      let query = """
        SELECT p.url, COALESCE(NULLIF(b.title,''), NULLIF(p.title,''), p.url), b.dateAdded/1000000.0
        FROM moz_bookmarks b JOIN moz_places p ON p.id=b.fk
        WHERE b.type=1 AND p.url IS NOT NULL ORDER BY b.dateAdded DESC LIMIT 10000
        """
      guard let parsed = try markRows(db, query: query, cancelled: cancelled) else {
        throw SereinError.invalid("Not a supported Firefox places database")
      }
      return parsed
    }
  }

  private static func visitRows(
    _ db: OpaquePointer?, query: String, cancelled: () -> Bool
  ) throws -> ([Visit], Int)? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      return nil
    }
    defer { sqlite3_finalize(statement) }
    var result: [Visit] = []
    var skipped = 0
    while sqlite3_step(statement) == SQLITE_ROW {
      if cancelled() { throw CancellationError() }
      guard let raw = sqlite3_column_text(statement, 0) else {
        skipped += 1
        continue
      }
      let address = String(cString: raw)
      let seconds = sqlite3_column_double(statement, 2)
      guard (try? BrowserPolicy.url(address)) != nil, seconds.isFinite, seconds > 0,
        seconds < Date().timeIntervalSince1970 + 86_400
      else {
        skipped += 1
        continue
      }
      let rawTitle = sqlite3_column_text(statement, 1).map(String.init(cString:))
      var visit = Visit(url: address, title: cleanTitle(rawTitle, fallback: address), text: "")
      visit.date = Date(timeIntervalSince1970: seconds)
      result.append(visit)
    }
    return (result, skipped)
  }

  private static func markRows(
    _ db: OpaquePointer?, query: String, cancelled: () -> Bool
  ) throws -> ([Mark], Int)? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      return nil
    }
    defer { sqlite3_finalize(statement) }
    var result: [Mark] = []
    var skipped = 0
    while sqlite3_step(statement) == SQLITE_ROW {
      if cancelled() { throw CancellationError() }
      guard let raw = sqlite3_column_text(statement, 0) else {
        skipped += 1
        continue
      }
      let address = String(cString: raw)
      guard (try? BrowserPolicy.url(address)) != nil else {
        skipped += 1
        continue
      }
      let rawTitle = sqlite3_column_text(statement, 1).map(String.init(cString:))
      var mark = Mark(title: cleanTitle(rawTitle, fallback: address), url: address, quote: "")
      let seconds = sqlite3_column_double(statement, 2)
      if seconds.isFinite, seconds > 0, seconds < Date().timeIntervalSince1970 + 86_400 {
        mark.date = Date(timeIntervalSince1970: seconds)
      }
      result.append(mark)
    }
    return deduplicateMarks(result, skipped: skipped)
  }

  static func withSQLiteSnapshot<T>(_ source: URL, body: (OpaquePointer?) throws -> T)
    throws -> T
  {
    let manager = FileManager.default
    guard manager.fileExists(atPath: source.path) else {
      throw SereinError.invalid("The browser database is no longer available")
    }
    let folder = manager.temporaryDirectory.appendingPathComponent(
      "serein-browser-import-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: folder) }
    let snapshot = folder.appendingPathComponent(source.lastPathComponent)
    var copied = false
    for _ in 0..<3 {
      try? manager.removeItem(at: snapshot)
      try? manager.removeItem(at: URL(fileURLWithPath: snapshot.path + "-wal"))
      let before = try snapshotStamp(source)
      let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
      let beforeWAL = try? snapshotStamp(sourceWAL)
      try manager.copyItem(at: source, to: snapshot)
      if beforeWAL != nil {
        try manager.copyItem(at: sourceWAL, to: URL(fileURLWithPath: snapshot.path + "-wal"))
      }
      if before == (try? snapshotStamp(source)), beforeWAL == (try? snapshotStamp(sourceWAL)) {
        copied = true
        break
      }
    }
    guard copied else {
      throw SereinError.invalid(
        "The browser database changed while Serein copied a read-only snapshot. Close the browser and retry."
      )
    }
    var db: OpaquePointer?
    guard sqlite3_open_v2(snapshot.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      let detail = db.map { String(cString: sqlite3_errmsg($0)) }
      if let db { sqlite3_close(db) }
      throw SereinError.invalid(
        detail ?? "Cannot open the browser database. macOS may be protecting it; choose the folder yourself or export from the browser.")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 2_000)
    return try body(db)
  }

  private struct SnapshotStamp: Equatable {
    let size: UInt64
    let modified: Date
  }

  private static func snapshotStamp(_ url: URL) throws -> SnapshotStamp {
    let values = try url.resourceValues(
      forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, let modified = values.contentModificationDate
    else {
      throw SereinError.invalid("Cannot inspect browser database")
    }
    return SnapshotStamp(size: UInt64(size), modified: modified)
  }

  private static func walkJSON(
    _ value: Any, cancelled: () -> Bool, visit: ([String: Any]) -> Void
  ) {
    guard !cancelled() else { return }
    if let dictionary = value as? [String: Any] {
      visit(dictionary)
      for child in dictionary.values { walkJSON(child, cancelled: cancelled, visit: visit) }
    } else if let array = value as? [Any] {
      for child in array { walkJSON(child, cancelled: cancelled, visit: visit) }
    }
  }

  private static func walkAny(
    _ value: Any, cancelled: () -> Bool, visit: ([String: Any]) -> Void
  ) {
    walkJSON(value, cancelled: cancelled, visit: visit)
  }

  private static func deduplicateMarks(_ values: [Mark], skipped: Int) -> ([Mark], Int) {
    var seen = Set<String>()
    var duplicateCount = 0
    let unique = values.filter {
      let key = BrowserImportMerger.canonicalURL($0.url)
      guard seen.insert(key).inserted else {
        duplicateCount += 1
        return false
      }
      return true
    }
    return (unique, skipped + duplicateCount)
  }

  private static func cleanTitle(_ title: String?, fallback: String) -> String {
    let value = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? fallback : String(value.prefix(1_000))
  }

  private static func decodeHTML(_ value: String) -> String { HTMLEntities.decode(value) }
}

public struct BrowserImportMergeResult: Sendable {
  public let importedVisits: [Visit]
  public let importedMarks: [Mark]
  public let allVisits: [Visit]
  public let allMarks: [Mark]
  public let duplicates: Int
}

public enum BrowserImportMerger {
  public static func merge(
    visits incomingVisits: [Visit], marks incomingMarks: [Mark], existingVisits: [Visit],
    existingMarks: [Mark]
  ) -> BrowserImportMergeResult {
    var visitKeys = Set(existingVisits.map(visitKey))
    var markKeys = Set(existingMarks.map { canonicalURL($0.url) })
    var visits: [Visit] = []
    var marks: [Mark] = []
    var duplicates = 0
    for visit in incomingVisits {
      guard visitKeys.insert(visitKey(visit)).inserted else {
        duplicates += 1
        continue
      }
      visits.append(visit)
    }
    for mark in incomingMarks {
      guard markKeys.insert(canonicalURL(mark.url)).inserted else {
        duplicates += 1
        continue
      }
      marks.append(mark)
    }
    return BrowserImportMergeResult(
      importedVisits: visits, importedMarks: marks,
      allVisits: (existingVisits + visits).sorted { $0.date > $1.date },
      allMarks: existingMarks + marks, duplicates: duplicates)
  }

  static func canonicalURL(_ value: String) -> String {
    guard var components = URLComponents(string: value) else { return value }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    components.fragment = nil
    if components.path == "/" { components.path = "" }
    return components.string ?? value
  }

  private static func visitKey(_ value: Visit) -> String {
    canonicalURL(value.url) + "|" + String(Int64(value.date.timeIntervalSince1970.rounded(.down)))
  }
}

private func boundedData(_ url: URL, limit: Int) throws -> Data {
  let values = try url.resourceValues(forKeys: [
    .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
  ])
  guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
    size <= limit
  else {
    throw SereinError.invalid("The selected import file is too large or is not a regular file")
  }
  return try Data(contentsOf: url, options: [.mappedIfSafe])
}
