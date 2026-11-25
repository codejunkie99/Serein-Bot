import AppKit
import Combine
import SereinCore
import SwiftUI

/// What the chip slot on Serein's composer shows.
enum SereinChipSlot: Equatable {
  case none
  /// The tab in view; `last` in Serein full, where the last page you were on stays for 10 minutes.
  case page(SereinPage, last: Bool)
  /// A private tab: “Private tab · not shared”, which cannot be removed.
  case privateTab
  var page: SereinPage? {
    if case .page(let page, _) = self { return page }
    return nil
  }
}

/// The page chip: it follows the selected tab while Serein is beside it, and a × on it sticks for
/// that tab. In Serein full the last page you were on stays for 10 minutes. Private tabs are never
/// shared, and Settings › Privacy › “The page you're viewing” turns the chip off.
/// Only the ⌥Space bar from another app goes without it.
@MainActor final class SereinPageChip: ObservableObject {
  static let shared = SereinPageChip()
  /// Settings › Privacy › “The page you're viewing” (on unless turned off).
  static let shareKey = "serein.assistant.sharePage"
  /// The first chip's line was dismissed (Got it, or a message sent with the chip).
  static let seenKey = "serein.assistant.pageChipSeen"
  /// In GateSettings; on unless turned off, and off while that file cannot be read.
  static var sharing: Bool { GateSettings.shared.object(forKey: shareKey) as? Bool ?? !GateSettings.shared.unreadable }

  @Published private(set) var slot: SereinChipSlot = .none
  /// Tabs whose chip you took off; it stays off for that tab.
  private(set) var removed: Set<String> = []
  /// The page you left for Serein full, and when.
  private(set) var left: (page: SereinPage, at: Date)?
  @Published private(set) var seen = UserDefaults.standard.bool(forKey: SereinPageChip.seenKey)

  private weak var browser: BrowserModel?
  private var watches: [AnyCancellable] = []
  private var tabWatch: AnyCancellable?
  private var watchedTab: String?
  private var expiry: DispatchWorkItem?

  func attach(_ browser: BrowserModel) {
    self.browser = browser
    watches = [
      browser.$selected.removeDuplicates().sink { [weak self] _ in self?.soon() },
      browser.$section.removeDuplicates().sink { [weak self] _ in self?.soon() },
      browser.$tabs.map { $0.map(\.id) }.removeDuplicates().sink { [weak self] _ in self?.soon() },
    ]
    refresh()
  }
  /// `@Published` sends before the value is stored: read it on the next turn.
  private func soon() { DispatchQueue.main.async { [weak self] in self?.refresh() } }

