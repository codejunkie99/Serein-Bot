import AppKit
import Combine
import SereinCore
import SwiftUI

/// The run ledger for tasks inside Serein. The whole file is read once, off the main thread, at
/// launch; after that the hub's own records (each `revision`) keep it current in memory, so a
/// working task never makes the main thread re-read the log, and an idle window does no work.
@MainActor final class SereinTray: ObservableObject {
  static let shared = SereinTray()
  /// This launch began here: a task card whose run started before it is “Finished earlier”.
  static let launchedAt = Date()
  /// Records that ended (or were last heard from) in the last 24 hours, one per run, newest first.
  @Published private(set) var ledger: [RunRecord] = []
  /// The latest record of every thread, all time: a task card and its header read it once the
  /// run has left the hub and the last day.
  private var latest: [String: RunRecord] = [:]
  private var recent: [String: RunRecord] = [:]
  private var watch: AnyCancellable?
  private weak var hub: AgentHub?
  func attach(hub: AgentHub, browser: BrowserModel) {
    guard watch == nil else { return }
    self.hub = hub
    loadDismissed()
    let library = browser.library
    hub.onRecord = { [weak self] record in
      guard let self, !self.deleted.contains(record.threadID) else { return }
      self.load([record])
    }
    watch = hub.$revision.removeDuplicates().receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.mergeHub() }
    // Previews and checks draw their first frame from it, so they read it now.
    if RunMode.automated {
      load(library.runs())
    } else {
      Task.detached(priority: .utility) {
        let runs = library.runs()
        await MainActor.run { SereinTray.shared.load(runs) }
      }
    }
  }
  /// Threads whose chat was deleted this launch: their records, cards and chips are gone, even
  /// while the stopped run is still in the hub. (After a relaunch, `items` drops ledger records
  /// whose chat no longer exists.)
  @Published private(set) var deleted: Set<String> = []
  /// Delete Chat…: the thread leaves the strip, its card and the Serein row at once.
  func forget(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    deleted.formUnion(ids)
    for id in ids { latest[id] = nil }
    recent = recent.filter { !ids.contains($0.value.threadID) }
    // Their ended runs leave the hub too, so nothing they held (a denied edit) lingers.
    if let hub {
      for run in hub.runs where ids.contains(run.spec.threadID) && !run.isActive { hub.dismiss(run) }
    }
    mergeHub()
  }
  /// Tasks you dismissed (Dismiss on a chip, or in the task's ⋯), by thread, with when: the
  /// thread's chip, and the “Needs you” it put on the Serein row, are gone until it starts again.
  /// Saved for a day (`dismissedKey`), as long as the ledger would still list it.
  @Published private(set) var dismissed: [String: Date] = [:]
  static let dismissedKey = "serein.assistant.dismissedTasks"
  /// Dismiss: the task leaves the strip (and the hub, once it has ended); its chat and card stay.
  func dismiss(_ threadID: String) {
    dismissed[threadID] = Date()
    // Every ended run of the thread, not only the latest: an older one can still hold a denied edit.
    if let hub {
      for run in hub.runs where run.spec.threadID == threadID && !run.isActive { hub.dismiss(run) }
    }
    saveDismissed()
    mergeHub()
  }
  /// The task was dismissed after its latest run started.
  func isDismissed(_ threadID: String, startedAt: Date) -> Bool {
    dismissed[threadID].map { $0 >= startedAt } ?? false
  }
  private func loadDismissed() {
    let since = Date().addingTimeInterval(-SereinTrayList.retention)
    let saved = UserDefaults.standard.dictionary(forKey: Self.dismissedKey) as? [String: Double] ?? [:]
    dismissed = saved.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value >= since }
  }
  private func saveDismissed() {
    let since = Date().addingTimeInterval(-SereinTrayList.retention)
    dismissed = dismissed.filter { $0.value >= since }
    RelayOrchestrator.setSetting(dismissed.mapValues(\.timeIntervalSince1970), forKey: Self.dismissedKey)
  }
  /// The next moment a record leaves the last day: the ledger is trimmed then, so the strip and
  /// the Serein row drop it on time even while nothing else happens (one timer, no polling).
  private var expiry: DispatchWorkItem?
  private func scheduleExpiry() {
    expiry?.cancel()
    expiry = nil
    guard let first = ledger.map({ $0.endedAt ?? $0.lastEventAt }).min() else { return }
    let delay = max(1, first.addingTimeInterval(SereinTrayList.retention).timeIntervalSinceNow + 1)
    let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.mergeHub() } }
    expiry = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
  /// The latest record of a thread: its run in the hub, else the ledger's; none once deleted.
  func record(_ threadID: String) -> RunRecord? {
    guard !deleted.contains(threadID) else { return nil }
    return hub?.latest(for: threadID)?.record ?? latest[threadID]
  }
  /// A task still has something to show: its chat exists, or its run is in the hub, and it was
  /// not deleted.
  func exists(_ threadID: String, agent: AgentModel) -> Bool {
    !deleted.contains(threadID)
      && (agent.conversations.contains { $0.id == threadID } || agent.hub.latest(for: threadID) != nil)
  }
  private func load(_ runs: [RunRecord]) {
    for record in runs { absorb(record) }
    mergeHub()
  }
  private func mergeHub() {
    for run in hub?.runs ?? [] where !deleted.contains(run.spec.threadID) { absorb(run.record) }
    let since = Date().addingTimeInterval(-SereinTrayList.retention)
    recent = recent.filter { ($0.value.endedAt ?? $0.value.lastEventAt) >= since }
    let fresh = recent.values.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    if fresh != ledger { ledger = fresh }
    scheduleExpiry()
  }
  private func absorb(_ record: RunRecord) {
    if let known = latest[record.threadID], known.id != record.id, known.startedAt > record.startedAt {} else {
      latest[record.threadID] = record
    }
    let since = Date().addingTimeInterval(-SereinTrayList.retention)
    if (record.endedAt ?? record.lastEventAt) >= since { recent[record.id] = record }
  }
  /// The strip's items: the ledger and the hub's live runs, without Serein's own turns.
  static func items(hub: AgentHub, agent: AgentModel, relay: RelayOrchestrator?, ledger: [RunRecord], now: Date)
    -> [SereinTrayList.Item]
  {
    func serein(_ id: String) -> Bool { relay?.isChild(id) == true }
    let tray = SereinTray.shared
    let deleted = tray.deleted
    // A record from the ledger shows only while its chat still exists (Delete Chat… removes it)
    // and you have not dismissed it.
    let past = ledger.filter { record in
      !deleted.contains(record.threadID) && !hub.runs.contains { $0.record.id == record.id }
        && agent.conversations.contains { $0.id == record.threadID }
        && !tray.isDismissed(record.threadID, startedAt: record.startedAt)
    }.map {
      SereinTrayList.Item(id: $0.threadID, title: $0.title, outcome: $0.outcome == .running ? .stopped : $0.outcome,
                          startedAt: $0.startedAt, endedAt: $0.endedAt ?? $0.lastEventAt, serein: serein($0.threadID))
    }
    let live = hub.runs.filter {
      !$0.spec.relay && !deleted.contains($0.spec.threadID)
        && ($0.isActive || !tray.isDismissed($0.spec.threadID, startedAt: $0.record.startedAt))
    }.map {
      SereinTrayList.Item(id: $0.spec.threadID, title: $0.spec.title.isEmpty ? "Task" : $0.spec.title,
                          outcome: $0.record.outcome, startedAt: $0.record.startedAt, endedAt: $0.record.endedAt,
                          serein: serein($0.spec.threadID))
    }
    // Serein's own chats are not tasks (a task it started is, even though Serein owns it).
    return SereinTrayList.items(ledger: past, live: live, now: now) { id in
      !serein(id) && (relay?.knownThreadIDs.contains(id) == true || agent.isSereinChatID(id))
    }
  }
}

