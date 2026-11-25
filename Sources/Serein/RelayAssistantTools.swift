import AppKit
import SereinCore

/// What the assistant tools keep for this launch, beside the roster: each chat's receipts, system
/// lines and answers of the turn that runs there, host messages that wait for a chat to be idle,
/// the way back from each change, proposals, the work Serein paused for an assistant, the owned
/// links and the open asks. A small observable object, so the chat redraws for these alone.
@MainActor final class AssistantDesk: ObservableObject {
  /// What one chat's running turn has to show when it ends: receipts and connect offers under its
  /// reply, system lines and other assistants' answers above it.
  struct Facts: Equatable {
    var receipts: [Receipt] = []
    /// System lines and other assistants' answers, in the order they came.
    var above: [AgentMessage] = []
    var connect: [ConnectLink] = []
    /// The dashboard this turn made (`dashboard_make`); the newest one wins.
    var siteID: String?
    var dashboard: DashboardSpec?
    /// The post this turn drafted (`post_draft`); the newest one wins.
    var post: PostDraft?
    /// The view this turn drew (`ui_show`); the newest one wins.
    var view: UITree?
    /// Yesterday's reel, under the morning brief (`ReportReelMaker.yesterday`).
    var reel: ReportReel?
    var isEmpty: Bool {
      receipts.isEmpty && above.isEmpty && connect.isEmpty && dashboard == nil && reel == nil && siteID == nil && post == nil && view == nil
    }
  }
  /// A system line as a host message: plain words, never a model's.
  static func lineMessage(_ line: String) -> AgentMessage {
    var message = AgentMessage(role: "assistant", text: "", notice: true)
    message.line = line
    return message
  }
  /// What Undo does besides putting the roster back.
  enum Undo {
    /// The roster only.
    case team
    /// The assistant was paused: its held work comes back.
    case paused(String)
    /// The assistant was turned on: the work that came back is held again.
    case resumed(String, [HeldWork])
    /// The assistant was deleted: the work that was on comes back with it.
    case deleted(name: String, resume: [HeldWork])
    /// A link was made: Undo removes it.
    case link(String)
    /// A link was removed: Undo puts it back while its secret is still kept.
    case unlink(String)
    /// A Board card was moved (`board_update`): Undo puts it back in its column, with its task.
    case board(card: String, column: TodoCard.Column, task: String?)
  }
  /// A removed link, kept with its secret for the Undo window.
  struct RemovedLink {
    var link: OwnedLink
    var at: Date
  }
  /// One host message that waits for its chat.
  struct Post {
    var thread: String
    var message: AgentMessage
    var title: String
    var provider: Provider
  }

  /// By chat id. The chat draws them live under the running reply; they land on it at its end.
  @Published var facts: [String: Facts] = [:]
  var posts: [Post] = []
  var undo = UndoStack()
  var undoActions: [String: Undo] = [:]
  /// The work Serein paused for each paused assistant, by profile id (relay/assistant-holds.json).
  var holds: [String: [HeldWork]] = [:]
  /// Kept in relay/links.json (RelayLinks.swift).
  @Published var links: [OwnedLink] = []
  /// Saved keys and cards by name and host, never the value (relay/secrets.json, RelaySecrets.swift).
  @Published var secrets: [SecretRecord] = []
  /// Light asks by hidden chat id (RelayAsks.swift). Published: a row reads who an assistant
  /// is answering now (`answering`).
  @Published var asks: [String: Ask] = [:]
  /// The names each chat is asking now, for its moving line ("Asking Planner…").
  @Published var asking: [String: [String]] = [:]
  /// Each asker's asks of the last hour and its open runs (relay/asks.json).
  var askRate = AskPolicy.Rate()
  /// The hidden chats of this launch's asks, also after they went, so no list, toast or notice
  /// shows them.
  var hiddenThreads: Set<String> = []
  var lateTurns: [LateTurn] = []
  /// The work ledger, once open: the one instance `openWork` opened (RelayWork.swift), for the
  /// link receiver's writes.
  var ledger: WorkLedger?
  /// Each link's deliveries of the last hour, shared with the receiver across restarts.
  let linkRates = LinkRates()
  /// Links removed in the last seconds, for Undo.
  var removedLinks: [String: RemovedLink] = [:]
  /// The live plan card of each chat's running turn (the `plan` tool). Its elapsed time is drawn
  /// from `PlanCard.startedAt` by a small clock of the view's own, never by this object.
  @Published var plans: [String: PlanCard] = [:]
  /// Routine offers: the kinds and times of the person's requests, the offers and the blocks
  /// (relay/routine-offers.json, RelayRoutineOffers.swift).
  var routineOffers = RoutineOffers.Book()
  /// The request the person's last message in each chat counted, until that turn ends.
  var offerAsked: [String: RoutineOffers.Request] = [:]
  /// A card's answer that waits for its chat to be idle, by offer id.
  var offerStates: [String: (chat: String, state: RoutineOffer.State)] = [:]
}

/// Why a change or an Undo did not land, in the person's words (`Result` needs an `Error`).
struct ChangeRefusal: Error, ExpressibleByStringLiteral {
  let words: String
  init(_ words: String) { self.words = words }
  init(stringLiteral words: String) { self.words = words }
}

extension RelayOrchestrator {
  static let holdsFile = "relay/assistant-holds.json"

  // MARK: who asks for a change

  /// The kind of turn a tool call comes from, for the admission rule (SPEC 3.9): the person's own
  /// message; a schedule, watch or link, or a turn Serein starts to speak first (a check-in, a
  /// brief), where nobody is there; else a turn that carries another assistant's or a task's
  /// words (a hand-off's result, a finished task, a late answer), which counts as an assistant
  /// asking: it can only propose. A paired app's request is never the person's. When the turn
  /// classes land (`TurnClass.of`, SPEC A14) they replace this, and a remote turn never approves.
  var admissionTurn: Admission.Turn {
    if runsUnattended || proactiveTurn { return .unattended }
    return startedByPerson ? .person : .assistant
  }
  /// The person's words in this turn, only while the person started it.
  var typedWords: String { startedByPerson ? (personWords ?? "") : "" }

  // MARK: kept between launches

