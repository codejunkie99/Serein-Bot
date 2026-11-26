import Foundation
import SereinCore

/// Routine offers in the app (rules in SereinCore/RoutineOffers.swift, board 13): the person's
/// own typed words in the chat on screen count as one request of a kind (`noteRoutineRequest`,
/// from `ask`); after the third such request on different days at about the same time, the
/// reply carries a "Make it a routine?" card (`AgentMessage.routineOffer`). Serein never makes the
/// routine by itself: "Make it" (`acceptRoutineOffer`) makes it through the same path as a typed
/// routine (`ScheduleGuard`, its owner, the receipt with Undo); "Not now" (`declineRoutineOffer`)
/// blocks that offer for 30 days. Assistant, link, ask and paired-app turns never count, and a
/// chat with the personal-read mark makes no offer. The book lives in relay/routine-offers.json,
/// read through the unreadable guard.
extension RelayOrchestrator {
  static let routineOffersFile = "relay/routine-offers.json"
  static let suggestRoutinesKey = "serein.relay.suggestRoutines"
  /// The Undo entry of "stop suggesting routines".
  static let offersUndoEntry = "setting:suggest-routines"

  /// Settings › Serein › Suggestions › "Suggest routines": on unless the person turned it off.
  var suggestsRoutines: Bool {
    get { UserDefaults.standard.object(forKey: Self.suggestRoutinesKey) as? Bool ?? true }
    set {
      objectWillChange.send()
      Self.setSetting(newValue, forKey: Self.suggestRoutinesKey)
    }
  }
  /// The Mac shows times as "7:30 AM".
  static var twelveHourClock: Bool {
    let format: String = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
    return format.contains("a")
  }

  func loadRoutineOffers() {
    desk.routineOffers = readState(RoutineOffers.Book.self, Self.routineOffersFile) ?? RoutineOffers.Book()
  }
  func saveRoutineOffers() { persist(desk.routineOffers, Self.routineOffersFile) }

  /// The person's own message in the chat on screen (`ask`, only with `userMessage`): its kind
  /// and time count toward an offer. Never its words. A chat with the personal-read mark counts
  /// nothing.
  func noteRoutineRequest(_ words: String) {
    guard suggestsRoutines, !isUnreadable(Self.routineOffersFile) else { return }
    guard !agent.readsPersonal(thread: threadID), let kind = RoutineOffers.kind(of: words) else { return }
    let now = Date()
    let request = RoutineOffers.Request(kind: kind.id, owner: team.activeID, at: now)
    var book = desk.routineOffers
    book.record(request, now: now)
    desk.routineOffers = book
    desk.offerAsked[threadID] = request
    saveRoutineOffers()
  }

  /// The person's turn in the chat on screen ended (`ended`): its reply carries the offer when
  /// this was the third such request. Only a turn the person started, that neither failed nor
  /// was stopped, in a chat with no personal-read mark.
  func offerRoutineIfDue(_ run: AgentRun, byPerson: Bool) {
    let thread = run.spec.threadID
    guard byPerson, let asked = desk.offerAsked.removeValue(forKey: thread) else { return }
    let outcome = run.record.outcome
    guard suggestsRoutines, outcome != .stuck, outcome != .stopped, !isUnreadable(Self.routineOffersFile) else { return }
    guard !agent.readsPersonal(thread: thread), let kind = RoutineOffers.kind(id: asked.kind) else { return }
    let now = Date()
    let main: String = team.mainProfileID ?? RelayTeam.mainID
    let owned: [RelayReminder] = reminders.filter { $0.action && ($0.profileID ?? main) == asked.owner }
    let existing: [String] = owned.map(\.text)
    let on: Int = ScheduleRequest.actionRoutinesOn(reminders)
    guard
      let found = RoutineOffers.next(
        book: desk.routineOffers, kind: kind, owner: asked.owner, existing: existing, actionRoutinesOn: on, now: now,
        calendar: .current)
    else { return }
    let offer = RoutineOffers.offer(
      found.plan, pattern: found.pattern, kind: kind, id: UUID().uuidString, twelveHour: Self.twelveHourClock)
    var attached = false
    agent.amendThread(thread) { messages in attached = Self.attach(offer, to: &messages) }
    guard attached else { return }
    var book = desk.routineOffers
    book.add(RoutineOffers.Book.Entry(offer: offer, plan: found.plan, chat: thread, at: now))
    desk.routineOffers = book
    saveRoutineOffers()
    note("Offered a routine: \(found.plan.what)", .auto)
  }
  /// Puts `offer` on the turn's reply: its last message of its own after the person's words.
  /// False when the turn left no reply.
  static func attach(_ offer: RoutineOffer, to messages: inout [AgentMessage]) -> Bool {
    let start: Int = (messages.lastIndex(where: { $0.role == "you" }) ?? -1) + 1
    guard let i = messages.lastIndex(where: { $0.role == "assistant" && $0.from == nil && $0.line == nil }), i >= start else {
      return false
    }
    messages[i].routineOffer = offer
    return true
  }

