#if DEBUG
import Foundation
import SereinCore

/// `--verify-assistant-core`: the pure rules behind assistants that do what the person types
/// (receipts, admission, schedules, lifecycle, asks, memory, the work ledger). No window, no
/// model, no files outside a temporary folder. Each unit adds its suite in its own file as an
/// extension, and one line to `suites`.
enum AssistantCoreChecks {
  typealias Check = (_ condition: Bool, _ label: String) throws -> Void

  static let suites: [(String, (Check) throws -> Void)] = [
    ("receipts", AssistantCoreChecks.receipts),
    ("secureCard", AssistantCoreChecks.secureCard),
    ("admission", AssistantCoreChecks.admission),
    ("schedules", AssistantCoreChecks.schedules),
    ("lifecycle", AssistantCoreChecks.lifecycle),
    ("bubbles", AssistantCoreChecks.bubbles),
    ("builtInSetup", AssistantCoreChecks.builtInSetup),
    ("macComputer", AssistantCoreChecks.macComputer),
    ("barWork", AssistantCoreChecks.barWork),
    ("workspaceSignals", AssistantCoreChecks.workspaceSignals),
    ("stepLabels", AssistantCoreChecks.stepLabels),
    ("reels", AssistantCoreChecks.reels),
    ("macFiles", AssistantCoreChecks.macFiles), ("allowAll", AssistantCoreChecks.allowAll), ("settingChange", AssistantCoreChecks.settingChange), ("cardPlacement", AssistantCoreChecks.cardPlacement), ("codeFormat", AssistantCoreChecks.codeFormat), ("macRun", AssistantCoreChecks.macRun), ("assistantWeb", AssistantCoreChecks.assistantWeb), ("everydayApps", AssistantCoreChecks.everydayApps), ("connectionStatus", AssistantCoreChecks.connectionStatus), ("uiSDKSkill", AssistantCoreChecks.uiSDKSkill), ("waitingPrompt", AssistantCoreChecks.waitingPrompt), ("decisionDock", AssistantCoreChecks.decisionDock), ("alwaysOn", AssistantCoreChecks.alwaysOn),
    ("setupHoldsCheckIns", AssistantCoreChecks.setupHoldsCheckIns),
    ("setupName", AssistantCoreChecks.setupName),
    ("sessionStatus", AssistantCoreChecks.sessionStatus),
    ("goalsSites", AssistantCoreChecks.goalsSites),
    ("uiTree", AssistantCoreChecks.uiTree),
    ("sessionList", AssistantCoreChecks.sessionList),
    ("agentListOrder", AssistantCoreChecks.agentListOrder),
    ("routines", AssistantCoreChecks.routines),
    ("spaces", AssistantCoreChecks.spaces),
    ("teamFaces", AssistantCoreChecks.teamFaces),
    ("screenSignal", AssistantCoreChecks.screenSignal),
    ("fnCall", AssistantCoreChecks.fnCall),
    ("asks", AssistantCoreChecks.asks),
    ("memoryModel", AssistantCoreChecks.memoryModel),
    ("memoryStore", AssistantCoreChecks.memoryStore),
    ("chatSearch", AssistantCoreChecks.chatSearch),
    ("searchPalette", AssistantCoreChecks.searchPalette),
    ("draftQuote", AssistantCoreChecks.draftQuote),
    ("connect", AssistantCoreChecks.connect),
    ("library", AssistantCoreChecks.library),
    ("welcome", AssistantCoreChecks.welcome),
    ("ledger", AssistantCoreChecks.ledger),
    ("research", AssistantCoreChecks.research),
    ("links", AssistantCoreChecks.links),
    ("proxyServerName", AssistantCoreChecks.proxyServerName),
    ("tools", AssistantCoreChecks.tools),
    ("plan", AssistantCoreChecks.plan),
    ("cuaDriver", AssistantCoreChecks.cuaDriver),
    ("shellMemory", AssistantCoreChecks.shellMemory),
    ("shellSchedules", AssistantCoreChecks.shellSchedules),
    ("shell", AssistantCoreChecks.shell),
    ("rowRules", AssistantCoreChecks.rowRules),
    ("sidebarWidth", AssistantCoreChecks.sidebarWidth),
    ("routineOffers", AssistantCoreChecks.routineOffers),
    ("backEnd", AssistantCoreChecks.backEnd),
    ("chatScreens", AssistantCoreChecks.chatScreens),
    ("turnActivity", AssistantCoreChecks.turnActivity),
    ("addList", AssistantCoreChecks.addList),
    ("settingsPaths", AssistantCoreChecks.settingsPaths),
    ("signIn", AssistantCoreChecks.signIn),
    ("browserMap", AssistantCoreChecks.browserMap),
    ("appAccess", AssistantCoreChecks.appAccess),
    ("voiceRoute", AssistantCoreChecks.voiceRoute),
    ("speechModel", AssistantCoreChecks.speechModel),
    ("setupSwitches", AssistantCoreChecks.setupSwitches),
    ("delegatedAccess", AssistantCoreChecks.delegatedAccess),
    ("signInFlow", AssistantCoreChecks.signInFlow),
    ("openCode2", AssistantCoreChecks.openCode2),
    ("codexGrok", AssistantCoreChecks.codexGrok),
    ("harnessBudget", AssistantCoreChecks.harnessBudget),
    ("droppedApps", AssistantCoreChecks.droppedApps),
    ("providerAudit", AssistantCoreChecks.providerAudit),
    ("appTools", AssistantCoreChecks.appTools),
    ("lazyLoad", AssistantCoreChecks.lazyLoad),
    ("localFinds", AssistantCoreChecks.localFinds),
    ("connectionStates", AssistantCoreChecks.connectionStates), ("outsideFence", AssistantCoreChecks.outsideFence),
    ("approvalLife", AssistantCoreChecks.approvalLife),
    ("approvalBaseline", AssistantCoreChecks.approvalBaseline),
    ("approvalDoor", AssistantCoreChecks.approvalDoor),
    ("proactiveOwner", AssistantCoreChecks.proactiveOwner),
    ("stepJournal", AssistantCoreChecks.stepJournal),
    ("macAccess", AssistantCoreChecks.macAccess),
    ("approvalCard", AssistantCoreChecks.approvalCard),
    ("computerHold", AssistantCoreChecks.computerHold),
    ("checkpointCompletion", AssistantCoreChecks.checkpointCompletion),
    ("planContext", AssistantCoreChecks.planContext),
    ("design", AssistantCoreChecks.design),
    ("marketplace", AssistantCoreChecks.marketplace),
    ("affectLaneOne", AssistantCoreChecks.affectLaneOne),
    ("awayRunningTurns", AssistantCoreChecks.awayRunningTurns),
    ("agentLedger", AssistantCoreChecks.agentLedger),
    ("citedUsage", AssistantCoreChecks.citedUsage),
    ("lookSheet", AssistantCoreChecks.lookSheet),
    ("affectDial", AssistantCoreChecks.affectDial),
    ("affectMemory", AssistantCoreChecks.affectMemory),
    ("affectSchedules", AssistantCoreChecks.affectSchedules),
    ("handoffChain", AssistantCoreChecks.handoffChain),
    ("turnFrame", AssistantCoreChecks.turnFrame),
    ("workroom", AssistantCoreChecks.workroom),
    ("packet", AssistantCoreChecks.packet),
    ("reach", AssistantCoreChecks.reach),
    ("roomFiles", AssistantCoreChecks.roomFiles),
    ("seatPacket", AssistantCoreChecks.seatPacket),
    ("channel", AssistantCoreChecks.channel),
    ("groupTurn", AssistantCoreChecks.groupTurn),
    ("noQueue", AssistantCoreChecks.noQueue),
    ("mentionPlan", AssistantCoreChecks.mentionPlan),
    ("swarm", AssistantCoreChecks.swarm),
    ("staffing", AssistantCoreChecks.staffing),
    ("keyFailure", AssistantCoreChecks.keyFailure),
    ("secureField", AssistantCoreChecks.secureField),
    ("assistantOwn", AssistantCoreChecks.assistantOwn),
    ("linkedOpen", AssistantCoreChecks.linkedOpen),
    ("sendWhileThinking", AssistantCoreChecks.sendWhileThinking),
    ("probeTruth", AssistantCoreChecks.probeTruth),
    ("shellNetwork", AssistantCoreChecks.shellNetwork),
    ("harnessRules", AssistantCoreChecks.harnessRules),
    ("engines", AssistantCoreChecks.engines),
    ("peers", AssistantCoreChecks.peers),
    ("grokEngine", AssistantCoreChecks.grokEngine),
    ("cursorEngine", AssistantCoreChecks.cursorEngine),
    ("geminiEngine", AssistantCoreChecks.geminiEngine),
    ("openCodeEngine", AssistantCoreChecks.openCodeEngine),
    ("launchMode", AssistantCoreChecks.launchMode),
    ("failover", AssistantCoreChecks.failover),
    ("modelRegistry", AssistantCoreChecks.modelRegistry),
    ("chatRegistry", AssistantCoreChecks.chatRegistry),
    ("composerChips", AssistantCoreChecks.composerChips),
    ("firstRun", AssistantCoreChecks.firstRun),
  ]