  /// Each file goes through the unreadable guard (`readState`, SPEC I13): one that does not
  /// decode is kept as it is, the person is told once, and no save writes over it.
  func loadAssistantWork() {
    desk.holds = readState([String: [HeldWork]].self, Self.holdsFile) ?? [:]
    loadLinks()
    loadSecrets()
    loadAsks()
    loadSeatChats()
    loadRoutineOffers()
  }
  func saveHolds() { persist(desk.holds, Self.holdsFile) }

  // MARK: receipts, lines and host messages

  /// Shows what landed: in a chat with a turn running now, on that turn's reply when it ends;
  /// in any other chat, as a host message now (or once it is idle). A receipt's Undo is kept.
  func deliver(receipt: Receipt?, line: String? = nil, connect: [ConnectLink] = [], into thread: String,
               owner: RelayProfile? = nil) {
    if let token = receipt?.undo { desk.undo.push(token, thread: thread) }
    let live = agent.hub.run(for: thread) != nil || (thread == threadID && sending)
    if live {
      var facts: AssistantDesk.Facts = desk.facts[thread] ?? AssistantDesk.Facts()
      if let receipt { facts.receipts.append(receipt) }
      if let line { facts.above.append(AssistantDesk.lineMessage(line)) }
      facts.connect.append(contentsOf: connect)
      desk.facts[thread] = facts
      return
    }
    var message = AgentMessage(role: "assistant", text: "", notice: true)
    if let receipt { message.receipts = [receipt] }
    message.line = line
    if !connect.isEmpty { message.connect = connect }
    post(message, into: thread, owner: owner)
  }
  /// A dashboard for `thread`'s reply: on the running turn, it lands on its reply when the turn
  /// ends (`land`); outside a turn, as a host message now.
  func showDashboard(_ spec: DashboardSpec, into thread: String) {
    let live = agent.hub.run(for: thread) != nil || (thread == threadID && sending)
    if live {
      var facts: AssistantDesk.Facts = desk.facts[thread] ?? AssistantDesk.Facts()
      facts.dashboard = spec
      desk.facts[thread] = facts
      return
    }
    var message = AgentMessage(role: "assistant", text: "", notice: true)
    message.dashboard = spec
    post(message, into: thread)
  }
  /// Another assistant's answer for `thread`, under the line that asked.
  func deliverAnswer(_ message: AgentMessage, into thread: String) {
    let live = agent.hub.run(for: thread) != nil || (thread == threadID && sending)
    if live {
      var facts: AssistantDesk.Facts = desk.facts[thread] ?? AssistantDesk.Facts()
      facts.above.append(message)
      desk.facts[thread] = facts
      return
    }
    post(message, into: thread)
  }
  /// A drafted post for `thread`'s reply: on the running turn, it lands on its reply when the turn
  /// ends (`land`); outside a turn, as a host message now.
  func showPost(_ draft: PostDraft, into thread: String) {
    let live = agent.hub.run(for: thread) != nil || (thread == threadID && sending)
    if live {
      var facts: AssistantDesk.Facts = desk.facts[thread] ?? AssistantDesk.Facts()
      facts.post = draft
      desk.facts[thread] = facts
      return
    }
    var message = AgentMessage(role: "assistant", text: "", notice: true)
    message.post = draft
    post(message, into: thread)
  }
  /// A drawn view for `thread`'s reply. On the running turn it takes the place, now, of the view
  /// whose button started the turn (true), or lands on the turn's reply when the turn ends
  /// (`land`); outside a turn, it is a host message now.
  @discardableResult
  func showView(_ tree: UITree, into thread: String) -> Bool {
    let run: AgentRun? = agent.hub.run(for: thread)
    if run != nil || (thread == threadID && sending) {
      // Only the person's own press: a scheduled or proactive turn never redraws a view.
      if startedByPerson, let run, AgentMessage.redraw(tree, kept: &UITreeValues.shared.kept, in: &run.transcript) {
        return true
      }
      var facts: AssistantDesk.Facts = desk.facts[thread] ?? AssistantDesk.Facts()
      facts.view = tree
      desk.facts[thread] = facts
      return false
    }
    var message = AgentMessage(role: "assistant", text: "", notice: true)
    message.view = tree
    post(message, into: thread)
    return false
  }
  /// The person's turn on `run` ended and is not held for a usage limit: the press that started
  /// it, if one did, is done (`UITreeKept.answered`). A held turn keeps it for when it goes again.
  func pressAnswered(_ run: AgentRun) {
    guard let asked = run.transcript.last(where: { $0.role == "you" })?.text else { return }
    UITreeValues.shared.kept.answered(asked, among: Set(run.transcript.map(\.id)))
  }
  /// Writes `message` at the end of `thread` now, or once no run works there. A chat that does
  /// not exist yet is `owner`'s new Main chat.
  func post(_ message: AgentMessage, into thread: String, owner: RelayProfile? = nil) {
    let chatOwner: RelayProfile? = assistantOwning(thread: thread).map { profile(id: $0) }
    let speaker: RelayProfile? = owner ?? chatOwner ?? team.active
    let title: String = speaker?.name ?? RelayTeam.mainName
    let provider: Provider = assistantEngine(speaker).provider
    if agent.postHostMessage(message, into: thread, title: title, provider: provider) { return }
    // Only a busy chat waits; a save that failed set the error and does not repeat.
    guard agent.hub.run(for: thread) != nil else { return }
    desk.posts.append(AssistantDesk.Post(thread: thread, message: message, title: title, provider: provider))
  }
  /// The host messages whose chat is idle now go in, and so do routine cards' answers.
  func flushHostPosts() {
    if !desk.offerStates.isEmpty { flushOfferStates() }
    guard !desk.posts.isEmpty else { return }
    var left: [AssistantDesk.Post] = []
    for item in desk.posts {
      if agent.hub.run(for: item.thread) != nil {
        left.append(item)
        continue
      }
      agent.postHostMessage(item.message, into: item.thread, title: item.title, provider: item.provider)
    }
    desk.posts = left
  }
  /// The turn on `run`'s chat ended: its receipts and connect offers go under its reply, its
  /// system lines and answers above it, and quick-reply chips leave the reply's words.
  func landTurnFacts(_ run: AgentRun) {
    let thread = run.spec.threadID
    let facts: AssistantDesk.Facts? = desk.facts.removeValue(forKey: thread)
    var plan: PlanCard? = desk.plans.removeValue(forKey: thread)
    plan?.end(now: Date())
    let ended: PlanCard? = plan
    agent.amendThread(thread) { messages in Self.land(facts, plan: ended, in: &messages) }
  }
  /// A burst answered one by one: the tags leave the turn's replies, and each bubble keeps the id
  /// of the message it answers. A tag that names no message of the burst is dropped with its word.
  static func landReplyTags(in messages: inout [AgentMessage]) {
    let start: Int = (messages.lastIndex(where: { $0.role == "you" }) ?? -1) + 1
    let burst: [AgentMessage] = AgentMessage.burst(before: start, in: messages)
    for reply in messages.indices where reply >= start && messages[reply].role == "assistant" {
      let tagged = ChatBubbles.tagged(ChatBubbles.ordered(messages[reply].text, replies: burst.count))
      if tagged.text != messages[reply].text { messages[reply].text = tagged.text }
      // After one message the answer sits right under it: only a burst says which.
      let answers: [String: String] = tagged.tags.reduce(into: [:]) { found, tag in
        if let person = burst.first(where: { $0.burstIndex == tag.value }) { found[String(tag.key)] = person.id }
      }
      if !answers.isEmpty { messages[reply].replies = answers }
    }
  }
  /// Pure placement of one turn's facts in its chat's messages.
  static func land(_ facts: AssistantDesk.Facts?, plan: PlanCard?, in messages: inout [AgentMessage]) {
    if let plan {
      // The ended plan rides on the turn's last message of its own, or a host message.
      let start: Int = (messages.lastIndex(where: { $0.role == "you" }) ?? -1) + 1
      if let i = messages.lastIndex(where: { $0.role == "assistant" && $0.notice != true }), i >= start {
        messages[i].plan = plan
      } else {
        var holder = AgentMessage(role: "assistant", text: "", notice: true)
        holder.plan = plan
        messages.append(holder)
      }
    }
    let start: Int = (messages.lastIndex(where: { $0.role == "you" }) ?? -1) + 1
    var reply: Int? = messages.lastIndex(where: { message in
      message.role == "assistant" && message.notice != true && message.line == nil && message.from == nil
    })
    if let found = reply, found < start { reply = nil }
    if let i = reply {
      let parsed = QuickReplies.parse(messages[i].text)
      if parsed.text != messages[i].text { messages[i].text = parsed.text }
      if !parsed.chips.isEmpty { messages[i].chips = parsed.chips }
    }
    landReplyTags(in: &messages)
    guard let facts, !facts.isEmpty else { return }
    if !facts.receipts.isEmpty || !facts.connect.isEmpty || facts.dashboard != nil || facts.reel != nil || facts.siteID != nil
      || facts.post != nil || facts.view != nil
    {
      let i: Int
      if let found = reply {
        i = found
      } else {
        messages.append(AgentMessage(role: "assistant", text: "", notice: true))
        i = messages.count - 1
        reply = i
      }
      let receipts: [Receipt] = (messages[i].receipts ?? []) + facts.receipts
      messages[i].receipts = receipts.isEmpty ? nil : receipts
      if !facts.connect.isEmpty { messages[i].connect = (messages[i].connect ?? []) + facts.connect }
      if let siteID = facts.siteID { messages[i].siteID = siteID }
      if let dashboard = facts.dashboard { messages[i].dashboard = dashboard }
      if let post = facts.post { messages[i].post = post }
      if let view = facts.view { messages[i].view = view }
      if let reel = facts.reel { messages[i].reel = reel }
      if !facts.receipts.isEmpty, HostFacts.hides(messages[i].text) { messages[i].text = "" }
    }
    guard !facts.above.isEmpty else { return }
    let at: Int = reply ?? messages.count
    messages.insert(contentsOf: facts.above, at: at)
  }

