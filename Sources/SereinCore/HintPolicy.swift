import Foundation

/// Priority is the declaration order. Raw values are shared with previews and saved tip state.
public enum HintID: String, CaseIterable, Codable, Hashable, Sendable {
  case sereinRow = "serein-row"
  case beside
  case optionSpace = "option-space"
  case taskDone = "task-done"
  case asksBefore = "asks-before"
  case checkIns = "check-ins"
}

/// Pure eligibility and accounting for occasional teaching. No clock, preferences or UI work.
public enum HintPolicy {
  public static let launchDelay: TimeInterval = 30
  public static let inputDelay: TimeInterval = 3
  public static let spacing: TimeInterval = 600
  public static let visibleDuration: TimeInterval = 8
  public static let dailyLimit = 2

  public struct History: Codable, Equatable, Sendable {
    public var seen: Set<HintID> = []
    /// Losing the anchor before eight seconds permits one later appearance, still rate-limited.
    public var lostAnchor: Set<HintID> = []
    public var lastShownAt: Date?
    public var shownDay: String?
    public var shownToday = 0
    public var messageDays: Set<String> = []
    public var allowedAt: [Date] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
      case seen, lostAnchor, lastShownAt, shownDay, shownToday, messageDays, allowedAt
    }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      seen = try c.decodeIfPresent(Set<HintID>.self, forKey: .seen) ?? []
      lostAnchor = try c.decodeIfPresent(Set<HintID>.self, forKey: .lostAnchor) ?? []
      lastShownAt = try c.decodeIfPresent(Date.self, forKey: .lastShownAt)
      shownDay = try c.decodeIfPresent(String.self, forKey: .shownDay)
      shownToday = max(0, try c.decodeIfPresent(Int.self, forKey: .shownToday) ?? 0)
      messageDays = try c.decodeIfPresent(Set<String>.self, forKey: .messageDays) ?? []
      allowedAt = try c.decodeIfPresent([Date].self, forKey: .allowedAt) ?? []
    }
    public mutating func recordShown(at now: Date, day: String) {
      if shownDay != day { shownDay = day; shownToday = 0 }
      shownToday += 1
      lastShownAt = now
    }
    public mutating func finish(_ id: HintID, anchorDisappeared: Bool = false) {
      guard !seen.contains(id) else { return }
      if anchorDisappeared, lostAnchor.insert(id).inserted { return }
      seen.insert(id)
    }
    public mutating func recordMessage(on day: String) {
      messageDays.insert(day)
      // Only the fact that two different days exist matters; keep no growing activity log.
      messageDays = Set(messageDays.sorted().suffix(2))
    }
    public mutating func recordAllow(at now: Date) {
      allowedAt = allowedAt.filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 86_400 }
      allowedAt.append(now)
      allowedAt = Array(allowedAt.suffix(3))
    }
    public func recentAllows(at now: Date) -> Int {
      allowedAt.filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 86_400 }.count
    }
  }

  public struct State: Equatable, Sendable {
    public var now: Date
    public var launchedAt: Date
    /// A local-calendar day identifier supplied by the caller; policy never guesses a timezone.
    public var day: String
    public var history = History()
    public var enabled = true
    public var current: HintID?
    public var anchors: Set<HintID> = []
    public var isKeyWindow = false
    public var replying = false
    public var approvalWaiting = false
    public var questionWaiting = false
    public var composerHasText = false
    public var lastInteractionAt: Date?
    public var sheetOpen = false
    public var menuOpen = false
    public var popoverOpen = false
    public var setupShowing = false
    /// Existing chat evidence makes the first-message gate work for upgraded installations.
    public var hasMessages = false
    public var besideEnabled = true
    public var leftFullForTabAt: Date?
    public var messagesInWindow = 0
    public var besidePageSince: Date?
    public var guideBesideVisible = false
    public var barUsed = false
    public var taskFinishedWhileVisible = false
    public var sereinVisible = false
    public var everyStep = true
    public var turnEndedAfterAllows = false
    public var checkInsOff = true
    public init(now: Date, launchedAt: Date, day: String) {
      self.now = now; self.launchedAt = launchedAt; self.day = day
    }
  }

  /// Conditions which hide an already visible tip, as well as blocking the next one.
  public static func blocked(_ s: State) -> Bool {
    !s.enabled || !s.isKeyWindow || s.replying || s.approvalWaiting || s.questionWaiting
      || s.composerHasText || s.sheetOpen || s.menuOpen || s.popoverOpen || s.setupShowing
      || (!s.hasMessages && s.messagesInWindow == 0 && s.history.messageDays.isEmpty)
      || s.now.timeIntervalSince(s.launchedAt) < launchDelay
      || s.lastInteractionAt.map { s.now.timeIntervalSince($0) < inputDelay } == true
  }

  public static func triggered(_ id: HintID, _ s: State) -> Bool {
    switch id {
    case .sereinRow:
      return !s.besideEnabled && s.messagesInWindow >= 1
        && s.leftFullForTabAt.map { s.now.timeIntervalSince($0) >= 5 } == true
    case .beside:
      return !s.guideBesideVisible
        && s.besidePageSince.map { s.now.timeIntervalSince($0) >= 1 } == true
    case .optionSpace: return s.messagesInWindow >= 3 && !s.barUsed
    case .taskDone: return s.taskFinishedWhileVisible && s.sereinVisible
    case .asksBefore:
      return s.everyStep && s.history.recentAllows(at: s.now) >= 3 && s.turnEndedAfterAllows
    case .checkIns: return s.checkInsOff && s.history.messageDays.count >= 2
    }
  }

  public enum PresentationEnd: Equatable, Sendable { case seen, anchorLost, interrupted }

  /// Timer expiry wins over a simultaneous anchor/context transition. Interruptions before
  /// eight seconds consume their shown slot, but are not an explicit dismissal or completed read.
  public static func ending(_ s: State, presentedAt: Date?) -> PresentationEnd? {
    guard let id = s.current else { return nil }
    if let at = presentedAt, s.now.timeIntervalSince(at) >= visibleDuration { return .seen }
    if !s.anchors.contains(id) { return .anchorLost }
    if blocked(s) || !triggered(id, s) { return .interrupted }
    return nil
  }

  /// One future deadline, never a repeating poll. Calendar-aware midnight is supplied by the UI.
  public static func nextWake(_ s: State, presentedAt: Date?, nextDay: Date?) -> Date? {
    guard s.enabled else { return nil }
    if s.current != nil, let at = presentedAt { return at.addingTimeInterval(visibleDuration) }
    guard s.isKeyWindow, !s.replying, !s.approvalWaiting, !s.questionWaiting,
      !s.composerHasText, !s.sheetOpen, !s.menuOpen, !s.popoverOpen, !s.setupShowing,
      s.hasMessages || s.messagesInWindow > 0 || !s.history.messageDays.isEmpty,
      !s.anchors.subtracting(s.history.seen).isEmpty else { return nil }
    var deadlines = [s.launchedAt.addingTimeInterval(launchDelay)]
    if let at = s.lastInteractionAt { deadlines.append(at.addingTimeInterval(inputDelay)) }
    if let at = s.history.lastShownAt { deadlines.append(at.addingTimeInterval(spacing)) }
    if let at = s.leftFullForTabAt { deadlines.append(at.addingTimeInterval(5)) }
    if let at = s.besidePageSince { deadlines.append(at.addingTimeInterval(1)) }
    if s.history.shownDay == s.day, s.history.shownToday >= dailyLimit, let nextDay {
      deadlines.append(nextDay)
    }
    return deadlines.filter { $0 > s.now }.min()
  }

  public static func next(_ s: State) -> HintID? {
    guard s.current == nil, !blocked(s),
      s.history.shownDay != s.day || s.history.shownToday < dailyLimit,
      s.history.lastShownAt.map({ s.now.timeIntervalSince($0) >= spacing }) ?? true
    else { return nil }
    return HintID.allCases.first {
      !s.history.seen.contains($0) && s.anchors.contains($0) && triggered($0, s)
    }
  }
}
