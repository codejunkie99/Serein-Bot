import AppKit
import SereinCore
import SwiftUI

/// The person's Goals board, kept in the Library's `todo.json` (0600) and shown in History ›
/// Goals. The person adds, edits, moves and deletes cards; an assistant can only propose one
/// (`todo_propose`: Add / Decline on Serein's card). Start opens the Start a task card with the
/// card's exact words, and only that card's yes starts work. A deadline makes a plain reminder
/// through Serein's reminders, which only notifies. A file that is there but cannot be read is
/// never written over: the board says so and changes nothing until it reads again.
@MainActor final class TodoBook: ObservableObject {
  static let shared = TodoBook()
  @Published private(set) var cards: [TodoCard] = []
  /// `todo.json` is there but could not be read.
  @Published private(set) var unreadable = false
  /// Cards whose Start card is waiting, so a second Start waits for it.
  @Published private(set) var starting: Set<String> = []
  private var library: Library?

  static let unreadableWords =
    "Serein could not read todo.json in its Library, so Goals changes nothing until it can. The cards in that file are kept as they are."
  static let gone = SereinError.invalid("That card was deleted.")

  /// At launch: reads the board, and from now on moves a card to Waiting when its task ends.
  func attach(_ library: Library, hub: AgentHub) {
    self.library = library
    let loaded = library.load([TodoCard].self, from: TodoBoard.path)
    if let loaded {
      // No task survives a quit: a card left in Doing waits for the person.
      let now = TodoBoard.relaunched(loaded)
      if now != loaded { try? library.save(now, to: TodoBoard.path) }
      cards = now
    } else if FileManager.default.fileExists(atPath: library.root.appendingPathComponent(TodoBoard.path).path) {
      unreadable = true
    }
    let previous = hub.onEnd
    hub.onEnd = { [weak self] run in
      previous?(run)
      self?.taskEnded(run.spec.threadID)
    }
  }

  /// Adds a card to Next: the person's own, or a proposal the person added on its card.
  func add(_ card: TodoCard) throws {
    guard cards.count < TodoBoard.maxCards else { throw SereinError.invalid(TodoBoard.full) }
    try commit(cards + [card])
    syncReminder(card, id: card.id)
  }

  /// The person's edit. Choosing an assistant starts nothing.
  func edit(_ id: String, title: String, notes: String?, deadline: Date?, assistantID: String?) throws {
    let clean = TodoBoard.cleanTitle(title)
    guard !clean.isEmpty else { throw SereinError.invalid("Give the card a title.") }
    guard let index = cards.firstIndex(where: { $0.id == id }) else { throw Self.gone }
    var next = cards
    next[index].title = clean
    next[index].notes = TodoBoard.cleanNotes(notes)
    next[index].deadline = deadline
    next[index].assistantID = assistantID
    try commit(next)
    syncReminder(next[index], id: id)
  }

  func updateGoal(_ id: String, details: PersonalGoal) throws {
    guard details.valid else { throw SereinError.invalid("Use a positive target, a nonnegative reading and at most 30 steps.") }
    guard let index = cards.firstIndex(where: { $0.id == id }) else { throw Self.gone }
    var next = cards; next[index].goal = details
    try commit(next)
  }

  func move(_ id: String, to column: TodoCard.Column) throws {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { throw Self.gone }
    var next = cards
    next[index].column = column
    // Moved back to Next or Doing by hand, the card is the person's again: the old task no
    // longer moves it to Waiting.
    if column == .next || column == .doing { next[index].taskID = nil }
    try commit(next)
    syncReminder(next[index], id: id)
  }

  /// Undo of an assistant's move (`board_update`): the card goes back to its column and task.
  func moveBack(_ id: String, to column: TodoCard.Column, task: String?) throws {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { throw Self.gone }
    var next = cards
    next[index].column = column
    next[index].taskID = task
    try commit(next)
    syncReminder(next[index], id: id)
  }

  func delete(_ id: String) throws {
    try commit(cards.filter { $0.id != id })
    syncReminder(nil, id: id)
  }