  /// Works the slot out again (a selection, a title, a setting or a × changed).
  func refresh(now: Date = Date()) {
    guard let browser else { return }
    let active = browser.section == ShellSection.browser ? browser.active : nil
    let lastTab = left.flatMap { left in browser.tabs.first { $0.id == left.page.tabID } }
    // The last page may finish loading or navigate while Serein is full. Keep its visible chip
    // in sync with the page that pageForSend will actually bind, and drop it if the tab closes.
    let observedTab = active ?? (browser.section == ShellSection.serein ? lastTab : nil)
    if watchedTab != observedTab?.id {
      watchedTab = observedTab?.id
      tabWatch = observedTab.map { tab in
        tab.$title.combineLatest(tab.$address).dropFirst().sink { [weak self] _ in self?.soon() }
      }
    }
    let next = Self.slot(
      section: browser.section, active: active.map(Self.page), removed: removed,
      left: left.flatMap { left in lastTab.map { (Self.page($0), left.at) } },
      sharing: Self.sharing, now: now)
    if next != slot { slot = next }
  }
  /// The rule (no state of its own, so a check can drive it).
  static func slot(section: String, active: SereinPage?, removed: Set<String>, left: (SereinPage, Date)?,
                   sharing: Bool, now: Date) -> SereinChipSlot {
    guard sharing else { return .none }
    if section == ShellSection.browser, let active {
      if active.isPrivate { return .privateTab }
      guard CurrentPageContext.shareable(active.url), !removed.contains(active.tabID) else { return .none }
      return .page(active, last: false)
    }
    // A site set to Never after you left it stays out too (SiteRules).
    if section == ShellSection.serein, let (page, at) = left, !page.isPrivate, CurrentPageContext.shareable(page.url),
      SiteRules.rule(for: page.url) != .never,
      !removed.contains(page.tabID), CurrentPageContext.stillCurrent(left: at, now: now)
    {
      return .page(page, last: true)
    }
    return .none
  }
  /// A tab as the chip reads it. A source view is never shared, like a private tab's contents.
  static func page(_ tab: BrowserTab) -> SereinPage {
    SereinPage(tabID: tab.id, title: tab.title, url: tab.hiddenFromAgents ? "" : tab.address, isPrivate: tab.privateMode)
  }
  /// Serein full is shown from a page: that page stays the chip's for 10 minutes.
  func leaving(_ browser: BrowserModel) {
    guard browser.section == ShellSection.browser, let tab = browser.active, !tab.privateMode else { return }
    left = (Self.page(tab), Date())
    expiry?.cancel()
    let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    expiry = work
    DispatchQueue.main.asyncAfter(deadline: .now() + CurrentPageContext.lastPageLifetime + 1, execute: work)
  }
  /// × on the chip: off for this tab.
  func remove(_ tabID: String) {
    removed.insert(tabID)
    refresh()
  }
  /// ⌥⌘E and ⋯ › Ask Serein About This Page put the chip back for this tab.
  func restore(_ tabID: String) {
    guard removed.remove(tabID) != nil else { return }
    refresh()
  }
  /// The page the next message carries, worked out at the moment it is sent.
  func pageForSend() -> SereinPage? {
    refresh()
    return slot.page
  }
  /// Got it on the first chip's line, or the first message that carried a chip.
  func markSeen() {
    guard !seen else { return }
    seen = true
    RelayOrchestrator.setSetting(true, forKey: Self.seenKey)
  }
}

/// The page chip in the chip row above Serein's composer: “[icon] Ramen guide · Eater ×”, “This page:
/// …” in Serein full, or “Private tab · not shared” (which cannot be removed).
struct SereinPageChipSlot: View {
  @ObservedObject var chip = SereinPageChip.shared
  @ObservedObject var surface = SereinSurface.main
  @Environment(\.palette) var p
  var body: some View {
    switch chip.slot {
    case .none: EmptyView()
    case .privateTab:
      HStack(spacing: 6) {
        InterfaceIcon(systemName: "eye.slash", size: 11).foregroundStyle(p.secondary)
        Text(CurrentPageContext.privateChip).font(UIStyle.meta).foregroundStyle(p.secondary).lineLimit(1).fixedSize()
      }.padding(.horizontal, 8).frame(height: 24)
        .overlay(Capsule().strokeBorder(p.line))
        .help("Nothing about a private tab goes to Serein")
        .accessibilityElement(children: .combine).accessibilityLabel(CurrentPageContext.privateChip)
    case .page(let page, let last):
      // ⌥⌘E's chip with the page text stands for the same tab: this one steps aside.
      if !surface.attachments.contains(where: { $0.page?.tabID == page.tabID }) {
        HStack(spacing: 6) {
          SiteIconImage(address: page.url, size: 12)
          Text(last ? CurrentPageContext.lastPageChip(page.title) : page.title)
            .font(UIStyle.meta).lineLimit(1).truncationMode(.tail)
          Button { chip.remove(page.tabID) } label: {
            InterfaceIcon(systemName: "xmark", size: 9).foregroundStyle(p.secondary).frame(width: 16, height: 16)
              .contentShape(Rectangle())
          }.buttonStyle(.pressable).help("Leave this tab out").accessibilityLabel("Leave this tab out")
        }.padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
          .background(p.card, in: Capsule())
          .help(CurrentPageContext.chipHelp)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("\(page.title). \(CurrentPageContext.chipHelp)")
      }
    }
  }
}

/// The first page chip ever: one line under it says what Serein sees, with Got it. Inline, so it
/// is never held back like a tip.
struct SereinPageChipLine: View {
  @ObservedObject var chip = SereinPageChip.shared
  @Environment(\.palette) var p
  var body: some View {
    if !chip.seen, chip.slot.page != nil {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(CurrentPageContext.firstTimeLine).font(UIStyle.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button("Got it") { chip.markSeen() }.buttonStyle(QuietButton()).font(UIStyle.meta).fixedSize()
      }.accessibilityElement(children: .contain)
    }
  }
}
