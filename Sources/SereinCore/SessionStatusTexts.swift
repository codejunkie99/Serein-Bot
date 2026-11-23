import Foundation

/// Decides when a session running on this Mac earns a text from Serein: it started waiting on the
/// person, or a turn long enough to matter ended. It only reads the states `ExternalSessionReader`
/// already reports, so it spends no AI usage. The host checkpoints it together with pending
/// notices. Only display metadata is saved, never a transcript, title or process command.
public struct SessionStatusTracker: Codable, Sendable {
  public enum Kind: String, Codable, Equatable, Sendable { case needsYou, finished }

  /// One text's worth of news. It holds what the chat may say and no more: never a session's
  /// title or anything it wrote.
  public struct Event: Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var kind: Kind
    public var sessionID: String
    public var app: String
    public var folder: String?
    /// A finish only: when its turn began, for what the turn made (`ReportReel`). Not news itself.
    public var startedAt: Date?
    /// A finish only: when its turn ended, which may be well before Serein noticed (a restart).
    public var endedAt: Date?
    public init(kind: Kind, sessionID: String, app: String, folder: String?, startedAt: Date? = nil) {
      self.kind = kind
      self.sessionID = sessionID
      self.app = app
      self.folder = folder
      self.startedAt = startedAt
    }
  }

  /// A question answered within this long never becomes a text.
  public static let needsSettle: TimeInterval = 5
  /// Work that picks up again within this long is the same turn.
  public static let finishSettle: TimeInterval = 20
  /// A turn shorter than this is chatter, not news: it never becomes a text.
  nonisolated(unsafe) public static var reportAfter: TimeInterval = 120
  /// A turn that ended in the app in front of the person was seen end: no text. (Delivery checks
  /// turn both rules off to exercise posting itself.)
  nonisolated(unsafe) public static var reportsWatched = false
  private struct Session: Codable, Sendable {
    var id: String
    var app: String
    var folder: String?
    var state: String
    var pid: Int32?
    var goal: String?
    var loopUntil: Date?
    init(_ session: ExternalSession) {
      id = session.id; app = session.driver.displayName
      folder = SessionStatusWords.place(session.cwd, home: NSHomeDirectory())
      state = session.state.rawValue; pid = session.pid
      goal = session.goal; loopUntil = session.loopUntil
    }
    func continuing(at now: Date) -> Bool { goal == "active" || (loopUntil.map { $0 > now } ?? false) }
  }

  private struct Entry: Codable, Sendable {
    var session: Session
    var gone = false
    /// When the current stretch of work began; a wait on the person ends a stretch.
    var runningSince: Date?
    /// Work in earlier stretches of this turn.
    var worked: TimeInterval = 0
    var needsAt: Date?
    var finishAt: Date?
    var recheckAt: Date?
  }
  private var entries: [String: Entry] = [:]
  private var started = false

  public init() {}

  /// Takes one scan of the sessions. The first scan is only a starting point.
  public mutating func observe(_ sessions: [ExternalSession], now: Date) {
    let baseline = !started
    started = true
    let current = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var next = entries
    for (id, session) in current {
      next[id] = Self.advance(entries[id], to: Session(session), now: now, baseline: baseline)
    }
    for (id, entry) in entries where current[id] == nil && !entry.gone {
      next[id] = Self.left(entry, now: now)
    }
    entries = next
  }

  /// The news that has settled by `now`, each decided once. `isAlive` says whether a session's
  /// process still runs; `isWatching` whether the app holding it is in front of the person.
  public mutating func due(now: Date, isAlive: (Int32) -> Bool, isWatching: (Int32) -> Bool) -> [Event] {
    var events: [Event] = []
    for id in entries.keys.sorted() {
      guard var entry = entries[id] else { continue }
      let watched = entry.session.pid.map(isWatching) ?? false
      if let asked = entry.needsAt, now.timeIntervalSince(asked) >= Self.needsSettle {
        entry.needsAt = nil
        if !watched { events.append(Self.event(.needsYou, entry.session)) }
      }
      if let ended = entry.finishAt, now.timeIntervalSince(ended) >= Self.finishSettle {
        let alive = !entry.gone || (entry.session.pid.map(isAlive) ?? false)
        // A known goal/loop may end a turn while more work is coming. Recheck without a hot
        // timer, and let the next scan of a terminal goal state release the pending finish.
        if alive, entry.session.continuing(at: now) {
          entry.recheckAt = now.addingTimeInterval(60)
          entries[id] = entry
          continue
        }
        let total = entry.worked + (entry.runningSince.map { ended.timeIntervalSince($0) } ?? 0)
        entry.finishAt = nil
        entry.runningSince = nil
        entry.worked = 0
        entry.recheckAt = nil
        // Only news: a turn long enough to matter that ended while the person was not looking at
        // the app it ran in. A short turn, or one they watched end, says nothing new.
        if alive, total >= Self.reportAfter, Self.reportsWatched || !watched {
          var finished = Self.event(.finished, entry.session)
          finished.startedAt = ended.addingTimeInterval(-total)
          finished.endedAt = ended
          events.append(finished)
        }
      }
      let keep = !entry.gone || entry.finishAt != nil
      entries[id] = keep ? entry : nil
    }
    return events.sorted { ($0.kind == .needsYou ? 0 : 1) < ($1.kind == .needsYou ? 0 : 1) }
  }

  /// When something pending settles, so the caller wakes then and not on a timer.
  public var nextDue: Date? {
    entries.values.flatMap { entry -> [Date] in
      [entry.needsAt?.addingTimeInterval(Self.needsSettle), entry.recheckAt ?? entry.finishAt?.addingTimeInterval(Self.finishSettle)]
        .compactMap { $0 }
    }.min()
  }

  private static func advance(_ previous: Entry?, to session: Session, now: Date, baseline: Bool) -> Entry {
    var entry = previous ?? Entry(session: session)
    let was = previous?.gone == false ? previous?.session.state : nil
    // A session that dropped out of one scan (a restart, a slow read) and comes back still waiting
    // is the same wait: it was told once already.
    let waitedBefore = previous?.session.state == "needsUser"
    if previous?.session.goal != session.goal || previous?.session.loopUntil != session.loopUntil { entry.recheckAt = nil }
    entry.session = session
    entry.gone = false
    switch session.state {
    case "running":
      // A short pause carries on the same stretch; an answered question starts a new one.
      entry.runningSince = entry.runningSince ?? now
      entry.needsAt = nil
      entry.finishAt = nil
      entry.recheckAt = nil
    case "needsUser":
      if was != "needsUser", !waitedBefore, !baseline { entry.needsAt = now }
      entry.finishAt = nil
      entry.recheckAt = nil
      if let since = entry.runningSince {
        entry.worked += now.timeIntervalSince(since)
        entry.runningSince = nil
      }
    default:
      entry.needsAt = nil
      if was == "running" {
        entry.finishAt = now
      } else if entry.finishAt == nil {
        entry.runningSince = nil
        entry.worked = 0
      }
    }
    return entry
  }

  private static func left(_ previous: Entry, now: Date) -> Entry {
    var entry = previous
    entry.gone = true
    entry.needsAt = nil
    if entry.session.state == "running" {
      entry.finishAt = now
    } else if entry.finishAt == nil {
      entry.runningSince = nil
      entry.worked = 0
    }
    return entry
  }

  private static func event(_ kind: Kind, _ session: Session) -> Event {
    Event(
      kind: kind, sessionID: session.id, app: session.app, folder: session.folder)
  }
}

