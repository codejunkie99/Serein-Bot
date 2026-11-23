import Foundation

/// First-day guidance, independent of views, providers and persistence. Completing a button's
/// action never ticks it: only the corresponding event does.
public struct SereinGuide: Codable, Equatable, Sendable {
  public static let defaultsKey = "serein.guide"
  public static let barUsedKey = "serein.bar.used"
  public enum Item: String, CaseIterable, Codable, Identifiable, Sendable {
    case ask, beside, `do`, anywhere, asks
    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .ask: return "Ask Serein something"
      case .beside: return "Keep Serein beside your work"
      case .do: return "Have Serein do something"
      case .anywhere: return "Ask from any app"
      case .asks: return "Choose what Serein asks about"
      }
    }
  }
  public enum Event: Equatable, Sendable {
    case messageReached, besideRendered
    case reminderCreated, watchCreated, macStepStarted, taskStarted
    case barSent, barHeld
    case approvalChoiceConfirmed, approvalChoiceKept
    public var item: Item {
      switch self {
      case .messageReached: return .ask
      case .besideRendered: return .beside
      case .reminderCreated, .watchCreated, .macStepStarted, .taskStarted: return .do
      case .barSent, .barHeld: return .anywhere
      case .approvalChoiceConfirmed, .approvalChoiceKept: return .asks
      }
    }
  }
  public enum Presentation: Equatable, Sendable {
    case hidden, expanded, collapsed, completed
  }
  public enum Anywhere: Equatable, Sendable {
    case off, on, taken
  }

  public private(set) var done: Set<Item>
  public private(set) var hidden: Bool
  /// The last displayed layout, recomputed for the current chat when it is shown again.
  public private(set) var collapsed: Bool
  public private(set) var firstShownAt: Date?
  public init(done: Set<Item> = [], hidden: Bool = false, collapsed: Bool = false, firstShownAt: Date? = nil) {
    self.done = done
    self.hidden = hidden
    self.collapsed = collapsed
    self.firstShownAt = firstShownAt
  }
  private enum CodingKeys: String, CodingKey { case done, hidden, collapsed, firstShownAt }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    done = Set((try values.decodeIfPresent([String].self, forKey: .done) ?? []).compactMap(Item.init(rawValue:)))
    hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    collapsed = try values.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    firstShownAt = try values.decodeIfPresent(Date.self, forKey: .firstShownAt)
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(Item.allCases.filter(done.contains).map(\.rawValue), forKey: .done)
    try values.encode(hidden, forKey: .hidden)
    try values.encode(collapsed, forKey: .collapsed)
    try values.encodeIfPresent(firstShownAt, forKey: .firstShownAt)
  }

  public var count: Int { done.count }
  public var complete: Bool { done.count == Item.allCases.count }
  public var firstUndone: Item? { Item.allCases.first { !done.contains($0) } }
  public var heading: String { "Get started · \(count) of 5 done" }
  public static let completedLine = "You are all set. Help › Getting Started brings this back."
  public static let hideHelp = "Hide the guide. Help › Getting Started brings it back."
  public static let hiddenToast = "The guide is hidden. Help › Getting Started brings it back."

  /// Called on the first load only, before a persisted guide exists. Turning the global bar on
  /// alone is not evidence that the user has tried it, and a migrated approval default is not a choice.
  public mutating func preTick(transcriptNotEmpty: Bool, barEnabled: Bool, barUsed: Bool, approvalsUserSet: Bool) {
    if transcriptNotEmpty { done.insert(.ask) }
    if barEnabled && barUsed { done.insert(.anywhere) }
    if approvalsUserSet { done.insert(.asks) }
  }
  @discardableResult public mutating func record(_ event: Event) -> Bool { done.insert(event.item).inserted }
  /// A completed card remains for the rest of the launch in which the last event arrived.
  public mutating func beginLaunch() { if complete { hidden = true } }
  public mutating func hide() { hidden = true }
  public mutating func showAgain() { hidden = false; collapsed = false }
  public mutating func shown(_ presentation: Presentation, at now: Date) {
    guard presentation != .hidden else { return }
    if firstShownAt == nil { firstShownAt = now }
    collapsed = presentation == .collapsed
  }
  public func presentation(connected: Bool, inChat: Bool = true, inBar: Bool = false,
                           hasMessages: Bool = false, isWorking: Bool = false,
                           hasPendingQuestion: Bool = false) -> Presentation {
    guard connected, inChat, !inBar, !hidden else { return .hidden }
    if complete { return .completed }
    // A saved collapsed layout is a snapshot, not a permanent dismissal: a new empty chat can
    // show the full guide again. Pending approvals leave its compact line visible.
    return hasMessages || isWorking || hasPendingQuestion ? .collapsed : .expanded
  }
  public static func subtitle(_ item: Item, anywhere: Anywhere = .off, riskyOnly: Bool = false,
                              shortcut: String = "⌥Space") -> String {
    switch item {
    case .ask: return "Type a question, or try one."
    case .beside: return "Open any page. Serein moves to the side. ⌘J switches between full and beside."
    case .do: return "Try “Remind me at 5 pm to stretch”. Bigger jobs run as tasks while you keep going."
    case .anywhere:
      switch anywhere {
      case .on: return "Press \(shortcut) in any app. Hold it to talk."
      case .off: return "Turn on \(shortcut) to ask Serein from any app."
      case .taken: return "Another app uses \(shortcut)."
      }
    case .asks:
      return riskyOnly ? "Serein asks only before risky steps, like sending or buying."
        : "Serein asks before every step. You can let it do routine steps on its own."
    }
  }
  public static func button(_ item: Item, anywhere: Anywhere = .off, shortcut: String = "⌥Space") -> String {
    switch item {
    case .ask: return "Try “What can you do?”"
    case .beside: return "Open a page"
    case .do: return "Try it"
    case .anywhere:
      switch anywhere {
      case .on: return "Show me"
      case .off: return "Turn on \(shortcut)"
      case .taken: return "Use ⌃⌥Space"
      }
    case .asks: return "Choose"
    }
  }
}