/// The Working strip above a composer: one line, every task (Serein's and direct ones) live,
/// waiting, or finished in the last day, at most three chips then “+N”, which lists the rest in a
/// popover (the main view never changes). A Serein task's chip opens its view in the surface; a
/// direct task's chip opens its tab. In a task's view it lists only the other tasks. Its clock
/// ticks once a second only while a task is live (`AtWorkTimelineSchedule`).
struct SereinWorkingStrip: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  @ObservedObject var relay: RelayOrchestrator
  var excluding: String?
  var full: Bool
  /// Full, the line is as wide as the message bar under it: the composer's width in a task's
  /// view, the 640-point chat column in Serein's chat.
  var column: CGFloat
  @ObservedObject private var tray = SereinTray.shared
  @ObservedObject private var hints = HintCenter.shared
  @ObservedObject private var network = NetworkMonitor.shared
  @State private var showMore = false
  @Environment(\.palette) var p
  init(browser: BrowserModel, agent: AgentModel, relay: RelayOrchestrator, excluding: String? = nil, full: Bool,
       column: CGFloat = UIStyle.composerWidth) {
    self.browser = browser
    self.agent = agent
    hub = agent.hub
    self.relay = relay
    self.excluding = excluding
    self.full = full
    self.column = column
  }
  var body: some View {
    let live = hub.runs.filter { $0.isActive && !$0.spec.relay && $0.spec.threadID != excluding }
    TimelineView(AtWorkTimelineSchedule(items: live.map(\.atWorkItem))) { context in
      // The chips say what's at work and leave the one in view out. VoiceOver gets the count of
      // every task, as the Serein row says it; only being offline shows as words on the strip.
      let every = SereinTray.items(hub: hub, agent: agent, relay: relay, ledger: tray.ledger, now: context.date)
      let items = every.filter { $0.id != excluding }
      if SereinTrayList.visible(items) {
        // As many chips as keep each title readable (at least `SereinStripFit.titleFloor`, about
        // ten characters), at most three (two beside a tab); the rest fold into “+N”. Whole titles
        // and the live step first; then the titles give way, down to that floor, and the detail
        // shortens to the time, then to the state alone (a live chip's spinner, a done chip's
        // check); “Needs you”, “Could not finish” and “Stopped” never drop. The line is planned
        // from the measured words (not left to the layout), so it never runs past its width.
        let cap = min(items.count, full ? SereinTrayList.cap : 2)
        let online = SereinSurface.online(network.online)
        let plan = SereinStripFit.plan(
          items: items, cap: cap, width: width, online: online,
          words: { item, detail in words(item, detail: detail, now: context.date) })
        // `minWidth: 0`: the line never asks for more than it is given, so its width (and the
        // plan made from it) cannot grow on itself.
        row(items: items, k: plan.k, detail: plan.detail, titles: plan.titles, online: online, now: context.date)
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
          .padding(.horizontal, full ? 0 : 12).frame(height: 34)
          .frame(maxWidth: full ? column : .infinity).padding(.horizontal, full ? 16 : 0)
          .frame(maxWidth: .infinity)
          .overlay(alignment: .top) { if !full { Rectangle().fill(p.line).frame(height: 1) } }
          .accessibilityElement(children: .contain).accessibilityLabel("Tasks")
          .accessibilityValue(SereinTrayList.label(every, online: online))
      }
    }
  }
  /// The width the strip's line has (measured; 0 until the first layout, which then plans again).
  @State private var width: CGFloat = 0
  private func words(_ item: SereinTrayList.Item, detail: SereinTrayList.ChipDetail, now: Date) -> String? {
    let line = item.live ? hub.latest(for: item.id).map { $0.atWorkPhase(browser) } : nil
    return SereinTrayList.chipWords(item, line: line, now: now, detail: detail, labelSaysNeedsYou: false)
  }
  /// One way the strip can read: “Offline” when it is, the first `k` chips, then “+N”.
  private func row(items: [SereinTrayList.Item], k: Int, detail: SereinTrayList.ChipDetail,
                   titles: [String: CGFloat], online: Bool, now: Date) -> some View
  {
    let layout = SereinTrayList.layout(items, cap: k)
    let folded = Array(items.dropFirst(layout.shown.count))
    return HStack(spacing: SereinStripFit.spacing) {
      if !online {
        Text(SereinStripFit.offline).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
      }
      ForEach(layout.shown, id: \.id) { item in
        SereinTrayChip(item: item, run: hub.latest(for: item.id), browser: browser, hub: hub, now: now, detail: detail,
                       titleWidth: titles[item.id])
          .sereinHintAnchor(.taskDone, when: [.done, .stuck, .stopped].contains(item.outcome) && item.id == (hints.finishedTaskID ?? layout.shown.first(where: { [.done, .stuck, .stopped].contains($0.outcome) })?.id))
      }
      if layout.more > 0 {
        Button { showMore.toggle() } label: {
          Text("+\(layout.more)").font(UIStyle.metaStrong).foregroundStyle(p.ink)
        }.buttonStyle(QuietButton()).fixedSize()
          .help("Show \(layout.more) more \(layout.more == 1 ? "task" : "tasks")")
          .accessibilityLabel("\(layout.more) more \(layout.more == 1 ? "task" : "tasks")")
          .popover(isPresented: $showMore, arrowEdge: .bottom) {
            SereinMoreTasks(items: folded, browser: browser, hub: hub, now: now) { showMore = false }
              .environment(\.palette, p)
          }
      }
      Spacer(minLength: 0)
    }
  }
}

