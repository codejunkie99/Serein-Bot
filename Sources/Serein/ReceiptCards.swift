import AppKit
import SereinCore
import SwiftUI

// A receipt in the chat (`AgentMessage.receipts`, `Receipt`): one "Done." line and at most one
// card under the reply: a banner with its action, a routine with its switch, up to three rows,
// or the Undo toast with its draining bar. The host wrote it from facts after the change landed;
// the words are drawn as text.

/// What a receipt's buttons do: Undo goes back through the change's own journal
/// (`RelayOrchestrator.undoReceipt`), Copy link puts the link on the clipboard by its id
/// (`Receipt.item`, `copyLink`; the secret never shows), and a routine's switch pauses or turns
/// on that schedule by its id (`Receipt.item`, `setRoutineOn`). The switch never sends the
/// routine's stored words as the person's message: those words were written by a model, and
/// typed words can count as the person's consent.
@MainActor enum ReceiptActions {
  static func performUndo(_ token: UndoToken, relay: RelayOrchestrator) {
    relay.undoReceipt(token)
  }
  static func performBanner(_ receipt: Receipt, action: String, relay: RelayOrchestrator) {
    if action == "Undo", let token = receipt.undo {
      performUndo(token, relay: relay)
      return
    }
    if let item = receipt.item {
      relay.copyLink(item)
      return
    }
    if case .banner(let title, _, _)? = receipt.card { relay.ask("\(action): \(title)") }
  }
  /// The schedule a routine card stands for, by its id (`Receipt.item`, which
  /// `ScheduleRequest.receipt` sets); nil for a card saved before ids, or once it is gone.
  static func routine(_ receipt: Receipt, relay: RelayOrchestrator) -> RelayReminder? {
    guard let id = receipt.item else { return nil }
    return relay.reminders.first { $0.id == id }
  }
  /// The switch: a host intent on that schedule, keyed by its id (`setRoutineOn`, which keeps the
  /// limit on routines that act). A card with no id does nothing; nothing is sent to the model.
  static func performRoutine(_ receipt: Receipt, on: Bool, relay: RelayOrchestrator) {
    guard case .routine(_, _, _)? = receipt.card, let id = receipt.item else { return }
    relay.setRoutineOn(id: id, on: on)
  }
  /// Undo on a row of what Serein changed (`AgentLedger`), with no second way back: a note goes
  /// back the memory journal's way (`undo(_:)`), a schedule or an assistant change the way its
  /// receipt's Undo goes (`undoReceipt`), and the chat says so. A row whose Undo is off does nothing.
  static func performLedgerUndo(_ row: AgentLedger.Row, relay: RelayOrchestrator) {
    guard row.blocked == nil else { return }
    switch row.source {
    case .note(let id):
      if let entry = relay.journal.first(where: { $0.id == id }) { relay.undo(entry) }
    case .schedule(let id):
      performUndo(UndoToken(entry: RelayOrchestrator.scheduleUndoPrefix + id.uuidString, kind: .routine), relay: relay)
    case .team(let id):
      performUndo(UndoToken(entry: id.uuidString, kind: .assistantChanged), relay: relay)
    }
  }
}

