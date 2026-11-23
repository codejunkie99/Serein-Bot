import AppKit
import SereinCore
import SwiftUI

// The running chat (board 17, NbQuick): its line above the ⌥Space bar, and its face and line over
// an empty chat in the window while a chat runs elsewhere. It shows the assistant whose chat runs
// now (the rules are SereinCore's `QuickFace`), moves by that assistant's state, and a press opens
// that chat. A chat title can be personal: it shows only in Serein's own window and in the bar the
// person brought up, never from a hidden ask chat, and never in a notification.

/// Every chat that runs for an assistant now, or waits on the person, read from what is in memory
/// only: Serein's turn in the chat on screen (`replyingHere`), another assistant's routine in its
/// own chat (`ownerRun`), the hand-offs that run (`handoffLedger`), the tasks and light asks the
/// assistants started (`AgentHub.slotted`, `childOwners`), and the cards that wait for an answer.
@MainActor enum RunningChats {
  static func all(relay: RelayOrchestrator, hub: AgentHub) -> [RunningChat] {
    let hidden: Set<String> = relay.desk.hiddenThreads
    var out: [RunningChat] = []
    // A routine in its owner's own chat (A1's owner run).
    let routine: RelayOrchestrator.OwnerRun? = relay.ownerRun
    if let routine {
      let run: AgentRun? = hub.run(for: routine.thread)
      let since: Date = run?.record.startedAt ?? Date()
      out.append(working(relay, routine.profileID, chat: routine.thread, run: run, since: since, hidden: hidden))
    }
    // Serein's own turn in the chat on screen (a reply, a send on its way, a hand-off starting).
    if relay.replyingHere, routine?.thread != relay.threadID {
      let run: AgentRun? = relay.run
      let since: Date = run?.record.startedAt ?? Date()
      out.append(working(relay, relay.team.activeID, chat: relay.threadID, run: run, since: since, hidden: hidden))
    }
    // Hand-offs another assistant works on, in its own Main chat.
    for record in relay.handoffLedger.records where record.state == .running {
      let run: AgentRun? = hub.run(for: record.threadID)
      let since: Date = record.startedAt ?? record.createdAt
      out.append(working(relay, record.to, chat: record.threadID, run: run, since: since, hidden: hidden))
    }
    // The tasks assistants started, and the light asks they answer (in hidden chats).
    for run in hub.slotted {
      if let entry = task(relay, run: run, hidden: hidden) { out.append(entry) }
    }
    // Cards that wait for the person.
    for approval in relay.approvals {
      let thread: String = approval.threadID ?? relay.threadID
      guard !hidden.contains(thread) else { continue }
      let owner: String = relay.assistantOwning(thread: thread) ?? relay.team.activeID
      out.append(RunningChat(assistantID: owner, name: relay.profileName(owner), chatID: thread, title: nil,
                             state: .needsYou, since: approval.askedAt))
    }
    if !relay.questionForms.isEmpty || relay.consentWaiting {
      let owner: String = relay.team.activeID
      out.append(RunningChat(assistantID: owner, name: relay.profileName(owner), chatID: relay.threadID, title: nil,
                             state: .needsYou, since: .distantPast))
    }
    return out
  }

  /// A task an assistant started: its own chat and title. A light ask's chat is hidden: it gives
  /// no title, and a press opens the chat that asked instead.
  private static func task(_ relay: RelayOrchestrator, run: AgentRun, hidden: Set<String>) -> RunningChat? {
    let thread: String = run.spec.threadID
    guard let owner = relay.childOwners[thread], !owner.isEmpty else { return nil }
    let secret: Bool = hidden.contains(thread)
    let chat: String? = secret ? relay.desk.asks[thread]?.askerChat : thread
    let title: String? = secret ? nil : QuickFace.title(run.record.title, chatID: thread, hidden: hidden)
    let state: RunningChat.State = run.approvals.isEmpty ? .working : .needsYou
    return RunningChat(assistantID: owner, name: relay.profileName(owner), chatID: chat, title: title, state: state,
                       since: run.record.startedAt)
  }

  private static func working(
    _ relay: RelayOrchestrator, _ id: String, chat: String, run: AgentRun?, since: Date, hidden: Set<String>
  ) -> RunningChat {
    let secret: Bool = hidden.contains(chat)
    let raw: String? = secret ? nil : chatTitle(chat, relay: relay, run: run)
    let title: String? = QuickFace.title(raw, chatID: chat, hidden: hidden)
    return RunningChat(assistantID: id, name: relay.profileName(id), chatID: secret ? nil : chat, title: title,
                       state: .working, since: since)
  }

  /// A chat's title: its saved record's (`ProjectChatIndex.title`), else its run's own.
  static func chatTitle(_ thread: String, relay: RelayOrchestrator, run: AgentRun?) -> String? {
    if let saved = relay.agent.conversations.first(where: { $0.id == thread }), !saved.messages.isEmpty {
      return ProjectChatIndex.title(saved)
    }
    return run?.record.title
  }

