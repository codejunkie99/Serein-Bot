import AppKit
import Combine
import SereinCore
import SwiftUI

/// The top of a chat, full, as at the top of a conversation with a contact: its picture and its
/// name side by side in the middle of the header row (`SereinFullHeader`), level with Call. For
/// Serein the picture is its live hologram; a team shows its members' pictures overlapping, as a
/// group text does. A tap opens the details on the right. The conversation stays the screen.
/// After the name it says what is happening now (`RunningNow`), and grows and shrinks with it.
struct SereinChatTop: View {
  @ObservedObject var relay: RelayOrchestrator
  /// What the hologram shows (`RelayPanelView.avatarState`).
  let state: RelayLook.State
  /// The floating panel shows the same hologram over this one.
  let paused: Bool
  /// Anything waits on the person: draws the dot on Serein's picture and on a team's.
  let needsYou: Bool
  @Environment(\.palette) private var p

  /// Checks and previews keep their chat as it was unless a preview asks for this.
  static var enabled: Bool {
    !RunMode.automated || ["--ui-chat-top", "--ui-team-chat", "--ui-avatar-panel", "--ui-avatar-customise"].contains { CommandLine.arguments.contains($0) }
  }
  /// Whether this chat has the top; its header then leaves out the name pill.
  static func shows(relay: RelayOrchestrator) -> Bool { enabled }
  private static let picture: CGFloat = 24
  private static let teamFace: CGFloat = 24

  private func details() {
    let inspector = AssistantInspector.shared
    if inspector.open, inspector.assistantID == relay.team.activeID, inspector.tab(for: relay.team.activeID) == .details {
      inspector.close()
    } else {
      inspector.show(relay.team.activeID, tab: .details)
    }
  }

  /// The sidebar shows this chat's assistant: its picture moves there, and the name stays here.
  @ObservedObject private var inspector = AssistantInspector.shared
  private var pictureInSidebar: Bool {
    inspector.open && inspector.assistantID == relay.team.activeID && relay.activeTeam == nil
  }

  @ObservedObject private var sessions = SereinSessions.shared
  /// What is happening now: what needs the person, else what runs, else this chat's own turn.
  private var live: String? {
    RunningNow.lead(sessions.entries) ?? (needsYou ? "needs you" : relay.working ? "working" : nil)
  }
  /// `live` as drawn. It changes inside an animation, so the pill and its place in the row move as one.
  @State private var shown: String?
  private func tasks() { inspector.show(relay.team.activeID, tab: .activity) }

