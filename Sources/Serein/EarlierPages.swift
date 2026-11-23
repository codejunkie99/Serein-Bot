import AppKit
import OSLog
import SwiftUI

/// One older message as its chat draws it, and what that drawing depends on: the row is drawn
/// again only when its key changes.
struct EarlierRow {
  let key: EarlierRowKey
  let make: () -> AnyView
}

/// Any equatable value, for an older row's key.
struct EarlierRowKey: Equatable {
  private let value: Any
  private let same: (Any) -> Bool
  init<Value: Equatable>(_ value: Value) {
    self.value = value
    same = { ($0 as? Value) == value }
  }
  static func == (a: Self, b: Self) -> Bool { a.same(b.value) }
}

/// What a chat hands the region that holds its older messages, on each update: all its
/// messages, where its own newest rows begin, how one older message draws, and the chat's row
/// spacing.
struct EarlierRows {
  let thread: String
  let messages: [AgentMessage]
  /// The first message the chat draws itself; everything above it belongs to the region.
  let liveStart: Int
  var spacing: CGFloat = AssistantMetrics.turnInnerGap
  var font: Font = UIStyle.meta
  /// `messages[index]` as the chat draws it, `index` being below `liveStart`.
  let row: (Int) -> EarlierRow
}

/// A long chat's older messages, built ahead of a reader scrolling up and never in the chat's
/// own layout. Each message is drawn in a hosting view of its own, stacked from the bottom of a
/// region of fixed height above the newest messages (`EarlierMessagesRegion`), so a page adds a
/// view in blank space: nothing built moves, and no row is measured again. Only the region's
/// height ever moves the chat: a guess at open, larger when the reader nears its top, exact once
/// the chat's first message is built, and back to the guess when the reader stays at the end and
/// the older messages go. The scroll keeps its distance from the end for each of those
/// (`ReadingPositionHold`).
@MainActor final class EarlierPages: ObservableObject {
  /// The region guesses this much for a message it has not drawn yet.
  static let guess: CGFloat = 240
  /// At most this much blank space above what is built.
  static let reach: CGFloat = 40_000
  /// A page takes another message only while it would still finish within this, so a page
  /// leaves most of its frame to the scroll.
  static let budget: Double = 6

  private static let log = Logger(subsystem: "app.serein", category: "chat-paging")
  #if DEBUG
    /// Each time the region's height moved, for the checks: how long until it was drawn, and why.
    static var resized: [(ms: Double, why: String)] = []
    /// Readings that saw blank space above what is built while older messages were left.
    static var blankSeen = 0
    /// The older messages built right after a chat opens (`warmSoon`).
    static var warmups: [Double] = []
  #endif

  let pager = EarlierPager()
  private struct Host {
    let id: String
    var key: EarlierRowKey
    let controller: NSHostingController<AnyView>
    var height: CGFloat
    /// The message's own changes of height: a picture that loads, a disclosure, Edit.
    var sizing: NSKeyValueObservation?
  }
  /// The region's width, shared by every built message's view, so a new width lays them out
  /// again without drawing them again.
  private let column = EarlierColumn()
  private var rows: EarlierRows?
  private var environment: EarlierEnvironment?
  private weak var region: EarlierRegionView?
  /// The thread the region's state belongs to.
  private var thread: String?
  /// The first message the chat draws itself, fixed once something is built above it.
  private var boundary: String?
  /// Built older messages, the nearest to the chat's own rows first.
  private var hosts: [Host] = []
  /// The region's height, as SwiftUI lays it out.
  private(set) var reserve: CGFloat = 0
  private var opened = false
  private var control: NSHostingController<AnyView>?
  private var controlHeight: CGFloat = 0
  /// How many older messages the control's hint counts.
  private var controlCount = 0
  private var warming: DispatchWorkItem?
  /// Whether this opening has built its nearest older messages yet (`warmSoon`).
  private var warmed = false
  private var width: CGFloat = 0
  private var hold: ReadingPositionHold?
  private var resizing = false
  /// What building one message has been taking, for the budget.
  private var perMessage: Double = 4

  init() {
    pager.build = { [weak self] count in self?.build(upTo: count) ?? 0 }
    pager.letGo = { [weak self] in self?.releaseAll() }
    pager.hasBuilt = { [weak self] in !(self?.hosts.isEmpty ?? true) }
    pager.refresh = { [weak self] in self?.scrolled(byReader: false) }
  }

  // MARK: what the chat asks

  /// Where the chat's own rows begin in `messages`: the newest `newest`, or from the message
  /// the older ones were built above.
  func liveStart(in messages: [AgentMessage], thread: String, newest: Int) -> Int {
    let opening = max(0, messages.count - newest)
    guard self.thread == thread, let boundary else { return opening }
    return messages.firstIndex { $0.id == boundary } ?? opening
  }