  // MARK: make

  struct MadeAssistant {
    let plan: MakePlan
    let entry: String
    let receipt: Receipt
  }
  /// An assistant's make, as `Staffing.decide` allowed it: at `reach`, with its lineage. The room
  /// that made it records it, for the make budget.
  struct Staffed {
    let reach: Reach
    let lineage: Staffing.Lineage
  }
  /// Makes one assistant from `draft`, journaled (Undo removes it). The receipt, the line and the
  /// apps to connect go to `chat`; an assistant that cannot tell its job from its name finds its
  /// first question, with chips, in its own Main chat. `staffed`: an assistant made it
  /// (`Staffing.make`), else the person did.
  func makeAssistant(_ draft: AssistantDraft, actor: String, chat: String, staffed: Staffed? = nil)
    -> Result<MadeAssistant, AssistantDraft.Problem>
  {
    let person = personPlaces
    func plan(_ team: RelayTeam) -> Result<MakePlan, AssistantDraft.Problem> {
      staffed.map { Staffing.make(draft, reach: $0.reach, lineage: $0.lineage, team: team) } ?? team.making(draft, person: person)
    }
    var made: MakePlan?
    let changed = changeTeam(actor: actor, "Made assistant \(draft.name)") { current in
      guard case .success(let plan) = plan(current) else { return nil }
      made = plan
      return plan.team
    }
    guard changed, let plan = made else {
      if case .failure(let problem) = plan(team) { return .failure(problem) }
      return .failure(.rosterFull)
    }
    if let staffed { rooms.update(staffed.lineage.madeIn) { $0.recordMade(plan.profile.id) } }
    persist(RelayPersona(name: plan.profile.name), team.folder(plan.profile.id) + "/persona.json")
    let entry: String = teamJournal.last?.id.uuidString ?? UUID().uuidString
    desk.undoActions[entry] = .team
    let receipt = plan.receipt(entry: entry)
    let offers = AppSuggestions.offers(name: plan.profile.name, job: plan.job, composioReady: ComposioApps.available)
    let line = staffed == nil ? plan.line : "Made \(plan.profile.name) for this task"
    deliver(receipt: receipt, line: line, connect: offers, into: chat)
    // The host's first message in its own chat (SPEC 2.2), with no model turn.
    if let first = FirstWords.message(name: plan.profile.name, job: plan.job, jobFromName: draft.jobFromName) {
      var message = AgentMessage(role: "assistant", text: first.text, notice: true)
      message.chips = first.chips
      post(message, into: mainThread(of: plan.profile.id), owner: plan.profile)
    }
    return .success(MadeAssistant(plan: plan, entry: entry, receipt: receipt))
  }
  /// New assistant with only a name typed: the person's own words name the make, so it is made
  /// at once. nil when it is made, else the words that say why not.
  func makeAssistant(named name: String) -> String? {
    switch AssistantDraft.parse(["name": name], person: personPlaces, team: team) {
    case .failure(let problem):
      return problem.words
    case .success(let draft):
      switch makeAssistant(draft, actor: "user", chat: threadID) {
      case .success: return nil
      case .failure(let problem): return problem.words
      }
    }
  }

