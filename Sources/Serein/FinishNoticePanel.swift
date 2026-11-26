import AppKit
import SereinCore
import SwiftUI

/// The finish notices (SereinCore/FinishNotice.swift) in one floating panel at the top right of
/// the screen the pointer is on, over every app and Space. The panel can take the keyboard
/// without bringing Serein forward (`RelayWindow`), so a reply is typed and sent from the notice.
@MainActor final class FinishNoticeCenter: ObservableObject {
  static let shared = FinishNoticeCenter()
  @Published private(set) var stack = FinishNoticeStack()
  /// Words typed in each card, kept while a newer finish replaces its card.
  @Published var drafts: [FinishNotice.ID: String] = [:]
  /// What a card says in place of its reply field once Return was pressed.
  @Published private(set) var sent: [FinishNotice.ID: String] = [:]
  private(set) var panel: RelayWindow?
  private var focused: FinishNotice.ID?
  private var timer: Timer?
  static let width: CGFloat = 340
  /// Room around the cards for their shadow.
  static let margin: CGFloat = 12

  func show(_ notice: FinishNotice) {
    stack.add(notice, now: Date())
    sent[notice.id] = nil
    present()
  }

  /// A card is hovered, focused or holds typed words: it never folds and never fades.
  func hold(_ id: FinishNotice.ID, hovered: Bool, focused isFocused: Bool) {
    if isFocused { focused = id } else if focused == id { focused = nil }
    let typed = !(drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    stack.hold(id, hovered || isFocused || typed, now: Date())
  }

  func close(_ id: FinishNotice.ID) {
    withAnimation(.easeOut(duration: 0.2)) { stack.close(id) }
    forget(id)
    present()
  }

  /// Open: that chat or task in Serein's window.
  func open(_ notice: FinishNotice) {
    close(notice.id)
    NSApp.activate(ignoringOtherApps: true)
    TaskNotifications.shared.open?(notice.opens)
  }

  /// The "N more finished" line: Serein's window, where every finish waits.
  func openMore() {
    stack.clearMore()
    present()
    NSApp.activate(ignoringOtherApps: true)
    SereinRouter.bringWindowForward?()
  }

  /// Return in a card's field: the words go where the notice points, with no card.
  func send(_ notice: FinishNotice) {
    let words = (drafts[notice.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else { return }
    Task {
      let refused = await Self.reply(notice.target, words)
      if let refused {
        sent[notice.id] = refused
      } else {
        drafts[notice.id] = nil
        sent[notice.id] = "Sent to \(notice.who)."
        stack.hold(notice.id, false, now: Date())
      }
      present()
    }
  }

  /// nil once sent, else the sentence the card shows.
  static func reply(_ target: FinishNotice.Target, _ words: String) async -> String? {
    if case .task(let thread) = target {
      guard let agent = SereinRouter.agent else { return "Serein is not ready." }
      return await agent.flow.replyToTask(thread, text: words, interrupt: false)
    }
    return RelayOrchestrator.shared?.replyFromNotice(target, words) ?? "Serein is not ready."
  }

  private func forget(_ id: FinishNotice.ID) {
    drafts[id] = nil
    sent[id] = nil
    if focused == id { focused = nil }
  }

  /// Shows, resizes or hides the panel to fit the cards, after SwiftUI has laid them out.
  private func present() {
    // A check run keeps the stack and draws nothing (AssistantCoreChecks+FinishNotice).
    guard !RunMode.checking else { return }
    DispatchQueue.main.async { [self] in
      guard !stack.notices.isEmpty else {
        panel?.orderOut(nil)
        timer?.invalidate()
        timer = nil
        return
      }
      let panel = self.panel ?? makePanel()
      self.panel = panel
      guard let host = panel.contentView else { return }
      host.layoutSubtreeIfNeeded()
      let size = host.fittingSize
      let mouse = NSEvent.mouseLocation
      let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
      let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
      panel.setFrame(NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height, width: size.width, height: size.height),
                     display: true)
      panel.orderFrontRegardless()
      if timer == nil {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
          Task { @MainActor in FinishNoticeCenter.shared.tick() }
        }
      }
    }
  }

  private func tick() {
    let before = Set(stack.notices.map(\.id))
    var next = stack
    guard next.expire(now: Date(), life: FinishNoticeStack.life(voiceOver: NSWorkspace.shared.isVoiceOverEnabled)) else { return }
    withAnimation(.easeOut(duration: 0.4)) { stack = next }
    before.subtracting(stack.notices.map(\.id)).forEach(forget)
    present()
  }

  private func makePanel() -> RelayWindow {
    let panel = RelayWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 200),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.onEscape = { [weak self] in
      guard let self, let id = focused ?? stack.notices.first?.id else { return }
      close(id)
    }
    let host = NSHostingView(rootView: FinishNoticeStackView(center: self).font(UIStyle.font(13)))
    panel.contentView = host
    return panel
  }
}