  /// The region's height for `older` messages above the chat's own rows. Set once per thread
  /// while nothing is built, so the chat's newest rows sliding as messages arrive move nothing.
  func height(thread: String, older: Int) -> CGFloat {
    if self.thread == thread, opened { return reserve }
    return Self.opening(older: older)
  }

  private static func opening(older: Int) -> CGFloat {
    older == 0 ? 0 : min(reach, CGFloat(older) * guess) + 32
  }

  // MARK: the region's view

  func attach(_ view: EarlierRegionView) {
    region = view
    // Reading order: the control first, then the oldest built message down to the nearest. The
    // control is made by the chat's first update, before the region has a view to hold it.
    if let control, control.view.superview !== view {
      view.addSubview(control.view, positioned: .below, relativeTo: nil)
    }
    for host in hosts.reversed() where host.controller.view.superview !== view { view.addSubview(host.controller.view) }
    placeAll()
  }

  func detach(_ view: EarlierRegionView) {
    guard region === view else { return }
    region = nil
    pager.scrollView = nil
  }

  /// The chat's latest rows and environment, from SwiftUI's update of the region.
  func update(_ rows: EarlierRows, environment: EarlierEnvironment) {
    if thread != rows.thread { reset(for: rows) }
    if !opened {
      opened = true
      reserve = Self.opening(older: rows.liveStart)
      warmed = false
    }
    let restyled = self.environment != environment
    self.environment = environment
    self.rows = rows
    guard !hosts.isEmpty else {
      updateControl(rows)
      return
    }
    // The messages above the boundary must still be the ones built, in order.
    guard rows.messages.indices.contains(rows.liveStart), rows.messages[rows.liveStart].id == boundary,
      hosts.count <= rows.liveStart,
      hosts.indices.allSatisfy({ hosts[$0].id == rows.messages[rows.liveStart - 1 - $0].id })
    else {
      Self.log.debug("Older messages changed under the built ones: building them again")
      DispatchQueue.main.async { [weak self] in self?.releaseAll() }
      return
    }
    if restyled { controlCount = -1 }
    var redrawn = false
    for index in hosts.indices {
      let row = rows.row(rows.liveStart - 1 - index)
      guard restyled || row.key != hosts[index].key else { continue }
      hosts[index].key = row.key
      hosts[index].controller.rootView = root(row, rows)
      hosts[index].height = measure(hosts[index].controller)
      redrawn = true
    }
    updateControl(rows)
    if redrawn { placeAll() }
  }

  private func reset(for rows: EarlierRows) {
    warming?.cancel()
    removeHosts()
    thread = rows.thread
    boundary = nil
    opened = false
  }

  // MARK: building

  private var remaining: Int {
    guard let rows else { return 0 }
    return max(0, rows.liveStart - hosts.count)
  }

  /// Builds up to `count` older messages at once, within the budget after the first, and lays them
  /// out and draws them, so the next frame carries them.
  private func build(upTo count: Int) -> Int {
    guard !resizing, let rows, let region, width > 0, remaining > 0 else { return 0 }
    if boundary == nil { boundary = rows.messages[rows.liveStart].id }
    let started = DispatchTime.now().uptimeNanoseconds
    var made: [NSHostingController<AnyView>] = []
    while made.count < count, remaining > 0 {
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      if !made.isEmpty, elapsed + perMessage > Self.budget { break }
      let began = DispatchTime.now().uptimeNanoseconds
      let index = rows.liveStart - 1 - hosts.count
      let row = rows.row(index)
      let controller = Self.host(root(row, rows))
      // In the window before it is measured: measured outside it, the message would be drawn
      // again once it joins the window's appearance and scale.
      controller.view.frame = NSRect(x: 0, y: builtHeight, width: width, height: 0)
      // Reading order: the region's first view is the control, then the oldest built message.
      if let control { region.addSubview(controller.view, positioned: .above, relativeTo: control.view) }
      else { region.addSubview(controller.view, positioned: .below, relativeTo: nil) }
      let height = measure(controller)
      let id: String = rows.messages[index].id
      hosts.append(Host(id: id, key: row.key, controller: controller, height: height,
                        sizing: watch(controller, id: id)))
      made.append(controller)
      // Building is two thirds of a message; laying out and drawing it, the rest.
      perMessage = 0.7 * perMessage + 0.3 * 1.5 * Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    }
    // The control's count is brought up to date by the chat's next update; it goes with the last message.
    if remaining == 0 { updateControl(rows) }
    placeAll()
    for controller in made {
      controller.view.layoutSubtreeIfNeeded()
      controller.view.displayIfNeeded()
    }
    control?.view.displayIfNeeded()
    afterBuild()
    return made.count
  }

