import Combine
import SereinCore
import SwiftUI

/// One ask waiting on the person in Serein's chat: an approval, or a session in another app that
/// needs an answer. The card at the foot of Serein's reply shows them one at a time, oldest first.
/// Serein's own question forms have their own card there (`QuestionFormCard`).
enum DecisionAsk: Identifiable {
  case approval(RelayOrchestrator.Approval)
  /// The session, and when its newest "needs you" text arrived.
  case waiting(ExternalSession, since: Date)

  var id: String {
    switch self {
    case .approval(let approval): return "approval:\(approval.id)"
    case .waiting(let session, _): return "waiting:\(session.id)"
    }
  }
  var askedAt: Date {
    switch self {
    case .approval(let approval): return approval.askedAt
    case .waiting(_, let since): return since
    }
  }

  /// A proposed team keeps its own card in the transcript: it is more than one answer.
  static func docks(_ approval: RelayOrchestrator.Approval) -> Bool { approval.proposal == nil }

  /// Every ask the dock shows, oldest first; asks from the same instant keep the order given.
  static func open(approvals: [RelayOrchestrator.Approval], waiting: [(ExternalSession, Date)]) -> [DecisionAsk] {
    let asks: [DecisionAsk] = approvals.filter { docks($0) }.map { .approval($0) }
      + waiting.map { .waiting($0.0, since: $0.1) }
    return asks.enumerated().sorted { ($0.element.askedAt, $0.offset) < ($1.element.askedAt, $1.offset) }.map(\.element)
  }

  /// The sessions this chat's "needs you" texts are about that still wait, each with its newest text's time.
  static func waiting(_ transcript: [AgentMessage], sessions: [ExternalSession]) -> [(ExternalSession, Date)] {
    var newest: [String: Date] = [:]
    for message in transcript {
      if let id = message.waitingSession { newest[id] = message.sentAt ?? .distantPast }
    }
    return sessions.compactMap { session in
      guard session.state == .needsUser, let since = newest[session.id] else { return nil }
      return (session, since)
    }
  }
}

/// One polling model per waiting session the dock shows, so its rows answer from the dock's keys.
@MainActor final class WaitingModels: ObservableObject {
  private(set) var models: [String: WaitingCardModel] = [:]
  private var watches: [String: AnyCancellable] = [:]

  func sync(_ sessions: [ExternalSession]) {
    let ids = Set(sessions.map(\.id))
    var changed = false
    for id in Array(models.keys) where !ids.contains(id) {
      models[id]?.stop()
      models[id] = nil
      watches[id] = nil
      changed = true
    }
    for session in sessions where models[session.id] == nil {
      let model = WaitingCardModel(session: session)
      watches[session.id] = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
      models[session.id] = model
      model.start()
      changed = true
    }
    if changed { objectWillChange.send() }
  }
}

/// One answer row: its words, the line under them, and what choosing it does.
struct DecisionRow: Identifiable {
  let id: String
  let title: String
  var summary: String? = nil
  var chosen = false
  let hint: String
  let pick: () -> Void
}

/// Every open ask in Serein's chat, at the foot of its reply (never above the composer): a "Needs you" card
/// with the source, a pager when several wait, and Later, which folds it to one line. A row
/// answers by click, by its number key, or by the arrows and Return; Esc is Later. After an answer
/// the next ask fades in; after the last the card folds away and the keyboard goes back to the composer.
struct DecisionDock: View {
  @ObservedObject var relay: RelayOrchestrator
  let controller: RelayController
  /// In a call the first approval shows in the call view instead.
  var skipsFirstApproval = false
  /// An approval the brief's Go to card asked for.
  @Binding var request: UUID?
  let focusComposer: () -> Void
  @StateObject private var waiting = WaitingModels()
  @State private var index = 0
  @State private var folded = false
  @State private var selected = 0
  @FocusState private var keys: Bool
  /// A mail draft's field on the card has the keyboard (`EmailDraftFields`).
  @State private var typingMail = false
  /// Words go into a field, so the number keys, the arrows and Return leave the rows alone.
  private var typing: Bool { typingMail }
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  private var reduceMotion: Bool { systemReduceMotion || previewReducedEffects }
  private var motion: Animation? { reduceMotion ? nil : MessageMotion.time }

  private var asks: [DecisionAsk] {
    let approvals = skipsFirstApproval ? Array(relay.approvals.dropFirst()) : relay.approvals
    // Sessions waiting in another app get no card here: Serein often can't read their question.
    return DecisionAsk.open(approvals: approvals, waiting: [])
  }

