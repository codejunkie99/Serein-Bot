import AppKit
import SereinCore
import SwiftUI

/// One occasional tip across the main window. Eligibility changes arrive as events; a single
/// cancellable deadline handles waiting and expiry, with no repeating timer or animation.
@MainActor final class HintCenter: ObservableObject {
  static let shared = HintCenter()
  static let enabledKey = "serein.hints.enabled"
  static let seenKey = "serein.hints.seen"
  static let lastShownKey = "serein.hints.lastShownAt"
  static let shownTodayKey = "serein.hints.shownToday"

  struct Context: Equatable {
    var isKeyWindow = false
    var replying = false
    var approvalWaiting = false
    var questionWaiting = false
    var composerHasText = false
    var sheetOpen = false
    var menuOpen = false
    var popoverOpen = false
    var setupShowing = false
    var hasMessages = false
    var besideEnabled = true
    var isBesideWebPage = false
    var isSereinFull = false
    var isOnTab = false
    var sereinVisible = false
    var guideBesideVisible = false
    var optionSpaceEnabled = false
    var barUsed = false
    var everyStep = true
    var checkInsOff = true
  }
  /// Hosts route these through the same controls and consent flows used by Settings/the guide.
  struct Actions {
    var turnOnOptionSpace: @MainActor () -> Void = {}
    var chooseApprovals: @MainActor () -> Void = {}
    var turnOnCheckIns: @MainActor () -> Void = {}
  }
  var actions = Actions()
  @Published private(set) var finishedTaskID: String?
  @Published private(set) var current: HintID?
  @Published private(set) var context = Context()
  @Published var enabled: Bool {
    didSet {
      guard enabled != oldValue else { return }
      if persists { defaults.set(enabled, forKey: Self.enabledKey) }
      evaluate()
    }
  }
  private let defaults: UserDefaults
  private let persists: Bool
  private let launchedAt: Date
  private var history = HintPolicy.History()
  private var anchors = Set<HintID>()
  private var messagesInWindow = 0
  #if DEBUG
  /// Runtime checks observe accepted sends without injecting events or writing teaching state.
  var messageEvidenceForChecks: (inWindow: Int, days: Set<String>) { (messagesInWindow, history.messageDays) }
  #endif
  private var lastInteractionAt: Date?
  private var leftFullForTabAt: Date?
  private var besidePageSince: Date?
  private var taskFinishedWhileVisible = false
  private var turnEndedAfterAllows = false
  private var presentedAt: Date?
  private var wake: Task<Void, Never>?
  private var previewID: HintID?

  init(defaults: UserDefaults = .standard, now: Date = Date()) {
    self.defaults = defaults
    persists = RelayOrchestrator.persists
    launchedAt = now
    // Fixtures show the default enabled setting without inheriting personal teaching state.
    enabled = persists ? defaults.object(forKey: Self.enabledKey) as? Bool ?? true : true
    if persists {
      if let data = defaults.data(forKey: Self.seenKey),
        let saved = try? JSONDecoder().decode(HintPolicy.History.self, from: data) {
        history = saved
      } else if let names = defaults.stringArray(forKey: Self.seenKey) {
        history.seen = Set(names.compactMap(HintID.init(rawValue:)))
      }
      if let date = defaults.object(forKey: Self.lastShownKey) as? Date { history.lastShownAt = date }
      if let daily = defaults.dictionary(forKey: Self.shownTodayKey) {
        history.shownDay = daily["day"] as? String
        history.shownToday = max(0, daily["count"] as? Int ?? 0)
      }
    } else {
      // Suppress unsolicited fixture tips; an explicit preview still selects its requested tip.
      history.seen = Set(HintID.allCases)
    }
  }

