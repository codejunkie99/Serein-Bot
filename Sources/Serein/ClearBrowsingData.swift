import SereinCore
import SwiftUI
import WebKit

/// Settings › Privacy › Clear saved data: a time range, a checkbox per kind of data and the
/// count each would clear, shown before anything is removed.
struct ClearBrowsingDataSheet: View {
  @ObservedObject var browser: BrowserModel
  @ObservedObject var agent: AgentModel
  var close: () -> Void
  @State private var range: ClearRange = .lastHour
  @State private var kinds: Set<ClearKind> = Set(ClearKind.allCases.filter(\.onByDefault))
  @State private var siteCount: Int?
  @State private var busy = false
  @Environment(\.palette) var p
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader("Clear saved data", subtitle: "Only data in Serein's library.") {
        EmptyView()
      }
      HStack {
        Text("Time range")
        Spacer()
        SettingsPopUp("Time range", selection: $range,
          choices: ClearRange.allCases.map { SettingsChoice(value: $0, label: $0.title) }, showsTitle: false)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(ClearKind.allCases) { kind in
          row(kind)
          if kind != ClearKind.allCases.last { Divider().overlay(p.line) }
        }
      }.padding(.horizontal, 12).card(p)
      HStack {
        Spacer()
        Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        Button(busy ? "Clearing…" : "Clear") { clear() }.buttonStyle(PrimaryButton())
          .disabled(busy || kinds.isEmpty || total == 0)
          .help(total == 0 ? "Nothing in this range to clear" : "Clears the checked data. This can't be undone.")
      }
    }.padding(24).frame(width: UIStyle.wide(520)).background(p.panel).foregroundStyle(p.ink).font(UIStyle.body)
      .buttonStyle(QuietButton()).controlSize(.small).tint(p.accent)
      .task { await countSites() }
      // The counts cover every saved day, not only the launch window.
      .task { await browser.loadAllVisits() }
      .onChange(of: range) { _, _ in Task { await countSites() } }
  }
  func row(_ kind: ClearKind) -> some View {
    let n = count(kind)
    return Toggle(
      isOn: Binding(
        get: { kinds.contains(kind) },
        set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } })
    ) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(kind.title)
          Spacer(minLength: 8)
          Text(BrowsingDataClear.summary(kind: kind, count: n, range: range))
            .font(UIStyle.microMono).foregroundStyle(p.faint)
        }
        Text(kind.detail).role(.meta)
      }
    }.toggleStyle(.checkbox).padding(.vertical, 10)
      .accessibilityValue(BrowsingDataClear.summary(kind: kind, count: n, range: range))
  }
  var total: Int {
    kinds.reduce(0) { sum, kind in sum + (count(kind) ?? 1) }
  }

  // MARK: Counts

  var downloads: [DownloadCenter.Item] {
    DownloadCenter.shared.items.filter { $0.state != .downloading && $0.state != .choosing }
  }
  var passages: [Mark] { browser.marks.filter { !$0.quote.isEmpty } }
  /// Every chat, Serein's own included: clearing browsing data leaves nothing behind, though no
  /// chat list shows Serein's chats (Delete Threads never deletes them). Its row's detail says so.
  var threads: [Conversation] {
    agent.conversations.filter { agent.hub.run(for: $0.id) == nil }
  }
  /// nil for cookies in a limited range: WebKit clears by time but cannot count by time.
  func count(_ kind: ClearKind) -> Int? {
    switch kind {
    case .history:
      return BrowsingDataClear.count(browser.visits, kind: kind, range: range) { $0.date }
    case .downloads:
      return BrowsingDataClear.count(downloads, kind: kind, range: range) { $0.startedAt }
    case .cookies:
      // All time also signs Serein out of every site it stays signed in to.
      guard range == .allTime, let sites = siteCount else { return nil }
      return sites + KeptSignIns.listed().count
    case .passages:
      return BrowsingDataClear.count(passages, kind: kind, range: range) { $0.date }
    case .threads:
      // Only a new message makes a thread recent; opening it does not.
      return threads.filter { ThreadActivity.inRange($0.lastMessageAt, range: range) }.count
    case .permissions: return SitePermissionStore.shared.entries.count
    case .recentlyClosed:
      return browser.recentlyClosed.count + SessionExtras.shared.folded.reduce(0) { $0 + $1.tabs.count }
        + ClosedWindows.stack.reduce(0) { $0 + $1.count }
    }
  }
  func countSites() async {
    guard range == .allTime else { return }
    let records = await WKWebsiteDataStore.default().dataRecords(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
    siteCount = records.count
  }

  // MARK: Clearing

  /// "All time": the whole history and day-summary folders go, with the search index,
  /// recently closed and folded tabs, as before ranges existed.
  func clearAllHistory() throws -> Int {
    let count = browser.visits.count
    let fm = FileManager.default
    for folder in ["history", "index/days"] {
      let url = browser.library.root.appendingPathComponent(folder)
      for item in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
        try fm.removeItem(at: item)
      }
    }
    browser.historyClears += 1
    browser.visits = []
    browser.timelines = [:]
    SessionExtras.shared.forgetHistory(nil)
    // Also tells on-screen search results to clear.
    browser.clearSemanticHistory()
    return count
  }
  /// A time range: matching visits go, and every day the range touches loses its summary and
  /// episodes, which were written from those visits. A summary is made again on demand.
  func clearHistory(now: Date) throws -> Int {
    let result = try browser.library.removeVisits(in: range, now: now)
    browser.historyClears += 1
    browser.visits.removeAll { range.contains($0.date, now: now) }
    let touched = result.days.union(result.removed.map { BrowserModel.dayKey($0.date) })
    for key in touched {
      try? FileManager.default.removeItem(
        at: browser.library.root.appendingPathComponent("index/days/\(key).json"))
      browser.timelines.removeValue(forKey: key)
    }
    SessionExtras.shared.forgetHistory(Set(result.removed.map(\.url)))
    browser.pruneSemanticIndex()
    // Search results on screen may show removed visits; they are cleared.
    NotificationCenter.default.post(name: .sereinHistoryCleared, object: nil)
    return result.removed.count
  }

  func clear() {
    busy = true
    var done: [String] = []
    let now = Date()
    func inRange(_ date: Date) -> Bool { range.contains(date, now: now) }
    if kinds.contains(.history) {
      do {
        let removed: Int
        if range == .allTime {
          removed = try clearAllHistory()
        } else {
          removed = try clearHistory(now: now)
        }
        if removed > 0 { done.append("\(removed) visit\(removed == 1 ? "" : "s")") }
      } catch { browser.notice = error.localizedDescription }
    }
    if kinds.contains(.downloads) {
      let gone = Set(downloads.filter { inRange($0.startedAt) }.map(\.id))
      DownloadCenter.shared.items.removeAll { gone.contains($0.id) }
      if !gone.isEmpty { done.append("\(gone.count) download\(gone.count == 1 ? "" : "s")") }
    }
    if kinds.contains(.passages) {
      let before = browser.marks.count
      browser.marks.removeAll { !$0.quote.isEmpty && inRange($0.date) }
      let n = before - browser.marks.count
      if n > 0 {
        try? browser.library.save(browser.marks, to: "marks/saved.json")
        done.append("\(n) passage\(n == 1 ? "" : "s")")
      }
    }
    if kinds.contains(.threads) {
      let ids = Set(
        threads.filter { ThreadActivity.inRange($0.lastMessageAt, range: range, now: now) }.map(\.id))
      let n = agent.flow.deleteThreads(ids)
      for id in ids { InterruptedRunCenter.shared.resolve(thread: id) }
      if n > 0 { done.append("\(n) chat\(n == 1 ? "" : "s")") }
    }
    if kinds.contains(.permissions) {
      let n = SitePermissionStore.shared.entries.count
      SitePermissionStore.shared.forgetAll()
      if n > 0 { done.append("\(n) site choice\(n == 1 ? "" : "s")") }
    }
    if kinds.contains(.recentlyClosed) {
      let n = count(.recentlyClosed) ?? 0
      SessionExtras.shared.forgetHistory(nil)
      if n > 0 { done.append("\(n) closed page\(n == 1 ? "" : "s")") }
    }
    if kinds.contains(.cookies) {
      // Serein's kept sign-ins go too: all of them for All time, else those used within the range.
      let ending: [KeptSignIn] = KeptSignIns.listed().filter { range == .allTime || inRange($0.lastUsed) }
      if range == .allTime {
        browser.taskStores.signOut(nil)
      } else {
        for signIn in ending { browser.taskStores.signOut(signIn.site) }
      }
      let n: Int = ending.count
      if n > 0 { done.append("\(n) kept sign-in\(n == 1 ? "" : "s")") }
    }
    let cleared = done
    let finish: @MainActor (String?) -> Void = { extra in
      let all = cleared + (extra.map { [$0] } ?? [])
      busy = false
      ToastCenter.shared.show(all.isEmpty ? "Nothing to clear." : "Cleared " + all.joined(separator: ", ") + ".")
      close()
    }
    if kinds.contains(.cookies) {
      WKWebsiteDataStore.default().removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
        modifiedSince: range.start(now: now) ?? .distantPast
      ) { Task { @MainActor in finish("cookies and site data") } }
    } else {
      finish(nil)
    }
  }
}