  static func run() throws {
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw SereinError.invalid("FAIL: " + label) }
      print("PASS: " + label)
      fflush(stdout)
    }
    let only = ProcessInfo.processInfo.environment["SEREIN_ONLY"]?.split(separator: ",").map(String.init)
    for (name, suite) in suites where only?.contains(name) ?? true {
      print("== \(name)")
      try suite(check)
    }
  }

  // MARK: unit 1

  static func receipts(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let all: [(Receipt, String?)] = [
      (ReceiptCopy.reminder(at: "3:45", text: "Call Ana"), nil),
      (ReceiptCopy.routine(when: "Every weekday at 8:00", what: "Clear my inbox"), nil),
      (ReceiptCopy.made(name: "Inbox Zero", job: "It sorts your mail and asks before it sends anything.", entry: "e1"), "Inbox Zero"),
      (ReceiptCopy.changed(name: "Inbox Zero", what: "is paused", entry: "e2"), nil),
      (ReceiptCopy.deleted(name: "Old notes", entry: "e3", now: now), nil),
      (ReceiptCopy.restored(name: "Old notes"), "Old notes"),
      (ReceiptCopy.remembered("Ana is a client", sharedWithAll: true, entry: "e4"), nil),
      (ReceiptCopy.ruleSet(whom: "Every assistant", entry: "e7"), nil),
      (ReceiptCopy.forgot(entry: "e5"), nil),
      (ReceiptCopy.shared(with: "Every assistant", entry: "e6"), nil),
      (ReceiptCopy.linkMade(for: "Release", title: "GitHub"), nil),
      (ReceiptCopy.connected(app: "Gmail"), nil),
      (ReceiptCopy.dashboard(title: "The trip dashboard"), nil),
      (ReceiptCopy.undone(), nil),
      (ReceiptCopy.allowAll(entry: "e7"), nil),
    ]
    for (receipt, name) in all {
      let problems = ReceiptCopy.lint(receipt.line, name: name)
      try check(problems.isEmpty, "Receipt \(receipt.kind.rawValue) is plain: \(problems.joined(separator: ", "))")
    }
    try check(!ReceiptCopy.lint("Done. I made a webhook with a cron.").isEmpty, "Feature words fail the lint")
    try check(!ReceiptCopy.lint("I made it.").isEmpty, "A line must open with Done., Okay. or <Name> is ready.")
    let many = Receipt(kind: .memorySaved, line: "Done.", card: .rows((1...5).map { Receipt.Row(title: "\($0)", detail: "") }))
    if case .rows(let rows)? = many.card { try check(rows.count == Receipt.maxRows, "A receipt keeps at most three rows") }
    let token = UndoToken.removal(entry: "e3", kind: .assistantDeleted, now: now)
    try check(token.isLive(now: now.addingTimeInterval(9)) && !token.isLive(now: now.addingTimeInterval(10)), "A removal's Undo lasts 10 seconds")
    try check(UndoToken(entry: "e1", kind: .assistantMade).isLive(now: .distantFuture), "A made thing keeps its Undo while the journal does")
  }

  static func admission(_ check: Check) throws {
    typealias A = Admission
    try check(A.decide(.schedule(signIns: false), turn: .person, wordsNameIt: true) == .apply, "A typed reminder applies")
    try check(A.decide(.schedule(signIns: true), turn: .person, wordsNameIt: true) == .ask, "A routine with kept sign-ins asks")
    try check(A.decide(.deleteAssistant, turn: .person, wordsNameIt: true) == .ask, "Delete always asks the person")
    try check(A.decide(.deleteAssistant, turn: .assistant, wordsNameIt: true) == .ask, "An assistant's delete is a card")
    try check(A.decide(.widen, turn: .person, wordsNameIt: true) == .ask, "Widening always asks")
    try check(A.decide(.ask, turn: .person, wordsNameIt: true) == .apply, "Asking another assistant needs no card")
    if case .refuse = A.decide(.ask, turn: .assistant, wordsNameIt: true) {} else { try check(false, "An asked assistant cannot ask again") }
    for change: A.Change in [.schedule(signIns: false), .memory, .ownChange, .shareMemory, .makeLink, .widen, .deleteAssistant, .undo, .board] {
      if case .refuse = A.decide(change, turn: .unattended, wordsNameIt: true) {} else {
        try check(false, "An unattended turn cannot change \(change)")
      }
    }
    try check(TypedConsent.names(.shareMemory, in: "Share that with every assistant"), "\"Share\" names a share")
    try check(!TypedConsent.names(.shareMemory, in: "Remember that Ana is a client"), "Remember alone does not share")
  }

  // MARK: unit 2

  static func schedules(_ check: Check) throws {
    func gap(_ cron: String) -> Int { RelayCron(parse: cron).map(ScheduleGuard.smallestGap) ?? -1 }
    try check(gap("*/5 * * * *") == 5, "Every 5 minutes has a 5-minute gap")
    try check(gap("*/15 * * * *") == 15, "Every 15 minutes has a 15-minute gap")
    try check(gap("0,10 * * * *") == 10, "Minutes 0 and 10 have a 10-minute gap")
    try check(gap("*/7 * * * *") == 4, "Every 7 minutes wraps at the hour with a 4-minute gap")
    try check(gap("55 23 * * *") == 1440, "Once a day has a one-day gap")
    try check(ScheduleGuard.check(cron: "*/5 * * * *", acts: true, actionRoutinesOn: 0) == .tooOften(minutes: 5), "Every 5 minutes is refused for an action")
    try check(ScheduleGuard.check(cron: "*/5 * * * *", acts: false, actionRoutinesOn: 0) == nil, "A plain reminder may repeat more often")
    try check(ScheduleGuard.check(cron: "*/15 * * * *", acts: true, actionRoutinesOn: 19) == nil, "The twentieth action routine is allowed")
    try check(ScheduleGuard.check(cron: "*/15 * * * *", acts: true, actionRoutinesOn: 20) == .tooMany, "The twenty-first is refused")
    try check(ScheduleGuard.check(cron: "nonsense", acts: true, actionRoutinesOn: 0) == .unreadable, "An unreadable schedule is refused")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    if case .success(let date) = ScheduleGuard.time(inMinutes: 15, now: now) {
      try check(date.timeIntervalSince(now) == 900, "In 15 minutes is 900 seconds from now")
    } else { try check(false, "In 15 minutes is allowed") }
    if case .failure(let refusal) = ScheduleGuard.time(inMinutes: 0, now: now) {
      try check(refusal == .outOfRange, "In 0 minutes is refused")
    } else { try check(false, "In 0 minutes is refused") }
    try check(ScheduleGuard.cron(everyMinutes: 15) == "*/15 * * * *", "Every 15 minutes becomes */15")
    try check(ScheduleGuard.cron(everyMinutes: 120) == "0 */2 * * *", "Every 2 hours becomes 0 */2")
    try check(ScheduleGuard.cron(everyMinutes: 7) == nil, "Every 7 minutes cannot repeat evenly")
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    func words(_ cron: String) -> String { RelayCron(parse: cron).map { ScheduleWords.words($0, calendar: calendar) } ?? "?" }
    try check(words("*/15 * * * *") == "Every 15 minutes", "*/15 reads Every 15 minutes")
    try check(words("0 * * * *") == "Every hour", "0 * reads Every hour")
    try check(words("0 */2 * * *") == "Every 2 hours", "0 */2 reads Every 2 hours")
    try check(words("0 8 * * 1-5") == "Every weekday at 8:00", "Weekdays at 8 reads Every weekday at 8:00")
    try check(words("30 9 * * *") == "Every day at 9:30", "Daily at 9:30 reads Every day at 9:30")
    try check(words("0 9 * * 1") == "Every Monday at 9:00", "Mondays at 9 reads Every Monday at 9:00")
    try check(words("5 4 1 * *") == "On a custom schedule", "An unusual cron reads On a custom schedule")
    try check(ScheduleGuard.Refusal.tooOften(minutes: 5).words.contains("every 15 minutes"), "The refusal names the fastest schedule")
  }
}
#endif
