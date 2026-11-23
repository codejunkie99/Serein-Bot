import AppKit
import Combine
import SereinCore

/// The person's own marks on the assistant list (board 12): the pinned rows in pin order, the
/// hidden rows, and the rows with a reply or a routine's result not seen yet. The rules are pure
/// (`AssistantRowRules`). The marks live in relay/sidebar.json and are read once through the
/// relay's guarded read (`readState`): a file that is there and does not decode stays as it is,
/// and `persist` never writes over it, so the marks then last only until Serein quits.
///
/// A turn that ends calls `replyLanded` (the orchestrator, at an owner run, a link turn, a late
/// ask answer and a hand-off result). A chat that opens is read: a switch to it, and Serein's
/// chat coming back on screen (as `RelayController.markRead` clears the Serein row's dot).
@MainActor final class AssistantRowState: ObservableObject {
  static let shared = AssistantRowState()
  /// Profile ids, in pin order.
  @Published private(set) var pinned: [String] = []
  @Published private(set) var hidden: Set<String> = []
  @Published private(set) var unread: Set<String> = []
  /// The file was read (or is not there). Marks set before that join the file's when it is read.
  private var loaded = false
  private var watches: [AnyCancellable] = []

  private init() {
    // Read after this frame, so no relay state changes while a view is being drawn.
    Task { @MainActor [weak self] in self?.loadIfNeeded() }
  }

  var marks: AssistantRowMarks { AssistantRowMarks(pinned: pinned, hidden: hidden, unread: unread) }

  func pin(_ id: String) { change { AssistantRowRules.pinning(id, in: $0) } }
  func unpin(_ id: String) { change { AssistantRowRules.unpinning(id, in: $0) } }
  /// A drag or Move up and Move down among the pinned rows.
  func orderPins(_ ids: [String]) { change { AssistantRowRules.ordering(pins: ids, in: $0) } }
  /// The main assistant never hides (`AssistantRowRules.hiding`).
  func hide(_ id: String) {
    let main: String = RelayOrchestrator.shared?.team.mainProfileID ?? RelayTeam.mainID
    change { AssistantRowRules.hiding(id, main: main, in: $0) }
  }
  func show(_ id: String) { change { AssistantRowRules.showing(id, in: $0) } }
  func markUnread(_ id: String) { change { AssistantRowRules.marking(id, unread: true, in: $0) } }
  func markRead(_ id: String) { change { AssistantRowRules.marking(id, unread: false, in: $0) } }
  /// A reply or a routine's result landed in `profileID`'s chat. Unread when that chat is not on screen.
  func replyLanded(profileID: String, chatOnScreen: Bool) {
    change { AssistantRowRules.replyLanded(profileID, chatOnScreen: chatOnScreen, in: $0) }
  }
  /// The list calls it when it shows: the file is read once the relay is there.
  func attach() { loadIfNeeded() }

  private func change(_ rule: (AssistantRowMarks) -> AssistantRowMarks) {
    loadIfNeeded()
    let before: AssistantRowMarks = marks
    let next: AssistantRowMarks = rule(before)
    guard next != before else { return }
    apply(next)
    save()
  }
  private func apply(_ next: AssistantRowMarks) {
    if pinned != next.pinned { pinned = next.pinned }
    if hidden != next.hidden { hidden = next.hidden }
    if unread != next.unread { unread = next.unread }
  }
  /// Checks and previews write nothing; `persist` refuses a file that did not decode.
  private func save() {
    guard loaded, RelayOrchestrator.persists, let relay = RelayOrchestrator.shared else { return }
    relay.persist(marks, AssistantRowRules.path)
  }
  private func loadIfNeeded() {
    guard !loaded, let relay = RelayOrchestrator.shared else { return }
    loaded = true
    let saved: AssistantRowMarks = relay.readState(AssistantRowMarks.self, AssistantRowRules.path) ?? AssistantRowMarks()
    let early: AssistantRowMarks = marks
    let roster: [String] = relay.team.profiles.map(\.id)
    let next: AssistantRowMarks = AssistantRowRules.pruned(AssistantRowRules.merged(saved, early), roster: roster)
    apply(next)
    if early != AssistantRowMarks() { save() }
    watch(relay)
  }
  /// A chat that opens is read: a switch to another assistant, and Serein's chat on screen again
  /// (the app back in front, the window key again, Serein shown, or the Serein row's dot cleared).
  private func watch(_ relay: RelayOrchestrator) {
    let center = NotificationCenter.default
    let opened = relay.$team.map(\.activeID).removeDuplicates().receive(on: RunLoop.main)
      .sink { [weak self] id in self?.markRead(id) }
    let cleared = SereinSurface.main.$unread.filter { !$0 }.map { _ in () }
    let active = center.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () }
    let key = center.publisher(for: NSWindow.didBecomeKeyNotification).map { _ in () }
    let placed = SereinSurface.main.placement.objectWillChange.map { _ in () }
    let shown = cleared.merge(with: active).merge(with: key).merge(with: placed).receive(on: RunLoop.main)
      .sink { [weak self, weak relay] in
        guard let relay, RelayController.chatShown, SereinSurface.main.view == .chat else { return }
        self?.markRead(relay.team.activeID)
      }
    watches = [opened, shown]
  }
}