  /// Right after the chat's opening layout, its two nearest older messages, a turn apart: the
  /// first row of each kind costs the most (cold caches), and is better paid with the opening
  /// than by a scroll. Then the pager is armed, so a chat whose newest messages are shorter than
  /// the lead builds the rest of it at rest, before the first scroll asks.
  private func warmSoon() {
    guard !warmed, rows.map({ $0.liveStart > 0 }) == true else { return }
    warmed = true
    warming?.cancel()
    warmNext(left: 2)
  }

  private func warmNext(left: Int) {
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.resizing else { return }
      guard left > 0 else {
        self.pager.arm()
        return
      }
      let started = DispatchTime.now().uptimeNanoseconds
      guard self.build(upTo: 1) > 0 else { return }
      let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      #if DEBUG
        Self.warmups.append(ms)
      #endif
      Self.log.debug("Built an older message after opening in \(ms, format: .fixed(precision: 2)) ms")
      self.warmNext(left: left - 1)
    }
    warming = work
    DispatchQueue.main.async(execute: work)
  }

  /// The region's height follows what is built: exact once the chat's first message is in,
  /// larger when the blank space above runs short.
  private func afterBuild() {
    if remaining == 0 {
      DispatchQueue.main.async { [weak self] in self?.resize(why: "chat's start built") }
    } else if reserve - content < EarlierPager.lead {
      // The reader is about to meet the top of the region: grow it now, not at the next rest.
      DispatchQueue.main.async { [weak self] in self?.resize(why: "reader near the region's top") }
    } else if reserve - content < 2 * EarlierPager.lead, pager.isResting {
      // While the scroll rests, the region keeps twice the lead of blank space above.
      DispatchQueue.main.async { [weak self] in self?.resize(why: "resting near the region's top") }
    }
  }

  /// A hosting view placed by the region, which reports the message's height as it changes. It
  /// sits inside the chat's scroll view, whose own view keeps the window's safe area: an older
  /// message scrolled under the title bar keeps its place.
  private static func host(_ view: AnyView) -> NSHostingController<AnyView> {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = [.preferredContentSize]
    controller.safeAreaRegions = []
    return controller
  }

  private func root(_ row: EarlierRow, _ rows: EarlierRows) -> AnyView {
    let content = VStack(alignment: .leading, spacing: rows.spacing) { row.make() }
    let sized = EarlierColumnFrame(column: column) { content }
    return environment?.apply(AnyView(sized)) ?? AnyView(sized)
  }

  private func watch(_ controller: NSHostingController<AnyView>, id: String) -> NSKeyValueObservation {
    controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
      guard let height = change.newValue?.height else { return }
      MainActor.assumeIsolated { self?.resized(id, to: ceil(height)) }
    }
  }

  /// A built message changed height. What is built above it moves with its top, so the scroll
  /// moves the same way whenever any of that is in view: what the reader sees stays put.
  private func resized(_ id: String, to height: CGFloat) {
    guard width > 0, let index = hosts.firstIndex(where: { $0.id == id }),
      abs(hosts[index].height - height) > 0.5 else { return }
    let delta = height - hosts[index].height
    var follows = false
    if let scroll = pager.scrollView, let document = scroll.documentView {
      let view = hosts[index].controller.view
      follows = scroll.documentVisibleRect.minY < view.convert(view.bounds, to: document).maxY
    }
    hosts[index].height = height
    placeAll()
    guard follows, let scroll = pager.scrollView else { return }
    let clip = scroll.contentView
    var bounds = clip.bounds
    bounds.origin.y -= delta
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scroll.reflectScrolledClipView(clip)
  }

  private func measure(_ controller: NSHostingController<AnyView>) -> CGFloat {
    ceil(controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
  }

  // MARK: the control above what is built

  private func updateControl(_ rows: EarlierRows) {
    let left = remaining
    guard left > 0 else {
      control?.view.removeFromSuperview()
      control = nil
      controlHeight = 0
      return
    }
    let view = AnyView(EarlierMessagesButton(hidden: left, font: rows.font) { [weak self] in self?.pager.request() })
    let rooted = environment?.apply(view) ?? view
    if let control {
      // Drawn again only for a new count: the chat updates for every word a reply streams.
      if controlCount != left { control.rootView = rooted }
      controlCount = left
    } else {
      controlCount = left
      let made = Self.host(rooted)
      control = made
      // Without a region yet, `attach` puts it in.
      region?.addSubview(made.view, positioned: .below, relativeTo: nil)
      if width > 0 { controlHeight = measure(made) }
    }
  }

  // MARK: geometry

  /// The height of what is built, from the region's bottom: each message with the chat's
  /// spacing above it.
  private var builtHeight: CGFloat {
    let spacing = rows?.spacing ?? 0
    return hosts.reduce(0) { $0 + ($1.height > 0 ? $1.height + spacing : 0) }
  }
  /// What the region draws, from its bottom: the built messages and the control above them.
  private var content: CGFloat {
    let built = builtHeight
    if control != nil { return built + controlHeight }
    return max(0, built - (hosts.contains { $0.height > 0 } ? rows?.spacing ?? 0 : 0))
  }

  private func placeAll() {
    guard region != nil, width > 0 else { return }
    let spacing = rows?.spacing ?? 0
    var y: CGFloat = 0
    for host in hosts {
      let frame = NSRect(x: 0, y: y, width: width, height: host.height)
      if host.controller.view.frame != frame { host.controller.view.frame = frame }
      if host.height > 0 { y += host.height + spacing }
    }
    if let control {
      let frame = NSRect(x: 0, y: y, width: width, height: controlHeight)
      if control.view.frame != frame { control.view.frame = frame }
    }
    if content > reserve + 0.5 {
      DispatchQueue.main.async { [weak self] in self?.resize(why: "built past the region's top") }
    }
  }

  /// The region's width, as SwiftUI laid it out. A new width lays every built message out again.
  func widthChanged(_ newWidth: CGFloat) {
    guard abs(newWidth - width) > 0.5 else { return }
    width = newWidth
    column.width = newWidth
    if newWidth > 0 { warmSoon() }
    for index in hosts.indices { hosts[index].height = measure(hosts[index].controller) }
    if let control { controlHeight = measure(control) }
    placeAll()
  }

  // MARK: the region's height

  /// The region takes the height it needs: what is built, the control, and blank space for what
  /// is left. Its growth goes above the reader, who keeps their distance from the end.
  private func resize(why: String) {
    guard !resizing, let rows else { return }
    let left = remaining
    let wanted: CGFloat = left == 0 ? content : content + min(Self.reach, CGFloat(left) * averageHeight)
    guard abs(wanted - reserve) > 0.5 else { return }
    resizing = true
    pager.paused = true
    let started = DispatchTime.now().uptimeNanoseconds
    let finish: () -> Void = { [weak self] in
      guard let self else { return }
      self.resizing = false
      self.pager.paused = false
      self.hold = nil
      let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      #if DEBUG
        Self.resized.append((ms, why))
      #endif
      Self.log.debug("Region of \(rows.liveStart) older messages resized in \(ms, format: .fixed(precision: 2)) ms: \(why)")
      self.scrolled(byReader: false)
    }
    if let scroll = pager.scrollView, let hold = ReadingPositionHold(scroll) {
      self.hold = hold
      hold.whenDrawn(finish)
    } else {
      DispatchQueue.main.async(execute: finish)
    }
    reserve = wanted
    objectWillChange.send()
  }

  private var averageHeight: CGFloat {
    let drawn = hosts.filter { $0.height > 0 }
    guard !drawn.isEmpty else { return Self.guess }
    return max(Self.guess / 2, drawn.reduce(0) { $0 + $1.height } / CGFloat(drawn.count) + (rows?.spacing ?? 0))
  }

  /// Back to the newest messages only: the built ones go, and the region to its guess.
  private func releaseAll() {
    guard !hosts.isEmpty || boundary != nil else { return }
    removeHosts()
    boundary = nil
    // The chat's next update guesses the region again, from its newest rows.
    opened = false
    objectWillChange.send()
  }

  private func removeHosts() {
    for host in hosts {
      host.sizing?.invalidate()
      host.controller.view.removeFromSuperview()
    }
    hosts = []
  }

  // MARK: the reader

  /// Where the top of what is built sits in the view, for the pager: negative above it.
  func scrolled(byReader: Bool = true) {
    guard let region, let scroll = pager.scrollView, let document = scroll.documentView, document.isFlipped else { return }
    let frame = region.convert(region.bounds, to: document)
    let visible = scroll.documentVisibleRect
    let builtTop = frame.maxY - builtHeight
    #if DEBUG
      if byReader, remaining > 0, !resizing, visible.minY < frame.maxY - content - 1 { Self.blankSeen += 1 }
    #endif
    pager.reading(rowBottom: builtTop - visible.minY, byReader: byReader)
  }

  #if DEBUG
    /// For the checks: how many older messages are built, and how many are left.
    var builtCount: Int { hosts.count }
    var leftCount: Int { remaining }
  #endif
}

