import AppKit
import OSLog
import SwiftUI

/// Brings a chat's older messages in as the person scrolls up, ahead of them, so the reader never
/// meets an edge or a wait. Pages are built by `EarlierPages`, in blank space above what is built,
/// so a page moves nothing and costs the same deep in a chat as at its end. While the scroll rests,
/// pages build one after another, a run-loop turn each, until `lead` points are built above the
/// view; a reader closing on the top mid-scroll gets a page at once, from the scroll that asks.
/// Back at the end for a while, the chat lets the older messages go again.
@MainActor final class EarlierPager {
  /// While the scroll rests, pages build until this much is built above the view: three screens.
  static let lead: CGFloat = 2_400
  /// Nearer the top than this, a page builds at once, even mid-scroll.
  static let urgent: CGFloat = 900
  /// How long the scroll rests before pages build: a little over two frames, so a page starts
  /// while the processor is still at speed from the scroll (after a longer pause the first
  /// page runs much slower).
  static let restMilliseconds = 40
  static let rest: DispatchTimeInterval = .milliseconds(restMilliseconds)
  /// At most this many messages a page; its time budget usually stops it sooner (`EarlierPages`).
  static let restingPage = 6
  static let urgentPage = 4
  /// Within this of the end counts as back at the end; after `letGoAfter` there, the older messages go.
  static let atEnd: CGFloat = 40
  static let letGoAfter: DispatchTimeInterval = .seconds(2)
  private static let log = Logger(subsystem: "app.serein", category: "chat-paging")
  private static let signposter = OSSignposter(subsystem: "app.serein", category: "chat-paging")
  #if DEBUG
    /// Each page built, for the checks: how many messages, how long from the request until they
    /// are laid out and drawn for the next frame, and whether the scroll was resting.
    static var built: [(count: Int, ms: Double, resting: Bool)] = []
  #endif

  /// Builds up to that many older messages now, ready for the next frame; how many it built.
  var build: ((Int) -> Int)?
  /// Goes back to the newest messages only.
  var letGo: (() -> Void)?
  /// Whether any older message is built.
  var hasBuilt: (() -> Bool)?
  /// Reads where the top of what is built sits again, after a page or a resize.
  var refresh: (() -> Void)?
  /// While the region's height moves, no page builds.
  var paused = false
  weak var scrollView: NSScrollView?
  private var near = false
  private var urgent = false
  /// The person has scrolled toward the top, or the chat has settled after opening (`arm`).
  private var armed = false
  private var lastTop: CGFloat?
  /// When the reader last scrolled; pages chain without waiting only once the scroll has rested.
  private var lastScroll: UInt64 = 0
  private var resting: DispatchWorkItem?
  private var leaving: DispatchWorkItem?
  private var hold: ReadingPositionHold?

  /// Each reading of where the top of what is built sits: its edge in the scroll view, negative
  /// above it. `byReader` readings come from the scroll; the others follow a page or a resize.
  func reading(rowBottom y: CGFloat, byReader: Bool = true) {
    defer { lastTop = y }
    if byReader { lastScroll = DispatchTime.now().uptimeNanoseconds }
    watchEnd()
    near = y >= -Self.lead
    urgent = y >= -Self.urgent
    guard near else {
      if byReader { armed = true }
      resting?.cancel()
      return
    }
    // The top coming down the view is the person scrolling up.
    if byReader, let lastTop, y > lastTop + 0.5 { armed = true }
    guard armed else { return }
    if urgent {
      request(Self.urgentPage, resting: false)
    } else if !byReader, rested {
      request(Self.restingPage, resting: true)
    } else {
      afterRest()
    }
  }

  private var rested: Bool {
    DispatchTime.now().uptimeNanoseconds - lastScroll >= UInt64(Self.restMilliseconds) * 1_000_000
  }
  /// The scroll has rested since the reader last moved it.
  var isResting: Bool { rested }