/// A message's receipts: each line (unless the reply already says it) and its card, 38 points in.
struct ReceiptBlock: View {
  let receipts: [Receipt]
  /// The reply's own words, so a line it already holds is not said twice.
  let replyText: String
  @ObservedObject var relay: RelayOrchestrator
  /// Only the newest receipt shows its Undo; typed "undo that" reaches the older ones.
  var showsUndo = true
  @Environment(\.palette) private var p
  var body: some View {
    // Notes kept show nothing: remembering is Serein's own business, as a person's is. They are
    // in Library, and "undo that" still takes the last one back.
    VStack(alignment: .leading, spacing: AssistantMetrics.cardGap) {
      ForEach(Array(receipts.filter { $0.kind != .memorySaved }.enumerated()), id: \.offset) { _, receipt in
        if !replyText.contains(receipt.line) {
          Text(verbatim: receipt.line).font(AssistantType.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        ReceiptCardView(receipt: receipt, relay: relay, showsUndo: showsUndo)
          .pressGuard(receipt.line)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// The one card of a receipt.
struct ReceiptCardView: View {
  let receipt: Receipt
  @ObservedObject var relay: RelayOrchestrator
  var showsUndo = true
  var body: some View {
    switch receipt.card {
    case .banner(let title, let detail, let action)?:
      BannerCard(icon: Self.icon(receipt.kind), title: title, detail: detail, action: shownAction(action)) {
        if let action { ReceiptActions.performBanner(receipt, action: action, relay: relay) }
      }
    case .routine(let title, let detail, let on)?:
      RoutineCard(title: title, detail: detail, on: liveOn(stored: on)) { next in
        ReceiptActions.performRoutine(receipt, on: next, relay: relay)
      }
    case .rows(let rows)?:
      ReceiptRowsCard(rows: rows)
    case .toast(let text)?:
      if let token = receipt.undo, let ends = token.expires {
        UndoToastCard(text: text, ends: ends) { ReceiptActions.performUndo(token, relay: relay) }
      }
    case nil:
      EmptyView()
    }
  }
  /// "Undo" shows only while the change can still be undone.
  private func shownAction(_ action: String?) -> String? {
    guard let action else { return nil }
    if action == "Undo" { return showsUndo && receipt.undo?.isLive() == true ? action : nil }
    return action
  }
  /// The routine's switch follows the schedule itself when it is found.
  private func liveOn(stored: Bool) -> Bool {
    guard let reminder = ReceiptActions.routine(receipt, relay: relay) else { return stored }
    return reminder.paused != true
  }
  static func icon(_ kind: Receipt.Kind) -> String {
    switch kind {
    case .reminder: return "bell"
    case .hookMade: return "link"
    case .connected: return "checkmark.circle"
    default: return "info.circle"
    }
  }
}

/// A reminder, a link or a note (`bt-info`): an 18-point accent icon, the title in medium, the
/// detail in `meta`, and its action as an accent word, on an accent wash with an accent edge.
struct BannerCard: View {
  let icon: String
  let title: String
  let detail: String
  let action: String?
  let act: () -> Void
  @Environment(\.palette) private var p
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AssistantMetrics.bannerRadius, style: .continuous)
    HStack(spacing: 12) {
      InterfaceIcon(systemName: icon, size: 18).foregroundStyle(p.accent).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title).font(AssistantType.name).foregroundStyle(p.ink)
        if !detail.isEmpty {
          Text(verbatim: detail).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let action {
        Button(action: act) {
          Text(action).font(AssistantType.meta).foregroundStyle(p.accent).linkTarget()
        }.buttonStyle(AssistantPressStyle()).accessibilityLabel("\(action): \(title)")
      }
    }
    .padding(14)
    .background(p.accent.opacity(0.10), in: shape)
    .accessibilityElement(children: .contain)
  }
}

/// The boards' switch: 44 by 26, `accent` when on and `track` when off, a 22-point knob in
/// `onSolid` when on and `secondary` when off, that moves with the `pop` spring (at once under
/// Reduce Motion).
struct AssistantSwitch: View {
  let on: Bool
  let label: String
  let set: (Bool) -> Void
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    Button { set(!on) } label: {
      ZStack(alignment: on ? .trailing : .leading) {
        Capsule().fill(on ? p.accent : p.track).frame(width: 44, height: 26)
        // Off, the knob is `secondary`, so it keeps 3:1 against the track in both palettes.
        Circle().fill(on ? p.onSolid : p.secondary).frame(width: 22, height: 22)
          .shadow(color: p.shadow(0.15), radius: 1.5, y: 1)
          .padding(2)
      }
      .frame(width: 44, height: 26)
      .contentShape(Capsule())
    }
    .buttonStyle(.pressable)
    // Under Reduce Motion the knob is at its new end at once: no slide, no spring.
    .animation(reduce ? nil : Motion.pop, value: on)
    .accessibilityLabel(label)
    .accessibilityValue(on ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
  }
}

/// A routine and whether it runs (`control-switch-desc`): its time in medium, what it does in
/// `meta`, and the switch.
struct RoutineCard: View {
  let title: String
  let detail: String
  let on: Bool
  let set: (Bool) -> Void
  @Environment(\.palette) private var p
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: title).font(AssistantType.name).foregroundStyle(p.ink)
        Text(verbatim: detail).font(AssistantType.meta).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity, alignment: .leading)
      AssistantSwitch(on: on, label: title, set: set)
    }
    .padding(18)
    .frame(maxWidth: AssistantMetrics.cardWide)
    .assistantCard(p)
  }
}