  // MARK: change and pause

  /// Applies one change to an assistant, journaled. A pause holds its routines, watches and links
  /// that are on; turning it on gives them back. The receipt, with Undo.
  func applyChange(_ change: AssistantChange, actor: String) -> Result<Receipt, ChangeRefusal> {
    let person = personScope
    let summary = "Changed assistant \(change.name): \(change.receiptPhrase)"
    let changed = changeTeam(actor: actor, summary) { current in change.applied(to: current, person: person) }
    guard changed else {
      return .failure("Nothing changed: the assistant changed meanwhile, or the new name is taken now.")
    }
    let entry: String = teamJournal.last?.id.uuidString ?? UUID().uuidString
    if change.pause == true {
      let held = holdWork(of: change.id)
      desk.holds[change.id] = (desk.holds[change.id] ?? []) + held
      desk.undoActions[entry] = .paused(change.id)
      stopRunningWork(of: change.id)
    } else if change.pause == false {
      let items: [HeldWork] = desk.holds.removeValue(forKey: change.id) ?? []
      releaseWork(items)
      desk.undoActions[entry] = .resumed(change.id, items)
    } else {
      desk.undoActions[entry] = .team
    }
    saveHolds()
    return .success(ReceiptCopy.changed(name: change.shownName, what: change.receiptPhrase, entry: entry))
  }
  /// Pausing or deleting an assistant stops what it does right now (SPEC 3.2): its routine's run
  /// (in its own chat, or in the chat on screen when it is the active assistant), its answers to
  /// light asks, and the hand-offs it works on. Each ends as a stopped run does.
  func stopRunningWork(of id: String) {
    if let owner = ownerRun, owner.profileID == id, let other = agent.hub.run(for: owner.thread) {
      agent.hub.stop(other)
    }
    let main: String = team.mainProfileID ?? RelayTeam.mainID
    if ownerRun == nil, runsUnattended, (scheduledProfileID ?? main) == id, let current = run {
      agent.hub.stop(current)
    }
    for (thread, ask) in desk.asks where ask.targetID == id && ask.shown == nil {
      if let asked = agent.hub.run(for: thread) { agent.hub.stop(asked) }
    }
    for record in handoffLedger.records where record.state == .running && record.to == id {
      if let handed = agent.hub.run(for: record.threadID) { agent.hub.stop(handed) }
    }
  }
  /// Pauses `id`'s routines, watches and links that are on now; the ones it paused.
  func holdWork(of id: String) -> [HeldWork] {
    var items: [HeldWork] = []
    for reminder in reminders where reminder.profileID == id && reminder.action && !TodoBoard.isReminder(reminder.id) {
      items.append(HeldWork(kind: .routine, id: reminder.id))
    }
    for watch in watches where watch.profileID == id {
      items.append(HeldWork(kind: .watch, id: watch.id))
    }
    for link in desk.links where link.spec.owner == id {
      items.append(HeldWork(kind: .link, id: link.id))
    }
    return pauseWork(items)
  }
  /// Pauses each item that is on now; the ones it paused, so only those come back.
  func pauseWork(_ items: [HeldWork]) -> [HeldWork] {
    var paused: [HeldWork] = []
    for item in items {
      switch item.kind {
      case .routine:
        guard let reminder = reminders.first(where: { $0.id == item.id }), reminder.paused != true else { continue }
        pauseSchedule(reminder)
      case .watch:
        guard let watch = watches.first(where: { $0.id == item.id }), watch.paused != true else { continue }
        pauseWatch(watch)
      case .link:
        guard setLinkPaused(item.id, true) else { continue }
      }
      paused.append(item)
    }
    return paused
  }
  /// Turns on again the items Serein paused, when they are still there and still paused.
  func releaseWork(_ items: [HeldWork]) {
    for item in items {
      switch item.kind {
      case .routine:
        if let reminder = reminders.first(where: { $0.id == item.id }), reminder.paused == true { resumeSchedule(reminder) }
      case .watch:
        if let watch = watches.first(where: { $0.id == item.id }), watch.paused == true { resumeWatch(watch) }
      case .link:
        setLinkPaused(item.id, false)
      }
    }
  }
  /// The ids of paused assistants.
  var pausedAssistants: Set<String> { Set(team.profiles.filter(\.isPaused).map(\.id)) }
  /// An assistant's status in words, for `assistant_list`.
  func statusWords(of profile: RelayProfile) -> String {
    if profile.isPaused { return "Paused" }
    if let asker = answering(profile.id) { return AskLines.answering(asker) }
    let chat: String? = knownMainThread(of: profile.id)
    let replying: Bool = chat.map { agent.hub.run(for: $0) != nil } ?? false
    let tasks: Bool = agent.hub.slotted.contains { childOwners[$0.spec.threadID] == profile.id }
    return replying || tasks ? "Working" : "Ready"
  }
  /// How many notes an assistant keeps in the memory store, as the last read counted them
  /// (`refreshNotes`, RelayMemoryShell.swift): its own records, at most `MemoryStore.recallLimit`.
  func noteCount(of id: String) -> Int {
    memoryCounts[id] ?? 0
  }
  /// The newest roster change that deleted an assistant called `name`, while the journal holds it
  /// ("bring back Old notes").
  func deletedEntry(named name: String) -> String? {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    for record in teamJournal.reversed() {
      guard let before = record.priorTeam, let after = record.nextTeam else { continue }
      let found = before.profiles.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
      guard let gone = found, !after.profiles.contains(where: { $0.id == gone.id }) else { continue }
      return record.id.uuidString
    }
    return nil
  }

  // MARK: delete