/// What a status text says. The app wrote it, not a model, and it names an app and a folder only:
/// sessions outside Serein stay out of saved chats and of anything a model reads.
public enum SessionStatusWords {
  /// The most sessions one text lists.
  static let maxListed = 4
  static let maxPlace = 40

  /// A working folder as chat words: its last part, without anything that would draw as markup.
  public static func place(_ cwd: String?, home: String) -> String? {
    guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
    if cwd == home { return "your home folder" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -._"))
    let name = URL(fileURLWithPath: cwd).lastPathComponent.unicodeScalars
      .map { allowed.contains($0) ? String($0) : " " }.joined()
      .split(separator: " ").joined(separator: " ")
    guard !name.isEmpty else { return nil }
    return name.count > maxPlace ? String(name.prefix(maxPlace - 1)) + "…" : name
  }

  /// The chat's words for one or more events of one kind.
  /// The longest session title a finish names.
  static let titleLimit = 80

  /// A finished turn from the session list alone: “Claude Code finished “Fix the login page” in
  /// site after 12 min.” The title is the one the app lists; the minutes are the turn's own.
  public static func finished(app: String, title: String?, folder: String?, minutes: Double?) -> String {
    var words = app + " finished"
    let cleaned = (title ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if !cleaned.isEmpty {
      let cut = cleaned.count > titleLimit ? String(cleaned.prefix(titleLimit - 1)) + "…" : cleaned
      words += " \u{201C}" + cut + "\u{201D}"
    }
    if let folder { words += " in " + folder }
    if let minutes, minutes >= 1 { words += " after " + duration(minutes) }
    return words + "."
  }

  /// “12 min”, “1 h” or “2 h 5 min”.
  public static func duration(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    let hours = total / 60, rest = total % 60
    if hours == 0 { return "\(total) min" }
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
  }

  public static func text(_ events: [SessionStatusTracker.Event]) -> String {
    guard let only = events.first else { return "" }
    guard events.count > 1 else {
      // A turn that ended is not a goal that is done: a session in a loop ends many.
      let verb = only.kind == .needsYou ? "needs you" : "has an update"
      return only.app + " " + verb + (only.folder.map { " in " + $0 } ?? "") + "."
    }
    let listed = events.prefix(maxListed).map { $0.app + ($0.folder.map { " in " + $0 } ?? "") }.joined(separator: ", ")
    let more = events.count > maxListed ? " and \(events.count - maxListed) more" : ""
    return "\(events.count) sessions \(only.kind == .needsYou ? "need you" : "have updates"): \(listed)\(more)."
  }

  /// A notification's words: names and counts only (ARCHITECTURE, notifications hold names).
  public static func notification(_ events: [SessionStatusTracker.Event]) -> String {
    guard let only = events.first else { return "" }
    guard events.count > 1 else { return only.app + (only.kind == .needsYou ? " needs you." : " has an update.") }
    return "\(events.count) sessions \(only.kind == .needsYou ? "need you" : "have updates")."
  }
}

/// One finished turn on a "Sessions finished" card, from the session list alone: its app, its
/// title (only while the person lets Serein read their chats), its folder, how long it worked and
/// when it ended. Never anything the session wrote. The host writes it; no model reads it.
public struct SessionFinish: Codable, Equatable, Sendable, Identifiable {
  /// The status event's id, so a delivery retried after a crash never adds the row twice.
  public var id: String
  public var sessionID: String
  public var app: String
  public var title: String?
  public var folder: String?
  public var minutes: Double?
  public var endedAt: Date
  public init(id: String, sessionID: String, app: String, title: String?, folder: String?, minutes: Double?, endedAt: Date) {
    self.id = id
    self.sessionID = sessionID
    self.app = app
    self.title = title
    self.folder = folder
    self.minutes = minutes
    self.endedAt = endedAt
  }
}

/// Turns that ended with no report to tell share one card at the end of the chat, a row each,
/// instead of a line each: the card grows while it is still the chat's last message, and a
/// session that finishes again moves its own row to the end instead of adding one.
public enum SessionFinishes {
  /// The most rows a card keeps; the oldest go first.
  public static let limit = 12

  /// The card's rows once `row` is in: oldest first, one per session, never the same event twice.
  public static func adding(_ row: SessionFinish, to rows: [SessionFinish]) -> [SessionFinish] {
    guard !rows.contains(where: { $0.id == row.id }) else { return rows }
    let others = rows.filter { $0.sessionID != row.sessionID }
    return Array((others + [row]).suffix(limit))
  }

  /// The card's words, for copying, search and anything that reads only text: one row as its
  /// sentence (`SessionStatusWords.finished`), several as a count and their apps and folders.
  public static func text(_ rows: [SessionFinish]) -> String {
    guard let only = rows.last else { return "" }
    guard rows.count > 1 else {
      return SessionStatusWords.finished(app: only.app, title: only.title, folder: only.folder, minutes: only.minutes)
    }
    let newest = rows.reversed()
    let listed = newest.prefix(SessionStatusWords.maxListed).map { $0.app + ($0.folder.map { " in " + $0 } ?? "") }
      .joined(separator: ", ")
    let more = rows.count > SessionStatusWords.maxListed ? " and \(rows.count - SessionStatusWords.maxListed) more" : ""
    return "\(rows.count) sessions finished: \(listed)\(more)."
  }
}