  var body: some View {
    let asks = asks
    let position = min(index, max(asks.count - 1, 0))
    VStack(spacing: 0) {
      if !asks.isEmpty {
        Group {
          if folded { foldedLine(asks.count) } else { card(asks[position], position: position, count: asks.count) }
        }
        .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
      }
    }
    .animation(motion, value: asks.map(\.id))
    .animation(motion, value: folded)
    .onAppear { waiting.sync(sessions(asks)) }
    .onDisappear { waiting.sync([]) }
    .onChange(of: asks.map(\.id)) { old, new in
      waiting.sync(sessions(self.asks))
      index = min(index, max(new.count - 1, 0))
      // A new ask is news: the folded line opens again.
      if !Set(new).subtracting(old).isEmpty { folded = false }
      if new.isEmpty, keys || typing { focusComposer() }
    }
    .onChange(of: asks.isEmpty ? nil : asks[position].id) {
      selected = 0
      typingMail = false
    }
    .onChange(of: relay.answered.last?.id) { _, id in
      // The card folds into its resolved row in the conversation: say what became of it.
      guard id != nil, let answer = relay.answered.last else { return }
      let word = ApprovalEnds.shared.ends[answer.id].map { ApprovalLife.line($0).word } ?? (answer.allowed ? "Allowed" : "Declined")
      AccessibilityNotification.Announcement("\(word): \(answer.title)").post()
    }
    .onChange(of: request) { _, id in
      guard let id else { return }
      request = nil
      guard let at = asks.firstIndex(where: { $0.id == "approval:\(id)" }) else { return }
      index = at
      folded = false
      keys = true
    }
  }

  private func sessions(_ asks: [DecisionAsk]) -> [ExternalSession] {
    asks.compactMap { if case .waiting(let session, _) = $0 { return session } else { return nil } }
  }

  // MARK: the card

  private func card(_ ask: DecisionAsk, position: Int, count: Int) -> some View {
    let rows = rows(ask)
    let enabled = answerable(ask)
    return VStack(alignment: .leading, spacing: 12) {
      header(ask, position: position, count: count)
      VStack(alignment: .leading, spacing: 12) {
        Text(question(ask)).font(UIStyle.font(15, weight: .medium)).foregroundStyle(p.ink)
          .fixedSize(horizontal: false, vertical: true)
        content(ask, rows: rows, enabled: enabled, position: position)
      }.id(ask.id).transition(reduceMotion ? .identity : .opacity)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(p.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
    .shadow(color: p.cardShadow, radius: 10, y: 4)
    .frame(maxWidth: 560, alignment: .leading)
    .focusable().focusEffectDisabled().focused($keys)
    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
      guard !typing, enabled, let number = Int(press.characters), number >= 1, number <= min(rows.count, 9)
      else { return .ignored }
      pick(rows[number - 1], at: number - 1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      guard !typing, !rows.isEmpty else { return .ignored }
      selected = max(selected - 1, 0)
      return .handled
    }
    .onKeyPress(.downArrow) {
      guard !typing, !rows.isEmpty else { return .ignored }
      selected = min(selected + 1, rows.count - 1)
      return .handled
    }
    .onKeyPress(.return) {
      guard !typing, enabled, rows.indices.contains(selected) else { return .ignored }
      pick(rows[selected], at: selected)
      return .handled
    }
    .onExitCommand { later() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label(ask))
  }

  private func header(_ ask: DecisionAsk, position: Int, count: Int) -> some View {
    HStack(spacing: 8) {
      needsYouChip
      if case .approval(let approval) = ask { RiskBadge(risk: approval.risk) }
      Text(source(ask)).font(UIStyle.font(14)).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 8)
      if count > 1 {
        HStack(spacing: 2) {
          pagerButton("chevron.left", "Previous decision", enabled: position > 0) { go(position - 1) }
          Text("\(position + 1) of \(count)").font(UIStyle.font(12)).monospacedDigit().foregroundStyle(p.secondary).lineLimit(1).fixedSize()
            .accessibilityLabel("Decision \(position + 1) of \(count)")
          pagerButton("chevron.right", "Next decision", enabled: position + 1 < count) { go(position + 1) }
        }
      }
      Button("Later") { later() }
        .buttonStyle(.pressable).font(UIStyle.font(14)).foregroundStyle(p.secondary).fixedSize()
        .help("Fold this card. Nothing happens until you answer.")
        .accessibilityHint("Esc")
    }
  }

  private var needsYouChip: some View {
    Text("Needs you").font(UIStyle.font(11)).foregroundStyle(p.warning)
      .padding(.horizontal, 7).frame(height: 20)
      .background(p.warning.opacity(0.12), in: Capsule())
  }

  private func pagerButton(_ icon: String, _ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      InterfaceIcon(systemName: icon, size: 11).foregroundStyle(p.secondary)
        .frame(width: 24, height: 24).contentShape(Circle())
    }.buttonStyle(GlyphButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.4)
      .help(name).accessibilityLabel(name)
  }

