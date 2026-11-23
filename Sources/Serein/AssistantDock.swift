import AppKit
import Combine
import SereinCore
import SwiftUI
import UniformTypeIdentifiers

/// The dock: every assistant's face on the right edge of the screen, over every app, and a small
/// chat that opens beside the face you click. It is the same chat as in Serein's window (one
/// conversation per assistant), so a message sent here, its reply and its cards are the ones the
/// window shows. A click on another face switches to that assistant, as its row in the window
/// does, and is refused the same way while the assistant in front still works.
///
/// Off unless "Keep your assistants at the edge of the screen" is on (Settings › Ask from any
/// app). Neither panel takes the app in front away: the rail never takes the keyboard, and the
/// chat takes it only while you type in it.
@MainActor final class AssistantDock: ObservableObject {
  static let shared = AssistantDock()
  static let enabledKey = "serein.dock"
  static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
  static let chatSize = NSSize(width: 380, height: 540)
  /// The gap between the rail and the screen's edge, and between the chat and the rail.
  private static let gap: CGFloat = 10

  /// The chat is open.
  @Published private(set) var chatOpen = false

  private weak var relay: RelayOrchestrator?
  private var rail: NSPanel?
  private var chat: RelayWindow?

  /// Shows or removes the rail to match Settings. Called whenever Settings change (`RelayController.install`).
  func install(relay: RelayOrchestrator) {
    self.relay = relay
    guard Self.enabled else {
      closeChat()
      rail?.orderOut(nil)
      rail = nil
      return
    }
    let panel = rail ?? makeRail(relay)
    rail = panel
    panel.orderFrontRegardless()
  }

  // MARK: the rail