/// How the Working strip's line fits: the widths of its words in Geist, and the most chips (then
/// the most words per chip) that fit the measured width.
@MainActor enum SereinStripFit {
  /// About ten characters of a title: the least a chip shows before it folds into “+N”.
  static let titleFloor: CGFloat = 64
  static let spacing: CGFloat = 6
  static let offline = "Offline"
  private static var font: NSFont {
    NSFont.systemFont(ofSize: 12 * UIStyle.textScale)
  }
  private static var strong: NSFont {
    NSFont.systemFont(ofSize: 12 * UIStyle.textScale, weight: .medium)
  }
  static func measure(_ text: String, strong bold: Bool = false) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: bold ? strong : font]).width)
  }
  /// A chip's width at `detail`: its insets, glyph, title (whole, or down to the floor) and words.
  static func chip(_ item: SereinTrayList.Item, detail: SereinTrayList.ChipDetail, words: String?) -> CGFloat {
    let glyph: CGFloat = switch item.outcome {
    case .running: 12
    case .waiting: 6
    case .done: 9
    default: 0
    }
    let title = measure(item.title)
    var parts: [CGFloat] = []
    if glyph > 0 { parts.append(glyph) }
    parts.append(detail == .full ? title : min(title, titleFloor))
    if let words { parts.append(measure(words)) }
    return 16 + parts.reduce(0, +) + CGFloat(parts.count - 1) * 5
  }
  /// The chips to show and how much each says. With no width yet, the fewest words (the first
  /// layout measures, then this plans again).
  static func plan(items: [SereinTrayList.Item], cap: Int, width: CGFloat, online: Bool,
                   words: (SereinTrayList.Item, SereinTrayList.ChipDetail) -> String?)
    -> (k: Int, detail: SereinTrayList.ChipDetail, titles: [String: CGFloat])
  {
    guard width > 0 else { return (0, .minimal, [:]) }
    // A few points spare for rounding and digits that widen as the clock ticks.
    let room = width - 6
    let label = online ? 0 : measure(offline)
    for k in stride(from: cap, through: 1, by: -1) {
      let more = items.count - k
      let plus = more > 0 ? spacing + measure("+\(more)", strong: true) + 12 : 0
      for detail in [SereinTrayList.ChipDetail.full, .short, .minimal] {
        let shown = Array(items.prefix(k))
        let chips = shown.map { spacing + chip($0, detail: detail, words: words($0, detail)) }.reduce(0, +)
        guard label + chips + plus <= room else { continue }
        guard detail != .full else { return (k, detail, [:]) }
        // Each title starts at the floor (or its whole width); the room left is shared evenly
        // among the titles still cut, up to their whole width, so the line fills and never runs
        // over.
        var spare = max(0, room - label - chips - plus)
        let whole = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, measure($0.title) + 1) })
        var titles = whole.mapValues { min($0, titleFloor) }
        while spare > 0.5 {
          let cut = shown.filter { titles[$0.id]! < whole[$0.id]! }
          guard !cut.isEmpty else { break }
          let share = spare / CGFloat(cut.count)
          for item in cut {
            let more = min(share, whole[item.id]! - titles[item.id]!)
            titles[item.id]! += more
            spare -= more
          }
        }
        return (k, detail, titles)
      }
    }
    return (0, .minimal, [:])
  }
}