  private func foldedLine(_ count: Int) -> some View {
    HStack(spacing: 8) {
      needsYouChip
      Text(count == 1 ? "1 decision waiting" : "\(count) decisions waiting").font(UIStyle.font(14)).foregroundStyle(p.ink)
      Text("·").font(UIStyle.font(14)).foregroundStyle(p.faint).accessibilityHidden(true)
      Button("Show") {
        withAnimation(motion) { folded = false }
        keys = true
      }.buttonStyle(.pressable).font(UIStyle.font(14)).foregroundStyle(p.accent).fixedSize()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16).frame(height: 44)
    .background(p.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.borderStrong, lineWidth: UIStyle.hairline))
    .shadow(color: p.cardShadow, radius: 10, y: 4)
    .frame(maxWidth: 560, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private func content(_ ask: DecisionAsk, rows: [DecisionRow], enabled: Bool, position: Int) -> some View {
    switch ask {
    case .approval(let approval):
      RelayApprovalCard(approval: approval, relay: relay, controller: controller, p: p,
                        showLevels: position == 0 && RelayOrchestrator.previewLevelsPopover, docked: true,
                        typing: $typingMail)
      rowList(rows, enabled: enabled)
    case .waiting(let session, _):
      let model = waiting.models[session.id]
      if let detail = model?.prompt?.detail {
        Text(verbatim: detail).font(UIStyle.monoMeta).foregroundStyle(p.ink).lineLimit(4)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10).padding(.vertical, 8)
          .background(p.codePanel, in: RoundedRectangle(cornerRadius: 10))
      }
      rowList(rows, enabled: enabled)
      HStack(spacing: 10) {
        let needsAccess = model?.read == .needsAccessibility
        // The same drag tile and floating card as the chat's Accessibility card (MacAccessCard).
        if needsAccess { SereinAppTile(size: 28) }
        Text(model?.note ?? "").font(UIStyle.meta)
          .foregroundStyle(model?.state == .failed || model?.state == .changed ? p.ink : p.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        if needsAccess {
          Button("Open Accessibility") {
            MacAccess.openSettings(.accessibility)
          }.buttonStyle(PrimaryButton()).fixedSize()
            .help("Opens System Settings › Privacy & Security › Accessibility")
        }
        if let model {
          Button("Open \(model.appName) \u{2197}") { model.open() }
            .buttonStyle(.pressable).font(UIStyle.metaStrong).foregroundStyle(p.secondary).fixedSize()
        }
      }
      .onChange(of: model?.note ?? "") { _, note in
        if !note.isEmpty { AccessibilityNotification.Announcement(note).post() }
      }
    }
  }

  private func rowList(_ rows: [DecisionRow], enabled: Bool) -> some View {
    VStack(spacing: 2) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { number, row in
        DecisionRowView(row: row, number: number + 1, selected: keys && number == selected, enabled: enabled) {
          pick(row, at: number)
        }
      }
    }.padding(.horizontal, -8)
  }

  // MARK: what each ask says

  private func source(_ ask: DecisionAsk) -> String {
    switch ask {
    case .approval(let approval): return approval.app ?? approval.site ?? "Serein"
    case .waiting(let session, _):
      let place = session.cwd.map { ($0 as NSString).lastPathComponent } ?? session.title
      return "\(session.driver.displayName) \u{00B7} \(place)"
    }
  }

  private func label(_ ask: DecisionAsk) -> String {
    switch ask {
    case .approval(let approval): return "Serein needs your OK: \(approval.title)"
    case .waiting(let session, _): return "\(session.driver.displayName) needs you"
    }
  }

  private func question(_ ask: DecisionAsk) -> String {
    switch ask {
    case .approval(let approval): return approval.title
    case .waiting(let session, _):
      guard let model = waiting.models[session.id] else { return "It is waiting for you." }
      if let asked = model.prompt?.question { return asked }
      return model.read == .needsAccessibility
        ? "It is waiting for you."
        : "It is waiting for you. Serein can't read this question from here."
    }
  }