/// Up to three short rows (`card-notification`), each its own card: a 40-point accent tile, the
/// title in medium with its date at the end, and one line of detail.
struct ReceiptRowsCard: View {
  let rows: [Receipt.Row]
  @Environment(\.palette) private var p
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(rows.prefix(Receipt.maxRows).enumerated()), id: \.offset) { _, row in
        HStack(spacing: 12) {
          InterfaceIcon(systemName: "doc", size: 16).foregroundStyle(p.overlay)
            .frame(width: 40, height: 40)
            .background(p.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Text(verbatim: row.title).font(AssistantType.name).foregroundStyle(p.ink).lineLimit(1)
              Spacer(minLength: 4)
              if let when = row.when { Text(verbatim: when).font(AssistantType.meta).foregroundStyle(p.secondary) }
            }
            if !row.detail.isEmpty {
              Text(verbatim: row.detail).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
            }
          }
        }
        .padding(14)
        .frame(maxWidth: AssistantMetrics.cardWide)
        .assistantCard(p)
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// The Undo toast after a removal (`bt-undo`): the `solid` plate, radius 14, the undo arrow, the
/// words in medium and an underlined Undo, with a 2-point bar along its foot that drains in the
/// 10 seconds Undo lasts. Then it goes. Under Reduce Motion there is no bar; the words say it.
struct UndoToastCard: View {
  let text: String
  let ends: Date
  let undo: () -> Void
  @State private var gone = false
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    let reduce: Bool = systemReduceMotion || previewReducedEffects
    let shape = RoundedRectangle(cornerRadius: AssistantMetrics.bannerRadius, style: .continuous)
    Group {
      if !gone && ends > Date() {
        HStack(spacing: 12) {
          InterfaceIcon(systemName: "arrow.uturn.backward", size: 16).foregroundStyle(p.onSolid).accessibilityHidden(true)
          // Under Reduce Motion the seconds go under the words, so the words keep their room.
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: text).font(AssistantType.name).foregroundStyle(p.onSolid).lineLimit(1)
            if reduce { secondsLeft }
          }
          Spacer(minLength: 8)
          Button(action: undo) {
            Text("Undo").font(AssistantType.name).foregroundStyle(p.onSolid).underline().linkTarget()
          }.buttonStyle(AssistantPressStyle()).accessibilityLabel("Undo: \(text)")
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .frame(maxWidth: 320)
        .background(p.solid, in: shape)
        .overlay(alignment: .bottom) {
          if !reduce {
            DrainingBar(color: p.onSolid.opacity(0.5), ends: ends, total: UndoToken.removalWindow)
              .frame(height: 2).padding(.horizontal, 14).padding(.bottom, 4)
          }
        }
        .shadow(color: p.shadow(0.15), radius: 12, y: 5)
        .transition(Motion.arrival(reduce))
      }
    }
    .frame(maxWidth: .infinity)
    .animation(Motion.leaving(reduce), value: gone)
    .task(id: ends) {
      let left: TimeInterval = ends.timeIntervalSinceNow
      if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
      gone = true
    }
  }
  /// Reduce Motion has no bar: the words say how long Undo lasts.
  private var secondsLeft: some View {
    Text("Undo for 10 seconds").font(AssistantType.meta).foregroundStyle(p.onSolid.opacity(0.7)).lineLimit(1)
  }
}