/// “+N”: the tasks that did not fit on the strip's line, each with its state. A click opens it the
/// way its chip does; a live one has Stop. “See All in Activity” is last.
private struct SereinMoreTasks: View {
  let items: [SereinTrayList.Item]
  @ObservedObject var browser: BrowserModel
  @ObservedObject var hub: AgentHub
  let now: Date
  let close: () -> Void
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(items, id: \.id) { item in
        let run = hub.latest(for: item.id)
        let line = item.live ? run.map { $0.atWorkPhase(browser) } : nil
        HStack(spacing: 8) {
          Button {
            close()
            SereinTrayChip.open(item)
          } label: {
            HStack(spacing: 8) {
              SereinTrayChip.glyph(item.outcome, p).frame(width: 12)
              Text(item.title).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
              Spacer(minLength: 8)
              Text(SereinTrayList.chipDetail(item, line: line, now: now)).font(UIStyle.meta).monospacedDigit()
                .foregroundStyle(item.needsYou ? p.ink : p.secondary).lineLimit(1).fixedSize()
            }.padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
          }.buttonStyle(.pressable).hoverWash(in: RoundedRectangle(cornerRadius: UIStyle.controlRadius))
            .help(item.serein ? "Show this task in Serein" : "Show this task’s tab")
            .accessibilityLabel(SereinTrayList.chipLabel(item, now: now))
          if item.live, let run {
            Button { hub.stop(run) } label: { Text("Stop").font(UIStyle.metaStrong) }
              .buttonStyle(QuietButton()).fixedSize().help("Stop this task").accessibilityLabel("Stop \(item.title)")
          }
        }
      }
    }.padding(8).frame(width: 320)
  }
}