  /// What `id` owns that ends with it, for the delete card: its routines, watches and links, and
  /// its open hand-offs.
  func ownedWork(of id: String) -> [DeletePlan.Item] {
    var items: [DeletePlan.Item] = []
    for reminder in reminders where reminder.profileID == id && reminder.action && !TodoBoard.isReminder(reminder.id) {
      items.append(DeletePlan.Item(kind: .routine, id: reminder.id, title: reminder.text, on: reminder.paused != true))
    }
    for watch in watches where watch.profileID == id {
      items.append(DeletePlan.Item(kind: .watch, id: watch.id, title: watch.name, on: watch.paused != true))
    }
    for link in desk.links where link.spec.owner == id {
      items.append(DeletePlan.Item(kind: .link, id: link.id, title: link.spec.name, on: !link.isPaused))
    }
    for record in handoffLedger.records where record.isOpen && (record.to == id || record.from == id) {
      items.append(DeletePlan.Item(kind: .handoff, id: record.id, title: record.task))
    }
    return items
  }
  func deletePlan(for id: String) -> Result<DeletePlan, DeletePlan.Refusal> { team.deleting(id, owned: ownedWork(of: id)) }
  /// Deletes as the card showed: only while the roster is the one the plan was made from. Its
  /// work that was on pauses, its hand-offs end, its files wait in relay/removed. The receipt
  /// carries the toast and a 10-second Undo; nil when nothing was deleted.
  func applyDelete(_ plan: DeletePlan, actor: String) -> Receipt? {
    guard team == plan.undo.before else { return nil }
    let paused = pauseWork(HeldWork.from(plan.ends))
    let done = changeTeam(actor: actor, "Deleted assistant \(plan.profile.name)") { _ in plan.team }
    guard done else {
      releaseWork(paused)
      return nil
    }
    stopRunningWork(of: plan.profile.id)
    endHandoffs(involving: plan.profile.id)
    let entry: String = teamJournal.last?.id.uuidString ?? UUID().uuidString
    desk.undoActions[entry] = .deleted(name: plan.profile.name, resume: paused)
    return plan.receipt(entry: entry)
  }

  // MARK: the way back

  /// Undoes the change `entry` names, or with nil the newest one made in `chat`. The receipt
  /// that says so, or the words that say why not.
  func revert(entry: String?, chat: String) -> Result<Receipt, ChangeRefusal> {
    let token: UndoToken? = desk.undo.find(entry: entry, thread: chat)
    guard let id = token?.entry ?? entry else { return .failure("There is nothing to undo in this chat.") }
    // A reminder or routine Serein saved: its schedule change goes back (RelayMemoryShell.swift).
    if id.hasPrefix(Self.scheduleUndoPrefix) {
      let raw = String(id.dropFirst(Self.scheduleUndoPrefix.count))
      guard let changeID = UUID(uuidString: raw), let change = scheduleChanges.first(where: { $0.id == changeID }) else {
        return .failure("That change can no longer be undone.")
      }
      undoSchedule(change)
      desk.undo.remove(id)
      return .success(ReceiptCopy.undone())
    }
    // A setting changed from the chat goes back while it still reads what the change wrote.
    if id.hasPrefix(ChatSettings.undoPrefix) { return undoSetting(id) }
    // A memory change goes back off the main thread (`revertMemory`).
    if id.hasPrefix(Self.memoryUndoPrefix) { return .failure("That note changes back on its own path.") }
    // "Stop suggesting routines" goes back: suggestions are on again.
    if id == Self.offersUndoEntry {
      desk.undo.remove(id)
      suggestsRoutines = true
      return .success(ReceiptCopy.undone())
    }
    // The move to Allow all goes back to the level before, unless the level changed since.
    if id == AllowAllMigration.undoEntry {
      desk.undo.remove(id)
      guard level == .proactive, let before = AllowAllMigration.previous(GateSettings.shared), before != .proactive else {
        return .failure("The level changed since. Say how much Serein should ask.")
      }
      setLevel(before)
      return .success(ReceiptCopy.undone())
    }
    let action: AssistantDesk.Undo? = desk.undoActions[id]
    if case .link(let linkID)? = action {
      desk.undo.remove(id)
      desk.undoActions[id] = nil
      guard removeOwnedLink(linkID) != nil else { return .failure("That link is gone already.") }
      return .success(ReceiptCopy.undone())
    }
    if case .unlink(let linkID)? = action {
      desk.undo.remove(id)
      desk.undoActions[id] = nil
      guard restoreRemovedLink(linkID) else { return .failure("That link is gone for good. Make it again.") }
      return .success(ReceiptCopy.undone())
    }
    if case .board(let card, let column, let task)? = action {
      desk.undo.remove(id)
      desk.undoActions[id] = nil
      do { try TodoBook.shared.moveBack(card, to: column, task: task) } catch {
        return .failure(ChangeRefusal(error.localizedDescription))
      }
      return .success(ReceiptCopy.undone())
    }
    guard let record = teamJournal.last(where: { $0.id.uuidString == id }), let before = record.priorTeam,
      let after = record.nextTeam
    else { return .failure("That change can no longer be undone.") }
    guard let restored = team.undoingChange(before: before, after: after) else {
      return .failure("Something changed since, or that assistant is on screen. Undo the newer change first, or switch to another assistant.")
    }
    let removed: Set<String> = Set(team.profiles.map(\.id)).subtracting(restored.profiles.map(\.id))
    guard changeTeam(actor: "user", "Undid: " + record.text, { _ in restored }) else {
      return .failure("It is already back the way it was.")
    }
    for gone in removed { endHandoffs(involving: gone) }
    desk.undo.remove(id)
    desk.undoActions[id] = nil
    var receipt = ReceiptCopy.undone()
    switch action {
    case .paused(let profileID)?:
      releaseWork(desk.holds.removeValue(forKey: profileID) ?? [])
    case .resumed(let profileID, let items)?:
      let held = pauseWork(items)
      desk.holds[profileID] = (desk.holds[profileID] ?? []) + held
    case .deleted(let name, let resume)?:
      releaseWork(resume)
      receipt = ReceiptCopy.restored(name: name)
    case .team?, .link?, .unlink?, .board?, nil:
      break
    }
    saveHolds()
    return .success(receipt)
  }
  /// Undo, pressed on a receipt or on its toast: the change goes back and the chat says so. A
  /// memory change goes back off the main thread; the chat says so when it has.
  @discardableResult func undoReceipt(_ token: UndoToken) -> Bool {
    if token.entry.hasPrefix(Self.memoryUndoPrefix) {
      let chat = threadID
      Task { [weak self] in
        guard let self else { return }
        switch await self.revertMemory(token) {
        case .success(let receipt): self.deliver(receipt: receipt, into: chat)
        case .failure(let refusal): self.lastError = refusal.words
        }
      }
      return true
    }
    switch revert(entry: token.entry, chat: threadID) {
    case .success(let receipt):
      deliver(receipt: receipt, into: threadID)
      return true
    case .failure(let refusal):
      lastError = refusal.words
      return false
    }
  }