  private func answerable(_ ask: DecisionAsk) -> Bool {
    guard case .waiting(let session, _) = ask else { return true }
    guard let model = waiting.models[session.id] else { return false }
    return model.state == .waiting || model.state == .failed
  }

  private func rows(_ ask: DecisionAsk) -> [DecisionRow] {
    switch ask {
    case .approval(let approval):
      // Every answer the inline card offers, as rows: yes first, as affectUI orders them, and no last.
      // Neutral and numbered: the risk is the word in the header, never a colour on a row.
      var rows: [DecisionRow] = []
      if !approval.blocked {
        rows.append(DecisionRow(id: "allow", title: approval.grants == nil ? approval.button : "Allow once",
                                hint: "Allows this step") { approval.allow() })
        if let grants = approval.grants {
          if grants.offersTask {
            rows.append(DecisionRow(id: "task", title: "For this task", summary: "Routine steps on \(grants.site) until it ends",
                                    hint: "Allows routine steps for the rest of this task") { grants.forTask(); approval.answer(.yes) })
          }
          rows.append(DecisionRow(id: "always", title: grants.alwaysTitle ?? "Always allow routine steps on \(grants.site)",
                                  hint: "Allows them from now on") { grants.always(); approval.answer(.yes) })
        }
        if approval.routine && relay.level == .everyStep {
          rows.append(DecisionRow(id: "routine", title: "Allow, and stop asking for routine steps",
                                  hint: ApprovalLevel.riskyOnly.note) {
            controller.setLevel(.riskyOnly)
            if relay.level == .riskyOnly { approval.answer(.yes) }
          })
        }
      }
      if approval.automation == .denied {
        rows.append(DecisionRow(id: "settings", title: "Open System Settings",
                                summary: "Privacy & Security \u{203A} Automation, then \(approval.app ?? "the app") under Serein",
                                hint: "Opens System Settings") { relay.openAutomationSettings(for: approval.app) })
      }
      rows.append(DecisionRow(id: "decline", title: approval.decline, hint: "Declines this step") { relay.decline(approval) })
      return rows
    case .waiting(let session, _):
      guard let model = waiting.models[session.id] else { return [] }
      return (model.prompt?.choices ?? []).map { choice in
        DecisionRow(id: choice.id, title: choice.label, chosen: choice.id == model.chosen,
                    hint: model.prompt?.kind == .transcript ? "Opens \(model.appName) to answer" : "Answers in \(model.appName)") {
          model.choose(choice.id)
        }
      }
    }
  }

  // MARK: answering

  private func pick(_ row: DecisionRow, at number: Int) {
    selected = number
    row.pick()
    keys = true
  }
  private func go(_ position: Int) {
    withAnimation(motion) { index = position }
  }
  private func later() {
    withAnimation(motion) { folded = true }
    focusComposer()
  }
}

/// A row: its grey number key, its words in up to two lines, and the line under them. The whole row answers.
struct DecisionRowView: View {
  let row: DecisionRow
  let number: Int
  let selected: Bool
  let enabled: Bool
  let pick: () -> Void
  @State private var hovered = false
  @Environment(\.palette) private var p

  var body: some View {
    Button(action: pick) {
      HStack(alignment: .top, spacing: 10) {
        Text("\(number)").font(UIStyle.font(12, weight: .medium)).foregroundStyle(plainKey ? p.secondary : p.onSolid)
          .frame(width: 24, height: 24)
          .background(keyFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(plainKey ? p.line : .clear, lineWidth: UIStyle.hairline))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text(row.title).font(UIStyle.font(14)).foregroundStyle(p.ink).lineSpacing(3)
            .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
          if let summary = row.summary {
            Text(summary).font(UIStyle.font(14)).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
          }
        }.padding(.top, 2)
        Spacer(minLength: 0)
      }
      .padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      .background(lit ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(AssistantPressStyle()).disabled(!enabled).onHover { hovered = $0 }
    .opacity(enabled || row.chosen ? 1 : 0.45)
    .accessibilityLabel(row.summary.map { "\(row.title), \($0)" } ?? row.title)
    .accessibilityHint("\(row.hint). Key \(number)")
  }

  private var lit: Bool { enabled && (hovered || selected) }
  private var plainKey: Bool { !row.chosen && !lit }
  private var keyFill: Color { plainKey ? p.track : p.solid }
}