  /// Start on a card: the Start a task card with the card's exact words (all of them under “Show
  /// the task”), for its assistant or else Serein, with what that assistant may use and the
  /// person's Ask before level. Nothing starts without that card's yes, whatever Serein asks
  /// before. The task is the assistant's from its first turn (`childOwners`), so every step
  /// follows its places; the card then moves to Doing, linked to the task. A no starts nothing.
  func start(_ id: String, in destination: RelayTools.Destination) async throws {
    guard !starting.contains(id) else { return }
    guard let relay = RelayOrchestrator.shared else { throw SereinError.invalid("Serein is not running, so nothing can start.") }
    guard !unreadable else { throw SereinError.invalid(Self.unreadableWords) }
    guard let card = cards.first(where: { $0.id == id }) else { throw Self.gone }
    starting.insert(id)
    defer { starting.remove(id) }
    let agent = relay.agent
    let profile = card.assistantID.map { relay.profile(id: $0) }
    let prompt = TodoBoard.prompt(card)
    let engine = relay.assistantEngine(profile)
    let mode: TaskMode
    switch destination {
    case .web: mode = .research
    case .mac: mode = .anywhere
    default: mode = .answer
    }
    let choice = RelayToolHost.modelAndEffort(
      ["model": engine.model, "effort": engine.effort], models: HarnessRegistry.shared.models(engine.provider))
    var target = AgentModel.DispatchTarget(
      mode: mode, provider: engine.provider, model: choice.model, effort: choice.effort, projectID: nil,
      actions: destination != .answer, edits: false, mac: destination == .mac, initiator: .delegated)
    try startRefusal(relay, profile: profile, place: destination.place, provider: engine.provider)
    let copy = ApprovalCopy.startTask(
      provider: engine.provider.name, destination: destination.rawValue, place: nil, edits: false, task: prompt)
    let who = profile.map { "For \($0.name), with only what it may use: \(relay.canUse($0))." } ?? "For you, with your own settings."
    let level: String = relay.level.title
    let detail: String = copy.detail + "\n" + who + " Asks before: \(level)."
    // No effect on the card, as on agent_start's: a spoken yes never starts a task.
    let human = await relay.confirmAnswer(
      copy.title, detail, button: "Start", thread: relay.threadID, more: prompt, moreName: "the task")
    guard human == .yes else {
      if human == .no { return }
      throw SereinError.invalid("The Start card was not answered, so nothing started.")
    }
    // What the card showed is what starts: the same words, for the same assistant.
    guard let now = cards.first(where: { $0.id == id }), TodoBoard.prompt(now) == prompt, now.assistantID == card.assistantID
    else { throw SereinError.invalid("The card changed while Serein asked, so nothing started. Press Start again.") }
    try startRefusal(relay, profile: profile.map { relay.profile(id: $0.id) }, place: destination.place, provider: engine.provider)
    // The task is Serein's child in this chat, and its report and status come back here: the
    // chat holds the card's words too, so it is marked before the task is dispatched.
    if card.personal == true, !agent.markPersonalRead(thread: relay.threadID) {
      throw SereinError.invalid(BrowserModel.personalMarkFailed)
    }
    let thread = UUID().uuidString
    relay.childOwners[thread] = profile?.id ?? ""
    let started: String
    // One reading of the turn for the child and the launch, so they stand alike even if a turn
    // starts or ends while the dispatch waits.
    let child = relay.newChild(thread, edits: false, frame: relay.clickFrame)
    target.byPerson = child.child.byPerson == true
    do {
      started = try await agent.dispatch(prompt, into: thread, create: true, as: target)
    } catch {
      relay.childOwners[thread] = nil
      throw error
    }
    relay.adopt(child)
    // adopt names the active assistant; the card's assistant owns this task.
    relay.childOwners[started] = profile?.id ?? ""
    if card.personal == true, !agent.markPersonalRead(thread: started) {
      if let run = agent.hub.run(for: started) { agent.hub.stop(run) }
      throw SereinError.invalid(BrowserModel.personalMarkFailed)
    }
    relay.note("Started “\(String(card.title.prefix(60)))” from Goals", .allowed)
    try commit(TodoBoard.started(cards, card: id, task: started))
  }

  /// Why Start cannot go now: the assistant may not work there, or no AI app.
  private func startRefusal(_ relay: RelayOrchestrator, profile: RelayProfile?, place: AssistantPlace, provider: Provider) throws {
    if let profile, let refusal = relay.placeRefusal(place, for: profile, suggestOthers: false) {
      throw SereinError.invalid(refusal)
    }
    guard relay.agent.available[provider] != nil || HarnessRegistry.shared.executable(provider) != nil else {
      throw SereinError.invalid("Serein needs an AI app for this. Connect one in Settings › AI apps.")
    }
  }

  /// A task ended (done, failed, stopped or waiting for the person): its card waits in Waiting.
  private func taskEnded(_ task: String) {
    guard !unreadable, cards.contains(where: { $0.column == .doing && $0.taskID == task }) else { return }
    try? commit(TodoBoard.taskEnded(cards, task: task))
  }