  var body: some View {
    let team: AssistantGroup? = relay.activeTeam
    let name: String = team?.name ?? relay.team.activeName
    HStack(spacing: 8) {
      if pictureInSidebar {
        EmptyView()
      } else if let team {
        Button(action: details) {
          TeamFaceStack(relay: relay, group: team, size: Self.teamFace, ground: p.background)
            .overlay(alignment: .bottomTrailing) {
              if needsYou {
                Circle().fill(p.warning).frame(width: 12, height: 12)
                  .overlay(Circle().strokeBorder(p.background, lineWidth: 2))
              }
            }
            .contentShape(Rectangle())
        }.buttonStyle(AssistantPressStyle()).accessibilityHidden(true)
      } else if relay.team.activeID == relay.team.main?.id {
        ChatTopHologramView(state: state, relay: relay, paused: paused, needsYou: needsYou, open: details, glides: true)
          .frame(width: Self.picture, height: Self.picture)
      } else {
        Button(action: details) {
          AssistantLiveMark(relay: relay, profile: relay.team.active, size: Self.picture)
            .frame(width: Self.picture, height: Self.picture).contentShape(Circle())
        }.buttonStyle(AssistantPressStyle()).accessibilityHidden(true)
      }
      Button(action: details) {
        Text(verbatim: name).font(UIStyle.font(14, weight: .medium)).foregroundStyle(p.ink)
          .lineLimit(1).truncationMode(.tail).contentShape(Rectangle())
      }
      .buttonStyle(AssistantPressStyle())
      // Its own width up to 320, so the picture sits against the name.
      .frame(maxWidth: 320).fixedSize()
      .help("Show \(name)'s details")
      .accessibilityLabel(name)
      .accessibilityHint("Shows \(name)'s details on the right")
      if let shown {
        let peek: String = RunningNow.peek(sessions.entries) ?? shown
        Button(action: tasks) {
          HStack(spacing: 6) {
            Circle().fill(needsYou || sessions.needsYou > 0 ? p.warning : p.faint).frame(width: 5, height: 5)
            // The middle gives way, so a long name keeps "needs you" in view.
            Text(verbatim: shown).font(UIStyle.meta).foregroundStyle(p.secondary)
              .lineLimit(1).truncationMode(.middle)
          }.contentShape(Rectangle())
        }
        .buttonStyle(AssistantPressStyle())
        .help(peek)
        .accessibilityLabel(peek)
        .accessibilityHint("Shows tasks on the right")
        .transition(.opacity)
      }
    }
    // Grok's floating bot pill: the pane, a hairline and a soft drop in light.
    .padding(.leading, pictureInSidebar ? 13.5 : 7.5).padding(.trailing, 13.5).padding(.vertical, 7.5)
    .background(p.panel, in: Capsule())
    .overlay(Capsule().strokeBorder(p.line, lineWidth: UIStyle.hairline))
    .shadow(color: p.shadow(0.2), radius: 6, y: 4)
    .onChange(of: live) { _, next in withAnimation(AssistantInspector.moves) { shown = next } }
    .onAppear {
      sessions.attach(relay: relay)
      shown = live
      if CommandLine.arguments.contains("--ui-tasks-panel") { AssistantInspector.shared.show(relay.team.activeID, tab: .activity) }
      if CommandLine.arguments.contains("--ui-details-panel") { AssistantInspector.shared.show(relay.team.activeID, tab: .details) }
      // `--ui-avatar-panel`: the panel open with the hologram in its card; `--ui-avatar-customise`
      // also opens the customise sheet (InspectorFace).
      if ["--ui-avatar-panel", "--ui-avatar-customise"].contains(where: { CommandLine.arguments.contains($0) }) {
        AssistantInspector.shared.show(relay.team.activeID, tab: .activity)
      }
    }
  }
}

/// Serein's own hologram as its picture, on the window's one engine, with a dot while Serein needs
/// the person. The drawn mark stands in until the hologram is ready and wherever WebGL fails. It is
/// in one place at a time: the chat's top, the panel's card while the panel shows Serein, or the
/// customise sheet's preview while that is open (the card draws the mark meanwhile).
struct ChatTopHologramView: View {
  let state: RelayLook.State
  @ObservedObject var relay: RelayOrchestrator
  let paused: Bool
  let needsYou: Bool
  let open: () -> Void
  var help = "Show details and customise"
  /// The chat's top and the panel's card: as the panel opens or closes, the one that appears glides
  /// from where the other was (a transform only, none under Reduce Motion).
  var glides = false
  /// The customise sheet's unsaved choice; nil is the look Serein wears.
  var look: RelayLook? = nil
  /// The `raised` disc behind it; onboarding shows the hologram on the page itself.
  var disc = true
  /// Its bloom, for the welcome only; in a chat it stays flat, as the drawn mark does.
  var glows = false
  @ObservedObject private var engine = SereinSurface.main.engine
  @State private var glide: CGSize = .zero
  @State private var glideScale: CGFloat = 1
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sereinReducedEffects) private var reducedEffects
  var body: some View {
    GeometryReader { box in
      let side = min(box.size.width, box.size.height)
      let here: CGRect = box.frame(in: .global)
      ZStack {
        if disc { Circle().fill(p.raised) }
        if !engine.ready || engine.failed {
          SereinHologramMark(size: side * 0.72, turning: relay.working, glows: glows)
        }
        if !engine.failed {
          RelayAvatarStage(
            state: state, look: shownLook, jobs: RelayPanelView.avatarJobs(relay: relay),
            controller: SereinSurface.controller, paused: paused, engine: engine, onTap: open)
            .padding(side * 0.06)
        }
      }
      .frame(width: side, height: side)
      // A native tap over the web view, so opening details does not depend on the page answering.
      .overlay {
        Color.clear.contentShape(Circle()).onTapGesture(perform: open).help(help).accessibilityHidden(true)
      }
      .overlay(alignment: .bottomTrailing) {
        if needsYou {
          Circle().fill(p.warning).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(p.background, lineWidth: 2)).accessibilityHidden(true)
        }
      }
      .scaleEffect(glideScale).offset(glide)
      .onAppear { arrive(at: here) }
      .onChange(of: here) { _, frame in if glides { Self.lastFrame = frame } }
    }
  }
  private var shownLook: RelayLook {
    var shown: RelayLook = self.look ?? relay.look
    if !glows { shown.effects.bloom = 0 }
    return shown
  }
  /// Where the gliding hologram was drawn last, in the window's coordinates.
  private static var lastFrame: CGRect?
  /// Just after the panel opened or closed, start where the hologram was and glide here.
  private func arrive(at here: CGRect) {
    guard glides else { return }
    let from: CGRect? = Self.lastFrame
    Self.lastFrame = here
    guard let from, from != here, here.width > 0, Date() < AssistantInspector.shared.glideUntil,
      !reduceMotion, !reducedEffects, let moves = AssistantInspector.moves
    else { return }
    glide = CGSize(width: from.midX - here.midX, height: from.midY - here.midY)
    glideScale = from.width / here.width
    DispatchQueue.main.async {
      withAnimation(moves) {
        glide = .zero
        glideScale = 1
      }
    }
  }
}

