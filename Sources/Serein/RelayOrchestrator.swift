import AppKit
import Combine
import CoreGraphics
import SereinCore

/// Relay, the assistant summoned from anywhere (RelayPanel). Its Main chat is one Serein thread
/// whose turns run as Anywhere runs of the chosen harness with Relay's tools (RelayToolHost), so
/// every harness policy, file guard, capability and history record applies to it unchanged.
///
/// Autopilot (off by default, confirmed once) lets Relay act without "Allow once" for steps that
/// RelayAutonomy judges ordinary. Password fields, password managers and Serein itself stay out
/// of reach; sending, deleting, paying and Full access still ask. A scheduled run never uses
/// Autopilot. The kill switch stops Relay, every run it started, and its scheduled requests.
@MainActor final class RelayOrchestrator: ObservableObject {
  static private(set) var shared: RelayOrchestrator?
  /// A Relay turn may wait on its delegated runs; the idle limit still ends a stuck CLI.
  static let limits = RunLimits(hard: 60 * 60, idle: 10 * 60)

  struct State: Codable {
    var threadID = UUID().uuidString
    /// Threads Relay started, newest last, with the access each was given.
    var children: [Child] = []
    var paused = false
    /// The last memory tidy pass, so it runs about once a day.
    var lastTidied: Date?
    /// Serein's earlier chats, oldest first, from before it kept one conversation (History reads
    /// them; none becomes the conversation again). Optional, so a
    /// state.json written before it decodes and keeps the current chat.
    var pastThreadIDs: [String]?
  }
  struct Child: Codable, Equatable {
    var threadID: String
    var edits: Bool
    var startedAt: Date
    /// The chat of Serein's that started it, where its card stays. Optional, so a state.json
    /// written before it decodes (those tasks show in the strip only).
    var chatID: String?
    /// The message that started Serein's turn which started it: its card sits after that turn.
    /// Optional, like `chatID`; a card without it sits above the chat's messages.
    var messageID: String?
    /// Serein started it, and last sent it new work, in a turn the person started: only then may a
    /// standing yes (RoutineGrants) answer its routine steps. Optional, so older state decodes
    /// (nil: never).
    var byPerson: Bool? = nil
  }
  /// A question Relay's tools put to the user, answered in Serein's chat (or an alert when it is
  /// not on screen). The title says exactly what will happen; the detail what follows from it.
  struct Approval: Identifiable {
    struct GrantOffer {
      let site: String
      let forTask: () -> Void
      let always: () -> Void
      /// The lasting choice in other words than a site's routine steps ("Always allow reads from
      /// Notion"), with its help; nil keeps the site's words.
      var alwaysTitle: String? = nil
      var alwaysHelp: String? = nil
      /// False leaves "For this task" out: the offer is only once or always.
      var offersTask = true
    }
    var id = UUID()
    let title: String
    let detail: String
    /// Allow or Start.
    let button: String
    /// The negative answer's words: Decline, or what the card offers instead (Stay).
    var decline = "Decline"
    /// The thread of the run that asked: Serein's own chat or a task it started.
    let threadID: String?
    /// The exact script, under “Show the script” (or a plugin's arguments, under “Show the
    /// details”: `moreName` names which).
    var more: String? = nil
    var moreName = "the script"
    /// Shown open, not behind “Show”: a page tool's exact arguments are part of the question.
    var moreOpen = false
    /// The Mac app a script reaches, for the card's Automation line.
    var app: String? = nil
    /// The site a page step acts on (the brief's Waiting on you).
    var site: String? = nil
    var automation: AutomationState? = nil
    /// False when `automation` is only what Serein remembers (macOS cannot say while the app is
    /// closed): a remembered denial still offers Allow.
    var automationLive = true
    /// A screenshot with the spot marked (click_point): part of the question, shown on the card.
    var picture: NSImage? = nil
    /// When the card was shown, and when it was reminded. A day with no answer is a no. A deferred
    /// card rebuilt after a relaunch keeps the time it was first asked.
    var askedAt = Date()
    var remindedAt: Date?
    /// The effect the gate judged, when the asker knows it: only a voice-eligible one can be
    /// allowed by voice in a call (nil needs a click).
    var effect: ApprovalGate.Effect? = nil
    /// A proposed team (team_propose, Describe it, Import file): the card lists every member and
    /// its instructions, and Change… edits the draft before Create team answers.
    var proposal: TeamProposalDraft? = nil
    /// A routine step's standing yeses (RoutineGrants): Allow for this task and Always on the site,
    /// each recorded, then answered yes. nil for every hard stop.
    var grants: GrantOffer? = nil
    /// Asked only because Serein asks before every step: Only risky steps would have let it go
    /// ahead, so the card offers that switch in place (with its confirmation).
    var routine = false
    /// Serein asks about itself (which AI app it thinks with), not a step of work: the brief's
    /// “Waiting on you” leaves it out, since the card already shows where it was asked.
    var aboutSerein = false
    /// A person step's card (PersonStep): it holds no call, and it moves with its task (R12).
    var personStep = false
    let answer: (ApprovalGate.HumanAnswer) -> Void
  }
  /// The team a proposal card holds, which Change… may edit before the card is answered; the
  /// roster it was shown for, so the answer still holds only for that roster.
  final class TeamProposalDraft {
    var proposal: TeamProposal
    let shown: RelayTeam
    /// Import file: the card's words and the quiet-start note.
    let imported: Bool
    init(proposal: TeamProposal, shown: RelayTeam, imported: Bool = false) {
      self.proposal = proposal
      self.shown = shown
      self.imported = imported
    }
  }
  /// An approval once answered: the card collapses to one line.
  struct AnsweredApproval: Identifiable, Equatable {
    let id: UUID
    let title: String
    let allowed: Bool
    let at: Date
    let threadID: String?
    /// Answered by voice in a call: the line says so.
    var byVoice = false
  }
  /// A form Relay asked for mid-turn (ask_user): answered in the panel, or it times out and
  /// Relay carries on.
  struct QuestionForm: Identifiable {
    let id = UUID()
    let title: String
    let questions: [RelayQuestion]
    /// The person's message that started the turn, and its chat: where the answered form shows.
    var after: String? = nil
    var threadID: String? = nil
    /// When it was asked: the dock above the composer shows asks oldest first.
    var askedAt = Date()
    /// The user's answers, or nil when the wait timed out.
    let answer: ([String: String]?) -> Void
  }
  /// A form the person answered, shown in the chat as one small chip per answer after the
  /// message that started its turn (this launch only, as answered approvals are).
  struct AnsweredQuestion: Identifiable, Equatable {
    /// One question and what the person said; nil when they skipped it.
    struct Item: Equatable {
      let question: String
      let answer: String?
      /// The choices it offered, so a chip can change the answer from the same list.
      var choices: [String] = []
    }
    let id: UUID
    let items: [Item]
    let at: Date
    let threadID: String?
    let after: String?
    /// The person's side in words, for VoiceOver (RelayAsk.summary).
    var summary: String {
      let said = items.compactMap { item in item.answer.map { "\(item.question): \($0)" } }
      return said.isEmpty ? "Skipped" : said.joined(separator: ". ")
    }
  }