/// The region's width, for every built message's view.
@MainActor final class EarlierColumn: ObservableObject {
  @Published var width: CGFloat = 0
}

/// An older message at the region's width, as tall as it needs: the height its hosting view
/// reports (`preferredContentSize`).
private struct EarlierColumnFrame<Content: View>: View {
  @ObservedObject var column: EarlierColumn
  @ViewBuilder var content: Content
  var body: some View {
    content.frame(width: column.width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
  }
}

/// What the older messages' hosting views take from the chat's environment: they sit outside
/// its SwiftUI tree.
struct EarlierEnvironment: Equatable {
  let palette: Palette
  let reducedEffects: Bool
  let selection: MessageSelection?
  let chatFolder: URL?
  let bubbleTint: Color?

  init(_ values: EnvironmentValues) {
    palette = values.palette
    reducedEffects = values.sereinReducedEffects
    selection = values.messageSelection
    chatFolder = values.chatFolder
    bubbleTint = values.personBubbleTint
  }

  static func == (a: Self, b: Self) -> Bool {
    a.palette == b.palette && a.reducedEffects == b.reducedEffects && a.selection === b.selection
      && a.chatFolder == b.chatFolder && a.bubbleTint == b.bubbleTint
  }

  func apply(_ view: AnyView) -> AnyView {
    AnyView(view.environment(\.palette, palette).environment(\.sereinReducedEffects, reducedEffects)
      .environment(\.messageSelection, selection).environment(\.chatFolder, chatFolder)
      .environment(\.personBubbleTint, bubbleTint))
  }
}

/// The top of what is built while older messages are left. Scrolling up toward it brings them
/// in ahead of the reader; the button does the same from the keyboard and VoiceOver.
private struct EarlierMessagesButton: View {
  let hidden: Int
  let font: Font
  let show: () -> Void
  var body: some View {
    Button("Show earlier messages", action: show)
      .buttonStyle(QuietButton()).font(font).frame(maxWidth: .infinity)
      .accessibilityHint("\(hidden) earlier messages in this chat")
  }
}

/// The chat's older messages: a region of fixed height above its newest rows (`EarlierPages`).
struct EarlierMessagesRegion: View {
  @ObservedObject var pages: EarlierPages
  let rows: EarlierRows
  var body: some View {
    EarlierRegionRepresentable(pages: pages, rows: rows,
      height: pages.height(thread: rows.thread, older: rows.liveStart))
  }
}

private struct EarlierRegionRepresentable: NSViewRepresentable {
  let pages: EarlierPages
  let rows: EarlierRows
  let height: CGFloat

