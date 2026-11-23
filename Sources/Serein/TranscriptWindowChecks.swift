import AppKit
import SereinCore
import SwiftUI

#if DEBUG
/// A long thread in the real chat view, in a real window: it opens on its newest message, builds
/// only part of the thread, and a person scrolling up fast gets older messages ahead of them,
/// 95% of pages within 12 ms in a task chat and 10 ms in Serein's, and none over a frame (in an
/// optimized build), from the request to the commit that carries it, as deep in the chat as at its
/// end, without what they read moving or blank space showing. Show earlier messages is in the window and builds a page. The same for
/// Serein's own chat. Synthetic messages only.
@MainActor func checkTranscriptWindow() async throws {
  func check(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SereinError.invalid("Transcript window: " + label) }
    print("PASS: " + label)
  }
  TranscriptScrolling.overBudget = []
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("serein-window-" + UUID().uuidString)
  let browser = try BrowserModel(root: root)
  let agent = AgentModel(browser: browser, discoverProviders: false)
  defer {
    browser.shutdown()
    try? FileManager.default.removeItem(at: root)
  }
  let reply = String(repeating: "A synthetic reply with **some** markdown and `code` in it. ", count: 12)
  agent.messages = (0..<600).flatMap { turn in
    [AgentMessage(role: "you", text: "Synthetic question \(turn)"), AgentMessage(role: "assistant", text: "\(turn). \(reply)")]
  }

  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let host = NSHostingView(rootView: ThreadWorkspace(browser: browser, agent: agent)
    .environment(\.palette, Palette.dusk).environment(\.sereinReducedEffects, true))
  let started = DispatchTime.now().uptimeNanoseconds
  window.contentView = host
  window.makeKeyAndOrderFront(nil)
  host.layoutSubtreeIfNeeded()
  host.displayIfNeeded()
  let opened = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
  try await TranscriptScrolling.settle(host)

  var scroll = try TranscriptScrolling.chat(in: host)
  let firstHeight = scroll.documentView?.frame.height ?? 0
  print("MEASURE: 1,200 messages opened in \(Int(opened)) ms, \(TranscriptScrolling.textViews(in: host)) text views, \(Int(firstHeight)) points tall")
  try check(TranscriptScrolling.belowView(scroll) <= 2, "a long thread opens on its newest message (\(Int(TranscriptScrolling.belowView(scroll))) points from the end)")
  try check(TranscriptScrolling.textViews(in: host) <= 200, "opening builds only the newest part of the thread")
  let openedTextViews = TranscriptScrolling.textViews(in: host)
  print("MEASURE: task chat: after opening, its nearest older messages were built in \(EarlierPages.warmups.map { String(format: "%.1f", $0) }.joined(separator: ", ")) ms (the first of each kind of row)")
  EarlierPages.warmups = []

  let reading = try await TranscriptScrolling.scrollUp(host, bursts: 10, steps: 8)
  try reading.report("task chat, read and scroll", budget: TranscriptScrolling.taskChatBudget, check)
  try check(reading.pages.allSatisfy(\.resting), "task chat: a reader who pauses never waits on a page mid-scroll")
  let fling = try await TranscriptScrolling.scrollUp(host, bursts: 1, steps: 160)
  try fling.report("task chat, one long fling", budget: TranscriptScrolling.taskChatBudget, check)
  try check(TranscriptScrolling.textViews(in: host) > openedTextViews, "scrolling up brings in older messages")
  try await TranscriptScrolling.backToEnd(host)
  try await Task.sleep(for: .milliseconds(2_600))
  try await TranscriptScrolling.settle(host)
  scroll = try TranscriptScrolling.chat(in: host)
  try check(TranscriptScrolling.textViews(in: host) <= TranscriptWindow.newest + 10, "back at the end, the task chat lets its older messages go")
  try check(TranscriptScrolling.belowView(scroll) <= 2, "letting them go leaves the end where it was")

  let previousLast = agent.messages.last?.id
  agent.conversationID = "synthetic-other-long"
  agent.messages = (0..<300).flatMap { turn in
    [AgentMessage(role: "you", text: "Other question \(turn)"), AgentMessage(role: "assistant", text: "\(turn). \(reply)")]
  }
  try await TranscriptScrolling.settle(host)
  scroll = try TranscriptScrolling.chat(in: host)
  // Following the end puts its marker at the foot of the view, above the chat's bottom padding.
  let atEnd: CGFloat = 26
  try check(TranscriptScrolling.belowView(scroll) <= atEnd, "another long thread opens on its newest message")
  try check(TranscriptScrolling.textViews(in: host) <= TranscriptWindow.newest + 10, "another thread starts from its newest messages again")
  try check(agent.messages.last?.id != previousLast, "the other thread is the one shown")

  agent.messages.append(AgentMessage(role: "you", text: "One more synthetic question"))
  try await Task.sleep(for: .milliseconds(100))
  agent.messages.append(AgentMessage(role: "assistant", text: reply + reply))
  try await TranscriptScrolling.settle(host)
  try check(TranscriptScrolling.belowView(try TranscriptScrolling.chat(in: host)) <= atEnd, "a new message at the end of a long thread stays in view")

  agent.conversationID = "synthetic-short"
  agent.messages = [AgentMessage(role: "you", text: "Only question"), AgentMessage(role: "assistant", text: "Only answer")]
  try await TranscriptScrolling.settle(host)
  scroll = try TranscriptScrolling.chat(in: host)
  let visible = scroll.documentVisibleRect
  let height = scroll.documentView?.frame.height ?? 0
  let atTop = scroll.documentView?.isFlipped == true ? visible.minY <= 2 : visible.maxY >= height - 2
  try check(atTop && height <= visible.height + 2, "a short chat still starts at the top of the view")
  try check(TranscriptScrolling.textViews(in: host) <= 4, "a short chat shows no earlier messages")

  // Serein's own chat: bubbles, a paragraph each, and short turns, so its newest 16 messages are
  // shorter than the lead and the first scroll up is what starts the pages.
  let paragraphs = [
    "Here is what I found.", "The first part is **done**, and the second waits on you.",
    "Want me to send it now, or keep it for later today?",
  ].joined(separator: "\n\n")
  let serein = (0..<500).flatMap { turn in
    [AgentMessage(role: "you", text: "Synthetic ask \(turn)"), AgentMessage(role: "assistant", text: "\(turn). " + paragraphs)]
  }
  let sereinHost = NSHostingView(rootView: RelayMessagesCheckHost(messages: serein)
    .environment(\.palette, Palette.dusk).environment(\.sereinReducedEffects, true))
  EarlierPager.built = []
  EarlierPages.warmups = []
  window.contentView = sereinHost
  try await TranscriptScrolling.settle(sereinHost)
  scroll = try TranscriptScrolling.chat(in: sereinHost)
  try check(TranscriptScrolling.belowView(scroll) <= 2, "Serein's long chat opens on its newest message")
  print("MEASURE: Serein's chat: after opening, its nearest older messages were built in \(EarlierPages.warmups.map { String(format: "%.1f", $0) }.joined(separator: ", ")) ms (the first of each kind of row); at rest it built \(EarlierPager.built.count) more")
  let sereinReading = try await TranscriptScrolling.scrollUp(sereinHost, bursts: 10, steps: 8)
  try sereinReading.report("Serein's chat, read and scroll", check)
  // Its newest 16 bubbles are shorter than the urgent distance: the first scroll up starts pages at
  // once, until the first rest builds ahead of the reader.
  let settled = sereinReading.pages.firstIndex(where: \.resting) ?? sereinReading.pages.count
  try check(sereinReading.pages[settled...].allSatisfy(\.resting), "Serein's chat: once it has built ahead, a reader who pauses never waits mid-scroll")
  let sereinFling = try await TranscriptScrolling.scrollUp(sereinHost, bursts: 1, steps: 160)
  try sereinFling.report("Serein's chat, one long fling", check)
  try check(TranscriptScrolling.textViews(in: sereinHost) > RelayMessagesCheckHost.newestTextViews,
            "scrolling up Serein's chat brings in older messages")
  try await TranscriptScrolling.backToEnd(sereinHost)
  try await Task.sleep(for: .milliseconds(2_600))
  try await TranscriptScrolling.settle(sereinHost)
  scroll = try TranscriptScrolling.chat(in: sereinHost)
  try check(TranscriptScrolling.textViews(in: sereinHost) <= RelayMessagesCheckHost.newestTextViews,
            "back at the end, Serein's chat lets its older messages go")
  try check(TranscriptScrolling.belowView(scroll) <= 2, "letting them go leaves Serein's chat at its end")

  // Show earlier messages, last: SwiftUI builds its accessibility only once it is asked for, as
  // VoiceOver does, and that would weigh on the pages measured above.
  TranscriptScrolling.accessibility(true)
  defer { TranscriptScrolling.accessibility(false) }
  try await TranscriptScrolling.pressEarlier(in: sereinHost, "Serein's chat, after letting them go", check)
  window.contentView = host
  agent.conversationID = "synthetic-third-long"
  agent.messages = (0..<300).flatMap { turn in
    [AgentMessage(role: "you", text: "Third question \(turn)"), AgentMessage(role: "assistant", text: "\(turn). \(reply)")]
  }
  try await TranscriptScrolling.settle(host)
  try await TranscriptScrolling.pressEarlier(in: host, "task chat, a newly opened thread", check)

  if TranscriptScrolling.timesPages {
    try check(TranscriptScrolling.overBudget.isEmpty,
              "95% of each scroll's pages are within \(Int(TranscriptScrolling.taskChatBudget)) ms in a task chat and \(Int(TranscriptScrolling.pageBudget)) ms in Serein's chat, and none takes longer than a frame (over:\(TranscriptScrolling.overBudget.joined(separator: "; ")))")
  } else {
    print("MEASURE: page times are held to the budget only in an optimized build (swift build -c release); this build is unoptimized")
  }
  let pages = EarlierPages()
  let many = (0..<100).map { AgentMessage(id: "m\($0)", role: "you", text: "") }
  try check(pages.liveStart(in: many, thread: "a", newest: TranscriptWindow.newest) == 70, "a chat draws its newest messages itself")
  try check(pages.liveStart(in: many, thread: "a", newest: 16) == 84, "a chat can draw fewer of them")
  try check(pages.height(thread: "a", older: 0) == 0, "a chat with nothing older has no region above")
  try check(pages.height(thread: "a", older: 70) <= EarlierPages.reach + 40, "the region's guess is bounded")
}

