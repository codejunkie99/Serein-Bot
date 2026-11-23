import AppKit
import Combine
import SereinCore
import SwiftUI

/// The guide's one store. New-user evidence is seeded once after Serein's transcript is loaded;
/// normal progress comes from successful app events, including while the guide is hidden.
@MainActor final class GuideCenter: ObservableObject {
  static let shared = GuideCenter()
  @Published private(set) var state: SereinGuide
  @Published private(set) var visibleItems: [UUID: Set<SereinGuide.Item>] = [:]
  @Published private(set) var expansionRequested = false
  private let defaults: UserDefaults
  private let persists: Bool
  private var needsUpgradeSeed: Bool

  init(defaults: UserDefaults = .standard, persists: Bool = RelayOrchestrator.persists) {
    self.defaults = defaults
    self.persists = persists
    // Previews and checks leave existing fixtures unchanged; an explicit guide preview seeds
    // its visible state later, independently of the user's completed or hidden guide.
    let saved = persists ? defaults.data(forKey: SereinGuide.defaultsKey)
      .flatMap { try? JSONDecoder().decode(SereinGuide.self, from: $0) } : nil
    needsUpgradeSeed = saved == nil
    var initial = saved ?? SereinGuide(hidden: !persists)
    initial.beginLaunch()
    state = initial
    if saved != nil { save() }
  }
  func bootstrap(transcriptNotEmpty: Bool, barEnabled: Bool, barUsed: Bool, approvalsUserSet: Bool) {
    guard needsUpgradeSeed else { return }
    needsUpgradeSeed = false
    change { $0.preTick(transcriptNotEmpty: transcriptNotEmpty, barEnabled: barEnabled,
                        barUsed: barUsed, approvalsUserSet: approvalsUserSet) }
  }
  func record(_ event: SereinGuide.Event) {
    if persists, event == .barSent || event == .barHeld { defaults.set(true, forKey: SereinGuide.barUsedKey) }
    change { $0.record(event) }
  }
  func hide() {
    change { $0.hide() }
    expansionRequested = false
    ToastCenter.shared.show(SereinGuide.hiddenToast)
  }
  /// Help and Settings reopen the existing guide, preserving every tick.
  func showAgain() {
    change { $0.showAgain() }
    expansionRequested = true
    // Help can be used from Settings too. Reveal the guide without closing a nested
    // confirmation/setup sheet or an AI-app connection that is still in progress.
    let window = (NSApp.delegate as? AppDelegate)?.window
    if window?.attachedSheet?.attachedSheet == nil, NSApp.modalWindow == nil,
      !SereinConnect.shared.presented {
      SereinRouter.browser?.showSettings = false
    }
    SereinRouter.bringWindowForward?()
    SereinRouter.show()
  }
  func presentation(connected: Bool, inChat: Bool = true, inBar: Bool = false,
                    hasMessages: Bool = false, isWorking: Bool = false,
                    hasPendingQuestion: Bool = false) -> SereinGuide.Presentation {
    state.presentation(connected: connected, inChat: inChat, inBar: inBar, hasMessages: hasMessages,
                       isWorking: isWorking, hasPendingQuestion: hasPendingQuestion)
  }
  func didPresent(_ presentation: SereinGuide.Presentation) {
    change { $0.shown(presentation, at: Date()) }
  }
  func consumeExpansionRequest() -> Bool {
    let requested = expansionRequested
    if requested { expansionRequested = false }
    return requested
  }
  /// The hint policy uses this to suppress the beside tip while its expanded guide row shows.
  func itemVisible(_ item: SereinGuide.Item) -> Bool { visibleItems.values.contains { $0.contains(item) } }
  func visible(_ items: Set<SereinGuide.Item>, owner: UUID) {
    guard (visibleItems[owner] ?? []) != items else { return }
    visibleItems[owner] = items.isEmpty ? nil : items
  }
  /// Deterministic `--ui-guide 0|2|5` snapshots; no defaults are written.
  func preview(completed: Int) {
    guard !persists else { return }
    needsUpgradeSeed = false
    state = SereinGuide(done: Set(SereinGuide.Item.allCases.prefix(max(0, min(completed, 5)))))
  }
  private func change(_ mutate: (inout SereinGuide) -> Void) {
    var next = state
    mutate(&next)
    guard next != state else { return }
    state = next
    save()
  }
  private func save() {
    guard persists, let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: SereinGuide.defaultsKey)
  }
}

/// Full card in the empty chat, or one compact line above the composer. The compact line opens
/// this same card in a popover; approvals and questions keep their place in the chat.
struct GuideCard: View {
  @ObservedObject var relay: RelayOrchestrator
  let presentation: SereinGuide.Presentation
  @ObservedObject private var guide: GuideCenter
  @Environment(\.palette) private var p
  @State private var expanded = false
  @State private var asksOpen = false
  @State private var visibleOwner = UUID()
  @State private var shortcutRevision = 0
  @AppStorage(RelayOrchestrator.enabledKey) private var barEnabled = false
  @AppStorage(RelayOrchestrator.summonKey) private var shortcut = RelayHotKey.summon

  init(relay: RelayOrchestrator, presentation: SereinGuide.Presentation, guide: GuideCenter = .shared) {
    self.relay = relay
    self.presentation = presentation
    self.guide = guide
  }
  private var controller: RelayController? { RelayController.shared }
  private var anywhere: SereinGuide.Anywhere {
    _ = shortcutRevision
    return controller?.summonTaken == true ? .taken : barEnabled ? .on : .off
  }
  private var shortcutLabel: String { RelayHotKey.symbols(shortcut) }
  private var visibleItems: Set<SereinGuide.Item> { presentation == .expanded ? Set(SereinGuide.Item.allCases) : [] }

