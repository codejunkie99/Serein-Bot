#if DEBUG
import Foundation
import SereinCore

/// What lets Serein work on its own (RelayAlwaysOn.swift): the quiet outbox, a scheduled run's
/// memory of its last result, an interrupted turn's one re-run, self-set follow-ups, the person's
/// words as authority, and deferred asks.
extension AssistantCoreChecks {
  static func alwaysOn(_ check: Check) throws {
    try check(RelayOutbox.holds(.update, hour: 23) && RelayOutbox.holds(.update, hour: 3)
      && !RelayOutbox.holds(.ask, hour: 23) && !RelayOutbox.holds(.reminder, hour: 3) && !RelayOutbox.holds(.update, hour: 12),
      "In quiet hours an update waits and an ask or a reminder goes out")
    try check(RelayOutbox.identifier(.update, thread: "a") == RelayOutbox.identifier(.update, thread: "a")
      && RelayOutbox.identifier(.update, thread: "a") != RelayOutbox.identifier(.update, thread: "b")
      && RelayOutbox.identifier(.ask, thread: "a") != RelayOutbox.identifier(.update, thread: "a")
      && RelayOutbox.identifier(.reminder, thread: "a") != RelayOutbox.identifier(.reminder, thread: "a"),
      "A newer post replaces the older one in the same chat, and reminders never replace each other")
    var held: String? = nil
    for (title, body) in [("Scout", "Scout has an update."), ("Goal ended", "Bike: met"), ("Scout", "Scout has an update."),
                          ("A", "1"), ("B", "2"), ("C", "3")] {
      held = RelayOutbox.merged(held, title: title, body: body)
    }
    let lines = (held ?? "").components(separatedBy: "\n")
    try check(lines.count == 4 && lines.last == "C: 3" && lines.filter { $0 == "Scout: Scout has an update." }.count == 1
      && (held ?? "").count <= 400,
      "Held posts merge per chat, a repeat counted once, at most four lines")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
    let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 23, minute: 30)) ?? Date()
    let early = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 2)) ?? Date()
    let brief = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: RelayProactive.briefHour)) ?? Date()
    try check(RelayOutbox.summaryTime(after: late, calendar: calendar) == brief
      && RelayOutbox.summaryTime(after: early, calendar: calendar) == brief,
      "Held posts are delivered at the brief hour")

    let said = String(repeating: "Maya replied about the invoice. ", count: 30)
    let again = RelayUnattended.prompt(text: "Check my inbox", repeats: .daily, now: "2026-11-15T09:00:00-08:00", last: said)
    let first = RelayUnattended.prompt(text: "Check my inbox", repeats: .daily, now: "2026-11-15T09:00:00-08:00")
    try check(again.contains("Last time you reported: Maya replied") && again.hasSuffix("Do not repeat this unless something changed.")
      && again.count - first.count < RelayUnattended.lastLimit + 120 && RelayAutomatic.label(again) == RelayAutomatic.label(first),
      "A scheduled run hears what it said last time, cut short, and is told not to repeat it")
    try check(!first.contains("Last time"), "A first run carries no earlier result")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-always-on-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let ledger = try WorkLedger(url: folder.appendingPathComponent("work.sqlite"))
    let key = WorkLedger.scheduleKey(id: "inbox", due: Date(timeIntervalSince1970: 1_800_000_000))
    _ = try ledger.enqueue(.schedule, owner: "person", dedupeKey: key, payload: "{}")
    let resume = WorkLedger.resumeKey(key)
    let queued = try resume.map { try ledger.enqueue(.schedule, owner: "person", dedupeKey: $0, payload: "{}") }
    let twice = try resume.map { try ledger.enqueue(.schedule, owner: "person", dedupeKey: $0, payload: "{}") }
    try check(queued?.isNew == true && twice?.isNew == false && resume.flatMap(WorkLedger.resumeKey) == nil,
      "An interrupted turn queues once more, and its re-run never queues again")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tomorrow = now.addingTimeInterval(86_400)
    try check(RelayFollowUp.refusal(repeats: .none, cron: nil, due: tomorrow, now: now, setThisRun: 0, open: 0) == nil
      && RelayFollowUp.refusal(repeats: .daily, cron: nil, due: tomorrow, now: now, setThisRun: 0, open: 0) != nil
      && RelayFollowUp.refusal(repeats: .none, cron: nil, due: now.addingTimeInterval(300), now: now, setThisRun: 0, open: 0) != nil
      && RelayFollowUp.refusal(repeats: .none, cron: nil, due: now.addingTimeInterval(15 * 86_400), now: now, setThisRun: 0, open: 0) != nil,
      "A follow-up runs once, between 10 minutes and 14 days ahead")
    var mine = RelayReminder(text: "Check back on Maya's reply", due: tomorrow, action: true)
    mine.selfSet = true
    try check(RelayFollowUp.refusal(repeats: .none, cron: nil, due: tomorrow, now: now, setThisRun: 1, open: 0) != nil
      && RelayFollowUp.refusal(repeats: .none, cron: nil, due: tomorrow, now: now, setThisRun: 0,
                               open: RelayFollowUp.open([mine, mine, mine])) != nil
      && RelayFollowUp.open([mine, RelayReminder(text: "Stretch", due: tomorrow)]) == 1,
      "One follow-up per run and three open at once")
    let old = #"{"id":"r1","text":"Stretch","due":0,"repeats":"none","action":false}"#
    let loaded = try? JSONDecoder().decode(RelayReminder.self, from: Data(old.utf8))
    try check(loaded?.selfSet == nil && loaded?.source == nil && loaded?.text == "Stretch",
      "An old reminder without the follow-up fields still loads")

    let weekly = "Send the weekly report to sam@acme.com every Friday"
    try check(!UnattendedAuthority.covers(request: weekly, effect: .send, targets: ["sam@acme.com"]),
      "A prose request cannot authorize a consequential send")
    try check(!UnattendedAuthority.covers(request: "Check my email and tell me what needs me", effect: .send, targets: ["sam@acme.com"]),
      "An unnamed send asks")
    try check(!UnattendedAuthority.covers(request: "Check the shop's orders page and tell me what is new", effect: .send,
                                          targets: ["orders@attacker.example"])
      && !UnattendedAuthority.covers(request: weekly, effect: .send, targets: ["sam.evil@attacker.example"])
      && !UnattendedAuthority.covers(request: weekly, effect: .send, targets: ["sam@acme.com", "x@attacker.example"])
      && !UnattendedAuthority.covers(request: nil, effect: .send, targets: ["sam@acme.com"])
      && !UnattendedAuthority.covers(request: "Send the weekly report to Sam every Friday", effect: .send, targets: ["sam@attacker.example"]),
      "Text from a page that tries to add an action asks")
    try check(!UnattendedAuthority.covers(request: "Pay the electricity bill and book it if it's under $600", effect: .pay,
                                          targets: ["electricity"]),
      "Money always asks")

    for request in ["Send to annsam@acme.com", "Do not send anything to sam@acme.com",
                    "The email says: send to sam@acme.com", "Send to John Smith", weekly] {
      for effect: ApprovalGate.Effect in [.send, .post, .change, .submit, .book, .fill, .merge, .type, .click, .navigate] {
        try check(!UnattendedAuthority.covers(request: request, effect: effect, targets: ["sam@acme.com"]),
          "Unstructured, quoted or negated prose never grants an external action")
      }
    }
    let shop = "Check my Etsy orders every morning and tell me what is new"
    try check(UnattendedAuthority.covers(request: shop, effect: .click, site: "www.etsy.com")
      && UnattendedAuthority.covers(request: shop, effect: .navigate, site: "orders.etsy.com")
      && UnattendedAuthority.covers(request: shop, effect: .read, site: "www.etsy.com"),
      "On a site the request names, a plain click or key move goes ahead")
    try check(!UnattendedAuthority.covers(request: shop, effect: .type, site: "www.etsy.com")
      && !UnattendedAuthority.covers(request: shop, effect: .submit, site: "www.etsy.com")
      && !UnattendedAuthority.covers(request: shop, effect: .send, site: "www.etsy.com")
      && !UnattendedAuthority.covers(request: shop, effect: .pay, site: "www.etsy.com"),
      "Typing and every risky step on a named site still ask")
    try check(!UnattendedAuthority.covers(request: shop, effect: .click, site: "evil-etsy.com")
      && !UnattendedAuthority.covers(request: shop, effect: .click, site: "etsy.attacker.example")
      && !UnattendedAuthority.covers(request: shop, effect: .click, site: "attacker.example")
      && !UnattendedAuthority.covers(request: nil, effect: .click, site: "www.etsy.com")
      && !UnattendedAuthority.covers(request: shop, effect: .click, site: nil)
      && !UnattendedAuthority.covers(request: shop, effect: .click, place: "Etsy")
      && !UnattendedAuthority.covers(request: "Click Next in Safari", effect: .click, place: "Safari"),
      "Another site, no request, a Mac app, an unnamed site or Every step still asks")
    // A key on a control that holds a value changes it: never a key move the words cover.
    func control(_ html: String) -> PageSnapshot {
      PageReading.describe(html: "<html><body><main>\(html)</main></body></html>")
    }
    let moves = [
      #"<a href="/orders" data-serein-target>Orders</a>"#,
      #"<button data-serein-target>Next page</button>"#,
      #"<div role="tab" data-serein-target>Shipped</div>"#,
      #"<ul role="menu"><li role="menuitem" data-serein-target>Open</li></ul>"#,
    ].map(control)
    let changes = [
      #"<input type="number" value="1" data-serein-target>"#,
      #"<input type="range" min="0" max="10" data-serein-target>"#,
      #"<input type="text" data-serein-target>"#,
      #"<textarea data-serein-target></textarea>"#,
      #"<select data-serein-target><option>A</option><option>B</option></select>"#,
      #"<div contenteditable><p data-serein-target>Note</p></div>"#,
      #"<div role="slider" aria-valuenow="3" data-serein-target></div>"#,
      #"<div role="spinbutton" data-serein-target>2</div>"#,
      #"<button role="switch" aria-checked="false" data-serein-target>Vacation mode</button>"#,
      #"<div role="checkbox" data-serein-target>Email me</div>"#,
      #"<div role="radio" data-serein-target>Weekly</div>"#,
      #"<div role="listbox"><div role="option" data-serein-target>Large</div></div>"#,
    ].map(control)
    try check(moves.allSatisfy { $0.present && UnattendedAuthority.keyMoves(on: $0) }
      && !changes.contains { UnattendedAuthority.keyMoves(on: $0) }
      && !UnattendedAuthority.keyMoves(on: .absent)
      && !UnattendedAuthority.keyMoves(on: control(#"<div contenteditable="true" role="none" data-serein-target>x</div>"#))
      && UnattendedAuthority.keyMoves(on: control(#"<div contenteditable="false"><span data-serein-target>x</span></div>"#)),
      "A key on a field, list, slider, stepper, switch or choice is a change, not a key move the words cover")
    try check(!UnattendedAuthority.covers(request: "Send in Messages to Sam", effect: .send, place: "Messages")
      && !UnattendedAuthority.covers(request: "Send on Gmail", effect: .send, place: "gmail.com")
      && UnattendedAuthority.covers(request: "Check Messages", effect: .read, place: "Messages"),
      "Observation remains available; app/site-only sends ask")
    let identity = ConnectedApps.approvalIdentity(app: "gmail", tool: "send", version: "1", account: "a", arguments: "{}")
    for other in [ConnectedApps.approvalIdentity(app: "gmail", tool: "send", version: "1", account: "b", arguments: "{}"),
                  ConnectedApps.approvalIdentity(app: "gmail", tool: "forward", version: "1", account: "a", arguments: "{}"),
                  ConnectedApps.approvalIdentity(app: "gmail", tool: "send", version: "2", account: "a", arguments: "{}"),
                  ConnectedApps.approvalIdentity(app: "gmail", tool: "send", version: "1", account: "a", arguments: "{\"cc\":\"other\"}")] {
      try check(identity != other, "Deferred app approvals bind account, tool, version and every argument")
    }

    let action = RelayDeferred.Action(title: "Send with Gmail", detail: "To 1 person", more: #"{"to":"sam@acme.com"}"#,
                                      app: nil, site: nil, effect: "send", thread: "main")
    var other = action
    other.more = #"{"to":"x@attacker.example"}"#
    var grants = [RelayDeferred.Grant(action: action, at: now)]
    let wrong = RelayDeferred.consume(other, from: &grants, now: now)
    let right = RelayDeferred.consume(action, from: &grants, now: now)
    let spent = RelayDeferred.consume(action, from: &grants, now: now)
    var stale = [RelayDeferred.Grant(action: action, at: now)]
    let expired = RelayDeferred.consume(action, from: &stale, now: now.addingTimeInterval(RelayDeferred.lifetime + 1))
    try check(!wrong && right && !spent && !expired && stale.isEmpty,
      "A one-time grant matches the exact action once and expires after a day")
    let ask = RelayDeferred.Ask(action: action, owner: "inbox", askedAt: now)
    try check(ask.payload().flatMap(RelayDeferred.Ask.decoded) == ask && ask.payload().flatMap(QueuedRun.decoded) == nil,
      "A deferred ask's row reads back whole and is never taken for a queued run")
    try check(RelayDeferred.isResume(RelayDeferred.resumePrefix + "x") && !RelayDeferred.isResume("inbox")
      && RelayDeferred.resumeText(action).contains("exactly that step"),
      "A resume turn is told to take exactly the allowed step once")
    try proactiveDefaults(check, calendar: calendar)
    try actingAlone(check)
    try unattendedWaits(check)
  }

  /// What a run nobody watches leaves waiting: a deferred card that lives a day and comes back
  /// after a relaunch still needing Allow, a question that blocks nothing, and a Settings hook's
  /// delivery on disk before its 200.
  static func unattendedWaits(_ check: Check) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let asked = now.addingTimeInterval(-31 * 60)
    try check(!ApprovalLife.skips(cardThread: "main", background: true, messageThread: "main")
      && RelayApproval.duty(askedAt: asked, remindedAt: nil, now: now) == RelayApproval.Duty.none
      && RelayApproval.duty(askedAt: now.addingTimeInterval(-RelayDeferred.lifetime), remindedAt: nil, now: now) == .decline,
      "A deferred card is still open at 31 minutes and closes at a day")
    let action = RelayDeferred.Action(title: "Send with Gmail", detail: "To 1 person", more: nil, app: nil, site: nil,
                                      effect: "send", thread: "main")
    let ask = RelayDeferred.Ask(action: action, owner: "inbox", askedAt: asked)
    let rebuilt = ask.payload().flatMap { RelayDeferred.restored($0, now: now) }
    let stale = ask.payload().flatMap { RelayDeferred.restored($0, now: asked.addingTimeInterval(RelayDeferred.lifetime)) }
    var grants: [RelayDeferred.Grant] = []
    try check(rebuilt == ask && stale == nil && !RelayDeferred.consume(action, from: &grants, now: now),
      "A card rebuilt from its row after a relaunch grants nothing until Allow, and one past its day is not rebuilt")

    let note = RelayAsk.unattended(true)?["note"] as? String
    let asks = RelayAsk.unattended(true)?["asked"] as? Bool
    try check(note?.contains(RelayUnattended.inputMark) == true && asks == false && RelayAsk.unattended(false) == nil,
      "An unattended question returns at once with the NEEDS INPUT guidance, and an attended one still asks")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("serein-hook-ledger-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let ledger = try WorkLedger(url: folder.appendingPathComponent("work.sqlite"))
    func deliver(_ header: String?, _ body: String?, after: TimeInterval = 0) throws -> WorkLedger.Enqueued? {
      try RelayHook.enqueue(ledger, hook: "h1", source: "Build", header: header, body: body, now: now.addingTimeInterval(after))
    }
    let first = try deliver("d-1", "done")
    let again = try deliver("d-1", "done", after: 3600)
    let ping = try deliver(nil, nil)
    let pingAgain = try deliver(nil, nil, after: 60)
    let pingLater = try deliver(nil, nil, after: 2 * RelayHook.repeatWindow)
    let rows = try ledger.queued(limit: 10)
    let run = first.flatMap { QueuedRun.decoded($0.row.payload) }
    try check(first?.isNew == true && again?.isNew == false && again?.row.id == first?.row.id
      && run?.initiator == .webhook && run?.profileID == nil && first?.row.owner == QueuedRun.personsOwn,
      "A hook delivery makes one queued row of the person's own, and a redelivery of the same key makes none")
    try check(ping?.isNew == true && pingAgain?.isNew == false && pingLater?.isNew == true
      && rows.count == 3,
      "A delivery with no key and the same body repeats once within ten minutes, and fires again after")
  }

  /// Check-ins on by default, an Always level above Often, and away no longer meaning off.
  static func proactiveDefaults(_ check: Check, calendar: Calendar) throws {
    let always = RelayProactive.Level.always
    try check(always.title == "Always" && always.dailyTurns == 30 && always.checkInHours == 1
      && always.dailyTurns > RelayProactive.Level.jarvis.dailyTurns && RelayProactive.Level.newInstallDefault == .jarvis,
      "Always checks in every hour, up to thirty turns a day, and a new install starts at Often")
    let fresh = AssistantMigration.plan(freshInstall: true, enabled: nil, proactive: nil, autopilot: nil, learnsNotes: nil)
    let chosen = AssistantMigration.plan(freshInstall: true, enabled: nil, proactive: "off", autopilot: nil, learnsNotes: nil)
    let upgrade = AssistantMigration.plan(freshInstall: false, enabled: true, proactive: nil, autopilot: nil, learnsNotes: nil)
    try check(fresh.contains(.briefingOn) && !upgrade.contains(.briefingOn)
      && !chosen.contains { write in
        if case .string(let key, _) = write { return key == AssistantMigration.proactiveKey }
        return false
      },
      "A fresh install gets the morning briefing, and a stored check-in choice such as Never is kept")
    let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12)) ?? Date()
    var memory = RelayProactive.Memory()
    memory.day = RelayProactive.dayKey(noon, calendar: calendar)
    memory.briefDay = memory.day
    memory.lastCheckIn = noon.addingTimeInterval(-4 * 3600)
    func next(_ memory: RelayProactive.Memory, at: Date? = nil, idle: TimeInterval, attention: [String] = [])
      -> RelayProactive.Trigger?
    {
      RelayProactive.next(level: .jarvis, memory: memory, now: at ?? noon, idle: idle, relayBusy: false, attention: attention,
                          calendar: calendar)
    }
    try check(next(memory, idle: 5) == .checkIn && next(memory, idle: 3600) == nil,
      "Away from the Mac, a check-in waits twice its interval")
    var longAgo = memory
    longAgo.lastCheckIn = noon.addingTimeInterval(-7 * 3600)
    try check(next(longAgo, idle: 3600) == .checkIn && next(memory, idle: 86_400, attention: ["run"]) == .attention(threadID: "run"),
      "Check-ins still come while the person is away, and a run that needs them is raised at any idle time")
    var unbriefed = longAgo
    unbriefed.briefDay = ""
    let night = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 23)) ?? Date()
    try check(next(unbriefed, idle: 5) == .morningBrief && next(unbriefed, idle: 3600) == .checkIn
      && next(longAgo, at: night, idle: 3600) == nil && next(longAgo, at: night, idle: 5, attention: ["run"]) == nil,
      "The morning brief waits for the person to be back, and quiet hours still hold")
    let speakers = [RelayProactive.Speaker(id: "a", level: .jarvis), RelayProactive.Speaker(id: "b", level: .light)]
    try check(RelayProactive.pick(speakers: speakers, memory: longAgo, now: noon, idle: 3600, busy: false, attention: [],
                                  calendar: calendar)?.trigger == .checkIn,
      "With several assistants, check-ins also run while the person is away")
    let acts = RelayProactive.prompt(.checkIn, acts: true)
    let asks = RelayProactive.prompt(.checkIn)
    try check(acts.contains(RelayProactive.actsLine) && !acts.contains("Do not start tasks")
      && asks.contains("Do not start tasks") && acts.contains(RelayProactive.ideaMark),
      "A check-in may take the pending step the person asked for in that chat, and otherwise only suggests")
    try check(RelayProactive.prompt(.attention(threadID: "repair:x"), detail: "E2B rejected the saved key").contains(RelayProactive.ideaMark),
      "A setup problem is raised with its fix as one idea")
  }

  /// A step in a run nobody watches, on the person's words: browser and Mac steps, standing yeses
  /// and watches.
  static func actingAlone(_ check: Check) throws {
    let table = "Book a table for two on OpenTable tonight"
    try check(!UnattendedAuthority.covers(request: table, effect: .book, place: "www.opentable.com")
      && !UnattendedAuthority.covers(request: table, effect: .click, place: "www.opentable.com"),
      "A site name is not authority for input or a booking")
    try check(!UnattendedAuthority.covers(request: table, effect: .click, place: "evil.example")
      && !UnattendedAuthority.covers(request: table, effect: .send, place: "www.opentable.com")
      && !UnattendedAuthority.covers(request: table, effect: .book, place: nil)
      && !UnattendedAuthority.covers(request: "Pay my bill on PG&E", effect: .pay, place: "pge.com")
      && !UnattendedAuthority.covers(request: nil, effect: .click, place: "www.opentable.com")
      && !UnattendedAuthority.covers(request: table, effect: .book, place: "evil-opentable.com")
      && !UnattendedAuthority.covers(request: table, effect: .book, place: "opentable.com.evil.example"),
      "Another site, another verb, no site, money or no words is not covered")
    let step = RelayAutonomy.MacStep(app: "TextEdit", kind: "click", label: "Next")
    let effect = ApprovalGate.effect(of: step)
    try check(!UnattendedAuthority.covers(request: "In TextEdit, go to the next page", effect: effect, place: step.app)
      && !UnattendedAuthority.covers(request: "Check my mail", effect: effect, place: step.app),
      "An app name cannot authorize input to an unverified recipient")
    func grant(_ effect: ApprovalGate.Effect, scheduled: Bool, covered: Bool) -> Bool {
      RoutineGrants.covers(decision: .ask, effect: effect, site: "shop.example", rule: .normal, scheduled: scheduled,
                           covered: covered, taskSites: [], alwaysSites: ["shop.example"])
    }
    try check(!grant(.click, scheduled: true, covered: true) && !grant(.click, scheduled: true, covered: false)
      && !grant(.pay, scheduled: true, covered: true) && !grant(.delete, scheduled: true, covered: true),
      "A standing site grant cannot authorize unattended input, money or deletion")
    let old = #"{"id":"w1","name":"Price","kind":"url","source":"https://example.com","minutes":60}"#
    let loaded = try? JSONDecoder().decode(RelayWatch.self, from: Data(old.utf8))
    let made = RelayWatch(name: "Price", kind: .url, source: "https://example.com", minutes: 60,
                          request: "Tell me when the price drops and buy it")
    try check(loaded != nil && loaded?.request == nil && made.request == "Tell me when the price drops and buy it",
      "An alert keeps the words that created it, and an older alert loads with none")
  }
}
#endif