  // MARK: unread

  /// A reply or a routine's result landed in `profileID`'s chat `thread`: the row shows it unread
  /// unless that chat is the one on screen and the window shows it (`AssistantRowState`).
  func noteReplyLanded(profileID: String, thread: String) {
    let onScreen: Bool = thread == threadID && chatOnScreen()
    AssistantRowState.shared.replyLanded(profileID: profileID, chatOnScreen: onScreen)
  }
  /// The run left words in its chat: not stopped, not empty, and not a quiet "nothing" reply.
  static func landsWords(_ run: AgentRun) -> Bool {
    guard run.record.outcome != .stopped else { return false }
    let last: AgentMessage? = run.transcript.last(where: { $0.role == "assistant" })
    let reply: String = last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !reply.isEmpty, !RelayProactive.isNothing(reply) else { return false }
    if case .quiet = RelayUnattended.interpret(reply: reply, failed: false) { return false }
    return true
  }

  // MARK: apps to connect

  /// The known apps a routine's words name that are not connected yet, as connect links.
  func missingApps(in text: String) -> [ConnectLink] {
    let accounts: [ConnectedApps.Account] = ComposioApps.available ? ComposioApps.shared.accounts : []
    let ready: Set<String> = Set(accounts.filter { $0.active }.map { $0.app })
    return ConnectCatalog.named(in: text).filter { !ready.contains($0.app) }
  }
  /// Whether a Composio app has a ready account now.
  func appConnected(_ slug: String) -> Bool {
    ComposioApps.available && ComposioApps.shared.accounts.contains { $0.app == slug && $0.active }
  }

  // MARK: every 15 seconds

  func sweepAssistantWork(now: Date = Date()) {
    flushHostPosts()
    sweepAsks(now: now)
    purgeRemovedLinks(now: now)
    // A plan with no move for 5 minutes folds while its turn runs (SPEC 2.6).
    for (thread, plan) in desk.plans where plan.idle(now: now) {
      var folded = plan
      folded.end(now: now)
      desk.plans[thread] = folded
    }
  }
}

// MARK: - The tools

extension RelayToolHost {
  /// `assistant_list`: name, job and places of every assistant. It reads, so any turn may.
  func listAssistants() -> [String: Any] {
    let team = relay.team
    let entries = AssistantRoster.entries(team, person: relay.personScope)
    var listing = AssistantRoster.listing(entries)
    // Status words and counts only (SPEC 5.1): never a note, a chat or an instruction.
    for (i, profile) in team.profiles.enumerated() where listing.indices.contains(i) {
      listing[i]["status"] = relay.statusWords(of: profile)
      listing[i]["routines"] = relay.ownedWork(of: profile.id).filter { $0.kind != .handoff }.count
      listing[i]["notes"] = relay.noteCount(of: profile.id)
    }
    return ["assistants": listing]
  }

  /// `assistant_make`: made at once when `Staffing.decide` allows it, with its receipt and Undo in
  /// this chat, and counted against this task's make budget. A refusal is the sentence the model
  /// follows, never a card (owner, 2026-11-25).
  func makeAssistant(_ a: [String: Any]) async throws -> [String: Any] {
    if let job = a["job"] as? String, let why = SavedText.problem(job) { throw SereinError.invalid(why) }
    let draft: AssistantDraft
    switch AssistantDraft.parse(a, person: relay.personPlaces, team: relay.team) {
    case .success(let parsed): draft = parsed
    case .failure(let problem): throw SereinError.invalid(problem.words)
    }
    let maker = relay.profile(id: relay.turnProfileID)
    let chat = relay.threadID
    let staffed = relay.staff(.newAssistant(draft), sender: maker, parent: nil, chat: chat, readOutside: frame.readOutside)
    guard case .make(let reach, let lineage) = staffed.verdict else { return Self.staffingRefusal(staffed.verdict) }
    switch relay.makeAssistant(draft, actor: "relay", chat: chat, staffed: .init(reach: reach, lineage: lineage)) {
    case .failure(let problem):
      throw SereinError.invalid(problem.words)
    case .success(let outcome):
      let places: Set<AssistantPlace> = outcome.plan.profile.scope?.destinations ?? []
      var out: [String: Any] = [
        "made": outcome.plan.profile.name, "can_use": AssistantPlace.words(places), "undo": outcome.entry,
        "note": HostFacts.receiptNote,
      ]
      if outcome.plan.asksFirst { out["first_question"] = "It asks the person what it should do when they open its chat." }
      let leftOut = draft.dropped + reach.dropped(from: AssistantScope(destinations: draft.places))
      if !leftOut.isEmpty { out["left_out"] = leftOut }
      return out
    }
  }

  /// `assistant_change`. Narrowing, a new name or job and a pause apply from the person's own
  /// turn; letting it do more asks on a card (`sheet-permission`), or at Allow all applies with the
  /// receipt's Undo; other turns are refused.
  func changeAssistant(_ a: [String: Any]) async throws -> [String: Any] {
    if let job = a["job"] as? String, let why = SavedText.problem(job) { throw SereinError.invalid(why) }
    let actingID: String = relay.actingProfile?.id ?? relay.team.activeID
    let parsed = AssistantChange.parse(
      a, actingID: actingID, team: relay.team, person: relay.personScope, global: relay.proactiveLevel)
    let change: AssistantChange
    switch parsed {
    case .success(let found): change = found
    case .failure(let problem): throw SereinError.invalid(problem.words)
    }
    let shown = relay.team
    // New words for an assistant apply at once only when the person's own words name it (safety
    // review 7): else a card, so a page cannot write another assistant's instructions.
    let named: Bool = ScheduleRequest.wordsName(change.name, in: frame.typedWords)
    let verdict = change.verdict(turn: frame.admission, wordsNameIt: named)
    switch Admission.atLevel(verdict, turn: frame.admission, level: relay.level) {
    case .refuse(let why):
      throw SereinError.invalid(why)
    case .apply:
      break
    case .ask:
      let effect: ApprovalGate.Effect = change.widens ? .widening : .settings
      let human = await relay.confirmAnswer(
        change.cardTitle, change.cardDetail, button: AssistantChange.allow, decline: AssistantChange.keep,
        thread: relay.threadID, effect: effect)
      guard human == .yes else {
        throw SereinError.invalid(human == .no ? "The person said not now. Nothing changed." : ActionAdmission.needsPerson)
      }
      guard relay.team == shown else {
        throw SereinError.invalid("The assistants changed while the card waited, so nothing changed. Ask again.")
      }
    }
    switch relay.applyChange(change, actor: "relay") {
    case .failure(let refusal):
      throw SereinError.invalid(refusal.words)
    case .success(let receipt):
      relay.deliver(receipt: receipt, into: relay.threadID)
      var out: [String: Any] = ["changed": change.shownName, "undo": receipt.undo?.entry ?? "", "note": HostFacts.receiptNote]
      if !change.dropped.isEmpty { out["left_out"] = change.dropped }
      return out
    }
  }