  /// Opens what the face shows: a task in its view, a chat that is not the assistant's Main chat
  /// (the chat that asked a light ask) through the router, else the assistant's chat. At rest,
  /// the active assistant's chat. A switch mid-reply is refused with the usual toast.
  static func open(_ running: RunningChat?, relay: RelayOrchestrator) {
    guard let running else {
      relay.openAssistant(relay.team.activeID)
      return
    }
    if let chat = running.chatID, relay.isChild(chat) {
      SereinRouter.openTask(chat)
      return
    }
    if let chat = running.chatID, chat != relay.threadID, relay.knownMainThread(of: running.assistantID) != chat {
      SereinRouter.open(threadID: chat)
      return
    }
    relay.openAssistant(running.assistantID)
  }
}

/// The face at 72 points with its 16-point status dot and, under it, one line in `meta`
/// `secondary` ("Scout is working · Lisbon fares", "Scout needs you", nothing at rest) that
/// shimmers only while it works. `bar`: above the ⌥Space bar, the line alone, under the hologram,
/// and nothing at rest. `chat`: over an empty chat in the window, only while a chat runs elsewhere
/// (at rest the welcome already shows this chat's face).
struct QuickBarFace: View {
  enum Place { case bar, chat }
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var hub: AgentHub
  let place: Place
  /// False in a bar that opened by itself for an answer, or in a private window: no chat title.
  var showsTitle: Bool
  /// Runs before the chat opens: the ⌥Space bar brings Serein's window forward first.
  var before: (() -> Void)?

  init(relay: RelayOrchestrator, place: Place, showsTitle: Bool = true, before: (() -> Void)? = nil) {
    self.relay = relay
    hub = relay.agent.hub
    self.place = place
    self.showsTitle = showsTitle
    self.before = before
  }

  /// What may show here: in the empty chat, only chats elsewhere, so its own first message never
  /// flashes the face.
  private var running: [RunningChat] {
    let all: [RunningChat] = RunningChats.all(relay: relay, hub: hub)
    guard place == .chat else { return all }
    let here: String = relay.threadID
    return all.filter { $0.chatID != here }
  }

  var body: some View {
    let picked: RunningChat? = QuickFace.now(running)
    let shown: RunningChat? = showsTitle ? picked : QuickFace.withoutTitle(picked)
    if place == .bar && QuickFace.line(shown) == nil {
      // Nothing to say: only the room that keeps the bar clear of the hologram, which stands 8
      // points into the panel's top edge.
      Color.clear.frame(height: 8).accessibilityHidden(true)
    } else if shown != nil {
      let id: String = shown?.assistantID ?? relay.team.activeID
      let profile: RelayProfile? = relay.team.profiles.first { $0.id == id }
      QuickFaceContent(profile: profile, running: shown, restName: relay.team.activeName, showsFace: place == .chat) {
        before?()
        RunningChats.open(shown, relay: relay)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 8)
      .padding(.bottom, 6)
    }
  }
}

/// The face, its dot and its line, as one button; above the ⌥Space bar, the line alone.
private struct QuickFaceContent: View {
  let profile: RelayProfile?
  let running: RunningChat?
  /// Whose chat a press opens at rest.
  let restName: String
  let showsFace: Bool
  let open: () -> Void
  @Environment(\.palette) private var p

  private var status: SereinStatus {
    switch running?.state {
    case .working?: return .replying
    case .needsYou?: return .needsYou
    case nil: return .ready
    }
  }
  private var dotTint: Color? {
    switch running?.state {
    case .working?: return p.success
    case .needsYou?: return p.warning
    case nil: return nil
    }
  }

  var body: some View {
    let line: String? = QuickFace.line(running)
    Button(action: open) {
      VStack(spacing: 8) {
        if showsFace { face }
        if let line { words(line) }
      }
      .padding(.horizontal, 16)
      .contentShape(Rectangle())
    }
    .buttonStyle(AssistantPressStyle())
    .help(line ?? "Open \(restName)'s chat")
    .accessibilityLabel(QuickFace.spoken(running, restName: restName))
  }

  /// The face moves by its state (`AssistantMark`: a working face blinks and lifts, Needs you
  /// pulses its ring); the loops stop off screen and are still under Reduce Motion.
  private var face: some View {
    AssistantMark(profile: profile, size: 72, status: status)
      .overlay(alignment: .bottomTrailing) { dot }
  }
  @ViewBuilder private var dot: some View {
    if let dotTint {
      Circle().fill(dotTint).frame(width: 16, height: 16)
        .padding(3).background(p.background, in: Circle())
        .offset(x: 1, y: -1)
        .accessibilityHidden(true)
    }
  }
  /// One line, centred, cut at its end; the shimmer is `ShimmerText`'s, still under Reduce Motion.
  @ViewBuilder private func words(_ line: String) -> some View {
    if QuickFace.shimmers(running) {
      ShimmerText(text: line, font: AssistantType.meta).lineLimit(1).truncationMode(.tail)
    } else {
      Text(verbatim: line).font(AssistantType.meta).foregroundStyle(p.secondary).lineLimit(1).truncationMode(.tail)
    }
  }
}