  /// "Make it" on the card: the routine is made as a typed one is, within `ScheduleGuard`, owned
  /// by the assistant whose chat it is, with its receipt and Undo in that chat. The card then
  /// reads "Made.".
  func acceptRoutineOffer(_ id: String) {
    guard let entry = desk.routineOffers.entry(id), entry.offer.state == .open else { return }
    let chat = entry.chat
    let plan = entry.plan
    let path = "relay/reminders.json"
    guard !isUnreadable(path) else {
      deliver(receipt: nil, line: RelayStateFile.words(for: path), into: chat)
      return
    }
    guard team.profiles.contains(where: { $0.id == plan.owner }) else {
      deliver(receipt: nil, line: "That assistant is gone, so I made nothing.", into: chat)
      return
    }
    let now = Date()
    let on: Int = ScheduleRequest.actionRoutinesOn(reminders)
    if let refusal = ScheduleRequest.refusal(repeats: plan.repeats, cron: nil, acts: true, actionRoutinesOn: on) {
      deliver(receipt: nil, line: refusal.words, into: chat)
      return
    }
    guard reminders.count < 200, let due = plan.firstDue(after: now, calendar: .current) else {
      deliver(receipt: nil, line: "Too many reminders. Cancel some first.", into: chat)
      return
    }
    let made = RelayReminder(text: plan.what, due: due, repeats: plan.repeats, action: true, profileID: plan.owner)
    // Recorded like the person's own changes, so the receipt's Undo and Settings can take it back.
    changeReminder(made.id, actor: "user", "Added \(Self.short(made.text))") { $0 = made }
    noteReminderCreated(made)
    note("Made the routine “\(String(made.text.prefix(60)))”", .user)
    _ = scheduleReceipt(for: made, owner: nil, into: chat)
    answerOffer(id, .made)
  }
  /// "Not now" on the card: nothing is made, and the same offer does not come again for 30
  /// days. The card then reads "Okay, not now.".
  func declineRoutineOffer(_ id: String) {
    guard let entry = desk.routineOffers.entry(id), entry.offer.state == .open else { return }
    answerOffer(id, .declined)
  }
  /// Keeps the answer in the book and on the card's message (once its chat is idle).
  private func answerOffer(_ id: String, _ state: RoutineOffer.State) {
    var book = desk.routineOffers
    guard book.answer(id, state, now: Date()), let entry = book.entry(id) else { return }
    desk.routineOffers = book
    saveRoutineOffers()
    desk.offerStates[id] = (chat: entry.chat, state: state)
    flushOfferStates()
  }
  /// The cards whose answer could not go on their message while a turn ran there.
  func flushOfferStates() {
    for (id, pending) in desk.offerStates {
      let done: Bool = agent.amendThread(pending.chat) { messages in
        for i in messages.indices where messages[i].routineOffer?.id == id { messages[i].routineOffer?.state = pending.state }
      }
      if done { desk.offerStates[id] = nil }
    }
  }

  /// "Stop suggesting routines" as the whole message (SPEC 3.11, a host intent): the person's own
  /// words turn the switch off at once (`Admission` `.ownChange` in their turn), with their bubble
  /// and a receipt with Undo, and no model turn. False when the chat is busy or the words cannot
  /// go in: they then go on as an ordinary message.
  func stopSuggestingRoutines(_ words: String) -> Bool {
    guard !working, Admission.decide(.ownChange, turn: .person, wordsNameIt: true) == .apply else { return false }
    let thread = threadID
    let speaker: RelayProfile? = team.active
    let bubble = AgentMessage(role: "you", text: words)
    let posted: Bool = agent.postHostMessage(
      bubble, into: thread, title: speaker?.name ?? RelayTeam.mainName, provider: assistantEngine(speaker).provider)
    guard posted else { return false }
    suggestsRoutines = false
    let receipt = Receipt(
      kind: .assistantChanged, line: RoutineOffers.stoppedLine,
      undo: UndoToken(entry: Self.offersUndoEntry, kind: .assistantChanged))
    deliver(receipt: receipt, into: thread)
    note("Stopped suggesting routines", .user)
    return true
  }
}