  /// Saves the whole board first, then shows it: a save that fails changes nothing.
  private func commit(_ next: [TodoCard]) throws {
    guard !unreadable else { throw SereinError.invalid(Self.unreadableWords) }
    guard let library else { throw SereinError.invalid("The Board is unavailable.") }
    try library.save(next, to: TodoBoard.path)
    cards = next
  }

  /// The card's deadline as a plain reminder in Serein's reminders (notify only, the person's
  /// own), changed or removed with the card. It counts toward the reminder limit: past it, the
  /// card is kept and a toast says its deadline will not remind. It is written outside the
  /// schedule-change record (`updateReminders`, not `changeReminder`), so Settings has no undo
  /// that would move it apart from its card; the board is where it changes, and a change made to
  /// it elsewhere is put back at the card's next edit.
  private func syncReminder(_ card: TodoCard?, id: String) {
    guard let relay = RelayOrchestrator.shared else { return }
    let reminderID = TodoBoard.reminderID(id)
    var wanted: RelayReminder?
    if let card { wanted = TodoBoard.reminder(for: card, now: Date()) }
    let current: RelayReminder? = relay.reminders.first { $0.id == reminderID }
    guard current != wanted else { return }
    if current == nil, wanted != nil, relay.reminders.count >= TodoBoard.reminderLimit {
      ToastCenter.shared.show("The card is saved, but Serein already has \(TodoBoard.reminderLimit) reminders, so its deadline will not remind you.")
      return
    }
    relay.updateReminders { list in
      list.removeAll { $0.id == reminderID }
      if let wanted { list.append(wanted) }
    }
  }
}

extension RelayToolHost {
  /// `todo_propose`: one card with the exact title, its deadline and assistant, and the notes
  /// behind “Show the notes”. Below Allow all it asks (`.change`), so a card is never added
  /// silently; at Allow all it is added with no ask. Either way it lands in Next and starts nothing.
  func proposeTodo(_ a: [String: Any]) async throws -> [String: Any] {
    // A check-in is not the person's turn: like the schedule tools, it proposes no card.
    if !frame.byPerson, !frame.unattended { throw SereinError.invalid(Self.lowerTrust) }
    let book = TodoBook.shared
    let title = TodoBoard.cleanTitle(a["title"] as? String ?? "")
    guard !title.isEmpty else { throw SereinError.invalid("title is required: one short line.") }
    let notes = TodoBoard.cleanNotes(a["notes"] as? String)
    var deadline: Date?
    if let raw = (a["deadline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      guard let date = RelayReminder.parse(raw) else {
        throw SereinError.invalid("deadline must be an ISO 8601 time such as \(Self.stamp(Date().addingTimeInterval(86_400))).")
      }
      guard date > Date() else { throw SereinError.invalid("That deadline has passed. Now is \(Self.stamp(Date())).") }
      deadline = date
    }
    var assistant: RelayProfile?
    if let name = (a["assistant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      let profiles: [RelayProfile] = relay.team.profiles
      guard let found = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
        let names: String = profiles.map(\.name).joined(separator: ", ")
        throw SereinError.invalid("The user's assistants are: \(names).")
      }
      assistant = found
    }
    if book.unreadable { throw SereinError.invalid(TodoBook.unreadableWords) }
    guard book.cards.count < TodoBoard.maxCards else { throw SereinError.invalid(TodoBoard.full) }
    // Words from a chat that read the person's mail, messages or Mac apps keep that mark.
    var card = TodoCard(
      title: title, notes: notes, deadline: deadline, assistantID: assistant?.id,
      personal: relay.agent.readsPersonal(thread: frame.thread) ? true : nil)
    if a["steps"] != nil || a["kind"] != nil || a["target"] != nil {
      card.goal = try PersonalGoalTools.details(a)
    }
    // At Allow all the card goes on the Board with no ask; the person moves or deletes it there.
    if relay.level != .proactive {
      let copy = TodoBoard.proposal(card, assistant: assistant?.name)
      let human = await relay.confirmAnswer(
        copy.title, copy.detail, button: "Add", thread: frame.thread, more: [notes, card.goal.map { $0.steps.map(\.title).joined(separator: "\n") }].compactMap { $0 }.joined(separator: "\n"), moreName: "the plan", effect: .change)
      guard human == .yes else {
        throw SereinError.invalid(human == .no ? "The user declined the card. Nothing was added." : ActionAdmission.needsPerson)
      }
    }
    try book.add(card)
    relay.note("Added “\(String(title.prefix(60)))” to Goals", .allowed)
    if card.goal != nil { relay.showSite("goal-" + card.id, into: frame.thread) }
    return ["added": true, "id": card.id, "site_id": "goal-" + card.id, "title": title, "column": TodoCard.Column.next.title]
  }
}