/// What is at work on this Mac, for the top-right toggle's count and the panel's Tasks tab. Rebuilt
/// when sessions or tasks change, not on each draw: reading the task list walks every saved chat.
@MainActor final class SereinSessions: ObservableObject {
  static let shared = SereinSessions()
  @Published private(set) var entries: [SereinSessionList.Entry] = []
  var needsYou: Int { entries.filter { $0.state == .needsYou }.count }
  private var watching: AnyCancellable?

  func attach(relay: RelayOrchestrator) {
    guard watching == nil else { return }
    let agent = relay.agent
    entries = Self.read(relay: relay)
    // At most once a second, after a change has landed; the timer lets a finished task leave on time.
    watching = Publishers.MergeMany([
      SereinTray.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      ExternalSessionStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      agent.hub.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      agent.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
      Timer.publish(every: 60, on: .main, in: .common).autoconnect().map { _ in () }.eraseToAnyPublisher(),
    ])
      .receive(on: DispatchQueue.main)
      .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self, weak relay] in
        guard let self, let relay else { return }
        let next = Self.read(relay: relay)
        if next != self.entries { self.entries = next }
      }
  }

  private static func read(relay: RelayOrchestrator) -> [SereinSessionList.Entry] {
    let now = Date()
    let agent = relay.agent
    let tasks = SereinTray.items(hub: agent.hub, agent: agent, relay: relay, ledger: SereinTray.shared.ledger, now: now)
      + UIPreview.affectLane3Tasks
    let outside = ExternalSessionStore.shared.sessions.filter { !ProjectChatIndex.isTemporary($0.cwd) }
    // A session behind a Serein chat already shows as that chat.
    let followed = Dictionary(agent.conversations.compactMap { chat -> (String, String)? in
      guard let remote = chat.remoteID, let driver = chat.provider.driver else { return nil }
      return (driver.rawValue + ":" + remote, chat.id)
    }, uniquingKeysWith: { first, _ in first })
    return SereinSessionList.entries(tasks: tasks, outside: outside, followed: followed, now: now)
  }
}