/// A person reading up a chat: scroll-wheel steps, as a trackpad sends them.
@MainActor enum TranscriptScrolling {
  /// One scroll up of the chat and what the pages cost on the way.
  struct Run {
    /// The largest move on screen that was not the scroll's own, read once the scroll had caught
    /// up with the wheel: what was read moved.
    let largestJump: CGFloat
    /// The most the scroll fell behind the wheel mid-scroll: steps sent and not yet applied.
    let largestLag: CGFloat
    /// Run-loop turns that built a page, from waking until the frame was committed: the page and
    /// the drawing that follows it in the same turn.
    let pageTurns: [Double]
    /// Pages that arrived after the reader reached the top of what was built.
    let wallsMet: Int
    let pages: [(count: Int, ms: Double, resting: Bool)]
    /// Times the region above the chat changed height on the way (`EarlierPages.resized`).
    let resizes: [(ms: Double, why: String)]

    @MainActor func report(_ name: String, budget: Double = TranscriptScrolling.pageBudget,
                           _ check: (Bool, String) throws -> Void) throws {
      func line(_ pages: [(count: Int, ms: Double, resting: Bool)]) -> String {
        let times = pages.map(\.ms).sorted()
        guard let slowest = times.last else { return "none" }
        let median = times[times.count / 2]
        return "\(pages.count) (\(pages.map(\.count).reduce(0, +)) messages), median \(String(format: "%.1f", median)) ms, slowest \(String(format: "%.1f", slowest)) ms"
      }
      print("MEASURE: \(name): pages while resting: \(line(pages.filter(\.resting)))")
      print("MEASURE: \(name): pages mid-scroll: \(line(pages.filter { !$0.resting }))")
      print("MEASURE: \(name): largest jump \(String(format: "%.1f", largestJump)) points, walls met \(wallsMet), scroll lag up to \(String(format: "%.0f", largestLag)) points")
      let turns = pageTurns.sorted()
      if !turns.isEmpty {
        let typicalTurn = turns[max(0, Int((0.95 * Double(turns.count)).rounded(.up)) - 1)]
        print("MEASURE: \(name): run-loop turns with a page, drawing included: median \(String(format: "%.1f", turns[turns.count / 2])) ms, 95% within \(String(format: "%.1f", typicalTurn)) ms, slowest \(String(format: "%.1f", turns.last ?? 0)) ms")
      }
      let slowestResize = resizes.map(\.ms).max() ?? 0
      print("MEASURE: \(name): region resized \(resizes.count) times, slowest \(String(format: "%.1f", slowestResize)) ms (\(Set(resizes.map(\.why)).sorted().joined(separator: "; ")))")
      try check(!pages.isEmpty, "\(name): scrolling up builds older pages")
      let times = pages.map(\.ms).sorted()
      // Nearest rank: the time 95% of the pages are within.
      let typical = times.isEmpty ? 0 : times[max(0, Int((0.95 * Double(times.count)).rounded(.up)) - 1)]
      let slowest = times.last ?? 0
      print("MEASURE: \(name): all \(times.count) pages: 95% within \(String(format: "%.1f", typical)) ms, slowest \(String(format: "%.1f", slowest)) ms")
      // Asked once at the end, so one run also shows everything else. The slowest page is the
      // one most at the mercy of the machine (another process, the processor waking from a pause),
      // so it is held to a frame, and the pages a reader meets to the budget.
      if TranscriptScrolling.timesPages, typical > budget {
        TranscriptScrolling.overBudget.append("\(name) 95% within \(String(format: "%.1f", typical)) ms, over \(Int(budget)) ms")
      }
      if TranscriptScrolling.timesPages, slowest > TranscriptScrolling.frame {
        TranscriptScrolling.overBudget.append("\(name) slowest \(String(format: "%.1f", slowest)) ms")
      }
      try check(largestJump <= 1, "\(name): older messages arrive without moving what is being read")
      try check(wallsMet == 0, "\(name): the reader never sees the top of what is built before the chat's start")
    }
  }