  func update(context next: Context, now: Date = Date()) {
    guard context != next else { return }
    if context.isSereinFull && next.isOnTab && !next.besideEnabled { leftFullForTabAt = now }
    if !next.isOnTab || next.besideEnabled { leftFullForTabAt = nil }
    if next.isBesideWebPage && !context.isBesideWebPage { besidePageSince = now }
    if !next.isBesideWebPage { besidePageSince = nil }
    if context.replying && !next.replying { turnEndedAfterAllows = true }
    if context.composerHasText != next.composerHasText { lastInteractionAt = now }
    context = next
    evaluate(now: now)
  }
  func updateAnchors(_ visible: Set<HintID>) {
    guard anchors != visible else { return }
    anchors = visible
    evaluate()
  }
  /// Call once a message reaches Serein, not while a disconnected/offline message is held.
  func recordMessage(inWindow: Bool = true, now: Date = Date()) {
    if inWindow { messagesInWindow += 1 }
    history.recordMessage(on: Self.day(now))
    lastInteractionAt = now
    save()
    evaluate(now: now)
  }
  /// Composer edits and sends delay teaching until the person has been idle for three seconds.
  func recordInteraction(now: Date = Date()) {
    lastInteractionAt = now
    evaluate(now: now)
  }
  func recordTaskFinished(threadID: String, now: Date = Date()) {
    guard context.sereinVisible, !context.replying, !context.approvalWaiting, !context.questionWaiting,
      !context.composerHasText, context.isKeyWindow, !context.sheetOpen, !context.menuOpen,
      !context.popoverOpen, !context.setupShowing,
      lastInteractionAt.map({ now.timeIntervalSince($0) >= HintPolicy.inputDelay }) ?? true
    else { return }
    finishedTaskID = threadID
    taskFinishedWhileVisible = true
    evaluate(now: now)
  }
  func recordAllowedStep(now: Date = Date()) {
    history.recordAllow(at: now)
    turnEndedAfterAllows = false
    save()
    evaluate(now: now)
  }
  func recordTurnEnded(now: Date = Date()) {
    turnEndedAfterAllows = true
    evaluate(now: now)
  }
  func recordBarUsed() {
    var next = context; next.barUsed = true
    update(context: next)
  }
  func showTipsAgain() {
    wake?.cancel(); wake = nil
    current = nil; presentedAt = nil; previewID = nil
    history.seen = []; history.lostAnchor = []
    save()
    ToastCenter.shared.show("Tips will show again.")
    evaluate()
  }
  /// A requested preview bypasses trigger timing and rate limits, never safety/attention guards.
  func preview(_ id: HintID?) {
    guard !persists else { return }
    wake?.cancel(); wake = nil
    current = nil; presentedAt = nil
    previewID = id
    evaluate()
  }
  func dismiss() {
    finish()
    previewID = nil
    evaluate()
  }
  func performPrimary() {
    guard let id = current else { return }
    let optionSpaceWasEnabled = context.optionSpaceEnabled
    finish()
    previewID = nil
    switch id {
    case .optionSpace where !optionSpaceWasEnabled: actions.turnOnOptionSpace()
    case .asksBefore: actions.chooseApprovals()
    case .checkIns: actions.turnOnCheckIns()
    default: break
    }
    evaluate()
  }
  var words: String {
    guard let current else { return "" }
    switch current {
    case .sereinRow: return "Serein stays here. Click it to show Serein full, or press ⌘E to ask from this tab."
    case .beside: return "Serein stays beside this view. Press ⌘J to make it full."
    case .optionSpace:
      return context.optionSpaceEnabled
        ? "Ask from any app: press ⌥Space. Hold it to talk."
        : "Ask Serein from any app with ⌥Space."
    case .taskDone: return "Finished work stays here for a day, and in History › Activity after that."
    case .asksBefore: return "Approving every step? You can let Serein do routine steps on its own. It still asks before it sends, buys or deletes anything."
    case .checkIns: return "Serein can speak first: a morning brief at 9 and a check-in every few hours. Each uses some of your AI app’s usage."
    }
  }
  var primaryTitle: String {
    switch current {
    case .optionSpace? where !context.optionSpaceEnabled: return "Turn on ⌥Space"
    case .asksBefore?: return "Choose"
    case .checkIns?: return "Turn on"
    default: return "Got it"
    }
  }
  var secondaryTitle: String? {
    switch current {
    case .optionSpace? where !context.optionSpaceEnabled: return "Not now"
    case .checkIns?: return "Not now"
    case .asksBefore?: return "Keep asking"
    default: return nil
    }
  }