  var body: some View {
    Group {
      switch presentation {
      case .hidden: EmptyView()
      case .expanded: fullCard
      case .collapsed:
        Button { expanded = true } label: {
          HStack(spacing: 6) {
            Text(guide.state.heading).font(UIStyle.meta)
            InterfaceIcon(systemName: "chevron.right", size: 9)
            Spacer(minLength: 0)
          }.foregroundStyle(p.secondary).contentShape(Rectangle())
        }.buttonStyle(.pressable).help("Open the getting-started guide")
          .accessibilityLabel(guide.state.heading + ". Open guide")
          .popover(isPresented: $expanded, arrowEdge: .top) {
            GuideCard(relay: relay, presentation: .expanded, guide: guide)
              .frame(width: 340).padding(12).environment(\.palette, p)
          }
      case .completed:
        HStack(alignment: .top, spacing: 8) {
          InterfaceIcon(systemName: "checkmark.circle", size: 13).foregroundStyle(p.secondary)
          Text(SereinGuide.completedLine).font(UIStyle.meta).foregroundStyle(p.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
      }
    }
    .onAppear {
      guide.didPresent(presentation)
      guide.visible(visibleItems, owner: visibleOwner)
      if guide.consumeExpansionRequest(), presentation == .collapsed { expanded = true }
    }
    .onChange(of: presentation) { _, next in
      guide.didPresent(next)
      guide.visible(visibleItems, owner: visibleOwner)
    }
    .onChange(of: guide.state.firstUndone) { _, _ in guide.visible(visibleItems, owner: visibleOwner) }
    .onChange(of: guide.expansionRequested) { _, requested in
      if requested, guide.consumeExpansionRequest(), presentation == .collapsed { expanded = true }
    }
    .onDisappear { guide.visible([], owner: visibleOwner) }
  }

  private var fullCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(guide.state.heading).font(UIStyle.bodyStrong).foregroundStyle(p.ink)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        Button("Hide") { expanded = false; guide.hide() }.buttonStyle(.pressable)
          .font(UIStyle.meta).foregroundStyle(p.secondary).help(SereinGuide.hideHelp)
      }
      ForEach(SereinGuide.Item.allCases) { item in
        row(item)
      }
      if guide.state.complete {
        Text(SereinGuide.completedLine).font(UIStyle.meta).foregroundStyle(p.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(p.card, in: RoundedRectangle(cornerRadius: UIStyle.panelRadius))
      .accessibilityElement(children: .contain)
  }
  private func row(_ item: SereinGuide.Item) -> some View {
    let done = guide.state.done.contains(item)
    let current = guide.state.firstUndone == item
    return HStack(alignment: .top, spacing: 9) {
      InterfaceIcon(systemName: done ? "checkmark.circle.fill" : "circle", size: 13)
        .foregroundStyle(done ? p.secondary : current ? p.ink : p.faint)
        .frame(width: 15, height: 18).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 7) {
        Text(item.title).font(UIStyle.body).foregroundStyle(done ? p.secondary : p.ink)
          .fixedSize(horizontal: false, vertical: true)
        if current {
          Text(SereinGuide.subtitle(item, anywhere: anywhere, riskyOnly: relay.level == .riskyOnly,
                                    shortcut: shortcutLabel))
            .font(UIStyle.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
          Button(SereinGuide.button(item, anywhere: anywhere, shortcut: shortcutLabel)) { act(item) }
            .buttonStyle(PrimaryButton())
            .popover(isPresented: item == .asks ? $asksOpen : .constant(false), arrowEdge: .bottom) {
              asksPopover
            }
        }
      }
      Spacer(minLength: 0)
    }.accessibilityElement(children: .contain)
      .accessibilityLabel(item.title + (done ? ", done" : current ? ", next" : ""))
  }
  @ViewBuilder private var asksPopover: some View {
    if let controller {
      VStack(alignment: .leading, spacing: 12) {
        Text("Serein asks before").font(UIStyle.bodyStrong).accessibilityAddTraits(.isHeader)
        AskBeforeControl(relay: relay, controller: controller)
        Divider().overlay(p.line)
        HStack {
          Spacer()
          Button("Keep this") {
            // Keeping the current choice is an explicit confirmation, including the default.
            relay.setLevel(relay.level)
            guide.record(.approvalChoiceKept)
            asksOpen = false
          }.buttonStyle(PrimaryButton())
        }
        Text(ApprovalLevel.footnote(killLabel: controller.killLabel)).font(UIStyle.meta)
          .foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }.padding(16).frame(width: 320).environment(\.palette, p)
    }
  }
  private func act(_ item: SereinGuide.Item) {
    switch item {
    case .ask:
      SereinRouter.ask("What can you do?", page: SereinPageChip.shared.pageForSend())
    case .beside:
      relay.browser.openInDefaultBrowser("https://serein.pro")
      SereinRouter.keepBeside()
      SereinRouter.show()
    case .do:
      SereinRouter.ask("Remind me at 5 pm to stretch", page: SereinPageChip.shared.pageForSend())
    case .anywhere:
      guard let controller else { return }
      switch anywhere {
      case .on: controller.show()
      case .off:
        RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.enabledKey)
        controller.install()
      case .taken:
        RelayOrchestrator.setSetting("ctrl+opt+space", forKey: RelayOrchestrator.summonKey)
        RelayOrchestrator.setSetting(true, forKey: RelayOrchestrator.enabledKey)
        controller.install()
      }
      shortcutRevision += 1
    case .asks: asksOpen = true
    }
  }
}