  @Published private(set) var state: State
  /// A visible empty chat can say hello independently of background check-ins. Its dedicated
  /// tool-free helper never occupies a task slot or blocks a person's first message.
  @Published private(set) var welcoming = false
  private let welcome = SereinWelcome()
  /// The active assistant's notes as Settings lists them, newest last: a read of the shared
  /// memory store (`refreshNotes`, RelayMemoryShell.swift). Set only there and by `updateNotes`.
  @Published var notes: [RelayNote]
  /// Notes waiting for the user's review: the active assistant's learned proposals in the memory
  /// store, then the tidy proposals (`tidyProposals`). Set only by the memory shell.
  @Published var proposals: [RelayNote] = []
  @Published private(set) var reminders: [RelayReminder]
  /// Change-watches: quiet reads on an interval that wake Relay only when the answer changes.
  @Published private(set) var watches: [RelayWatch] = []
  /// Every change to the notes, so the user can undo one (RelayJournal). The memory shell adds
  /// the entries for the changes Serein's tools make.
  @Published var journal: [RelayJournalEntry] = []
  /// Every change to a reminder, scheduled request or alert, so the user can undo one.
  @Published private(set) var scheduleChanges: [RelayScheduleChange] = []
  /// Who Relay is, in the user's own words (Settings › Relay).
  @Published private(set) var persona: RelayPersona = RelayPersona()
  /// The roster of assistants; the active one answers ⌥Space. Schedules, watches and the
  /// user's reminders are shared; persona, thread and notes belong to a profile.
  @Published private(set) var team: RelayTeam = RelayTeam.fresh() {
    didSet {
      if team.activeID != oldValue.activeID || team.active?.route != oldValue.active?.route { cancelWelcome() }
    }
  }
  /// The folder of the active profile's own files.
  var dir: String { team.folder(team.activeID) }
  /// Every change to the roster and its teams, shared by all assistants, so the person can undo
  /// one (relay/team-journal.json).
  @Published private(set) var teamJournal: [RelayJournalEntry] = []
  /// Hand-offs between assistants and their counters (relay/handoffs.json, 0600): the limits live
  /// here, in host state the model cannot edit, and survive a relaunch.
  @Published var handoffLedger = HandoffLedger()
  /// Chats waiting on Accessibility, and those whose grant came (relay/mac-access.json, MacAccessCard.swift).
  @Published var macAccess = MacAccessWait()
  /// While a card waits: the 2-second check and the observer of Serein becoming active.
  var macAccessWatch: Task<Void, Never>?
  var macAccessActive: NSObjectProtocol?
  /// The Main chats a hand-off is being dispatched into right now, so none starts twice.
  var handoffsStarting: Set<String> = []
  /// The assistant each delegated task started under (thread → profile id; "" for a scheduled
  /// turn of the person's own), so its scope holds after a switch. This launch only.
  var childOwners: [String: String] = [:]
  /// The other assistants' Main chats, read once from their state.json for the board
  /// (`knownMainThread`); never written here.
  var mainThreadCache: [String: String] = [:]
  /// The team whose header was clicked last: its lead (or first member) answers ⌥Space, and the
  /// Serein header names the team. Cleared when another assistant is opened on its own.
  @Published var activeTeamID: String? = UserDefaults.standard.string(forKey: RelayOrchestrator.activeTeamKey) {
    didSet {
      if activeTeamID != oldValue { cancelWelcome() }
      Self.setSetting(activeTeamID ?? "", forKey: Self.activeTeamKey)
    }
  }
  static let activeTeamKey = "serein.relay.activeTeam"
  /// The turn now running was started by the person's own message. Anything else (a check-in, a
  /// report, a scheduled request, a webhook, a hand-off result) is the lower trust class: it cannot
  /// create or change assistants or teams, or hand work on (`startedByPerson`).
  private var personTurn = false
  /// The person's own words in the turn now running, as they sent them (`turn`): the admission
  /// rule reads them (`TypedConsent`, through `typedWords`) only while `startedByPerson`.
  private(set) var personWords: String?
  /// What the assistant tools keep for this launch: each chat's receipts and lines, open asks,
  /// owned links, proposals and the way back (RelayAssistantTools.swift, RelayAsks.swift,
  /// RelayLinks.swift).
  private(set) lazy var desk = AssistantDesk()
  private(set) lazy var research = makeResearchCoordinator()
  /// Words typed to each assistant and not sent, by assistant: this launch only (`switchTo`).
  private var drafts: [String: String] = [:]
  /// Messages the user sent while Relay was working; they go with its next turn.
  @Published private(set) var pending: [String] = []
  /// Each chat's first reply the person had not read when it came back on screen: the Unread line
  /// sits above it (`RelayReading.swift`).
  @Published var unreadFrom: [String: String] = [:]
  /// One read mark per chat: the newest reply the person had on screen (`chatRead`).
  var chatReadMarks: [String: String] = [:]
  /// A message Serein could not answer yet (no AI app, or offline), with the chips that rode with
  /// it. It sends by itself when what held it clears within 30 minutes (`HeldMessage`), else it
  /// waits for Send now or Discard. Kept in relay/held.json (its words, time and reason; a chip
  /// that rode with it is not), so a quit or a restart never loses it. A turn the AI app's usage
  /// limit stopped is held here too (`holdLimited`), with its chat and reset time kept as well.
  struct Held: Identifiable, Equatable {
    var message: HeldMessage
    var attachments: [SereinAttachment] = []
    /// The tab the message carried (its page chip), kept with it in memory only.
    var page: SereinPage? = nil
    /// In-memory origin, like the page and attachments. Restored held messages default to false
    /// rather than counting a later automatic retry as a new in-window message.
    var inWindow = false
    /// Paired-app requests are not evidence that the person used Serein.
    var userMessage = true
    /// A usage-limit hold Serein sends by itself, once, at `message.resetsAt` (UsageLimit.plan).
    var waits = false
    /// It was already sent again from a usage-limit hold: met again, it never goes by itself.
    var retried = false
    /// A scheduled run held for the limit: the run is queued again, with its own origin, rather
    /// than sent as a message. In memory only; a quit records it as missed (`missHeldRuns`).
    var scheduled: ScheduledTurn? = nil
    var id: String { message.id }
  }
  /// AI apps whose usage limit stopped a turn, by provider id, until their reset (an hour when
  /// they named none). Serein moves a held chat only to an AI app that is not on this list.
  private(set) var limitedApps: [String: Date] = [:]
  /// Assistants moved off a usage limit, until they go back (`restoreAfterLimit`).
  var limitFailovers = LimitFailovers() {
    didSet { if Self.persists, limitFailovers != oldValue { persist(limitFailovers, Self.limitFailoversFile) } }
  }
  /// Chats whose last turn parked on a secure card: a usage limit there keeps its hold (`noteSecureCard`).
  var cardThreads: Set<String> = []
  /// The reset time each limited AI app named, by provider id; none when it named none.
  private(set) var namedLimitResets: [String: Date] = [:]
  /// What Serein last offered a usage-limit hold (held id to route id; empty when nothing else
  /// could answer, so its row asks to connect another AI app). It offers a hold again only when
  /// something new can answer, so a Stay is never asked twice for the same app.
  @Published private(set) var elsewhereOffered: [String: String] = [:]
  /// AI apps a held message just failed on after a move, by provider id, until this time: the
  /// next move skips them, so a chain of failures never comes back round to the same app.
  private var failedApps: [String: Date] = [:]
  static let failedAppWait: TimeInterval = 10 * 60
  /// How long an AI app counts as limited when its answer named no reset time.
  static let unnamedLimitWait: TimeInterval = 60 * 60
  @Published private(set) var held: [Held] = [] {
    didSet {
      guard held != oldValue else { return }
      if Self.persists { persist(held.filter { $0.scheduled == nil }.map(\.message), "relay/held.json") }
      let ids = Set(held.map(\.id))
      if elsewhereOffered.keys.contains(where: { !ids.contains($0) }) { elsewhereOffered = elsewhereOffered.filter { ids.contains($0.key) } }
      scheduleHeldTick()
      scheduleUsageTick()
    }
  }
  #if DEBUG
  /// Checks hold a message as `holdLimited` does, without a run that met the limit.
  func holdForChecks(_ item: Held) { held.append(item) }
  func limitForChecks(_ provider: Provider, until: Date?) { noteLimited(provider, until: until) }
  #endif
  /// The held messages of the chat on screen: a usage-limit hold stays with its own chat.
  var heldHere: [Held] { held.filter { $0.message.threadID == nil || $0.message.threadID == threadID } }
  /// The AI app a usage-limit hold's chat thinks with, by its saved record (so a restored hold
  /// names it too).
  func limitApp(_ item: Held, now: Date = Date()) -> String {
    // The app whose limit holds it: the one with this reset time, else the one that resets first.
    // The chat's own app can be another by now (a move to an app that then needed a sign-in).
    let live = limitedApps.filter { $0.value > now }
    if let reset = item.message.resetsAt,
      let named = live.first(where: { abs($0.value.timeIntervalSince(reset)) < 1 }) ?? live.min(by: { $0.value < $1.value }) {
      return Provider(rawValue: named.key).name
    }
    return agent.conversations.first { $0.id == item.message.threadID }?.provider.name ?? "Your AI app"
  }
  /// One wake-up at the earliest reset time a usage-limit hold waits for (`continueAtReset`).
  private var usageTick: DispatchWorkItem?
  private func scheduleUsageTick(now: Date = Date()) {
    usageTick?.cancel()
    usageTick = nil

    guard let due = held.filter(\.waits).compactMap(\.message.resetsAt).min() else { return }
    let item = DispatchWorkItem { [weak self] in self?.continueAtReset() }
    usageTick = item
    // Wall time: a reset hours away still lands on time after the Mac slept through it.
    DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, due.timeIntervalSince(now)) + 1, execute: item)
  }
  /// One wake-up at the moment the oldest waiting held message turns 30 minutes old, so its line
  /// turns to “You asked this earlier” and its chip to “Not sent” without any clock running.
  private var heldTick: DispatchWorkItem?
  private func scheduleHeldTick(now: Date = Date()) {
    heldTick?.cancel()
    heldTick = nil
    guard let due = held.map({ $0.message.at.addingTimeInterval(HeldMessage.window) }).filter({ $0 > now }).min() else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.objectWillChange.send()
      self.scheduleHeldTick()
    }
    heldTick = item
    DispatchQueue.main.asyncAfter(deadline: .now() + due.timeIntervalSince(now) + 1, execute: item)
  }
  /// The line after a held message went: “Connected. Answering your message now.” It goes with
  /// the next message.
  @Published var heldNotice: String?
  private var heldWatch: AnyCancellable?
  /// The line after a Stop (F5): the reply stopped while tasks go on, a bare “stop” while idle,
  /// or Stop Everything. It goes with the next message or New chat.
  @Published var stopNotice: RelayStopNotice?
  @Published private(set) var approvals: [Approval] = []
  /// Answered approvals of this chat, shown collapsed until the next message or New chat.
  @Published private(set) var answered: [AnsweredApproval] = []
  /// The one-time “Serein goes ahead with routine steps” card is waiting for its answer.
  @Published private(set) var consentWaiting = false
  /// Steps waiting on that card, each with the thread whose run asked (Serein's chat or a task).
  private var consentWaiters: [(thread: String?, waiter: CheckedContinuation<Bool, Never>, id: UUID)] = []
  /// ask_user forms waiting in the panel.
  @Published private(set) var questionForms: [QuestionForm] = []
  /// Ideas Serein suggested on its own (a check-in's IDEA lines), newest last, six at most, until
  /// done or set aside (this launch).
  @Published private(set) var ideas: [RelayProactive.Idea] = []
  /// Do it: Serein is asked to go ahead; the idea leaves the list. The idea's words were written
  /// by a check-in from what it read (mail, reminders, runs), so they ride with the message as an
  /// attachment, untrusted data, and never as the person's typed words, which can count as their
  /// consent to a change (`typedWords`, TypedConsent). Each step still asks as usual.
  func doIdea(_ idea: RelayProactive.Idea) {
    ideas.removeAll { $0.id == idea.id }
    let from: String = idea.source.map { "\nWhere it came from: " + $0 } ?? ""
    let note = SereinAttachment(title: "Serein's idea", icon: "lightbulb", body: idea.text + from)
    ask("Go ahead with the idea you suggested (attached).", attachments: [note])
  }
  /// Not now: the idea leaves the list.
  func dismissIdea(_ idea: RelayProactive.Idea) { ideas.removeAll { $0.id == idea.id } }
  /// The forms answered this launch, newest last (at most 30).
  @Published private(set) var answeredQuestions: [AnsweredQuestion] = []
  /// Reminders that came due, shown in the panel until dismissed.
  @Published var dueReminders: [RelayReminder] = []
  /// Scheduled runs that came due while the Mac slept, Serein was closed or stopped, or a usage
  /// limit held them, one per schedule, each waiting in Serein's chat (and the ⌥Space bar) for
  /// Run now or Skip. Kept in relay/missed.json, so a quit or restart does not lose one.
  @Published private(set) var missedRuns: [RelayMissedRun] = [] {
    didSet {
      if Self.persists, missedRuns != oldValue { persist(missedRuns.map(\.saved), Self.missedFile) }
    }
  }
  private static let missedFile = "relay/missed.json"
  /// When Stop Everything began holding every request (distant past when Serein launched
  /// stopped); the first tick after Resume reads it to word what came due meanwhile.
  private var stoppedSince: Date?
  /// The Mac waking: the clock looks for missed runs at once rather than at its next step.
  private var wakeWatch: AnyCancellable?
  /// A line under a reminder Serein just set: what happens to it while Serein is closed.
  enum ReminderNotice: Equatable {
    /// A plain reminder, and macOS has not been asked about notifications yet.
    case allowNotifications
    /// A plain reminder, and notifications are off for Serein.
    case notificationsOff
    /// A request (Serein does something then) while nothing keeps Serein running; `when` reads
    /// “at 9:00 AM”.
    case keepRunning(when: String)
    /// The user chose Keep Serein in the menu bar from that line.
    case keptInMenuBar
  }
  @Published var reminderNotice: ReminderNotice?
  /// Plain reminders macOS showed while Serein was closed, with the time each showed: that
  /// occurrence comes due without a second notification.
  private var shownWhileClosed: [String: Date] = [:]
  /// A turn Relay runs on its own: a scheduled request, or a watch that fired. They queue until
  /// Relay is idle and never cut into the user's turns.
  struct ScheduledTurn: Equatable {
    let reminder: RelayReminder
    let initiator: AgentHistoryRun.Initiator
    /// The assistant whose schedule or watch this is: the turn works with its scope. nil is the
    /// person's own (a webhook, a schedule from Settings).
    var profileID: String? = nil
    /// Queued again from a usage-limit hold: met again, it is missed, never held twice.
    var retried = false
    /// Its row in the work ledger (relay/work.sqlite), once written; nil when the ledger is not
    /// open, so the turn queues in memory only, as before the ledger.
    var ledgerID: Int64? = nil
    /// The owned link whose delivery this turn reads (`enqueueLink`); nil for every other turn.
    var linkID: String? = nil
    /// The alert whose change this turn reports: its tokens land on that alert's history.
    var watchID: String? = nil
    /// Its request in the step journal, once it ran: a run queued again (a usage-limit hold, an
    /// interruption) is the same request sent again (`StepJournal`). In memory only.
    var journal: String? = nil
  }
  /// The turns waiting to run, a read of the queued rows of the work ledger (`queueWork`).
  @Published private(set) var scheduledQueue: [ScheduledTurn] = []
  /// The scheduled turn running now.
  private var activeScheduled: ScheduledTurn?
  /// The ledger row of the scheduled turn the person's message stopped (`finishWork` queues it
  /// again once).
  private var interruptedWork: Int64?
  /// Counts turns, so a follow-up is one per turn (RelayFollowUp): `turnSerial` of the turn
  /// that set one.
  private var turnSerial = 0
  private var followedUp: Int?
  /// One-time yeses from deferred cards (RelayDeferred): each answers one exact card once.
  private var oneTimeGrants: [RelayDeferred.Grant] = []
  /// Watches whose check is running right now.
  private var checking: Set<String> = []
  @Published var lastError: String?
  @Published var sending = false
  /// The person's messages on their way to the AI app, with the moment Send was pressed: the chat
  /// shows them and the trail from then, before the run exists. Gone once the turn has started
  /// or could not.
  struct Outgoing: Equatable {
    let threadID: String
    let messages: [AgentMessage]
    let at: Date
  }
  @Published private(set) var outgoing: Outgoing?
  /// The messages on their way in the chat on screen.
  var outgoingHere: Outgoing? { outgoing?.threadID == threadID ? outgoing : nil }
  /// When Send was pressed for the newest turn the person started, by its first message: that
  /// turn's trail counts from the press, not from the run's start a moment later.
  private(set) var sendPressed: (message: String, at: Date)?
  /// Messages a turn that could not start left in the chat: they read "Not sent" until the
  /// person's next message.
  @Published private(set) var unsent: Set<String> = []
  /// An approval, a question or the consent card waits on the person for `thread`'s turn: its
  /// trail stands still until they answer.
  func waitsOnPerson(in thread: String) -> Bool {
    approvals.contains { $0.threadID == nil || $0.threadID == thread }
      || questionForms.contains { $0.threadID == nil || $0.threadID == thread }
      || consentWaiters.contains { $0.thread == nil || $0.thread == thread }
  }
  /// Whether the ⌥Space panel is on screen (the bar; its triage and look previews use this).
  var panelVisible: () -> Bool = { false }
  /// Whether Serein's chat is on screen where the user can answer it: the column is shown, the
  /// app is active, and the main window is key and not covered. Approvals show inline then.
  var chatOnScreen: () -> Bool = { false }
  /// Serein's chat is in an open window, even one behind another app: a card there is seen when
  /// the user comes back. Once neither it nor the ⌥Space bar shows a card, it moves to an alert.
  var chatShown: () -> Bool = { false }
  /// Brings the panel forward (a reminder that came due). Only with ⌥Space on.
  var showPanel: () -> Void = {}
  /// Shows the ⌥Space bar without taking the keyboard, holding the cards that wait (an approval
  /// or a question while Serein is out of view). Allowed with ⌥Space off.
  var showForAnswer: () -> Void = {}
  /// Serein's window is in front and key, though its chat may not be on screen: a card waits in
  /// the chat, the slim line and the row say so, and nothing switches by itself.
  var windowKey: () -> Bool = { false }
  /// The frontmost app's frontmost window covers its screen (a full-screen app): only a
  /// notification, never the bar over it.
  var frontFullScreen: () -> Bool = { false }
  /// Serein's chat is on screen and uncovered, though another app is in front.
  var chatVisible: () -> Bool = { false }
  /// Some screen can show the ⌥Space bar; when none can, the alert is the last resort.
  var screenAvailable: () -> Bool = { !NSScreen.screens.isEmpty }
  /// The Mac is online (`NetworkMonitor`; the offline preview says no).
  var networkOnline: () -> Bool = { SereinSurface.online(NetworkMonitor.shared.online) }
  /// Where a question for the user shows now (`ApprovalPlacement`).
  func answerPlacement() -> ApprovalPlacement {
    ApprovalPlacement.place(chatOnScreen: chatOnScreen(), barShown: panelVisible(), windowKey: windowKey(),
                            frontFullScreen: frontFullScreen(), screenAvailable: screenAvailable(), chatVisible: chatVisible())
  }
  /// Cards and forms the user put off (Later, or the bar put away) or that lost their place: they
  /// wait in Serein's chat, and nothing brings them up again by itself.
  @Published private(set) var deferred: Set<UUID> = []
  /// The waiting cards and forms wait in Serein's chat from now on (Later; the bar put away).
  func deferWaiting() {
    if consentWaiting { consentDeferred = true }
    let ids = Set(approvals.map(\.id)).union(questionForms.map(\.id))
    guard !ids.isSubset(of: deferred) else { return }
    deferred.formUnion(ids)
  }
  /// The one-time card waits in the chat, put off (as `deferred` is for cards and forms).
  private var consentDeferred = false
  /// The one-time card's notification went (once while it waits).
  private var consentNotified = false
  /// Plays a state of the look on the hologram (look_show); true when it is on screen.
  var previewLook: (String, Double) -> Bool = { _, _ in false }

  let agent: AgentModel
  let browser: BrowserModel
  private(set) lazy var tools = RelayToolHost(relay: self)
  private var clock: Task<Void, Never>?
  private var capture: Task<Void, Never>?

  // MARK: shared memory (its logic is in RelayMemoryShell.swift)

  /// Serein's shared memory (relay/memory/memory.sqlite), once it is open. It opens once, off the
  /// main thread (`openMemory`); nil while it opens, in UI previews and when it could not open.
  var memory: OffMain<MemoryStore>?
  /// The open of the memory store, so a tool or a turn waits for it rather than failing.
  var memoryOpening: Task<Void, Never>?
  /// The memory block of the turn being sent (`prepareMemory`): `RelayPrompt.volatile` reads it.
  var turnMemory: String?
  /// The rules in force for the turn being sent (`prepareMemory`, RelayRules.swift): first in `RelayPrompt.volatile`.
  var turnRules: String?
  /// The person's correction for the turn being sent (`Rules.correction`), taken from `corrections`.
  var turnCorrection: String?
  /// Per chat, words the person sent while a turn ran there (`noteCorrection`): the next turn takes them.
  var corrections: [String: String] = [:]
  /// The turn now running brought outside text in (a page, a file, a task's reply, an app's data)
  /// or carried a page or a file: a typed remember then stays with its assistant (`MemoryTurn`).
  var turnReadOutside = false
  /// The chat whose Get to know you turn is running: check-ins are offered there when it ends.
  var checkInsAfterTurn: String?

  #if DEBUG
    /// Every tool Serein's own turns called, in order, for a live check to read.
    var toolsCalledForChecks: [String] = []
  #endif
  /// The personal-read mark of each note the Settings list showed this launch, by id, so a note
  /// that Undo puts back keeps it. A note whose mark is not known is marked.
  var noteMarks: [String: Bool] = [:]
  /// Tidy proposals (RelayTidy), kept in the active profile's proposals.json. Learned proposals
  /// are records in the memory store.
  var tidyProposals: [RelayNote] = []
  /// What the memory shell keeps between launches (relay/memory/shell.json): the move of the old
  /// notes, and each chat's last capture.
  var memoryShell = MemoryShellState()
  /// Each assistant's count of its own notes, from the last read (`refreshNotes`, `noteCount`).
  var memoryCounts: [String: Int] = [:]

  // MARK: the work ledger (relay/work.sqlite, `workFile`)

  /// The work ledger, once it is open and the launch recovery ran (`openWork`, off the main
  /// thread). nil while it opens, in UI previews and when it could not open: then scheduled turns
  /// queue in memory only, as before the ledger.
  private(set) var work: OffMain<WorkLedger>?
  /// The open and the launch recovery, which every run waits for.
  private var workOpening: Task<Void, Never>?
  /// The open finished, or never started (previews): the clock may fire scheduled requests.
  private var workReady = false
  /// Requests whose ledger rows are being written now, so a second Run now waits for the first.
  private var writing: [String] = []
  /// The clock's runs that came due are being written to the ledger: the next tick waits.
  private var writingDue = false
  /// Moves on at each Stop Everything, so a ledger write still landing is dropped, not queued.
  private var workEpoch = 0
  var actionEpoch: Int { workEpoch }
  /// A scheduled turn running in another assistant's Main chat (`drainScheduled`): that chat and
  /// its owner, from its hand-over until it ends. While it is set, Serein's tools answer for that
  /// chat (`turnThread`), and Serein starts no other turn of its own (`working`).
  struct OwnerRun: Equatable {
    let thread: String
    let profileID: String
  }
  @Published private(set) var ownerRun: OwnerRun?
  /// The persona of `ownerRun`'s assistant, read once when its turn starts (RelayPrompt.stable).
  private(set) var ownerPersona: RelayPersona?
  /// Relay state files that did not decode: nothing writes them (`persist`), as To do writes
  /// nothing over an unreadable todo.json (SPEC I13).
  private(set) var unwritable: Set<String> = []

  static let providerKey = "serein.relay.provider"
  static let autopilotKey = "serein.relay.autopilot"
  static let enabledKey = "serein.relay.enabled"
  static let summonKey = "serein.relay.summonKey"
  static let killKey = "serein.relay.killKey"
  /// "Keep Serein in the menu bar when you close this window": the status item and staying alive
  /// after the window closes, without the global shortcuts. Always in effect while ⌥Space is on.
  static let menuBarKey = "serein.assistant.menuBar"
  static var menuBar: Bool {
    get { UserDefaults.standard.bool(forKey: menuBarKey) }
    set { UserDefaults.standard.set(newValue, forKey: menuBarKey) }
  }
  /// UI previews and checks never write the user's settings or library migrations.
  static let persists = !RunMode.automated && !RunMode.stress
  /// Writes a setting the user changed from the window (the column's ×, ⌘J). Under a preview or
  /// a check it changes only the volatile argument domain the preview's defaults live in, so the
  /// view still follows and the user's own settings stay as they are.
  static func setSetting(_ value: Any, forKey key: String) {
    let defaults = UserDefaults.standard
    guard !persists else {
      defaults.set(value, forKey: key)
      return
    }
    var volatile = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    volatile[key] = value
    defaults.setVolatileDomain(volatile, forName: UserDefaults.argumentDomain)
  }
  /// `--ui-serein-ready` (and the seeded `--ui-relay` chat): previews draw Serein as connected to
  /// an AI app without making one available, so a preview still reports no providers.
  static let previewHint: HintID? = {
    guard CommandLine.arguments.contains("--ui-preview"),
      let i = CommandLine.arguments.firstIndex(of: "--ui-hint"), i + 1 < CommandLine.arguments.count else { return nil }
    return HintID(rawValue: CommandLine.arguments[i + 1])
  }()
  static let previewGuide = CommandLine.arguments.drop(while: { $0 != "--ui-guide" }).dropFirst().first
  static let previewReady = CommandLine.arguments.contains("--ui-preview") && previewGuide != "no-ai"
    && (CommandLine.arguments.contains("--ui-serein-ready") || previewHint != nil || previewBarHeld == .offline
      || (previewSeeded && !CommandLine.arguments.contains("--ui-relay-no-ai")))
  /// `--ui-serein-bar-held [offline]`: why the bar's message is held (no AI app unless `offline`,
  /// which draws Serein connected and the Mac offline).
  static let previewBarHeld: HeldMessage.Reason? = {
    let arguments = CommandLine.arguments
    guard arguments.contains("--ui-preview"), arguments.contains("--ui-serein-bar-held") else { return nil }
    return arguments.drop(while: { $0 != "--ui-serein-bar-held" }).dropFirst().first == "offline" ? .offline : .noAI
  }()
  /// Previews that seed Serein's chat: `--ui-relay`, and the quit and close questions, whose
  /// window behind must agree with what they ask.
  static let previewSeeded = CommandLine.arguments.contains("--ui-preview")
    && (["--ui-relay", "--ui-serein-chat", "--ui-serein-quit-guard", "--ui-serein-close-guard", "--ui-serein-paused-by-update",
         "--ui-serein-busy", "--ui-serein-stop-reply", "--ui-serein-notify-card", "--ui-serein-task-cards",
         "--ui-serein-toast", "--ui-serein-direct-needs", "--ui-serein-stop-idle", "--ui-serein-bar-reply", "--ui-hint",
         "--ui-serein-bar-approval", "--ui-serein-waiting", "--ui-serein-offline", "--ui-agents-schedules", "--ui-automations", "--ui-waiting",
         "--ui-serein-automatic", "--ui-question", "--ui-ideas", "--ui-session-status", "--ui-session-report", "--ui-chat-top", "--ui-serein-reply",
         "--ui-decision-dock", "--ui-mac-access-card"]
      .contains { CommandLine.arguments.contains($0) } || previewSide)
  /// The `serein-side` preview: a page with Serein beside it, on a chat already under way.
  static let previewSide = CommandLine.arguments.drop(while: { $0 != "--ui-preview" }).dropFirst().first == "serein-side"
  /// The page chip's previews (on `serein-side`): `--ui-serein-page-chip` (a new chat beside the
  /// page, with the chip and its first-time line), `--ui-serein-page-text` (⌥⌘E's chip with the
  /// page text), `--ui-serein-private` (a private tab: “Private tab · not shared”), and
  /// `--ui-serein-do-here` (“Work in this tab?” waiting). Only in memory.
  static let previewPageChat = CommandLine.arguments.contains("--ui-preview")
    && ["--ui-serein-page-chip", "--ui-serein-page-text", "--ui-serein-private"].contains { CommandLine.arguments.contains($0) }
  static let previewDoHere = CommandLine.arguments.contains("--ui-preview") && CommandLine.arguments.contains("--ui-serein-do-here")

  /// "Ask Serein from any app with ⌥Space": the global shortcuts and the menu bar item. The
  /// assistant itself works in the window whether or not this is on.
  #if DEBUG
  /// Checks turn Relay on here, never in the user's defaults.
  static var enabledOverride: Bool?
  #endif
  static var enabled: Bool {
    get {
      #if DEBUG
      if let enabledOverride { return enabledOverride }
      #endif
      return UserDefaults.standard.bool(forKey: enabledKey)
    }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }
  #if DEBUG
  /// Checks set Autopilot here, never in the user's defaults.
  var autopilotOverride: Bool?
  /// Checks set the check-in level and note suggestions here.
  var proactiveOverride: RelayProactive.Level?
  var learnsOverride: Bool?
  /// Checks answer approvals here instead of the panel or an alert.
  var confirmOverride: ((String, String) -> Bool)?
  /// Checks answer the alert fallback here (by title) instead of showing one.
  var alertOverride: ((String) -> Bool)?
  #endif
  /// “Serein asks before”: Only risky steps lets routine steps go ahead (RelayAutonomy).
  /// A scheduled run is never that case: it asks even when the saved level would auto-run.
  var runsUnattended: Bool { activeScheduled != nil }
  /// The person's own words behind the running scheduled turn (UnattendedAuthority): the
  /// request's or goal's text as they approved it, or a self-set follow-up's `source`; in a
  /// check-in, the last message they typed in this chat; for an alert, what they typed when
  /// creating it. nil for a link, the brief, a resume turn, or no scheduled turn: those may only ask.
  var turnAuthority: String? {
    if checkingIn { return lastRequest[threadID] }
    if let turn = activeScheduled, turn.initiator == .watch, let id = turn.watchID {
      return watches.first { $0.id == id }?.request
    }
    guard let turn = activeScheduled, turn.initiator == .scheduled, turn.linkID == nil, turn.watchID == nil,
      turn.reminder.id != RelayBriefing.reminderID, !RelayDeferred.isResume(turn.reminder.id)
    else { return nil }
    // A one-time request has left the list once it fired; its running copy holds the same words.
    let reminder = reminders.first { $0.id == turn.reminder.id } ?? turn.reminder
    return reminder.selfSet == true ? reminder.source : reminder.text
  }
  /// Whether the running scheduled turn's words name this action.
  func wordsCover(_ effect: ApprovalGate.Effect, targets: [String]) -> Bool {
    (runsUnattended || checkingIn) && UnattendedAuthority.covers(request: turnAuthority, effect: effect, targets: targets)
  }
  /// Whether those words cover a Mac app step: reading only (`UnattendedAuthority.passive`).
  func wordsCover(_ effect: ApprovalGate.Effect, place: String?) -> Bool {
    (runsUnattended || checkingIn) && UnattendedAuthority.covers(request: turnAuthority, effect: effect, place: place)
  }
  /// Whether those words cover a step on a web page: reading, and on a site they name a plain
  /// click or key move (`UnattendedAuthority.covers(request:effect:site:)`).
  func wordsCover(_ effect: ApprovalGate.Effect, site: String?) -> Bool {
    (runsUnattended || checkingIn) && UnattendedAuthority.covers(request: turnAuthority, effect: effect, site: site)
  }
  /// A one-time yes from a deferred card waits in this chat (RelayDeferred).
  func grantWaits(thread: String?) -> Bool {
    let now = Date()
    return oneTimeGrants.contains { $0.action.thread == (thread ?? threadID) && $0.until > now }
  }
  /// Whether the running scheduled turn already set its one follow-up.
  var followedUpThisRun: Bool { followedUp == turnSerial }
  func markFollowUp() { followedUp = turnSerial }
  /// The assistant whose schedule or watch the running scheduled turn is; nil for none, or for
  /// the person's own.
  var scheduledProfileID: String? { activeScheduled?.profileID }
  /// The kept sign-ins the running scheduled request's creation card named, as the saved request
  /// names them now (a Sign out takes a site off it), or as the running copy does once a one-time
  /// request has left the list; none for a watch, a webhook or a request that named none.
  var scheduledSignInSites: Set<String> {
    guard let active = activeScheduled else { return [] }
    let live: RelayReminder = reminders.first { $0.id == active.reminder.id } ?? active.reminder
    return Set(live.signInSites ?? [])
  }
  /// A kept sign-in ended (TaskStores.end): no scheduled request names those sites any more, nor
  /// any copy of one (running, queued, held for the usage limit or missed), so keeping a site again
  /// never revives a copy taken before the Sign out.
  func forgetSignInSites(_ sites: Set<String>) {
    if let active = activeScheduled { activeScheduled = Self.strip(sites, fromTurn: active) }
    let queue: [ScheduledTurn] = scheduledQueue.map { Self.strip(sites, fromTurn: $0) }
    if queue != scheduledQueue { scheduledQueue = queue }
    for i in held.indices {
      guard let turn = held[i].scheduled else { continue }
      let stripped: ScheduledTurn = Self.strip(sites, fromTurn: turn)
      if stripped != turn { held[i].scheduled = stripped }
    }
    let missed: [RelayMissedRun] = missedRuns.map { (run: RelayMissedRun) -> RelayMissedRun in
      RelayMissedRun(reminder: Self.strip(sites, from: run.reminder), why: run.why)
    }
    if missed != missedRuns { missedRuns = missed }
    // The copies Undo keeps lose those sites too, so undoing an older change never brings back
    // a sign-in that ended since.
    let changes: [RelayScheduleChange] = scheduleChanges.map { (change: RelayScheduleChange) -> RelayScheduleChange in
      var copy = change
      if let kept = change.reminder { copy.reminder = Self.strip(sites, from: kept) }
      return copy
    }
    if changes != scheduleChanges {
      scheduleChanges = changes
      persist(scheduleChanges, "relay/schedule-changes.json")
    }
    let named: Bool = reminders.contains { Self.strip(sites, from: $0) != $0 }
    guard named else { return }
    updateReminders { list in
      for i in list.indices { list[i] = Self.strip(sites, from: list[i]) }
    }
  }
  /// `reminder` without the kept sign-ins in `sites`.
  private static func strip(_ sites: Set<String>, from reminder: RelayReminder) -> RelayReminder {
    guard let named = reminder.signInSites else { return reminder }
    let left: [String] = named.filter { !sites.contains($0) }
    var copy: RelayReminder = reminder
    copy.signInSites = left.isEmpty ? nil : left
    return copy
  }
  private static func strip(_ sites: Set<String>, fromTurn turn: ScheduledTurn) -> ScheduledTurn {
    ScheduledTurn(
      reminder: strip(sites, from: turn.reminder), initiator: turn.initiator, profileID: turn.profileID,
      retried: turn.retried, ledgerID: turn.ledgerID, watchID: turn.watchID, journal: turn.journal)
  }

  /// What started the running scheduled turn; Mail, Messages and connected apps are never used
  /// by a webhook's turn (Connections, ComposioApps).
  var scheduledInitiator: AgentHistoryRun.Initiator? { activeScheduled?.initiator }
  /// The running turn came from the person's own message: only such a turn may propose a team or
  /// hand work to another assistant.
  var startedByPerson: Bool { personTurn && activeScheduled == nil && !proactiveTurn }
  /// `Admission`'s verdict on `change` in the turn now running (`admissionTurn`), with
  /// `TypedConsent` reading the person's words (`typedWords`). A call while no turn of Serein's own
  /// runs asks: only Serein's own checks make one, with no typed words behind it.
  func admission(_ change: Admission.Change) -> Admission.Verdict {
    guard working else { return .ask }
    return Admission.decide(change, turn: admissionTurn, wordsNameIt: TypedConsent.names(change, in: typedWords))
  }
  /// The site whose Never rule stopped the running scheduled request (BrowserModel.handle):
  /// the run is recorded as blocked, never counted toward the pause.
  var scheduledRuleBlock: String?
  /// A goal check is running: its findings notify through `goalChecked`, so only new ones do.
  var checkingGoal: Bool { activeScheduled?.reminder.goal != nil }
  var autopilot: Bool { standing.levelStands && level.autopilot }
  /// Who is asking, for the approval door: the turn now running, and the level as it is at this
  /// step, so a switch to Every step counts from the next step on.
  var standing: ApprovalDoor.Standing { standing(present: !runsUnattended) }
  /// The same with the caller's own word on whether anybody is there: a task's run can be
  /// unattended while this chat's turn is not.
  func standing(present: Bool) -> ApprovalDoor.Standing {
    // A check-in acts on the person's words alone (`wordsCover`): the level does not stand in it.
    ApprovalDoor.Standing(level: level, levelStands: activeScheduled == nil && !checkingIn, present: present)
  }
  /// With no chat behind the step, no level stands.
  static func standing(_ relay: RelayOrchestrator?, present: Bool) -> ApprovalDoor.Standing {
    relay?.standing(present: present) ?? .noChat(present: present)
  }
  var level: ApprovalLevel {
    #if DEBUG
    if let autopilotOverride { return autopilotOverride ? .riskyOnly : .everyStep }
    #endif
    // In GateSettings: unset, or a file that cannot be read, is Every step.
    return ApprovalLevel.resolve(stored: GateSettings.shared.object(forKey: Self.autopilotKey))
  }
  /// The user chose a level (the confirmation for Only risky steps and Allow all is the
  /// caller's). Marks the choice as theirs and retires the one-time consent card.
  func setLevel(_ level: ApprovalLevel) {
    objectWillChange.send()
    GateSettings.shared.set(level.storedValue, forKey: Self.autopilotKey)
    Self.setSetting(true, forKey: ApprovalLevel.userSetKey)
    GateSettings.shared.set(false, forKey: ApprovalLevel.defaultedKey)
    finishConsent(proceed: true)
    GuideCenter.shared.record(.approvalChoiceConfirmed)
  }
  /// The harness Relay thinks with: the user's choice, else Claude Code, Codex, then any. Never a
  /// local model endpoint: its turns have no Relay tools (`Provider.thinksForSerein`).
  var provider: Provider {
    get {
      if let raw = UserDefaults.standard.string(forKey: Self.providerKey) {
        let chosen = Provider(rawValue: raw)
        if chosen.thinksForSerein, agent.available[chosen] != nil { return chosen }
      }
      return [Provider.claude, .codex].first { agent.available[$0] != nil }
        ?? Provider.allCases.first { $0.thinksForSerein && agent.available[$0] != nil } ?? .claude
    }
    set {
      cancelWelcome()
      objectWillChange.send()
      UserDefaults.standard.set(newValue.rawValue, forKey: Self.providerKey)
    }
  }

  static func start(agent: AgentModel, browser: BrowserModel) -> RelayOrchestrator {
    if let shared { return shared }
    migrate(agent: agent, browser: browser)
    let relay = RelayOrchestrator(agent: agent, browser: browser)
    shared = relay
    if persists { Task { await relay.research.load() } }
    // Task panel tabs restored at launch that are Serein's own chats leave it now that Serein
    // knows its chats: they show in the Serein surface.
    TaskDock.shared.dropSereinChats(agent: agent)
    return relay
  }
  /// Once per install, before anything reads them: explicit values for what the old on/off switch
  /// used to hold back (AssistantMigration). Never in previews or checks.
  private static func migrate(agent: AgentModel, browser: BrowserModel) {
    guard persists else { return }
    let root = browser.library.root
    _ = ActionClickDefault.apply()
    PairingGrantReset.migrateOnce(root: root, defaults: .standard)
    AssistantMigration.run(
      .standard, gates: GateSettings.shared,
      freshInstall: {
        let files = FileManager.default
        let profiles = root.appendingPathComponent("relay/profiles", isDirectory: true)
        let saved = files.fileExists(atPath: root.appendingPathComponent("relay/state.json").path)
          || ((try? files.contentsOfDirectory(atPath: profiles.path)) ?? []).contains {
            files.fileExists(atPath: profiles.appendingPathComponent($0 + "/state.json").path)
          }
        return AssistantMigration.isFreshInstall(
          needsFirstRun: SetupProgress.needsFirstRun(), savedConversations: agent.conversations.count,
          assistantStateExists: saved)
      },
      canRunBuiltIn: VirtualMachineComputer.supported && VirtualMachineComputer.entitled,
      clearOutsideAgentAsks: { OutsideAgents.clearRelayGrants(root: root) },
      pauseRequestsAndWatches: {
        // Before init loads them: stored requests and alerts never ran while the assistant was
        // off, so they wait in Settings › Serein as paused until the user resumes them.
        let library = browser.library
        if let stored = library.load([RelayReminder].self, from: "relay/reminders.json") {
          let paused = AssistantMigration.pausing(stored)
          if paused != stored { try? library.save(paused, to: "relay/reminders.json") }
        }
        if let stored = library.load([RelayWatch].self, from: "relay/watches.json") {
          let paused = AssistantMigration.pausing(stored)
          if paused != stored { try? library.save(paused, to: "relay/watches.json") }
        }
      },
      turnOnBriefing: {
        let library = browser.library
        var stored = library.load([RelayReminder].self, from: "relay/reminders.json") ?? []
        guard !stored.contains(where: { $0.id == RelayBriefing.reminderID }) else { return }
        stored.append(RelayReminder(
          id: RelayBriefing.reminderID, text: RelayBriefing.text, due: RelayUnattended.nextMorning(after: Date()),
          repeats: .daily, action: true))
        try? library.save(stored, to: "relay/reminders.json")
      })
  }
  private init(agent: AgentModel, browser: BrowserModel) {
    self.agent = agent
    self.browser = browser
    // Library.save writes files only; Relay's folder is private like the rest of the library.
    let folder = browser.library.root.appendingPathComponent("relay", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(folder.path, 0o700)
    UITreeValues.shared.open(browser.library)
    // A single-assistant library migrates into the first profile, once.
    let profilesDir = folder.appendingPathComponent("relay/profiles/\(RelayTeam.mainID)", isDirectory: true)
    if !FileManager.default.fileExists(atPath: profilesDir.path),
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("relay/state.json").path) {
      try? FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for name in ["state", "notes", "proposals", "journal", "persona"] {
        let from = folder.appendingPathComponent("relay/\(name).json")
        if FileManager.default.fileExists(atPath: from.path) {
          try? FileManager.default.moveItem(at: from, to: profilesDir.appendingPathComponent("\(name).json"))
        }
      }
    }
    hookRegistry = (try? Data(contentsOf: folder.appendingPathComponent("hooks.json")))
      .flatMap { try? JSONDecoder().decode([RelayHookEntry].self, from: $0) } ?? []
    // Once: the assistant once called "Relay" answers to "Serein". The mark lives in this
    // library's team.json, so a preview's temporary library never marks the real one. A team that
    // decoded is rewritten with the mark. A missing team.json stays missing unless a persona was
    // checked (it can be saved without a team), which saves the marked fresh team so the check
    // runs once. A file that does not decode is left alone and never written (`RelayStateFile`).
    // Every Relay state file below is read the same way, and the person is told once.
    var aside: [String] = []
    let library = browser.library
    let teamFile = browser.library.root.appendingPathComponent("relay/team.json")
    let decodedTeam = Self.read(RelayTeam.self, "relay/team.json", library, &aside)
    let launch = RelayTeam.launching(decodedTeam)
    let loadedTeam = launch.team
    var checkedPersona = false
    if decodedTeam != nil || !FileManager.default.fileExists(atPath: teamFile.path) {
      for id in launch.personas {
        let path = loadedTeam.folder(id) + "/persona.json"
        guard let persona = Self.read(RelayPersona.self, path, library, &aside) else { continue }
        checkedPersona = true
        if let renamed = persona.renamingFormerMain() { try? browser.library.save(renamed, to: path) }
      }
      if launch.rewrite || checkedPersona { try? browser.library.save(loadedTeam, to: "relay/team.json") }
    }
    team = loadedTeam
    // All stored properties must exist before `self` is read, so the profile folder is local here.
    let active = "relay/profiles/\(loadedTeam.activeID)"
    state = Self.read(State.self, active + "/state.json", library, &aside) ?? State()
    // Notes live in the memory store (`openMemory` reads them in); a UI preview, which opens no
    // store, still shows the old file.
    notes = RunMode.previewing ? (library.load([RelayNote].self, from: active + "/notes.json") ?? []) : []
    let loadedTidy = Self.read([RelayNote].self, active + "/proposals.json", library, &aside) ?? []
    tidyProposals = loadedTidy
    proposals = loadedTidy
    let loadedReminders = Self.read([RelayReminder].self, "relay/reminders.json", library, &aside) ?? []
    reminders = loadedReminders
    // Missed runs listed before the last quit come back without a second notification.
    missedRuns = Self.persists
      ? RelayMissedRun.restored(
        Self.read([RelayMissedRun.Saved].self, Self.missedFile, library, &aside) ?? [], reminders: loadedReminders)
      : []
    watches = Self.read([RelayWatch].self, "relay/watches.json", library, &aside) ?? []
    scheduleChanges = Self.read([RelayScheduleChange].self, "relay/schedule-changes.json", library, &aside) ?? []
    journal = Self.read([RelayJournalEntry].self, active + "/journal.json", library, &aside) ?? []
    persona = Self.read(RelayPersona.self, active + "/persona.json", library, &aside) ?? RelayPersona()
    teamJournal = Self.read([RelayJournalEntry].self, "relay/team-journal.json", library, &aside) ?? []
    handoffLedger = Self.read(HandoffLedger.self, Self.handoffsFile, library, &aside) ?? HandoffLedger()
    limitFailovers = Self.read(LimitFailovers.self, Self.limitFailoversFile, library, &aside) ?? LimitFailovers()
    macAccess = Self.read(MacAccessWait.self, Self.macAccessFile, library, &aside) ?? MacAccessWait()
    activity = Self.read([Activity].self, "relay/activity.json", library, &aside) ?? []
    proactiveMemory = Self.read(RelayProactive.Memory.self, "relay/proactive.json", library, &aside) ?? RelayProactive.Memory()
    chatReadMarks = Self.read([String: String].self, Self.chatReadFile, library, &aside) ?? [:]
    looks = (Self.read(RelayLookStore.self, "relay/look.json", library, &aside) ?? RelayLookStore()).repaired()
    memoryShell = Self.read(MemoryShellState.self, MemoryShellState.path, library, &aside) ?? MemoryShellState()
    // Messages held at the last quit (the 30-minute rule still counts from when each was written).
    // After a relaunch a usage-limit hold always waits for Continue now: its attachments and page
    // were not kept, and whose it was is not either, so it goes as a lower-trust message. One whose
    // chat is gone is dropped.
    let chats = Set(agent.conversations.map(\.id))
    held = (Self.persists ? Self.read([HeldMessage].self, "relay/held.json", library, &aside) : nil)?.compactMap {
      (message: HeldMessage) -> Held? in
      guard message.reason == .usageLimit else { return Held(message: message) }
      guard let chat = message.threadID, chats.contains(chat) else { return nil }
      return Held(message: message, userMessage: false)
    } ?? []
    let previous = agent.hub.onEnd
    agent.hub.onEnd = { [weak self] run in
      previous?(run)
      self?.ended(run)
    }
    // Launched while stopped: whatever comes due before Resume is worded as missed while stopped.
    if state.paused { stoppedSince = .distantPast }
    // Plain reminders handed to macOS at the last quit come back before the clock starts, so
    // nothing fires twice.
    takeBackReminders()
    wakeWatch = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        // Only while the clock runs (fixture approvals suspend it).
        guard let self, self.clock != nil else { return }
        self.tick()
        // A usage-limit reset that passed while the Mac slept goes now.
        self.continueAtReset()
      }
    keptAside(aside)
    // Proposals, holds, asks and owned links kept from the last launch (RelayAssistantTools.swift).
    loadAssistantWork()
    // The shared memory and the work ledger open once, off the main thread; no scheduled run
    // starts before the ledger's launch recovery (`openWork`).
    openMemory()
    openWork()
    // An AI app connecting or the network coming back sends what was held (the value is set by
    // the next turn of the run loop: `@Published` sends before it changes).
    // A sign-in made anywhere (a fresh check of the app) counts too.
    heldWatch = agent.$available.map { _ in () }.merge(with: NetworkMonitor.shared.$online.map { _ in () })
      .merge(with: HarnessActions.shared.$needsSignIn.map { _ in () })
      .merge(with: HarnessRegistry.shared.$snapshots.map { _ in () })
      // A hold kept for one chat goes when that chat is on screen again.
      .merge(with: $team.map(\.activeID).removeDuplicates().map { _ in () })
      .receive(on: RunLoop.main)
      .sink { [weak self] in self?.releaseHeld() }
    scheduleHeldTick()
    scheduleUsageTick()
    startClock()
  }

  /// Reads one Relay state file. A file that is there and does not decode is listed in `aside`,
  /// so the person is told once (`keptAside`) and no save writes over it (SPEC I13).
  private static func read<T: Decodable>(_ type: T.Type, _ path: String, _ library: Library, _ aside: inout [String])
    -> T?
  {
    switch library.loadGuarded(type, from: path) {
    case .missing: return nil
    case .loaded(let value): return value
    case .unreadable:
      aside.append(path)
      return nil
    }
  }
  /// Reads one Relay state file after launch, as `read` does, and tells the person at once.
  func readState<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
    var aside: [String] = []
    let value = Self.read(type, path, browser.library, &aside)
    keptAside(aside)
    return value
  }
  /// Keeps each unreadable Relay state file from being written (`persist`) and tells the person
  /// once, in plain words.
  private func keptAside(_ aside: [String]) {
    for path in aside where !unwritable.contains(path) {
      unwritable.insert(path)
      let words = RelayStateFile.words(for: path)
      note(words, .auto)
      lastError = words
    }
  }
  /// The file `path` did not decode at launch, so nothing changes it (`persist` refuses).
  func isUnreadable(_ path: String) -> Bool { unwritable.contains(path) }

  private func startClock() {
    clock = Task { [weak self] in
      while !Task.isCancelled {
        // Each step keeps its own pause check (Stop Everything holds them until resumed).
        // The clock stays on when Relay is switched off so an unanswered approval still becomes a no.
        self?.tick()
        self?.checkWatches()
        self?.tidyIfDue()
        self?.speakFirst()
        // What Serein knows about the person, kept current from their AI chats each week.
        if let self, RelayOrchestrator.persists, !state.paused { GetToKnow.runIfDue(self) }
        self?.releaseProactiveNotices()
        // Proposal cards, late answers, host messages and removed links (RelayAssistantTools.swift).
        self?.sweepAssistantWork()
        // Owned links run whether or not ⌥Space is on; Settings' hooks follow their switch.
        self?.runHookServer()
        try? await Task.sleep(nanoseconds: 15_000_000_000)
      }
    }
  }

  /// Isolated fixtures exercise the ordinary approval UI without running unrelated reminders,
  /// watches, or webhooks. Only the validated fixture library's shared Relay may be suspended.
  func suspendForFixtureApprovals() throws -> () -> Void {
    guard FixtureApprovals.isAllowed(root: browser.library.root), Self.shared === self,
      held.isEmpty, checking.isEmpty, approvals.isEmpty, !consentWaiting, questionForms.isEmpty
    else { throw SereinError.invalid("Fixture approvals need an idle isolated Relay.") }
    #if DEBUG
    guard confirmOverride == nil else { throw SereinError.invalid("Fixture approvals require the real approval cards.") }
    #endif
    let wasPaused = state.paused
    let hadClock = clock != nil
    let hadServer = hookServer != nil
    state.paused = true
    clock?.cancel()
    clock = nil
    heldTick?.cancel()
    heldTick = nil
    usageTick?.cancel()
    usageTick = nil
    hookServer?.stop()
    hookServer = nil
    return { [weak self] in
      guard let self, Self.shared === self, FixtureApprovals.isAllowed(root: self.browser.library.root) else { return }
      self.state.paused = wasPaused
      self.scheduleHeldTick()
      self.scheduleUsageTick()
      if hadClock { self.startClock() }
      if hadServer { self.runHookServer() }
    }
  }

  /// Release only the Relay that the fixture created. Browser tasks and hub runs belong to
  /// their callers; releasing an approval host must not revoke a stress driver's accepted task.
  static func releaseFixtureRelay(_ relay: RelayOrchestrator) {
    guard FixtureApprovals.isAllowed(root: relay.browser.library.root) else { return }
    release(relay)
  }
  #if DEBUG
  /// Checks end the Relay they started on a throwaway library, so the next suite can start one.
  static func releaseForChecks(_ relay: RelayOrchestrator) { release(relay) }
  #endif
  private static func release(_ relay: RelayOrchestrator) {
    guard shared === relay else { return }
    relay.clock?.cancel()
    relay.clock = nil
    relay.capture?.cancel()
    relay.capture = nil
    relay.heldTick?.cancel()
    relay.heldTick = nil
    relay.usageTick?.cancel()
    relay.usageTick = nil
    relay.heldWatch?.cancel()
    relay.heldWatch = nil
    relay.hookServer?.stop()
    relay.hookServer = nil
    shared = nil
  }

  // MARK: Main chat

  var threadID: String { state.threadID }
  /// Every chat id that is Serein's own: each assistant's current chat and the chats it moved on
  /// from, read from every profile's state.json once, then kept current; and the hidden chats of
  /// light asks (RelayAsks.swift), so no task list, toast or notice shows them.
  var knownThreadIDs: Set<String> {
    if let knownCache { return knownCache.union(desk.hiddenThreads) }
    var ids: Set<String> = [state.threadID]
    var others: Set<String> = []
    ids.formUnion(state.pastThreadIDs ?? [])
    for profile in team.profiles where profile.id != team.activeID {
      if let other = browser.library.load(State.self, from: team.folder(profile.id) + "/state.json") {
        ids.insert(other.threadID)
        others.insert(other.threadID)
        ids.formUnion(other.pastThreadIDs ?? [])
      }
    }
    knownCache = ids
    otherCurrentCache = others
    return ids.union(desk.hiddenThreads)
  }
  private var knownCache: Set<String>?
  /// The other assistants' current chats, which never show as this one's past chats.
  private var otherCurrentCache: Set<String>?
  /// One conversation per assistant: true when `id` is it (another assistant's becomes the active
  /// one). An earlier chat of Serein's, from before it kept one conversation, never becomes it
  /// again: it opens to read (History, a notification). Refused while Serein replies.
  @discardableResult func resumeChat(_ id: String) -> Bool {
    guard id != state.threadID else { return true }
    guard !working else { return false }
    // Another assistant's Main chat (a hand-off's, say) opens as that assistant, never as this one's.
    _ = knownThreadIDs
    guard otherCurrentCache?.contains(id) == true else { return false }
    cancelWelcome()
    let owner = team.profiles.first {
      $0.id != team.activeID && browser.library.load(State.self, from: team.folder($0.id) + "/state.json")?.threadID == id
    }
    return owner.map { switchTo($0.id) } ?? false
  }
  /// A deleted past chat of Serein's leaves its past chats. Whatever chat was deleted, what was
  /// learned in it is forgotten (SPEC 4.9).
  func forgetPast(_ id: String) {
    forgetChatMemory(id)
    guard state.pastThreadIDs?.contains(id) == true else { return }
    state.pastThreadIDs?.removeAll { $0 == id }
    knownCache = nil
    save()
  }
  /// A deleted task's chat leaves Serein's chat: its card goes, and it is no longer a task.
  func forgetChild(_ id: String) {
    guard isChild(id) else { return }
    state.children.removeAll { $0.threadID == id }
    save()
  }
  /// The chat has something to go back to (saved messages, or a live transcript).
  private func hasMessages(_ id: String) -> Bool {
    agent.conversations.contains { $0.id == id && !$0.messages.isEmpty }
      || agent.hub.latest(for: id)?.transcript.isEmpty == false
  }
  /// Serein's earlier chats that still have something in them, newest first (Past chats): those
  /// it moved on from, and older ones known by their saved flag or scope. Never the current chat,
  /// another assistant's current chat or a task.
  var pastChats: [Conversation] {
    _ = knownThreadIDs
    let others = otherCurrentCache ?? []
    // A light ask's hidden chat is never a past chat (RelayAsks.swift).
    let hidden: Set<String> = desk.hiddenThreads
    return agent.conversations.filter {
      $0.id != threadID && !others.contains($0.id) && !hidden.contains($0.id) && !$0.messages.isEmpty && !isChild($0.id)
        && agent.isSereinChat($0)
    }.sorted { ($0.lastMessageAt ?? $0.updatedAt) > ($1.lastMessageAt ?? $1.updatedAt) }
  }
  /// Relay's own run while it works.
  var run: AgentRun? { agent.hub.run(for: threadID) }
  /// A hand-off being dispatched into this chat counts too, so a scheduled turn never races it,
  /// and so does another assistant's routine in its own chat (`ownerRun`): Serein's tools answer
  /// one turn at a time.
  var working: Bool { run != nil || sending || handoffsStarting.contains(threadID) || ownerRun != nil }
  /// The chat whose turn Serein's tools answer now: another assistant's Main chat while its
  /// routine runs there (`ownerRun`), else the chat on screen. Cards, the personal-read mark and
  /// receipts follow it.
  var turnThread: String { ownerRun?.thread ?? threadID }
  /// The assistant whose turn runs now: a routine's owner, else the one Serein's turn acts for,
  /// else Serein (the main assistant) for the person's own requests.
  var turnProfileID: String { ownerRun?.profileID ?? actingProfile?.id ?? team.mainProfileID ?? RelayTeam.mainID }
  /// The assistant whose persona and places the turn's stable prompt names (RelayPrompt.stable).
  var turnProfile: RelayProfile? { ownerRun.map { profile(id: $0.profileID) } ?? team.active }
  /// The persona the turn's stable prompt carries: the routine owner's while `ownerRun` is set.
  var turnPersona: RelayPersona { ownerRun == nil ? persona : (ownerPersona ?? RelayPersona()) }
  /// The Main chat: the live run's transcript, else the saved thread.
  var transcript: [AgentMessage] {
    agent.hub.latest(for: threadID)?.transcript
      ?? agent.conversations.first { $0.id == threadID }?.messages ?? []
  }
  /// Called only by a visible in-window chat. The controller checks the same conditions again
  /// after the helper returns, so a person's message always takes precedence.
  func welcomeIfNeeded() { welcome.begin(self) }
  func cancelWelcome(suppress: Bool = false) { welcome.cancel(suppress: suppress) }
  func setWelcoming(_ value: Bool) { welcoming = value }
  #if DEBUG
  /// The actual lifecycle with a deterministic, tool-free generator and no window dependency.
  /// Only automated processes can use it; normal app instances retain the visibility checks.
  func welcomeForChecks(generate: @escaping SereinWelcome.Generator) {
    guard RunMode.automated else { return }
    welcome.begin(self, generate: generate)
  }
  func restoreWelcomeCheckState(_ saved: State) {
    guard RunMode.automated else { return }
    cancelWelcome()
    state = saved
    knownCache = nil
  }
  #endif
  /// Saves the reply without selecting this chat in AgentModel or changing sessions/active.json.
  /// The current main-thread id is saved too, so a relaunch cannot manufacture a second greeting.
  func recordWelcome(_ text: String, generated: Bool, provider: Provider, thread: String) {
    guard thread == threadID, !working, transcript.isEmpty else { return }
    let now = Date()
    let message = AgentMessage(role: "assistant", text: text, notice: generated ? nil : true)
    var conversations = agent.conversations
    if let index = conversations.firstIndex(where: { $0.id == thread }) {
      guard conversations[index].messages.isEmpty else { return }
      conversations[index].messages = [message]
      conversations[index].serein = true
      conversations[index].updatedAt = now
      conversations[index].lastMessageAt = now
    } else {
      var conversation = Conversation(id: thread, title: "Serein", messages: [message], provider: provider,
        mode: .anywhere, projectID: nil, remoteID: nil, scope: "", updatedAt: now)
      conversation.serein = true
      conversation.lastMessageAt = now
      conversations.insert(conversation, at: 0)
    }
    do {
      // Automated checks have an isolated library; explicit UI previews keep everything in memory.
      if !RunMode.previewing {
        let statePath = dir + "/state.json"
        try FileManager.default.createDirectory(
          at: browser.library.root.appendingPathComponent(statePath).deletingLastPathComponent(),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try browser.library.save(state, to: statePath)
        try browser.library.save(conversations, to: "sessions/threads.json")
      }
      agent.conversations = conversations
      if agent.conversationID == thread, agent.messages.isEmpty { agent.messages = [message] }
      // An empty ended run can still be the transcript source until the next turn starts.
      agent.hub.latest(for: thread)?.transcript = [message]
      knownCache = nil
      objectWillChange.send()
    } catch {
      lastError = "Serein could not save its greeting: \(error.localizedDescription)"
    }
  }
  /// Delegated runs, newest first, that are still in the hub (this launch).
  var childRuns: [AgentRun] {
    let ids = Set(state.children.map(\.threadID))
    return agent.hub.runs.filter { ids.contains($0.spec.threadID) }.reversed()
  }
  func isChild(_ threadID: String) -> Bool { state.children.contains { $0.threadID == threadID } }
  func child(_ threadID: String) -> Child? { state.children.first { $0.threadID == threadID } }
  /// New work went to a run Serein started (agent_send): whether its routine steps may use a
  /// standing yes follows the turn that sent it, so work sent by a schedule, a link, an ask or a
  /// check-in never rides on one.
  func noteSteered(_ threadID: String) {
    guard let i = state.children.firstIndex(where: { $0.threadID == threadID }) else { return }
    let now: Bool? = startedByPerson ? true : nil
    guard state.children[i].byPerson != now else { return }
    state.children[i].byPerson = now
    save()
  }

  /// A message from the user. "stop" stops everything at once. While Relay works, a message is
  /// a correction: the turn stops and starts again with it (the native session keeps what was
  /// done), unless `interrupt` is off, when it waits for the turn to finish (the panel's "After
  /// this", and scheduled requests, which never cut into the user's own turn).
  /// `page` is the tab the message's page chip stands for (or ⌥⌘E's chip with text): the turn
  /// carries its title and site, `current_page` may read it, and “do it here” may act in it,
  /// after asking. Nothing else ever names a tab for Serein. `userMessage` is false for
  /// paired-app automation, which must not count toward teaching about the person’s activity.
  /// `limitRetry`: it is sent again from a usage-limit hold, so meeting the limit again never
  /// sends it by itself (UsageLimit.plan). True when the words start a reply or wait behind one;
  /// a command, held or refused words do not.
  @discardableResult
  func ask(_ text: String, attachments: [SereinAttachment] = [], trail: SereinAttachment? = nil, interrupt: Bool = false,
           page: SereinPage? = nil, inWindow: Bool = true, userMessage: Bool = true, limitRetry: Bool = false,
           request: String? = nil) -> Bool {
    // Nobody signed in: nothing starts or waits, from any caller.
    let page = attachments.compactMap(\.page).last ?? page
    var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if prompt.isEmpty && !attachments.isEmpty { prompt = SereinAttachment.noWords }
    guard !prompt.isEmpty else { return false }
    // A key never goes to a model (T7). The message boxes say so before they give up their words
    // (`messagePlan`), and Edit before it rewinds (`rerun`); this stops a person's message that
    // reaches `ask` any other way.
    if userMessage, ComposerGuard.looksLikeKey(prompt) {
      lastError = ComposerGuard.keyRefusal
      return false
    }
    // The person is here and writing: what was unread here is read.
    if userMessage { chatRead(silent: true) }
    cancelWelcome()
    if userMessage && inWindow { HintCenter.shared.recordInteraction() }
    lastError = nil
    unsent = []
    heldNotice = nil
    // The line under the last reminder belongs to that turn; the next one moves on, and so do
    // the collapsed answers of that turn.
    reminderNotice = nil
    answered = []
    // "/login" is the AI app's own sign-in, never words for the model: the Connect job starts
    // for the app this chat thinks with, in every harness (ConnectNeed.aiApp's open). It comes
    // before the cards are cleared, so the message an AI app card holds still goes after it.
    if userMessage, attachments.isEmpty, prompt.lowercased() == "/login" {
      ConnectNeed.aiApp(assistantEngine(team.active).provider).open()
      return false
    }
    // The person's next message replaces the connect cards; a paired app's request does not.
    if userMessage { clearConnectCards() }
    stopNotice = nil
    // “@Writer …” goes to Writer's Main chat and “@Trip …” to that team's responder: the person's
    // own words only, never automation (TeamMention).
    if userMessage, TeamMention.parse(prompt, in: team) != nil {
      guard let routed = routeMention(prompt, attachments: attachments) else { return false }
      prompt = routed
    }
    // The person talking to Relay again lifts the kill switch's pause; a paired app's request
    // never does (it waits until the person resumes Serein).
    if state.paused {
      guard userMessage else { return false }
      resume()
    }
    // A bare “stop” ends only the reply; its tasks keep going. “Stop everything” stops all.
    switch attachments.isEmpty ? RelayStop.kind(prompt) : nil {
    case .everything?:
      stopEverything(pause: true)
      note("Stopped everything", .user)
      return false
    case .reply?:
      cancelWelcome(suppress: true)
      SereinChatSetup.shared.cancelPending(self)
      if working {
        stopReply()
      } else {
        stopNotice = .idle(working: liveTasks, others: otherLiveTasks)
      }
      return false
    case nil: break
    }
    if userMessage && inWindow {
      let answeringSetup = SereinChatSetup.shared.prepareForMessage(self)
      if attachments.isEmpty && SereinChatSetup.shared.handleText(prompt, relay: self, answeringQuestion: answeringSetup) { return false }
      if SereinChatSetup.shared.requiresChoice(self) {
        held.append(Held(message: HeldMessage(id: request ?? UUID().uuidString, text: prompt, at: Date(), reason: .noAI),
          attachments: attachments, page: page, inWindow: true, userMessage: true))
        return false
      }
    }
    // "Stop suggesting routines" is a host intent: the switch goes off with no model turn. The
    // person's own words otherwise count toward a routine offer (RelayRoutineOffers.swift).
    if userMessage, attachments.isEmpty, RoutineOffers.stopsSuggestions(prompt), stopSuggestingRoutines(prompt) { return false }
    if userMessage { noteRoutineRequest(prompt) }
    // No AI app, or offline: the message is held, never lost (F10, F12). A request going again
    // keeps its id, so the journal still knows its steps when it leaves the hold.
    if let reason = HeldMessage.reason(connected: SereinSurface.connected(agent), online: networkOnline()) {
      held.append(Held(message: HeldMessage(id: request ?? UUID().uuidString, text: prompt, at: Date(), reason: reason),
                       attachments: attachments, page: page, inWindow: inWindow, userMessage: userMessage))
      return false
    }
    if working {
      // The person's own words go into the reply that runs, where its engine reads them now
      // (RunSteering.path). Its consent words and grants stay as the turn started with.
      if !interrupt, let run, run.spec.initiator != .handoff, agent.hub.takesWords(run),
        RunSteering.path(
          agent.hub.steerWire(run), carriesContext: !attachments.isEmpty || trail != nil || page != nil,
          othersWaiting: !pending.isEmpty || approvals.contains { $0.threadID == threadID }, byPerson: userMessage) == .intoTurn
      {
        if userMessage { noteCorrection(prompt, thread: threadID) }
        agent.hub.steer(run, prompt) { [weak self] unread in self?.keepForNextTurn(unread, inWindow: inWindow) }
        return true
      }
      pending.append(prompt)
      pendingContext.append((attachments, trail, page, inWindow, userMessage, limitRetry, request))
      if interrupt { interruptForPending() }
      return true
    }
    // Only a message that starts a turn closes the cards this chat waited on: one typed while a
    // card waits queues behind it (TurnActivity's "Answer the card first"), never answers it.
    if userMessage { personSpoke(thread: threadID) }
    turn(prompt, attached: attachments + [trail].compactMap { $0 }, page: page, userMessages: userMessage ? 1 : 0,
         windowMessages: userMessage && inWindow ? 1 : 0, byPerson: userMessage,
         request: userMessage
           ? Held(message: HeldMessage(id: request ?? UUID().uuidString, text: prompt, at: Date(), reason: .usageLimit),
                  attachments: attachments, page: page, inWindow: inWindow, userMessage: userMessage, retried: limitRetry) : nil)
    return true
  }
  /// Words a running reply took and never read wait ahead of the others, for the next turn.
  private func keepForNextTurn(_ texts: [String], inWindow: Bool) {
    pending.insert(contentsOf: texts, at: 0)
    pendingContext.insert(contentsOf: texts.map { _ in ([], nil, nil, inWindow, true, false, nil) }, at: 0)
  }
  /// Stops what runs so the words that wait go now, as the next turn.
  private func interruptForPending() {
    // A task handed over from another assistant finishes first: the message waits for it.
    if let run, run.spec.initiator != .handoff {
      redirecting = true
      if ownerRun == nil { interruptedWork = activeScheduled?.ledgerID }
      agent.hub.stop(run)
    } else if let owner = ownerRun, let other = agent.hub.run(for: owner.thread) {
      // Another assistant's routine runs in its own chat: the person's words go first, as they
      // do over a scheduled turn in this chat. It runs once more after the person's turn.
      interruptedWork = activeScheduled?.ledgerID
      agent.hub.stop(other)
    }
  }
  /// Send now, on a queued message, can act: a reply runs in this chat that may be cut short. A
  /// handed-over task finishes first, a turn still starting has nothing to stop, and another
  /// assistant's routine is never cut short from here (as ⌥Return).
  var canSendPendingNow: Bool { replyingHere && run.map { $0.spec.initiator != .handoff } == true }
  /// Send now, on a queued message: what ⌥Return does for words still in the box. No AI app
  /// takes words into a turn that is running, so the reply stops, keeping the work done, and
  /// every message that waits goes at once, in order, as the next turn.
  func sendPendingNow() {
    guard canSendPendingNow, !pending.isEmpty else { return }
    interruptForPending()
  }
  /// What held messages can do now: those written within 30 minutes send once what held them
  /// clears; older ones wait for Send now or Discard. Runs when an AI app connects or the network
  /// comes back.
  func releaseHeld(now: Date = Date()) {
    // UI previews never send a held message. While Stop Everything has Serein paused nothing
    // goes by itself: a send would lift the pause (`ask`), and only the person resumes. Signed
    // out, a held message stays held for the next sign-in.
    guard !RunMode.previewing, !state.paused else { return }
    continueSignedIn(now: now)
    guard !held.isEmpty else { return }
    // An AI app that just connected can take a chat its usage limit held.
    offerElsewhereAgain()
    // An AI app that Connect has just installed is not signed in yet: `connected` leaves it out
    // until Connect finishes (`AgentModel.canThink`).
    let connected = SereinSurface.connected(agent) && !SereinChatSetup.shared.requiresChoice(self)
    let online = networkOnline()
    // A hold kept for one chat (`holdPendingSignedOut`) goes only while that chat is on screen,
    // with its own assistant; a hold for no chat goes in the chat on screen, as before.
    for item in held where (item.scheduled != nil || item.message.threadID == nil || item.message.threadID == threadID)
      && HeldMessage.next(item.message, connected: connected, online: online, now: now) == .send {
      held.removeAll { $0.id == item.id }
      let notice = HeldMessage.sendingLine(item.message.reason)
      // The first goes now; any after it waits for that reply (as Send when done).
      ask(item.message.text, attachments: item.attachments, interrupt: false, page: item.page, inWindow: item.inWindow,
          userMessage: item.userMessage, request: item.id)
      heldNotice = notice
    }
  }
  /// An AI app card's message goes once the app the next turn uses can answer: the one that
  /// refused after its sign-in (here or elsewhere), or another app picked from the card. The same
  /// message, once, as Continue sends it (`continueAfterConnect`). As with a held message, only
  /// within 30 minutes of being written; an older one waits for Continue.
  private func continueSignedIn(now: Date) {
    guard let cards = connectCards, cards.threadID == threadID, !cards.needs.isEmpty,
      now.timeIntervalSince(cards.request.message.at) <= HeldMessage.window,
      cards.needs.allSatisfy({ need in
        if case .aiApp = need { return agent.canThink(assistantEngine(team.active).provider) }
        return false
      })
    else { return }
    continueAfterConnect(byPerson: false)
  }
  /// Messages that waited behind a turn the AI app's sign-in stopped wait for the sign-in too,
  /// each with what it carried. A paired app's request is never held; its waiting files go.
  private func holdPendingSignedOut(thread: String) {
    for (index, text) in pending.enumerated() where pendingContext.indices.contains(index) {
      let context = pendingContext[index]
      guard context.userMessage else {
        ComposerContext.discard(context.attachments.flatMap(\.filePaths), keeping: [])
        continue
      }
      held.append(Held(
        message: HeldMessage(text: text, at: Date(), reason: .noAI, threadID: thread),
        attachments: context.attachments, page: context.page, inWindow: context.inWindow, userMessage: true,
        retried: context.retried))
    }
    pending = []
    pendingContext = []
  }
  /// Send now, on a held message: it goes (or is held again, written now, if still blocked).
  func sendHeld(_ id: String) {
    guard let item = held.first(where: { $0.id == id }) else { return }
    held.removeAll { $0.id == id }
    ask(item.message.text, attachments: item.attachments, page: item.page, inWindow: item.inWindow,
        userMessage: item.userMessage, request: item.id)
  }
  /// Discard, on a held message. Its waiting document files go with it.
  func discardHeld(_ id: String) {
    if let item = held.first(where: { $0.id == id }) {
      ComposerContext.discard(item.attachments.flatMap(\.filePaths), keeping: [])
      if let scheduled = item.scheduled {
        note("Cancelled scheduled request \(Self.short(scheduled.reminder.text)) while it waited for the usage limit", .user)
      }
    }
    held.removeAll { $0.id == id }
  }
  // MARK: the AI app's usage limit

  /// A turn the AI app's usage limit stopped (`AgentRun.usageLimit`, read from the app's own
  /// answer) is held in its chat rather than failed, by `UsageLimit.plan`: a message waits for the
  /// reset time (or for Continue now, when no time was named or it already went again); a
  /// scheduled run waits only when its schedule allows a run that late, else it is recorded as
  /// missed with why; a webhook, an alert and Serein's own turns fail as before. True when the
  /// turn was held or recorded as missed.
  private func holdLimited(_ run: AgentRun, request: Held?, scheduled: ScheduledTurn?) -> Bool {
    guard run.record.outcome == .stuck, let limit = run.usageLimit else { return false }
    let app = run.spec.provider.name
    let origin: UsageLimit.Origin
    if let scheduled, scheduled.initiator == .scheduled {
      origin = .scheduled(due: scheduled.reminder.due, runLate: scheduled.reminder.runLate == true)
    } else if scheduled == nil, let request, request.userMessage {
      // Only the person's own message: a paired app's request is never held, since its pairing
      // is checked only when it arrives (the app sees the failed turn instead).
      origin = .message
    } else {
      origin = .unattended
    }
    let retried = scheduled?.retried ?? request?.retried ?? false
    // Only this chat's assistant moves; a scheduled run in another assistant's chat waits.
    let moves = scheduled == nil || run.spec.threadID == threadID
    var plan = UsageLimit.plan(origin, limit: limit, retried: retried, app: app, now: Date())
    if case .missed = plan, scheduled != nil, moves, !retried, !holdsCard(task: run.taskID), elsewhereStep()?.sameCost == true {
      plan = .hold(waits: false)
    }
    switch plan {
    case .fail:
      return false
    case .missed(let why):
      guard let scheduled else { return false }
      // Its history says why; the missed list offers Run now and Skip, with one notification.
      recordScheduleRun(scheduled.reminder, outcome: RelayReminder.missed, result: why, thread: run.spec.threadID)
      listMissed(scheduled.reminder, why: .usageLimit)
      return true
    case .hold(let waits):
      if let scheduled, held.contains(where: { $0.scheduled?.reminder.id == scheduled.reminder.id }) {
        recordScheduleRun(scheduled.reminder, outcome: RelayReminder.skipped,
                          result: "An earlier run is waiting for the usage limit.", thread: run.spec.threadID)
        return true
      }
      var item = request ?? Held(message: HeldMessage(text: "", at: Date(), reason: .usageLimit))
      // The id stays: sent again, it is the same request in the step journal.
      item.message = HeldMessage(
        id: item.message.id, text: scheduled?.reminder.text ?? item.message.text, at: Date(), reason: .usageLimit,
        threadID: run.spec.threadID, resetsAt: waits ? limit.resetsAt : nil)
      item.waits = waits
      item.retried = retried
      item.scheduled = scheduled
      held.append(item)
      noteLimited(run.spec.provider, until: limit.resetsAt)
      note("Held \(scheduled == nil ? "a message" : "scheduled request " + Self.short(scheduled?.reminder.text ?? "")) for \(app)'s usage limit", .auto)
      // The person's own message, or this chat's scheduled run, does not sit waiting: Serein
      // offers another AI app at once.
      if moves { continueElsewhere(item.id) }
      return true
    }
  }
  /// Messages that waited for a turn the limit stopped are held beside it, each with what it carried.
  private func holdPending(_ limit: UsageLimit, app: String, thread: String) {
    for (index, text) in pending.enumerated() where pendingContext.indices.contains(index) {
      let context = pendingContext[index]
      // A paired app's request is never held; its waiting files go.
      guard context.userMessage,
        case .hold(let waits) = UsageLimit.plan(.message, limit: limit, retried: context.retried, app: app, now: Date())
      else {
        ComposerContext.discard(context.attachments.flatMap(\.filePaths), keeping: [])
        continue
      }
      held.append(Held(
        message: HeldMessage(text: text, at: Date(), reason: .usageLimit, threadID: thread, resetsAt: waits ? limit.resetsAt : nil),
        attachments: context.attachments, page: context.page, inWindow: context.inWindow, userMessage: context.userMessage,
        waits: waits, retried: context.retried))
    }
    pending = []
    pendingContext = []
  }
  /// The reset time came: each hold waiting for it goes once, as it was sent (its attachments,
  /// page and origin; a scheduled run queues again with its own). It gains nothing: the new turn
  /// mints its own capability and every step asks as usual. A hold whose chat is no longer
  /// Serein's chat on screen, one that comes while Stop Everything has Serein paused, and every
  /// hold in a preview wait for Continue now instead.
  private func continueAtReset(now: Date = Date()) {
    for item in held where item.waits && (item.message.resetsAt.map { $0 <= now } ?? false) {
      guard !RunMode.previewing, !state.paused, item.scheduled != nil || item.message.threadID == threadID else {
        if let index = held.firstIndex(where: { $0.id == item.id }) { held[index].waits = false }
        continue
      }
      resend(item)
    }
    scheduleUsageTick(now: now)
  }
  /// Sends a usage-limit hold again, once: a message through `ask` with what it carried (marked
  /// `limitRetry`), a scheduled run queued again (`retried`). `byPerson`: Continue now or Use
  /// another AI app…; the reset time's own send waits for a running reply and, like any automatic
  /// retry, is not counted as a message written in the window. `unasked`: the send carries what
  /// a press carries, but nobody pressed (a move at the same cost that Serein made by itself), so
  /// it reads the journal as the reset time's send does. False when the hold stays.
  @discardableResult
  private func resend(_ item: Held, byPerson: Bool = false, unasked: Bool = false) -> Bool {
    // A step of it has an unknown outcome: a send nobody pressed does not go. It waits for
    // Continue now, where the step asks first (`StepJournal`).
    if !byPerson || unasked, case .waits = browser.stepJournal.resend(request: item.scheduled?.journal ?? item.id) {
      if let index = held.firstIndex(where: { $0.id == item.id }) { held[index].waits = false }
      return false
    }
    held.removeAll { $0.id == item.id }
    if let scheduled = item.scheduled {
      // The schedule as it is now: paused, deleted or out of runs meanwhile, it does not run.
      let live = reminders.first(where: { $0.id == scheduled.reminder.id })
        ?? (scheduled.reminder.repeats == .none ? scheduled.reminder : nil)
      guard let live, live.paused != true, !live.limitReached else {
        note("Scheduled request \(Self.short(scheduled.reminder.text)) was paused or removed while it waited for the usage limit", .auto)
        return true
      }
      queueWork(
        ScheduledTurn(
          reminder: live, initiator: scheduled.initiator, profileID: scheduled.profileID, retried: true,
          watchID: scheduled.watchID, journal: scheduled.journal),
        kind: scheduled.initiator == .webhook ? .link : .schedule, key: "retry:\(live.id):" + UUID().uuidString)
    } else {
      // Only the person's own press binds the tab again; the reset time's send, with nobody
      // there, goes without the page chip (a page chip with text keeps its text, not its tab).
      let attachments = byPerson ? item.attachments : item.attachments.map { chip -> SereinAttachment in
        var unbound = chip
        unbound.page = nil
        return unbound
      }
      ask(item.message.text, attachments: attachments, interrupt: byPerson, page: byPerson ? item.page : nil,
          inWindow: byPerson && item.inWindow, userMessage: item.userMessage, limitRetry: true, request: item.id)
    }
    return true
  }
  /// Continue now, on a usage-limit hold: it goes again once, now.
  func continueHeld(_ id: String) {
    guard let item = held.first(where: { $0.id == id }) else { return }
    resend(item, byPerson: true)
  }
  /// An AI app's usage limit is on until `until` (an hour when it named no time).
  private func noteLimited(_ provider: Provider, until: Date?, now: Date = Date()) {
    limitedApps = limitedApps.filter { $0.value > now }
    limitedApps[provider.rawValue] = until ?? now.addingTimeInterval(Self.unnamedLimitWait)
    namedLimitResets[provider.rawValue] = until
  }
  /// The AI app a usage-limit hold would move to now (`ModelFallback.elsewhere`): the person's
  /// backups from another AI app first, then any other installed, signed-in AI app that can
  /// answer as the assistant, never one whose own limit is still on.
  private func elsewhereStep(now: Date = Date()) -> ModelFallback.Step? {
    let engine = assistantEngine(team.active)
    guard let current = agent.routes(engine.provider, models: [engine.model]).first else { return nil }
    let canAnswer = { (provider: Provider) in provider != engine.provider && Self.assistantRouteRefusal(provider) == nil }
    let backups = ModelBackups.shared.entries.filter { canAnswer($0.provider) }
      .compactMap { agent.routes($0.provider, models: [$0.model]).first }
    let others = Provider.allCases.filter(canAnswer).compactMap { agent.routes($0, models: [""]).first }
    let limited = Set(limitedApps.filter { $0.value > now }.keys).union(failedApps.filter { $0.value > now }.keys)
    guard var step = ModelFallback.elsewhere(current: current, backups: backups, others: others, limited: limited) else { return nil }
    step.sameCost = step.sameCost || LimitFailover.allowed(from: current, to: step.route)
    return step
  }
  /// A usage-limit hold's next AI app: offered when the hold is made, on Use another AI app…,
  /// and again whenever an AI app connects (`releaseHeld`) if that brings a new one.
  private func offerElsewhereAgain() {
    let fresh = elsewhereStep()?.route.id ?? ""
    for item in held where item.message.reason == .usageLimit && item.scheduled == nil
      && item.message.threadID == threadID && elsewhereOffered[item.id] != fresh {
      continueElsewhere(item.id)
    }
  }
  /// The person's `words` are the last thing they wrote here and nothing answered them yet: only
  /// Serein's own notices and its own prompts (a brief, a check-in) came after.
  nonisolated static func awaitsReply(_ words: String, in messages: [AgentMessage]) -> Bool {
    for message in messages.reversed() {
      let own = message.text.hasPrefix(RelayProactive.marker)
      if message.role == "you", !own { return message.text == words }
      if message.role != "you", message.notice != true, !message.text.isEmpty { return false }
    }
    return false
  }
  /// A message sent again after a usage limit (`Held.retried`) failed on the AI app it moved to
  /// (signed out, an expired sign-in, or any other error): that app is set aside for a while
  /// (`failedApps`), and when another AI app can answer, the message is held for the limit again
  /// and offered there at once. False when nothing else can answer, so the failure (or that
  /// app's sign-in card) shows as before.
  private func moveOnAfterFailure(_ run: AgentRun, request: Held, now: Date = Date()) -> Bool {
    guard request.retried, request.userMessage, request.scheduled == nil else { return false }
    failedApps = failedApps.filter { $0.value > now }
    failedApps[run.spec.provider.rawValue] = now.addingTimeInterval(Self.failedAppWait)
    guard
      elsewhereStep(now: now) != nil || HarnessRegistry.shared.hasUnchecked
    else { return false }
    let reset = limitedApps.values.filter { $0 > now }.min()
    var item = request
    item.message = HeldMessage(text: request.message.text, at: now, reason: .usageLimit, threadID: run.spec.threadID,
                               resetsAt: reset)
    item.waits = reset != nil
    held.append(item)
    run.movedOn = true
    note("\(run.spec.provider.name) could not answer\(run.signedOut ? " (it needs a sign-in)" : ""); offered another AI app for the held message", .auto)
    continueElsewhere(item.id)
    return true
  }
  /// The assistant now thinks with an AI app whose limit is not on (a pick in the model list, or
  /// Use another AI app…): this chat's usage-limit holds go there at once, each once. The first
  /// goes as the person's own press; any after it waits for that reply. `byPerson` false: Serein
  /// made the move by itself, so a hold with a step whose outcome is unknown stays (`StepJournal`).
  func resumeLimitedHolds(on provider: String, byPerson: Bool = true, now: Date = Date()) {
    guard limitedApps[provider].map({ $0 <= now }) ?? true else { return }
    let waiting = held.filter { $0.message.reason == .usageLimit && $0.scheduled == nil && $0.message.threadID == threadID }
    var first = true
    for item in waiting {
      if resend(item, byPerson: first, unasked: !byPerson) { first = false }
    }
  }
  /// Use another AI app…, on a usage-limit hold (and at once when the hold is made): Serein moves
  /// to the next AI app that can answer (`elsewhereStep`), under the backup rules: a move at the
  /// same cost happens by itself, any other asks on its card first (`switchRoute`), and a move
  /// declines what its chat was asking. Once moved, the hold goes again once. With nothing that
  /// can answer, its row offers Connect, and connecting one offers it then. `byPerson`: the
  /// person pressed Use another AI app…. Without that press, a move at the same cost reads the
  /// step journal first: a hold with a step whose outcome is unknown does not move and does not
  /// go again by itself (`StepJournal`). Its row keeps Continue now and Use another AI app….
  func continueElsewhere(_ id: String, byPerson: Bool = false) {
    guard held.contains(where: { $0.id == id }) else { return }
    if let step = elsewhereStep() { return moveElsewhere(id, step, byPerson: byPerson) }
    elsewhereOffered[id] = ""
    // AI apps Serein has not checked yet (they are checked when first needed) cannot count as
    // ready: check them now, then look again.
    Task { [weak self] in
      await HarnessRegistry.shared.probeDeferredNow()
      guard let self, self.held.contains(where: { $0.id == id }), self.elsewhereOffered[id] == "",
        let step = self.elsewhereStep()
      else { return }
      self.moveElsewhere(id, step, byPerson: byPerson)
    }
  }
  private func moveElsewhere(_ id: String, _ step: ModelFallback.Step, byPerson: Bool) {
    elsewhereOffered[id] = step.route.id
    // The person's word: their press, or their answer on the card of a move that can cost.
    let asked = byPerson || !step.sameCost
    if !asked, let index = held.firstIndex(where: { $0.id == id }),
      case .waits = browser.stepJournal.resend(request: held[index].scheduled?.journal ?? id) {
      held[index].waits = false
      return
    }
    lastError = nil
    let assistant = team.activeID
    Task { [weak self] in
      guard let self, let item = await self.switchHeldRoute(id, step: step, assistant: assistant, byPerson: byPerson)
      else { return }
      self.resend(item, byPerson: true, unasked: !asked)
    }
  }
  /// At quit: a scheduled run waiting for the usage limit is not kept as a hold (only messages
  /// are). Its history says why, and it joins the missed list (relay/missed.json) without a
  /// notification, so the next launch offers Run now and Skip and runs nothing by itself.
  func missHeldRuns() {
    for item in held {
      guard let scheduled = item.scheduled else { continue }
      recordScheduleRun(scheduled.reminder, outcome: RelayReminder.missed,
                        result: "Serein quit before the usage limit reset.", thread: item.message.threadID)
      missedRuns = RelayMissedRun.adding(scheduled.reminder, why: .usageLimit, to: missedRuns)
    }
  }
  /// Takes a message waiting for the reply to finish (× on its chip).
  func removePending(at index: Int) {
    guard pending.indices.contains(index) else { return }
    pending.remove(at: index)
    if pendingContext.indices.contains(index) {
      // The message never goes: its waiting document files go now.
      ComposerContext.discard(pendingContext[index].attachments.flatMap(\.filePaths), keeping: [])
      pendingContext.remove(at: index)
    }
  }
  /// Edit, on a queued message: it leaves the queue for the box, with the chips that rode with
  /// it (their waiting files stay, since the message may still go).
  func takePending(at index: Int) -> (text: String, attachments: [SereinAttachment])? {
    guard pending.indices.contains(index) else { return nil }
    let text: String = pending.remove(at: index)
    let chips: [SereinAttachment] = pendingContext.indices.contains(index) ? pendingContext.remove(at: index).attachments : []
    return (text == SereinAttachment.noWords ? "" : text, chips)
  }
  /// Drops every message waiting for the reply, and their waiting document files with them.
  private func dropPending() {
    ComposerContext.discard(pendingContext.flatMap(\.attachments).flatMap(\.filePaths), keeping: [])
    pending = []
    pendingContext = []
  }
  /// Tasks Serein started that are still working.
  var liveTasks: Int { childRuns.filter(\.isActive).count }
  /// Tasks you started yourself (not Serein, not its own chats) that are still working: a Stop
  /// never touches them, and its line says so.
  var otherLiveTasks: Int {
    agent.hub.runs.filter { run in
      let id = run.spec.threadID
      return run.isActive && !run.spec.relay && !isChild(id) && !knownThreadIDs.contains(id) && !agent.isSereinChatID(id)
    }.count
  }
  /// Stop (the composer's status line) and a bare “stop”: ends only Serein's reply. What waited
  /// for it goes, and only the approvals and questions its own turn asked are declined; the tasks
  /// it started, and their approvals, keep going. Then it says how many tasks still work.
  func stopReply() {
    cancelWelcome(suppress: true)
    turnPage = nil
    turnBrief = nil
    dropPending()
    redirecting = false
    if let run {
      agent.hub.stop(run)
    } else if sending {
      // The turn is still being handed to the AI app: it stops as soon as it starts.
      cancelTurn = true
    } else if let owner = ownerRun, let other = agent.hub.run(for: owner.thread) {
      // Another assistant's routine was what Serein was doing: it stops.
      agent.hub.stop(other)
    }
    // Only this turn's cards are declined (with one moved to an alert, and its steps waiting on
    // the one-time card); a task's stay up.
    declineApprovals(thread: threadID)
    // Questions come only from Serein's own tools (ask_user), so they are all this turn's.
    for form in questionForms { form.answer(nil) }
    questionForms = []
    stopNotice = .stoppedReply(working: liveTasks, others: otherLiveTasks)
    note("Stopped the reply", .user)
  }
  /// Declines every card one thread has open: its approvals, any that moved to an alert, and its
  /// steps waiting on the one-time card. Stop uses it for Serein's turn, a model switch for the
  /// chat it moves (AgentModel.switchModel), and Edit and rerun for the chat it rewinds
  /// (AgentModel.rewind), so no yes outlives the engine or the turns it was given to.
  func declineApprovals(thread: String) {
    // A person step's card stays: it waits on the person, not on the engine (R12).
    for approval in approvals where approval.threadID == thread && !approval.personStep { approval.answer(.no) }
    approvals.removeAll { $0.threadID == thread && !$0.personStep }
    MacApproval.declineAll(thread: thread)
    finishConsent(proceed: false, thread: thread)
  }
  /// Edit and rerun on one of the user's messages in Serein's chat: what waited for the reply
  /// goes, the chat is rewound to before the message (`AgentModel.rewind` stops the reply and
  /// declines its cards), and the new words go as a new message, so every step asks again.
  /// Not while the turn is still being handed to the AI app (`sending`): Edit hides then.
  /// The refusal when the words look like a key: nothing is rewound, and the caller says why.
  @discardableResult func rerun(_ messageID: String, text: String) -> String? {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !sending, transcript.contains(where: { $0.id == messageID && $0.role == "you" })
    else { return nil }
    // Refused before the rewind: `ask` would refuse the same words only after the chat was cut.
    guard !ComposerGuard.looksLikeKey(prompt) else { return ComposerGuard.keyRefusal }
    let waiting = pending.count
    // Nothing here changes when the rewind is refused: the queued messages stay.
    guard let cleared = agent.rewind(messageID, in: threadID) else { return nil }
    turnPage = nil
    turnBrief = nil
    dropPending()
    redirecting = false
    for form in questionForms { form.answer(nil) }
    questionForms = []
    MessageEdit.announce(cleared: cleared + waiting)
    ask(prompt)
    return nil
  }
  /// Which try the newest turn in a chat is, of the same words: Try again counts up, and any
  /// other turn starts over at 1 (`TurnActivity.tryWords`).
  @Published private(set) var turnTry: (thread: String, number: Int)?
  func tryNumber(in thread: String) -> Int { turnTry?.thread == thread ? turnTry?.number ?? 1 : 1 }
  /// Set while Try again sends: the turn it starts is the same request, sent again (`turn`).
  private var tryingAgain = false
  /// Try again: `again` sends the person's words once more, and the turn it starts is the next try.
  func retrying(_ again: () -> Void) {
    let next: Int = tryNumber(in: threadID) + 1
    let before: Int = turnSerial
    tryingAgain = true
    again()
    tryingAgain = false
    // Only a turn that started counts: held or refused words are no new try.
    if turnSerial != before { turnTry = (thread: threadID, number: next) }
  }
  /// Try again on a burst that got no answer: its messages go again together, each its own bubble.
  func retryBurst() {
    let burst: [AgentMessage] = AgentMessage.burst(before: transcript.count, in: transcript)
    guard !sending, !working, let first = burst.first, agent.rewind(first.id, in: threadID) != nil else { return }
    turnPage = nil
    turnBrief = nil
    dropPending()
    redirecting = false
    pending = burst.map(\.text)
    pendingContext = burst.map { _ in
      (attachments: [], trail: nil, page: nil, inWindow: true, userMessage: true, retried: false, request: nil)
    }
    sendPending()
  }
  /// “Stop them too” after a Stop: every task Serein started stops; Serein is not paused.
  func stopTasks() {
    for run in childRuns where run.isActive { agent.hub.stop(run) }
    stopNotice = nil
  }
  /// Context stays beside its queued message, so removing a message also removes its authority.
  private var pendingContext: [(attachments: [SereinAttachment], trail: SereinAttachment?, page: SereinPage?, inWindow: Bool,
                                userMessage: Bool, retried: Bool, request: String?)] = []
  /// The host binding: the tab the user's own message carried for the turn now running (its page
  /// chip). The turn's context names its title and site; `current_page` reads only this tab, and
  /// `agent_start` here binds only to it. Nil for turns Serein starts itself.
  var turnPage: SereinPage?
  /// The brief's “Waiting on you” section for the turn now running (`RelayPrompt.volatile` puts it
  /// in that turn's context); nil for every other turn. Every turn on Serein's chat sets it.
  private(set) var turnBrief: String?
  /// The latest brief's “Waiting on you” items, with the chat and prompt that started it, so the
  /// chat shows them as a read-only card under that brief (this launch only; the reply repeats it).
  struct BriefWaiting: Equatable {
    let threadID: String
    let prompt: String
    let items: [RelayBriefing.Waiting]
  }
  @Published private(set) var briefWaiting: BriefWaiting?
  /// The brief card for the chat on screen.
  var briefCard: BriefWaiting? { briefWaiting?.threadID == threadID ? briefWaiting : nil }
  /// Chats and sites where you said Work here (`CurrentPageContext.workHereKey`), this launch.
  var workHereAllowed: Set<String> = []
  /// Set while a correction stops the turn, so its end starts the next one at once.
  private var redirecting = false
  /// Stop came while the turn was still being handed over (`sending`, no run yet).
  private var cancelTurn = false
  /// `request`: the person's own message turn, kept as it was sent, with its
  /// own copy of its documents, so the AI app's usage limit can hold it (`holdLimited`). Turns
  /// Serein starts itself have none and are never held.
  private func turn(_ prompt: String, attached: [SereinAttachment] = [], page: SereinPage? = nil,
                    userMessages: Int = 0, windowMessages: Int = 0, brief: String? = nil, byPerson: Bool = false,
                    request: Held? = nil, shown: [String]? = nil) {
    if let earlier = turnRequest { Self.dropFiles(earlier.held) }
    turnRequest = nil
    // The person's message is one request in the step journal, whichever send of it this is: a
    // hold or a connect card sends it again under its own id, Try again under the id the journal
    // kept for these words (`StepJournal`).
    var request = request
    let words: String = StepJournal.words(request?.message.text ?? prompt)
    if tryingAgain, request != nil, let same = browser.stepJournal.current(threadID, words: words) {
      request?.message.id = same
    }
    let journal: String? = request?.id
    if let request, let copies = Self.keptCopy(request.attachments) {
      var kept = request
      kept.attachments = copies
      turnRequest = (thread: threadID, held: kept)
    }
    let requestID = turnRequest?.held.id
    turnNeeds[threadID] = nil
    // The host binding lasts for this turn only; a private tab never binds.
    turnPage = page?.isPrivate == false ? page : nil
    turnBrief = brief
    turnSerial += 1
    turnTry = nil
    personTurn = byPerson
    personWords = byPerson ? (request?.message.text ?? prompt) : nil
    if byPerson, let personWords { lastRequest[threadID] = personWords }
    // Receipts, lines and the plan card are this turn's from here on (RelayAssistantTools.swift).
    desk.facts[threadID] = nil
    desk.plans[threadID] = nil
    // What the turn brings in from outside, for a new memory's defaults (`MemoryTurn`): a page or
    // a file on the message, or a turn nobody typed (a report, a hand-off's result, a check-in).
    turnReadOutside = !byPerson || page != nil || !attached.isEmpty
    sending = true
    cancelTurn = false
    // The active assistant thinks with its own engine when it has one (its route).
    restoreAfterLimit(team.activeID)
    let engine = assistantEngine(team.active)
    var target = AgentModel.DispatchTarget(
      mode: .anywhere, provider: engine.provider, model: engine.model, effort: engine.effort, actions: true, mac: true,
      relay: true, initiator: .relay)
    target.attached = attached
    let chat = threadID
    let profileID = team.activeID
    // The words the person wrote, as the turn will save them: in the chat from now (`outgoing`).
    var people: [AgentMessage] = (shown ?? (byPerson ? [prompt] : nil)).map { AgentMessage.written($0, attached: attached) } ?? []
    // A message sent again after a usage limit is already in the chat, with no reply under it:
    // the new AI app answers that bubble rather than a second copy of the same words.
    if request?.retried == true, let words = people.last?.text, Self.awaitsReply(words, in: transcript) {
      people = []
      target.written = []
    }
    let pressed = Date()
    outgoing = people.isEmpty ? nil : Outgoing(threadID: chat, messages: people, at: pressed)
    if let first = people.first {
      target.written = people
      sendPressed = (message: first.id, at: pressed)
    }
    Task {
      defer {
        sending = false
        outgoing = nil
      }
      // What this assistant remembers for these words rides in the turn's context.
      await prepareMemory(request: prompt, thread: chat, profileID: profileID)
      do {
        if let journal { browser.stepJournal.nextTurn(in: chat, is: journal, words: words) }
        defer { browser.stepJournal.settle(chat) }
        let id = try await agent.dispatch(prompt, into: chat, create: true, as: target)
        if cancelTurn, let run = agent.hub.run(for: id) {
          // What the user sent after the Stop still goes, once this turn has ended.
          redirecting = !pending.isEmpty
          agent.hub.stop(run)
        } else if !cancelTurn {
          // Held, failed and automatic turns do not count. Queued messages retain their own
          // origins even when several are delivered together in this turn.
          if userMessages > 0 { GuideCenter.shared.record(.messageReached) }
          for index in 0..<userMessages {
            HintCenter.shared.recordMessage(inWindow: index < windowMessages)
          }
        }
        cancelTurn = false
      } catch {
        turnPage = nil
        turnBrief = nil
        // A check-in that couldn't start is over: left set, the person's next message would count
        // as unattended and its approvals would be refused.
        proactiveTurn = false
        checkInTurn = false
        // Nothing started: what waited goes with the user's next message instead. This turn's
        // own documents were never staged, so their waiting files go now.
        ComposerContext.discard(attached.flatMap(\.filePaths), keeping: [])
        var carded = false
        if let kept = turnRequest, kept.held.id == requestID {
          turnRequest = nil
          // The assistant's AI app is missing or signed out: the person's message waits on a card
          // to connect it, in place of the plain line (ConnectNeed.aiApp).
          let words = error.localizedDescription
          if words == ConnectNeed.noAIApp || words == ConnectNeed.signedOut(engine.provider), kept.held.userMessage {
            showConnectCards(ConnectCards(threadID: kept.thread, request: kept.held, needs: [.aiApp(engine.provider)]))
            carded = true
          } else {
            Self.dropFiles(kept.held)
          }
        }
        // Words that could not start stay in the chat, marked Not sent, for Send again: nothing
        // holds them now.
        if !carded, let first = people.first {
          // A new chat's first message has no saved chat yet: this makes it, named as its turn would have.
          let title = String((first.text.isEmpty ? (first.attached?.first ?? "") : first.text).prefix(100))
          unsent = Set(people.filter { agent.postHostMessage($0, into: chat, title: title, provider: engine.provider) }.map(\.id))
        }
        // SPEC 2.4's failure line, with the reason in plain words or none (never system text).
        if !carded { lastError = TurnFailure.couldNotAnswer(team.activeName, reason: error.localizedDescription, app: engine.provider.name) }
      }
    }
  }
  /// The message turn now running, as it was sent, with the chat it went to (`turn`).
  private var turnRequest: (thread: String, held: Held)?
  /// The connections the person's last message needed and did not have, one card each under the
  /// reply (ConnectNeedCard), holding the message as it was sent. They stay until the next
  /// message, New chat or Continue; this launch only.
  struct ConnectCards: Equatable {
    let threadID: String
    let request: Held
    let needs: [ConnectNeed]
  }
  @Published private(set) var connectCards: ConnectCards?
  /// The connect cards of the chat on screen.
  var connectCardsHere: ConnectCards? { connectCards?.threadID == threadID ? connectCards : nil }
  /// Missing connections met by each chat's running turn, in order, each once (`noteNeed`).
  private var turnNeeds: [String: [ConnectNeed]] = [:]
  /// A tool refused because a connection is missing (BrowserModel.handle): one card per missing
  /// connection per turn, shown when the turn ends.
  func noteNeed(_ need: ConnectNeed, thread: String) {
    guard turnNeeds[thread]?.contains(need) != true else { return }
    turnNeeds[thread, default: []].append(need)
  }
  private func showConnectCards(_ cards: ConnectCards) {
    clearConnectCards()
    connectCards = cards
  }
  /// The cards go, and the documents their message kept with them.
  private func clearConnectCards() {
    if let cards = connectCards { Self.dropFiles(cards.request) }
    connectCards = nil
  }
  /// Continue, on a connect card: the same message goes again once, as a new message of the
  /// person's, with what it carried. It is a new turn; on a warm thread it keeps that thread's
  /// capability, which holds no earlier answer, so every step asks again and no send or write
  /// of the earlier turn is carried or resumed. A reply still running is not cut: the message
  /// waits for it.
  func continueAfterConnect(byPerson: Bool = true) {
    guard let cards = connectCards, cards.threadID == threadID else { return }
    // A step of this message has an unknown outcome: it never goes again by itself, and the card
    // waits for Continue (the step asks then, `StepJournal`).
    if !byPerson, case .waits = browser.stepJournal.resend(request: cards.request.id) { return }
    // Its documents go with the message now, so they are not dropped with the cards.
    connectCards = nil
    let item = cards.request
    ask(item.message.text, attachments: item.attachments, interrupt: false, page: item.page, inWindow: item.inWindow,
        userMessage: true, request: item.id)
  }
  /// A copy of each attached document in the waiting folder: the turn's start deletes the waiting
  /// files it staged, and a held turn goes again with the same documents. nil, with nothing left
  /// behind, when a copy cannot be made (the turn is then never held).
  private static func keptCopy(_ attachments: [SereinAttachment]) -> [SereinAttachment]? {
    var kept: [SereinAttachment] = []
    for var attachment in attachments {
      if var document = attachment.document {
        let source = URL(fileURLWithPath: document.path)
        do {
          let copy = try ComposerContext.attachmentURL(
            name: "document", extension: source.pathExtension.isEmpty ? "bin" : source.pathExtension)
          try FileManager.default.copyItem(at: source, to: copy)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
          document.path = copy.path
          attachment.document = document
        } catch {
          ComposerContext.discard(kept.flatMap(\.filePaths), keeping: [])
          return nil
        }
      }
      if var picture = attachment.picture {
        let source = URL(fileURLWithPath: picture.path)
        do {
          let copy = try ComposerContext.attachmentURL(
            name: "picture", extension: source.pathExtension.isEmpty ? "jpg" : source.pathExtension)
          try FileManager.default.copyItem(at: source, to: copy)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
          picture.path = copy.path
          attachment.picture = picture
        } catch {
          // The copy of this chip's document, made just above, goes too.
          ComposerContext.discard(kept.flatMap(\.filePaths) + [attachment.document?.path].compactMap { $0 }, keeping: [])
          return nil
        }
      }
      kept.append(attachment)
    }
    return kept
  }
  /// Deletes a held or kept message's own document files.
  private static func dropFiles(_ item: Held) {
    ComposerContext.discard(item.attachments.flatMap(\.filePaths), keeping: [])
  }
  /// Serein keeps one conversation: nothing in the app starts another. This replaces it only when
  /// the person deleted it (`force`, even mid-turn: a running chat cannot be deleted) and for the
  /// checks; the old one stays in Serein's threads (and in `pastThreadIDs`, so it is still known
  /// as Serein's).
  func newChat(force: Bool = false) {
    guard force || !working else { return }
    cancelWelcome()
    SereinChatSetup.shared.cancelPending(self)
    // The current chat was deleted: its usage-limit holds go with it, and what was learned in it.
    if force {
      let gone = state.threadID
      for item in held where item.message.threadID == gone { discardHeld(item.id) }
      forgetChatMemory(gone)
    }
    // A deleted chat, or one with nothing in it, is not worth going back to.
    state.pastThreadIDs = SereinChat.past(
      state.pastThreadIDs ?? [], leaving: state.threadID, keep: !force && hasMessages(state.threadID))
    state.threadID = UUID().uuidString
    // The pages Relay read from the page chip belonged to the chat left (or deleted).
    CollectedPages.forget(owners: [CollectedPages.relayOwner])
    turnPage = nil
    turnBrief = nil
    knownCache = nil
    // Messages left waiting in the chat left never go: their document files go now.
    dropPending()
    clearConnectCards()
    reminderNotice = nil
    stopNotice = nil
    answered = []
    save()
  }
  /// The report turn for a finished delegated run — what the decider can choose to hold.
  fileprivate func reportFinished(_ run: AgentRun, outcome: RunRecord.Outcome) {
    let title = String(run.spec.title.prefix(120))
    turn("A run you delegated finished (\(outcome.rawValue)): run \(run.spec.threadID), “\(title)”. Check it with agent_status and tell me the result in one or two sentences.")
  }
  /// A turn Serein starts on its own in the active assistant's chat (a hand-off's result): never
  /// the person's, so it is the lower trust class.
  func startOwnTurn(_ prompt: String) { turn(prompt) }
  /// The messages that waited for the chat go as one turn, once it is free: after a turn ends, or
  /// after a hand-off that was being dispatched into it failed to start. `interrupted`: they
  /// stopped the turn before.
  func sendPending(interrupted: Bool = false) {
    guard !working, !pending.isEmpty else { return }
    let words = RelaySteering.prompt(pending)
    let shown: [String] = pending.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let next = (interrupted ? "I interrupted you. Keep the work already done and continue with this:\n" : "") + words
    let attached = pendingContext.flatMap(\.attachments)
    let page = pendingContext.last?.page
    let userMessages = pendingContext.filter(\.userMessage).count
    let windowMessages = pendingContext.filter { $0.userMessage && $0.inWindow }.count
    // Only the person's words make it their turn: a paired-app request riding along does not.
    let byPerson = userMessages > 0 && pendingContext.allSatisfy(\.userMessage)
    // The person's words as kept for sending again (a usage-limit hold, a connect card's
    // Continue): without the lead-in, which only this live turn needs.
    // One message that waited keeps the request it was sent again as; several are a new one.
    let same: String? = pendingContext.count == 1 ? pendingContext[0].request : nil
    let request = Held(message: HeldMessage(id: same ?? UUID().uuidString, text: shown.joined(separator: "\n"), at: Date(),
                                            reason: .usageLimit), attachments: attached,
                       page: page, inWindow: windowMessages > 0, userMessage: byPerson,
                       retried: pendingContext.contains(where: \.retried))
    let trail = ScreenTrailWatch.enabled ? pendingContext.compactMap(\.trail).last : nil
    pending = []
    pendingContext = []
    if byPerson { noteCorrection(shown.joined(separator: " "), thread: threadID) }
    // A turn carrying a paired app's request is not held (`holdLimited`).
    turn(next, attached: attached + [trail].compactMap { $0 }, page: page, userMessages: userMessages, windowMessages: windowMessages,
         byPerson: byPerson, request: byPerson ? request : nil, shown: shown)
  }
  private func ended(_ run: AgentRun) {
    // Whatever ended, a queued scheduled turn may go now (its owner's chat may be free).
    defer { drainScheduled() }
    noteSecureCard(run)
    // Get to know you ended: the check-ins card comes next, whatever the reply said. While they
    // are on (the default) it says so, with what they do.
    if checkInsAfterTurn == run.spec.threadID {
      checkInsAfterTurn = nil
      if !dismissedSetupOffersHere.contains(.checkIns) { offerSetup(.checkIns) }
    }
    // Host messages that waited for a chat to be idle go in now (RelayAssistantTools.swift).
    flushHostPosts()
    // A light ask's hidden run: its answer goes back to the asker, and nothing else here
    // concerns it (RelayAsks.swift).
    if finishAsk(run) { return }
    let needs = turnNeeds.removeValue(forKey: run.spec.threadID) ?? []
    // Another assistant spoke first in its own chat: its word, if any, reaches the person, and
    // nothing else here concerns it (it is not work that failed or succeeded).
    let spoke = finishSpeakingElsewhere(run)
    if spoke, run.spec.threadID != threadID {
      // Its word, if any, is unread on its row until its chat is opened.
      if Self.landsWords(run), let speaker = assistantOwning(thread: run.spec.threadID) {
        noteReplyLanded(profileID: speaker, thread: run.spec.threadID)
      }
      return
    }
    // Work that succeeded ends its assistant's failure streak (one notice per streak).
    if !spoke, !run.spec.relay, run.record.outcome == .done { workSucceeded(owner: workOwner(run)) }
    // A handed-over task's run: its result goes back to the asking chat. On another assistant's
    // chat nothing else here concerns it.
    if finishHandoff(run), run.spec.threadID != threadID {
      // The hand-off's result is in its assistant's chat: unread on its row.
      if Self.landsWords(run), let target = assistantOwning(thread: run.spec.threadID) {
        noteReplyLanded(profileID: target, thread: run.spec.threadID)
      }
      return
    }
    // A scheduled turn that ran in its owner's own chat (`drainScheduled`).
    if let owner = ownerRun, owner.thread == run.spec.threadID, run.spec.relay {
      endOwnerRun(run, needs: needs)
      return
    }
    defer {
      if run.spec.threadID == threadID || isChild(run.spec.threadID) { HintCenter.shared.recordTurnEnded() }
    }
    // The message turn this run answered, as it was sent: the usage limit may hold it.
    var request: Held?
    if let kept = turnRequest, kept.thread == run.spec.threadID, run.spec.relay, run.spec.initiator == .relay {
      turnRequest = nil
      request = kept.held
    }
    var limited = false
    // The message is kept on its connect cards (`connectCards`).
    var carded = false
    defer { if !limited, !carded, let request { Self.dropFiles(request) } }
    // A reply in a chat no longer on screen: its tags leave its words all the same.
    if run.spec.relay, run.spec.threadID != threadID {
      agent.amendThread(run.spec.threadID) { Self.landReplyTags(in: &$0) }
    }
    if run.spec.threadID == threadID {
      turnPage = nil
      turnBrief = nil
      objectWillChange.send()
      // This turn's receipts, system lines and answers land on its reply (RelayAssistantTools.swift).
      if run.spec.relay { landTurnFacts(run) }
      // The person's third such request: the reply offers a routine (RelayRoutineOffers.swift).
      if run.spec.relay { offerRoutineIfDue(run) }
      // A turn in the active assistant's chat (the person's, a link's or routine's, a late
      // answer's, a hand-off result's): unread when that chat is not on screen.
      if run.spec.relay, Self.landsWords(run) { noteReplyLanded(profileID: team.activeID, thread: run.spec.threadID) }
      turnMemory = nil
      turnRules = nil
      turnCorrection = nil
      // A scheduled turn in another assistant's chat ends in `endOwnerRun`, not here. Its ledger
      // row (a link's too) is finished or failed (`finishWork`).
      let scheduled: ScheduledTurn? = ownerRun == nil ? activeScheduled : nil
      if scheduled != nil { activeScheduled = nil }
      // The person's reply used its whole step budget: the line, with Resume, under it.
      if run.spec.relay, scheduled == nil, let limit = run.stepLimit { stopNotice = .steps(limit) }
      limited = holdLimited(run, request: request, scheduled: scheduled)
      if !limited, scheduled == nil { pressAnswered(run) }
      if let scheduled { finishWork(scheduled, run: run, held: limited) }
      if let scheduled, !limited {
        if let watch = scheduled.watchID { countWatchTurn(watch, tokens: run.record.tokens) }
        handleScheduled(scheduled.reminder, run: run)
      }
      // The AI app said it is signed out: its connect card holds the message, which goes once
      // after the sign-in (`continueSignedIn`). What waited behind it waits for the sign-in too.
      // A message Serein moved off a usage limit that fails on the next app too (signed out, an
      // expired sign-in, any error) moves on again rather than stopping there (`moveOnAfterFailure`).
      if !limited, run.record.outcome == .stuck, let request, moveOnAfterFailure(run, request: request) {
        carded = true
      } else if !limited, run.signedOut, let request, request.userMessage {
        showConnectCards(ConnectCards(threadID: run.spec.threadID, request: request, needs: [.aiApp(run.spec.provider)]))
        carded = true
      }
      if run.signedOut { holdPendingSignedOut(thread: run.spec.threadID) }
      // OpenCode refused its key: one card under the failure line takes a new one, holding the
      // message, which goes once after Save (`OpenCodeKeyCard`).
      if !limited, !carded, let request, request.userMessage, let failure = OpenCodeKey.failure(run) {
        showConnectCards(ConnectCards(threadID: run.spec.threadID, request: request,
                                      needs: [.aiKey(run.spec.provider, model: run.spec.model, failure)]))
        carded = true
      }
      // A connection the person's message needed was missing: a card for each under the reply.
      if !limited, !carded, !needs.isEmpty, run.record.outcome != .stopped, let request, request.userMessage {
        showConnectCards(ConnectCards(threadID: run.spec.threadID, request: request, needs: needs))
        carded = true
      }
      // Relay spoke first and had something to say: a notification when the user is elsewhere.
      if proactiveTurn, run.record.outcome == .done,
        let reply = run.transcript.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
        !reply.isEmpty, !RelayProactive.isNothing(reply)
      {
        // Its ideas wait in Activity until done or set aside. The notification holds names and
        // counts only (SPEC I14): the reply and its ideas, which can hold words from mail, stay in
        // the chat and Activity.
        let found = RelayProactive.ideas(in: reply)
        if !found.isEmpty {
          ideas = Array((ideas.filter { idea in !found.contains { $0.id == idea.id } } + found).suffix(6))
        }
        let name: String = team.profiles.count > 1 ? team.activeName : RelayTeam.mainName
        noticeProactive(thread: threadID, title: name, body: Self.ideasBody(name, count: found.count))
      }
      proactiveTurn = false
      checkInTurn = false
      let redirected = redirecting
      redirecting = false
      // What waited for a turn the limit stopped is held with it, never sent into that limit.
      if limited, let limit = run.usageLimit { holdPending(limit, app: run.spec.provider.name, thread: run.spec.threadID) }
      if !pending.isEmpty, run.record.outcome != .stopped || redirected {
        sendPending(interrupted: redirected)
      } else {
        personTurn = false
        drainScheduled()
      }
    } else if !run.spec.relay, [.stuck, .waiting].contains(run.record.outcome), !isChild(run.spec.threadID) {
      // Any other run in Serein that failed or waits for the user: Relay may bring it up.
      let outcome: String = run.record.outcome == .stuck ? "failed" : "is waiting for the user"
      let reason: String = run.error.map { ": \(String($0.prefix(300)))" } ?? ""
      let detail: String = "\(run.spec.provider.name) run “\(String(run.spec.title.prefix(100)))” \(outcome)\(reason)"
      attention.append((run.spec.threadID, detail, workOwner(run)))
      if attention.count > 20 { attention.removeFirst(attention.count - 20) }
    }
    if !run.spec.relay, [.done, .stuck, .stopped].contains(run.record.outcome) {
      HintCenter.shared.recordTaskFinished(threadID: run.spec.threadID)
    }
    if !run.spec.relay, run.record.outcome == .done, !isChild(run.spec.threadID) {
      SessionStatusTexts.shared.taskFinished(run)
    }
    if isChild(run.spec.threadID) {
      objectWillChange.send()
      let outcome = run.record.outcome
      note("\(run.spec.provider.name) finished “\(String(run.spec.title.prefix(60)))”: \(outcome.rawValue.replacingOccurrences(of: "_", with: " "))",
           outcome == .done ? .auto : .user)
      // Relay tells the user what came of it, unless it is already working (it may be waiting
      // on this run) or the user stopped it. With the decider available and the panel closed,
      // a routine success can wait in the activity list instead of spending a turn (fail-open).
      if outcome != .stopped, reportsFinishedWork, !working, !state.paused {
        let summary = run.reportedSummary
          ?? run.transcript.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text ?? ""
        let visible = panelVisible()
        Task { [weak self] in
          guard let self else { return }
          guard let triage = await RelayDecider.triageFinishedReport(
            summary: summary, outcome: outcome.rawValue, panelVisible: visible),
            triage.hold
          else {
            self.reportFinished(run, outcome: outcome)
            return
          }
          self.note("Held the finished-run report for later", .auto)
        }
      }
    }
  }

  // MARK: what Relay did

  /// One line of what Relay or its runs did, newest last; the last 100 are kept in Relay's
  /// private folder so they are there after a restart (the agent-history ledger is the full record).
  struct Activity: Identifiable, Codable {
    enum How: String, Codable { case auto = "on its own", allowed = "you allowed", declined = "you declined", refused = "not allowed", user = "" }
    var id = UUID()
    var at = Date()
    let text: String
    let how: How
  }
  @Published private(set) var activity: [Activity] = []
  func note(_ text: String, _ how: Activity.How) {
    activity.append(Activity(text: String(text.prefix(160)), how: how))
    if activity.count > 100 { activity.removeFirst(activity.count - 100) }
    persist(activity, "relay/activity.json")
  }
  static func how(_ decision: AgentHistoryEvent.Decision) -> Activity.How {
    switch decision {
    case .allowedByAutopilot: return .auto
    case .allowedOnce, .alwaysAllowed: return .allowed
    case .denied: return .declined
    }
  }
  static let reportsKey = "serein.relay.reportsFinishedWork"
  /// Relay reports each delegated run when it finishes (one short turn each); on by default.
  var reportsFinishedWork: Bool {
    get { UserDefaults.standard.object(forKey: Self.reportsKey) as? Bool ?? true }
    set {
      objectWillChange.send()
      UserDefaults.standard.set(newValue, forKey: Self.reportsKey)
    }
  }
  /// Learning from quiet chats (SPEC 4.6, `serein.memory.learns` in the gate file): on unless the
  /// person turned it off (Settings › Serein › “Learn from your chats”, or by typing). Each
  /// capture is one request to the person's AI app, at most `RelayLearning.perHour` an hour and
  /// `perDay` a day.
  static let learnsKey = "serein.memory.learns"
  var learnsNotes: Bool {
    get {
      #if DEBUG
      if let learnsOverride { return learnsOverride }
      #endif
      if let chosen = GateSettings.shared.object(forKey: Self.learnsKey) as? Bool { return chosen }
      // An unreadable gate file reads closed (SPEC 8.1, I13): the person's "off" may be in it.
      if GateSettings.shared.unreadable { return false }
      // The old switch (`AssistantMigration.learnsKey`) set to off stays off: on is only the
      // default for an install that never had it.
      return UserDefaults.standard.object(forKey: AssistantMigration.learnsKey) as? Bool ?? true
    }
    set {
      objectWillChange.send()
      GateSettings.shared.set(newValue, forKey: Self.learnsKey)
      if !newValue {
        capture?.cancel()
        capture = nil
      }
    }
  }

  // MARK: learning notes from conversations

  /// The clock's step for learning (memory unit 6b): one capture at a time reads one chat that
  /// has been quiet for `RelayLearning.idleBeforeCapture` and changed since its last capture
  /// (`distilCandidate`), and proposes a few notes, private to the chat's assistant and
  /// unreviewed. Proposals show only when the person asks what Serein remembers. Quiet failure
  /// throughout: learning is opportunistic and never surfaces an error.
  private func learnIfIdle(now: Date) {
    guard learnsNotes, !state.paused, !working, capture == nil, memory != nil else { return }
    guard RelayLearning.mayCapture(after: memoryShell.captures ?? [], now: now) else { return }
    guard let pick = distilCandidate(now: now) else { return }
    var shell = memoryShell
    shell.captures = ((shell.captures ?? []) + [now]).filter { now.timeIntervalSince($0) < 86_400 }
    var done = shell.distilled ?? [:]
    done[pick.chat] = pick.lastID
    // The watermarks of chats that are gone go too.
    if done.count > 400 {
      let live = Set(agent.conversations.map(\.id))
      done = done.filter { live.contains($0.key) }
    }
    shell.distilled = done
    memoryShell = shell
    persist(shell, MemoryShellState.path)
    capture = Task { [weak self] in
      await self?.learn(chat: pick.chat, owner: pick.owner, messages: pick.messages)
      self?.capture = nil
    }
  }
  /// The chat the next capture reads: the active assistant's chat on screen and its recent past
  /// chats, and each other assistant's Main chat, when quiet long enough and changed since its
  /// last capture (`RelayLearning.isDue`); the most recently active one first. A chat that is
  /// running now waits.
  private func distilCandidate(now: Date)
    -> (chat: String, owner: String, lastID: String, messages: [AgentMessage])?
  {
    var chats: [(chat: String, owner: String)] = [(chat: threadID, owner: team.activeID)]
    for id in (state.pastThreadIDs ?? []).suffix(20).reversed() { chats.append((chat: id, owner: team.activeID)) }
    for profile in team.profiles where profile.id != team.activeID {
      if let main = knownMainThread(of: profile.id) { chats.append((chat: main, owner: profile.id)) }
    }
    let done = memoryShell.distilled ?? [:]
    var best: (chat: String, owner: String, lastID: String, messages: [AgentMessage], at: Date)?
    for item in chats {
      guard agent.hub.run(for: item.chat) == nil,
        let saved = agent.conversations.first(where: { $0.id == item.chat }), let last = saved.messages.last
      else { continue }
      let lastAt: Date = saved.lastMessageAt ?? saved.updatedAt
      guard RelayLearning.isDue(lastID: last.id, lastAt: lastAt, learnedThrough: done[item.chat], now: now) else { continue }
      if let current = best, current.at >= lastAt { continue }
      best = (chat: item.chat, owner: item.owner, lastID: last.id, messages: saved.messages, at: lastAt)
    }
    guard let best else { return nil }
    return (chat: best.chat, owner: best.owner, lastID: best.lastID, messages: best.messages)
  }
  /// One capture of `chat` for `owner`: its proposals are learned records, private to the owner,
  /// with the chat's personal-read mark and id (for the chat-delete cascade). One the person forgot
  /// or declined before is refused by its tombstone.
  private func learn(chat: String, owner: String, messages: [AgentMessage]) async {
    guard learnsNotes, !state.paused else { return }
    // Serein's own notices (a job's end, with fenced output) and the turns it started itself (a
    // schedule, an alert, a webhook: untrusted text, never the person's words) are not anyone's
    // words to learn from.
    let spoken = RelayAutomatic.personTurns(messages.filter { $0.notice != true }, role: \.role, text: \.text)
    let conversation = RelayLearning.excerpt(spoken.map { message in
      (message.role == "assistant" ? "Serein" : "user", message.text)
    })
    guard conversation.contains(where: { $0.hasPrefix("user: ") }) else { return }
    // Notes with the personal-read mark stay out of the request (the chat itself goes, as before,
    // to the person's own AI app).
    let known = await memoryTexts(owner: owner)
    let now = RelayToolHost.stamp(Date())
    guard let reply = try? await agent.helperRequest(
      RelayLearning.prompt(conversation: conversation, existing: known.unmarked, now: now))
    else { return }
    let fresh = RelayLearning.records(
      RelayLearning.decode(reply), by: owner, chat: chat, personal: agent.readsPersonal(thread: chat), known: known.all,
      waiting: known.waiting, said: conversation)
    guard !fresh.isEmpty else { return }
    let added = await addProposals(fresh)
    guard added > 0 else { return }
    note("Learned \(added) idea\(added == 1 ? "" : "s") from a quiet chat", .auto)
  }
  /// The user kept a proposal. A learned one becomes a kept note of its assistant, still private
  /// to it (`reviewProposal`). A tidy one joins the notes like one Relay was told to remember and
  /// retires the notes it replaces — all one change, so one journal entry shows both.
  func keep(_ proposal: RelayNote) {
    guard tidyProposals.contains(where: { $0.id == proposal.id }) else {
      Task { [weak self] in _ = await self?.reviewProposal(proposal.id, keep: true) }
      note("Kept the learned note “\(String(proposal.text.prefix(60)))”", .user)
      return
    }
    updateNotes(actor: "learning") { notes in
      if let made = try? RelayMemory.remember(proposal.text, quote: proposal.quote, in: &notes, expires: proposal.expires) {
        // Tidy read only notes without the personal-read mark, so its merge has none.
        if noteMarks[made.id] == nil { noteMarks[made.id] = false }
      }
      for id in proposal.replaces ?? [] { RelayMemory.forget(id, in: &notes) }
    }
    updateProposals { $0.removeAll { $0.id == proposal.id } }
    note("Kept the learned note “\(String(proposal.text.prefix(60)))”", .user)
  }
  /// The user discarded a proposal. A learned one leaves a digest (`MemoryTombstone`), so
  /// learning never proposes that fact again.
  func discard(_ proposal: RelayNote) {
    guard tidyProposals.contains(where: { $0.id == proposal.id }) else {
      Task { [weak self] in _ = await self?.reviewProposal(proposal.id, keep: false) }
      return
    }
    updateProposals { $0.removeAll { $0.id == proposal.id } }
  }
  /// Changes the tidy proposals (the profile's proposals.json, from builds that ran a model pass
  /// over the notes); the review list follows.
  func updateProposals(_ change: (inout [RelayNote]) -> Void) {
    let before = Set(tidyProposals.map(\.id))
    var copy = tidyProposals
    change(&copy)
    tidyProposals = copy
    persist(copy, dir + "/proposals.json")
    proposals = proposals.filter { !before.contains($0.id) } + copy
  }

  // MARK: memory tidy

  /// About once a day: exact duplicates collapse on their own (one journal entry). Host rules
  /// only: a model never rewrites facts (SPEC 4.8), so no model pass proposes merges any more.
  func tidyIfDue(now: Date = Date()) {
    guard !state.paused, !working,
      notes.count >= RelayTidy.minimum,
      state.lastTidied.map({ now.timeIntervalSince($0) < RelayTidy.interval }) != true
    else { return }
    state.lastTidied = now
    save()
    // Exact duplicates: the oldest copy wins, the rest go — plain bookkeeping, no model.
    let dupes = RelayTidy.duplicates(in: notes)
    guard !dupes.isEmpty else { return }
    let ids = Set(dupes.flatMap { $0.map(\.id) })
    updateNotes(actor: "tidy") { notes in notes.removeAll { ids.contains($0.id) } }
    note("\(ids.count) duplicate note\(ids.count == 1 ? "" : "s") collapsed", .auto)
  }

  // MARK: kill switch

  /// Stops Relay's turn and every run it started; `pause` also holds its scheduled requests
  /// until the user sends Relay a message (the kill switch).
  func stopEverything(pause: Bool) {
    research.pauseAll()
    cancelWelcome(suppress: true)
    SereinChatSetup.shared.cancelPending(self)
    turnPage = nil
    turnBrief = nil
    dropPending()
    // Queued and running scheduled turns end in the work ledger too, so none comes back at the
    // next launch; a write still landing is dropped when it lands (`workEpoch`).
    workEpoch += 1
    interruptedWork = nil
    oneTimeGrants = []
    for turn in scheduledQueue { dropWork(turn, note: "Stop Everything removed it before it ran.") }
    scheduledQueue = []
    if let active = activeScheduled { failWork(active, note: "Stop Everything stopped it.") }
    activeScheduled = nil
    if sending { cancelTurn = true }
    if let owner = ownerRun, let other = agent.hub.run(for: owner.thread) { agent.hub.stop(other) }
    ownerRun = nil
    ownerPersona = nil
    capture?.cancel()
    capture = nil
    if let run { agent.hub.stop(run) }
    for run in childRuns where run.isActive { agent.hub.stop(run) }
    stopHandoffs()
    // Light asks stop too (RelayAsks.swift); link turns are scheduled turns, so their ledger
    // rows ended above.
    stopAsks()
    for approval in approvals { approval.answer(.no) }
    approvals = []
    // An approval that moved to an alert is declined too.
    MacApproval.declineAll()
    finishConsent(proceed: false)
    if pause {
      if !state.paused { stoppedSince = Date() }
      state.paused = true
      stopNotice = .everything
      save()
    }
  }
  func resume() {
    state.paused = false
    if stopNotice == .everything { stopNotice = nil }
    save()
  }

  // MARK: questions (ask_user)

  /// Puts a form in the panel and waits; nil when nobody answered within the timeout. When the
  /// panel is hidden, a notification brings it up.
  func ask(_ title: String, _ questions: [RelayQuestion]) async -> [String: String]? {
    // Inside a socket call the form closes before the caller stops waiting (SocketCall): an
    // answer after that would reach nobody.
    let life: TimeInterval
    if let call = SocketCall.live {
      guard let left = call.cardWindow().cardLife(RelayAsk.timeout, now: Date()) else { return nil }
      life = left
    } else {
      life = RelayAsk.timeout
    }
    return await withCheckedContinuation { continuation in
      Task { @MainActor in
        var settled = false
        // A closure literal keeps the task's main-actor isolation; a local func would not.
        let finish = { [weak self] (answers: [String: String]?) in
          guard let self, !settled else { return }
          settled = true
          continuation.resume(returning: answers)
          self.objectWillChange.send()
          self.questionForms.removeAll { $0.title == title && $0.questions == questions }
        }
        let form = QuestionForm(
          title: title, questions: questions, after: self.transcript.last(where: { $0.role == "you" })?.id,
          threadID: self.threadID
        ) { answers in
          finish(answers)
        }
        questionForms.append(form)
        // Wherever the user is, as an approval is: inline, the bar, the slim line, or only a
        // notification over a full-screen app.
        let placement = answerPlacement()
        if placement == .notificationOnly || placement == .alert { deferred.insert(form.id) }
        if placement.showsBar { showForAnswer() }
        if placement.notifies || placement == .alert { notifyAsks(form) }
        Task { [weak self] in
          try? await Task.sleep(nanoseconds: UInt64(life * 1_000_000_000))
          guard let self else { return }
          self.finishForm(form)
        }
      }
    }
  }
  /// The timeout side of ask(): called on the main actor after the wait.
  fileprivate func finishForm(_ form: QuestionForm) {
    form.answer([:])
  }
  /// “Serein asks”, once per question, while the user is in another app.
  private func notifyAsks(_ form: QuestionForm) {
    guard Self.persists, !NSApp.isActive, notifiedCards.insert(form.id).inserted else { return }
    TaskNotifications.shared.post(threadID: threadID, title: "Serein asks", body: form.title, always: true, kind: .ask)
  }
  /// “Serein needs your OK” for the one-time card, once while it waits, out of view.
  private func notifyConsent(thread: String?) {
    guard Self.persists, !NSApp.isActive, consentWaiting, !consentNotified else { return }
    consentNotified = true
    TaskNotifications.shared.post(threadID: thread ?? threadID, title: "Serein needs your OK", body: ApprovalLevel.consentTitle,
                                  asks: true, kind: .ask)
  }
  /// The panel handed the answers in; the chat keeps them as the person's reply.
  func answer(_ form: QuestionForm, _ answers: [String: String]) {
    questionForms.removeAll { $0.id == form.id }
    deferred.remove(form.id)
    let kept = AnsweredQuestion(id: form.id, items: Self.answeredItems(form.questions, answers), at: Date(),
                                threadID: form.threadID, after: form.after)
    answeredQuestions = Array((answeredQuestions + [kept]).suffix(30))
    form.answer(answers)
  }
  /// Each question with its answer as the chip shows it: a choice's title, the columns as given.
  nonisolated static func answeredItems(_ questions: [RelayQuestion], _ answers: [String: String]) -> [AnsweredQuestion.Item] {
    questions.map { question in
      let text = answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let shown = text.isEmpty ? nil : (question.columns == nil ? RelayAsk.split(text).title : text)
      return AnsweredQuestion.Item(question: question.label, answer: shown, choices: question.choices)
    }
  }
  /// A chip's answer changed after Serein moved on: the turn already has the old one, so the new
  /// one goes as the person's next message, and the chip shows it.
  func changeAnswer(_ answered: AnsweredQuestion, at index: Int, to value: String) {
    let words = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard answered.items.indices.contains(index), !words.isEmpty, words != answered.items[index].answer,
          let at = answeredQuestions.firstIndex(where: { $0.id == answered.id }) else { return }
    let item = answered.items[index]
    guard ask("Change my answer to \u{201C}\(item.question)\u{201D}: \(words)") else { return }
    var items = answered.items
    items[index] = AnsweredQuestion.Item(question: item.question, answer: RelayAsk.split(words).title, choices: item.choices)
    var updated = answeredQuestions
    updated[at] = AnsweredQuestion(id: answered.id, items: items, at: answered.at, threadID: answered.threadID, after: answered.after)
    answeredQuestions = updated
  }
  /// The one waiting question the window's composer answers (RelayAsk.composerAnswers), if any.
  var composerQuestion: QuestionForm? {
    guard questionForms.count == 1, let form = questionForms.first, RelayAsk.composerAnswers(form.questions) else { return nil }
    return form
  }
  /// Words sent from the composer while one question waits answer it, as the person's reply.
  func answerFromComposer(_ text: String) -> Bool {
    guard let form = composerQuestion, let question = form.questions.first else { return false }
    answer(form, [question.id: text])
    return true
  }
  /// What a message box does with the words sent from it (`MessagePlan`): the window's composer,
  /// the dock and the bar all ask here before anything leaves. `answersQuestion` is off for the
  /// bar: its words are always a new message, and a waiting question has its own card under it.
  func messagePlan(_ typed: String, hasAttachments: Bool, answersQuestion: Bool = true) -> MessagePlan {
    MessagePlan.of(
      typed, hasAttachments: hasAttachments, shortcuts: ShortcutBook.shared.shortcuts,
      mentionRefusal: mentionRefusal(typed), questionWaits: answersQuestion && composerQuestion != nil)
  }

  // MARK: approvals

  /// Asks the user, wherever they are (`ApprovalPlacement`): inline in Serein's chat while it is
  /// on screen; in the ⌥Space bar while it is up; in the chat with the slim line while Serein's
  /// window is in front; else in the bar without taking the keyboard, with a notification (only
  /// the notification over a full-screen app). The alert is the last resort, when no screen can
  /// show the bar. `thread` is the asking run's thread; `app` names the Mac app a script reaches,
  /// for the Automation line; `more` is the exact script (or a plugin's arguments, `moreName`
  /// “the details”), shown on request, or open with `moreOpen` (a page tool's exact arguments);
  /// `picture` is a screenshot with the spot marked (click_point), shown on the card or the alert.
  /// Nothing switches the main view by itself.
  /// Returns the person's HumanAnswer. A card that times out is removed and returns .timeout,
  /// which callers treat as needing a person: nothing runs.
  /// Inside a tool call the journal hears a yes before the step runs (StepJournal.Live): the
  /// step is written down first, and a yes that cannot be written down is no answer. A step
  /// that asks because its earlier outcome is unknown says so on its card.
  func confirmAnswer(_ title: String, _ detail: String, button: String = "Allow", decline: String = "Decline",
                     thread: String?, more: String? = nil, moreName: String = "the script", app: String? = nil,
                     site: String? = nil, moreOpen: Bool = false, picture: NSImage? = nil,
                     effect: ApprovalGate.Effect? = nil, proposal: TeamProposalDraft? = nil,
                     grants: Approval.GrantOffer? = nil,
                     routine: Bool = false, aboutSerein: Bool = false) async -> ApprovalGate.HumanAnswer {
    let live = StepJournal.live
    let human = await cardAnswer(
      title, live?.stuck == nil ? detail : detail + " " + StepJournal.unknownLine, button: button, decline: decline,
      thread: thread, more: more, moreName: moreName, app: app, site: site, moreOpen: moreOpen, picture: picture,
      effect: effect, proposal: proposal, grants: grants, routine: routine, aboutSerein: aboutSerein)
    if human == .yes, let live, !live.allowed() { return .error }
    return human
  }
  private func cardAnswer(_ title: String, _ detail: String, button: String, decline: String,
                          thread: String?, more: String?, moreName: String, app: String?,
                          site: String?, moreOpen: Bool, picture: NSImage?,
                          effect: ApprovalGate.Effect?, proposal: TeamProposalDraft?,
                          grants: Approval.GrantOffer?,
                          routine: Bool, aboutSerein: Bool) async -> ApprovalGate.HumanAnswer {
    #if DEBUG
    if let confirmOverride {
      return ActionAdmission.AskTimeout.settle(answered: confirmOverride(title, detail), timedOut: false)
    }
    #endif
    let exact = RelayDeferred.Action(
      title: title, detail: detail, more: more, app: app, site: site, effect: effect?.rawValue, thread: thread ?? threadID)
    if RelayDeferred.consume(exact, from: &oneTimeGrants, now: Date()) {
      note("Allowed earlier on its card: \(title)", .allowed)
      return .yes
    }
    // The person declined this exact step since their last message: the run does not ask again.
    if refusesRetry(title: title, detail: detail, thread: thread) { return .no }
    // A run nobody watches does not wait on a card: the card stays, the step does not run now,
    // and Allow queues this exact step again in the same chat.
    if activeScheduled != nil || checkingIn, exact.thread == (ownerRun?.thread ?? threadID), proposal == nil,
      grants == nil
    {
      let owner: String? = activeScheduled.map(\.profileID)
        ?? (team.activeID == team.mainProfileID ? nil : team.activeID)
      deferAsk(exact, owner: owner, button: button, decline: decline, moreName: moreName,
               moreOpen: moreOpen, picture: picture, effect: effect)
      return .timeout
    }
    // The run that asks, taken before any wait: its card is noted in its own turn only.
    let asker = thread.flatMap { agent.hub.run(for: $0) }
    let automation = await automationState(app)
    let placement = answerPlacement()
    if placement == .alert {
      let human = await alertAnswer(title: title, detail: detail, button: button, decline: decline, more: more,
                                    app: app, automation: automation.state, live: automation.live, thread: thread,
                                    picture: picture)
      record(title: title, human: human, thread: thread, asker: asker, button: button)
      return human
    }
    // Inside a socket call the card closes before the caller stops waiting (SocketCall).
    let call = SocketCall.live
    let life: TimeInterval
    if let call {
      guard let left = call.life(RelayAsk.timeout) else { return .timeout }
      life = left
    } else {
      life = RelayAsk.timeout
    }
    final class Once { var done = false }
    let once = Once()
    return await withCheckedContinuation { c in
      let id = UUID()
      let approval = Approval(id: id, title: title, detail: detail, button: button, decline: decline, threadID: thread,
                              more: more, moreName: moreName, moreOpen: moreOpen, app: app, site: site,
                              automation: automation.state,
                              automationLive: automation.live, picture: picture, effect: effect,
                              proposal: proposal, grants: grants, routine: routine, aboutSerein: aboutSerein) { [weak self] given in
        guard !once.done else { return }
        once.done = true
        let human = call?.settle(given) ?? given
        if human != given { ApprovalEnds.shared.end(id, .unanswered) }
        c.resume(returning: human)
        guard let self else { return }
        self.approvals.removeAll { $0.id == id }
        self.deferred.remove(id)
        self.record(title: title, human: human, thread: thread, asker: asker, id: id, button: button)
      }
      approvals.append(approval)
      place(approval, placement)
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(life * 1_000_000_000))
        guard !once.done else { return }
        once.done = true
        if let call {
          call.closedUnanswered()
          ApprovalEnds.shared.end(id, .unanswered)
        }
        self?.approvals.removeAll { $0.id == id }
        self?.deferred.remove(id)
        self?.record(title: title, human: .timeout, thread: thread, asker: asker, id: id, button: button)
        c.resume(returning: ActionAdmission.AskTimeout.settle(answered: nil, timedOut: true))
      }
    }
  }
  /// A person step's card (PersonStep) in the task's chat. It holds no call: `answered` gets the
  /// person's yes or no later, and `expired` when the day sweep closed it unanswered (R26).
  func personCard(_ id: UUID, _ title: String, _ detail: String, button: String, thread: String?,
                  answered: @escaping (_ yes: Bool, _ expired: Bool) -> Void) {
    final class Once { var done = false }
    let once = Once()
    let askedAt = Date()
    let approval = Approval(id: id, title: title, detail: detail, button: button, threadID: thread,
                            personStep: true) { [weak self] human in
      guard !once.done else { return }
      once.done = true
      self?.approvals.removeAll { $0.id == id }
      self?.deferred.remove(id)
      answered(human == .yes, human != .yes && Date().timeIntervalSince(askedAt) >= RelayApproval.declineAfter)
    }
    approvals.append(approval)
    markBackground(id)
    place(approval, answerPlacement())
  }
  /// R16: the person's yes on a confirm card covers that exact call once, for a day. Only the
  /// card's answer writes it (`BrowserModel.personStepAnswered`).
  static func confirmAction(tool: String, argsHash: String, path: String?, task: String) -> RelayDeferred.Action {
    RelayDeferred.Action(title: tool, detail: argsHash, more: path ?? "", app: "", site: "", effect: "confirm", thread: task)
  }
  func grantConfirm(tool: String, argsHash: String, path: String?, task: String) {
    oneTimeGrants.append(RelayDeferred.Grant(
      action: Self.confirmAction(tool: tool, argsHash: argsHash, path: path, task: task), at: Date()))
  }
  func takesConfirm(tool: String, argsHash: String, path: String?, task: String) -> Bool {
    RelayDeferred.consume(Self.confirmAction(tool: tool, argsHash: argsHash, path: path, task: task),
                          from: &oneTimeGrants, now: Date())
  }
  /// A deferred card (RelayDeferred): its `proposal` row holds the exact step until the person
  /// answers; the card is the one every ask uses.
  private func deferAsk(_ action: RelayDeferred.Action, owner: String?, button: String, decline: String,
                        moreName: String, moreOpen: Bool, picture: NSImage?, effect: ApprovalGate.Effect?) {
    let id = UUID()
    let ask = RelayDeferred.Ask(action: action, owner: owner, askedAt: Date())
    let key = RelayDeferred.key(id)
    let rowOwner: String = owner ?? QueuedRun.personsOwn
    if let work, let payload = ask.payload() {
      work.post { ledger in _ = try ledger.enqueue(.proposal, owner: rowOwner, dedupeKey: key, payload: payload) }
    }
    let approval = deferredCard(ask, id: id, key: key, button: button, decline: decline, moreName: moreName,
                                moreOpen: moreOpen, picture: picture, effect: effect)
    place(approval, answerPlacement())
    note("Asked you on a card, so the run went on without it: \(action.title)", .auto)
  }
  /// A deferred card the last launch left, from its `proposal` row (`restoreWork`): the same card,
  /// still waiting for Allow, timed from when it was first asked. It waits in the chat, put off,
  /// as a card that lost its place does; the screenshot it may have had is not kept.
  private func restoreDeferred(_ ask: RelayDeferred.Ask, key: String) {
    let approval = deferredCard(
      ask, id: UUID(), key: key, moreName: ask.action.app == nil ? "the details" : "the script",
      effect: ask.action.effect.flatMap { ApprovalGate.Effect(rawValue: $0) })
    deferred.insert(approval.id)
  }
  /// Shows a deferred ask's card: a background card, so the person's next message leaves it, and
  /// the day sweep reminds and declines it (`sweepApprovals`). Its answer closes the row.
  private func deferredCard(_ ask: RelayDeferred.Ask, id: UUID, key: String, button: String = "Allow",
                            decline: String = "Decline", moreName: String, moreOpen: Bool = false,
                            picture: NSImage? = nil, effect: ApprovalGate.Effect?) -> Approval {
    final class Once { var done = false }
    let once = Once()
    let action = ask.action
    let approval = Approval(id: id, title: action.title, detail: action.detail, button: button, decline: decline,
                            threadID: action.thread, more: action.more, moreName: moreName, moreOpen: moreOpen,
                            app: action.app, site: action.site, picture: picture, askedAt: ask.askedAt,
                            effect: effect) { [weak self] human in
      guard !once.done, let self else { return }
      once.done = true
      self.approvals.removeAll { $0.id == id }
      self.deferred.remove(id)
      self.answerDeferred(ask, key: key, yes: human == .yes)
    }
    approvals.append(approval)
    markBackground(id)
    return approval
  }
  /// The answer to a deferred card: its row closes; a yes grants that exact step once, for a day,
  /// and queues a turn in the same chat to take it.
  private func answerDeferred(_ ask: RelayDeferred.Ask, key: String, yes: Bool) {
    let rowOwner: String = ask.owner ?? QueuedRun.personsOwn
    if let work, let payload = ask.payload() {
      work.post { ledger in
        let row = try ledger.enqueue(.proposal, owner: rowOwner, dedupeKey: key, payload: payload).row
        if yes {
          if try ledger.move(row.id, .start) { _ = try ledger.move(row.id, .finish, note: "Allowed") }
        } else {
          _ = try ledger.move(row.id, .drop, note: "Declined")
        }
      }
    }
    guard yes else { return }
    let now = Date()
    guard now.timeIntervalSince(ask.askedAt) < RelayDeferred.lifetime else { return }
    oneTimeGrants.append(RelayDeferred.Grant(action: ask.action, at: now))
    let reminder = RelayReminder(
      id: RelayDeferred.resumePrefix + UUID().uuidString, text: RelayDeferred.resumeText(ask.action), due: now,
      action: true)
    queueWork(ScheduledTurn(reminder: reminder, initiator: .scheduled, profileID: ask.owner), kind: .schedule,
              key: key + ":resume")
  }
  /// Puts a new card where `placement` says: the bar (without the keyboard), a notification, or
  /// only the chat (the slim line says so while the window is in front, and announces it).
  private func place(_ approval: Approval, _ placement: ApprovalPlacement) {
    if placement == .notificationOnly { deferred.insert(approval.id) }
    if placement.showsBar { showForAnswer() }
    if placement.notifies, Self.persists, !NSApp.isActive, notifiedCards.insert(approval.id).inserted {
      TaskNotifications.shared.post(threadID: approval.threadID ?? threadID, title: "Serein needs your OK", body: approval.title,
                                    asks: approval.threadID == nil || approval.threadID == threadID, kind: .ask)
    }
  }
  /// The fallback when no screen shows Serein's chat: an alert with the card's words, its
  /// primary and Decline. When macOS itself says the app is denied, the step cannot run: the
  /// alert offers Open System Settings instead, and the step counts as declined.
  private func alertAnswer(title: String, detail: String, button: String, decline: String, more: String?,
                           app: String?, automation: AutomationState?, live: Bool,
                           thread: String?, picture: NSImage? = nil) async -> ApprovalGate.HumanAnswer {
    #if DEBUG
    if let alertOverride { return alertOverride(title) ? .yes : .no }
    #endif
    let alert = NSAlert()
    alert.messageText = title
    let line = app.flatMap { ApprovalCopy.automation(automation, app: $0, live: live) }
    let blocked = automation == .denied && live
    // A task takes many steps: its alert promises only that task, not “this one step”.
    let suffix = blocked ? ApprovalCopy.alertDenied(app: app ?? "the app")
      : button == "Start" ? ApprovalCopy.startAlertSuffix
      : button == "Send" ? ApprovalCopy.sendAlertSuffix : ApprovalCopy.alertSuffix
    alert.informativeText = ([detail, line].compactMap { $0 }).joined(separator: "\n\n") + "\n\n" + suffix
    // The script (or the details) scrolls in a box of its own, so the buttons stay on screen. A
    // marked screenshot is the question itself, so it takes the place.
    if let picture { alert.accessoryView = Self.pictureBox(picture) } else if let more { alert.accessoryView = Self.moreBox(more) }
    NSApp.activate(ignoringOtherApps: true)
    if blocked {
      let human = await MacApproval.ask(alert, button: "Open System Settings", decline: "Decline", thread: thread)
      if human == .yes { openAutomationSettings(for: app) }
      return human == .timeout ? .timeout : .no
    }
    return await MacApproval.ask(alert, button: button, decline: decline, thread: thread)
  }
  /// Cards that lost their place (the column went, the window closed or went to the Dock): while
  /// Serein's window is in front, the slim line says they wait; out of view, the bar shows them
  /// without taking the keyboard (only a notification over a full-screen app). Cards the user put
  /// off (Later, or the bar put away) wait in the chat. Only when no screen can show the bar do
  /// they move to the alert, one by one, each still answering the run that asked.
  func reviewHiddenCards() {
    guard !movingCards else { return }
    let waiting = approvals.filter { !deferred.contains($0.id) }
    let forms = questionForms.filter { !deferred.contains($0.id) }
    let consent = consentWaiting && !consentDeferred
    guard !waiting.isEmpty || !forms.isEmpty || consent, !chatShown(), !panelVisible(), !windowKey() else { return }
    if screenAvailable() {
      // As a new card would be placed: the bar with a notification, or over a full-screen app
      // only the notification (each says so once).
      let placement: ApprovalPlacement = frontFullScreen() ? .notificationOnly : .bar
      for card in waiting { place(card, placement) }
      for form in forms {
        if placement == .notificationOnly { deferred.insert(form.id) }
        notifyAsks(form)
      }
      if consent {
        if placement == .notificationOnly { consentDeferred = true }
        notifyConsent(thread: nil)
      }
      if placement.showsBar, waiting.isEmpty { showForAnswer() }
      return
    }
    movingCards = true
    Task { @MainActor in
      defer { movingCards = false }
      while let card = approvals.first, !chatShown(), !panelVisible(), !screenAvailable() {
        approvals.removeAll { $0.id == card.id }
        let human = await alertAnswer(title: card.title, detail: card.detail, button: card.button, decline: card.decline,
                                      more: card.more, app: card.app, automation: card.automation,
                                      live: card.automationLive, thread: card.threadID, picture: card.picture)
        if human == .no { decline(card) } else { card.answer(human) }
      }
    }
  }
  private var movingCards = false
  /// The app went to the background with cards waiting in Serein's chat: a notification says
  /// so, once per card. Nothing comes forward by itself.
  func cardsWaitUnseen() {
    guard Self.persists, !panelVisible() else { return }
    // Questions and the one-time card say so too, each once.
    for form in questionForms { notifyAsks(form) }
    notifyConsent(thread: nil)
    let fresh = approvals.filter { notifiedCards.insert($0.id).inserted }
    guard let first = fresh.first else { return }
    // Serein's own step may ask macOS on first use; a task's step waits for the in-context card.
    TaskNotifications.shared.post(threadID: first.threadID ?? threadID, title: "Serein needs your OK", body: first.title,
                                  asks: first.threadID == nil || first.threadID == threadID, kind: .ask)
  }
  private var notifiedCards = Set<UUID>()
  /// A script or a tool's arguments in an alert: a fixed-height box that scrolls.
  private static func moreBox(_ text: String) -> NSView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
    let view = NSTextView(frame: scroll.bounds)
    view.string = text
    view.isEditable = false
    view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    view.autoresizingMask = [.width]
    scroll.documentView = view
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    return scroll
  }
  private static func pictureBox(_ picture: NSImage) -> NSView {
    let width = min(420, picture.size.width)
    let height = picture.size.width > 0 ? width * picture.size.height / picture.size.width : 0
    let view = NSImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    view.image = picture
    view.imageScaling = .scaleProportionallyUpOrDown
    view.setAccessibilityLabel(PointClick.pictureLabel)
    return view
  }
  /// The collapsed card after an answer. A task's card and its answer also join the turn of the
  /// run that asked (`asker`), while that run is still going, in its record (the session log). A
  /// card left over from a stopped run is not written into a later one, and Serein's own chats,
  /// which show their answered cards themselves, are never written to.
  private func record(title: String, human: ApprovalGate.HumanAnswer, thread: String?, asker: AgentRun?,
                      id: UUID = UUID(), button: String) {
    let allowed = human == .yes
    if let asker, let thread, asker.isActive, !asker.spec.relay, !agent.isSereinChatID(thread) {
      asker.noteCard(title, human)
    }
    // Only the user's Allow on a step counts; Start, Work here, automatic approvals and
    // declined/cancelled cards cannot trigger the approval-level hint.
    if allowed, button == "Allow" { HintCenter.shared.recordAllowedStep() }
    answered.append(AnsweredApproval(id: id, title: title, allowed: allowed, at: Date(), threadID: thread,
                                     byVoice: voiceAnswering == id))
    if answered.count > 20 { answered.removeFirst(answered.count - 20) }
  }
  /// The card a spoken answer is reaching right now, so its answered line says “by voice”.
  private var voiceAnswering: UUID?
  /// A spoken answer in a call (RelayController.answerByVoice): the card's own `answer`, exactly
  /// as its button gives it, never a new approval. A yes counts only for a voice-eligible effect
  /// with voice answers on; anything but yes or no is ignored. False when nothing was answered.
  @discardableResult func answerByVoice(_ id: UUID, _ human: ApprovalGate.HumanAnswer) -> Bool {
    guard human == .yes || human == .no, let card = approvals.first(where: { $0.id == id }) else { return false }
    if human == .yes {
      // Never where the card's own Allow is hidden (macOS denies the app's Automation right now).
      guard CallVoice.allowable(card.effect, enabled: RelayController.voiceAnswers),
        !(card.automation == .denied && card.automationLive)
      else { return false }
    }
    voiceAnswering = id
    if human == .no { decline(card) } else { card.answer(human) }
    voiceAnswering = nil
    return true
  }
  /// The last Automation answer macOS gave for each app (by bundle ID), or a script run told:
  /// macOS cannot say while the app is closed, so the card uses what it last knew, as a hint.
  /// In memory only; nothing known means no Automation line.
  private var automationKnown: [String: AutomationState] = [:]
  /// macOS Automation permission for a script's app, read off the main thread. `live` is false
  /// when macOS could not say (the app is closed) and the state is only what was remembered.
  private func automationState(_ app: String?) async -> (state: AutomationState?, live: Bool) {
    guard let app, let bundleID = ApprovalCopy.bundleID(for: app) else { return (nil, false) }
    if let state = await Task.detached(priority: .userInitiated, operation: {
      MacAccess.automationState(bundleID: bundleID)
    }).value {
      automationKnown[bundleID] = state
      return (state, true)
    }
    return (automationKnown[bundleID], false)
  }
  /// What a script run showed about the app's Automation permission: it ran (allowed), or
  /// macOS refused it (denied, -1743).
  func learnAutomation(app: String?, _ state: AutomationState) {
    guard let app, let bundleID = ApprovalCopy.bundleID(for: app) else { return }
    automationKnown[bundleID] = state
  }
  /// Open System Settings from a card or an alert: the user is about to change the answer, so
  /// the remembered one is dropped. Back in Serein, the card reads macOS again, and when macOS
  /// cannot say (the app is closed) it shows a plain Allow.
  func openAutomationSettings(for app: String?) {
    if let app, let bundleID = ApprovalCopy.bundleID(for: app) { automationKnown[bundleID] = nil }
    MacAccess.openSettings(.automation)
  }
  /// Reads the Automation permission again for each waiting card (the user may have come back
  /// from System Settings).
  func refreshAutomation() {
    let waiting = approvals.filter { $0.app != nil }
    guard !waiting.isEmpty else { return }
    Task {
      for approval in waiting {
        let read = await automationState(approval.app)
        if let i = approvals.firstIndex(where: { $0.id == approval.id }),
          approvals[i].automation != read.state || approvals[i].automationLive != read.live {
          approvals[i].automation = read.state
          approvals[i].automationLive = read.live
        }
      }
    }
  }

  // MARK: the one-time consent card

  /// What a run hears when Stop everything (or the pause) ended its wait for the consent card.
  static let stoppedStep = "The user stopped Serein, so this step did not run. Do not retry it."

  /// Before the first routine step that would have asked: callers call it only once the policy
  /// judged a step routine (.auto), and judge it again after, since the answer may be Ask before
  /// every step. When a fresh install was given Only risky steps without confirming it
  /// (`serein.approvals.defaulted`), Serein says so once and waits for OK or Ask before every
  /// step. Today's default is Every step, so this never shows unless that default is raised.
  /// False when the step must not go on: Stop everything ended the wait, or Serein is paused.
  func settleConsent(thread: String?) async -> Bool {
    #if DEBUG
    if autopilotOverride != nil { return true }
    #endif
    guard ApprovalLevel.showsConsent(
      defaulted: GateSettings.shared.bool(forKey: ApprovalLevel.defaultedKey), level: level)
    else { return true }
    // Inside a socket call the step stops waiting before the caller does (SocketCall).
    let call = SocketCall.live
    let left: TimeInterval? = call?.life(.infinity)
    if call != nil, left == nil { return false }
    // Wherever the user is, as an approval is; the alert only when no screen can show the bar.
    let placement = answerPlacement()
    if placement == .alert {
      let alert = NSAlert()
      alert.messageText = ApprovalLevel.consentTitle
      alert.informativeText = ApprovalLevel.consentBody
      alert.addButton(withTitle: ApprovalLevel.consentKeep)
      alert.addButton(withTitle: ApprovalLevel.consentAskEvery)
      NSApp.activate(ignoringOtherApps: true)
      // Closed with no choice made when the call stops waiting.
      let timeout = DispatchWorkItem {
        if NSApp.modalWindow === alert.window {
          NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: AlertVerdict.timeoutCode))
        }
      }
      if let left { DispatchQueue.main.asyncAfter(deadline: .now() + left, execute: timeout) }
      let response = alert.runModal()
      timeout.cancel()
      if response.rawValue != AlertVerdict.timeoutCode {
        setLevel(response == .alertFirstButtonReturn ? .riskyOnly : .everyStep)
      }
      let inTime = call?.waiting() ?? true
      return inTime && !state.paused
    }
    if !consentWaiting {
      consentDeferred = placement == .notificationOnly
      consentNotified = false
    }
    consentWaiting = true
    if placement.showsBar { showForAnswer() }
    // Out of view, a notification says so once (the slim line announces it in the window).
    if placement.notifies { notifyConsent(thread: thread) }
    let id = UUID()
    if let call, let left {
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
        self?.dropConsentWaiter(id, call)
      }
    }
    let proceed = await withCheckedContinuation { consentWaiters.append((thread, $0, id)) }
    let inTime = call?.waiting() ?? true
    return proceed && inTime && !state.paused
  }
  /// The socket call behind a step stopped waiting: that step goes no further, and the card
  /// closes once no other step waits on it.
  private func dropConsentWaiter(_ id: UUID, _ call: SocketCall) {
    guard let at = consentWaiters.firstIndex(where: { $0.id == id }) else { return }
    let entry = consentWaiters.remove(at: at)
    if consentWaiters.isEmpty { consentWaiting = false }
    call.closedUnanswered()
    entry.waiter.resume(returning: false)
  }
  /// The card's answer (`proceed`), or Stop everything (which leaves the level as it was and
  /// lets no waiting step go on).
  /// With `thread`, only the steps that thread's run asked (Stop on Serein's reply); the card
  /// stays while other steps still wait on it.
  private func finishConsent(proceed: Bool, thread: String? = nil) {
    let finishing = consentWaiters.filter { thread == nil || $0.thread == thread }
    consentWaiters.removeAll { thread == nil || $0.thread == thread }
    if consentWaiters.isEmpty { consentWaiting = false }
    for entry in finishing { entry.waiter.resume(returning: proceed) }
  }

  // MARK: delegated runs

  func adopt(_ threadID: String, edits: Bool) { adopt(newChild(threadID, edits: edits)) }
  /// What `adopt` records about the turn starting it, taken now for a task that starts later.
  func newChild(_ threadID: String, edits: Bool) -> (child: Child, owner: String) {
    // The chat whose turn started it: another assistant's while its routine runs there.
    let chat = turnThread
    let message: String? = chat == state.threadID ? transcript.last(where: { $0.role == "you" })?.id : nil
    return (Child(threadID: threadID, edits: edits, startedAt: Date(), chatID: chat, messageID: message,
                  byPerson: startedByPerson ? true : nil), actingProfile?.id ?? "")
  }
  func adopt(_ new: (child: Child, owner: String)) {
    var child = new.child
    child.startedAt = Date()
    state.children.removeAll { $0.threadID == child.threadID }
    state.children.append(child)
    childOwners[child.threadID] = new.owner
    if state.children.count > 200 { state.children.removeFirst(state.children.count - 200) }
    save()
    GuideCenter.shared.record(.taskStarted)
  }

  // MARK: notes and reminders

  /// A change to the notes Settings lists (Forget, Undo in the journal, tidy): shown at once,
  /// written to the memory store off the main thread (`applyToMemory`), and journaled.
  func updateNotes(actor: String = "user", _ change: (inout [RelayNote]) throws -> Void) rethrows {
    let before = notes
    var copy = notes
    try change(&copy)
    guard copy != before else { return }
    notes = copy
    applyToMemory(before: before, after: copy)
    let entries = RelayJournal.entries(actor: actor, before: before, after: copy)
    guard !entries.isEmpty else { return }
    journal = RelayJournal.trimmed(journal + entries)
    persist(journal, dir + "/journal.json")
  }
  /// The user undid one journal entry; the undo itself is recorded, so it can be undone too.
  func undo(_ entry: RelayJournalEntry) {
    if entry.isInstruction {
      if let prior = RelayJournal.undoneInstructions(entry, current: persona.rules) { updateInstructions(prior) }
      return
    }
    updateNotes { changed in _ = RelayJournal.undo(entry, in: &changed) }
  }
  func updateReminders(_ change: (inout [RelayReminder]) throws -> Void) rethrows {
    var copy = reminders
    try change(&copy)
    let timed = Set(reminders.filter(\.action).map(\.id))
    reminders = copy
    persist(reminders, "relay/reminders.json")
    // A new timed request: its runs depend on Serein being open, so Open at login is offered.
    if copy.contains(where: { $0.action && !timed.contains($0.id) }) { offerLoginIfUseful() }
  }
  /// One change to one schedule (nil: it is gone, or it was not there), applied at once and
  /// recorded with the schedule as it was, so Settings can undo it. The person's own changes
  /// come here straight from Settings; Serein's come only after the card (RelayToolHost).
  func changeReminder(
    _ id: String, actor: String = "user", _ summary: String, _ change: (inout RelayReminder?) throws -> Void
  ) rethrows {
    let before = reminders.first { $0.id == id }
    var after = before
    try change(&after)
    guard after != before else { return }
    updateReminders { list in
      if let index = list.firstIndex(where: { $0.id == id }) {
        if let after { list[index] = after } else { list.remove(at: index) }
      } else if let after {
        list.append(after)
      }
    }
    // A deleted schedule's missed card goes with it.
    if after == nil { missedRuns.removeAll { $0.id == id } }
    recordChange(RelayScheduleChange(actor: actor, summary: summary, kind: .reminder, itemID: id, reminder: before))
  }
  private func recordChange(_ change: RelayScheduleChange) {
    scheduleChanges = RelayScheduleChange.trimmed(scheduleChanges + [change])
    persist(scheduleChanges, "relay/schedule-changes.json")
  }
  /// The user undid one change to a schedule or an alert; the undo is itself recorded, so it can
  /// be undone too.
  func undoSchedule(_ change: RelayScheduleChange) {
    let now = Date()
    switch change.kind {
    case .reminder:
      changeReminder(change.itemID, "Undid: " + change.summary) { current in
        current = change.reminder.map { $0.restored(over: current, now: now) }
      }
    case .watch:
      changeWatch(change.itemID, "Undid: " + change.summary) { current in
        current = change.watch.map { $0.restored(over: current) }
      }
    }
  }
  /// Words for a change summary: a schedule's text, short.
  static func short(_ text: String) -> String { "“\(String(text.prefix(60)))”" }
  // MARK: the hologram's look

  /// The look Relay wears and the ones before it (RelayLookStore).
  @Published private(set) var looks = RelayLookStore()
  var look: RelayLook { looks.look }
  static let restyleKey = "serein.relay.restyleOnItsOwn"
  static let hologramKey = "serein.relay.hologram"
  /// Unset, the hologram is on, for everyone and whatever ⌥Space is (it is Serein's signature);
  /// Settings › Serein › Look turns it off. It holds still while the window is neither key nor
  /// in the active app (RelayAvatarEngine), and previews leave it off unless `--ui-hologram`.
  static let hologramDefault = true
  #if DEBUG
  /// Checks decide this here, never in the user's defaults.
  var restyleOverride: Bool?
  #endif
  /// Relay may change its look in turns it starts itself (on by default; at most twice a day).
  var restyleOnItsOwn: Bool {
    get {
      #if DEBUG
      if let restyleOverride { return restyleOverride }
      #endif
      return UserDefaults.standard.object(forKey: Self.restyleKey) as? Bool ?? true
    }
    set {
      objectWillChange.send()
      UserDefaults.standard.set(newValue, forKey: Self.restyleKey)
    }
  }
  /// The current turn is one Relay started on its own (a brief, a check-in, a look at a run).
  var ownTurn: Bool { proactiveTurn && working }
  /// Wears `look`. Relay's changes pass its daily limits first; the user's always apply.
  func wear(_ look: RelayLook, by author: RelayLookStore.Author, reason: String? = nil) throws {
    let own = author == .relay && ownTurn
    if author == .relay, let why = looks.refusal(own: own, allowedOnOwn: restyleOnItsOwn, now: Date()) {
      throw SereinError.invalid(why)
    }
    looks.set(look, by: author, own: own, reason: reason)
    persist(looks, "relay/look.json")
  }
  @discardableResult func undoLook() -> Bool {
    guard looks.undo() else { return false }
    persist(looks, "relay/look.json")
    return true
  }

  // MARK: speaking first

  static let proactiveKey = "serein.relay.proactive"
  /// How much Serein does on its own (RelayProactive.Level), in GateSettings. The migration writes
  /// it for every install; unset it is `newInstallDefault`, and while that file cannot be read
  /// or holds an unknown value it is Never.
  var proactiveLevel: RelayProactive.Level {
    get {
      #if DEBUG
      if let proactiveOverride { return proactiveOverride }
      #endif
      guard !GateSettings.shared.unreadable else { return .off }
      guard let stored = GateSettings.shared.string(forKey: Self.proactiveKey) else { return .newInstallDefault }
      return RelayProactive.Level(rawValue: stored) ?? .off
    }
    set { syncSpeaksFirst(main: newValue) }
  }
  /// Settings › Check-ins and the main assistant's "Speaks first" are one value: writing either
  /// writes both. Settings' picker comes here through `proactiveLevel`; the assistant editor, a
  /// row's menu and Undo through `changeTeam`.
  func syncSpeaksFirst(main level: RelayProactive.Level) {
    objectWillChange.send()
    GateSettings.shared.set(level.rawValue, forKey: Self.proactiveKey)
    guard let id = team.mainProfileID, let i = team.profiles.firstIndex(where: { $0.id == id }),
      team.profiles[i].speaksFirst != level
    else { return }
    team.profiles[i].speaksFirst = level
    saveTeam()
  }
  @Published private(set) var proactiveMemory = RelayProactive.Memory()
  /// Automated checks keep Relay from speaking first unless they test it.
  #if DEBUG
  static var quietForChecks = RunMode.checking
  #else
  static var quietForChecks = false
  #endif
  /// Runs outside Relay that failed or wait for the user: (thread, what happened, the assistant
  /// that raises it).
  private var attention: [(thread: String, detail: String, owner: String)] = []
  /// A setup problem Serein raises once, with its fix (the attention prompt asks for one IDEA
  /// line): a connected app's sign-in, a rejected key, a computer left idle. `key` names it in
  /// `proactiveMemory.raised`.
  func needsRepair(_ key: String, _ detail: String) {
    let id = Self.repairPrefix + key
    guard !Self.quietForChecks, !proactiveMemory.raised.contains(id), !attention.contains(where: { $0.thread == id }) else { return }
    attention.append((id, detail, team.mainProfileID ?? team.activeID))
    if attention.count > 20 { attention.removeFirst(attention.count - 20) }
  }
  static let repairPrefix = "repair:"
  /// The current turn is one Relay started itself.
  private(set) var proactiveTurn = false
  private var checkInTurn = false
  /// A check-in runs in this chat: it may carry out what the person last asked here
  /// (`turnAuthority`), and its cards wait instead of holding the turn.
  var checkingIn: Bool { proactiveTurn && checkInTurn }
  /// The last message the person typed in each chat, this launch: a check-in's authority.
  private var lastRequest: [String: String] = [:]
  /// Another assistant is speaking first in its own Main chat (`speakFirstElsewhere`): its chat
  /// and id. One turn of one's own at a time, across every assistant.
  private(set) var speakingElsewhere: (thread: String, profileID: String)?
  /// Proactive words that wait while the person types in a composer in front (`noticeProactive`).
  private var heldNotices: [(thread: String, title: String, body: String)] = []
  /// Seconds since the user last used a keyboard, mouse or trackpad (any app; no permission).
  nonisolated static var idleSeconds: TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
  }
  /// One step of the proactive loop: a morning brief, a word about a run that needs the user,
  /// or a check-in, within the shared daily cap and outside quiet hours (RelayProactive.next).
  /// `RelayProactive.pick` chooses which assistant speaks; with one assistant it is the old rule.
  func speakFirst(now: Date = Date(), idle: TimeInterval? = nil) {
    let idle = idle ?? Self.idleSeconds
    // Never in UI previews or checks that did not ask for it.
    guard !RelayController.previewing, !Self.quietForChecks, !state.paused, agent.available[provider] != nil else { return }
    // Nothing speaks first, or reads the person's calendar for a brief, before setup is done.
    guard !SereinChatSetup.shared.holdsCheckIns(self) else { return }
    let speakers = proactiveSpeakers()
    let waiting = attention.map { RelayProactive.Attention(threadID: $0.thread, owner: $0.owner) }
    // One brief a day: while the 9:00 brief is on it is the day's brief, so this reading counts
    // today as briefed (nothing saved) and only attention and check-ins remain here.
    var memory = proactiveMemory
    if briefing { memory.briefDay = RelayProactive.dayKey(now) }
    guard let pick = RelayProactive.pick(
      speakers: speakers, memory: memory, now: now, idle: idle, busy: working || speakingElsewhere != nil,
      attention: waiting)
    else { return }
    // A check-in waits while the person wrote in that chat in the last 20 minutes.
    if case .checkIn = pick.trigger,
      personWroteRecently(in: pick.speaker == team.activeID ? threadID : mainThread(of: pick.speaker), now: now) { return }
    // Signed out or offline, nothing can answer: the day's brief or check-in stays unspent, and the
    // record doesn't claim one was given.
    guard agent.canThink(assistantEngine(profile(id: pick.speaker)).provider), networkOnline() else { return }
    let trigger = pick.trigger
    // Words from a chat that read the person's data go in only once the chat this turn speaks in
    // is marked too (PersonalCarry).
    let carry = PersonalCarry(agent: agent, into: pick.speaker == team.activeID ? threadID : mainThread(of: pick.speaker))
    var detail = ""
    if case .attention(let id) = trigger {
      detail = attention.first { $0.thread == id }?.detail ?? ""
      if !carry.admits(agent.readsPersonal(thread: id)) { detail = Self.withheldAttention }
    }
    RelayProactive.record(pick, speakers: speakers, attention: waiting, in: &proactiveMemory, now: now)
    persist(proactiveMemory, "relay/proactive.json")
    attention.removeAll { item in proactiveMemory.raised.contains(item.thread) }
    let label: String
    switch trigger {
    case .morningBrief: label = "Started the morning brief"
    case .attention: label = "Looked into a run that needs you"
    case .checkIn: label = "Checked in"
    }
    let huddle = trigger == .morningBrief ? huddleSection(lead: pick.speaker, speakers: speakers, now: now, carry: carry) : nil
    guard pick.speaker == team.activeID else {
      speakFirstElsewhere(
        profile(id: pick.speaker), trigger: trigger, detail: detail, huddle: huddle, label: label, now: now, carry: carry)
      return
    }
    note(label, .auto)
    proactiveTurn = true
    checkInTurn = trigger == .checkIn
    var prompt = RelayProactive.prompt(
      trigger, detail: detail, restyle: restyleOnItsOwn, chats: SessionReading.allowed,
      acts: trigger == .checkIn && lastRequest[threadID] != nil)
    var brief: String?
    if trigger == .morningBrief, let goals = RelayGoal.brief(briefGoals(now: now, carry: carry), now: now) {
      prompt += "\n" + goals
    }
    if let huddle { prompt += "\n" + huddle }
    if trigger == .morningBrief {
      // The 9:00 brief is off here. With nothing open this brief stays as it was, with no section
      // and no card (an older snapshot would sit under it: the prompt reads the same every day).
      // (Serein's own questions about itself, such as an AI app switch, do not count.)
      if pendingForBrief().isEmpty { briefWaiting = nil } else { brief = startBrief(prompt, carry: carry) }
    }
    turn(prompt, brief: brief)
    if trigger == .morningBrief { attachYesterday(to: threadID) }
  }

  /// The roster as `RelayProactive.Speaker`s: each assistant's own level (the main one, unset,
  /// keeps Settings' level) and its team's lead for the huddle. Another assistant waits while a
  /// hand-off works in its chat, while it may not use Answers (it speaks in words only), and
  /// while a run holds its Main chat.
  private func proactiveSpeakers() -> [RelayProactive.Speaker] {
    RelayProactive.speakers(team, global: proactiveLevel).map { speaker in
      var speaker = speaker
      // A paused assistant does not speak first (RelayProfile.paused).
      let paused: Bool = team.profiles.contains { $0.id == speaker.id && $0.isPaused }
      let busy: Bool = speaker.id != team.activeID
        && (handoffLedger.records.contains { $0.to == speaker.id && $0.state == .running }
          || !(effectiveScope(profile(id: speaker.id)) ?? personScope).allows(.answer)
          || knownMainThread(of: speaker.id).flatMap { agent.hub.run(for: $0) } != nil)
      speaker.occupied = paused || busy
      return speaker
    }
  }
  /// The assistant a run's success or failure belongs to: a hand-off's target, the assistant a
  /// task Serein started works for, else, for the person's own work, the active assistant when it
  /// speaks first, else the main one (so Settings' level still raises it).
  private func workOwner(_ run: AgentRun) -> String {
    if run.spec.initiator == .handoff, let record = handoffLedger.records.last(where: { $0.threadID == run.spec.threadID }) {
      return record.to
    }
    if let owner = childOwners[run.spec.threadID], !owner.isEmpty { return owner }
    let active = team.activeID
    return RelayProactive.level(of: profile(id: active), in: team, global: proactiveLevel) != .off ? active : (team.mainProfileID ?? active)
  }
  /// Something of `owner`'s succeeded: its failure streak ends (`RelayProactive.succeeded`).
  private func workSucceeded(owner: String) {
    let waiting = attention.map { RelayProactive.Attention(threadID: $0.thread, owner: $0.owner) }
    let before = proactiveMemory
    RelayProactive.succeeded(owner, pending: waiting, in: &proactiveMemory)
    guard proactiveMemory != before else { return }
    persist(proactiveMemory, "relay/proactive.json")
    attention.removeAll { item in proactiveMemory.raised.contains(item.thread) }
  }
  /// The lead's morning brief speaks for the teams it leads: one short section per member, with
  /// what it finished since yesterday and the cards waiting in its chat. nil when `lead` leads
  /// no huddle.
  /// A result or card from a chat that read the person's data goes in only as `carry` admits it.
  private func huddleSection(lead: String, speakers: [RelayProactive.Speaker], now: Date, carry: PersonalCarry) -> String? {
    let since = now.addingTimeInterval(-86_400)
    let members = speakers.filter { $0.huddleLead == lead }.map { member -> RelayProactive.HuddleMember in
      let finished = handoffLedger.records.filter { record in
        let ended: Bool = record.state == .done || record.state == .failed
        let endedAt: Date = record.finishedAt ?? .distantPast
        return record.to == member.id && ended && endedAt > since
      }
      let did: [String] = finished.suffix(3).filter { carry.admits(personal($0)) }.map { record -> String in
        let outcome: String = record.state == .done ? "Finished" : "Couldn't finish"
        let result: String = record.result.map { ": \($0)" } ?? ""
        return "\(outcome) “\(String(record.task.prefix(80)))”\(result)"
      }
      var waiting: [String] = []
      if let chat = knownMainThread(of: member.id), carry.admits(agent.readsPersonal(thread: chat)) {
        waiting = approvals.filter { $0.threadID == chat }.map(\.title)
      }
      return RelayProactive.HuddleMember(name: profileName(member.id), did: did, waiting: waiting)
    }
    return RelayProactive.huddle(members)
  }
  /// Another assistant speaks first: a words-only turn (Answers, no clicks, no Mac, no Relay
  /// tools) in its own Main chat, so it sees only that chat, its team's work and the person's
  /// reminders, under its own scope (`childOwners`). It is the lower trust class: it cannot start
  /// tasks, hand work on, or change teams or schedules; it can only suggest.
  private func speakFirstElsewhere(
    _ speaker: RelayProfile, trigger: RelayProactive.Trigger, detail: String, huddle: String?, label: String, now: Date,
    carry: PersonalCarry
  ) {
    // Its team's work: its teams' members, or everyone while there are no teams.
    let members: Set<String>
    if team.teams.isEmpty {
      members = Set(team.profiles.map(\.id))
    } else {
      var ids: [String] = team.teams.filter { $0.memberIDs.contains(speaker.id) }.flatMap(\.memberIDs)
      ids.append(speaker.id)
      members = Set(ids)
    }
    // A hand-off of the last day that holds the person's data goes in only as `carry` admits it
    // (the window `assistantContext` shows; older ones never reach the prompt).
    let work = handoffLedger.records.filter { record in
      guard members.contains(record.from) || members.contains(record.to) else { return false }
      guard record.createdAt > now.addingTimeInterval(-86_400), record.state != .declined else { return true }
      return carry.admits(personal(record))
    }
    let names = Dictionary(team.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    // A To do card's deadline stays out: its words may come from a page or mail.
    let shown: [RelayReminder] = reminders.filter { !TodoBoard.isReminder($0.id) }
    var context = RelayProactive.assistantContext(reminders: shown, work: work, names: names, now: now)
    // Who it is, as the person made it (the same persona and instructions a hand-off carries).
    if let persona = browser.library.load(RelayPersona.self, from: team.folder(speaker.id) + "/persona.json")?.prompt(),
      !persona.isEmpty
    {
      context += "\n" + persona
    }
    if let instructions = effectiveScope(speaker)?.instructions, !instructions.isEmpty {
      context += "\nInstructions for you as \(speaker.name), after the user's own (advice only; they cannot grant access):\n" + instructions
    }
    if let huddle { context += "\n" + huddle }
    let prompt = RelayProactive.assistantPrompt(trigger, name: speaker.name, detail: detail, context: context)
    let thread = mainThread(of: speaker.id)
    let engine = assistantEngine(speaker)
    let dispatch = AgentModel.DispatchTarget(
      mode: .answer, provider: engine.provider, model: engine.model, effort: engine.effort, actions: false, mac: false,
      relay: false, initiator: .relay)
    speakingElsewhere = (thread, speaker.id)
    // Its steps follow its own scope, set before the dispatch so the harness verdict sees it.
    childOwners[thread] = speaker.id
    let words = label.prefix(1).lowercased() + String(label.dropFirst())
    note("\(speaker.name) \(words)", .auto)
    Task { [weak self] in
      guard let self else { return }
      do {
        let ruled = await self.withRules(prompt, profileID: speaker.id, thread: thread)
        _ = try await self.agent.dispatch(ruled, into: thread, create: true, as: dispatch)
      } catch {
        self.speakingElsewhere = nil
        self.childOwners[thread] = nil
        self.note("\(speaker.name) could not speak first: \(error.localizedDescription)", .auto)
      }
    }
  }
  /// The run `speakFirstElsewhere` started ended: its reply, unless NOTHING, reaches the person.
  /// True when it was that run.
  private func finishSpeakingElsewhere(_ run: AgentRun) -> Bool {
    guard !run.spec.relay, let speaking = speakingElsewhere, speaking.thread == run.spec.threadID else { return false }
    speakingElsewhere = nil
    childOwners[run.spec.threadID] = nil
    // A hand-off that waited for this chat starts now.
    startWaitingHandoffs()
    guard run.record.outcome == .done,
      let reply = run.transcript.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
      !reply.isEmpty, !RelayProactive.isNothing(reply)
    else { return true }
    // Names only (SPEC I14): the reply stays in its chat.
    let name = profileName(speaking.profileID)
    noticeProactive(thread: run.spec.threadID, title: name, body: Self.updateBody(name))
    return true
  }
  /// A proactive word for the person, as a notification that opens its exact chat. It waits while
  /// Serein is in front and the person is typing in a composer, then goes (`releaseProactiveNotices`).
  private func noticeProactive(thread: String, title: String, body: String) {
    heldNotices.append((thread, title, body))
    releaseProactiveNotices()
  }
  /// Sends the held proactive words once the person is not typing in front (each clock step).
  /// In front, the chat on screen already shows its own reply; another assistant's is not on
  /// screen, so it notifies.
  func releaseProactiveNotices() {
    guard !heldNotices.isEmpty, !(NSApp.isActive && Self.typingInComposer) else { return }
    let notices = heldNotices
    heldNotices = []
    for notice in notices where !(NSApp.isActive && notice.thread == threadID) {
      TaskNotifications.shared.post(
        threadID: notice.thread, title: notice.title, body: notice.body, always: NSApp.isActive, asks: true)
    }
  }
  /// The person is writing in a composer: one has the keyboard and holds a draft.
  private static var typingInComposer: Bool {
    guard let editor = NSApp.keyWindow?.firstResponder as? ComposerTextView else { return false }
    return !editor.string.isEmpty
  }

  /// What waits on the person, for the brief's “Waiting on you”: one item per open approval card,
  /// read only. A page step's card carries its site and opens with the step's ask line; any other
  /// card speaks in its own title (and names its Mac app, when it has one).
  func pendingForBrief() -> [RelayBriefing.Waiting] {
    approvals.filter { !$0.aboutSerein }.map { card in
      let thread = card.threadID ?? threadID
      // A page step's card opens with its ask line (ActionAdmission.readback).
      let action = card.site != nil ? (card.detail.components(separatedBy: "\n").first ?? card.title) : card.title
      let named = agent.hub.latest(for: thread)?.spec.title
      let title = thread == threadID ? "Serein's chat"
        : (named?.isEmpty == false ? named : nil) ?? agent.conversations.first { $0.id == thread }?.title ?? "A task"
      return RelayBriefing.Waiting(task: title, place: card.site ?? card.app, action: action, cardID: card.id)
    }
  }
  /// Takes the brief's “Waiting on you” snapshot for the turn `prompt` starts: the card under it,
  /// and the section its context carries when anything waits.
  /// The card shows the person every item; the model reads a card from a chat that read the
  /// person's data only as `carry` admits it.
  /// Yesterday's sessions as a reel under the brief's reply (`ReportReel.day`): what the brief's
  /// words leave out, drawn from facts. The turn's facts were just cleared, so this lands on its reply.
  private func attachYesterday(to chat: String) {
    guard let reel = ReportReelMaker.yesterday(library: browser.library) else { return }
    var facts = desk.facts[chat] ?? AssistantDesk.Facts()
    facts.reel = reel
    desk.facts[chat] = facts
  }

  private func startBrief(_ prompt: String, carry: PersonalCarry, in chat: String? = nil) -> String? {
    let items = pendingForBrief()
    let briefChat = chat ?? threadID
    briefWaiting = BriefWaiting(threadID: briefChat, prompt: prompt, items: items)
    let told = items.filter { item in
      let chat = approvals.first { $0.id == item.cardID }?.threadID ?? briefChat
      return carry.admits(agent.readsPersonal(thread: chat))
    }
    // Nothing waiting: the card says so, and the reply may still be NOTHING NEW.
    return told.isEmpty ? nil : RelayBriefing.waiting(told)
  }
  /// A hand-off that holds the person's data: asked from a marked chat, or either chat marked.
  private func personal(_ record: AssistantHandoff) -> Bool {
    record.personal == true || agent.readsPersonal(thread: record.threadID) || agent.readsPersonal(thread: record.askedIn)
  }
  /// The reminders for a brief's goal lines: a goal with new findings whose checks answered in a
  /// chat that read the person's data goes in only as `carry` admits it.
  private func briefGoals(now: Date, carry: PersonalCarry) -> [RelayReminder] {
    reminders.filter { reminder in
      guard reminder.goal?.fresh(now: now).isEmpty == false else { return true }
      let marked = (reminder.history ?? []).contains { run in run.thread.map { agent.readsPersonal(thread: $0) } == true }
      return carry.admits(marked)
    }
  }
  /// An attention line from a chat that read the person's data, when this chat cannot be marked.
  static let withheldAttention =
    "A run in a chat that used the user's data failed or waits for them. Its details are left out because Serein could not save that this chat holds them."

  /// Due reminders: a note shows in the panel and as a notification; a request queues as a
  /// turn that runs when Relay is idle, under the unattended protocol (RelayUnattended). Held
  /// while the kill switch pauses Relay; a paused schedule waits for the user to resume it.
  func tick(now: Date = Date()) {
    if Self.persists { research.tick() }
    sweepApprovals(now: now)
    endDueGoals(now: now)
    sweepHandoffs(now: now)
    checkMacAccess()
    learnIfIdle(now: now)
    tellMemoryMoved()
    checkWeeklyLimits(now: now)
    guard !state.paused else { return }
    drainScheduled()
    // Nothing comes due before the work ledger's launch recovery ran, nor while the last tick's
    // runs are still being written to it.
    guard workReady, !writingDue else { return }
    // Requests that came due after Stop Everything began are worded as missed while stopped.
    let stoppedAt = stoppedSince
    stoppedSince = nil
    let due: [RelayReminder] = reminders.filter { $0.paused != true && $0.due <= now }
    guard !due.isEmpty else { return }
    // Overdue by more than the grace, a request came due while the Mac slept, Serein was closed or
    // Stop Everything held it: it is listed once per schedule with Run now and Skip, never run late
    // unless it says so. One whose last run is still going is skipped.
    var runs: [RelayReminder] = []
    var others: [RelayReminder] = []
    for reminder in due {
      let missed = RelayMissedRun.isMissed(reminder, now: now)
        && !RoutineRuns.catchesUp(reminder, now: now, stoppedAt: stoppedAt)
      let skipped = reminder.skipsWhileBusy && isBusy(reminder.id)
      if reminder.action, !missed, !skipped { runs.append(reminder) } else { others.append(reminder) }
    }
    // What does not run moves on now. A run is written to the work ledger first, and its schedule
    // moves on only then: a crash in between comes due again at the same time, with the same key,
    // which writes nothing (`WorkLedger.scheduleKey`).
    advance(others, now: now)
    for reminder in others { fire(reminder, now: now, stoppedAt: stoppedAt) }
    guard !runs.isEmpty else { return }
    let turns: [(turn: ScheduledTurn, kind: WorkLedger.Kind, key: String)] = runs.map { reminder in
      (turn: ScheduledTurn(reminder: reminder, initiator: .scheduled, profileID: reminder.profileID),
       kind: WorkLedger.Kind.schedule, key: WorkLedger.scheduleKey(id: reminder.id, due: reminder.due))
    }
    writingDue = true
    let epoch = workEpoch
    Task { [weak self] in
      guard let self else { return }
      let queued = await self.writeWork(turns)
      self.writingDue = false
      self.advance(runs, now: now)
      self.enqueue(queued, epoch: epoch)
    }
  }
  /// One reminder that came due and does not run now: a missed request, a skipped one, or a
  /// plain reminder to show.
  private func fire(_ reminder: RelayReminder, now: Date, stoppedAt: Date?) {
    if reminder.action {
      if RelayMissedRun.isMissed(reminder, now: now) {
        listMissed(reminder, why: stoppedAt.map { reminder.due >= $0 } == true ? .stopped : .asleep)
      } else {
        recordScheduleRun(reminder, outcome: RelayReminder.skipped, result: "The last run was still going.")
      }
      return
    }
    dueReminders.append(reminder)
    // macOS already showed this occurrence while Serein was closed. Another one (already
    // due at quit, so macOS got the next) still notifies.
    if !ReminderHandoff.alreadyShown(shownWhileClosed, id: reminder.id, due: reminder.due) {
      TaskNotifications.shared.post(threadID: threadID, title: "Reminder", body: reminder.text, always: true, kind: .reminder)
    }
    shownWhileClosed[reminder.id] = nil
    showPanel()
  }
  /// Moves each of `fired` on to its next time (a one-time one leaves the list), while it is
  /// still as it came due: an edit or a pause made meanwhile stays as it is.
  private func advance(_ fired: [RelayReminder], now: Date) {
    guard !fired.isEmpty else { return }
    updateReminders { list in
      for reminder in fired {
        guard let index = list.firstIndex(where: { $0.id == reminder.id }), list[index].due == reminder.due,
          list[index].paused != true
        else { continue }
        if let next = list[index].next(after: now) { list[index].due = next } else { list.remove(at: index) }
      }
    }
  }

  // MARK: reminders while Serein is closed

  /// Where the reminders handed to macOS at quit are listed, so the next launch can take back
  /// the ones still pending and knows which already showed.
  private static let handoffFile = "relay/handoff.json"
  /// At quit: each plain reminder still to come becomes a scheduled macOS notification with the
  /// reminder's id. Only when notifications are allowed; nothing asks for permission at quit.
  /// Waits up to a second for macOS to take them.
  func handOffReminders(now: Date = Date()) {
    guard Self.persists, TaskNotifications.shared.supported else { return }
    // Stop Everything paused every reminder: macOS must not fire them while Serein is closed.

    let plan = ReminderHandoff.plan(reminders: reminders, now: now, paused: state.paused)
    guard !plan.isEmpty, TaskNotifications.shared.authorizedNow(timeout: 0.5) else {
      try? FileManager.default.removeItem(at: browser.library.root.appendingPathComponent(Self.handoffFile))
      return
    }
    persist(plan, Self.handoffFile)
    TaskNotifications.shared.schedule(plan, timeout: 1)
  }
  /// At launch: the handed-off notifications that have not fired go back to Serein's clock.
  private func takeBackReminders(now: Date = Date()) {
    guard Self.persists else { return }
    let file = browser.library.root.appendingPathComponent(Self.handoffFile)
    guard let plan = browser.library.load([ReminderHandoff.Request].self, from: Self.handoffFile) else { return }
    try? FileManager.default.removeItem(at: file)
    shownWhileClosed = ReminderHandoff.delivered(plan, now: now)
    TaskNotifications.shared.withdraw(plan.map(\.id))
  }
  /// After reminder_create: the one line that says how this reminder behaves once Serein is
  /// closed, if anything needs the user. The request line and the allow-notifications line each
  /// show once per install; the notifications-off line shows while macOS has them off (F14).
  func noteReminderCreated(_ reminder: RelayReminder, now: Date = Date()) {
    let defaults = UserDefaults.standard
    if reminder.action {
      let kept = RelayOrchestrator.enabled || RelayOrchestrator.menuBar
      let key = "serein.assistant.requestNoticeShown"
      guard !kept, !defaults.bool(forKey: key) else { return }
      if Self.persists { defaults.set(true, forKey: key) }
      reminderNotice = .keepRunning(when: QuitGuard.when(reminder.due, now: now))
      return
    }
    switch TaskNotifications.shared.authorization {
    case .notDetermined:
      let key = "serein.assistant.notifyNoticeShown"
      guard !defaults.bool(forKey: key) else { return }
      if Self.persists { defaults.set(true, forKey: key) }
      reminderNotice = .allowNotifications
    case .denied: reminderNotice = .notificationsOff
    default: break
    }
  }
  /// “Keep Serein in the menu bar” from the request line.
  func keepInMenuBar() {
    if Self.persists { RelayOrchestrator.menuBar = true }
    RelayController.shared?.install()
    reminderNotice = .keptInMenuBar
  }

  // MARK: webhooks

  /// Relay's own folder in the library; the hook registry lives beside its state.
  var hookFolder: URL? { browser.library.root.appendingPathComponent("relay", isDirectory: true) }

  /// The loopback receiver, started once hooks are on and Serein is not a preview or check.
  /// A registry change restarts it, so a removed hook stops working at once.
  private var hookServer: RelayHookServer?
  /// Hooks from Settings take deliveries while their switch is on. Owned links take them while
  /// one exists, since the person's own words made each (RelayLinks.swift); they need the work
  /// ledger, which opens here once.
  func runHookServer() {
    let legacy = RelayHookServer.enabled
    let owned = !desk.links.isEmpty
    guard legacy || owned, !RelayController.previewing,
      !CommandLine.arguments.contains("--verify")
    else {
      hookServer?.stop()
      hookServer = nil
      return
    }
    openWorkLedger()
    guard hookServer == nil else { return }
    guard let server = try? RelayHookServer(
      registry: hookRegistry, legacy: legacy, links: desk.links, ledger: desk.ledger, rates: desk.linkRates)
    else { return }
    server.start()
    hookServer = server
  }
  /// The hooks or the owned links changed: the receiver starts again with them, so a removed or
  /// paused one stops at once.
  func restartHookServer() {
    hookServer?.stop()
    hookServer = nil
    runHookServer()
  }

  /// The registered webhooks: name plus the digest of a secret Serein never keeps whole.
  @Published private(set) var hookRegistry: [RelayHookEntry] = []

  /// Creates a hook; the secret it returns is shown once and never stored. Nil, and no hook,
  /// when the system could not make a random secret.
  @discardableResult
  func addHook(name: String) -> String? {
    guard let secret = RelayHookServer.newSecret() else { return nil }
    hookRegistry.append(RelayHookEntry(name: String(name.prefix(60)), secretDigest: RelayHookServer.digest(secret)))
    persistHooks()
    hookServer?.stop()
    hookServer = nil
    runHookServer()
    return secret
  }

  func removeHook(_ id: String) {
    hookRegistry.removeAll { $0.id == id }
    persistHooks()
    hookServer?.stop()
    hookServer = nil
    runHookServer()
  }

  private func persistHooks() {
    guard let data = try? JSONEncoder().encode(hookRegistry) else { return }
    try? data.write(to: hookFolder!.appendingPathComponent("hooks.json"), options: .atomic)
  }

  /// One webhook delivery: a turn that runs when Relay is idle, under the unattended
  /// protocol like every scheduled request, attributed in the ledger to the webhook.
  func enqueueWebhook(_ prompt: String) {
    guard !state.paused else { return }
    let turn = ScheduledTurn(reminder: RelayReminder(text: prompt, due: Date(), action: true), initiator: .webhook)
    note("A webhook fired", .auto)
    queueWork(turn, kind: .link, key: "hook:" + UUID().uuidString)
  }
  /// One Settings hook delivery already on disk (`RelayHook.enqueue`): its turn queues with its
  /// row, so it starts, ends and stops like every scheduled turn's. While Stop Everything holds it
  /// waits in the queue for Resume; with Relay off it is dropped, as before the ledger.
  func hookArrived(_ row: WorkLedger.Row) {
    guard Self.enabled else {
      moveWork(row.id, .drop, note: "Relay is off.")
      return
    }
    guard let run = QueuedRun.decoded(row.payload), !holds(row.id) else { return }
    note("A webhook fired", .auto)
    scheduledQueue.append(ScheduledTurn(reminder: run.reminder, initiator: run.initiator, ledgerID: row.id))
    drainScheduled()
  }

  /// One delivery of an owned link, already on disk in the work ledger (RelayWork.swift): its
  /// owner's unattended turn, queued like a webhook's with its row (`ledgerID`), reading
  /// `HookGate.Admitted.prompt` with the owner's scope in the owner's own chat (`drainScheduled`).
  /// A paused owner skips it (`dropped`, "Paused"); while Stop Everything holds, it is `missed`
  /// ("Stopped"); an owner that is gone drops it. The row starts, ends and stops like every
  /// scheduled turn's (`startWork`, `finishWork`, `stopEverything`).
  func enqueueLink(_ row: WorkLedger.Row) {
    guard let owner = team.profiles.first(where: { $0.id == row.owner }) else {
      moveWork(row.id, .drop, note: "Its assistant is gone.")
      return
    }
    if owner.isPaused {
      moveWork(row.id, .drop, note: "Paused")
      return
    }
    if state.paused {
      moveWork(row.id, .miss, note: "Stopped")
      return
    }
    guard !holds(row.id) else { return }
    // The link's id leads the row's key (`HookGate.Admitted.dedupeKey`: "<link id>:…").
    let link: String? = row.dedupeKey.split(separator: ":", maxSplits: 1).first.map(String.init)
    var queued = ScheduledTurn(
      reminder: RelayReminder(id: Self.linkTurnID(row.id), text: row.payload, due: row.due, action: true),
      initiator: .webhook, profileID: owner.id, ledgerID: row.id)
    queued.linkID = link
    scheduledQueue.append(queued)
    note("A link woke \(owner.name)", .auto)
    drainScheduled()
  }

  // MARK: scheduled requests and watches, unattended

  /// The life of an unanswered approval: reminded once after four hours, declined after a day.
  /// A step Relay asked for never waits forever. A deferred card (`deferAsk`) lives the same day,
  /// the life of the one-time yes it can give.
  private func sweepApprovals(now: Date) {
    for approval in approvals {
      switch RelayApproval.duty(askedAt: approval.askedAt, remindedAt: approval.remindedAt, now: now) {
      case .remind:
        if let index = approvals.firstIndex(where: { $0.id == approval.id }) {
          approvals[index].remindedAt = now
        }
        TaskNotifications.shared.post(
          threadID: threadID, title: "Relay still needs you",
          body: approval.title, always: true, kind: .ask)
      case .decline:
        approvals.removeAll { $0.id == approval.id }
        ApprovalEnds.shared.end(approval.id, .expired)
        approval.answer(.no)
        note("An approval nobody answered was declined after a day: \(approval.title)", .auto)
      case .none: break
      }
    }
  }

  /// Starts the next queued turn when Serein is idle, in its owner's own Main chat with that
  /// assistant's engine and scope (SPEC I10); the person's own requests are Serein's, the main
  /// assistant's. A turn whose owner's chat is busy (a hand-off works there) waits for it, and the
  /// next one goes. Its ledger row moves to started before the turn goes, so after a crash it is
  /// missed, never run again (`recoverAfterLaunch`).
  private func drainScheduled() {
    guard !working, !state.paused, activeScheduled == nil, !scheduledQueue.isEmpty else { return }
    guard let index = scheduledQueue.firstIndex(where: { ownerChatFree($0) }) else { return }
    let scheduled = scheduledQueue.remove(at: index)
    // A goal paused, ended or deleted after its check queued does not check; the next turn goes.
    let live = reminders.first { $0.id == scheduled.reminder.id }
    if scheduled.reminder.goal != nil, live?.goal == nil || live?.paused == true {
      dropWork(scheduled, note: "The goal was paused or ended before this check ran.")
      drainScheduled()
      return
    }
    let ownerID: String = scheduled.profileID ?? team.mainProfileID ?? team.activeID
    guard let owner = team.profiles.first(where: { $0.id == ownerID }) else {
      // Its assistant was deleted: nothing runs, and its failures pause the schedule.
      let why = "The assistant it belongs to was deleted."
      dropWork(scheduled, note: why)
      recordScheduleRun(scheduled.reminder, outcome: "failed", result: why)
      failScheduled(scheduled.reminder, detail: why)
      drainScheduled()
      return
    }
    // A paused assistant starts no turn (RelayProfile.paused): its queued turn is skipped.
    if owner.isPaused {
      dropWork(scheduled, note: "Paused")
      recordScheduleRun(scheduled.reminder, outcome: RelayReminder.skipped, result: "\(owner.name) is paused.")
      drainScheduled()
      return
    }
    // The briefing a fresh install starts with waits, like check-ins, until setup is done.
    if scheduled.reminder.id == RelayBriefing.reminderID, SereinChatSetup.shared.holdsCheckIns(self) {
      dropWork(scheduled, note: "Setup isn't finished")
      recordScheduleRun(scheduled.reminder, outcome: RelayReminder.skipped, result: "Setup isn't finished yet.")
      drainScheduled()
      return
    }
    let thread: String = owner.id == team.activeID ? threadID : mainThread(of: owner.id)
    // Its request in the step journal: the one it was queued again with, else a new one.
    let journal: String = scheduled.journal ?? UUID().uuidString
    activeScheduled = scheduled
    activeScheduled?.journal = journal
    turnSerial += 1
    if thread != threadID {
      ownerRun = OwnerRun(thread: thread, profileID: owner.id)
      ownerPersona = readState(RelayPersona.self, team.folder(owner.id) + "/persona.json") ?? RelayPersona()
    }
    // This turn's receipts, lines and plan card start empty in its chat (RelayAssistantTools.swift).
    desk.facts[thread] = nil
    desk.plans[thread] = nil
    scheduledRuleBlock = nil
    personTurn = false
    // An unattended turn reads what its request names: nothing it learns is the person's words.
    turnReadOutside = true
    sending = true
    cancelTurn = false
    var prompt: String
    if let live, let goal = live.goal {
      // The goal as it is now: the latest note and findings ride with the check.
      prompt = RelayGoal.prompt(text: live.text, goal: goal, now: RelayToolHost.stamp(Date()))
    } else {
      prompt = RelayUnattended.prompt(
        text: scheduled.reminder.text, repeats: scheduled.reminder.repeats, now: RelayToolHost.stamp(Date()),
        last: (live ?? scheduled.reminder).lastResult)
    }
    turnBrief = nil
    if scheduled.reminder.id == RelayBriefing.reminderID {
      let carry = PersonalCarry(agent: agent, into: thread)
      if let goals = RelayGoal.brief(briefGoals(now: Date(), carry: carry), now: Date()) { prompt += "\n" + goals }
      // The day's brief: the proactive loop neither briefs again today nor checks in right after.
      proactiveMemory.briefDay = RelayProactive.dayKey(Date())
      proactiveMemory.lastCheckIn = Date()
      persist(proactiveMemory, "relay/proactive.json")
      turnBrief = startBrief(prompt, carry: carry, in: thread)
      attachYesterday(to: thread)
    }
    // The owner thinks with its own engine (its route), in its own chat.
    restoreAfterLimit(owner.id)
    let engine = assistantEngine(owner)
    let target = AgentModel.DispatchTarget(
      mode: .anywhere, provider: engine.provider, model: engine.model, effort: engine.effort, actions: true,
      mac: true, relay: true, initiator: scheduled.initiator)
    let request = memoryRequest(for: scheduled)
    Task {
      // The row says started before the turn goes; one that another path moved first (Stop
      // Everything) does not run.
      let started = await startWork(scheduled)
      let current: Bool = activeScheduled?.reminder.id == scheduled.reminder.id
        && activeScheduled?.ledgerID == scheduled.ledgerID
      guard started, current else {
        sending = false
        cancelTurn = false
        if current { endScheduledHandover() }
        drainScheduled()
        return
      }
      await prepareMemory(request: request, thread: thread, profileID: owner.id)
      do {
        browser.stepJournal.nextTurn(in: thread, is: journal)
        defer { browser.stepJournal.settle(thread) }
        let id = try await agent.dispatch(prompt, into: thread, create: true, as: target)
        sending = false
        // Stop came while the turn was being handed over: it stops now that it started.
        if cancelTurn, let run = agent.hub.run(for: id) { agent.hub.stop(run) }
        cancelTurn = false
      } catch {
        sending = false
        cancelTurn = false
        endScheduledHandover()
        // The failure line belongs to the chat it ran in: a routine of another chat keeps its
        // reason in its run's record only, so "Send again" here never reruns something else.
        if thread == threadID { lastError = TurnFailure.couldNotAnswer(owner.name, reason: error.localizedDescription, app: engine.provider.name) }
        failWork(scheduled, note: String(error.localizedDescription.prefix(200)))
        if routineFailed(scheduled.reminder, run: nil, failure: error.localizedDescription, thread: thread) {
          drainScheduled()
          return
        }
        recordScheduleRun(
          scheduled.reminder, outcome: "failed", result: String(error.localizedDescription.prefix(200)), thread: thread)
        failScheduled(scheduled.reminder, detail: error.localizedDescription)
        drainScheduled()
      }
    }
  }
  /// What a scheduled turn's memory search reads (SPEC 4.7): a routine's own words. A link's
  /// turn reads the link's name and instruction only, never the delivery, which anyone who can
  /// call the link wrote; a delivery from a Settings hook searches with no words.
  private func memoryRequest(for scheduled: ScheduledTurn) -> String {
    guard scheduled.initiator == .webhook else { return scheduled.reminder.text }
    guard let id = scheduled.linkID, let link = desk.links.first(where: { $0.id == id }) else { return "" }
    return link.spec.name + " " + link.spec.instruction
  }
  /// A scheduled turn that did not start after all: nothing of it stays live.
  private func endScheduledHandover() {
    activeScheduled = nil
    ownerRun = nil
    ownerPersona = nil
    turnBrief = nil
    turnMemory = nil
    turnRules = nil
    turnCorrection = nil
  }
  /// Whether `turn`'s owner's chat can take it now. The active assistant's chat is free when
  /// Serein is (`working`); another one's while nothing runs or starts in it.
  private func ownerChatFree(_ turn: ScheduledTurn) -> Bool {
    let ownerID: String = turn.profileID ?? team.mainProfileID ?? team.activeID
    guard ownerID != team.activeID, team.profiles.contains(where: { $0.id == ownerID }) else { return true }
    guard let thread = knownMainThread(of: ownerID) else { return true }
    let busy: Bool = agent.hub.run(for: thread) != nil || handoffsStarting.contains(thread)
      || speakingElsewhere?.thread == thread
    return !busy
  }
  /// The end of a turn in another assistant's own chat (`ownerRun`): a scheduled turn, or the
  /// person's reply that went on after a switch. Its outcome lands as one in this chat does: the
  /// person's message is held at a usage limit or on a sign-in or connect card in that chat, then
  /// what waited for it goes.
  private func endOwnerRun(_ run: AgentRun, needs: [ConnectNeed]) {
    // Its receipts, system lines and plan card land on its reply in that chat.
    landTurnFacts(run)
    // Its result is unread on its owner's row until that chat is opened.
    if let owner = ownerRun, Self.landsWords(run) { noteReplyLanded(profileID: owner.profileID, thread: owner.thread) }
    let scheduled = activeScheduled
    ownerRun = nil
    ownerPersona = nil
    turnMemory = nil
    turnRules = nil
    turnCorrection = nil
    turnBrief = nil
    turnPage = nil
    activeScheduled = nil
    objectWillChange.send()
    var request: Held?
    if scheduled == nil, let kept = turnRequest, kept.thread == run.spec.threadID, run.spec.initiator == .relay {
      turnRequest = nil
      request = kept.held
    }
    let limited = holdLimited(run, request: request, scheduled: scheduled)
    if !limited, scheduled == nil { pressAnswered(run) }
    var carded = false
    if !limited, run.signedOut, let request, request.userMessage {
      showConnectCards(ConnectCards(threadID: run.spec.threadID, request: request, needs: [.aiApp(run.spec.provider)]))
      carded = true
    }
    if !limited, !carded, !needs.isEmpty, run.record.outcome != .stopped, let request, request.userMessage {
      showConnectCards(ConnectCards(threadID: run.spec.threadID, request: request, needs: needs))
      carded = true
    }
    if !limited, !carded, let request { Self.dropFiles(request) }
    if let scheduled {
      finishWork(scheduled, run: run, held: limited)
      if !limited { handleScheduled(scheduled.reminder, run: run) }
    }
    if !pending.isEmpty { sendPending() }
  }

  // MARK: the work ledger

  /// Opens the work ledger once, off the main thread, and runs its launch recovery before any
  /// scheduled turn: a run that had started becomes missed (nobody knows what it did, so it never
  /// runs again by itself) and joins the missed list, where the person skips it or starts a new
  /// run. Runs still queued come back to the queue; one that waited past its grace is listed as
  /// missed instead. UI previews open no ledger.
  private func openWork() {
    guard !RunMode.previewing else {
      workReady = true
      return
    }
    let url = browser.library.root.appendingPathComponent(Self.workFile)
    workOpening = Task { [weak self] in
      let opened = await Task.detached(priority: .utility) {
        () -> (ledger: OffMain<WorkLedger>, queued: [WorkLedger.Row], missed: [WorkLedger.Row])? in
        guard let ledger = try? WorkLedger(url: url) else { return nil }
        // Before any run: every started row becomes missed, and nothing runs it again.
        _ = try? ledger.recoverAfterLaunch()
        _ = try? ledger.prune()
        let queued: [WorkLedger.Row] = (try? ledger.queued(limit: WorkLedger.maxRows)) ?? []
        let missed: [WorkLedger.Row] = (try? ledger.missed(limit: WorkLedger.maxRows)) ?? []
        return (ledger: OffMain(ledger, label: "serein.relay.work"), queued: queued, missed: missed)
      }.value
      guard let self else { return }
      self.workReady = true
      guard let opened else {
        self.note("I could not open my list of queued work, so a quit or a crash may lose a scheduled run.", .auto)
        return
      }
      self.work = opened.ledger
      // The one ledger instance: the link receiver writes its rows there too (RelayWork.swift).
      self.desk.ledger = opened.ledger.store
      self.restoreWork(queued: opened.queued, missed: opened.missed)
      // The receiver starts again with the ledger, so a delivery is on disk before its 200.
      if !self.desk.links.isEmpty || self.hookServer != nil { self.restartHookServer() }
      self.drainScheduled()
    }
  }
  /// The rows the last launch left. A missed one joins the missed list once (Run now or Skip) and
  /// leaves the ledger's own list; a queued one queues again, or, when it waited past its grace,
  /// is missed and listed the same way. A row this build cannot read is dropped.
  private func restoreWork(queued: [WorkLedger.Row], missed: [WorkLedger.Row]) {
    guard let work else { return }
    var cleared: [Int64] = []
    var late: [Int64] = []
    var unreadable: [Int64] = []
    var unanswered: [Int64] = []
    var lostLinks = 0
    for row in missed {
      if let run = QueuedRun.decoded(row.payload) {
        listMissed(run.reminder, why: .interrupted)
      } else if row.kind == .link {
        lostLinks += 1
      }
      cleared.append(row.id)
    }
    if lostLinks > 0 {
      note("\(lostLinks) link deliver\(lostLinks == 1 ? "y" : "ies") stopped when Serein closed. Serein did not run \(lostLinks == 1 ? "it" : "them") again.", .auto)
    }
    let now = Date()
    for row in queued {
      guard let run = QueuedRun.decoded(row.payload) else {
        // An owned link's row holds the delivery's prompt, not a queued run (RelayHookServer).
        if row.kind == .link {
          enqueueLink(row)
        } else if row.kind == .proposal {
          // A deferred card comes back while its one-time yes could still live, and still needs
          // Allow; past its day it closes, and the step never runs without a new card.
          if let ask = RelayDeferred.restored(row.payload, now: now) {
            restoreDeferred(ask, key: row.dedupeKey)
          } else {
            unanswered.append(row.id)
          }
        } else {
          unreadable.append(row.id)
        }
        continue
      }
      if RelayMissedRun.isMissed(run.reminder, now: now) {
        listMissed(run.reminder, why: .asleep)
        late.append(row.id)
        continue
      }
      guard !holds(row.id) else { continue }
      scheduledQueue.append(restoredTurn(run, ledgerID: row.id))
    }
    let clear = cleared
    let miss = late
    let drop = unreadable
    let closed = unanswered
    work.post { ledger in
      for id in closed { _ = try ledger.move(id, .drop, note: "Nobody answered its card within a day.") }
      for id in miss { _ = try ledger.move(id, .miss, note: "It waited past its time while Serein was closed.") }
      for id in drop { _ = try ledger.move(id, .drop, note: "This build cannot read it.") }
      for id in clear + miss { _ = try ledger.clearMissed(id) }
    }
  }
  /// A queued turn from the ledger, with the kept sign-ins its live schedule still names. A
  /// one-time copy keeps none: a Sign out since the quit could not reach it.
  private func restoredTurn(_ run: QueuedRun, ledgerID: Int64) -> ScheduledTurn {
    var reminder = run.reminder
    reminder.signInSites = reminders.first { $0.id == reminder.id }?.signInSites
    return ScheduledTurn(
      reminder: reminder, initiator: run.initiator, profileID: run.profileID, retried: run.retried == true,
      ledgerID: ledgerID)
  }
  /// The ledger row `id` is the running or a queued turn already.
  private func holds(_ id: Int64) -> Bool {
    activeScheduled?.ledgerID == id || scheduledQueue.contains { $0.ledgerID == id }
  }
  /// Queues one turn Serein runs by itself: its ledger row first (what makes it survive a quit or
  /// a crash; `key` makes a repeat write nothing), then the queue; it starts when Serein is idle.
  func queueWork(_ turn: ScheduledTurn, kind: WorkLedger.Kind, key: String) {
    let id = turn.reminder.id
    let epoch = workEpoch
    writing.append(id)
    Task { [weak self] in
      guard let self else { return }
      let queued = await self.writeWork([(turn: turn, kind: kind, key: key)])
      if let index = self.writing.firstIndex(of: id) { self.writing.remove(at: index) }
      self.enqueue(queued, epoch: epoch)
    }
  }
  /// Turns whose rows were written join the queue, unless Stop Everything came while they were
  /// written: then their rows are dropped.
  private func enqueue(_ queued: [ScheduledTurn], epoch: Int) {
    guard epoch == workEpoch, !state.paused else {
      for turn in queued { dropWork(turn, note: "Stop Everything removed it before it ran.") }
      return
    }
    scheduledQueue.append(contentsOf: queued)
    drainScheduled()
  }
  /// Writes each turn's row (`WorkLedger.enqueue`, off the main thread). Returns the turns to
  /// queue, each with its row: a key the ledger already holds in another state is left out (it
  /// ran, or it was missed, and never runs twice), and so is one that waits there already. With no
  /// ledger, or when it cannot write, the turns queue in memory only, as before the ledger.
  private func writeWork(_ items: [(turn: ScheduledTurn, kind: WorkLedger.Kind, key: String)]) async -> [ScheduledTurn] {
    if !workReady { await workOpening?.value }
    guard let work else { return items.map(\.turn) }
    var entries: [(kind: WorkLedger.Kind, owner: String, key: String, payload: String, due: Date)?] = []
    for item in items {
      let run = QueuedRun(
        reminder: item.turn.reminder, initiator: item.turn.initiator, profileID: item.turn.profileID,
        retried: item.turn.retried)
      let entry: (kind: WorkLedger.Kind, owner: String, key: String, payload: String, due: Date)? = run.payload().map {
        (kind: item.kind, owner: run.owner, key: item.key, payload: $0, due: item.turn.reminder.due)
      }
      entries.append(entry)
    }
    let rows = entries
    let written: [WorkLedger.Row?]? = try? await work.run { (ledger: WorkLedger) -> [WorkLedger.Row?] in
      var out: [WorkLedger.Row?] = []
      for entry in rows {
        guard let entry else {
          out.append(nil)
          continue
        }
        let result = try ledger.enqueue(
          entry.kind, owner: entry.owner, dedupeKey: entry.key, payload: entry.payload, due: entry.due)
        out.append(result.row)
      }
      return out
    }
    guard let written else { return items.map(\.turn) }
    var out: [ScheduledTurn] = []
    for (index, item) in items.enumerated() {
      // Too long to write: it runs from memory, as before the ledger.
      guard index < written.count, let row = written[index] else {
        out.append(item.turn)
        continue
      }
      guard row.state == .queued, !holds(row.id) else { continue }
      var turn = item.turn
      turn.ledgerID = row.id
      out.append(turn)
    }
    return out
  }
  /// The row goes to started before its turn. False when another path moved it first, or when the
  /// ledger could not write it: a run whose start is not written down does not go.
  private func startWork(_ turn: ScheduledTurn) async -> Bool {
    guard let id = turn.ledgerID, let work else { return true }
    let moved: Bool? = try? await work.run { (ledger: WorkLedger) -> Bool in try ledger.move(id, .start) }
    guard let moved else {
      recordScheduleRun(turn.reminder, outcome: "failed", result: "I could not write down that it started, so it did not run.")
      return false
    }
    return moved
  }
  /// The row of a turn that ended: finished, or failed with why (the usage limit holds it).
  private func finishWork(_ turn: ScheduledTurn, run: AgentRun, held: Bool) {
    guard let id = turn.ledgerID, let work else { return }
    let resumes = run.record.outcome == .stopped && interruptedWork == id
    if interruptedWork == id { interruptedWork = nil }
    let done: Bool = run.record.outcome == .done && !held
    let transition: WorkLedger.Transition = done ? .finish : .fail
    let outcome = run.record.outcome.rawValue.replacingOccurrences(of: "_", with: " ")
    let note: String? = held ? "It waits for the AI app's usage limit."
      : resumes ? "You interrupted it. It runs again after your turn."
      : done ? nil : run.stepLimit.map(StepBudget.line) ?? "It ended: " + outcome
    work.post { ledger in _ = try ledger.move(id, transition, note: note) }
    if resumes { resumeLater(turn, row: id) }
  }
  /// Queues a turn the person interrupted once more (`WorkLedger.resumeKey`): it runs after
  /// their turn. A re-run that is interrupted again does not come back.
  private func resumeLater(_ turn: ScheduledTurn, row id: Int64) {
    guard let work else { return }
    let epoch = workEpoch
    Task { [weak self] in
      let key: String? = try? await work.run { (ledger: WorkLedger) -> String? in
        guard let row = try ledger.row(id: id), row.kind == .schedule else { return nil }
        return WorkLedger.resumeKey(row.dedupeKey)
      }
      guard let self, let resumeKey = key, epoch == self.workEpoch, !self.state.paused else { return }
      // A step of it has an unknown outcome: it does not run again by itself (`StepJournal`).
      if let journal = turn.journal, case .waits = self.browser.stepJournal.resend(request: journal) {
        self.note("An interrupted request was not run again. Serein cannot tell whether one of its steps finished", .auto)
        return
      }
      var again = turn
      again.ledgerID = nil
      self.queueWork(again, kind: .schedule, key: resumeKey)
    }
  }
  /// The row of a queued turn that will not run.
  private func dropWork(_ turn: ScheduledTurn, note: String) {
    guard let id = turn.ledgerID, let work else { return }
    work.post { ledger in _ = try ledger.move(id, .drop, note: note) }
  }
  /// The row of a turn that stopped: failed when it had started, else dropped.
  private func failWork(_ turn: ScheduledTurn, note: String) {
    guard let id = turn.ledgerID, let work else { return }
    work.post { ledger in
      let failed = try ledger.move(id, .fail, note: note)
      if !failed { _ = try ledger.move(id, .drop, note: note) }
    }
  }
  /// What came of one scheduled request: the reply decides whether the user hears anything;
  /// failures accumulate toward the pause. Every run lands in the schedule's history.
  private func handleScheduled(_ reminder: RelayReminder, run: AgentRun) {
    // A site rule that refused a step: it replaces a failure or an empty result, never a goal
    // check's findings or a question for the person.
    let ruleSite = scheduledRuleBlock
    scheduledRuleBlock = nil
    // Its step budget ran out: the schedule's history and the Board say so, in the budget's line.
    if let limit = run.stepLimit {
      recordScheduleRun(reminder, outcome: "stopped", result: StepBudget.line(limit), thread: run.spec.threadID,
                        tokens: run.record.tokens)
      return
    }
    if run.record.outcome == .stopped {
      note("Cancelled scheduled request “\(String(reminder.text.prefix(60)))”", .user)
      return
    }
    let reply = run.reportedSummary
      ?? run.transcript.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text ?? ""
    let thread = run.spec.threadID
    guard run.record.outcome == .done else {
      if let site = ruleSite {
        recordRuleBlock(reminder, site: site, thread: thread, tokens: run.record.tokens)
        return
      }
      if routineFailed(reminder, run: run, failure: reply, thread: thread) { return }
      recordScheduleRun(reminder, outcome: "failed", result: String(reply.prefix(200)), thread: thread, tokens: run.record.tokens)
      failScheduled(reminder, detail: reply.isEmpty ? "The run could not finish." : String(reply.prefix(200)))
      return
    }
    // A goal's check reports only what is new; a question for the user goes the usual way.
    if reminder.goal != nil, RelayMarks.after(RelayUnattended.inputMark, in: reply) == nil {
      goalChecked(reminder, reply: reply, thread: thread, tokens: run.record.tokens)
      return
    }
    switch RelayUnattended.interpret(reply: reply, failed: false) {
    case .quiet where ruleSite != nil, .report where ruleSite != nil:
      recordRuleBlock(reminder, site: ruleSite ?? "", thread: thread, tokens: run.record.tokens)
    case .quiet:
      recordScheduleRun(reminder, outcome: "nothing new", result: nil, thread: thread, tokens: run.record.tokens)
      note("Scheduled request “\(String(reminder.text.prefix(60)))”: nothing new", .auto)
    case .needsInput(let question):
      recordScheduleRun(reminder, outcome: "needs you", result: String(question.prefix(200)), thread: thread, tokens: run.record.tokens)
      dueReminders.append(reminder)
      // The notification opens the chat the run answered in: its owner's (SPEC I10). It holds
      // names only (SPEC I14): the question stays in the chat.
      let name = notificationName(thread: thread)
      TaskNotifications.shared.post(threadID: thread, title: name, body: "Needs you", always: true, kind: .ask)
      showPanel()
    case .report(let text):
      recordScheduleRun(reminder, outcome: "done", result: String(text.prefix(200)), thread: thread, tokens: run.record.tokens)
      // The report can hold words from mail, pages or another app: they stay in the chat.
      let name = notificationName(thread: thread)
      TaskNotifications.shared.post(threadID: thread, title: name, body: Self.updateBody(name), always: true)
    }
  }
  /// The name a notification about `thread` shows: the assistant whose chat it is, else Serein.
  func notificationName(thread: String) -> String {
    assistantOwning(thread: thread).map { profileName($0) } ?? RelayTeam.mainName
  }
  /// A notification body that holds a name only (SPEC 2.12, I14): "Scout has an update."
  static func updateBody(_ name: String) -> String { "\(name) has an update." }
  /// A check-in's notification: a name and how many ideas wait in Activity, never their words
  /// (SPEC I14): "Serein has 2 ideas."
  static func ideasBody(_ name: String, count: Int) -> String {
    count == 0 ? updateBody(name) : "\(name) has \(count == 1 ? "an idea" : "\(count) ideas")."
  }
  /// What came of one goal check: only findings never reported before reach the person, as a
  /// notification and on the goal's card; the note carries to the next check; a met goal or a run
  /// of quiet checks ends it, and it says why.
  private func goalChecked(_ reminder: RelayReminder, reply: String, thread: String, tokens: Int?) {
    guard let live = reminders.first(where: { $0.id == reminder.id }), let goal = live.goal else { return }
    // Pause or Done during the hand-over stopped nothing; the reply lands in the history only.
    guard live.paused != true else {
      recordScheduleRun(live, outcome: RelayReminder.skipped, result: "Paused while the check started.", thread: thread, tokens: tokens)
      return
    }
    let check = goal.read(reply, at: Date())
    let found = check.findings
    recordScheduleRun(
      live, outcome: found.isEmpty ? "nothing new" : "done",
      result: found.first.map { "\(found.count) new: " + String($0.text.prefix(160)) }, thread: thread, tokens: tokens)
    // The run limit may have paused it just now; the check lands on the schedule as it is.
    let counted = reminders.first { $0.id == reminder.id } ?? live
    let next = counted.checked(check)
    updateReminders { list in
      if let index = list.firstIndex(where: { $0.id == reminder.id }) { list[index] = next }
    }
    if !found.isEmpty {
      note("Goal \(Self.short(live.text)): \(found.count) new", .auto)
      // A finding is page text: the notification holds a name only, and the finding stays on
      // the goal's card (SPEC I14).
      let name = notificationName(thread: thread)
      TaskNotifications.shared.post(threadID: thread, title: name, body: Self.updateBody(name), always: true)
    } else {
      note("Goal \(Self.short(live.text)): nothing new", .auto)
    }
    if next.goalEnded, !counted.goalEnded { announceGoalEnd(next) }
  }
  /// Goals past their end date end and say why; the clock does this before anything runs.
  private func endDueGoals(now: Date) {
    let ending = reminders.compactMap { $0.endingIfDue(now: now) }
    guard !ending.isEmpty else { return }
    updateReminders { list in
      for goal in ending {
        if let index = list.firstIndex(where: { $0.id == goal.id }) { list[index] = goal }
      }
    }
    for goal in ending { announceGoalEnd(goal) }
  }
  private func announceGoalEnd(_ goal: RelayReminder) {
    let why = goal.goal?.ended ?? ""
    note("Goal \(Self.short(goal.text)) ended: \(why)", .auto)
    TaskNotifications.shared.post(
      threadID: threadID, title: "Goal ended", body: "\(Self.short(goal.text)): \(why)", always: true)
  }
  /// Done on a goal's card: it ends now and keeps its findings; a check queued or running stops.
  func endGoal(_ reminder: RelayReminder) {
    changeReminder(reminder.id, "Ended goal \(Self.short(reminder.text))") { $0 = $0?.ending("You marked it done") }
    stopChecks(reminder.id)
  }
  /// A goal's Pause and Done take effect at once: its queued check goes and a running one stops.
  private func stopChecks(_ id: String) {
    for turn in scheduledQueue where turn.reminder.id == id { dropWork(turn, note: "It was paused or ended before it ran.") }
    scheduledQueue.removeAll { $0.reminder.id == id }
    guard activeScheduled?.reminder.id == id else { return }
    if let run { agent.hub.stop(run) }
    if let owner = ownerRun, let other = agent.hub.run(for: owner.thread) { agent.hub.stop(other) }
  }
  /// One run in the schedule's history (the last ten). A run that ran counts toward the run
  /// limit, and the run that uses it up pauses the schedule and says so; a skipped one only lands
  /// in the history.
  private func recordScheduleRun(
    _ reminder: RelayReminder, outcome: String, result: String?, thread: String? = nil, tokens: Int? = nil
  ) {
    var stopped: RelayReminder?
    var overspent: RelayReminder?
    let now = Date()
    updateReminders {
      guard let i = $0.firstIndex(where: { $0.id == reminder.id }) else { return }
      let run = RelayReminder.Run(outcome: outcome, result: result, thread: thread, tokens: tokens)
      $0[i].history = Array((($0[i].history ?? []) + [run]).suffix(10))
      if outcome != RelayReminder.skipped, outcome != RelayReminder.missed {
        // A run that came back clears the failure streak; a failed one is counted by failScheduled.
        if outcome != "failed" {
          $0[i].failures = nil
          $0[i].lastResult = result
        }
        if $0[i].limit != nil {
          $0[i].runs = ($0[i].runs ?? 0) + 1
          if $0[i].limitReached, $0[i].paused != true {
            $0[i].paused = true
            stopped = $0[i]
          }
        }
      }
      // Its tokens count toward its week whatever came of the run, after the run limit: a run that
      // uses up both reads as the run limit.
      let counted = $0[i].counting(tokens: tokens ?? 0, now: now)
      $0[i] = counted.reminder
      if counted.paused { overspent = counted.reminder }
    }
    if let stopped, let limit = stopped.limit {
      note("Scheduled request \(Self.short(stopped.text)) stopped after \(limit) run\(limit == 1 ? "" : "s")", .auto)
    }
    if let overspent { announceCostPause(overspent, now: now) }
  }
  /// A schedule its weekly token limit paused: a line in Serein's chat and one notification, with
  /// the week's count and the day it runs again. Every other schedule keeps running.
  private func announceCostPause(_ reminder: RelayReminder, now: Date) {
    let used = UsageLedger.Summary.short(reminder.tokensThisWeek(now: now))
    let limit = reminder.weeklyTokens.map(UsageLedger.Summary.short) ?? ""
    let again = RelayReminder.nextWeek(after: now).formatted(.dateTime.weekday(.wide))
    note("Paused \(Self.short(reminder.text)) until \(again): it used \(used) of its \(limit) tokens this week", .auto)
    // Counts only (SPEC I14): the schedule's words stay in the chat line and in Automations.
    TaskNotifications.shared.post(
      threadID: threadID, title: "Serein paused a schedule until \(again)",
      body: "It used \(used) tokens this week, over its limit of \(limit). Your other schedules keep running. Turn it back on in Automations.",
      always: true)
  }
  /// Weekly token limits, each tick: a schedule its limit paused runs again once a new week began,
  /// and one already over its limit (the limit lowered, an undo) pauses before it runs again.
  private func checkWeeklyLimits(now: Date) {
    let lifted = reminders.compactMap { $0.liftingCostPause(now: now) }
    let over = reminders.filter { $0.action && $0.paused != true && $0.overWeeklyLimit(now: now) }
    guard !lifted.isEmpty || !over.isEmpty else { return }
    updateReminders { list in
      for reminder in lifted {
        if let i = list.firstIndex(where: { $0.id == reminder.id }) { list[i] = reminder }
      }
      for reminder in over {
        if let i = list.firstIndex(where: { $0.id == reminder.id }) { list[i] = list[i].pausingForCost() }
      }
    }
    for reminder in lifted where reminder.paused != true {
      note("\(Self.short(reminder.text)) runs again: a new week began", .auto)
    }
    for reminder in over { announceCostPause(reminder, now: now) }
  }
  /// The tokens of the turn an alert's change started, on the run that recorded the change.
  private func countWatchTurn(_ id: String, tokens: Int?) {
    guard let tokens, tokens > 0 else { return }
    updateWatches { list in
      guard let i = list.firstIndex(where: { $0.id == id }), let runs = list[i].history,
        let last = runs.lastIndex(where: { $0.outcome == "changed" })
      else { return }
      list[i].history?[last].tokens = tokens
    }
  }
  /// This schedule's run is going now or waits in the queue.
  private func isBusy(_ id: String) -> Bool {
    activeScheduled?.reminder.id == id || scheduledQueue.contains { $0.reminder.id == id }
      || held.contains { $0.scheduled?.reminder.id == id } || writing.contains(id)
  }
  /// Run now: one run of a scheduled request, queued exactly like a timed one, so it runs under
  /// the same unattended rules (`runsUnattended`: no Autopilot, every step judged as scheduled).
  /// The click gives it no more freedom. Its next time stays; the run counts toward the limit.
  /// False when it cannot run now (stopped, the limit reached, a paused goal); a run skipped
  /// because the last one is still going counts as handled.
  @discardableResult func runNow(_ reminder: RelayReminder) -> Bool {
    guard !state.paused, let current = reminders.first(where: { $0.id == reminder.id }), current.action,
      !current.limitReached, current.goal == nil || current.paused != true
    else { return false }
    if current.skipsWhileBusy, isBusy(current.id) {
      recordScheduleRun(current, outcome: RelayReminder.skipped, result: "The last run was still going.")
      return true
    }
    note("Running scheduled request \(Self.short(current.text)) now", .user)
    queueWork(
      ScheduledTurn(reminder: current, initiator: .scheduled, profileID: current.profileID), kind: .schedule,
      key: "now:\(current.id):" + UUID().uuidString)
    return true
  }
  /// A request that did not run at its time (the Mac asleep, Serein closed or stopped, or the AI
  /// app's usage limit): listed in Serein's chat with one notification, once per schedule
  /// (RelayMissedRun.adding). The caller decides it was missed; nothing here runs it.
  func listMissed(_ reminder: RelayReminder, why: RelayMissedRun.Why) {
    let listed = RelayMissedRun.adding(reminder, why: why, to: missedRuns)
    guard listed != missedRuns else { return }
    missedRuns = listed
    let missed = RelayMissedRun(reminder: reminder, why: why)
    note(missed.line, .auto)
    TaskNotifications.shared.post(threadID: threadID, title: missed.title, body: missed.name, always: true)
  }
  /// The missed card's Run now is off: Serein is stopped, or the schedule used up its run limit.
  func missedBlocked(_ missed: RelayMissedRun) -> Bool {
    state.paused || reminders.first { $0.id == missed.id }?.limitReached == true
  }
  /// Run now on a missed run: the same run Run now in Settings starts, under the same unattended
  /// rules and cards. The card goes only once the run is under way. A one-time request has left
  /// the list, so its copy queues the same way.
  func runMissed(_ missed: RelayMissedRun) {
    guard !state.paused else { return }
    if reminders.contains(where: { $0.id == missed.id }) {
      if runNow(missed.reminder) { missedRuns.removeAll { $0.id == missed.id } }
      return
    }
    missedRuns.removeAll { $0.id == missed.id }
    // A repeating schedule that is no longer listed was deleted meanwhile: nothing runs.
    guard missed.reminder.action, missed.reminder.repeats == .none else { return }
    note("Running scheduled request \(Self.short(missed.reminder.text)) now", .user)
    queueWork(
      ScheduledTurn(reminder: missed.reminder, initiator: .scheduled, profileID: missed.reminder.profileID),
      kind: .schedule, key: "now:\(missed.reminder.id):" + UUID().uuidString)
  }
  /// Skip: the missed run is dropped; the schedule's history says so and its next run stays.
  func skipMissed(_ missed: RelayMissedRun) {
    missedRuns.removeAll { $0.id == missed.id }
    recordScheduleRun(missed.reminder, outcome: RelayReminder.skipped, result: missed.title + ".")
  }
  func pauseSchedule(_ reminder: RelayReminder) {
    changeReminder(reminder.id, "Paused \(Self.short(reminder.text))") { $0 = $0?.pausing() }
    if reminder.goal != nil { stopChecks(reminder.id) }
  }
  private func failScheduled(_ reminder: RelayReminder, detail: String) {
    let failures = (reminder.failures ?? 0) + 1
    let pause = RelayUnattended.shouldPause(failures: failures)
    updateReminders {
      if let i = $0.firstIndex(where: { $0.id == reminder.id }) {
        $0[i].failures = failures
        $0[i].lastResult = String(detail.prefix(200))
        if pause { $0[i].paused = true }
      }
    }
    note("Scheduled request “\(String(reminder.text.prefix(60)))” failed (\(failures))", .auto)
    if pause {
      TaskNotifications.shared.post(
        threadID: threadID, title: "Serein paused a schedule",
        body: "“\(String(reminder.text.prefix(80)))” failed \(failures) times and is paused. Resume it in Settings › Assistants.",
        always: true)
      showPanel()
    }
  }
  /// The user resumed a schedule they, the failure limit, the run limit or an update paused.
  func resumeSchedule(_ reminder: RelayReminder) {
    let now = Date()
    changeReminder(reminder.id, "Resumed \(Self.short(reminder.text))") { $0 = $0?.resumed(now: now) }
  }
  /// A routine card's switch (`Receipt.item` holds the schedule's id): the person's own press
  /// pauses or turns on that schedule, as Settings does, with no model turn and no typed words, so
  /// no stored text ever counts as the person's message. Turning on keeps `ScheduleGuard`'s count.
  func setRoutineOn(id: String, on: Bool) {
    guard !TodoBoard.isReminder(id), let reminder = reminders.first(where: { $0.id == id }) else { return }
    let paused: Bool = reminder.paused == true
    if !on {
      if !paused { pauseSchedule(reminder) }
      return
    }
    guard paused else { return }
    let others: Int = ScheduleRequest.actionRoutinesOn(reminders, except: id)
    if let refusal = ScheduleRequest.refusal(
      repeats: reminder.repeats, cron: reminder.cron, acts: reminder.action, actionRoutinesOn: others)
    {
      lastError = refusal.words
      return
    }
    resumeSchedule(reminder)
  }
  // MARK: the team

  private func saveTeam() { persist(team, "relay/team.json") }
  static let handoffsFile = "relay/handoffs.json"
  static let macAccessFile = "relay/mac-access.json"
  func saveHandoffs() { persist(handoffLedger, Self.handoffsFile) }
  /// One change to the roster or its teams, applied at once and journaled with the roster before
  /// and after, so Settings can undo it (`undoTeam`). `change` returns nil to refuse. An assistant
  /// that leaves keeps its files in relay/removed until no journal entry can bring it back.
  @discardableResult
  func changeTeam(actor: String = "user", _ summary: String, _ change: (RelayTeam) -> RelayTeam?) -> Bool {
    guard let next = change(team), next != team else { return false }
    let before = team
    team = next
    saveTeam()
    if let id = next.mainProfileID, let level = next.profiles.first(where: { $0.id == id })?.speaksFirst, level != proactiveLevel {
      syncSpeaksFirst(main: level)
    }
    moveProfileFolders(before: before, after: next)
    if let entry = RelayJournal.teamEntry(actor: actor, summary: summary, before: before, after: next) {
      teamJournal = RelayJournal.trimmed(teamJournal + [entry])
      persist(teamJournal, "relay/team-journal.json")
    }
    purgeRemovedProfiles()
    purgeUnusedPictures()
    knownCache = nil
    note(summary, actor == "user" ? .user : .allowed)
    return true
  }
  /// The person undid one change to the roster; the undo is itself journaled, so it can be undone.
  /// False when the roster changed since (undo newer changes first) or the active assistant would go.
  @discardableResult
  func undoTeam(_ entry: RelayJournalEntry) -> Bool {
    guard let restored = RelayJournal.undoneTeam(entry, current: team) else { return false }
    let removed = Set(team.profiles.map(\.id)).subtracting(restored.profiles.map(\.id))
    guard changeTeam("Undid: " + entry.text, { _ in restored }) else { return false }
    for id in removed { endHandoffs(involving: id) }
    return true
  }
  /// Assistants that left the roster move to relay/removed/<id>; those an undo brings back return.
  private func moveProfileFolders(before: RelayTeam, after: RelayTeam) {
    let files = FileManager.default
    let root = browser.library.root
    let removedDir = root.appendingPathComponent("relay/removed", isDirectory: true)
    let beforeIDs = Set(before.profiles.map(\.id)), afterIDs = Set(after.profiles.map(\.id))
    for id in beforeIDs.subtracting(afterIDs) {
      let from = root.appendingPathComponent(before.folder(id), isDirectory: true)
      guard files.fileExists(atPath: from.path) else { continue }
      try? files.createDirectory(at: removedDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let to = removedDir.appendingPathComponent(id, isDirectory: true)
      try? files.removeItem(at: to)
      try? files.moveItem(at: from, to: to)
    }
    for id in afterIDs.subtracting(beforeIDs) {
      let from = removedDir.appendingPathComponent(id, isDirectory: true)
      let to = root.appendingPathComponent(after.folder(id), isDirectory: true)
      guard files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) else { continue }
      try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try? files.moveItem(at: from, to: to)
    }
  }
  /// Files of removed assistants that no journal entry can bring back any more are deleted.
  private func purgeRemovedProfiles() {
    let removedDir = browser.library.root.appendingPathComponent("relay/removed", isDirectory: true)
    guard let ids = try? FileManager.default.contentsOfDirectory(atPath: removedDir.path), !ids.isEmpty else { return }
    let reachable = Set(teamJournal.flatMap { ($0.priorTeam?.profiles ?? []) + ($0.nextTeam?.profiles ?? []) }.map(\.id))
    for id in ids where !reachable.contains(id) {
      try? FileManager.default.removeItem(at: removedDir.appendingPathComponent(id, isDirectory: true))
    }
  }
  /// Pictures in an assistant's folder that it no longer wears and no journal entry can put back
  /// (each pick is saved under a new name, so Undo finds the one before) are deleted, as is one
  /// saved for a change that was then refused.
  private func purgeUnusedPictures() {
    let files = FileManager.default
    let journaled = teamJournal.flatMap { ($0.priorTeam?.profiles ?? []) + ($0.nextTeam?.profiles ?? []) }
    let worn = Set((team.profiles + journaled).compactMap { $0.icon?.pictureFile })
    for profile in team.profiles {
      let folder = browser.library.root.appendingPathComponent(team.folder(profile.id), isDirectory: true)
      for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
      where AssistantIcon.isPictureName(name) && !worn.contains(name) {
        try? files.removeItem(at: folder.appendingPathComponent(name))
      }
    }
  }
  /// Adds an assistant (a profile with its own persona, thread and notes). Refused while
  /// Relay works, like switching.
  func addProfile(_ name: String) -> Bool {
    guard !working, let next = team.adding(name) else { return false }
    return changeTeam("Added assistant \(next.profiles.last?.name ?? name)") { _ in next }
  }
  func renameProfile(_ id: String, to name: String) -> Bool {
    guard let next = team.renaming(id, to: name) else { return false }
    team = next
    saveTeam()
    return true
  }
  /// The one writer of routes (`setProfileRoute`, "All assistants"), saved outside the journal.
  func setRoutes(_ change: (RelayTeam) -> RelayTeam?) -> Bool {
    guard let next = change(team), next != team else { return false }
    team = next
    saveTeam()
    return true
  }
  /// Deletes an assistant and takes it out of every team. Its chats stay in History and its files
  /// wait in relay/removed, so Undo brings it back whole; its open hand-offs end.
  func removeProfile(_ id: String) -> Bool {
    let name = team.profiles.first { $0.id == id }?.name ?? "an assistant"
    guard changeTeam("Deleted assistant \(name)", { $0.removing(id) }) else { return false }
    endHandoffs(involving: id)
    return true
  }
  /// Deletes a team; its assistants stay.
  @discardableResult
  func removeGroup(_ id: String) -> Bool {
    let name = team.teams.first { $0.id == id }?.name ?? "a team"
    return changeTeam("Deleted team \(name)") { $0.removingGroup(id) }
  }
  /// A proposed team after "Create team": the new assistants, each answering to its own name, and
  /// the team. Refused when the roster no longer fits what the card showed.
  func createTeam(_ proposal: TeamProposal, actor: String) throws -> [RelayProfile] {
    var created: [RelayProfile] = []
    let names = proposal.members.map(\.name).joined(separator: ", ")
    let made = changeTeam(actor: actor, "Created team \(proposal.name) with \(names)") { current in
      guard let result = current.addingTeam(proposal) else { return nil }
      created = result.created
      return result.team
    }
    guard made else {
      throw SereinError.invalid("The team no longer fits (a name is taken, or there are too many assistants), so nothing was created.")
    }
    for profile in created { persist(RelayPersona(name: profile.name), team.folder(profile.id) + "/persona.json") }
    return created
  }
  /// An assistant's Main chat. Another assistant's comes from its own state.json, which is written
  /// now when it has none yet, so its chat stays the same from the first hand-off on.
  /// An assistant's Main chat id, without making one: nil before its first chat (for display).
  func existingThread(of profileID: String) -> String? {
    if profileID == team.activeID { return threadID }
    if let cached = mainThreadCache[profileID] { return cached }
    return browser.library.load(State.self, from: team.folder(profileID) + "/state.json")?.threadID
  }
  func mainThread(of profileID: String) -> String {
    if profileID == team.activeID { return threadID }
    let path = team.folder(profileID) + "/state.json"
    // A state.json that does not decode is never written over (`persist` refuses it).
    if let saved = readState(State.self, path) { return saved.threadID }
    let fresh = State()
    persist(fresh, path)
    knownCache = nil
    mainThreadCache[profileID] = fresh.threadID
    return fresh.threadID
  }
  /// Switching is possible now: no scheduled turn runs, no turn is starting and no message waits
  /// behind a reply (the queue belongs to the chat on screen). The person's own reply goes on in
  /// its chat (`switchTo`), one at a time; any other run there holds the switch, since only that
  /// reply ends through `endOwnerRun`. A queued turn runs in its owner's own chat whichever
  /// assistant is active, so it does not hold a switch.
  var canSwitchAssistant: Bool {
    guard activeScheduled == nil, !sending, !handoffsStarting.contains(threadID), pending.isEmpty || !working else {
      return false
    }
    guard let run else { return true }
    // Words it has not read yet come back to this chat if it ends without reading them.
    guard run.steering.waiting.isEmpty else { return false }
    if let owner = ownerRun { return owner.thread == threadID }
    return run.spec.relay && run.spec.initiator == .relay
  }
  /// Answers with the profile's persona, thread and notes from here on. A reply running in the
  /// chat left goes on there as its owner's (`ownerRun`, as a routine runs in its owner's chat);
  /// what the person sends meanwhile waits for it to end.
  func switchTo(_ id: String) -> Bool {
    guard canSwitchAssistant, let next = team.switching(to: id) else {
      return false
    }
    if run != nil, ownerRun == nil {
      ownerRun = OwnerRun(thread: threadID, profileID: team.activeID)
      ownerPersona = persona
    }
    // A reply going on in its chat keeps its page and brief until it ends (`endOwnerRun`).
    if ownerRun == nil {
      turnPage = nil
      turnBrief = nil
    }
    cancelWelcome()
    // The chat left stays this assistant's Main chat; the board reads it from here on.
    mainThreadCache[team.activeID] = threadID
    // Each assistant keeps the words typed to it and not sent.
    SereinSurface.main.draft = TurnActivity.swapDraft(
      &drafts, leaving: team.activeID, typed: SereinSurface.main.draft, opening: id)
    team = next
    saveTeam()
    state = readState(State.self, dir + "/state.json") ?? State()
    knownCache = nil
    // This assistant's notes and proposals come from the memory store (`refreshNotes`); its tidy
    // proposals and its journal from its own folder.
    notes = []
    tidyProposals = readState([RelayNote].self, dir + "/proposals.json") ?? []
    proposals = tidyProposals
    journal = readState([RelayJournalEntry].self, dir + "/journal.json") ?? []
    persona = readState(RelayPersona.self, dir + "/persona.json") ?? RelayPersona()
    Task { [weak self] in await self?.refreshNotes() }
    capture?.cancel()
    capture = nil
    dropPending()
    // The pane beside the chat redraws for the assistant now answering.
    AssistantInspector.shared.follow(id)
    objectWillChange.send()
    note("Now talking with \(team.activeName)", .user)
    return true
  }

  /// Saves the persona. A change to its standing instructions is journaled like a note change
  /// ("user" from Settings, "relay" after the person allowed its proposal), so it can be undone.
  func updatePersona(_ persona: RelayPersona, actor: String = "user") {
    let before = self.persona.rules
    let clean = persona.sanitized() ?? RelayPersona()
    self.persona = clean
    persist(clean, dir + "/persona.json")
    guard let entry = RelayJournal.instructionEntry(actor: actor, before: before, after: clean.rules) else { return }
    journal = RelayJournal.trimmed(journal + [entry])
    persist(journal, dir + "/journal.json")
  }
  /// Replaces only the standing instructions, keeping the name and the line about the user.
  func updateInstructions(_ rules: String, actor: String = "user") {
    updatePersona(RelayPersona(name: persona.name, about: persona.about, rules: rules), actor: actor)
  }
  /// The daily morning briefing, off by default: one ordinary scheduled request with a fixed id.
  var briefing: Bool {
    get { reminders.contains { $0.id == RelayBriefing.reminderID && $0.paused != true } }
    set {
      objectWillChange.send()
      // Already briefed today (either way): the first 9:00 brief is tomorrow's.
      let now = Date()
      let briefed = proactiveMemory.briefDay == RelayProactive.dayKey(now)
      updateReminders { list in
        list.removeAll { $0.id == RelayBriefing.reminderID }
        if newValue {
          list.append(RelayReminder(
            id: RelayBriefing.reminderID, text: RelayBriefing.text,
            due: RelayUnattended.nextMorning(
              after: briefed ? (Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now) : now),
            repeats: .daily, action: true))
        }
      }
    }
  }

  // MARK: watches

  func updateWatches(_ change: (inout [RelayWatch]) -> Void) {
    var copy = watches
    change(&copy)
    watches = copy
    persist(watches, "relay/watches.json")
  }
  /// One change to one alert, applied at once and recorded so it can be undone (changeReminder).
  func changeWatch(_ id: String, actor: String = "user", _ summary: String, _ change: (inout RelayWatch?) throws -> Void) rethrows {
    let before = watches.first { $0.id == id }
    var after = before
    try change(&after)
    guard after != before else { return }
    updateWatches { list in
      if let index = list.firstIndex(where: { $0.id == id }) {
        if let after { list[index] = after } else { list.remove(at: index) }
      } else if let after {
        list.append(after)
      }
    }
    // The snapshot leaves out the last answer and its fingerprint: no read lingers after a delete,
    // and an undo learns the starting answer again rather than firing on a stale one.
    recordChange(
      RelayScheduleChange(
        actor: actor, summary: summary, kind: .watch, itemID: id,
        watch: before.map {
          var w = $0
          w.fingerprint = nil
          w.lastAnswer = nil
          return w
        }))
  }
  func pauseWatch(_ watch: RelayWatch) {
    changeWatch(watch.id, "Paused \(Self.short(watch.name))") { $0 = $0?.pausing() }
  }
  /// One check in the alert's history (the last ten).
  private func recordWatchCheck(_ id: String, outcome: String, result: String? = nil, thread: String? = nil) {
    updateWatches {
      guard let i = $0.firstIndex(where: { $0.id == id }) else { return }
      let run = RelayReminder.Run(outcome: outcome, result: result, thread: thread)
      $0[i].history = Array((($0[i].history ?? []) + [run]).suffix(10))
    }
  }

  /// Starts every due, unpaused watch's check; the clock calls this every 15 seconds.
  func checkWatches(now: Date = Date()) {
    guard !state.paused else { return }
    for watch in watches where watch.paused != true && watch.due(now: now) { startCheck(watch, now: now) }
  }
  /// Check now: the same check the clock starts, once, outside the interval. One check per watch
  /// at a time, and none while Stop Everything holds Serein.
  func checkWatchNow(_ watch: RelayWatch) {
    guard !state.paused, let current = watches.first(where: { $0.id == watch.id }) else { return }
    startCheck(current, now: Date())
  }
  private func startCheck(_ watch: RelayWatch, now: Date) {
    guard !checking.contains(watch.id) else { return }
    // Marked before the check: a slow check must not stampede.
    updateWatches { if let i = $0.firstIndex(where: { $0.id == watch.id }) { $0[i].lastCheckedAt = now } }
    checking.insert(watch.id)
    Task { [weak self] in
      await self?.checkWatch(watch)
      self?.checking.remove(watch.id)
    }
  }

  /// A scheduled request a Never rule stopped: it lands in the history as the rule, not a failure.
  private func recordRuleBlock(_ reminder: RelayReminder, site: String, thread: String, tokens: Int? = nil) {
    recordScheduleRun(reminder, outcome: "blocked by your rule", result: SiteRules.personLine(site), thread: thread, tokens: tokens)
    note("Scheduled request “\(String(reminder.text.prefix(60)))”: blocked by your rule for \(site)", .auto)
  }

  /// One check: run the read, compare the fingerprint, and on a change queue a turn that tells
  /// the user what changed — through the same unattended protocol as a scheduled request.
  func checkWatch(_ watch: RelayWatch) async {
    // A site set to Never pauses its alert instead of failing it again every interval.
    if watch.kind == .url, SiteRules.rule(for: watch.source) == .never {
      let site = SiteRules.site(watch.source) ?? "this site"
      updateWatches { if let i = $0.firstIndex(where: { $0.id == watch.id }) { $0[i].paused = true } }
      recordWatchCheck(watch.id, outcome: "blocked by your rule", result: SiteRules.personLine(site) + " The alert is paused.")
      note("Alert “\(String(watch.name.prefix(60)))” paused: blocked by your rule for \(site)", .auto)
      return
    }
    // An assistant's watch stays inside what that assistant may use now (a deleted one: nothing).
    if let id = watch.profileID {
      let owner = profile(id: id)
      let place: AssistantPlace = watch.kind == .url ? .web : .mac
      if effectiveScope(owner).map({ !$0.allows(place) || (watch.kind == .url && $0.blocks(watch.source)) }) == true {
        updateWatches { if let i = $0.firstIndex(where: { $0.id == watch.id }) { $0[i].paused = true } }
        recordWatchCheck(watch.id, outcome: "outside \(owner.name)'s places", result: "\(owner.name) can't check this any more. The alert is paused.")
        note("Alert “\(String(watch.name.prefix(60)))” paused: outside \(owner.name)'s places", .auto)
        return
      }
    }
    guard let answer = await runWatchCheck(watch) else {
      failWatch(watch, detail: watch.kind == .script ? "The script could not run." : "The page could not be fetched.")
      return
    }
    let fingerprint = RelayWatches.textFingerprint(answer)
    let head = RelayWatch.answerHead(answer)
    // Deleted, or its read edited, while this check ran: the answer belongs to nothing listed now.
    guard watches.first(where: { $0.id == watch.id })?.source == watch.source else { return }
    if let previous = watch.fingerprint, previous != fingerprint {
      let old = watch.lastAnswer ?? "the starting answer"
      updateWatches {
        if let i = $0.firstIndex(where: { $0.id == watch.id }) {
          $0[i].fingerprint = fingerprint
          $0[i].lastAnswer = head
          $0[i].failures = nil
        }
      }
      // What the watch read is page or app text: fenced as data, never an instruction (I6). The
      // name is escaped too; the prompt keeps RelayWatch's lead, so the chat shows it as an alert.
      let shownName: String = UntrustedText.escape(String(watch.name.prefix(80)))
      let text: String = RelayWatch.changePrompt(name: shownName, before: old, now: head)
      let fired = ScheduledTurn(
        reminder: RelayReminder(text: text, due: Date(), action: true),
        initiator: .watch, profileID: watch.profileID, watchID: watch.id)
      recordWatchCheck(watch.id, outcome: "changed", result: String(head.prefix(200)), thread: threadID)
      if watchMayWake(watch.id) {
        note("Alert “\(String(watch.name.prefix(60)))” fired", .auto)
        queueWork(fired, kind: .schedule, key: "watch:\(watch.id):" + UUID().uuidString)
      }
    } else {
      updateWatches {
        if let i = $0.firstIndex(where: { $0.id == watch.id }) {
          $0[i].fingerprint = fingerprint
          $0[i].lastAnswer = head
          $0[i].failures = nil
        }
      }
      recordWatchCheck(watch.id, outcome: watch.fingerprint == nil ? "first check" : "nothing new")
    }
  }

  /// The read behind a watch: an AppleScript over the approved apps, or a page fetch. Runs off
  /// the main actor with a timeout and a bounded answer; nil means it failed.
  private func runWatchCheck(_ watch: RelayWatch) async -> String? {
    switch watch.kind {
    case .script:
      // A stored watch re-proves the read grammar every time: a watch edited out of band, or
      // written by an older build, never runs unattended.
      guard RelayWatch.validScript(watch.source) else { return nil }
      let source = watch.source
      return await Task.detached { () -> String? in
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = source.components(separatedBy: "\n").flatMap { ["-e", $0] }
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer)
        defer { timer.cancel() }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.prefix(24_000), as: UTF8.self)
      }.value
    case .url:
      let source = watch.source.trimmingCharacters(in: .whitespacesAndNewlines)
      // Defence: checkWatch already paused a watch on a Never site. A redirect onto one is not
      // followed either (FetchRedirects).
      guard let url = URL(string: source), SiteRules.rule(for: source) != .never else { return nil }
      return await Task.detached { () -> String? in
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 SereinWatch/1.0", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .default, delegate: FetchRedirects(nil), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty
        else { return nil }
        let text = RelayWatches.visibleText(String(decoding: data.prefix(2_000_000), as: UTF8.self))
        return text.isEmpty ? nil : text
      }.value
    }
  }

  private func failWatch(_ watch: RelayWatch, detail: String) {
    let failures = (watch.failures ?? 0) + 1
    let pause = RelayUnattended.shouldPause(failures: failures)
    updateWatches {
      if let i = $0.firstIndex(where: { $0.id == watch.id }) {
        $0[i].failures = failures
        if pause { $0[i].paused = true }
      }
    }
    recordWatchCheck(watch.id, outcome: "failed", result: detail)
    note("Alert “\(String(watch.name.prefix(60)))” failed (\(failures))", .auto)
    if pause {
      TaskNotifications.shared.post(
        threadID: threadID, title: "Serein paused an alert",
        body: "“\(String(watch.name.prefix(80)))” failed \(failures) times and is paused. Resume it in Settings › Assistants.",
        always: true)
      showPanel()
    }
  }
  /// The user resumed a watch they, the failure limit or an update paused.
  func resumeWatch(_ watch: RelayWatch) {
    changeWatch(watch.id, "Resumed \(Self.short(watch.name))") { $0 = $0?.resumed() }
  }
  private func save() { persist(state, dir + "/state.json") }
  func persist<T: Encodable>(_ value: T, _ path: String) {
    // A file that did not decode is never written over (`keptAside`).
    guard !unwritable.contains(path) else { return }
    do {
      // Profile folders come into existence with their first file, not up front.
      let file = browser.library.root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try browser.library.save(value, to: path)
    } catch {
      lastError = "Serein could not save \(path): \(error.localizedDescription)"
    }
  }
}