  private func state(now: Date) -> HintPolicy.State {
    var s = HintPolicy.State(now: now, launchedAt: launchedAt, day: Self.day(now))
    s.history = history; s.enabled = enabled; s.current = current; s.anchors = anchors
    s.isKeyWindow = context.isKeyWindow; s.replying = context.replying
    s.approvalWaiting = context.approvalWaiting; s.questionWaiting = context.questionWaiting
    s.composerHasText = context.composerHasText; s.lastInteractionAt = lastInteractionAt
    s.sheetOpen = context.sheetOpen; s.menuOpen = context.menuOpen; s.popoverOpen = context.popoverOpen
    s.setupShowing = context.setupShowing; s.hasMessages = context.hasMessages
    s.besideEnabled = context.besideEnabled
    s.leftFullForTabAt = leftFullForTabAt; s.messagesInWindow = messagesInWindow
    s.besidePageSince = besidePageSince; s.guideBesideVisible = context.guideBesideVisible
    s.barUsed = context.barUsed; s.taskFinishedWhileVisible = taskFinishedWhileVisible
    s.sereinVisible = context.sereinVisible; s.everyStep = context.everyStep
    s.turnEndedAfterAllows = turnEndedAfterAllows; s.checkInsOff = context.checkInsOff
    if previewID != nil {
      s.enabled = true; s.hasMessages = true
      s.launchedAt = now.addingTimeInterval(-HintPolicy.launchDelay)
      s.lastInteractionAt = nil
    }
    return s
  }
  private func evaluate(now: Date = Date()) {
    wake?.cancel(); wake = nil
    var s = state(now: now)
    if let id = current {
      if previewID != nil {
        if !anchors.contains(id) || HintPolicy.blocked(s) { finish(markSeen: false) }
      } else if let end = HintPolicy.ending(s, presentedAt: presentedAt) {
        switch end {
        case .seen: finish()
        case .anchorLost: finish(anchorDisappeared: true)
        case .interrupted: finish(markSeen: false)
        }
      }
      s = state(now: now)
    }
    if current == nil {
      let next: HintID?
      if let previewID {
        next = !HintPolicy.blocked(s) && anchors.contains(previewID) ? previewID : nil
      } else { next = HintPolicy.next(s) }
      if let next {
        current = next; presentedAt = now
        if previewID == nil { history.recordShown(at: now, day: s.day); save() }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
          userInfo: [.announcement: words + " " + primaryTitle,
                     .priority: NSAccessibilityPriorityLevel.medium.rawValue])
      }
    }
    schedule(now: now)
  }
  private func finish(anchorDisappeared: Bool = false, markSeen: Bool = true) {
    guard let id = current else { return }
    if previewID == nil, markSeen { history.finish(id, anchorDisappeared: anchorDisappeared); save() }
    current = nil; presentedAt = nil
  }
  private func schedule(now: Date) {
    guard previewID == nil else { return }
    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))
    if let date = HintPolicy.nextWake(state(now: now), presentedAt: presentedAt, nextDay: tomorrow) {
      schedule(at: date, now: now)
    }
  }
  private func schedule(at date: Date, now: Date) {
    let delay = max(0.05, min(86_400, date.timeIntervalSince(now)))
    wake = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.evaluate()
    }
  }
  private func save() {
    guard persists else { return }
    if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.seenKey) }
    if let date = history.lastShownAt { defaults.set(date, forKey: Self.lastShownKey) }
    let daily: [String: Any] = ["day": history.shownDay ?? "", "count": history.shownToday]
    defaults.set(daily, forKey: Self.shownTodayKey)
  }
  private static func day(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.era, .year, .month, .day], from: date)
    return String(format: "%d-%04d-%02d-%02d", c.era ?? 1, c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}