  private func makeRail(_ relay: RelayOrchestrator) -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 64, height: 120),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    let host = NSHostingView(rootView: AssistantDockRail(relay: relay, dock: self).font(UIStyle.font(13)))
    host.sizingOptions = []
    host.frame = panel.contentLayoutRect
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    return panel
  }

  /// The rail is as tall as its faces: it sits at the middle of the right edge of the screen the
  /// pointer is on, and the open chat follows it.
  func fitRail(_ size: CGSize) {
    guard let rail, size.width > 0, size.height > 0 else { return }
    let screen = rail.screen ?? NSScreen.main ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else { return }
    let frame = NSRect(
      x: visible.maxX - size.width - Self.gap, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    if rail.frame != frame { rail.setFrame(frame, display: true) }
    placeChat()
  }

  // MARK: the chat

  /// A click on a face: its chat opens beside the rail; a click on the face whose chat is open
  /// closes it. Another assistant's face switches to it first, refused while this one works.
  func toggleChat(_ id: String) {
    guard let relay else { return }
    if chatOpen, relay.team.activeID == id {
      closeChat()
      return
    }
    openChat(id)
  }

  /// Opens the chat of the assistant `id`; false when the assistant in front is still working.
  @discardableResult
  func openChat(_ id: String) -> Bool {
    guard let relay, Self.enabled else { return false }
    if relay.team.activeID != id, !relay.switchTo(id) {
      ToastCenter.shared.show("\(relay.team.activeName) is still busy in this chat. Wait for it to finish, then switch.")
      return false
    }
    let panel = chat ?? makeChat(relay)
    chat = panel
    placeChat()
    panel.orderFrontRegardless()
    panel.makeKey()
    chatOpen = true
    return true
  }

  /// The chat of the assistant that owns `thread`, for a finish notification's Show result.
  @discardableResult
  func openChat(forThread thread: String) -> Bool {
    guard let relay, let owner = relay.assistantOwning(thread: thread) else { return false }
    return openChat(owner)
  }

  func closeChat() {
    chat?.orderOut(nil)
    chatOpen = false
  }

  private func makeChat(_ relay: RelayOrchestrator) -> RelayWindow {
    let panel = RelayWindow(
      contentRect: NSRect(origin: .zero, size: Self.chatSize),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.onEscape = { [weak self] in self?.closeChat() }
    let host = NSHostingView(rootView: AssistantDockChat(relay: relay, dock: self).font(UIStyle.font(13)))
    host.sizingOptions = []
    host.frame = panel.contentLayoutRect
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    return panel
  }

  /// Beside the rail, on its inner side, kept on the screen.
  private func placeChat() {
    guard let chat, let rail else { return }
    let visible = (rail.screen ?? NSScreen.main)?.visibleFrame ?? rail.frame
    let size = Self.chatSize
    let y = min(max(rail.frame.midY - size.height / 2, visible.minY + Self.gap), visible.maxY - size.height - Self.gap)
    let frame = NSRect(x: rail.frame.minX - size.width - Self.gap, y: y, width: size.width, height: size.height)
    if chat.frame != frame { chat.setFrame(frame, display: true) }
  }
}

/// The rail: one face for each assistant, with what it is doing, and a plus for a new one.
struct AssistantDockRail: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var dock: AssistantDock
  @ObservedObject private var appearance = AppearanceController.shared
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var hub: AgentHub

  init(relay: RelayOrchestrator, dock: AssistantDock) {
    self.relay = relay
    self.dock = dock
    hub = relay.agent.hub
  }

  var body: some View {
    let p = appearance.palette
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    VStack(spacing: 6) {
      ForEach(relay.team.profiles) { profile in face(profile, p) }
      Button { newAssistant() } label: {
        InterfaceIcon(systemName: "plus", size: 13).foregroundStyle(p.secondary)
          .frame(width: 44, height: 32).contentShape(Rectangle())
      }
      .buttonStyle(AssistantPressStyle())
      .help("New Serein")
      .accessibilityLabel("New Serein")
    }
    .padding(.vertical, 10).padding(.horizontal, 6)
    .background(p.background, in: shape)
    .overlay(shape.strokeBorder(p.line, lineWidth: 1))
    .fixedSize()
    .onGeometryChange(for: CGSize.self) { $0.size } action: { dock.fitRail($0) }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.palette, p)
    .foregroundStyle(p.ink)
    .tint(p.solid)
  }

  private func status(_ profile: RelayProfile) -> SereinStatus {
    relay.assistantStatus(
      profile.id, hub: hub, online: SereinSurface.online(network.online), connected: SereinSurface.connected(relay.agent),
      unread: surface.unread)
  }

  private func face(_ profile: RelayProfile, _ p: Palette) -> some View {
    let state: SereinStatus = status(profile)
    let open = dock.chatOpen && relay.team.activeID == profile.id
    return Button { dock.toggleChat(profile.id) } label: {
      AssistantMark(tint: profile.colour, size: 36, icon: profile.icon, owner: profile.id, motion: AssistantMarkMotion(state))
        .frame(width: 44, height: 44)
        .background(open ? p.track : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) { badge(state, p) }
        .contentShape(Rectangle())
    }
    .buttonStyle(AssistantPressStyle())
    .help("\(profile.name) · \(state.words)")
    .accessibilityLabel("\(profile.name), \(state.words)")
    .accessibilityAddTraits(open ? .isSelected : [])
  }

  /// What needs a look, on the face's corner: amber when it needs you, the accent for a reply
  /// not read yet. Working shows on the face itself, which moves.
  @ViewBuilder private func badge(_ status: SereinStatus, _ p: Palette) -> some View {
    switch status {
    case .needsYou: dot(p.warning, p)
    case .unread: dot(p.accent, p)
    default: EmptyView()
    }
  }
  private func dot(_ colour: Color, _ p: Palette) -> some View {
    Circle().fill(colour).frame(width: 9, height: 9)
      .overlay(Circle().strokeBorder(p.background, lineWidth: 1.5))
      .offset(x: -3, y: -3).accessibilityHidden(true)
  }

  /// The main assistant makes assistants (`assistant_make`): its chat opens with the words begun.
  private func newAssistant() {
    guard let main = relay.team.mainProfileID, dock.openChat(main) else { return }
    NotificationCenter.default.post(name: AssistantDockChat.begin, object: "Make me an assistant that ")
  }
}

/// The dock's chat: who it is and what it is doing, the conversation, and a box to write or
/// speak in. Files and pictures dropped on it go with the next message.
struct AssistantDockChat: View {
  /// Fills the message box (the rail's plus).
  static let begin = Notification.Name("SereinDockBegin")

  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject var dock: AssistantDock
  @ObservedObject private var appearance = AppearanceController.shared
  @ObservedObject private var network = NetworkMonitor.shared
  @ObservedObject private var surface = SereinSurface.main
  @ObservedObject private var hub: AgentHub
  @ObservedObject private var dictation: Dictation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var draft = ""
  @State private var problem: String?
  /// The draft as it was when the microphone opened: what is heard goes after it.
  @State private var beforeSpeech: String?
  @FocusState private var writing: Bool

  init(relay: RelayOrchestrator, dock: AssistantDock) {
    self.relay = relay
    self.dock = dock
    hub = relay.agent.hub
    dictation = RelayController.shared?.dictation ?? Dictation()
  }

  private var messages: [AgentMessage] {
    (relay.run?.transcript ?? relay.transcript).filter {
      ($0.role == "you" || $0.role == "assistant") && !RelayProactive.isNothing($0.text)
        && !($0.text.isEmpty && ($0.attached ?? []).isEmpty && ($0.images ?? []).isEmpty)
    }
  }
  private var name: String { relay.team.activeName }