/// The cards, newest on top, and the fold line under them.
struct FinishNoticeStackView: View {
  @ObservedObject var center: FinishNoticeCenter
  @ObservedObject private var appearance = AppearanceController.shared

  var body: some View {
    let p = appearance.palette
    VStack(spacing: 8) {
      ForEach(center.stack.notices) { entry in
        FinishNoticeView(notice: entry.notice, center: center).transition(.opacity)
      }
      if center.stack.more > 0 {
        Button { center.openMore() } label: {
          Text(center.stack.more == 1 ? "1 more finished" : "\(center.stack.more) more finished")
            .font(AssistantType.meta).foregroundStyle(p.secondary)
            .frame(maxWidth: .infinity).frame(height: 32)
            .background(p.overlay, in: Capsule())
            .overlay(Capsule().strokeBorder(p.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .help("Open Serein to see them")
      }
    }
    .frame(width: FinishNoticeCenter.width)
    .padding(FinishNoticeCenter.margin)
    .fixedSize(horizontal: false, vertical: true)
    .environment(\.palette, p)
    .preferredColorScheme(p.colorScheme)
  }
}

/// One card (docs/demos/finish-notice.decision.md, layout 1): who finished and when, the task in
/// two lines, one line of what it did, where and how long, then the reply field and Open.
struct FinishNoticeView: View {
  let notice: FinishNotice
  @ObservedObject var center: FinishNoticeCenter
  @ObservedObject private var appearance = AppearanceController.shared
  @State private var hovered = false
  @FocusState private var typing: Bool

  var body: some View {
    let p = appearance.palette
    let shape = RoundedRectangle(cornerRadius: AssistantMetrics.bannerRadius, style: .continuous)
    VStack(alignment: .leading, spacing: 12) {
      header(p)
      VStack(alignment: .leading, spacing: 4) {
        Text(notice.title).font(AssistantType.body).foregroundStyle(p.ink)
          .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
        Text(notice.summary).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
        if let meta = metaLine {
          Text(meta).font(AssistantType.meta).foregroundStyle(p.faint).lineLimit(1).truncationMode(.tail)
        }
      }
      replyRow(p)
    }
    .padding(16)
    .frame(width: FinishNoticeCenter.width, alignment: .leading)
    .background(p.overlay, in: shape)
    .overlay(shape.strokeBorder(p.line))
    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    .onHover { hovered = $0; reportHold() }
    .onChange(of: typing) { _, _ in reportHold() }
    .onChange(of: center.drafts[notice.id] ?? "") { _, _ in reportHold() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(headline). \(notice.title)")
  }

  private var headline: String { notice.failed ? "\(notice.who) couldn't finish" : "\(notice.who) finished" }

  private var metaLine: String? {
    let took = notice.took.map { $0 < 60 ? "under a minute" : "\(Int(($0 / 60).rounded())) min" }
    let parts = [notice.place, took].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func header(_ p: Palette) -> some View {
    HStack(spacing: 8) {
      face(p)
      Text(headline).font(AssistantType.name).foregroundStyle(notice.failed ? p.danger : p.ink).lineLimit(1)
      Spacer(minLength: 8)
      Text(notice.at, format: .dateTime.hour().minute()).font(AssistantType.figures).foregroundStyle(p.faint)
      Button { center.close(notice.id) } label: {
        InterfaceIcon(systemName: "xmark", size: 12).foregroundStyle(p.secondary)
          .frame(width: 22, height: 22).contentShape(Rectangle())
      }
      .buttonStyle(.pressable)
      .help("Close")
      .accessibilityLabel("Close \(notice.who)'s notice")
    }
  }

  @ViewBuilder private func face(_ p: Palette) -> some View {
    if let id = notice.face, let profile = RelayOrchestrator.shared?.team.profiles.first(where: { $0.id == id }) {
      AssistantMark(tint: profile.colour, size: 20, icon: profile.icon, owner: profile.id)
    } else if notice.face != nil {
      AssistantMark(tint: nil, size: 20)
    } else {
      InterfaceIcon(systemName: "terminal", size: 12).foregroundStyle(p.secondary)
        .frame(width: 20, height: 20)
        .background(p.track, in: Circle())
        .overlay(Circle().strokeBorder(p.line))
    }
  }

  private func replyRow(_ p: Palette) -> some View {
    HStack(spacing: 8) {
      if let sent = center.sent[notice.id], (center.drafts[notice.id] ?? "").isEmpty {
        Text(sent).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField("Reply to \(notice.who)", text: Binding(
          get: { center.drafts[notice.id] ?? "" }, set: { center.drafts[notice.id] = $0 }))
          .textFieldStyle(.plain).font(AssistantType.body).foregroundStyle(p.ink)
          .focused($typing)
          .onSubmit { center.send(notice) }
          .padding(.horizontal, 12).frame(height: 32)
          .background(p.track, in: Capsule())
          .overlay(Capsule().strokeBorder(typing ? p.accent : p.line))
          .accessibilityLabel("Reply to \(notice.who)")
      }
      Button { center.open(notice) } label: {
        Text("Open").font(AssistantType.name).foregroundStyle(p.ink)
          .padding(.horizontal, 14).frame(height: 32)
          .background(p.track, in: Capsule())
          .overlay(Capsule().strokeBorder(p.line))
          .contentShape(Capsule())
      }
      .buttonStyle(.pressable)
      .help("Open in Serein")
    }
  }

  private func reportHold() { center.hold(notice.id, hovered: hovered, focused: typing) }
}

extension RelayOrchestrator {
  /// A reply typed in a finish notice to an assistant's chat or a seat: the person's words land
  /// in that chat and the assistant answers there, with no card and no switch of the chat on
  /// screen. nil once sent, else the sentence the card shows. A task goes through
  /// `FinishNoticeCenter.reply`.
  @discardableResult
  func replyFromNotice(_ target: FinishNotice.Target, _ words: String) -> String? {
    switch target {
    case .task:
      return "Serein is not ready."
    case .chat(let assistant):
      guard team.profiles.contains(where: { $0.id == assistant }) else { return "That assistant was deleted." }
      if assistant == team.activeID {
        return ask(words, inWindow: false) ? nil : (lastError ?? "It wasn't sent.")
      }
      startSideSeat(words, in: mainThread(of: assistant), as: assistant)
      return nil
    case .seat(let id):
      guard let seat = handoffLedger.records.first(where: { $0.id == id }) else { return "That task is gone." }
      guard team.profiles.contains(where: { $0.id == seat.to }) else { return "That assistant was deleted." }
      // The seat's own model and what it answered, in the chat its answer was for.
      startSideSeat(words, in: originChat(seat), as: seat.to, route: seat.route,
                    task: FinishNotice.seatTask(words: words, earlier: seat.result))
      return nil
    }
  }
}

extension FinishNoticeCenter {
  /// `--ui-finish-notice short|long|swarm|stack [typed]` (UIPreview): synthetic notices, and with
  /// `typed`, words in the top card's reply field.
  func preview(_ seed: String, typed: Bool) {
    let relay = RelayOrchestrator.shared
    let bot = relay?.team.activeID ?? "preview"
    let name = relay?.profileName(bot) ?? "Serein"
    let chat = relay?.threadID ?? ""
    let now = Date()
    func seat(_ id: String, _ model: String, _ summary: String) -> FinishNotice {
      FinishNotice(target: .seat(handoff: id), face: bot, title: "Find fares to Lisbon for the first weekend in March", summary: summary,
                   who: name, place: "Seat on " + model, took: 130, failed: false, at: now, opens: chat)
    }
    let short = FinishNotice(target: .chat(assistant: bot), face: bot, title: "Summarise my inbox",
                             summary: "Twelve new emails; two need a reply today.", who: name, place: "Main chat", took: 40,
                             failed: false, at: now, opens: chat)
    let long = FinishNotice(target: .chat(assistant: bot), face: bot,
                            title: "Draft the launch email for the beta list and send me the draft before you send it to anyone on the list",
                            summary: "Wrote a 140-word draft with three subject lines to pick from.", who: name, place: "Main chat",
                            took: 360, failed: false, at: now, opens: chat)
    let task = FinishNotice(target: .task(thread: "preview-task"), face: nil, title: "Fix the flaky relay test on main",
                            summary: "The test needs a network the task may not use.", who: "Claude Code", place: "serein-bot",
                            took: 660, failed: true, at: now, opens: "preview-task")
    let seeds: [FinishNotice] = switch seed {
    case "long": [long]
    case "swarm": [seat("preview-seat-a", "GPT-5", "Three fares under $600; the cheapest leaves Friday at 7:05.")]
    case "stack":
      [task, seat("preview-seat-b", "Claude Sonnet", "Two direct fares, both on Saturday morning."),
       seat("preview-seat-a", "GPT-5", "Three fares under $600; the cheapest leaves Friday at 7:05."), long]
    default: [short]
    }
    seeds.forEach(show)
    if typed, let top = stack.notices.first {
      drafts[top.id] = "Make it shorter and send it to me again"
      stack.hold(top.id, true, now: now)
    }
  }
}