/// One task in the Working strip, sized to its words: the state (spinner, amber dot, check), the
/// title, which gives way first, and its second words (“Needs you”, “3 h ago”, “Could not
/// finish”, “Stopped”; for a live task its step and time, the time alone, or nothing when room is
/// short). A live chip's Stop shows on hover or while either of its buttons has the keyboard, so
/// Tab reaches it; a finished one can be dismissed from its context menu or by VoiceOver.
private struct SereinTrayChip: View {
  let item: SereinTrayList.Item
  let run: AgentRun?
  @ObservedObject var browser: BrowserModel
  @ObservedObject var hub: AgentHub
  let now: Date
  var detail: SereinTrayList.ChipDetail = .full
  /// The strip's label already says “Needs you”, so a waiting chip leaves the words out.
  var labelSaysNeedsYou = false
  /// The title's width from the strip's plan (nil: its whole width).
  var titleWidth: CGFloat?
  private enum Focus: Hashable { case open, stop }
  @State private var hovered = false
  @FocusState private var focus: Focus?
  @Environment(\.palette) var p
  var body: some View {
    let line = item.live ? run.map { $0.atWorkPhase(browser) } : nil
    let words = SereinTrayList.chipWords(item, line: line, now: now, detail: detail, labelSaysNeedsYou: labelSaysNeedsYou)
    let stopShown = item.live && run != nil && (hovered || focus != nil)
    HStack(spacing: 4) {
      Button { Self.open(item) } label: {
        HStack(spacing: 5) {
          Self.glyph(item.outcome, p)
          if let titleWidth {
            // The strip planned this width: at least the floor (or the whole title, if shorter).
            title.frame(width: titleWidth, alignment: .leading)
          } else {
            title.fixedSize()
          }
          if let words { second(words) }
        }.padding(.leading, 8).padding(.trailing, stopShown ? 2 : 8).frame(height: 24)
          .contentShape(Capsule())
      }.buttonStyle(.pressable).focused($focus, equals: .open)
        .help("\(item.title) · \(SereinTrayList.chipDetail(item, line: line, now: now))")
      if stopShown, let run {
        Button("Stop") { hub.stop(run) }.buttonStyle(.pressable).font(UIStyle.metaStrong).foregroundStyle(p.ink)
          .padding(.trailing, 8).fixedSize().focused($focus, equals: .stop)
          .help("Stop this task").accessibilityLabel("Stop this task")
      }
    }
      .background(hovered ? p.selected : p.track, in: Capsule())
      .onHover { hovered = $0 }
      .contextMenu {
        Button("Open") { Self.open(item) }
        if item.live, let run {
          Button("Stop") { hub.stop(run) }
        } else {
          Button("Dismiss") { SereinTray.shared.dismiss(item.id) }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(SereinTrayList.chipLabel(item, now: now))
      .accessibilityAction { Self.open(item) }
      .accessibilityActions {
        if item.live, let run {
          Button("Stop this task") { hub.stop(run) }
        } else if !item.live {
          Button("Dismiss") { SereinTray.shared.dismiss(item.id) }
        }
      }
  }
  private var title: some View {
    Text(item.title).font(UIStyle.meta).foregroundStyle(p.ink).lineLimit(1).truncationMode(.tail)
  }
  private func second(_ words: String) -> some View {
    Text(words).font(UIStyle.meta).monospacedDigit().foregroundStyle(item.needsYou ? p.ink : p.secondary)
      .lineLimit(1).fixedSize()
  }
  /// The chip's state: the mini spinner, an amber dot, a check, or nothing (its words say it).
  @ViewBuilder static func glyph(_ outcome: RunRecord.Outcome, _ p: Palette) -> some View {
    switch outcome {
    case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
    case .waiting: Circle().fill(p.warning).frame(width: 6, height: 6)
    case .done: InterfaceIcon(systemName: "checkmark", size: 9).foregroundStyle(p.success)
    default: EmptyView()
    }
  }
  static func open(_ item: SereinTrayList.Item) {
    if item.serein { SereinRouter.openTask(item.id) } else { SereinRouter.open(threadID: item.id) }
  }
}

/// A task Serein started in this chat: its card stays here for good, after the turn that started
/// it. Title; where it works and with what (“Codex · GPT-5.1 · in shop-web”); its status
/// (“Running the tests · 0:12”, “Needs your answer”, “Done in 3 min”, “Could not finish.”); Open,
/// and Stop while it works or Try again after a failure. Once its run has left the hub it reads the
/// thread's latest record from the whole ledger; a task from an earlier launch is marked “Finished
/// earlier”, and one with no record left says only that. A live card's clock ticks with the strip's.
struct SereinTaskCard: View {
  let threadID: String
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  @ObservedObject var hub: AgentHub
  /// A task Serein started opens in its surface; one you started (the Agents view lists both)
  /// opens as its tab.
  var serein = true
  @ObservedObject private var tray = SereinTray.shared
  @Environment(\.palette) var p
  init(threadID: String, browser: BrowserModel, agent: AgentModel, serein: Bool = true) {
    self.threadID = threadID
    self.browser = browser
    self.agent = agent
    self.serein = serein
    hub = agent.hub
  }
  var body: some View {
    let run = hub.latest(for: threadID)
    let record = tray.record(threadID)
    let thread = agent.conversations.first { $0.id == threadID }
    let title = run?.spec.title ?? record?.title ?? thread?.title ?? "Task"
    let provider = run?.spec.provider ?? thread?.provider
    let model = run?.spec.model ?? record?.model ?? thread?.model ?? ""
    let mode = run?.spec.mode.runKey ?? record?.mode ?? thread?.mode.runKey ?? "answer"
    let project = run?.spec.projectName ?? record?.projectName
    // A record still marked running with no run behind it ended when an earlier launch quit.
    let outcome = record.map { run == nil && $0.outcome == .running ? .stopped : $0.outcome }
    let earlier = run == nil && (record.map { $0.startedAt < SereinTray.launchedAt } ?? true)
    let live = run?.isActive == true
    let seconds: (Date) -> TimeInterval = { now in
      record.map { (($0.endedAt ?? (live ? now : $0.lastEventAt)).timeIntervalSince($0.startedAt)) } ?? 0
    }
    let line = live ? run?.atWorkPhase(browser) : nil
    // What it used, as the AI app reported it: the live run's count while it works, then its record's.
    let tokens = (run?.record.tokens ?? record?.tokens).flatMap { $0 > 0 ? "\(UsageLedger.Summary.short($0)) tokens" : nil }
    let place = ([provider?.name] + [model.isEmpty ? nil : ModelBadge.display(model, provider: provider?.shortName ?? "")]
                 + [TaskWords.place(mode: mode, project: project), tokens]).compactMap { $0 }.joined(separator: " · ")
    let status: (Date) -> String? = { now in outcome.map { TaskWords.card($0, line: line, seconds: seconds(now)) } }
    VStack(alignment: .leading, spacing: 6) {
      Text(title.isEmpty ? "Task" : title).font(AgentsType.title).foregroundStyle(p.ink).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      Text(place).font(AgentsType.detail).foregroundStyle(p.secondary).lineLimit(1)
      HStack(spacing: 6) {
        switch outcome {
        case .running?: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .waiting?: Circle().fill(p.warning).frame(width: 6, height: 6)
        case .done?: InterfaceIcon(systemName: "checkmark", size: 9).foregroundStyle(p.success)
        default: EmptyView()
        }
        // A live card's clock ticks on the strip's and the header's schedule (once a second, only
        // while it works), so the three read the same time.
        TimelineView(AtWorkTimelineSchedule(items: live ? run.map { [$0.atWorkItem] } ?? [] : [])) { context in
          let words = status(context.date)
          Text(earlier ? [TaskWords.finishedEarlier, words].compactMap { $0 }.joined(separator: " · ") : words ?? "")
            .font(AgentsType.detail).monospacedDigit().foregroundStyle(outcome == .stuck ? p.danger : p.ink).lineLimit(1)
        }
        Spacer(minLength: 6)
        if outcome == .stuck {
          Button("Try again") { SereinTaskHeader.tryAgain(threadID, agent: agent) }.buttonStyle(PillButton(kind: .tinted, small: true))
        }
        if let run, run.isActive {
          Button("Stop") { hub.stop(run) }.buttonStyle(PillButton(kind: .quiet, small: true))
            .help("Stop this task. Serein keeps working on other things.").accessibilityLabel("Stop \(title)")
        }
        Button("Open") {
          if serein { SereinRouter.openTask(threadID) } else { SereinRouter.open(threadID: threadID) }
        }.buttonStyle(PillButton(kind: .tinted, small: true))
          .help("Show this task in Serein").accessibilityLabel("Open \(title)")
      }
      if let outcome, let detail = run?.attentionDetail
        ?? RunAttention.detail(outcome: outcome, saved: record?.attentionDetail, summary: record?.summary)
      {
        Text(detail).font(AgentsType.detail).foregroundStyle(p.secondary).lineLimit(3)
          .fixedSize(horizontal: false, vertical: true).help(detail)
      } else if outcome == .done, let summary = (run?.reportedSummary ?? record?.summary)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
        Text(summary).font(AgentsType.detail).foregroundStyle(p.secondary).lineLimit(2)
      }
      if !live, let meter = record?.context { ContextMeterLine(meter: meter) }
    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityElement(children: .contain).accessibilityLabel("Task: \(title)")
  }
}

/// Under the first task card while macOS has not been asked about notifications: Serein asks in
/// context, never with the first notification it posts.
struct SereinNotifyCard: View {
  @AppStorage(SereinNotifyCard.dismissedKey) private var dismissed = false
  @State private var answered = false
  @Environment(\.palette) var p
  static let dismissedKey = "serein.assistant.notifyCardDismissed"
  /// `--ui-serein-notify-card`: the card, whatever macOS has said.
  static let preview = CommandLine.arguments.contains("--ui-preview") && CommandLine.arguments.contains("--ui-serein-notify-card")
  static var undetermined: Bool { preview || TaskNotifications.shared.authorization == .notDetermined }
  var body: some View {
    if Self.undetermined, !dismissed || Self.preview, !answered {
      HStack(alignment: .top, spacing: 10) {
        InterfaceIcon(systemName: "bell", size: 13).foregroundStyle(p.secondary).padding(.top, 2)
        VStack(alignment: .leading, spacing: 8) {
          Text("Serein can tell you when this is done, even while you are in another app.")
            .font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 8) {
            Button("Allow notifications") {
              TaskNotifications.shared.requestAuthorization()
              answered = true
            }.buttonStyle(PillButton(kind: .solid, small: true))
            Button("Not now") {
              RelayOrchestrator.setSetting(true, forKey: Self.dismissedKey)
              answered = true
            }.buttonStyle(PillButton(kind: .quiet, small: true))
          }
        }
        Spacer(minLength: 0)
      }.padding(14).background(p.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
  }
}

/// The line after a Stop (F5): “Stopped this reply. 2 tasks are still working. Stop them too”,
/// a bare “stop” while idle (“2 tasks are working. Stop them · Keep them going”, or “Nothing is
/// running.”), and Stop Everything (“… paused until you resume. Resume”).
struct SereinStopNoticeRow: View {
  let notice: RelayStopNotice
  @ObservedObject var relay: RelayOrchestrator
  /// Try again on a stopped reply: the person's words once more. A stop is no error, so the line stays in ink.
  var retry: (() -> Void)? = nil
  @Environment(\.palette) var p
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(notice.text).font(UIStyle.meta).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
      switch notice {
      case .stoppedReply(let n, _):
        if let retry { action("Try again", help: "Send your last message again", retry) }
        // A new message in the person's name: whatever it runs asks as any turn does.
        action(RunSteering.resume, help: "Carry on from where it stopped") { _ = relay.ask(RunSteering.resumeWords) }
        if n > 0 { action("Stop them too", help: "Stop every task Serein started") { relay.stopTasks() } }
      case .idle(let n, _) where n > 0:
        action("Stop them", help: "Stop every task Serein started") { relay.stopTasks() }
        Text("·").font(UIStyle.meta).foregroundStyle(p.secondary).accessibilityHidden(true)
        action("Keep them going", help: "Let the tasks finish") { relay.stopNotice = nil }
      case .everything:
        action("Resume", help: "Resume Serein") { relay.resume() }
      case .steps:
        action(RunSteering.resume, help: "Carry on from where it stopped, with a fresh step budget") { _ = relay.ask(RunSteering.resumeWords) }
      default: EmptyView()
      }
      Spacer(minLength: 0)
    }.padding(.vertical, 4)
      .accessibilityElement(children: .contain)
      .onAppear {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: notice.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
      }
  }
  /// An action in the line, in the accent link style of the waiting line's Show, so it never
  /// reads as part of the sentence. (The font sits on the label: QuietButton sets its own.)
  private func action(_ title: String, help: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) { Text(title).font(UIStyle.metaStrong).foregroundStyle(p.accent) }
      .buttonStyle(QuietButton()).fixedSize().help(help)
  }
}