/// "Make it a routine?" (board 13; `AgentMessage.routineOffer`, `RoutineOffer`): an `accent`
/// clock, the title in 13 medium, the detail in 13 `secondary`, then Make it (`solid`) and Not now
/// (`track`), each 32 high, in a card at most 440 wide. Made or declined, it is one quiet line
/// ("Made.", "Okay, not now.") with no buttons. The host writes its words (RoutineOffers.swift);
/// they are drawn as text. Make it and Not now are host intents keyed by the offer's id.
struct RoutineOfferCard: View {
  let offer: RoutineOffer
  @ObservedObject var relay: RelayOrchestrator
  @Environment(\.palette) private var p
  var body: some View {
    switch offer.state {
    case .open: openCard
    case .made: quietLine("Made.")
    case .declined: quietLine("Okay, not now.")
    }
  }
  private var openCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        InterfaceIcon(systemName: "clock", size: 16).foregroundStyle(p.accent).accessibilityHidden(true)
        Text(verbatim: offer.title).font(AssistantType.name).foregroundStyle(p.ink)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(verbatim: offer.detail).font(AssistantType.body).foregroundStyle(p.secondary)
        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: AssistantMetrics.chipGap) {
        Button { relay.acceptRoutineOffer(offer.id) } label: {
          capsule("Make it", ink: p.onSolid, ground: p.solid)
        }
        .buttonStyle(AssistantPressStyle())
        .accessibilityLabel("Make it")
        .accessibilityHint("\(offer.when): \(offer.what)")
        Button { relay.declineRoutineOffer(offer.id) } label: {
          capsule("Not now", ink: p.ink, ground: p.track)
        }
        .buttonStyle(AssistantPressStyle())
        .accessibilityLabel("Not now")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .frame(maxWidth: AssistantMetrics.cardWide, alignment: .leading)
    .assistantCard(p)
    .pressGuard(offer.id)
    // ⌘Return in an empty message bar: Make it, while this is the newest card that waits. Esc on
    // the focused card: Not now (SPEC.md 2.0 keys).
    .modifier(PrimaryCardKey(key: "routine:" + offer.id, active: true, press: { [relay = self.relay, id = self.offer.id] in
      relay.acceptRoutineOffer(id)
    }))
    .onExitCommand { relay.declineRoutineOffer(offer.id) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(offer.title)
  }
  private func capsule(_ words: String, ink: Color, ground: Color) -> some View {
    Text(words).font(AssistantType.meta).foregroundStyle(ink)
      .padding(.horizontal, 14).frame(height: 32)
      .background(ground, in: Capsule())
      .contentShape(Capsule())
  }
  private func quietLine(_ words: String) -> some View {
    HStack(spacing: 8) {
      InterfaceIcon(systemName: "clock", size: 13).foregroundStyle(p.secondary).accessibilityHidden(true)
      Text(words).font(AssistantType.meta).foregroundStyle(p.secondary)
    }
    .frame(minHeight: 24)
    .accessibilityElement(children: .combine)
  }
}

/// The newest waiting card's primary button, for ⌘Return in an empty message bar (SPEC.md 2.0
/// keys). A card offers its primary while it shows and waits (`PrimaryCardKey`); the newest offer
/// wins. The message bar holds the key only while it is empty and no approval card waits.
@MainActor final class ChatCardKeys: ObservableObject {
  static let shared = ChatCardKeys()
  private var offers: [(key: String, press: () -> Void)] = []
  @Published private(set) var hasPrimary = false
  func offer(_ key: String, press: @escaping () -> Void) {
    offers.removeAll { $0.key == key }
    offers.append((key: key, press: press))
    if !hasPrimary { hasPrimary = true }
  }
  func withdraw(_ key: String) {
    offers.removeAll { $0.key == key }
    let any: Bool = !offers.isEmpty
    if hasPrimary != any { hasPrimary = any }
  }
  func pressPrimary() { offers.last?.press() }
}

/// Offers a card's primary button to ⌘Return while `active` (the card waits for a press).
struct PrimaryCardKey: ViewModifier {
  let key: String
  let active: Bool
  let press: () -> Void
  func body(content: Content) -> some View {
    content
      .onAppear { if active { ChatCardKeys.shared.offer(key, press: press) } }
      .onChange(of: active) { _, now in
        if now { ChatCardKeys.shared.offer(key, press: press) } else { ChatCardKeys.shared.withdraw(key) }
      }
      .onDisappear { ChatCardKeys.shared.withdraw(key) }
  }
}

/// A card's buttons take a press only 0.3 seconds after the card appears or changes (SPEC.md 2.7,
/// G10), so a card that moves under the pointer is never pressed by mistake.
struct PressGuard: ViewModifier {
  /// What the card shows; a change arms the guard again.
  var key: String
  @State private var armed = false
  func body(content: Content) -> some View {
    content
      .allowsHitTesting(armed)
      .task(id: key) {
        armed = false
        try? await Task.sleep(nanoseconds: 300_000_000)
        armed = true
      }
  }
}

extension View {
  /// The card's 0.3-second press guard, armed again whenever `key` changes.
  func pressGuard(_ key: String) -> some View { modifier(PressGuard(key: key)) }
  /// A text link's press area on the personal-assistant screens: at least 24 by 24 points
  /// (WCAG 2.5.8), with its words drawn as before.
  func linkTarget() -> some View { frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }
}