extension RelayOrchestrator {
  /// `--ui-relay` previews (release builds too, only under `--ui-preview`): a short Main chat, a
  /// delegated run, a few steps and one approval. Serein shows as connected through `previewReady`,
  /// so no AI app is made available.
  /// `--ui-relay-new` leaves the chat empty (the hologram's large stage) with the run working.
  /// `--ui-relay-no-ai` stops before any of it: no AI app, so the column shows the connect card.
  func previewSeed() {
    guard CommandLine.arguments.contains("--ui-preview"), !CommandLine.arguments.contains("--ui-relay-no-ai") else { return }
    let now = Date()
    if let name = CommandLine.arguments.drop(while: { $0 != "--ui-relay-look" }).dropFirst().first, let look = RelayLook.preset(name) {
      looks.set(look, by: .relay, own: true, reason: "A preview", at: now)
    }
    let fresh = CommandLine.arguments.contains("--ui-relay-new") || Self.previewPageChat
    // The quit and close questions: `--ui-serein-quit-guard` has Serein's two tasks working;
    // `--ui-serein-quit-guard request` and `--ui-serein-close-guard` have nothing working and
    // the 9:00 request coming up; `--ui-serein-close-guard work` keeps Serein's task working
    // too, so the sheet says Serein quits when its work is done.
    let quitArgument = CommandLine.arguments.drop(while: { $0 != "--ui-serein-quit-guard" }).dropFirst().first
    let closeArgument = CommandLine.arguments.drop(while: { $0 != "--ui-serein-close-guard" }).dropFirst().first
    let closeGuard = CommandLine.arguments.contains("--ui-serein-close-guard")
    let guardRequest = closeGuard
      || (CommandLine.arguments.contains("--ui-serein-quit-guard") && quitArgument == "request")
    let guardWork = CommandLine.arguments.contains("--ui-serein-quit-guard") && !guardRequest
    // `--ui-relay-idle`: no delegated run either, so nothing but Relay itself is on screen.
    // `--ui-serein-chat`: Serein's chat with its transcript only, nothing working or waiting.
    // `serein-side` is the same chat, unless an approval preview asks for a waiting card.
    let chatOnly = CommandLine.arguments.contains("--ui-serein-chat") || (Self.previewSide && !Self.previewApprovalOnly)
    // `--ui-serein-busy`: Serein replying, with a message waiting for it (Send when done).
    // `--ui-serein-stop-reply`: the reply just stopped while two of its tasks still work.
    // `--ui-serein-notify-card`: a task card with the notification question under it.
    let busy = CommandLine.arguments.contains("--ui-serein-busy")
    let stoppedReply = CommandLine.arguments.contains("--ui-serein-stop-reply")
    let notifyCard = CommandLine.arguments.contains("--ui-serein-notify-card")
    // `--ui-serein-task-cards`: finished tasks in this chat, a done, a failed and a stopped card
    // and one from an earlier launch, with the strip on “Done today”.
    // `--ui-serein-toast` (or `--ui-serein-toast several`): the finish toast.
    // `--ui-serein-direct-needs`: a task you started (not Serein) waiting for your answer.
    // `--ui-serein-stop-idle` (or `none`): a bare “stop” with nothing of Serein's own running:
    // “2 tasks are working. Stop them · Keep them going”, or “Nothing is running.”.
    let taskCards = CommandLine.arguments.contains("--ui-serein-task-cards") || Self.previewHint == .taskDone
    let toastArgument = CommandLine.arguments.drop(while: { $0 != "--ui-serein-toast" }).dropFirst().first
    let toast = CommandLine.arguments.contains("--ui-serein-toast")
    let directNeeds = CommandLine.arguments.contains("--ui-serein-direct-needs")
    let stopIdle = CommandLine.arguments.contains("--ui-serein-stop-idle")
    let stopIdleNone = stopIdle && CommandLine.arguments.drop(while: { $0 != "--ui-serein-stop-idle" }).dropFirst().first == "none"
    // `--ui-serein-bar-reply`: the ⌥Space bar's reply card on an exchange just answered;
    // `--ui-serein-bar-approval`: the bar holding the Mail card (with Later); `--ui-serein-waiting`:
    // that card waiting while Serein is hidden (the slim line and the row's Needs you);
    // `--ui-serein-offline`: offline with a task working and a message held.
    let barReply = CommandLine.arguments.contains("--ui-serein-bar-reply")
    let barApproval = CommandLine.arguments.contains("--ui-serein-bar-approval")
    let offline = CommandLine.arguments.contains("--ui-serein-offline")
    let idle = Self.previewHint != nil || barReply || barApproval || CommandLine.arguments.contains("--ui-relay-idle")
      || (chatOnly && !stoppedReply && !notifyCard && !(stopIdle && !stopIdleNone)) || busy
      || taskCards || stopIdleNone || directNeeds
      || (guardRequest && !(closeGuard && closeArgument == "work"))
    // `--ui-serein-request-warning` (or `--ui-serein-reminder-line request|kept|allow|off`): the
    // line under a reminder Serein just set. A request line follows a request turn ("every
    // morning at 9"); a notification line follows the plain reminder at 3:45.
    let line = CommandLine.arguments.contains("--ui-serein-request-warning") ? "request"
      : CommandLine.arguments.drop(while: { $0 != "--ui-serein-reminder-line" }).dropFirst().first
    let requestTurn = line == "request" || line == "kept" || guardRequest
    var nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
    if nine <= now { nine = Calendar.current.date(byAdding: .day, value: 1, to: nine) ?? nine }
    if guardRequest {
      // Only in memory: a preview never writes the reminders file.
      reminders = [RelayReminder(
        id: "relay-preview-request", text: "Check my inbox and tell me what needs me", due: nine,
        repeats: .daily, action: true)]
    }
    // `--ui-agents-schedules`, `--ui-automations`, `--ui-waiting`: routines with one run missed
    // while the Mac slept, one paused by its weekly token limit, two coming up (one near its
    // limit) and the last day's runs (only in memory). Automations and Waiting on you add a
    // second failure in a row (so the inbox routine needs you), an hourly routine with runs
    // earlier and later today, and a page watch.
    let spaces = CommandLine.arguments.contains("--ui-automations") || CommandLine.arguments.contains("--ui-waiting")
    if CommandLine.arguments.contains("--ui-agents-schedules") || spaces {
      var brief = RelayReminder(id: "relay-preview-brief", text: "Morning brief", due: nine, repeats: .daily, action: true)
      brief.history = [RelayReminder.Run(at: now.addingTimeInterval(-3 * 3600), outcome: "done", result: "2 events, 1 run needs you",
                                         tokens: 8_900)]
      brief = brief.counting(tokens: 26_700, now: now).reminder
      var inbox = RelayReminder(id: "relay-preview-inbox", text: "Check my inbox and tell me what needs me",
                                due: now.addingTimeInterval(2 * 3600), repeats: .weekdays, action: true)
      inbox.history = [RelayReminder.Run(at: now.addingTimeInterval(-90 * 60), outcome: "nothing new", tokens: 4_200),
                       RelayReminder.Run(at: now.addingTimeInterval(-30 * 60), outcome: "failed", result: "Mail did not answer",
                                         tokens: 1_300)]
      inbox.weeklyTokens = 25_000
      inbox = inbox.counting(tokens: 21_400, now: now).reminder
      var prices = RelayReminder(id: "relay-preview-prices", text: "Watch flight prices to Tokyo", due: now.addingTimeInterval(1800),
                                 repeats: .cron, action: true, cron: RelayReminder.cron(everyMinutes: 30))
      prices.history = [RelayReminder.Run(at: now.addingTimeInterval(-4 * 3600), outcome: "nothing new", tokens: 3_100)]
      prices.weeklyTokens = 50_000
      prices = prices.counting(tokens: 51_200, now: now).reminder
      reminders = [brief, inbox, prices]
      if spaces {
        inbox.history?.append(RelayReminder.Run(at: now.addingTimeInterval(-10 * 60), outcome: "failed",
                                                result: "Mail did not answer", tokens: 900))
        // The first top of the hour at least 30 minutes away, so no run comes due during a capture.
        let hour = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(1800))?.end ?? now.addingTimeInterval(3600)
        var tidy = RelayReminder(id: "relay-preview-tidy", text: "Tidy my Downloads folder", due: hour,
                                 repeats: .cron, action: true, cron: "0 * * * *")
        tidy.history = [RelayReminder.Run(at: now.addingTimeInterval(-2 * 3600), outcome: "done", result: "Moved 4 files", tokens: 600),
                        RelayReminder.Run(at: now.addingTimeInterval(-3600), outcome: "nothing new", tokens: 300)]
        reminders = [brief, inbox, prices, tidy]
        watches = [RelayWatch(id: "relay-preview-lamp", name: "Desk lamp price", kind: .url,
                              source: "https://example.com/desk-lamp", minutes: 60,
                              lastCheckedAt: now.addingTimeInterval(-20 * 60))]
      }
      missedRuns = RelayMissedRun.adding(
        RelayReminder(id: "relay-preview-backup", text: "Back up the shop-web database", due: now.addingTimeInterval(-6 * 3600),
                      repeats: .daily, action: true), why: .asleep, to: [])
    }
    if CommandLine.arguments.contains("--ui-serein-paused-by-update") {
      // Settings › Serein after the migration paused what sat dormant (only in memory).
      reminders = AssistantMigration.pausing([RelayReminder(
        id: "relay-preview-paused", text: "Check my inbox and tell me what needs me", due: nine,
        repeats: .daily, action: true)])
      watches = AssistantMigration.pausing([RelayWatch(
        id: "relay-preview-paused-watch", name: "Desk lamp price", kind: .url,
        source: "https://example.com/desk-lamp", minutes: 60)])
    }
    let reminderTurn = requestTurn
      ? [AgentMessage(role: "you", text: "Every morning at 9, check my inbox and tell me what needs me."),
         AgentMessage(role: "assistant", text: "Done: I’ll check your inbox every morning at \(nine.formatted(date: .omitted, time: .shortened)).")]
      : [AgentMessage(role: "you", text: "Thanks. Remind me 15 minutes before the review."),
         AgentMessage(role: "assistant", text: "Done: I'll remind you at 3:45 pm.")]
    switch line {
    case "request": reminderNotice = .keepRunning(when: QuitGuard.when(nine, now: now))
    case "kept": reminderNotice = .keptInMenuBar
    case "allow": reminderNotice = .allowNotifications
    case "off": reminderNotice = .notificationsOff
    default: break
    }
    var thread = Conversation(
      id: threadID, title: "What’s on my calendar today?",
      messages: [
        AgentMessage(role: "you", text: "What’s on my calendar today?"),
        AgentMessage(role: "assistant", text: "Three things: **stand-up at 10:00**, lunch with Maya at 12:30, and the design review at 4 pm.\n\nI also asked Codex to fix the failing checkout tests in *shop-web*.\n\nI'll tell you when it's done."),
      ] + reminderTurn,
      provider: .claude, mode: .anywhere, projectID: nil, remoteID: nil, scope: "", updatedAt: now)
    thread.lastMessageAt = now
    thread.serein = true
    if barReply {
      thread.messages += [
        AgentMessage(role: "you", text: Self.previewBarPrompt),
        AgentMessage(role: "assistant", text: "Done. I will remind you **today at 5:00 PM** to call Maya.\n\n- It shows as a notification, even if Serein is closed.\n- Say *“move it to 6”* to change the time."),
      ]
    }
    if chatOnly {
      // `--ui-serein-chat`: a message sent with a chip (its name under the words), and an
      // earlier chat, so the full header shows Past chats.
      thread.messages += [
        AgentMessage(role: "you", text: "Which of these should I read first?", attached: ["Part of “Checkout redesign notes”"]),
        AgentMessage(role: "assistant", text: "Start with the second section: the review at 4 pm is about it."),
        AgentMessage(role: "you", text: "What was the fix for the checkout tests?"),
        AgentMessage(role: "assistant", text: "Codex found it. The test waited a fixed 2 seconds:\n\n```swift\nlet paid = try await checkout.wait(until: .paid)\n```\n\nWant me to open the pull request?"),
        // A bare DONE draws nothing and must leave the face on the bubble above it.
        AgentMessage(role: "assistant", text: "DONE"),
      ]
      // `--ui-serein-burst`: three messages in a row, answered one by one, unread.
      if CommandLine.arguments.contains("--ui-serein-burst") {
        thread.messages += [
          AgentMessage(role: "you", text: "Book the table for Friday", burstIndex: 1),
          AgentMessage(role: "you", text: "Also what's the weather then?", burstIndex: 2),
          AgentMessage(role: "you", text: "And remind Maya", burstIndex: 3),
          AgentMessage(id: "preview-burst-reply", role: "assistant",
                       text: "[reply 1] Booked, 7 pm at Ichiran.\n\n[reply 2] Clear, about 18°.\n\n[reply 3] Done, she gets a reminder on Thursday."),
        ]
        unreadFrom[threadID] = "preview-burst-reply"
      }
      // `--ui-serein-key-ask`: the key card for a cloud computer, under the reply that asks for it.
      if CommandLine.arguments.contains("--ui-serein-key-ask"), let e2b = ConnectLink(app: "e2b", kind: .key) {
        var asks = AgentMessage(role: "assistant", text: "I need your E2B key to move my computer there.")
        asks.connect = [e2b]
        thread.messages += [AgentMessage(role: "you", text: "Move your computer to E2B"), asks]
      }
      // `--ui-serein-github-ask`: GitHub's one-click pill, under the reply that needs it (issue 83).
      // Add `--ui-serein-github-sheet` to open its token sheet too.
      if CommandLine.arguments.contains("--ui-serein-github-ask"), let github = ConnectLink(app: "github", kind: .mcp) {
        var asks = AgentMessage(role: "assistant", text: "I need GitHub connected to read your open pull requests.")
        asks.connect = [github]
        thread.messages += [AgentMessage(role: "you", text: "What pull requests are waiting on me?"), asks]
      }
      // `--ui-serein-post`: a thread for X under the reply that drafted it, the second post too long.
      if CommandLine.arguments.contains("--ui-serein-post") {
        var drafted = AgentMessage(role: "assistant", text: "Here's a thread. The second one runs long.")
        drafted.post = PostDraft(posts: [
          "We shipped key cards in Serein today 🔑\n\nYour assistant asks for a cloud key right in the chat, and it goes straight to Keychain. It never sees it.",
          "How it works: the model only asks for the place by name (E2B, Daytona). The card is the host's, the field is masked, and Save writes the Keychain item directly. A value that does not look like a key gets a plain red reason and the field clears at once, so nothing lingers on screen. Not now settles the card to one line.",
          "Try it in the next build. Thanks @e2b_dev #buildinpublic https://github.com/codejunkie99/serein-personal-assistant",
        ])
        thread.messages += [AgentMessage(role: "you", text: "Write a thread for X about the key card"), drafted]
      }
      // `--ui-serein-ui <queue|trip|week>`: a view drawn under a reply (`ui_show`), alone in the
      // chat so the whole card shows.
      if let sample = CommandLine.arguments.drop(while: { $0 != "--ui-serein-ui" }).dropFirst().first,
        let tree = UITreeSamples.tree(sample)
      {
        // One id for every launch, so what was set in the sample is still there after a relaunch.
        var drew = AgentMessage(id: "ui-preview-" + sample, role: "assistant", text: "Here it is.")
        drew.view = tree
        thread.messages = [AgentMessage(role: "you", text: UITreeSamples.asked(sample)), drew]
        // `--ui-serein-ui-values <file>`: what an earlier launch saved (`UITreeValues.file`), read
        // the way a relaunch reads it. The preview's own library is new each launch.
        if let saved = CommandLine.arguments.drop(while: { $0 != "--ui-serein-ui-values" }).dropFirst().first,
          let data = FileManager.default.contents(atPath: saved)
        {
          try? data.write(to: browser.library.root.appendingPathComponent(UITreeValues.file))
          UITreeValues.shared.open(browser.library)
        }
        // `--ui-serein-ui-pressed <button>`: the person pressed that button and the answer drew
        // the view again (`UITreeSamples.after`), placed the way a running turn's is (`redraw`).
        if let label = CommandLine.arguments.drop(while: { $0 != "--ui-serein-ui-pressed" }).dropFirst().first,
          let after = UITreeSamples.after(sample)
        {
          let words: String = UITreeValues.shared.kept.message(tree, in: drew.id, pressing: label)
          UITreeValues.shared.kept.press(words, in: drew.id)
          thread.messages += [AgentMessage(role: "you", text: words), AgentMessage(role: "assistant", text: after.words)]
          _ = AgentMessage.redraw(after.tree, kept: &UITreeValues.shared.kept, in: &thread.messages)
        }
      }
      let yesterday = now.addingTimeInterval(-26 * 3600)
      var past = Conversation(
        id: "relay-preview-past", title: "Find the best-rated ramen near me",
        messages: [
          AgentMessage(role: "you", text: "Find the best-rated ramen near me"),
          AgentMessage(role: "assistant", text: "Ichiran on 5th is the best rated nearby."),
        ],
        provider: .claude, mode: .anywhere, projectID: nil, remoteID: nil, scope: "", updatedAt: yesterday)
      past.lastMessageAt = yesterday
      past.serein = true
      agent.conversations.insert(past, at: 0)
      state.pastThreadIDs = [past.id]
    }
    if CommandLine.arguments.contains("--ui-chat-top") {
      // `--ui-chat-top`: the chat's picture and name, with sessions at work and a text about one of
      // them. `--ui-tasks-panel` opens the right panel on Tasks.
      let now = Date()
      ExternalSessionStore.shared.update([
        ExternalSession(id: "preview.claude", driver: .claude, title: "Sign-in fix", cwd: "/synthetic/shop-web", state: .needsUser, updatedAt: now, pid: getpid()),
        ExternalSession(id: "preview.codex", driver: .codex, title: "Checkout tests", cwd: "/synthetic/checkout", state: .running, updatedAt: now, pid: getpid()),
        ExternalSession(id: "preview.pi", driver: .pi, title: "Tidy notes", cwd: "/synthetic/notes", state: .running, updatedAt: now, pid: getpid()),
        ExternalSession(id: "preview.grok", driver: .grok, title: "Docs", cwd: "/synthetic/docs", state: .running, updatedAt: now, pid: getpid()),
      ])
      var question = AgentMessage(role: "assistant", text: "Claude Code needs you in shop-web.", notice: true)
      question.waitingSession = "preview.claude"
      thread.messages += [
        AgentMessage(role: "assistant", text: "Morning. Two things finished while you were away.", notice: true), question,
      ]
    }
    if CommandLine.arguments.contains("--ui-session-status") {
      // `--ui-session-status`: a session waiting in another app (the row at the chat's foot) and
      // three turns that ended with nothing to report (one Sessions finished card). The saved
      // "needs you" text is one an older Serein wrote: the row says it now, so it never draws.
      let waiting = ExternalSession(
        id: "preview.waiting", driver: .claude, title: "Sign-in fix", cwd: "/synthetic/shop-web", state: .needsUser, updatedAt: now)
      let settings = ExternalSession(
        id: "claude:preview-settings", driver: .claude, title: "Settings redesign", cwd: "/synthetic/serein agent", state: .open, updatedAt: now)
      ExternalSessionStore.shared.update([waiting, settings])
      SessionStatusTexts.shared.previewWaiting(waiting.id, since: now.addingTimeInterval(-4 * 60))
      var question = AgentMessage(role: "assistant", text: "Claude Code needs you in shop-web.", notice: true)
      question.waitingSession = waiting.id
      let rows = [
        SessionFinish(id: "preview.finish.1", sessionID: "opencode:preview-router", app: "OpenCode", title: nil,
          folder: "codex-router", minutes: 37, endedAt: now.addingTimeInterval(-50 * 60)),
        SessionFinish(id: "preview.finish.2", sessionID: "claude:preview-what", app: "Claude Code", title: "What is this?",
          folder: "serein agent", minutes: 4, endedAt: now.addingTimeInterval(-30 * 60)),
        SessionFinish(id: "preview.finish.3", sessionID: settings.id, app: "Claude Code", title: "Settings redesign",
          folder: "serein agent", minutes: 13, endedAt: now.addingTimeInterval(-12 * 60)),
      ]
      var card = AgentMessage(role: "assistant", text: SessionFinishes.text(rows), notice: true)
      card.finished = rows
      thread.messages += [question, card]
    }
    if CommandLine.arguments.contains("--ui-decision-dock") {
      // `--ui-decision-dock`: the Mail approval, a session waiting in another app and a question,
      // one after another in the dock above the composer.
      ExternalSessionStore.shared.update([ExternalSession(
        id: "preview.dock", driver: .claude, title: "Sign-in fix", cwd: "/synthetic/shop-web", state: .needsUser, updatedAt: now)])
      var asked = AgentMessage(role: "assistant", text: "Claude Code needs you in shop-web.", notice: true)
      asked.waitingSession = "preview.dock"
      asked.sentAt = now.addingTimeInterval(1)
      thread.messages += [asked]
    }
    if CommandLine.arguments.contains("--ui-serein-reply") {
      // `--ui-serein-reply`: a sent reply with its quote chip and a sent picture (a synthetic
      // gradient), and the composer's reply bar on Serein's last message.
      let picture = NSImage(size: NSSize(width: 360, height: 240), flipped: false) { rect in
        NSGradient(colors: [NSColor(red: 0.95, green: 0.55, blue: 0.3, alpha: 1), NSColor(red: 0.35, green: 0.3, blue: 0.85, alpha: 1)])?
          .draw(in: rect, angle: 35)
        return true
      }
      let png = picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
      var shot = AgentMessage(role: "you", text: "This is the poster for the trip.")
      shot.images = png.flatMap { browser.saveChatPicture($0) }.map { [$0] }
      shot.attached = ["Pasted picture"]
      let answer = AgentMessage(role: "assistant", text: "Booked the 9:40 ferry to Lisbon for Saturday. The poster looks great.")
      let reply = AgentMessage(role: "you", text: DraftQuote.draft(quoting: answer.text, before: "is it refundable?"))
      thread.messages += [shot, answer, reply, AgentMessage(role: "assistant", text: "Yes, until Friday at noon.")]
      SereinSurface.main.replyingTo = ReplyTarget(text: "Yes, until Friday at noon.", from: team.activeName)
    }
    if CommandLine.arguments.contains("--ui-session-report") {
      // `--ui-session-report`: a session that really finished, told briefly.
      var report = AgentMessage(role: "assistant", text: """
        Codex in shop-web: The checkout button now stays visible on small screens, and the sticky footer no longer covers it.
        Edited 2 files · ran tests
        """, notice: true)
      report.aboutSession = "Codex|shop-web"
      // `--ui-session-report-reel`: the same report with its reel (synthetic files and counts).
      if CommandLine.arguments.contains("--ui-session-report-reel") {
        var reel = ReportReel(title: "Claude Code in serein agent")
        reel.files = [
          .init(path: "Sources/Serein/UISDK/waiting-card.css", added: 29, removed: 64),
          .init(path: "Sources/Serein/SessionStatusTexts.swift", added: 45, removed: 34),
        ]
        reel.filesTotal = 2; reel.added = 74; reel.removed = 98; reel.minutes = 9
        // `--ui-session-report-reel media` (or `media8`): with four (or eight) pictures it made,
        // synthetic gradients, in the grid; eight fill it and leave "+5" on the last tile.
        let mediaArgument = CommandLine.arguments.drop(while: { $0 != "--ui-session-report-reel" }).dropFirst().first
        if mediaArgument == "media" || mediaArgument == "media8" {
          let names = ["settings-light.png", "settings-dark.png", "settings-sidebar-small.png", "settings-wide.png",
                       "settings-models.png", "settings-privacy.png", "settings-usage.png", "settings-about.png"]
          let shades: [(String, NSColor, NSColor)] = names.prefix(mediaArgument == "media8" ? 8 : 4).enumerated().map { index, name in
            let hue = CGFloat(index) / 8
            return (name, NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1),
                    NSColor(hue: hue + 0.1, saturation: 0.6, brightness: 0.4, alpha: 1))
          }
          reel.media = shades.compactMap { name, from, to in
            let picture = NSImage(size: NSSize(width: 1280, height: 800), flipped: false) { rect in
              NSGradient(colors: [from, to])?.draw(in: rect, angle: 35)
              (name as NSString).draw(at: NSPoint(x: 48, y: 48), withAttributes: [
                .font: NSFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
              return true
            }
            guard let png = picture.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]),
              let path = browser.saveChatPicture(png) else { return nil }
            return ReportReel.Media(kind: .image, path: path, name: name, project: "serein agent", made: now)
          }
        }
        report.reel = reel
      }
      thread.messages += [report]
    }
    if CommandLine.arguments.contains("--ui-ideas") {
      // `--ui-ideas`: a check-in that brought two ideas, waiting in the chat and in Activity.
      let reply = "Two things from this morning.\nIDEA: Draft a reply to Maya about the 4 pm review | Mail: Maya, 9:12 AM\nIDEA: Move the dentist reminder to Friday | Reminders"
      thread.messages += [AgentMessage(role: "you", text: RelayProactive.prompt(.checkIn)), AgentMessage(role: "assistant", text: reply)]
      ideas = RelayProactive.ideas(in: reply)
    }
    if CommandLine.arguments.contains("--ui-serein-automatic") {
      // `--ui-serein-automatic`: turns Serein started itself, each as its “why” line: a scheduled
      // request, one with nothing new (hidden), an alert's change, a webhook and a check-in.
      let stamp = RelayToolHost.stamp(now)
      thread.messages += [
        AgentMessage(role: "you", text: RelayHook.prompt(source: "GitHub", body: #"{"action":"opened","pull_request":"Fix checkout"}"#, key: nil)),
        AgentMessage(role: "assistant", text: "GitHub: a pull request “Fix checkout” was opened."),
        AgentMessage(role: "you", text: RelayProactive.prompt(.checkIn)),
        AgentMessage(role: "assistant", text: "You have 20 minutes before the design review. Want me to pull up the notes?"),
        AgentMessage(role: "you", text: RelayWatch.changePrompt(name: "Flight price to Tokyo", before: "$420", now: "$380")),
        AgentMessage(role: "assistant", text: "The flight to Tokyo dropped from $420 to $380, its lowest this month."),
        AgentMessage(role: "you", text: RelayUnattended.prompt(text: "Back up the shop-web database", repeats: .daily, now: stamp)),
        AgentMessage(role: "assistant", text: "NOTHING NEW"),
        AgentMessage(role: "you", text: RelayUnattended.prompt(text: "Check my inbox and tell me what needs me", repeats: .weekdays, now: stamp)),
        AgentMessage(role: "assistant", text: "Two emails need you: Maya asked about the 4 pm review, and Northwind's invoice is due Friday."),
      ]
    }
    if Self.previewDoHere {
      // “Do it here”: the user asked from the page, so Serein asks before it works there.
      thread.messages = [
        AgentMessage(role: "you", text: "Fill in the feedback form on this page with my notes. Do it here."),
        AgentMessage(role: "assistant", text: "I will fill it in on this page once you say yes."),
      ]
      thread.title = "Fill in the feedback form on this page"
    }
    if CommandLine.arguments.drop(while: { $0 != "--ui-setup-offer" }).dropFirst().first == SereinSetup.Topic.files.rawValue {
      // `--ui-setup-offer files`: the person asked about a file while reading is off.
      // A preview keeps gates in memory, so this turns nothing off on disk.
      GateSettings.shared.set(false, forKey: MacFiles.wholeMacKey)
      thread.messages = [
        AgentMessage(role: "you", text: "What does the plan on my Desktop say about the launch date?"),
        AgentMessage(role: "assistant", text: "I can't read your files yet. You can allow it on the card below, and I'll look right after."),
      ]
      thread.title = "The plan on my Desktop"
    }
    if let card = CommandLine.arguments.drop(while: { $0 != "--ui-mac-access-card" }).dropFirst().first {
      // `--ui-mac-access-card waiting|granted`: the chat's Accessibility card, or the line the chat
      // carried on from. Only in memory.
      thread.messages = [
        AgentMessage(role: "you", text: "Turn on Do Not Disturb until 5."),
        AgentMessage(role: "assistant", text: "I need Accessibility to use your Mac. The card below shows how, and I'll carry on once it's on."),
      ]
      if card == "granted" {
        thread.messages += [AgentMessage(role: "you", text: MacAccessWait.followUp),
                            AgentMessage(role: "assistant", text: "Done. Do Not Disturb is on until 5 PM.")]
      } else {
        macAccess = MacAccessWait(chats: [thread.id: .waiting])
      }
      thread.title = "Do Not Disturb until 5"
    }
    if !fresh { agent.conversations.insert(thread, at: 0) }
    let child = AgentRun(
      spec: RunSpec(threadID: "relay-preview-child", provider: .codex, executable: "/usr/bin/false", model: "",
        effort: "medium", mode: .project, projectID: nil, projectName: "shop-web", title: "Fix the failing checkout tests",
        scope: "Synthetic preview", autoRouting: false, grants: RunGrants(edits: true, projectName: "shop-web"),
        limits: RunLimits(hard: nil, idle: 3600)),
      taskID: "relay-preview-task", transcript: [])
    child.phase = "Running the tests"
    if !idle {
      agent.hub.adoptPreview(child)
      state.children = [Child(threadID: "relay-preview-child", edits: true, startedAt: now, chatID: threadID,
                              messageID: thread.messages.first?.id)]
    }
    if guardWork || stoppedReply || (stopIdle && !stopIdleNone) {
      // A second task, so the ⌘Q question and the header both say 2 things.
      let second = AgentRun(
        spec: RunSpec(threadID: "relay-preview-child-2", provider: .claude, executable: "/usr/bin/false", model: "",
          effort: "medium", mode: .project, projectID: nil, projectName: "shop-web", title: "Draft the release notes",
          scope: "Synthetic preview", autoRouting: false, grants: RunGrants(edits: true, projectName: "shop-web"),
          limits: RunLimits(hard: nil, idle: 3600)),
        taskID: "relay-preview-task-2", transcript: [])
      second.phase = "Writing"
      agent.hub.adoptPreview(second)
      state.children.append(Child(threadID: "relay-preview-child-2", edits: true, startedAt: now, chatID: threadID,
                                  messageID: thread.messages.first?.id))
    }
    activity = [
      Activity(text: "Ran a Calendar script", how: .auto),
      Activity(text: "Asked Codex to work on shop-web: Fix the failing checkout tests", how: .auto),
      Activity(text: "Scheduled “Design review in 15 minutes” for Oct 22 at 3:45 PM", how: .auto),
    ]
    if busy {
      // Serein's own turn, working on a new question; the earlier exchange stays above it.
      let asked = AgentMessage(role: "you", text: "Find me a flight to Tokyo next Friday")
      let turn = AgentRun(
        spec: RunSpec(threadID: threadID, provider: .claude, executable: "/usr/bin/false", model: "",
          effort: "medium", mode: .anywhere, projectID: nil, projectName: nil, title: "Serein · Reply",
          scope: "Synthetic preview", autoRouting: false, grants: RunGrants(), limits: RunLimits(hard: nil, idle: 3600),
          relay: true),
        taskID: "relay-preview-turn", transcript: (agent.conversations.first { $0.id == threadID }?.messages ?? []) + [asked])
      turn.phase = "Checking flights…"
      // Its trail above the reply: what it used so far, the newest still going.
      turn.record.startedAt = now.addingTimeInterval(-19)
      let seeded: [(String, [String: Any], TimeInterval)] = [
        ("recall", ["query": "travel"], -17), ("files_find", ["query": "passport"], -14),
        ("WebSearch", [:], -9), ("navigate", ["url": "https://www.google.com/travel/flights"], -4),
      ]
      turn.steps = seeded.map { tool, arguments, seconds in
        let label = tool == "WebSearch" ? "Searched the web for “flights to Tokyo”" : AgentStep.label(tool: tool, arguments: arguments)
        return AgentStep(time: now.addingTimeInterval(seconds), tool: tool, label: label)
      }
      agent.hub.adoptPreview(turn)
      pending = ["also check trains"]
    }
    if stoppedReply { stopNotice = .stoppedReply(working: 2) }
    if stopIdle { stopNotice = .idle(working: stopIdleNone ? 0 : 2) }
    if taskCards { previewFinishedTasks(chat: thread, now: now) }
    if directNeeds {
      let waiting = AgentRun(
        spec: RunSpec(threadID: "relay-preview-direct", provider: .claude, executable: "/usr/bin/false", model: "",
          effort: "medium", mode: .project, projectID: nil, projectName: "shop-web", title: "Compare the two pricing pages",
          scope: "Synthetic preview", autoRouting: false, grants: RunGrants(projectName: "shop-web"),
          limits: RunLimits(hard: nil, idle: 3600)),
        taskID: "relay-preview-direct-task", transcript: [])
      waiting.record.outcome = .waiting
      waiting.record.endedAt = now.addingTimeInterval(-60)
      agent.hub.adoptPreview(waiting)
    }
    if Self.previewDoHere {
      let card = CurrentPageContext.workHereCard(title: "Workspace design notes")
      approvals = [Approval(title: card.title, detail: card.detail, button: card.button, threadID: threadID) { _ in }]
    }
    if toast {
      let several = toastArgument == "several"
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SereinFinishToast.preview(several: several) }
    }
    // The quit and close questions keep the chat plain behind them: no approval or form waits.
    if Self.previewHint == .asksBefore {
      answered = [AnsweredApproval(id: UUID(), title: "Click “Archive” in Notes?", allowed: true, at: now, threadID: threadID)]
    }
    if Self.previewHint == nil, !fresh, !guardWork, !guardRequest, !chatOnly, !busy, !stoppedReply, !notifyCard, !taskCards, !toast, !directNeeds,
      !stopIdle, !barReply, !offline {
      let send = ApprovalCopy.macStep(kind: "click", label: "Send", app: "Mail")
      // `--ui-question quick|list|typed|steps|answered`: one form in its own style, without the
      // approval; answered shows a form and an approval already answered, as replies.
      let question = CommandLine.arguments.drop(while: { $0 != "--ui-question" }).dropFirst().first
      if question == nil || question == "answered" {
        approvals = [Approval(title: send.title, detail: send.detail, button: "Allow", threadID: threadID) { _ in }]
        // `--ui-routine-approval`: a routine step that only Every step stops, with its one-click switch.
        if CommandLine.arguments.contains("--ui-routine-approval") {
          let click = ApprovalCopy.macStep(kind: "click", label: "New Note", app: "Notes")
          approvals = [Approval(title: click.title, detail: click.detail, button: "Allow", threadID: threadID, routine: true) { _ in }]
        }
        previewApprovals()
      }
      let turn = thread.messages.last(where: { $0.role == "you" })?.id
      switch question {
      case "quick":
        questionForms = [QuestionForm(title: "Before I book the flight", questions: [
          RelayQuestion(id: "cabin", label: "Which cabin?", choices: ["Economy", "Premium economy", "Business"]),
        ], after: turn, threadID: threadID) { _ in }]
      case "list":
        questionForms = [QuestionForm(title: "Two flights fit", questions: [
          RelayQuestion(id: "flight", label: "Which flight?", choices: [
            "TAP · 8:05 to 10:40 — Direct, arrives before lunch · $380",
            "Ryanair · 6:30 to 9:15 — Direct, bags cost extra · $290",
          ]),
        ], after: turn, threadID: threadID) { _ in }]
      case "typed":
        questionForms = [QuestionForm(title: "Before I book the flight", questions: [
          RelayQuestion(id: "notes", label: "Anything the booker should know?"),
        ], after: turn, threadID: threadID) { _ in }]
      case "answered":
        approvals = []
        answeredQuestions = [AnsweredQuestion(
          id: UUID(), items: [
            AnsweredQuestion.Item(question: "Which cabin?", answer: "Economy", choices: ["Economy", "Premium economy", "Business"]),
            AnsweredQuestion.Item(question: "Anything the booker should know?", answer: nil),
          ], at: now, threadID: threadID, after: turn)]
        answered = [AnsweredApproval(id: UUID(), title: send.title, allowed: true, at: now, threadID: threadID)]
      default:
        if CommandLine.arguments.contains("--ui-decision-dock") {
          questionForms = [QuestionForm(title: "Before I book the flight", questions: [
            RelayQuestion(id: "cabin", label: "Which cabin?", choices: ["Economy", "Premium economy", "Business"]),
          ], after: turn, threadID: threadID, askedAt: now.addingTimeInterval(2)) { _ in }]
        } else if !Self.previewApprovalOnly {
          questionForms = [QuestionForm(title: "Before I book the flight", questions: [
            RelayQuestion(id: "cabin", label: "Which cabin?", choices: ["Economy", "Premium", "Business"]),
            RelayQuestion(id: "notes", label: "Anything the booker should know?"),
          ], after: turn, threadID: threadID) { _ in }]
        }
      }
    }
  }
  /// `--ui-serein-task-cards`: four tasks this chat started that have finished (in memory only):
  /// done with its summary, failed, stopped, and one from an earlier launch with no record left.
  private func previewFinishedTasks(chat: Conversation, now: Date) {
    let anchor = chat.messages.first?.id
    let rows: [(String, Provider, String, RunRecord.Outcome, String?)] = [
      ("relay-preview-done", .codex, "Fix the failing checkout tests", .done, "The tests pass now. Codex changed 2 files."),
      ("relay-preview-failed", .claude, "Update the pricing page copy", .stuck, nil),
      ("relay-preview-stopped", .codex, "Rename the checkout events", .stopped, nil),
    ]
    state.children = []
    for (index, row) in rows.enumerated() {
      let run = AgentRun(
        spec: RunSpec(threadID: row.0, provider: row.1, executable: "/usr/bin/false", model: "", effort: "medium",
          mode: .project, projectID: nil, projectName: "shop-web", title: row.2, scope: "Synthetic preview",
          autoRouting: false, grants: RunGrants(edits: true, projectName: "shop-web"), limits: RunLimits(hard: nil, idle: 3600)),
        taskID: "relay-preview-task-\(index)", transcript: [])
      run.record.startedAt = now.addingTimeInterval(-Double(5 + index * 7) * 60)
      run.record.endedAt = now.addingTimeInterval(-Double(2 + index * 7) * 60)
      run.record.outcome = row.3
      run.reportedSummary = row.4
      if row.3 == .stuck { run.error = "Synthetic preview failure" }
      agent.hub.adoptPreview(run)
      state.children.append(Child(threadID: row.0, edits: true, startedAt: run.record.startedAt, chatID: threadID, messageID: anchor))
    }
    // A task from an earlier launch: its chat is saved, its run long gone.
    let yesterday = now.addingTimeInterval(-30 * 3600)
    var earlier = Conversation(
      id: "relay-preview-earlier", title: "Draft the release notes",
      messages: [AgentMessage(role: "you", text: "Draft the release notes"), AgentMessage(role: "assistant", text: "Here is a draft.")],
      provider: .claude, mode: .project, projectID: nil, remoteID: nil, scope: "", updatedAt: yesterday)
    earlier.lastMessageAt = yesterday
    agent.conversations.append(earlier)
    state.children.insert(Child(threadID: earlier.id, edits: false, startedAt: yesterday, chatID: threadID, messageID: anchor), at: 0)
  }
  /// What `--ui-serein-bar-reply` asked from the bar.
  static let previewBarPrompt = "Remind me at 5 pm to call Maya"
  /// What `--ui-serein-bar-held` asked from the bar with no AI app.
  static let previewHeldPrompt = "What’s on my calendar today?"
  /// A held message, in memory only: `--ui-serein-no-ai` (no AI app, written two minutes ago),
  /// `--ui-serein-offline` (offline, a minute ago), `--ui-serein-held-stale` (no AI app, 45
  /// minutes ago, so it waits for Send now or Discard) and `--ui-serein-bar-held [offline]` (asked
  /// from the bar just now, with no AI app or offline).
  func previewHeld() {
    let arguments = CommandLine.arguments
    guard arguments.contains("--ui-preview") else { return }
    let now = Date()
    if let reason = Self.previewBarHeld {
      held = [Held(message: HeldMessage(text: Self.previewHeldPrompt, at: now, reason: reason))]
    }
    if arguments.contains("--ui-serein-no-ai") {
      held = [Held(message: HeldMessage(text: "What’s on my calendar today?", at: now.addingTimeInterval(-120), reason: .noAI))]
    }
    if arguments.contains("--ui-serein-offline") {
      held = [Held(message: HeldMessage(text: "Also check trains to Kyoto", at: now.addingTimeInterval(-60), reason: .offline))]
    }
    if arguments.contains("--ui-serein-held-stale") {
      held = [Held(message: HeldMessage(text: "What’s on my calendar today?", at: now.addingTimeInterval(-45 * 60), reason: .noAI))]
    }
    // `--ui-serein-limit`: a message the usage limit held, with another AI app it can move to;
    // `--ui-serein-limit-none`: the same with nothing else that can answer, so it offers Connect.
    if arguments.contains("--ui-serein-limit") || arguments.contains("--ui-serein-limit-none") {
      let item = Held(message: HeldMessage(text: "What’s on my calendar today?", at: now, reason: .usageLimit,
                                           threadID: threadID, resetsAt: now.addingTimeInterval(2 * 24 * 3600)), waits: true)
      held = [item]
      if arguments.contains("--ui-serein-limit-none") { elsewhereOffered[item.id] = "" }
    }
  }
  /// The `tasks` preview: its seeded runs are tasks Serein started in its current chat (in memory
  /// only; a preview never saves state.json).
  func previewAdoptTasks(_ ids: [String]) {
    guard CommandLine.arguments.contains("--ui-preview") else { return }
    let now = Date()
    let asked = transcript.first { $0.role == "you" }?.id
    state.children = ids.map { Child(threadID: $0, edits: false, startedAt: now, chatID: threadID, messageID: asked) }
  }
  /// `--ui-serein-approval` and its variants: only approval cards wait (no question form).
  static let previewApprovalOnly = ["--ui-serein-approval", "--ui-serein-approval-denied",
                                    "--ui-serein-approval-remembered", "--ui-serein-start-card",
                                    "--ui-serein-approval-popover", "--ui-serein-consent",
                                    "--ui-serein-bar-approval", "--ui-serein-waiting"]
    .contains { CommandLine.arguments.contains($0) }
  /// `--ui-serein-approval-popover`: the first card's “Change what Serein asks about” is open.
  static let previewLevelsPopover = CommandLine.arguments.contains("--ui-preview")
    && CommandLine.arguments.contains("--ui-serein-approval-popover")
  /// `--ui-serein-approval-popover --ui-serein-level-changed`: the popover after a change, with
  /// its note that the card still waits.
  static let previewLevelChanged = previewLevelsPopover && CommandLine.arguments.contains("--ui-serein-level-changed")
  /// The approval previews: a Calendar card whose Automation permission is undetermined
  /// (`--ui-serein-approval`), denied (`--ui-serein-approval-denied`) or only remembered as
  /// denied while Calendar is closed (`--ui-serein-approval-remembered`), the Start-task card that
  /// may edit or only reads (`--ui-serein-start-card edits|read`), and the consent card
  /// (`--ui-serein-consent`). Only in memory.
  private func previewApprovals() {
    let arguments = CommandLine.arguments
    let source = """
      tell application "Calendar"
        set todayStart to (current date) - (time of (current date))
        set todayEnd to todayStart + (1 * days)
        get summary of every event of every calendar whose start date ≥ todayStart and start date < todayEnd
      end tell
      """
    let calendar = ApprovalCopy.script(source)
    if arguments.contains("--ui-serein-approval") || arguments.contains("--ui-serein-approval-popover") {
      approvals.append(Approval(title: calendar.title, detail: calendar.detail, button: "Allow", threadID: threadID,
                                more: source, app: "Calendar",
                                automation: .undetermined) { _ in })
    }
    if arguments.contains("--ui-serein-approval-denied") {
      approvals = [Approval(title: calendar.title, detail: calendar.detail, button: "Allow", threadID: threadID,
                            more: source, app: "Calendar",
                            automation: .denied) { _ in }]
    }
    if arguments.contains("--ui-serein-approval-remembered") {
      // Calendar is closed, so macOS cannot say; Serein remembers a refused run: a hint, with Allow.
      approvals = [Approval(title: calendar.title, detail: calendar.detail, button: "Allow", threadID: threadID,
                            more: source, app: "Calendar",
                            automation: .denied, automationLive: false) { _ in }]
    }
    if let index = arguments.firstIndex(of: "--ui-serein-start-card") {
      let variant = arguments.indices.contains(index + 1) ? arguments[index + 1] : "edits"
      let card = ApprovalCopy.startTask(provider: "Codex", destination: "project", place: "shop-web",
                                        edits: variant != "read",
                                        task: variant == "read" ? "Review the checkout copy" : "Update the checkout copy")
      approvals = [Approval(title: card.title, detail: card.detail, button: "Start", threadID: threadID) { _ in }]
    }
    if arguments.contains("--ui-serein-approval") {
      // One answered card above, collapsed.
      answered = [AnsweredApproval(id: UUID(), title: "Serein wants to read your reminders",
                                   allowed: true, at: Date().addingTimeInterval(-60), threadID: threadID)]
    }
    if arguments.contains("--ui-serein-consent") {
      approvals = []
      consentWaiting = true
    }
  }
}