  /// Back at the end with pages built: they go once the reader has stayed there `letGoAfter`.
  private func watchEnd() {
    guard hasBuilt?() == true, let scroll = scrollView, let document = scroll.documentView else { return }
    guard document.frame.height - scroll.contentView.bounds.maxY <= Self.atEnd else {
      leaving?.cancel()
      leaving = nil
      return
    }
    // From arriving at the end: a reply streaming in there does not put it off.
    guard leaving == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.leaving = nil
      self?.releaseEarlier()
    }
    leaving = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.letGoAfter, execute: work)
  }

  private func releaseEarlier() {
    guard hasBuilt?() == true, hold == nil, !paused, let letGo, let scroll = scrollView else { return }
    // Still at the end: the end stays put as the rows above go.
    guard let document = scroll.documentView, document.frame.height - scroll.contentView.bounds.maxY <= Self.atEnd else { return }
    // The rows above going moves the top down the view: not the person scrolling up.
    armed = false
    lastTop = nil
    resting?.cancel()
    if let hold = ReadingPositionHold(scroll) {
      self.hold = hold
      hold.whenDrawn { [weak self] in self?.hold = nil }
    }
    letGo()
    Self.log.debug("Let the earlier messages go at the end of the chat")
  }

  /// After the chat's opening: pages may build ahead of the reader from now on, at rest.
  func arm() {
    armed = true
    refresh?()
  }

  /// A page now (Show earlier messages, from the keyboard or VoiceOver).
  func request() {
    armed = true
    request(Self.restingPage, resting: true)
  }

  private func afterRest() {
    resting?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.near, self.armed else { return }
      self.request(Self.restingPage, resting: true)
    }
    resting = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.rest, execute: work)
  }

  private func request(_ count: Int, resting: Bool) {
    guard !paused, hold == nil, let build else { return }
    self.resting?.cancel()
    let started: UInt64 = DispatchTime.now().uptimeNanoseconds
    let interval = Self.signposter.beginInterval("Earlier page", "\(count) messages")
    let made = build(count)
    Self.signposter.endInterval("Earlier page", interval)
    guard made > 0 else { return }
    finished(count: made, ms: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000, resting: resting)
  }

  private func finished(count: Int, ms: Double, resting: Bool) {
    #if DEBUG
      Self.built.append((count, ms, resting))
    #endif
    Self.log.debug("Built \(count) earlier messages in \(ms, format: .fixed(precision: 2)) ms, resting: \(resting)")
    // The next page in the next turn, while the reader is close or the scroll rests: a reading
    // of the new top decides.
    DispatchQueue.main.async { [weak self] in self?.refresh?() }
  }
}

/// For the frame that builds older messages above the reader, the chat's scroll view keeps its
/// distance from the end, so nothing on screen moves. SwiftUI keeps the distance from the top
/// instead, which would push the reading down by the height of the new messages. The scroll is
/// put back as the document grows, before the frame is drawn. The reader's own scrolling while a
/// page builds moves the distance kept, so no scroll is lost.
@MainActor final class ReadingPositionHold {
  private let scroll: NSScrollView
  private let document: NSView
  /// From the bottom of the view to the end of the chat, as of the last scroll.
  private var fromEnd: CGFloat
  private let watching = HoldRegistrations()
  private var grew = false
  private var turns = 0

  init?(_ scroll: NSScrollView) {
    // SwiftUI's scroll document is flipped: its top is y = 0.
    guard let document = scroll.documentView, document.isFlipped else { return nil }
    self.scroll = scroll
    self.document = document
    fromEnd = document.frame.height - scroll.contentView.bounds.maxY
    document.postsFrameChangedNotifications = true
    scroll.contentView.postsBoundsChangedNotifications = true
    let center = NotificationCenter.default
    watching.tokens = [
      // Posted once the new height is set: `fromEnd` still holds the distance before it.
      center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.resized() }
      },
      center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.scrolled() }
      },
    ]
  }

  private func resized() {
    grew = true
    restore()
  }
  private func scrolled() { fromEnd = document.frame.height - scroll.contentView.bounds.maxY }

  /// Calls `done` at the end of the run loop turn that drew the new messages: after Core
  /// Animation's commit (order 2,000,000). SwiftUI may build them a turn later, so a turn with no
  /// growth waits, up to three.
  func whenDrawn(_ done: @escaping () -> Void) {
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) {
      [weak self] observer, _ in
      MainActor.assumeIsolated {
        guard let self else {
          CFRunLoopObserverInvalidate(observer)
          return
        }
        self.turns += 1
        guard self.grew || self.turns >= 3 else { return }
        self.stop()
        done()
      }
    }
    watching.turnEnd = observer
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  private func restore() {
    let clip: NSClipView = scroll.contentView
    let bounds: NSRect = clip.bounds
    let wanted = NSRect(x: bounds.minX, y: document.frame.height - fromEnd - bounds.height, width: bounds.width, height: bounds.height)
    let origin: NSPoint = clip.constrainBoundsRect(wanted).origin
    guard abs(origin.y - bounds.minY) > 0.25 else { return }
    clip.scroll(to: origin)
    scroll.reflectScrolledClipView(clip)
  }

  private func stop() { watching.end() }
}

/// What a hold listens with, ended when the page is drawn or, if the chat goes first, as the hold
/// goes away.
private final class HoldRegistrations {
  var tokens: [NSObjectProtocol] = []
  var turnEnd: CFRunLoopObserver?
  func end() {
    tokens.forEach(NotificationCenter.default.removeObserver)
    tokens = []
    if let turnEnd { CFRunLoopObserverInvalidate(turnEnd) }
    turnEnd = nil
  }
  deinit { end() }
}