/// While Serein replies, the messages waiting for it to finish (Send when done): “Sends when
/// Serein is done: “also check trains” ×”.
struct SereinPendingChips: View {
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) var p
  var body: some View {
    if relay.working, !relay.pending.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(relay.pending.enumerated()), id: \.offset) { index, text in
          HStack(spacing: 6) {
            Text("Sends when Serein is done: “\(TaskWords.short(text))”").font(UIStyle.meta).foregroundStyle(p.secondary)
              .lineLimit(1)
            Button { relay.removePending(at: index) } label: {
              InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary).frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }.buttonStyle(.pressable).help("Do not send this").accessibilityLabel("Do not send: \(text)")
          }.padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
            .background(p.card, in: Capsule())
        }
      }
    }
  }
}

/// A task finished while the window is in front and Serein is not on screen (F8): a toast for
/// six seconds, “Done: Fix the failing checkout tests · Show”; several within that time collapse
/// into “2 tasks done · Show”, or “2 tasks finished · 1 needs you · Show”, so a task that waits on
/// you is never hidden in a count (Show then opens that one). It stays while hovered or focused,
/// and VoiceOver reads it. While Serein is on screen its strip lists every task, so the chip and
/// card change in place and nothing pops up. With the app in the background the notification says
/// it instead (TaskNotifications).
@MainActor enum SereinFinishToast {
  struct Finish {
    var id: String
    var title: String
    var outcome: RunRecord.Outcome
    /// It waits on an approval (an OK), not a question (an answer).
    var asks: Bool
    var serein: Bool
    var at: Date
  }
  private static var recent: [Finish] = []
  static let id = "serein-finished"
  static func ended(_ run: AgentRun, relay: RelayOrchestrator) {
    guard !run.spec.relay, [.done, .stuck, .waiting].contains(run.record.outcome) else { return }
    let thread = run.spec.threadID
    let serein = relay.isChild(thread)
    // Serein's own chats are not tasks.
    if !serein, relay.knownThreadIDs.contains(thread) { return }
    if serein, !onScreen(thread) { SereinSurface.main.unread = true }
    guard NSApp.isActive, let window = (NSApp.delegate as? AppDelegate)?.window, window.isKeyWindow,
      !onScreen(thread)
    else { return }
    let now = Date()
    recent.removeAll { now.timeIntervalSince($0.at) > 6 || $0.id == thread }
    let title = run.spec.title.isEmpty ? "Task" : String(run.spec.title.prefix(80))
    recent.append(Finish(id: thread, title: title, outcome: run.record.outcome, asks: !run.approvals.isEmpty, serein: serein,
                         at: now))
    show(recent)
  }
  /// The toast's words for these finishes, newest last.
  static func words(_ finishes: [Finish]) -> String {
    guard let last = finishes.last else { return "" }
    if finishes.count > 1 {
      let waiting = finishes.filter { $0.outcome == .waiting }.count
      if waiting > 0 { return "\(finishes.count) tasks finished · \(waiting) \(waiting == 1 ? "needs" : "need") you" }
      return finishes.allSatisfy { $0.outcome == .done } ? "\(finishes.count) tasks done" : "\(finishes.count) tasks finished"
    }
    switch last.outcome {
    case .stuck: return "Could not finish: \(last.title)"
    // As the notification says it: an approval wants an OK, a question wants an answer.
    case .waiting: return last.asks ? "\(last.title) needs your OK" : "\(last.title) needs your answer"
    default: return "Done: \(last.title)"
    }
  }
  private static func show(_ finishes: [Finish]) {
    // Show opens the one task: the only one, else the one that waits on you; else Serein.
    let target = finishes.count == 1 ? finishes.first
      : finishes.filter { $0.outcome == .waiting }.count == 1 ? finishes.first { $0.outcome == .waiting } : nil
    ToastCenter.shared.show(words(finishes), id: id, actionTitle: "Show", duration: previewing ? 60 : 6, opaque: true) {
      recent = []
      if let target {
        if target.serein { SereinRouter.openTask(target.id) } else { SereinRouter.open(threadID: target.id) }
      } else {
        SereinRouter.show()
      }
    }
  }
  private static var previewing = false
  /// `--ui-serein-toast [several]`: the toast as a finish shows it (Serein hidden, as it must be
  /// for a toast), in memory only.
  static func preview(several: Bool) {
    guard CommandLine.arguments.contains("--ui-preview") else { return }
    previewing = true
    let now = Date()
    let done = Finish(id: "relay-preview-child", title: "Fix the failing checkout tests", outcome: .done, asks: false,
                      serein: true, at: now)
    let waiting = Finish(id: "relay-preview-child-2", title: "Draft the release notes", outcome: .waiting, asks: true,
                         serein: true, at: now)
    show(several ? [done, waiting] : [done])
  }
  /// The task can be seen now: Serein is on screen (its strip lists every task, Serein's and
  /// direct ones, and its chat holds the cards), or the task's tab is in front.
  private static func onScreen(_ thread: String) -> Bool {
    if SereinSurface.main.place.shows { return true }
    guard let browser = SereinRouter.browser, let agent = SereinRouter.agent else { return false }
    return browser.section == ShellSection.thread && agent.conversationID == thread
  }
}