  var body: some View {
    let p = appearance.palette
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    VStack(spacing: 0) {
      header(p)
      transcript(p)
      if let problem = problem ?? relay.lastError {
        Text(problem).font(UIStyle.meta).foregroundStyle(p.danger).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
      }
      composer(p)
    }
    .frame(width: AssistantDock.chatSize.width, height: AssistantDock.chatSize.height)
    .background(p.background, in: shape)
    .overlay(shape.strokeBorder(p.line, lineWidth: 1))
    .clipShape(shape)
    .onDrop(of: [.fileURL], isTargeted: nil) { surface.acceptDocuments($0) }
    .onReceive(NotificationCenter.default.publisher(for: Self.begin)) { note in
      if draft.isEmpty, let words = note.object as? String { draft = words }
      writing = true
    }
    .onAppear { writing = true }
    .environment(\.palette, p)
    .foregroundStyle(p.ink)
    .tint(p.solid)
  }

  // MARK: header

  private func header(_ p: Palette) -> some View {
    let profile = relay.team.active
    let status: SereinStatus = relay.assistantStatus(
      relay.team.activeID, hub: hub, online: SereinSurface.online(network.online),
      connected: SereinSurface.connected(relay.agent), unread: false)
    return HStack(spacing: 10) {
      AssistantMark(
        tint: profile?.colour, size: 30, icon: profile?.icon, owner: profile?.id, motion: AssistantMarkMotion(status))
      VStack(alignment: .leading, spacing: 1) {
        Text(name).font(UIStyle.bodyStrong).foregroundStyle(p.ink).lineLimit(1)
        Text(status.words).font(UIStyle.meta).foregroundStyle(status == .needsYou ? p.warning : p.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      Menu {
        Button("Open in Serein") { openInWindow() }
        Button("\(name)’s Settings…") { RelayController.shared?.openSettings("Relay") }
      } label: {
        InterfaceIcon(systemName: "ellipsis", size: 13).foregroundStyle(p.secondary).frame(width: 28, height: 28)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .accessibilityLabel("More")
      Button { dock.closeChat() } label: {
        InterfaceIcon(systemName: "xmark", size: 12).foregroundStyle(p.secondary).frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(AssistantPressStyle()).keyboardShortcut(.cancelAction)
      .help("Close · Esc").accessibilityLabel("Close")
    }
    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    .accessibilityElement(children: .contain)
  }

  private func openInWindow() {
    dock.closeChat()
    RelayController.shared?.openInSerein()
  }

  // MARK: the conversation

  private func transcript(_ p: Palette) -> some View {
    let shown = messages
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          if shown.isEmpty {
            Text("\(name) is ready. Say what you want done.").font(UIStyle.meta).foregroundStyle(p.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
          }
          ForEach(shown) { message in bubble(message, p).id(message.id) }
          if waitsForYou {
            Button { openInWindow() } label: {
              Text("\(name) needs your OK · Show").font(UIStyle.meta).foregroundStyle(p.warning)
            }.buttonStyle(.pressable).frame(maxWidth: .infinity, alignment: .leading)
          } else if relay.replyingHere, shown.last?.role == "you" {
            typing(p)
          }
          Color.clear.frame(height: 1).id(Self.foot)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
      }
      .scrollIndicators(.automatic)
      .onChange(of: shown.count) { _, _ in toFoot(proxy) }
      .onChange(of: shown.last?.text.count ?? 0) { _, _ in toFoot(proxy) }
      .onChange(of: relay.team.activeID) { _, _ in toFoot(proxy, animated: false) }
      .onAppear { toFoot(proxy, animated: false) }
    }
  }
  private static let foot = "dock-foot"
  private func toFoot(_ proxy: ScrollViewProxy, animated: Bool = true) {
    if animated && !reduceMotion {
      withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(Self.foot, anchor: .bottom) }
    } else {
      proxy.scrollTo(Self.foot, anchor: .bottom)
    }
  }
  private var waitsForYou: Bool {
    relay.cardsWaiting
  }

  @ViewBuilder private func bubble(_ message: AgentMessage, _ p: Palette) -> some View {
    let shape = RoundedRectangle(cornerRadius: UIStyle.bubbleRadius, style: .continuous)
    if message.role == "you" {
      HStack {
        Spacer(minLength: 44)
        VStack(alignment: .trailing, spacing: 4) {
          if !message.text.isEmpty {
            Text(message.text).textSelection(.enabled)
              .padding(.horizontal, 12).padding(.vertical, 8).background(p.bubble, in: shape)
          }
          if let attached = message.attached, !attached.isEmpty {
            Text(attached.joined(separator: " · ")).font(UIStyle.micro).foregroundStyle(p.secondary).lineLimit(2)
          }
        }
      }
    } else {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          // The screenshots the assistant took during the turn, before its answer, as in the window's chat.
          ForEach(message.images ?? [], id: \.self) { MessageImage(source: $0, alt: "Screenshot") }
          if !message.text.isEmpty {
            MessageContent(
              text: ChatBubbles.plain(ChatBubbles.withoutPartialTag(message.text)), showsCopyButton: false, read: message.read
            )
            .padding(.horizontal, 12).padding(.vertical, 8).background(p.card, in: shape)
          }
        }
        Spacer(minLength: 44)
      }
    }
  }