extension BrowserModel {
  /// Relay, when task `id` is Relay's own run, a run it started, or a task one assistant handed
  /// to another (its Autopilot and its panel apply there); nil for every other task.
  func relayTask(_ id: String, _ task: BrowserTask?) -> RelayOrchestrator? {
    guard let relay = RelayOrchestrator.shared else { return nil }
    if task?.allowRelay == true { return relay }
    guard let run = relay.agent.hub.runs.first(where: { $0.taskID == id }) else { return nil }
    return relay.isChild(run.spec.threadID) || run.spec.initiator == .handoff ? relay : nil
  }
  /// Whether nobody is there to answer a card for task `id`: Serein's own scheduled turn is
  /// running it, or a schedule, watch or webhook started this run, while that run is active (Serein's
  /// chat reuses one task across turns, so a finished scheduled turn says nothing about the next).
  /// Every step of such a task is judged as scheduled, and what needs a person (upload,
  /// click_point, page_tool, downloads) is refused before any card.
  func isUnattended(task id: String) -> Bool {
    if let caller = tasks[id]?.caller { return isUnattended(task: caller) }
    if relayTask(id, tasks[id])?.runsUnattended == true { return true }
    return agentTabs.hub?.runs.contains {
      $0.taskID == id && $0.isActive && ($0.spec.initiator?.isUnattended == true || $0.spec.speaksFirstElsewhere)
    } == true
  }
  /// Whether a standing yes (RoutineGrants) may answer a step of task `id`: only in a turn the
  /// person started (`RoutineGrants.standsIn`). Serein's own task counts during the person's own
  /// turn only; a run counts when the person started it, or when Serein started it, and last sent
  /// it work, in the person's own turn (`Child.byPerson`). Never with nobody there.
  func standingYesStands(task id: String) -> Bool {
    guard !isUnattended(task: id) else { return false }
    let relay: RelayOrchestrator? = RelayOrchestrator.shared
    if tasks[id]?.allowRelay == true {
      return RoutineGrants.standsIn(relayTurn: relay?.admissionTurn ?? .assistant, initiator: nil, fromPersonTurn: false)
    }
    guard let run = agentTabs.hub?.runs.last(where: { $0.taskID == id }) else { return false }
    let fromPerson: Bool = relay?.child(run.spec.threadID)?.byPerson == true
    return RoutineGrants.standsIn(relayTurn: nil, initiator: run.spec.initiator, fromPersonTurn: fromPerson)
  }
  /// Whether task `id` stands at Allow all: one the person asked for, with them there
  /// (`standingYesStands`), when the chosen level is Allow all or the task is one Serein delegated,
  /// which the owner made autonomous (2026-11-16). A plain chat turn at Auto or Manual follows that
  /// level. Never Serein's own task, a paired app's, a hand-off's, or a run nobody attends. A task an
  /// agent called (AppPeerHost) stands as its caller's does.
  func taskStandsProactive(_ id: String) -> Bool {
    if let caller = tasks[id]?.caller { return taskStandsProactive(caller) }
    guard tasks[id]?.allowRelay != true, standingYesStands(task: id) else { return false }
    if RelayOrchestrator.shared?.level == .proactive { return true }
    return agentTabs.hub?.runs.last(where: { $0.taskID == id })?.spec.initiator == .delegated
  }
  /// Who is asking for a step of task `id`: such a task stands at Allow all; every other task
  /// stands as `today` says.
  func standing(task id: String, else today: ApprovalDoor.Standing) -> ApprovalDoor.Standing {
    taskStandsProactive(id) ? .proactiveTask(present: today.present) : today
  }
  /// The thread whose run holds task `id`: a task Serein started, or Serein's own chat.
  func threadID(forTask id: String) -> String? {
    if let run = RelayOrchestrator.shared?.agent.hub.runs.first(where: { $0.taskID == id }) { return run.spec.threadID }
    return tasks[id]?.allowRelay == true ? RelayOrchestrator.shared?.threadID : nil
  }
}

/// Words a proactive turn carries from a chat that read the person's data (a hand-off's task and
/// result, a card's title, a run's error, a goal's findings) into the chat it speaks in: speaks-
/// first context, the huddle, the brief's “Waiting on you” and its goal lines. They go in only
/// once that chat is marked too (`AgentModel.markPersonalRead`), so it loses Serein's computer as
/// the chat they came from did. The first such words mark it; when the mark cannot be saved,
/// every such word is left out.
@MainActor final class PersonalCarry {
  private let agent: AgentModel
  private let thread: String
  private var allowed: Bool?
  init(agent: AgentModel, into thread: String) {
    self.agent = agent
    self.thread = thread
  }
  /// Whether words from a source may go in: always for one that read nothing personal.
  func admits(_ personal: Bool) -> Bool {
    guard personal else { return true }
    if allowed == nil { allowed = agent.markPersonalRead(thread: thread) }
    return allowed == true
  }
}