  /// The most 95% of a scroll's pages in Serein's chat may take, from the request until the page
  /// is laid out and drawn for the next frame.
  static let pageBudget: Double = 10
  /// The same for a task chat. Its messages cost more to build than Serein's bubbles: about 4 ms
  /// of SwiftUI row content, 1.5 ms of text views and 1.25 ms of hosting view each, so resting
  /// pages after a reading pause, when the processor runs slower, came in at 9.5–11.9 ms. Every
  /// page still fits in a frame (`frame`).
  static let taskChatBudget: Double = 12
  /// The most any page may take: one frame at 60 Hz.
  static let frame: Double = 1_000 / 60
  /// Page times are held to the budget in an optimized build, where it was set; an unoptimized
  /// build (`swift build`) only reports them.
  static let timesPages = !_isDebugAssertConfiguration()
  /// Scrolls whose pages took longer.
  static var overBudget: [String] = []

  /// `bursts` scrolls of `steps` wheel steps, one a frame at 60 Hz (6,000 points a second), with
  /// half a second's reading after each burst but the last.
  static func scrollUp(_ host: NSView, bursts: Int, steps: Int, step: CGFloat = 100) async throws -> Run {
    let scroll = try chat(in: host)
    EarlierPager.built = []
    EarlierPages.resized = []
    let blankBefore = EarlierPages.blankSeen
    let start: CGFloat = belowView(scroll)
    var scrolled: CGFloat = 0
    var jump: CGFloat = 0
    var lag: CGFloat = 0
    var walls = 0
    let watch = ScrollWatch(scroll)
    defer { watch.stop() }
    // AppKit applies the wheel's steps at the display's pace, so mid-scroll the view is also
    // behind by the steps not applied yet; on a busy main thread, several. That is lag, not a jump.
    func measure() { lag = max(lag, abs(belowView(scroll) - start - scrolled)) }
    // Once the scroll has caught up, whatever is still off moved without the reader.
    func settled() async throws {
      try await watch.still()
      jump = max(jump, abs(belowView(scroll) - start - scrolled))
    }
    reading: for burst in 0..<bursts {
      for _ in 0..<steps {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(step), wheel2: 0, wheel3: 0)
        guard let event, let wheel = NSEvent(cgEvent: event) else { throw SereinError.invalid("Transcript window: no scroll event") }
        scroll.scrollWheel(with: wheel)
        scrolled += step
        try await Task.sleep(for: .milliseconds(16))
        // The chat's real start is fine to reach; blank space above what is built is a wall
        // (`EarlierPages.blankSeen`).
        if scroll.documentVisibleRect.minY <= 1 { break reading }
        measure()
      }
      if burst < bursts - 1 {
        try await Task.sleep(for: .milliseconds(500))
        try await settled()
      }
    }
    if scroll.documentVisibleRect.minY > 1 { try await settled() }
    walls = EarlierPages.blankSeen - blankBefore
    return Run(largestJump: jump, largestLag: lag, pageTurns: watch.pageTurns, wallsMet: walls,
               pages: EarlierPager.built, resizes: EarlierPages.resized)
  }

  /// The chat's scroll while a check scrolls it: when the view last moved, and how long each
  /// run-loop turn that built a page took, from waking until its frame was committed.
  @MainActor final class ScrollWatch {
    private var moved = DispatchTime.now().uptimeNanoseconds
    private var woke: UInt64 = 0
    private var pagesAtWake = 0
    private(set) var pageTurns: [Double] = []
    private var observers: [CFRunLoopObserver] = []
    private var token: NSObjectProtocol?

    init(_ scroll: NSScrollView) {
      token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
        object: scroll.contentView, queue: nil) { [weak self] _ in
          MainActor.assumeIsolated { self?.moved = DispatchTime.now().uptimeNanoseconds }
        }
      // First on waking, last before sleeping: after Core Animation's commit.
      let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.woke(at: DispatchTime.now().uptimeNanoseconds) }
      }
      let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.sleeps(at: DispatchTime.now().uptimeNanoseconds) }
      }
      observers = [wake, sleep].compactMap { $0 }
      observers.forEach { CFRunLoopAddObserver(CFRunLoopGetMain(), $0, .commonModes) }
    }

    private func woke(at time: UInt64) {
      woke = time
      pagesAtWake = EarlierPager.built.count
    }

    private func sleeps(at time: UInt64) {
      guard woke > 0, EarlierPager.built.count > pagesAtWake else { return }
      pageTurns.append(Double(time - woke) / 1_000_000)
    }

    func stop() {
      observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
      observers = []
      if let token { NotificationCenter.default.removeObserver(token) }
      token = nil
    }

    /// Until the view has not moved for 100 ms, at most two seconds.
    func still() async throws {
      for _ in 0..<125 where DispatchTime.now().uptimeNanoseconds - moved < 100_000_000 {
        try await Task.sleep(for: .milliseconds(16))
      }
    }
  }

  /// A person scrolling back down to the end in big wheel steps.
  static func backToEnd(_ host: NSView) async throws {
    let scroll = try chat(in: host)
    for _ in 0..<600 where belowView(scroll) > 1 {
      let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -400, wheel2: 0, wheel3: 0)
      guard let event, let wheel = NSEvent(cgEvent: event) else { throw SereinError.invalid("Transcript window: no scroll event") }
      scroll.scrollWheel(with: wheel)
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  static func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }

  /// What VoiceOver turns on as it starts (`AXEnhancedUserInterface`): SwiftUI builds its
  /// accessibility elements only then.
  static func accessibility(_ on: Bool) {
    let enhanced = Selector(("accessibilitySetEnhancedUserInterfaceAttribute:"))
    if NSApp.responds(to: enhanced) { NSApp.perform(enhanced, with: NSNumber(value: on)) }
  }

  /// Show earlier messages, as VoiceOver and Full Keyboard Access reach it: through the
  /// accessibility of the region in the window, so a button outside the window is never found.
  static func earlierButton(in host: NSView) -> AnyObject? {
    guard let region = region(in: host), region.window != nil else { return nil }
    return accessible("Show earlier messages", in: region)
  }

  /// The button is there, and pressing it builds older messages at once.
  static func pressEarlier(in host: NSView, _ name: String, _ check: (Bool, String) throws -> Void) async throws {
    try await Task.sleep(for: .milliseconds(200))
    let button = earlierButton(in: host)
    try check(button != nil, "\(name): Show earlier messages is in the window, for the keyboard and VoiceOver")
    guard let pages = region(in: host)?.pages else { throw SereinError.invalid("Transcript window: no older messages region") }
    let before = pages.builtCount
    let pressed = button?.accessibilityPerformPress?() ?? false
    try await Task.sleep(for: .milliseconds(50))
    try check(pressed && pages.builtCount > before,
              "\(name): pressing Show earlier messages builds older messages (\(before) → \(pages.builtCount))")
  }

  private static func region(in view: NSView) -> EarlierRegionView? {
    (view as? EarlierRegionView) ?? view.subviews.lazy.compactMap(region(in:)).first
  }

  /// The first accessibility element under `element` titled or labelled `name`.
  private static func accessible(_ name: String, in element: AnyObject, depth: Int = 0) -> AnyObject? {
    let title: String? = element.accessibilityTitle?() ?? nil
    let label: String? = element.accessibilityLabel?() ?? nil
    if title == name || label == name { return element }
    guard depth < 40, let children = element.accessibilityChildren?() ?? nil else { return nil }
    for child in children {
      if let found = accessible(name, in: child as AnyObject, depth: depth + 1) { return found }
    }
    return nil
  }
  static func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
  }
  static func textViews(in view: NSView) -> Int {
    (view is NSTextView ? 1 : 0) + view.subviews.map(textViews(in:)).reduce(0, +)
  }
  static func chat(in host: NSView) throws -> NSScrollView {
    guard let found = scrollViews(in: host).max(by: {
      ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
    }), found.documentView != nil else { throw SereinError.invalid("Transcript window: no chat scroll view") }
    return found
  }
  /// Points from the bottom of the visible part to the end of the chat.
  static func belowView(_ scroll: NSScrollView) -> CGFloat {
    let visible = scroll.documentVisibleRect
    let height = scroll.documentView?.frame.height ?? 0
    return scroll.documentView?.isFlipped == true ? height - visible.maxY : visible.minY
  }
}
#endif