  func makeNSView(context: Context) -> EarlierRegionView {
    let view = EarlierRegionView()
    view.pages = pages
    return view
  }
  func updateNSView(_ view: EarlierRegionView, context: Context) {
    view.pages = pages
    pages.update(rows, environment: EarlierEnvironment(context.environment))
    pages.attach(view)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: EarlierRegionView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: height)
  }
  static func dismantleNSView(_ view: EarlierRegionView, coordinator: ()) {
    view.pages?.detach(view)
  }
}

/// Holds the older messages' hosting views, laid out from its bottom.
final class EarlierRegionView: NSView {
  weak var pages: EarlierPages?
  private var watching: [NSObjectProtocol] = []
  override var isFlipped: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    watching.forEach(NotificationCenter.default.removeObserver)
    watching = []
    guard window != nil, let scroll = enclosingScrollView else { return }
    pages?.pager.scrollView = scroll
    scroll.contentView.postsBoundsChangedNotifications = true
    watching.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
      object: scroll.contentView, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.pages?.scrolled() }
      })
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    pages?.widthChanged(newSize.width)
  }

  deinit { watching.forEach(NotificationCenter.default.removeObserver) }
}

extension ChatTurns {
  /// How many messages before a row its turn gap is read with.
  static let context = 4

  /// The turn gaps for `messages[start...]` (through `end`, when given), read with a few messages
  /// before them, so a row has the same gap whether it is in the chat's own layout or built above
  /// it (`EarlierPages`), and whatever is built around it.
  static func breaks(_ messages: [AgentMessage], from start: Int, through end: Int? = nil) -> Set<String> {
    guard start < messages.count else { return [] }
    let first = max(0, start - context)
    let last = min(messages.count - 1, end ?? messages.count - 1)
    guard first <= last else { return [] }
    let kept = Set(messages[start...last].map(\.id))
    return breaks(Array(messages[first...last])).intersection(kept)
  }
}