  /// `assistant_delete`: a card (`sheet-destructive-confirm`) that says what ends with it, then the
  /// toast with a 10-second Undo. At Allow all the person's own turn archives it with no card: its
  /// files wait in relay/removed and the receipt's Undo brings it back while the roster's history
  /// holds the change. Nobody there refuses.
  func deleteAssistant(_ a: [String: Any]) async throws -> [String: Any] {
    let raw: String = (a["name"] as? String) ?? (a["assistant"] as? String) ?? ""
    var wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if wanted.hasPrefix("@") { wanted = String(wanted.dropFirst()).trimmingCharacters(in: .whitespaces) }
    guard let target = relay.team.profile(named: wanted) else {
      throw SereinError.invalid(DeletePlan.Refusal.unknown.words)
    }
    let verdict = Admission.atLevel(
      Admission.decide(.deleteAssistant, turn: frame.admission, wordsNameIt: true), turn: frame.admission, level: relay.level)
    if case .refuse(let why) = verdict { throw SereinError.invalid(why) }
    let plan: DeletePlan
    switch relay.deletePlan(for: target.id) {
    case .success(let found): plan = found
    case .failure(let refusal): throw SereinError.invalid(refusal.words)
    }
    let archives = verdict == .apply && relay.level == .proactive
    if !archives {
      let human = await relay.confirmAnswer(
        plan.title, plan.detail, button: DeletePlan.confirm, decline: DeletePlan.keep, thread: relay.threadID, effect: .delete)
      guard human == .yes else {
        throw SereinError.invalid(human == .no ? "The person kept \(target.name). Nothing was deleted." : ActionAdmission.needsPerson)
      }
    }
    guard let deleted = relay.applyDelete(plan, actor: "relay") else {
      throw SereinError.invalid("The assistants changed while the card waited, so nothing was deleted. Ask again.")
    }
    let entry = deleted.undo?.entry ?? ""
    let receipt = archives ? ReceiptCopy.archived(name: target.name, entry: entry) : deleted
    relay.deliver(receipt: receipt, into: relay.threadID)
    let way = archives ? "The person can bring it back with Undo on the receipt, or by asking. " : "The person can undo it for 10 seconds on the toast, or by asking. "
    return [archives ? "archived" : "deleted": target.name, "undo": entry, "note": way + HostFacts.receiptNote]
  }

  /// `plan`: draws or moves this turn's plan card (SPEC 2.6). It changes nothing, so any turn may.
  func updatePlan(_ a: [String: Any]) throws -> [String: Any] {
    // The chat whose turn runs: a routine's owner chat while it runs there.
    let thread = frame.thread
    switch PlanCard.parse(a, previous: relay.desk.plans[thread], now: Date()) {
    case .failure(let problem):
      throw SereinError.invalid(problem.words)
    case .success(let card):
      relay.desk.plans[thread] = card
      let running: Int = card.current.map { $0 + 1 } ?? 0
      return ["shown": true, "steps": card.steps.count, "now": running]
    }
  }

  /// `post_draft`: a post for X (or a thread) under this turn's reply, drawn as it will look.
  /// Nothing is posted; a post over X's limit comes back to the model to shorten.
  func draftPost(_ a: [String: Any]) throws -> [String: Any] {
    guard let draft = PostDraft.parse(a) else { throw SereinError.invalid("posts: give the post's words, one string per post.") }
    relay.showPost(draft, into: frame.thread)
    var out: [String: Any] = ["shown": draft.posts.count, "note": "The person sees the draft under your reply, with Copy and Open in X. Nothing was posted."]
    let over = draft.over
    if !over.isEmpty {
      out["too_long"] = over.map { "Post \($0.number) is \($0.count) of \(PostDraft.limit) characters." }.joined(separator: " ")
        + " Shorten it and call post_draft again."
    }
    return out
  }

  /// `ui_show`: a view under this turn's reply, drawn from the model's tree of blocks
  /// (`UITree`). A tree that breaks a limit draws nothing and goes back as a plain problem to fix.
  /// Drawing it saves and changes nothing, so it leaves no receipt; a pressed button is the
  /// person's next message (`UITree.message`), handled like any other.
  func showView(_ a: [String: Any]) throws -> [String: Any] {
    switch UITree.parse(a) {
    case .failure(let problem): throw SereinError.invalid(problem.words)
    case .success(let tree):
      let replaced: Bool = relay.showView(tree, into: frame.thread)
      // A redrawn view sits above the person's message, so the reply says what changed.
      let place: String = replaced
        ? "It takes the place of the view the person pressed. Say in one short line what changed."
        : "The person sees it under your reply."
      return ["shown": true, "replaced": replaced, "blocks": tree.count, "note": place + " Do not repeat it in words. A button they press arrives as their next message."]
    }
  }