/// The header's top-right toggle: the panel on the right, on its Tasks tab, with a dot while
/// anything needs the person. With the panel on another tab it moves to Tasks. Its hover peek
/// names what is at work (`RunningNow`); the chat's pill says it in the row.
/// No number on it: the owner rules out count badges.
struct SereinPanelToggle: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var sessions = SereinSessions.shared
  @ObservedObject private var inspector = AssistantInspector.shared
  @Environment(\.palette) private var p
  private var showing: Bool {
    inspector.open && inspector.assistantID == relay.team.activeID
      && inspector.tab(for: relay.team.activeID) == .activity
  }
  private func toggle() {
    if showing { inspector.close() } else { inspector.show(relay.team.activeID, tab: .activity) }
  }
  var body: some View {
    let needs = sessions.needsYou
    let peek: String? = RunningNow.peek(sessions.entries)
    Button(action: toggle) {
      InterfaceIcon(systemName: "sidebar.right", size: 13).foregroundStyle(p.ink)
        .frame(width: 26, height: 26).contentShape(Rectangle())
    }
    .buttonStyle(RoundIconButtonStyle(size: 30))
    .overlay(alignment: .topTrailing) {
      if needs > 0, !showing {
        Circle().fill(p.warning).frame(width: 8, height: 8)
          .overlay(Circle().strokeBorder(p.background, lineWidth: 1.5))
          .offset(x: 1, y: 1)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
    .help(showing ? "Hide the panel" : peek ?? "Show tasks and computer")
    .accessibilityLabel(showing ? "Hide the panel" : "Show tasks and computer")
    .accessibilityValue(peek ?? "")
    .onAppear { sessions.attach(relay: relay) }
  }
}

/// The panel's Tasks tab: everything at work on this Mac, in plain rows. Each one gets this row
/// until it can draw its own view.
struct InspectorTasks: View {
  @ObservedObject var relay: RelayOrchestrator
  @ObservedObject private var sessions = SereinSessions.shared
  @Environment(\.palette) private var p
  private static let sections: [(state: SereinSessionList.Entry.State, title: String)] = [
    (.needsYou, "Needs you"), (.working, "Working"), (.finished, "Finished"),
  ]
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      ForEach(Self.sections, id: \.title) { section in
        let rows = sessions.entries.filter { $0.state == section.state }
        if !rows.isEmpty {
          InspectorSection(title: section.title) {
            InspectorShowMore(items: rows) { entry in
              InspectorTaskRow(entry: entry, session: ExternalSessionStore.shared.sessions.first { $0.id == entry.sourceID }, agent: relay.agent)
            }
          }
        }
      }
    }
    .onAppear { sessions.attach(relay: relay) }
  }
}

/// Grok's task check: a warning ring waits on the person, a turning green arc works, a green check
/// is done.
private struct InspectorTaskCheck: View {
  let state: SereinSessionList.Entry.State
  @Environment(\.palette) private var p
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.sereinReducedEffects) private var previewReducedEffects
  var body: some View {
    Group {
      switch state {
      case .needsYou: Circle().strokeBorder(p.warning, lineWidth: 3.5).opacity(0.9).frame(width: 15, height: 15)
      case .working:
        if systemReduceMotion || previewReducedEffects {
          Circle().trim(from: 0, to: 0.75).stroke(p.success, lineWidth: 1.5).rotationEffect(.degrees(-45)).frame(width: 13.5, height: 13.5)
        } else {
          TurningArc(color: p.success, diameter: 13.5, fraction: 0.75, lineWidth: 1.5, lineCap: .butt, period: 1.4)
            .frame(width: 15, height: 15)
        }
      case .finished: InterfaceIcon(systemName: "checkmark.circle.fill", size: 18).foregroundStyle(p.success)
      }
    }.frame(width: 18, height: 18).accessibilityHidden(true)
  }
}

/// One task or session: its state mark, title and words; a click opens it. The Tasks tab and the
/// away card (`AwaySummaryCard`) both draw it.
struct InspectorTaskRow: View {
  let entry: SereinSessionList.Entry
  let session: ExternalSession?
  let agent: AgentModel
  @Environment(\.palette) private var p
  private var ink: AgentRowInk {
    switch entry.state {
    case .needsYou: return .attention
    case .working: return .working
    case .finished: return .quiet
    }
  }
  private var words: String? { entry.place ?? entry.detail }
  private var canOpen: Bool { !entry.outside || session != nil }
  var body: some View {
    Button {
      SubThreadFocus.shared.close()
      if entry.outside {
        guard let session, let link = SessionOpen.link(for: session) else {
          ToastCenter.shared.show("This session does not have a readable chat in Serein yet.")
          return
        }
        agent.openLinked(link, lastActive: session.updatedAt)
      } else if let thread = agent.openThreadItem(entry.sourceID) {
        SereinRouter.direct { agent.openConversation(thread) }
      } else {
        SereinRouter.open(threadID: entry.sourceID)
      }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        InspectorTaskCheck(state: entry.state).padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          AgentRowTitle(text: entry.title, ink: ink, font: UIStyle.font(13, weight: .medium))
          if let words {
            Text(verbatim: words).font(UIStyle.font(12)).foregroundStyle(p.secondary).lineLimit(2).truncationMode(.tail)
          }
        }
        Spacer(minLength: 8)
        if canOpen { InterfaceIcon(systemName: "chevron.right", size: 10).foregroundStyle(p.faint).accessibilityHidden(true) }
      }
      .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }.buttonStyle(InspectorRowStyle()).disabled(!canOpen)
      .help("Open \(entry.title)")
      .accessibilityElement(children: .combine)
      .accessibilityHint("Opens this task")
  }
}