struct HintAnchorKey: PreferenceKey {
  struct Value {
    var targets: [HintID: Anchor<CGRect>] = [:]
    var viewports: [HintID: Anchor<CGRect>] = [:]
  }
  static var defaultValue: Value { Value() }
  static func reduce(value: inout Value, nextValue: () -> Value) {
    let next = nextValue()
    value.targets.merge(next.targets, uniquingKeysWith: { _, newest in newest })
    value.viewports.merge(next.viewports, uniquingKeysWith: { _, newest in newest })
  }
}
extension View {
  func sereinHintAnchor(_ id: HintID) -> some View {
    anchorPreference(key: HintAnchorKey.self, value: .bounds) { HintAnchorKey.Value(targets: [id: $0]) }
  }
}

/// Mount once over the shell. Empty regions pass through clicks; only the bubble is interactive.
struct CoachMarkLayer: View {
  @ObservedObject var center: HintCenter
  var anchors: [HintID: Anchor<CGRect>]
  var viewports: [HintID: Anchor<CGRect>]
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sereinReducedEffects) private var reducedEffects
  @State private var bubbleSize = CGSize(width: 280, height: 160)

  var body: some View {
    GeometryReader { geometry in
      let bounds = CGRect(origin: .zero, size: geometry.size)
      let visible = Set(anchors.compactMap { id, anchor in
        // A transcript target can remain inside the window after scrolling underneath the
        // fixed header/composer. Its actual scroll viewport, not the shell, determines visibility.
        let available = viewports[id].map { bounds.intersection(geometry[$0]) } ?? bounds
        return available.intersects(geometry[anchor]) ? id : nil
      })
      ZStack(alignment: .topLeading) {
        if let id = center.current, let anchor = anchors[id], visible.contains(id) {
          let target = geometry[anchor]
          let width = min(280.0, max(1, geometry.size.width - 24))
          let below = target.maxY + bubbleSize.height + 8 <= geometry.size.height - 12
          let x = max(12, min(target.midX - width / 2, geometry.size.width - width - 12))
          let proposedY = below ? target.maxY + 8 : target.minY - bubbleSize.height - 8
          let y = max(12, min(proposedY, geometry.size.height - bubbleSize.height - 12))
          VStack(spacing: 0) {
            if below { arrow(target: target.midX - x, width: width, down: false) }
            VStack(alignment: .leading, spacing: 14) {
              Text(center.words).font(UIStyle.body).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                  secondaryButton
                  Spacer(minLength: 0)
                  primaryButton
                }
                VStack(alignment: .trailing, spacing: 8) {
                  primaryButton
                  secondaryButton
                }.frame(maxWidth: .infinity, alignment: .trailing)
              }
            }.padding(16).frame(width: width)
              .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
              .accessibilityElement(children: .contain)
            if !below { arrow(target: target.midX - x, width: width, down: true) }
          }
          .background(GeometryReader { proxy in
            Color.clear.onAppear { bubbleSize = proxy.size }
              .onChange(of: proxy.size) { _, size in bubbleSize = size }
          })
          .offset(x: x, y: y)
          .id(id)
          .transition(reduceMotion || reducedEffects ? .identity : .opacity)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion || reducedEffects ? nil : .easeInOut(duration: 0.15), value: center.current)
        .onAppear { center.updateAnchors(visible) }
        .onChange(of: visible) { _, ids in center.updateAnchors(ids) }
        .onDisappear { center.updateAnchors([]) }
    }
  }
  private var primaryButton: some View {
    Button(center.primaryTitle) { center.performPrimary() }.buttonStyle(PrimaryButton())
  }
  @ViewBuilder private var secondaryButton: some View {
    if let title = center.secondaryTitle {
      Button(title) { center.dismiss() }.buttonStyle(QuietButton())
    }
  }
  private func arrow(target: CGFloat, width: CGFloat, down: Bool) -> some View {
    HintArrow(down: down).fill(p.card).frame(width: 16, height: 8)
      .offset(x: min(max(12, target), width - 12) - width / 2)
      .frame(width: width).accessibilityHidden(true)
  }
}
private struct HintArrow: Shape {
  var down: Bool
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: down ? rect.minY : rect.maxY))
      path.addLine(to: CGPoint(x: rect.midX, y: down ? rect.maxY : rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: down ? rect.minY : rect.maxY))
      path.closeSubpath()
    }
  }
}