  /// `dashboard_make`: a dashboard card on this turn's reply (SPEC 2.9), built from the model's
  /// words by `DashboardDraft` (one line each, cut to the spec's limits, then validated), with the
  /// receipt `ReceiptCopy.dashboard`. Only the person's own turn makes one ("make a dashboard of
  /// the trip", "update the trip dashboard"). Made in a chat with the personal-read mark, it keeps
  /// the mark.
  func makeDashboard(_ a: [String: Any]) throws -> [String: Any] {
    guard frame.byPerson else { throw SereinError.invalid(Self.dashboardNotHere) }
    let built: DashboardDraft.Built
    switch DashboardDraft.parse(a, team: relay.team, actingID: relay.turnProfileID) {
    case .success(let value): built = value
    case .failure(let problem): throw SereinError.invalid(problem.words)
    }
    var spec = built.spec
    let thread = frame.thread
    if relay.agent.readsPersonal(thread: thread) { spec.personal = true }
    let site = try SiteBook.shared.dashboard(spec)
    relay.showDashboard(spec, into: thread)
    relay.showSite(site.id, into: thread)
    relay.deliver(receipt: ReceiptCopy.dashboard(title: spec.title), into: thread)
    relay.note("Made the dashboard “\(String(spec.title.prefix(60)))”", .auto)
    var out: [String: Any] = ["shown": spec.title, "site_id": site.id, "saved_to_sites": true, "note": HostFacts.receiptNote]
    if built.leftOut > 0 {
      out["left_out"] = "\(built.leftOut) more did not fit: a dashboard shows 1 big number and \(DashboardSpec.maxRows) rows."
    }
    return out
  }
  static let dashboardNotHere = "Make a dashboard only when the person asks for one in their chat."

  /// `connect_app {app}`: the person's request needs an app that is not connected. The host finds
  /// it in the catalogue (`ConnectCatalog.resolve`) and puts the connect pill under this reply
  /// (`deliver` with `connect`), or the card that turns on an app of this Mac (`noteNeed`). Only
  /// the person's own turn shows one (SPEC 5.4). The model reads one sentence back, never a key,
  /// an address or an account.
  func connectApp(_ a: [String: Any]) throws -> [String: Any] {
    guard frame.byPerson else { throw SereinError.invalid(ConnectCatalog.notHere) }
    let raw: String = (a["app"] as? String) ?? ""
    let thread = frame.thread
    // A cloud computer's key goes in the key card under the reply, straight to Keychain.
    if let link = ConnectLink(app: raw, kind: .key), let account = HostedAccount.forKey(link) {
      if account.hasKey { return ["note": ConnectCatalog.ready(link.name)] }
      let shown: [ConnectLink] = relay.desk.facts[thread]?.connect ?? []
      if !shown.contains(link) { relay.deliver(receipt: nil, connect: [link], into: thread) }
      return ["note": ConnectCatalog.keyShown(link.name)]
    }
    // An app with its own MCP server connects in one click (ConnectorCatalog): a browser sign-in,
    // or a token the person pastes in its own sheet, never in the chat. A token app gives way to
    // Composio while Composio is on, and a Composio app always does (`offeredInChat`).
    if let connector = ConnectorCatalog.find(raw), OneClickConnect.shared.offeredInChat(connector),
      let link = ConnectLink(app: connector.id, kind: .mcp)
    {
      if OneClickConnect.shared.isConnected(connector) { return ["note": ConnectCatalog.ready(connector.name)] }
      let shown: [ConnectLink] = relay.desk.facts[thread]?.connect ?? []
      if !shown.contains(link) { relay.deliver(receipt: nil, connect: [link], into: thread) }
      return ["note": ConnectCatalog.shown(connector.name)]
    }
    // Gmail and Google Calendar reach the person through the Mac's Mail and Calendar.
    let fallback = ConnectorCatalog.macFallback[ConnectorCatalog.normalized(raw)].flatMap { ConnectCatalog.resolve($0) }
    guard let found = fallback ?? ConnectCatalog.resolve(raw) else { throw SereinError.invalid(ConnectCatalog.unknown) }
    switch found {
    case .mac(let id):
      guard let need = Self.macNeed(id) else { throw SereinError.invalid(ConnectCatalog.unknown) }
      if Self.macOn(id) { return ["note": ConnectCatalog.ready(need.name)] }
      relay.noteNeed(need, thread: thread)
      return ["note": ConnectCatalog.shown(need.name)]
    case .composio(let link):
      if relay.appConnected(link.app) { return ["note": ConnectCatalog.ready(link.name)] }
      let shown: [ConnectLink] = relay.desk.facts[thread]?.connect ?? []
      if !shown.contains(link) { relay.deliver(receipt: nil, connect: [link], into: thread) }
      return ["note": ConnectCatalog.shown(link.name)]
    }
  }
  /// The card for an app on this Mac, by its id (`ConnectCatalog.macApps`).
  static func macNeed(_ id: String) -> ConnectNeed? {
    if let connection = Connection(rawValue: id) { return .connection(connection) }
    if let native = NativeConnection(rawValue: id) { return .native(native, macOS: false) }
    return nil
  }
  /// Whether an app on this Mac is turned on in Settings.
  static func macOn(_ id: String) -> Bool {
    if let connection = Connection(rawValue: id) { return Connections.isOn(connection) }
    if let native = NativeConnection(rawValue: id) { return native.isOn() }
    return false
  }

  /// `undo`: the last change made in this chat, or the one `token` names. Only the person's own
  /// turn may undo.
  func undoChange(_ a: [String: Any]) async throws -> [String: Any] {
    if case .refuse(let why) = Admission.decide(.undo, turn: frame.admission, wordsNameIt: true) {
      throw SereinError.invalid(why)
    }
    let token = (a["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var entry: String? = token.isEmpty ? nil : token
    let deleted = (a["assistant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if entry == nil, !deleted.isEmpty {
      guard let found = relay.deletedEntry(named: deleted) else {
        throw SereinError.invalid("No deleted assistant called \(String(deleted.prefix(40))) can come back now.")
      }
      entry = found
    }
    // A memory change goes back off the main thread (RelayMemoryShell.swift).
    if let token = relay.desk.undo.find(entry: entry, thread: relay.threadID),
      token.entry.hasPrefix(RelayOrchestrator.memoryUndoPrefix)
    {
      switch await relay.revertMemory(token) {
      case .failure(let refusal):
        throw SereinError.invalid(refusal.words)
      case .success(let receipt):
        relay.deliver(receipt: receipt, into: relay.threadID)
        return ["undone": true, "note": HostFacts.receiptNote]
      }
    }
    switch relay.revert(entry: entry, chat: relay.threadID) {
    case .failure(let refusal):
      throw SereinError.invalid(refusal.words)
    case .success(let receipt):
      relay.deliver(receipt: receipt, into: relay.threadID)
      return ["undone": true, "note": HostFacts.receiptNote]
    }
  }
}