  /// Three dots while the reply has not started; still under Reduce Motion.
  private func typing(_ p: Palette) -> some View {
    HStack(spacing: 4) {
      ForEach(0..<3, id: \.self) { index in
        Circle().fill(p.secondary).frame(width: 5, height: 5)
          .phaseAnimator(reduceMotion ? [1.0] : [0.35, 1.0, 0.35]) { dot, phase in
            dot.opacity(phase)
          } animation: { _ in .easeInOut(duration: 0.5).delay(Double(index) * 0.15) }
      }
    }
    .padding(.horizontal, 12).frame(height: 30)
    .background(p.card, in: Capsule())
    .accessibilityLabel("\(name) is replying")
  }

  // MARK: the message box

  private func composer(_ p: Palette) -> some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    let chips = surface.attachments
    return VStack(alignment: .leading, spacing: 6) {
      if !chips.isEmpty {
        FlowChips(items: chips.map(\.id)) { id in
          if let chip = chips.first(where: { $0.id == id }) {
            HStack(spacing: 4) {
              InterfaceIcon(systemName: chip.icon, size: 10).foregroundStyle(p.secondary)
              Text(chip.title).font(UIStyle.micro).lineLimit(1).frame(maxWidth: 160)
              Button { surface.detach(chip.id) } label: {
                InterfaceIcon(systemName: "xmark", size: 8).foregroundStyle(p.secondary).frame(width: 14, height: 14)
                  .contentShape(Rectangle())
              }.buttonStyle(.pressable).accessibilityLabel("Remove \(chip.title)")
            }
            .padding(.leading, 8).padding(.trailing, 4).frame(height: 22).background(p.track, in: Capsule())
          }
        }
      }
      HStack(alignment: .bottom, spacing: 6) {
        TextField(dictation.recording ? "Listening…" : "Message \(name)", text: $draft, axis: .vertical)
          .textFieldStyle(.plain).lineLimit(1...4).focused($writing).onSubmit(send).shiftReturnNewLine()
          .accessibilityLabel("Message \(name)")
        Button(action: speak) {
          InterfaceIcon(systemName: dictation.recording ? "mic.fill" : "mic", size: 13)
            .foregroundStyle(dictation.recording ? p.onSolid : p.secondary)
            .frame(width: 28, height: 28).background(dictation.recording ? p.danger : p.track, in: Circle())
        }
        .buttonStyle(AssistantPressStyle())
        .help(dictation.recording ? "Stop listening" : "Speak").accessibilityLabel(dictation.recording ? "Stop listening" : "Speak")
        Button(action: send) {
          InterfaceIcon(systemName: "arrow.up", size: 13).foregroundStyle(canSend ? p.onSolid : p.faint)
            .frame(width: 28, height: 28).background(canSend ? p.solid : p.track, in: Circle())
        }
        .buttonStyle(AssistantPressStyle()).disabled(!canSend)
        .help("Send · Return").accessibilityLabel("Send")
      }
      .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
      .background(p.card, in: shape)
      .overlay(shape.strokeBorder(p.line, lineWidth: 1))
    }
    .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !surface.attachments.isEmpty
  }

  private func send() {
    guard canSend else { return }
    if dictation.recording { dictation.stop() }
    beforeSpeech = nil
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    problem = nil
    relay.lastError = nil
    switch relay.messagePlan(text, hasAttachments: !surface.attachments.isEmpty) {
    case .fill(let words):
      draft = words
    case .refuse(let why):
      problem = why
    case .answer(let words):
      draft = ""
      _ = relay.answerFromComposer(words)
    case .send(let words):
      draft = ""
      // As the window's composer sends: while a reply runs the message waits its turn, and another
      // assistant's routine is never cut short.
      relay.ask(words, attachments: surface.takeAttachments(), interrupt: false)
    }
  }

  /// The microphone: a click starts listening and what is heard goes into the box as it is said;
  /// a second click stops. Nothing is sent until Send.
  private func speak() {
    if dictation.recording || dictation.starting {
      let base = beforeSpeech ?? draft
      beforeSpeech = nil
      Task { @MainActor in
        let heard = await dictation.finish()
        draft = Self.joined(base, heard)
        writing = true
      }
      return
    }
    let base = draft
    beforeSpeech = base
    dictation.start { heard in draft = Self.joined(base, heard) }
  }
  private static func joined(_ base: String, _ heard: String) -> String {
    let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !said.isEmpty else { return base }
    return base.isEmpty || base.hasSuffix(" ") ? base + said : base + " " + said
  }
}
