import Foundation

/// How far back "Clear saved data" reaches.
public enum ClearRange: String, CaseIterable, Codable, Identifiable, Sendable {
  case lastHour, today, lastWeek, lastFourWeeks, allTime
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .lastHour: return "Last hour"
    case .today: return "Today"
    case .lastWeek: return "Last 7 days"
    case .lastFourWeeks: return "Last 4 weeks"
    case .allTime: return "All time"
    }
  }
  /// The earliest moment that is cleared; nil means everything.
  public func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
    switch self {
    case .lastHour: return now.addingTimeInterval(-3600)
    case .today: return calendar.startOfDay(for: now)
    case .lastWeek: return now.addingTimeInterval(-7 * 86_400)
    case .lastFourWeeks: return now.addingTimeInterval(-28 * 86_400)
    case .allTime: return nil
    }
  }
  /// True when `date` falls inside the range. Dates in the future (a clock that moved back)
  /// count as inside, so they are never left behind.
  public func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard let start = start(now: now, calendar: calendar) else { return true }
    return date >= start
  }
}

/// The kinds of data the sheet can clear.
public enum ClearKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case history, downloads, cookies, passages, threads, permissions, recentlyClosed
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .history: return "History"
    case .downloads: return "Downloads list"
    case .cookies: return "Cookies and site data"
    case .passages: return "Kept passages"
    case .threads: return "Chats"
    case .permissions: return "Site permissions"
    case .recentlyClosed: return "Recently closed pages"
    }
  }
  public var detail: String {
    switch self {
    case .history: return "Pages you visited, their excerpts and day summaries."
    case .downloads: return "The list only. Downloaded files stay on your Mac."
    case .cookies: return "Signs you out of most sites, and signs Serein out of sites it stays signed in to."
    case .passages: return "Text you kept from pages. Saved pages stay."
    case .threads: return "Your chats with Serein and your AI apps. Running tasks are kept."
    case .permissions: return "Camera, microphone, location, notifications and sound."
    case .recentlyClosed: return "Pages you can reopen."
    }
  }
  /// Kinds stored without a time. Any range clears all of them, and the sheet says so.
  public var dated: Bool { self != .permissions && self != .recentlyClosed }
  /// Checked when the sheet opens. Data that signs you out or loses your own words starts off.
  public var onByDefault: Bool { self == .history || self == .downloads || self == .recentlyClosed }
}

public enum BrowsingDataClear {
  /// Splits dated items into the ones kept and the ones cleared.
  public static func split<T>(
    _ items: [T], range: ClearRange, now: Date = Date(), calendar: Calendar = .current,
    date: (T) -> Date
  ) -> (kept: [T], removed: [T]) {
    var kept: [T] = []
    var removed: [T] = []
    for item in items {
      if range.contains(date(item), now: now, calendar: calendar) {
        removed.append(item)
      } else {
        kept.append(item)
      }
    }
    return (kept, removed)
  }
  /// How many items a kind would clear. Undated kinds count everything.
  public static func count<T>(
    _ items: [T], kind: ClearKind, range: ClearRange, now: Date = Date(),
    calendar: Calendar = .current, date: (T) -> Date?
  ) -> Int {
    guard kind.dated else { return items.count }
    return items.filter { item in
      date(item).map { range.contains($0, now: now, calendar: calendar) } ?? (range == .allTime)
    }.count
  }
  /// The sheet's line for a kind: "12 visits", "Nothing to clear", or a note for undated kinds.
  public static func summary(kind: ClearKind, count: Int?, range: ClearRange) -> String {
    guard let count else { return range == .allTime ? "Every site" : "Sites changed in this range" }
    let noun: String
    switch kind {
    case .history: noun = count == 1 ? "visit" : "visits"
    case .downloads: noun = count == 1 ? "download" : "downloads"
    case .cookies: noun = count == 1 ? "site" : "sites"
    case .passages: noun = count == 1 ? "passage" : "passages"
    case .threads: noun = count == 1 ? "thread" : "threads"
    case .permissions: noun = count == 1 ? "site choice" : "site choices"
    case .recentlyClosed: noun = count == 1 ? "page" : "pages"
    }
    if count == 0 { return "Nothing to clear" }
    let line = "\(count) \(noun)"
    return kind.dated || range == .allTime ? line : line + " · not dated, so all are cleared"
  }
}

extension Library {
  /// Removes every stored visit that matches. Returns the removed visits.
  @discardableResult
  public func removeVisits(where matches: (Visit) -> Bool) throws -> [Visit] {
    try rewriteHistory(removes: { visit, _ in visit.map(matches) ?? false }).removed
  }

  /// The one rewrite of the `history/*.jsonl` day files. `touches` marks a day whose unreadable
  /// lines (or whole unreadable file) go too; `removes` decides each line from its visit (nil when
  /// the line does not decode) and its day's mark. A file left empty is deleted; a rewritten one
  /// stays 0600. Returns the removed visits and the days that changed.
  func rewriteHistory(
    touches: (_ day: String) -> Bool = { _ in false },
    removes: (_ visit: Visit?, _ dayTouched: Bool) -> Bool
  ) throws -> (removed: [Visit], days: Set<String>) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let dir = root.appendingPathComponent("history")
    let files =
      (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var removed: [Visit] = []
    var days = Set<String>()
    for file in files where file.pathExtension == "jsonl" {
      let key = file.deletingPathExtension().lastPathComponent
      let touched = touches(key)
      guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        if touched {
          try FileManager.default.removeItem(at: file)
          days.insert(key)
        }
        continue
      }
      var kept: [Substring] = []
      var changed = false
      for line in text.split(separator: "\n") {
        let visit = try? decoder.decode(Visit.self, from: Data(line.utf8))
        if removes(visit, touched) {
          if let visit { removed.append(visit) }
          changed = true
        } else {
          kept.append(line)
        }
      }
      guard changed else { continue }
      days.insert(key)
      if kept.isEmpty {
        try FileManager.default.removeItem(at: file)
      } else {
        try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
    }
    return (removed, days)
  }
}
