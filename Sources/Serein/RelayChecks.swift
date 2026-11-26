#if DEBUG
import AppKit
import Combine
import Foundation
import SereinCore
import WebKit

extension SmokeTest {
  /// Relay end to end with a fake Claude Code (no provider usage): Relay's turn starts through
  /// AgentModel.dispatch, its CLI reaches Relay's tools through the real serein-browser-mcp and
  /// socket, delegates a child run, waits for it, keeps a note and a reminder; the user's own
  /// thread is untouched by the swaps; a child never gets Relay's tools; stop ends everything.
  @MainActor static func relay(browser: BrowserModel, agent: AgentModel) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    let folder = browser.library.root.appendingPathComponent("relay-check", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let cli = folder.appendingPathComponent("claude")
    try fakeRelayClaude.write(to: cli, atomically: true, encoding: .utf8)
    chmod(cli.path, 0o755)
    let log = folder.appendingPathComponent("log.jsonl")
    func records() -> [[String: Any]] {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    }
    func record(_ key: String) -> [String: Any]? { records().last { $0[key] != nil } }
    agent.pin(.claude, executable: cli.path)
    guard let relay = RelayOrchestrator.shared else { throw SereinError.invalid("FAIL: Relay did not start") }
    relay.autopilotOverride = true
    results += try await relayS10Origins(browser: browser, relay: relay, record: record)
    results += try await relayBurst(relay: relay)

    // The user's own thread, with a draft, stays as it was through every swap.
    agent.draft = "my unsent draft"
    let userThread = agent.conversationID
    let userMode = agent.mode

    // The origin checks leave a warm CLI, which can delegate before the first poll. Hold
    // this request before agent_start so the empty-slot assertion observes only Relay's run.
    let delegationGate = folder.appendingPathComponent("first-delegation-release")
    try? FileManager.default.removeItem(at: delegationGate)
    var delegationReleased = false
    defer {
      if !delegationReleased, let run = relay.run { agent.hub.stop(run) }
    }
    relay.ask("Please delegate a check task.")
    try await waitFor(5) { record("first_delegation_ready") != nil }
    let firstReady = (record("first_delegation_ready")?["first_delegation_ready"] as? String)?
      .contains("Please delegate a check task.") == true
    try check(firstReady && relay.run?.transcript.last(where: { $0.role == "you" })?.text == "Please delegate a check task.",
              "Relay's turn starts as a run in its own thread")
    try check(agent.conversationID == userThread && agent.draft == "my unsent draft" && agent.mode == userMode,
              "The user's thread, draft and destination are untouched by the swap")
    try check(relay.run?.spec.relay == true && relay.run?.spec.mode == .anywhere, "Relay runs as an Anywhere run flagged relay")
    try check(agent.hub.slotted.isEmpty, "Relay's own run is not counted among its tasks")
    if let run = relay.run { try check(browser.tasks[run.taskID]?.allowRelay == true, "Only Relay's capability holds Relay's tools") }
    // The fake CLI's remember comes in the person's turn, but their words ("Please delegate a
    // check task.") do not ask to keep anything: it is the assistant's own idea, kept unreviewed
    // with no card and no receipt, unused until the person keeps it (SPEC 4.3).
    try Data().write(to: delegationGate)
    delegationReleased = true
    let memoryText = "Prefers Codex for Swift work"
    try await waitFor(40) { record("remembered") != nil || relay.run == nil }
    try check(relay.approvals.isEmpty && (record("remembered")?["remembered"] as? [String: Any])?["waiting"] != nil,
              "An assistant's own remember in the person's turn waits as an idea, with no card")

    try await waitFor(40) { relay.run == nil }
    let all = records()
    let tools = (all.first { $0["relay_tools"] != nil }?["relay_tools"] as? [String]) ?? []
    let cliTools: Set<String> = Set(tools)
    let groupTools: Set<String> = [ToolGroups.moreTool, ToolGroups.runTool]
    let listsShown: Bool = cliTools.isSuperset(of: RelayTools.names.subtracting(ToolGroups.hidden))
    let listsGroupTools: Bool = cliTools.isSuperset(of: groupTools)
    let hidesRare: Bool = cliTools.isDisjoint(with: ToolGroups.hidden)
    try check(listsShown && listsGroupTools && hidesRare,
              "Relay's CLI lists every Relay tool through serein-browser-mcp, the rarely used ones behind tools_more and tool_run")
    try check((record("prompt_relay")?["prompt_relay"] as? Bool) == true, "Relay's system prompt reaches its CLI")
    let started = record("started")?["started"] as? [String: Any]
    let childID = started?["run"] as? String ?? ""
    // The model and effort agent_start names are kept only when the AI app offers them.
    let offered = [HarnessModel(id: "real-1", name: "Real", isDefault: true, options: [.effort(["low", "high"])])]
    let kept = RelayToolHost.modelAndEffort(["model": "real-1", "effort": "High"], models: offered)
    let invented = RelayToolHost.modelAndEffort(["model": "made-up-9", "effort": "ludicrous"], models: offered)
    try check(!childID.isEmpty && relay.isChild(childID) && kept == ("real-1", "high") && invented == ("", "low"),
              "agent_start delegates a run and Relay adopts it")
    try check(agent.conversations.contains { $0.id == childID }, "The delegated run is an ordinary saved thread")
    let waited = record("waited")?["waited"] as? [String: Any]
    let waitedRuns = waited?["runs"] as? [[String: Any]] ?? []
    try check(waitedRuns.first?["state"] as? String == "done"
              && (waitedRuns.first?["reply_untrusted"] as? String)?.contains("child says hi") == true,
              "agent_wait reports the delegated run's outcome and reply")
    let childTools = (all.first { $0["child_tools"] != nil }?["child_tools"] as? [String]) ?? ["missing"]
    try check(RelayTools.names.isDisjoint(with: childTools) && !childTools.isEmpty, "A delegated run never gets Relay's tools")
    try check((record("child_refused")?["child_refused"] as? String)?.contains("Unknown") == true,
              "A delegated run's call to a Relay tool is refused")
    try check(relay.proposals.contains { $0.text == memoryText && $0.quote == "use codex for swift" }
              && !relay.notes.contains { $0.text == memoryText },
              "remember keeps the idea with the user's words, unused until they keep it")
    let recalledAnswer = record("recalled")?["recalled"] as? [String: Any] ?? [:]
    let recalledNotes = recalledAnswer["notes"] as? [[String: Any]] ?? []
    let recalledIdeas = (recalledAnswer["ideas"] as? [String: Any])?["notes"] as? [[String: Any]] ?? []
    try check(!recalledNotes.contains { $0["text"] as? String == memoryText }
              && recalledIdeas.first?["text_untrusted"] as? String == memoryText,
              "recall offers the idea apart from the notes, in the person's turn")
    try check(relay.reminders.contains { $0.text == "Stretch" && $0.repeats == .daily }, "reminder_create schedules a reminder")
    let replyReceipts = relay.transcript.last(where: { $0.role == "assistant" })?.receipts ?? []
    try check(replyReceipts.contains { $0.kind == .routine && $0.line.hasPrefix("Okay.") && $0.undo != nil },
              "The reminder Serein set shows its receipt, with Undo, under the reply")
    try check(relay.transcript.last?.text.contains("Relay finished") == true, "Relay's reply lands in its Main chat")
    try check(agent.conversationID == userThread && agent.draft == "my unsent draft", "The user's thread is still selected afterwards")
    let got = record("look_got")?["look_got"] as? [String: Any] ?? [:]
    try check((got["formations"] as? [[String: Any]])?.count == RelayLook.formations.count
              && (got["cores"] as? [[String: Any]])?.count == RelayLook.cores.count
              && got["skill"] as? String == "design-your-look" && got["may_change_now"] as? Bool == true,
              "look_get gives Relay its look, every formation and core, and its design skill")
    try check((record("look_set")?["look_set"] as? [String: Any])?["wearing"] as? String == "Check Look",
              "look_set applies only the changes Relay names")
    let bad = (record("look_bad")?["look_bad"] as? [String: Any])?["error"] as? String ?? ""
    try check(bad.contains("rings.count") && bad.contains("states.idle.formation"), "look_set refuses a broken look and names every problem")
    try check((record("look_show")?["look_show"] as? [String: Any])?["showing"] as? String == "tour", "look_show plays a tour")
    try check((record("look_undo")?["look_undo"] as? [String: Any])?["wearing"] as? String == "Serein", "look_undo goes back")
    try check(relay.look.name == "Aurora" && relay.looks.current.by == .relay && !relay.looks.current.own
              && relay.looks.current.reason == "Back to a preset", "A look Relay chose when asked is worn and credited")
    let savedLook = browser.library.load(RelayLookStore.self, from: "relay/look.json")
    try check(savedLook?.look.name == "Aurora" && (savedLook?.history.count ?? 0) >= 1, "The look and the ones before it persist")
    try check(relay.activity.contains { $0.text == "Changed its look to “Check Look”: A check" }, "Changing its look shows in “What I did”")
    let memoryURL = browser.library.root.appendingPathComponent(MemoryStore.relativePath)
    let savedID = (record("remembered")?["remembered"] as? [String: Any])?["saved"] as? String ?? ""
    let reopenedStore = try? MemoryStore(url: memoryURL)
    let keptIdea: MemoryRecord? = (try? reopenedStore?.record(id: savedID)) ?? nil
    try check(keptIdea?.text == memoryText && keptIdea?.review == .unreviewed && keptIdea?.chat == relay.threadID,
              "Memory persists in the store, with the chat it came from")
    let state = browser.library.load(RelayOrchestrator.State.self, from: relay.dir + "/state.json")
    try check(state?.threadID == relay.threadID && state?.children.contains { $0.threadID == childID } == true,
              "Relay's Main chat and delegated runs persist across launches")
    let mode = (try? FileManager.default.attributesOfItem(atPath: browser.library.root.appendingPathComponent("relay").path))?[.posixPermissions] as? Int
    try check(mode == 0o700, "Relay's folder is private")
    let savedActivity = browser.library.load([RelayOrchestrator.Activity].self, from: "relay/activity.json") ?? []
    try check(savedActivity.count == relay.activity.count && !savedActivity.isEmpty, "“What I did” is kept for after a restart")

    let did = relay.activity.map(\.text)
    try check(did.contains { $0.hasPrefix("Asked Claude Code to work on an answer") } && did.contains { $0.hasPrefix("Remembered:") }
              && did.contains { $0.hasPrefix("Scheduled “Stretch”") } && did.contains { $0.contains("finished “CHILD please say hi”: done") },
              "“What I did” lists the delegation, the note, the reminder and the finished run")

    // A finished delegated run, while Relay is idle, gets a short report turn.
    _ = try await relay.tools.call("agent_start", ["task": "CHILD report me", "destination": "answer"], thread: relay.threadID)
    try await waitFor(20) { record("report") != nil }
    try check((record("report")?["report"] as? String)?.contains("A run you delegated finished (done)") == true,
              "Relay reports a delegated run that finished while it was idle [error: \(relay.lastError ?? "none"); did: \(relay.activity.map(\.text).suffix(3)); working: \(relay.working)]")
    try await waitFor(20) { relay.run == nil }

    // Words with a file sent while Serein works wait for its next turn; a correction interrupts it and goes on with both.
    // An assistant to mention, made before the turn: none can be added while Serein works.
    let proofer = relay.addProfile("Proofer") ? relay.team.profiles.last?.id : nil
    let bar = RelayController.shared
    // HOLD: a step that reads no stdin until the correction stops it, as a long tool call does.
    relay.ask("SLOW HOLD keep working")
    try await waitFor(5) { relay.run.map(relay.agent.hub.takesWords) == true }
    let first = relay.run
    // A plain message now takes a side seat (no queue); one with a file still waits for this
    // chat's next turn, which the correction below sends.
    relay.ask("also do this", attachments: [SereinAttachment(title: "Also note", body: "ALSO NOTE 4410")], interrupt: false)
    try check(relay.pending == ["also do this"] && relay.run === first && first?.steering.waiting.isEmpty == true,
              "Words with a file sent while Serein works wait for its next turn, which keeps running "
                + "[pending: \(relay.pending); same run: \(relay.run === first); waiting: \(first?.steering.waiting.map(\.shown) ?? [])]")
    // A bare tag: words after it go now as a group turn, but opening Proofer's chat waits.
    let mention = "@Proofer"
    bar?.summonDraft = mention
    // Sent from the bar only while it would be refused: a mention that goes opens Proofer's chat.
    if relay.messagePlan(mention, hasAttachments: false, answersQuestion: false).refusal != nil { bar?.sendWriting() }
    let mentionWaits = bar?.barRefusalShown?.contains("busy") == true
    try await waitFor(10) { record("slow_child") != nil }
    let delegatedBeforeCorrection = records().filter { $0["slow_child"] != nil }.count
    relay.ask("SLOW HOLD actually change course", interrupt: true)
    try await waitFor(10) { relay.run != nil && relay.run !== first }
    try await waitFor(10) { (record("prompt")?["prompt"] as? String)?.contains("I interrupted you") == true }
    let redirected = record("prompt")?["prompt"] as? String ?? ""
    try check(first?.record.outcome == .stopped && redirected.contains("also do this") && redirected.contains("change course"),
              "A correction stops the turn and the next one carries the words that waited for it")
    let mentionGoes = bar?.barRefusalShown == nil && bar?.barRefusal != nil && bar?.summonDraft == mention
    bar?.summonDraft = ""
    try check(mentionWaits && mentionGoes,
              "A mention's reason under the bar is there while a message waits behind the reply, and goes once the mention would [waits: \(mentionWaits), goes: \(mentionGoes)]")
    if let proofer { _ = relay.removeProfile(proofer) }
    // Wait for this reply's delegation to finish starting before recording the live task count.
    try await waitFor(10) { records().filter { $0["slow_child"] != nil }.count > delegatedBeforeCorrection }
    try await waitFor(5) { relay.childRuns.contains(where: \.isActive) }
    try check(relay.childRuns.contains(where: \.isActive), "Relay has a delegated run working")
    try check(bar.map { ScreenSignals.current($0).shown } == ScreenSignal.Shown(),
              "While Serein and a task work outside a Mac app or a page, the screen's edge does not glow")
    if let child = relay.childRuns.first(where: \.isActive) {
      func holds(waiting: Bool = false, _ change: (inout AgentStep) -> Void = { _ in }) -> Bool {
        var step = AgentStep(tool: "mac_act", label: "Clicked in Mail")
        change(&step)
        var board = AgentTabBoard.RunInfo()
        board.steps = [step]
        return ScreenSignals.work(child, board: board, waiting: waiting).controls
      }
      try check(holds() && !holds { $0.failed = "refused" } && !holds(waiting: true)
                && !holds { $0.time = child.record.startedAt.addingTimeInterval(-1) },
                "A task's step in a Mac app holds the controls, unless it failed, the task waits on the person, or the step is from an earlier turn")
    }
    // Stop, or a bare “stop”, ends only the reply: the task keeps working, and only the
    // approvals Serein's own turn asked are declined; the task's approval still waits.
    let slowChild = relay.childRuns.first(where: \.isActive)?.spec.threadID ?? ""
    let screenBefore = relay.chatOnScreen
    let barBefore = relay.panelVisible
    relay.chatOnScreen = { true }
    relay.panelVisible = { false }
    let ownAsk = Task { @MainActor in await relay.confirmAnswer("Serein wants to read your calendar", "Nothing is changed.", thread: relay.threadID) == .yes }
    let taskAsk = Task { @MainActor in await relay.confirmAnswer("Serein wants to click “Send” in Mail", "This sends the message.", thread: slowChild) == .yes }
    try await waitFor(3) { relay.approvals.count == 2 }
    relay.ask("SLOW wait for this", attachments: [SereinAttachment(title: "Wait note", body: "WAIT NOTE 5521")], interrupt: false)
    relay.ask("stop")
    try await waitFor(5) { relay.run == nil }
    let ownDeclined = await ownAsk.value == false
    let replyStopped = relay.run == nil && relay.childRuns.contains { $0.isActive && $0.spec.threadID == slowChild }
      && relay.approvals.map(\.threadID) == [slowChild] && ownDeclined && relay.pending.isEmpty
      && relay.liveTasks >= 1 && relay.stopNotice == .stoppedReply(working: relay.liveTasks, others: relay.otherLiveTasks) && !relay.state.paused
    relay.ask("stop")
    let idleNotice = relay.run == nil && relay.stopNotice == .idle(working: relay.liveTasks, others: relay.otherLiveTasks)
    try check(replyStopped && idleNotice,
              "Stopping a reply, by Stop or a bare “stop”, leaves its tasks and their approvals alone [stopped: \(replyStopped), idle: \(idleNotice), approvals: \(relay.approvals.count), notice: \(String(describing: relay.stopNotice))]")
    relay.ask("stop everything")
    try await waitFor(5) { relay.run == nil && !relay.childRuns.contains(where: \.isActive) }
    let taskDeclined = await taskAsk.value == false
    relay.chatOnScreen = screenBefore
    relay.panelVisible = barBefore
    try check(relay.run == nil && !relay.childRuns.contains(where: \.isActive) && relay.pending.isEmpty && relay.approvals.isEmpty
              && taskDeclined && relay.state.paused && relay.stopNotice == .everything,
              "“stop everything” ends Relay's turn, its delegated runs, their approvals and what waited, and pauses")
    try check(bar.map { ScreenSignals.current($0).shown } == ScreenSignal.Shown(), "Stopped and paused, the glow is gone")
    relay.resume()

    // Paired apps: only a pairing allowed to ask Relay may; its request is labelled and queued.
    // ⌥Space on here only for the shortcut taps below; nothing else depends on it.
    RelayOrchestrator.enabledOverride = true
    defer { RelayOrchestrator.enabledOverride = nil }
    let access = OutsideAgents(root: browser.library.root, browser: browser)
    func pairing(_ name: String, relay allowed: Bool) async throws -> String {
      guard access.makeOffer(name: name, sites: "", actions: false, localHosts: "", days: 1, relay: allowed) == nil,
        let code = access.offer?.code else { throw SereinError.invalid("FAIL: no pairing offer") }
      _ = await access.respond(["op": "pair", "code": code])
      guard let token = access.grants.first(where: { $0.name == name })?.token else { throw SereinError.invalid("FAIL: not paired") }
      return token
    }
    let plainToken = try await pairing("Plain app", relay: false)
    let refused = await access.respond(["op": "relay_ask", "token": plainToken, "text": "do something"])
    try check((refused["error"] as? String)?.contains("may not ask Serein") == true, "A pairing without “May ask Serein” is refused")
    let relayToken = try await pairing("Script", relay: true)
    let childrenBeforeGreeting = relay.state.children
    let notesBeforeGreeting = relay.notes
    let remindersBeforeGreeting = relay.reminders
    let asked = await access.respond(["op": "relay_ask", "token": relayToken, "text": "say hello", "wait": 20])
    let lastPrompt = record("prompt")?["prompt"] as? String ?? ""
    try check(lastPrompt.contains("Request from Script, an app you paired") && lastPrompt.contains("say hello"),
              "A paired app's request reaches Relay labelled with its name")
    try check(asked["state"] as? String == "ready" && asked["reply"] as? String == "Hello from the paired-app check."
              && relay.state.children == childrenBeforeGreeting && relay.notes == notesBeforeGreeting
              && relay.reminders == remindersBeforeGreeting && relay.approvals.isEmpty,
              "relay ask returns Relay's greeting without starting a task or changing memory")
    let status = await access.respond(["op": "relay_status", "token": relayToken])
    try check(status["state"] as? String == "ready", "relay status reports Relay's state")

    // The shortcut: a tap opens the panel, another tap hides it (holding listens, which needs a microphone).
    if let controller = RelayController.shared {
      controller.summonPressed()
      controller.summonReleased()
      try await waitFor(2) { relay.panelVisible() }
      try check(relay.panelVisible(), "Tapping the shortcut opens Relay's panel")
      try check(controller.panelShown, "While the panel is open, the column's hologram holds still")
      controller.summonPressed()
      controller.summonReleased()
      try await waitFor(2) { !relay.panelVisible() }
      try check(!relay.panelVisible(), "Tapping it again hides the panel")
      try check(!controller.panelShown, "Hiding the panel lets the column's hologram move again")
    }

    // Speaking first, on a controlled clock: a daily brief, a quiet check-in, a failed run raised once.
    RelayOrchestrator.quietForChecks = false
    defer { RelayOrchestrator.quietForChecks = true }
    // This part tests check-ins at Often, the default.
    relay.proactiveOverride = .jarvis
    defer { relay.proactiveOverride = nil }
    relay.restyleOverride = true
    defer { relay.restyleOverride = nil }
    // Earlier fixture messages have real timestamps. Anchor the simulated day after them so
    // an afternoon run cannot place the noon check-in before the person's last message.
    let morning = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 0),
                                            matchingPolicy: .nextTime)!
    relay.speakFirst(now: morning, idle: 5)
    try await waitFor(20) { record("brief") != nil && relay.run == nil }
    try check(relay.transcript.contains { RelayProactive.isOwnPrompt($0.text) } && relay.transcript.last?.text == "Good morning. Your day is clear.",
              "Relay gives a daily brief on its own")
    try check(agent.hub.latest(for: relay.threadID)?.spec.title == "Serein · Daily brief", "Relay's own turns get a readable title")
    try check((record("brief_look")?["brief_look"] as? [String: Any])?["on_its_own"] as? Bool == true
              && relay.look.name == "Ember" && relay.looks.current.own,
              "On its own, the morning brief can give Relay a new look for the day")
    relay.speakFirst(now: morning.addingTimeInterval(60), idle: 5)
    try check(relay.run == nil && !relay.working, "Nothing more right after the brief (check-ins wait three hours)")
    relay.speakFirst(now: morning.addingTimeInterval(3 * 3600 + 60), idle: 5)
    try await waitFor(20) { record("checkin") != nil && relay.run == nil }
    try check(relay.transcript.last?.text == RelayProactive.nothing, "A check-in with nothing to say replies NOTHING, which the chat hides")
    try check((record("checkin_look")?["checkin_look"] as? [String: Any])?["wearing"] as? String == "Mono"
              && ((record("checkin_look2")?["checkin_look2"] as? [String: Any])?["error"] as? String)?.contains("on your own today") == true
              && relay.look.name == "Mono", "Relay changes its look on its own at most twice a day")
    relay.speakFirst(now: morning.addingTimeInterval(4 * 3600), idle: 600)
    try check(!relay.working, "While the user is away from the Mac, check-ins wait twice as long")
    _ = try await agent.dispatch("FAIL this run", into: nil, as: AgentModel.DispatchTarget(mode: .answer, provider: .claude))
    try await waitFor(20) { agent.hub.runs.contains { $0.spec.title == "FAIL this run" && $0.record.outcome == .stuck } }
    relay.speakFirst(now: morning.addingTimeInterval(4 * 3600 + 60), idle: 5)
    try await waitFor(20) { record("attention") != nil && relay.run == nil }
    try check((record("attention")?["attention"] as? String)?.contains("“FAIL this run” failed") == true,
              "A run that fails outside Relay is raised by Relay")
    relay.speakFirst(now: morning.addingTimeInterval(4 * 3600 + 120), idle: 5)
    try check(!relay.working, "The same failed run is raised once")
    try check(relay.proactiveMemory.used == 3, "Each turn Relay starts counts toward its daily cap")

    // Due reminders: a note shows; the kill switch holds them until the user speaks again.
    relay.updateReminders { $0 = [RelayReminder(text: "Due now", due: Date().addingTimeInterval(-1))] }
    relay.stopEverything(pause: true)
    relay.tick()
    try check(relay.dueReminders.isEmpty && relay.reminders.count == 1, "The kill switch holds scheduled reminders")
    relay.resume()
    relay.tick()
    try check(relay.dueReminders.map(\.text) == ["Due now"] && relay.reminders.isEmpty, "A due reminder shows once")

    // Autopilot's decisions reach the Mac tool gate only for Relay's runs.
    let plain = try browser.beginTask(isolated: true, allowActions: false, includeCurrent: false, allowMac: true)
    try check(browser.relayTask(plain.capability.task, plain) == nil, "Other tasks keep asking for every Mac step")
    do {
      _ = try await browser.handle(["task": plain.capability.task, "token": plain.capability.token, "name": "agent_status", "arguments": [:]])
      try check(false, "A task without Relay's grant is refused Relay's tools")
    } catch {
      try check(error.localizedDescription.contains("only available to Serein"), "A task without Relay's grant is refused Relay's tools")
    }
    browser.endTask(plain.capability.task)

    // The warm thread: the next turn rides the retained Claude Code process — one process for
    // the whole conversation, no second spawn.
    relay.ask("WARM PING")
    try await waitFor(60) { !relay.working }
    try check(relay.transcript.last?.text.contains("warm pong") == true, "The second turn rides the warm process")
    let warmLog = (try? String(contentsOf: cli.deletingLastPathComponent().appendingPathComponent("log.jsonl"), encoding: .utf8)) ?? ""
    let pids = warmLog.components(separatedBy: "\n").compactMap { line -> String? in
      guard line.contains("\"prompt\""), let range = line.range(of: "\"pid\": (\\d+)", options: .regularExpression) else {
        return nil
      }
      return String(line[range])
    }
    // Steering interruptions kill the process on purpose (Stop is hard cancellation); the warm
    // guarantee is that idle-to-idle turns share one process.
    let perProcess = Dictionary(grouping: pids, by: { $0 }).mapValues(\.count)
    try check(pids.count >= 4 && (perProcess.values.max() ?? 0) >= 2,
              "Warm threads: \(pids.count) turns, up to \(perProcess.values.max() ?? 0) on one retained process")

    // The prompt split: the stable prefix is byte-identical however the request differs, the
    // volatile tail carries the replace-note, the time and the ranked memory (each note fenced as
    // data, `RelayOrchestrator.prepareMemory`) — so provider prompt caches hit on every turn.
    let t0 = Date().addingTimeInterval(-3_600)
    let memoryOwner = relay.team.activeID
    await relay.seedMemoryForChecks([
      MemoryRecord(
        id: "check-linear", text: "Uses Linear for the shop-web triage", owner: memoryOwner, scope: .person,
        provenance: MemoryProvenance(source: .person), createdAt: t0, review: .confirmed, personal: false),
      MemoryRecord(
        id: "check-codex", text: "Prefers Codex for Swift work", owner: memoryOwner, scope: .person,
        provenance: MemoryProvenance(source: .person), createdAt: t0.addingTimeInterval(60), review: .confirmed,
        personal: false),
      MemoryRecord(
        id: "check-rule", kind: .rule, text: "Answer in one short paragraph", quote: "answer in one short paragraph",
        owner: memoryOwner, scope: .person, provenance: MemoryProvenance(source: .person), createdAt: t0, review: .confirmed,
        personal: false),
    ])
    relay.updatePersona(RelayPersona(name: "Scout", about: "", rules: ""))
    let stableA = RelayPrompt.stable(browser: browser)
    await relay.prepareMemory(request: "triage the shop-web build", thread: relay.threadID, profileID: memoryOwner)
    let volatileA = RelayPrompt.volatile(request: "triage the shop-web build", thread: relay.threadID)
    try check(RelayPrompt.stable(browser: browser) == stableA, "The stable prompt prefix is byte-identical across turns")
    await relay.prepareMemory(request: "what is on my calendar?", thread: relay.threadID, profileID: memoryOwner)
    let volatileB = RelayPrompt.volatile(request: "what is on my calendar?", thread: relay.threadID)
    // A ranks the topical note first, then fills with the newest shared note; B has no topical
    // match, so the newest comes first.
    let shopA = volatileA.range(of: "shop-web")?.lowerBound
    let codexA = volatileA.range(of: "Codex")?.lowerBound
    try check(volatileA != volatileB && volatileA.contains("replaces any earlier copy")
      && volatileA.contains(MemoryPrompt.start) && volatileA.contains(MemoryPrompt.notProof)
      && shopA != nil && codexA != nil && (shopA ?? volatileA.endIndex) < (codexA ?? volatileA.startIndex),
      "The volatile tail ranks fenced memory per request and says it replaces")
    // Rules lead the volatile block, before the time and the memory, and never in the stable prefix.
    let rulesAt = volatileA.range(of: Rules.header)?.lowerBound
    let timeAt = volatileA.range(of: "The time now is")?.lowerBound
    try check(rulesAt != nil && timeAt != nil && (rulesAt ?? volatileA.endIndex) < (timeAt ?? volatileA.startIndex)
      && volatileA.contains("[check-rule] Answer in one short paragraph") && volatileB.contains(Rules.header)
      && !stableA.contains(Rules.header),
      "The rules in force go first in every turn's volatile block, and the stable prefix holds")
    try check(RelayPrompt.text(browser: browser, request: "x", thread: relay.threadID).hasSuffix(RelayPrompt.volatile(request: "x", thread: relay.threadID)), "text is stable then volatile")
    relay.restyleOverride = false
    let stableQuiet = RelayPrompt.stable(browser: browser)
    relay.restyleOverride = true
    try check(RelayPrompt.stable(browser: browser) == stableQuiet && stableQuiet == stableA
              && !stableA.contains("“\(relay.look.name)”") && volatileA.contains("“\(relay.look.name)”"),
              "Relay's look and its restyle setting ride in the volatile tail, so the stable prefix holds when they change")
    relay.restyleOverride = nil
    // A change to the stable prompt mid-thread (the persona just changed) retires the parked
    // process; the next turn starts a fresh one on the same capability and still answers.
    let beforeChange = relay.transcript.last?.text ?? ""
    relay.ask("WARM PING")
    try await waitFor(60) { !relay.working }
    let afterChange = relay.transcript.last?.text ?? ""
    try check(afterChange.contains("warm pong") && afterChange != beforeChange,
              "After the stable prompt changes, the next turn starts a fresh process and still answers [\(afterChange.prefix(60)); error: \(relay.lastError ?? "none")]")

    // The decider's contract: validated choice, threshold, and fail-open on any failure.
    let holdAnswers: [String: Any] = ["report": ["choice": "hold", "confidence": 0.9,
      "probabilities": ["tell": 0.1, "hold": 0.9]]]
    FastSteps.scripted = { _, _ in holdAnswers }
    let held = await RelayDecider.triageFinishedReport(summary: "done", outcome: "done", panelVisible: false)
    try check(held == RelayDecider.Triage(hold: true, confidence: 0.9), "A confident hold decision is honored")
    let told = await RelayDecider.triageFinishedReport(summary: "done", outcome: "done", panelVisible: true)
    try check(told == nil, "A visible panel never asks the decider")
    FastSteps.scripted = { _, _ in ["report": ["choice": "hold", "confidence": 0.3]] }
    let unsure = await RelayDecider.triageFinishedReport(summary: "done", outcome: "done", panelVisible: false)
    try check(unsure == nil, "Under the threshold it falls back to telling")
    FastSteps.scripted = { _, _ in ["report": ["choice": "banana", "confidence": 0.99]] }
    let invalid = await RelayDecider.triageFinishedReport(summary: "done", outcome: "done", panelVisible: false)
    try check(invalid == nil, "An answer that does not check out fails open")
    FastSteps.scripted = { _, _ in throw SereinError.invalid("no key") }
    let failed = await RelayDecider.triageFinishedReport(summary: "done", outcome: "done", panelVisible: false)
    try check(failed == nil, "A decider failure fails open")
    FastSteps.scripted = nil

    // With ⌥Space off, the assistant still works in the window: it answers, a paired app still
    // reaches it, and its clock still fires a reminder.
    RelayOrchestrator.enabledOverride = false
    relay.ask("WARM PING")
    try await waitFor(60) { !relay.working }
    let answeredOff = relay.transcript.last?.text.contains("warm pong") == true
    let pairedOff = await access.respond(["op": "relay_status", "token": relayToken])
    relay.dueReminders = []
    relay.updateReminders { $0 = [RelayReminder(text: "Stretch now", due: Date().addingTimeInterval(-1))] }
    relay.tick()
    try check(answeredOff && pairedOff["error"] == nil && pairedOff["state"] as? String == "ready"
              && relay.dueReminders.map(\.text) == ["Stretch now"] && relay.reminders.isEmpty,
              "With ⌥Space off, Serein still answers and a reminder fires [\(relay.transcript.last?.text.prefix(40) ?? ""); \(pairedOff)]")
    relay.dueReminders = []

    // File › Stop Everything, with ⌥Space still off: its key is the kill switch's, it is enabled
    // while something works, and it stops Serein's turn and its tasks and pauses.
    let slowBefore = records().filter { $0["slow_child"] != nil }.count
    relay.ask("SLOW stop everything from the menu")
    try await waitFor(15) {
      records().filter { $0["slow_child"] != nil }.count > slowBefore && relay.childRuns.contains(where: \.isActive)
    }
    let delegate = NSApp.delegate as? AppDelegate
    let fileMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "File" }
    let stopItem = fileMenu?.items.first { $0.title == "Stop Everything" }
    let enabledWhileWorking = stopItem.map { delegate?.validateMenuItem($0) == true } ?? false
    // ⌘Q's question counts Serein's own run once: its reply, plus every other live task.
    let things = relay.agent.hub.slotted.count + (relay.working ? 1 : 0)
    let quitTitle = delegate?.quitReason()?.title
    let countsOnce = quitTitle == "Serein is working on \(things == 1 ? "1 thing" : "\(things) things"). Quit anyway?"
    // ⌘J's File item reads what it will do, from the same rule the shell and the router follow
    // (Show Serein Beside, Show Serein Full or Back to Your Tab).
    let switchItem = fileMenu?.items.first { $0.action == #selector(AppDelegate.toggleRelayColumn) }
    let switchEnabled = switchItem.map { delegate?.validateMenuItem($0) == true } ?? false
    let showMatchesTitle = switchItem?.keyEquivalent == "j" && switchItem?.title == SereinRouter.switchState.title
      && switchEnabled == SereinRouter.switchState.enabled
    if let stopItem, let action = stopItem.action { NSApp.sendAction(action, to: stopItem.target, from: stopItem) }
    try await waitFor(5) { relay.run == nil && !relay.childRuns.contains(where: \.isActive) }
    // Once Serein and its tasks have stopped, the item has nothing left to stop.
    let disabledAfter = stopItem.map { delegate?.validateMenuItem($0) == false } ?? false
    try check(stopItem?.keyEquivalent == "." && stopItem?.keyEquivalentModifierMask == [.control, .option, .command]
              && enabledWhileWorking && disabledAfter && relay.run == nil && !relay.childRuns.contains(where: \.isActive) && relay.state.paused
              && countsOnce && showMatchesTitle,
              "File › Stop Everything stops Serein and its tasks and pauses [item: \(stopItem != nil), enabled: \(enabledWhileWorking), then: \(!disabledAfter), paused: \(relay.state.paused), quit: \(quitTitle ?? "none") for \(things), show: \(showMatchesTitle)]")
    relay.resume()

    // Placement: while Serein's chat is on screen, an approval waits inline in it, carrying the
    // thread that asked, and no alert, sheet or ⌥Space bar opens; answering collapses it to one
    // line. With the window in front but the chat gone (the column gave way) it waits in the chat
    // (the slim line says so); out of view the bar shows it; from the ⌥Space bar it waits in the
    // bar; put off with Later it waits in the chat. Only when no screen can show the bar does it
    // become an alert, and it still answers its run.
    let realVisible = relay.chatVisible
    let realScreen = relay.chatOnScreen
    let realShown = relay.chatShown
    let realBar = relay.panelVisible
    let realShow = relay.showPanel
    let realAnswer = relay.showForAnswer
    let realKey = relay.windowKey
    let realFull = relay.frontFullScreen
    let realScreens = relay.screenAvailable
    var panelShown = false
    var answerShown = 0
    var alerted: [String] = []
    func restore() {
      relay.chatVisible = realVisible
      relay.chatOnScreen = realScreen
      relay.chatShown = realShown
      relay.panelVisible = realBar
      relay.showPanel = realShow
      relay.showForAnswer = realAnswer
      relay.windowKey = realKey
      relay.frontFullScreen = realFull
      relay.screenAvailable = realScreens
      relay.alertOverride = nil
    }
    relay.chatVisible = { false }
    relay.chatOnScreen = { true }
    relay.chatShown = { true }
    relay.panelVisible = { false }
    relay.windowKey = { true }
    relay.frontFullScreen = { false }
    relay.screenAvailable = { true }
    relay.showPanel = { panelShown = true }
    relay.showForAnswer = { answerShown += 1 }
    relay.alertOverride = { alerted.append($0); return true }
    let asking = Task { @MainActor in
      await relay.confirmAnswer("Serein wants to click “Send” in Mail", "This sends the message.", thread: relay.threadID) == .yes
    }
    try await waitFor(3) { !relay.approvals.isEmpty }
    guard let card = relay.approvals.first else {
      restore()
      throw SereinError.invalid("FAIL: An approval while Serein’s chat is on screen shows inline, never as an alert (no card)")
    }
    let inline = card.threadID == relay.threadID && card.title == "Serein wants to click “Send” in Mail"
      && NSApp.modalWindow == nil && NSApp.windows.allSatisfy { $0.attachedSheet == nil } && !panelShown
      && alerted.isEmpty && answerShown == 0
    card.answer(.yes)
    let allowed = await asking.value
    let collapsed = relay.approvals.isEmpty && relay.answered.last?.allowed == true
      && relay.answered.last?.threadID == relay.threadID
    // The column gives way while the window is in front: the card waits in the chat.
    let leaving = Task { @MainActor in
      await relay.confirmAnswer("Serein wants to read your reminders", "Nothing is changed.", thread: relay.threadID) == .yes
    }
    try await waitFor(3) { !relay.approvals.isEmpty }
    relay.chatOnScreen = { false }
    relay.chatShown = { false }
    relay.reviewHiddenCards()
    try await Task.sleep(nanoseconds: 300_000_000)
    let waits = relay.approvals.count == 1 && alerted.isEmpty && answerShown == 0
    // The window closes: out of view, the bar shows the card (without the keyboard).
    relay.windowKey = { false }
    relay.reviewHiddenCards()
    let barred = answerShown == 1 && alerted.isEmpty && relay.approvals.count == 1
    relay.approvals.first?.answer(.yes)
    let moved = await leaving.value && waits && barred
    // Asked from the ⌥Space bar: the card waits in the bar; Later puts it off, and it waits in
    // the chat, never an alert.
    relay.panelVisible = { true }
    let fromBar = Task { @MainActor in
      await relay.confirmAnswer("Serein wants to read today’s events in Calendar", "Nothing is changed.", thread: relay.threadID) == .yes
    }
    try await waitFor(3) { !relay.approvals.isEmpty }
    let inBar = answerShown == 2 && alerted.isEmpty
    relay.deferWaiting()
    relay.panelVisible = { false }
    relay.reviewHiddenCards()
    try await Task.sleep(nanoseconds: 300_000_000)
    let later = relay.approvals.count == 1 && alerted.isEmpty && answerShown == 2
    relay.approvals.first?.answer(.yes)
    let barAnswered = await fromBar.value && later && relay.approvals.isEmpty
    // Split from the lines above so no one async function grows past what LLVM can split in time.
    func approvalsAndSereinChat() async throws {
      // No screen can show the bar: the alert, the last resort, still answering the run.
      relay.screenAvailable = { false }
      let lastResort = await relay.confirmAnswer("Serein wants to read your notes", "Nothing is changed.", thread: relay.threadID) == .yes
        && alerted == ["Serein wants to read your notes"]
      restore()
      try check(inline && allowed && collapsed && moved && inBar && barAnswered && lastResort,
                "An approval while Serein’s chat is on screen shows inline; with the window in front it waits in the chat; out of view the bar shows it; from the bar it waits there and Later leaves it in the chat; only with no screen for the bar is it an alert [inline: \(inline), waits: \(waits), bar: \(barred), from bar: \(inBar), later: \(barAnswered), alert: \(lastResort)]")

      if let controller = RelayController.shared {
        // The ⌥Space bar answers in place: the reply grows under the bar, Serein's window is not
        // brought forward and the main view stays as it was.
        try await waitFor(20) { relay.run == nil && !relay.working }
        let window = (NSApp.delegate as? AppDelegate)?.window
        let frameBefore = window?.frame
        let visibleBefore = window?.isVisible
        let sectionBefore = browser.section
        let selectedBefore = browser.selected
        var opened = 0
        let realOpen = controller.openWindow
        let realFront = controller.chatInFront
        controller.openWindow = { opened += 1 }
        controller.chatInFront = { false }
        // The ⌥Space bar, as the shortcut opens it: ⌥Space on for this check (the check above
        // turned it off).
        let enabledBefore = RelayOrchestrator.enabledOverride
        RelayOrchestrator.enabledOverride = true
        controller.show()
        let prompt = "WARM PING from the bar"
        controller.summonDraft = prompt
        controller.sendWriting()
        // Up when the message went (a click elsewhere may put it away later, by design; the
        // exchange stays for its reopening).
        let upAtSend = relay.panelVisible()
        try await waitFor(5) { relay.run != nil }
        try await waitFor(30) { relay.run == nil && !relay.working }
        func barReply() -> String {
          guard let exchange = controller.barExchange else { return "" }
          return SereinBarReply.replies(relay.run?.transcript ?? relay.transcript, exchange: exchange).map(\.text).joined()
        }
        let reply = barReply()
        let answeredInBar = upAtSend && controller.barExchange?.prompt == prompt && reply.contains("warm pong")
        // Sent while Serein works: the words take a side seat (no queue), the turn keeps running,
        // and the seat's answer posts in the chat under them, not an earlier answer to the same words.
        let slowCount = records().filter { $0["slow_child"] != nil }.count
        relay.ask("SLOW keep this one going")
        try await waitFor(5) { relay.run != nil }
        try await waitFor(10) { records().filter { $0["slow_child"] != nil }.count > slowCount }
        if !relay.panelVisible() { controller.show() }
        let slowRun = relay.run
        func asked() -> Int { records().filter { ($0["prompt"] as? String)?.contains(prompt) == true }.count }
        let askedBefore = asked()
        controller.summonDraft = prompt
        controller.sendWriting()
        let busyUp = relay.panelVisible()
        let staleFree = barReply().isEmpty
        let side = relay.handoffLedger.records.last { $0.side == .busy && $0.task == prompt }
        let tookSideSeat = relay.run === slowRun && relay.pending.isEmpty && slowRun?.steering.waiting.isEmpty == true && side != nil
        try await waitFor(15) { asked() > askedBefore }
        // Read while the turn still runs: the seat's answer waits above the turn, then lands in the chat.
        func sideAnswer() -> String {
          guard let side else { return "" }
          let id = HandoffReport.postID(side.id)
          return (relay.transcript + (relay.desk.facts[relay.threadID]?.above ?? [])).last { $0.id == id }?.text ?? ""
        }
        try await waitFor(15) { sideAnswer().contains("warm pong") }
        let keptRunning = slowRun?.isActive == true
        let busyReply = sideAnswer()
        // The slow turn reads no words now, so it is stopped here instead of ending on them.
        relay.stopReply()
        try await waitFor(30) { relay.run == nil && !relay.working }
        let answeredBusy = staleFree && busyUp && tookSideSeat && keptRunning && busyReply.contains("warm pong")
        for run in relay.childRuns where run.isActive { relay.agent.hub.stop(run) }
        let stayed = opened == 0 && browser.section == sectionBefore && browser.selected == selectedBefore
          && window?.frame == frameBefore && window?.isVisible == visibleBefore
        controller.hide()
        controller.barExchange = nil
        controller.openWindow = realOpen
        controller.chatInFront = realFront
        RelayOrchestrator.enabledOverride = enabledBefore
        try check(answeredInBar && answeredBusy && stayed,
                  "A message typed in the bar gets its reply in the bar; the window stays where it was [bar: \(answeredInBar), reply: \(reply.prefix(40)), while working: \(answeredBusy) \(busyReply.prefix(40)), stayed: \(stayed)]")

        let key = "my key is sk-proj-ABCDEFGHIJKLMNOPQRSTUV"
        controller.summonDraft = key
        controller.sendWriting()
        let keptInBar = controller.summonDraft == key
        let saidUnderBar = controller.barRefusalShown == ComposerGuard.keyRefusal
        controller.summonDraft = ""
        let goesWithWords = controller.barRefusalShown == nil
        relay.ask(key)
        let refused = relay.lastError == ComposerGuard.keyRefusal
        relay.lastError = nil
        try check(keptInBar && saidUnderBar && goesWithWords && refused,
                  "A key typed in the bar stays in the bar with the reason under it until the words change, and a key that arrives any other way is not sent [bar: \(keptInBar), said: \(saidUnderBar), goes: \(goesWithWords), refused: \(refused)]")

        let edited = relay.transcript.last { $0.role == "you" }
        let saidBefore = relay.transcript.map(\.id)
        let keepsEditor = edited.flatMap { relay.rerun($0.id, text: key) } == ComposerGuard.keyRefusal
        let uncut = relay.transcript.map(\.id) == saidBefore
        let saidInEditor = relay.lastError == nil
        try check(keepsEditor && uncut && saidInEditor,
                  "An edit that holds a key is refused before the chat is rewound, and its editor gets the reason to show beside the words [keeps: \(keepsEditor), uncut: \(uncut), editor only: \(saidInEditor)]")

        // A second assistant, so a stop can be said to one whose chat is not in front.
        let mainID = relay.team.activeID
        let mainName = relay.team.activeName
        let mainThread = relay.threadID
        let scoutID = relay.addProfile("Scout") ? relay.team.profiles.last?.id : nil
        // Spoken words are routed here whatever the person's own switch says. A check writes only
        // the argument domain, so their setting stays as it is.
        let argumentsBefore = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        RelayOrchestrator.setSetting(true, forKey: VoiceRoute.settingKey)
        func held(_ selection: String) -> ScreenContextCapture.Captured {
          .init(context: ScreenContext(app: "Pages", selection: selection))
        }
        func sent() -> Int { relay.transcript.filter { $0.role == "you" }.count }
        func startSlow(_ words: String) async throws {
          let before = records().filter { $0["slow_child"] != nil }.count
          relay.ask(words)
          try await waitFor(5) { relay.run != nil }
          try await waitFor(10) { records().filter { $0["slow_child"] != nil }.count > before }
        }
        /// The reply was stopped with nothing sent and no refusal, and it ended.
        func stoppedReply(_ sentBefore: Int) async throws -> Bool {
          let noticed = relay.stopNotice == .stoppedReply(working: relay.liveTasks, others: relay.otherLiveTasks)
            && relay.lastError == nil && sent() == sentBefore
          try await waitFor(10) { relay.run == nil && !relay.working }
          return noticed && !relay.working
        }
        func cardUp() -> Bool { relay.approvals.contains { $0.threadID == mainThread } }
        /// A card the reply in the main chat asked for, placed in the chat: no bar, alert or
        /// notification comes. False when it never came up.
        func askCard() async throws -> Bool {
          let realScreen = relay.chatOnScreen
          relay.chatOnScreen = { true }
          Task { @MainActor in
            _ = await relay.confirmAnswer("Serein wants to read your calendar", "Nothing is changed.", thread: mainThread)
          }
          try await waitFor(3) { cardUp() }
          relay.chatOnScreen = realScreen
          return cardUp()
        }
        /// The main chat in front with no reply running, whatever the case before left. `tasks`
        /// false leaves the task that reply started working.
        func settle(tasks: Bool = true) async throws {
          if relay.state.paused { relay.resume() }
          if relay.working { relay.stopReply() }
          try await waitFor(10) { relay.run == nil && !relay.working }
          if relay.team.activeID != mainID { _ = relay.switchTo(mainID) }
          if cardUp() { relay.declineApprovals(thread: mainThread) }
          guard tasks else { return }
          for run in relay.childRuns where run.isActive { relay.agent.hub.stop(run) }
          try await waitFor(10) { relay.liveTasks == 0 }
        }
        // Scout has nothing running, so the stop said to it stops the reply in front, and the card
        // that reply asked for is declined with it.
        try await startSlow("SLOW keep this one going too")
        let idleAsked = try await askCard()
        var sentBefore = sent()
        controller.sendFromBar("Scout, stop.", spoken: true, shown: held("Q3 spend"))
        let idle = try await stoppedReply(sentBefore) && relay.team.activeID == mainID
        let idleCard = idleAsked && !cardUp()
        try await settle(tasks: false)
        // The task that reply started still works: “cancel that” is a stop, not about the selection.
        sentBefore = sent()
        controller.sendFromBar("Cancel that.", spoken: true, shown: held("Q3 spend"))
        let overTask = relay.liveTasks > 0 && relay.stopNotice == .idle(working: relay.liveTasks, others: relay.otherLiveTasks)
          && sent() == sentBefore
        try await settle(tasks: false)
        // Said to Scout, which has nothing to stop, “cancel this” is about what was shown, although
        // that task still works: it goes to Scout with the selection. The fake CLI answers “warm
        // pong” only to the selection's words, so the reply shows it went.
        controller.chatInFront = { true }
        let taskWorks = relay.liveTasks > 0
        controller.sendFromBar("Scout, cancel this.", spoken: true, shown: held("WARM PING notes"))
        try await waitFor(15) { relay.run == nil && !relay.working && relay.transcript.last?.text.contains("warm pong") == true }
        let toIdle = taskWorks && relay.team.activeID == scoutID && relay.stopNotice == nil && sent() == 1
          && relay.transcript.last?.text.contains("warm pong") == true
        try await settle()
        // Serein's reply goes on behind Scout's chat, with a card waiting: “cancel that” said to
        // Serein is a stop, because Serein works. Its chat comes back, the reply stops there and its
        // card is declined.
        try await startSlow("SLOW and this one")
        sentBefore = sent()
        var away = scoutID.map { relay.switchTo($0) } ?? false
        let namedAsked = try await askCard()
        controller.sendFromBar("\(mainName), cancel that.", spoken: true, shown: held("Q3 spend"))
        let byName = try await stoppedReply(sentBefore) && away && relay.team.activeID == mainID
        let namedCard = namedAsked && !cardUp()
        try await settle()
        // A message waits behind that reply in Scout's chat, so the chats cannot change: the stop
        // said to Serein stops its reply from the chat in front, where a mention would wait.
        try await startSlow("SLOW one more")
        away = scoutID.map { relay.switchTo($0) } ?? false
        // A file keeps it waiting; a plain message would take a side seat and free the chats.
        relay.ask("also this", attachments: [SereinAttachment(title: "Also this note", body: "ALSO THIS NOTE 7731")], interrupt: false)
        sentBefore = sent()
        controller.sendFromBar("\(mainName), stop.", spoken: true, shown: held("Q3 spend"))
        let fromFront = try await stoppedReply(sentBefore) && away && relay.team.activeID == scoutID && relay.pending.isEmpty
        try await settle()
        // “Stop everything” keeps no name: said to Serein from Scout's chat, it acts from that chat.
        // Serein's reply behind it stops, and the pause is the chat in front's.
        try await startSlow("SLOW the last one")
        away = scoutID.map { relay.switchTo($0) } ?? false
        controller.sendFromBar("\(mainName), stop everything.", spoken: true, shown: held("Q3 spend"))
        try await waitFor(10) { relay.agent.hub.run(for: mainThread) == nil && !relay.working }
        let everything = away && relay.team.activeID == scoutID && relay.stopNotice == .everything && relay.state.paused
          && relay.agent.hub.run(for: mainThread) == nil
        try await settle()
        // Nothing runs and nobody is named: “cancel this” goes to the chat in front with the selection.
        sentBefore = sent()
        controller.sendFromBar("Cancel this.", spoken: true, shown: held("WARM PING notes"))
        try await waitFor(15) { relay.run == nil && !relay.working && relay.transcript.last?.text.contains("warm pong") == true }
        let went = relay.stopNotice == nil && sent() == sentBefore + 1 && relay.transcript.last?.text.contains("warm pong") == true
        try await settle()
        // An unattended turn is being handed to Scout, and nothing runs in its chat yet: “cancel
        // that” said to Scout is a stop all the same. The words go the moment the hand-over begins
        // (the main queue runs this before the turn's own task), then the turn is dropped unrun.
        // Scout's chat cannot come forward then, so the stop goes on as a plain one: with the chat in
        // front the bar gives way to it and lets go of what it showed.
        controller.barExchange = RelayController.BarExchange(prompt: "Earlier words", at: Date())
        var handover: Bool?, barGaveWay = false
        let handing = relay.$ownerRun.first { $0 != nil }.receive(on: DispatchQueue.main).sink { owner in
          let starting = relay.sending && owner?.profileID == scoutID
            && owner.map { relay.agent.hub.run(for: $0.thread) == nil } == true
          let before = sent()
          controller.sendFromBar("Scout, cancel that.", spoken: true, shown: held("Q3 spend"))
          handover = starting && relay.stopNotice == .stoppedReply(working: relay.liveTasks, others: relay.otherLiveTasks)
            && relay.lastError == nil && sent() == before
          barGaveWay = controller.barExchange == nil
          relay.stopEverything(pause: false)
        }
        relay.queueWork(
          .init(reminder: RelayReminder(text: "Check the fares", due: Date(), action: true), initiator: .webhook, profileID: scoutID),
          kind: .link, key: "check:" + UUID().uuidString)
        try await waitFor(10) { handover != nil && !relay.working }
        handing.cancel()
        relay.stopNotice = nil
        try await settle()
        if let scoutID { _ = relay.removeProfile(scoutID) }
        UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
        controller.chatInFront = realFront
        controller.hide()
        controller.barExchange = nil
        try check(idle && idleCard && overTask && toIdle && byName && namedCard && fromFront && everything && went && handover == true && barGaveWay,
          "A spoken stop starts no turn: said to an assistant with nothing running it stops the reply in front and declines its card; said to one with a reply in its own chat it stops that reply there and declines its card, or stops it from the chat in front when the chats cannot change; said to one a turn is being handed to it is a stop too, and the bar gives way as for a plain stop; “stop everything” by name acts from the chat in front; “cancel that” while only a task works is a stop that starts no turn; “cancel this” over something shown is sent with it, to the assistant named or to the chat in front [nothing running: \(idle), card: \(idleCard), over a task: \(overTask), sent by name: \(toIdle), by name: \(byName), card: \(namedCard), cannot switch: \(fromFront), everything: \(everything), sent: \(went), handed over: \(handover == true), bar gave way: \(barGaveWay)]")

        controller.summonDraft = key
        controller.sendWriting()
        let saidAgain = controller.barRefusalShown == ComposerGuard.keyRefusal
        controller.sendFromBar("Stop.", spoken: true)
        let spokenClears = controller.barRefusalShown == nil && controller.summonDraft == key
        controller.summonDraft = ""
        controller.hide()
        controller.barExchange = nil
        try check(saidAgain && spokenClears,
                  "Words that never pass through the bar's draft, as spoken ones do not, take away the reason under it [said: \(saidAgain), cleared: \(spokenClears)]")

        let trailBefore = GateSettings.shared.bool(forKey: ScreenTrail.enabledKey)
        let barBefore = RelayOrchestrator.enabledOverride
        RelayOrchestrator.enabledOverride = true
        func sentWithTrail(_ words: String, on: Bool) async throws -> String {
          if on { ScreenTrailWatch.turnOn() } else { GateSettings.shared.set(false, forKey: ScreenTrail.enabledKey) }
          ScreenTrailWatch.shared.refresh()
          ScreenTrailWatch.shared.note(app: "Pages", bundleID: "com.apple.iWork.Pages", window: "Budget 2026", isSerein: false, opensWebPages: false)
          ScreenTrailWatch.shared.note(app: "Safari", bundleID: "com.apple.Safari", window: "Hidden page", isSerein: false, opensWebPages: true)
          controller.sendFromBar(words)
          func prompt() -> String? { records().compactMap { $0["prompt"] as? String }.last { $0.contains(words) } }
          try await waitFor(15) { prompt() != nil }
          try await waitFor(30) { relay.run == nil && !relay.working }
          return prompt() ?? ""
        }
        for topic in relay.setupOffersHere { relay.dismissSetupOffer(topic, declined: false) }
        RelayOrchestrator.setSetting(false, forKey: ScreenTrailWatch.declinedKey)
        let withTrail = try await sentWithTrail("WARM PING trail on", on: true)
        let quietWhileOn = relay.setupOffersHere.isEmpty
        let chip = relay.transcript.last(where: { $0.role == "you" })?.attached?.contains(ScreenTrail.title) == true
        func sentByPerson() -> Int { relay.transcript.filter { $0.role == "you" }.count }
        let sentSoFar = sentByPerson()
        let carried = ScreenTrailWatch.shared.attachment()
        controller.sendFromBar("stop")
        let stopStays = carried != nil && !relay.working && relay.stopNotice == .idle(working: relay.liveTasks, others: relay.otherLiveTasks)
        relay.ask("", trail: carried, inWindow: false)
        let aloneSends = relay.working
        controller.sendFromBar("stop everything")
        let allStopped = !relay.working && relay.state.paused && relay.stopNotice == .everything
        relay.resume()
        let sentAsWords = sentByPerson() - sentSoFar
        GateSettings.shared.set(false, forKey: ScreenTrail.enabledKey)
        controller.sendFromBar("stop")
        let stopQuiet = relay.setupOffersHere.isEmpty
        let withoutTrail = try await sentWithTrail("WARM PING trail off", on: false)
        let offered = relay.setupOffersHere == [.follow]
        relay.dismissSetupOffer(.follow, declined: false)
        // Words that cut into a running reply start one too, so they bring the card as well.
        try await startSlow("SLOW look into this")
        let replyRunning = relay.run != nil
        controller.sendFromBar("WARM PING while busy")
        let offeredBusy = replyRunning && relay.setupOffersHere == [.follow]
        relay.dismissSetupOffer(.follow, declined: false)
        try await settle()
        RelayOrchestrator.setSetting(true, forKey: ScreenTrailWatch.declinedKey)
        relay.offerFollowIfUseful()
        let declinedQuiet = relay.setupOffersHere.isEmpty
        RelayOrchestrator.setSetting(false, forKey: ScreenTrailWatch.declinedKey)
        relay.offerSetup(.anywhere)
        relay.offerFollowIfUseful()
        let cardKept = relay.setupOffersHere == [.anywhere]
        relay.dismissSetupOffer(.anywhere, declined: false)
        ScreenTrailWatch.turnOff()
        relay.offerFollowIfUseful()
        let offByHand = relay.setupOffersHere.isEmpty
        RelayOrchestrator.setSetting(false, forKey: ScreenTrailWatch.declinedKey)
        func pagesInFront() {
          ScreenTrailWatch.shared.refresh()
          ScreenTrailWatch.shared.note(app: "Pages", bundleID: "com.apple.iWork.Pages", window: "Budget 2026", isSerein: false, opensWebPages: false)
        }
        GateSettings.shared.set(true, forKey: ScreenTrail.enabledKey)
        ScreenTrailWatch.shared.refresh()
        let forgotten = ScreenTrailWatch.shared.attachment() == nil
        pagesInFront()
        let keptAgain = ScreenTrailWatch.shared.attachment() != nil
        RelayOrchestrator.enabledOverride = false
        pagesInFront()
        let barOff = ScreenTrailWatch.shared.attachment() == nil
        controller.hide()
        controller.barExchange = nil
        GateSettings.shared.set(trailBefore, forKey: ScreenTrail.enabledKey)
        RelayOrchestrator.enabledOverride = barBefore
        ScreenTrailWatch.shared.refresh()
        let trailRode = withTrail.contains("Pages: Budget 2026") && withTrail.contains("- Safari (")
        let offArrived = withoutTrail.contains("WARM PING trail off")
        try check(trailRode && chip && !withTrail.contains("Hidden page") && offArrived && !withoutTrail.contains("Pages: Budget 2026"),
                  "The apps and windows the person was in ride with a message from the bar only while the switch is on, and never a browser's page [rode: \(trailRode), chip: \(chip), off arrived: \(offArrived)]")
        try check(stopStays && !aloneSends && allStopped && sentAsWords == 0,
                  "With the trail on, “stop” and “stop everything” from the bar are still commands, and the trail alone is no message [stop: \(stopStays), alone: \(aloneSends), everything: \(allStopped), sent as words: \(sentAsWords)]")
        try check(forgotten && keptAgain && barOff,
                  "Turning the trail off forgets it, and nothing is kept while Serein cannot be asked from other apps [forgotten: \(forgotten), kept again: \(keptAgain), bar off: \(barOff)]")
        try check(quietWhileOn && stopQuiet && offered && offeredBusy && declinedQuiet && offByHand && cardKept,
                  "A message from the bar offers following along while it is off, also one that cuts into a running reply, never for a command, never once it is on, was declined or was switched off by hand, and never over a card that waits [on: \(quietWhileOn), stop: \(stopQuiet), offered: \(offered), over a reply: \(offeredBusy), declined: \(declinedQuiet), off by hand: \(offByHand), kept: \(cardKept)]")

        // Out of view (another app in front, ⌥Space off): an approval shows in the bar without the
        // keyboard, never as an alert. Later puts the bar away and the card waits in Serein's chat;
        // over a full-screen app only the notification would show.
        var outAlerts: [String] = []
        relay.chatVisible = { false }
        relay.chatOnScreen = { false }
        relay.chatShown = { false }
        relay.windowKey = { false }
        relay.frontFullScreen = { false }
        relay.screenAvailable = { true }
        relay.alertOverride = { outAlerts.append($0); return true }
        let outEnabledBefore = RelayOrchestrator.enabledOverride
        RelayOrchestrator.enabledOverride = false
        let outOfView = Task { @MainActor in
          await relay.confirmAnswer("Serein wants to click “Send” in Mail", "This sends the message.", thread: relay.threadID) == .yes
        }
        try await waitFor(3) { !relay.approvals.isEmpty && relay.panelVisible() }
        let bar = NSApp.windows.first { $0 is RelayWindow }
        // It opened by itself, so it stands still: no hologram (it may wait for hours).
        let unfocused = relay.panelVisible() && bar?.isKeyWindow == false && controller.answerOnly && outAlerts.isEmpty
          && NSApp.modalWindow == nil && !controller.hologramVisible
        // A click into its field (the panel becomes key): you write in it now, so it is no longer
        // answer-only and answering will not put it away.
        let keyBefore = NSApp.keyWindow
        controller.giveKeyboard()
        try await waitFor(2) { !controller.answerOnly }
        let clickedIn = !controller.answerOnly
        controller.later()
        keyBefore?.makeKey()
        try await waitFor(2) { !relay.panelVisible() }
        try await Task.sleep(nanoseconds: 500_000_000)
        let waited = !relay.panelVisible() && relay.approvals.count == 1 && outAlerts.isEmpty
        relay.approvals.first?.answer(.no)
        let declined = await outOfView.value == false
        // Answered in the bar it opened for: once nothing waits, the bar goes by itself.
        let answerIn = Task { @MainActor in
          await relay.confirmAnswer("Serein wants to read your calendar", "Nothing is changed.", thread: relay.threadID) == .yes
        }
        try await waitFor(3) { !relay.approvals.isEmpty && relay.panelVisible() }
        relay.approvals.first?.answer(.yes)
        let answeredIn = await answerIn.value
        try await waitFor(3) { !relay.panelVisible() }
        let goneAfter = answeredIn && !relay.panelVisible() && outAlerts.isEmpty
        relay.frontFullScreen = { true }
        let overFull = Task { @MainActor in
          await relay.confirmAnswer("Serein wants to read your reminders", "Nothing is changed.", thread: relay.threadID) == .yes
        }
        try await waitFor(3) { !relay.approvals.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        let onlyNotified = !relay.panelVisible() && outAlerts.isEmpty
        relay.approvals.first?.answer(.no)
        _ = await overFull.value
        RelayOrchestrator.enabledOverride = outEnabledBefore
        restore()
        try check(unfocused && clickedIn && waited && declined && goneAfter && onlyNotified,
                  "An approval while Serein is out of view shows in the bar without the keyboard, never as an alert [bar: \(unfocused), clicked in: \(clickedIn), later: \(waited), answered: \(declined), goes after: \(goneAfter), full screen: \(onlyNotified)]")
      }

      // Serein's chat: every dispatch into it keeps its flag, the user's own saves never drop it,
      // and a reopened library still knows it. A message the user sends into it goes to Serein
      // (the send guard), while dispatch's own send still starts Serein's turn. Deleting the
      // current chat starts a new one. Files written before these fields still decode.
      try await waitFor(10) { relay.run == nil && !relay.working }
      let sereinID = relay.threadID
      agent.saveConversation()
      let flagged = agent.conversations.first { $0.id == sereinID }?.serein == true
      let reopened = browser.library.load([Conversation].self, from: "sessions/threads.json")?
        .first { $0.id == sereinID }
      let reopenedFlag = reopened?.serein == true && reopened.map(agent.isSereinChat) == true
      agent.showThreadTab(sereinID)
      let noTab = !agent.openThreads.contains(sereinID)
        && !ThreadTabs.open(browser: browser, agent: agent).contains { $0.id == sereinID || relay.isChild($0.id) }
      let listedHidden = !agent.listedConversations.contains { $0.id == sereinID }
      // The guard: the user's selected thread is Serein's chat (an older record could restore it).
      let userBefore = agent.conversationID
      let userSaved = agent.conversations.first { $0.id == userBefore }
      let sectionBefore = browser.section
      if let reopened { SereinRouter.direct { agent.openConversation(reopened) } }
      let guardArmed = agent.sereinChat
      let turnsBefore = records().filter { ($0["prompt"] as? String)?.contains("WARM PING guard") == true }.count
      agent.send("WARM PING guard")
      try await waitFor(5) { relay.run != nil || relay.sending }
      let forwarded = !agent.running && (relay.run != nil || relay.sending)
      try await waitFor(20) { relay.run == nil && !relay.working }
      let reached = records().filter { ($0["prompt"] as? String)?.contains("WARM PING guard") == true }.count > turnsBefore
      if let userSaved { SereinRouter.direct { agent.openConversation(userSaved) } } else { agent.clear() }
      browser.section = sectionBefore
      let stillFlagged = agent.conversations.first { $0.id == sereinID }?.serein == true
      // A chip rides as untrusted data in the turn only: the saved message keeps the words and the
      // chip's name, so the transcript, the title and note learning never read it as the user's.
      let chipTitle = "Part of “Fixture”"
      relay.ask("WARM PING chip", attachments: [SereinAttachment(title: chipTitle, body: "CHIP BODY 7731")])
      try await waitFor(5) { relay.run != nil || relay.sending }
      try await waitFor(20) { relay.run == nil && !relay.working }
      let chipSent = records().contains {
        ($0["prompt"] as? String).map { $0.contains("WARM PING chip") && $0.contains("CHIP BODY 7731") && $0.contains("<untrusted_attachment>") } == true
      }
      let chipSaved = relay.transcript.last { $0.role == "you" }
      let chipKept = chipSent && chipSaved?.text == "WARM PING chip" && chipSaved?.attached == [chipTitle]
        && !relay.transcript.contains { $0.text.contains("CHIP BODY 7731") }
        && agent.conversations.first { $0.id == sereinID }.map { !$0.title.contains("CHIP BODY") } == true
      // A chip sent with no words: the CLI gets a stand-in line, the saved message keeps no words
      // (only the chip's name), and nothing invented shows as yours.
      let aloneTitle = "Part of “Fixture alone”"
      relay.ask("", attachments: [SereinAttachment(title: aloneTitle, body: "CHIP ALONE 5519")])
      try await waitFor(5) { relay.run != nil || relay.sending }
      try await waitFor(20) { relay.run == nil && !relay.working }
      let aloneSent = records().contains {
        ($0["prompt"] as? String).map { $0.contains("CHIP ALONE 5519") && $0.contains(SereinAttachment.noWords) } == true
      }
      let aloneSaved = relay.transcript.last { $0.role == "you" }
      let chipAlone = aloneSent && aloneSaved?.text == "" && aloneSaved?.attached == [aloneTitle]
        && !relay.transcript.contains { $0.role == "you" && $0.text == SereinAttachment.noWords }
      // The chat indexes (Chats card, Projects) list none of Serein's chats, and the harness session
      // a Serein chat ran in stays hidden behind it rather than showing as a “past” chat.
      var hiddenIndex = false
      if var sereinRecord = agent.conversations.first(where: { $0.id == sereinID }), let driver = sereinRecord.provider.driver {
        sereinRecord.remoteID = "serein-check-session"
        let session = DiscoveredSession(provider: driver.rawValue, id: "serein-check-session",
                                        cwd: NSHomeDirectory() + "/serein-check", title: "WARM PING", date: Date())
        let hiding = ProjectChatIndex(projects: [], threads: [sereinRecord], running: [], history: [session], hides: agent.isSereinChat)
        let plain = ProjectChatIndex(projects: [], threads: [sereinRecord], running: [], history: [session])
        hiddenIndex = hiding.all.isEmpty && plain.all.count == 1
      }
      // Deleting Serein's current chat moves it to a new one; the deleted id is not a past chat.
      agent.deleteThread(sereinID)
      let rotated = relay.threadID != sereinID && relay.state.pastThreadIDs?.contains(sereinID) != true
        && !relay.pastChats.contains { $0.id == sereinID }
      // Old files: a state.json and a threads.json written before pastThreadIDs and serein.
      let oldState = #"{"threadID":"old-relay-thread","children":[],"paused":false}"#
      let oldThreads = #"[{"id":"old-thread","title":"Old","messages":[{"id":"m1","role":"you","text":"hi"}],"provider":"claude","mode":"Anywhere","scope":"claude|anywhere|relay","updatedAt":"2026-10-20T10:00:00Z"}]"#
      try oldState.write(to: browser.library.root.appendingPathComponent("relay-check/old-state.json"), atomically: true, encoding: .utf8)
      try oldThreads.write(to: browser.library.root.appendingPathComponent("relay-check/old-threads.json"), atomically: true, encoding: .utf8)
      let decodedState = browser.library.load(RelayOrchestrator.State.self, from: "relay-check/old-state.json")
      let decodedThreads = browser.library.load([Conversation].self, from: "relay-check/old-threads.json")
      let oldFiles = decodedState?.threadID == "old-relay-thread" && decodedState?.pastThreadIDs == nil
        && decodedThreads?.first?.serein == nil && decodedThreads.map { $0.first.map(agent.isSereinChat) == true } == true
      try check(flagged && reopenedFlag && noTab && listedHidden && guardArmed && forwarded && reached && stillFlagged
                && chipKept && chipAlone && hiddenIndex && rotated && oldFiles,
                "A Serein turn still starts with the send guard in place, and its chat keeps the Serein flag [flag: \(flagged), reopened: \(reopenedFlag), no tab: \(noTab), hidden: \(listedHidden), guard: \(guardArmed), forwarded: \(forwarded), reached: \(reached), kept: \(stillFlagged), chip: \(chipKept), chip alone: \(chipAlone), index: \(hiddenIndex), rotated: \(rotated), old files: \(oldFiles)]")
    }
    try await approvalsAndSereinChat()

    // Its defers run when this part ends, just before the return, as they did at the function's end.
    func pageChipAndSurfaces() async throws {
      // The page chip (S8). Two regular tabs, a private one and a password page, all synthetic.
      try await waitFor(10) { relay.run == nil && !relay.working }
      func pageTab(_ title: String, _ html: String, host: String, isPrivate: Bool = false) async throws -> BrowserTab {
        let tab = BrowserTab(privateMode: isPrivate, store: .nonPersistent())
        tab.web.loadHTMLString("<!doctype html><title>\(title)</title>" + html, baseURL: URL(string: "https://\(host)/"))
        browser.tabs.append(tab)
        for _ in 0..<80 where tab.web.isLoading || tab.web.url == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        // The address the tab shows, with a path, a query and a fragment that must never ride along.
        tab.title = title
        tab.address = "https://\(host)/guides/ramen?ref=SECRETQ#top"
        return tab
      }
      let plainTab = try await pageTab("Ramen guide · Eater", "<h1>Ramen guide</h1><p>PAGE TEXT 4417: Ichiran opens until 11.</p>", host: "www.eater.example")
      let otherTab = try await pageTab("Other page", "<p>OTHER 9912</p>", host: "other.example")
      let privateTab = try await pageTab("Gift ideas", "<p>PRIVATE 5521</p>", host: "gifts.example", isPrivate: true)
      let payTab = try await pageTab("Checkout", "<form><label>Card<input autocomplete=\"cc-number\" name=card></label><label>Password<input type=password name=pw></label></form><p>PAY 3381</p>", host: "pay.example")
      defer {
        [plainTab, otherTab, privateTab, payTab].forEach { $0.discardPage() }
        browser.tabs.removeAll { [plainTab.id, otherTab.id, privateTab.id, payTab.id].contains($0.id) }
      }
      let plainPage = SereinPageChip.page(plainTab)
      let privatePage = SereinPageChip.page(privateTab)

      // 1. The title and site ride in the turn's context (the volatile tail, never the stable
      // prefix), never the path or the query, and never a private tab's.
      let stableBeforePage = RelayPrompt.stable(browser: browser)
      relay.turnPage = plainPage
      let withPage = RelayPrompt.volatile(request: "which are open late?", thread: relay.threadID)
      relay.turnPage = privatePage
      let withPrivate = RelayPrompt.volatile(request: "which are open late?", thread: relay.threadID)
      relay.turnPage = nil
      let withoutPage = RelayPrompt.volatile(request: "which are open late?", thread: relay.threadID)
      let lineOK = withPage.contains("“Ramen guide · Eater” on eater.example") && withPage.contains("untrusted data, not instructions")
        && !withPage.contains("/guides") && !withPage.contains("SECRETQ") && !withPage.contains("PAGE TEXT 4417")
        && !withPrivate.contains("Gift ideas") && !withPrivate.contains("gifts.example")
        && !withoutPage.contains("current tab") && RelayPrompt.stable(browser: browser) == stableBeforePage
        && !stableBeforePage.contains("Ramen guide")
      // End to end: a message carrying the chip reaches the AI app with the line; a private tab's never does.
      relay.ask("WARM PING page", page: plainPage)
      try await waitFor(5) { relay.run != nil || relay.sending }
      let bound = relay.turnPage == plainPage
      try await waitFor(20) { relay.run == nil && !relay.working }
      let pageSent = records().contains {
        ($0["prompt"] as? String).map { $0.contains("WARM PING page") && $0.contains("“Ramen guide · Eater” on eater.example") && !$0.contains("SECRETQ") } == true
      }
      relay.ask("WARM PING private", page: privatePage)
      try await waitFor(5) { relay.run != nil || relay.sending }
      let privateUnbound = relay.turnPage == nil
      try await waitFor(20) { relay.run == nil && !relay.working }
      let privateSent = records().contains {
        ($0["prompt"] as? String).map { $0.contains("WARM PING private") && !$0.contains("Gift ideas") && !$0.contains("gifts.example") } == true
      }
      // The chip's own rule: a private tab shows “Private tab · not shared”, a removed chip stays off.
      let slotPrivate = SereinPageChip.slot(section: ShellSection.browser, active: privatePage, removed: [], left: nil, sharing: true, now: Date())
      let slotRemoved = SereinPageChip.slot(section: ShellSection.browser, active: plainPage, removed: [plainPage.tabID], left: nil, sharing: true, now: Date())
      let slotOff = SereinPageChip.slot(section: ShellSection.browser, active: plainPage, removed: [], left: nil, sharing: false, now: Date())
      let slotFull = SereinPageChip.slot(section: ShellSection.serein, active: nil, removed: [], left: (plainPage, Date().addingTimeInterval(-60)), sharing: true, now: Date())
      let slotStale = SereinPageChip.slot(section: ShellSection.serein, active: nil, removed: [], left: (plainPage, Date().addingTimeInterval(-601)), sharing: true, now: Date())
      let slotsOK = slotPrivate == .privateTab && slotRemoved == .none && slotOff == .none
        && slotFull == .page(plainPage, last: true) && slotStale == .none
      try check(lineOK && bound && pageSent && privateUnbound && privateSent && slotsOK,
                "The current tab’s title and site ride in the turn context, never a private tab’s [line: \(lineOK), bound: \(bound), sent: \(pageSent), private: \(privateUnbound) \(privateSent), chip: \(slotsOK)]")

      // 2. current_page reads only the chip's tab: its address without the query and its text,
      // framed as untrusted, logged in Activity; private tabs, files and password pages are refused.
      func refusal(_ name: String, _ arguments: [String: Any] = [:]) async -> String? {
        do { _ = try await relay.tools.call(name, arguments, thread: relay.threadID); return nil } catch { return error.localizedDescription }
      }
      relay.turnPage = plainPage
      var readError = ""
      var read: [String: Any]?
      do { read = try await relay.tools.call("current_page", [:], thread: relay.threadID) } catch { readError = error.localizedDescription }
      let readLogged = relay.activity.last?.text ?? "-"
      let readOK = read?["address"] as? String == "https://www.eater.example/guides/ramen"
        && (read?["text_untrusted"] as? String)?.contains("PAGE TEXT 4417") == true
        && readLogged == "Read “Ramen guide · Eater”"
      relay.turnPage = privatePage
      let privateRefused = await refusal("current_page") == CurrentPageContext.privateRefusal
      relay.turnPage = SereinPageChip.page(payTab)
      let payRefused = await refusal("current_page") == CurrentPageContext.sensitiveRefusal
      relay.turnPage = SereinPage(tabID: plainTab.id, title: "Notes", url: "file:///Users/me/notes.html")
      let fileRefused = await refusal("current_page") == CurrentPageContext.pageKindRefusal
      relay.turnPage = nil
      let noChipRefused = await refusal("current_page") == CurrentPageContext.noChipRefusal
      try check(readOK && privateRefused && payRefused && fileRefused && noChipRefused,
                "current_page refuses private tabs and password pages [read: \(readOK) \(readError) \(readLogged), private: \(privateRefused), password: \(payRefused), file: \(fileRefused), no chip: \(noChipRefused)]")

      // 3. A tab named only in a tool call is refused: “do it here” binds only to the tab the
      // user's own message carried, after Work in this tab?, and dispatch takes a tab only from the
      // host binding.
      let runsBefore = agent.hub.runs.count
      relay.turnPage = nil
      let hereWithoutChip = await refusal("agent_start", ["task": "Book a table", "destination": "here"]) != nil
      relay.turnPage = plainPage
      let namedInStart = await refusal("agent_start", ["task": "Book a table", "destination": "here", "tab": otherTab.id])
        == RelayToolHost.namedTab.localizedDescription
      let namedInAnswer = await refusal("agent_start", ["task": "Book a table", "destination": "answer", "tab_id": otherTab.id])
        == RelayToolHost.namedTab.localizedDescription
      let webRefused = await refusal("agent_start", ["task": "Book a table", "destination": "web", "tab_id": otherTab.id])
        == AssistantWeb.webRefusal
      let namedInRead = await refusal("current_page", ["tab": otherTab.id]) == RelayToolHost.namedTab.localizedDescription
      let hereApprovals = try FixtureApprovals(browser: browser, agent: agent)
      defer { hereApprovals.close() }
      let workHereCard = CurrentPageContext.workHereCard(title: "Ramen guide · Eater", site: CurrentPageContext.host(plainTab.address))
      var askedHere = false
      let declined = try await hereApprovals.perform(expecting: [
        .init(title: workHereCard.title, detail: workHereCard.detail, thread: relay.threadID,
              button: workHereCard.button, more: "Book a table", moreName: "the task", answer: .no, beforeAnswer: { askedHere = true }),
      ]) {
        await refusal("agent_start", ["task": "Book a table", "destination": "here"]) != nil
      }
      relay.turnPage = nil
      var unboundRefused = false
      do {
        _ = try await agent.dispatch("x", into: nil, as: AgentModel.DispatchTarget(mode: .page, provider: .claude))
      } catch { unboundRefused = error.localizedDescription == "Serein cannot start that kind of task." }
      let nothingStarted = agent.hub.runs.count == runsBefore && relay.workHereAllowed.isEmpty
      try check(hereWithoutChip && namedInStart && namedInAnswer && webRefused && namedInRead && declined && askedHere && unboundRefused && nothingStarted,
                "A tab named only in a tool call is refused [no chip: \(hereWithoutChip), named: \(namedInStart) \(namedInAnswer) \(webRefused) \(namedInRead), asked: \(askedHere) \(declined), dispatch: \(unboundRefused), none started: \(nothingStarted)]")

      // Approval and provider preparation may yield: neither may grant a different site or a
      // stopped turn access to the user's tab.
      relay.turnPage = plainPage
      let originalAddress = plainTab.address
      let movedDuringApproval = try await hereApprovals.perform(expecting: [
        .init(title: workHereCard.title, detail: workHereCard.detail, thread: relay.threadID,
              button: workHereCard.button, more: "CHILD here race", moreName: "the task", beforeAnswer: { plainTab.address = "https://different.example/" }),
      ]) {
        await refusal("agent_start", ["task": "CHILD here race", "destination": "here"])
      }
      let changedSiteRead = await refusal("current_page")
      plainTab.address = originalAddress
      var pageValidationCalls = 0
      var staleTarget = AgentModel.DispatchTarget(mode: .page, provider: .claude)
      staleTarget.page = plainPage
      staleTarget.pageIsCurrent = { pageValidationCalls += 1; return pageValidationCalls == 1 }
      var staleDispatchRefused = false
      do { _ = try await agent.dispatch("CHILD stale page", into: nil, as: staleTarget) }
      catch { staleDispatchRefused = error.localizedDescription.contains("approved tab or site changed") }
      try check(movedDuringApproval?.contains("approved tab or site changed") == true
                && changedSiteRead?.contains("changed sites") == true && staleDispatchRefused && pageValidationCalls == 2
                && agent.hub.runs.count == runsBefore && relay.workHereAllowed.isEmpty,
                "Page grants reject site changes during approval and revalidate immediately before dispatch")

      // A successful start and continuation load only the approved URL into separate task-owned
      // tabs. The real local page is reachable through the fixture proxy; personal state is not copied.
      let reportsBeforeHere = relay.reportsFinishedWork
      relay.reportsFinishedWork = false
      defer { relay.reportsFinishedWork = reportsBeforeHere }
      let selectedBeforeHere = browser.selected
      let hereBase = ProcessInfo.processInfo.environment["SEREIN_FIXTURE_URL"] ?? "http://127.0.0.1:18765/"
      guard let hereURL = URL(string: "relay-here?approved=203#bound", relativeTo: URL(string: hereBase))?.absoluteURL else {
        throw SereinError.invalid("FAIL: Invalid work-here fixture URL")
      }
      let hereTab = BrowserTab(store: .nonPersistent())
      browser.tabs.append(hereTab)
      defer {
        browser.selected = selectedBeforeHere
        hereTab.discardPage()
        browser.tabs.removeAll { $0.id == hereTab.id }
      }
      try hereTab.navigate(hereURL.absoluteString)
      await hereTab.settle(limit: 10)
      guard try await hereTab.script("document.title === 'Work here fixture' && !!document.querySelector('textarea')") as? Bool == true else {
        throw SereinError.invalid("FAIL: The work-here fixture page did not load")
      }
      _ = try await hereTab.script("sessionStorage.setItem('personalHere', 'PRIVATE HERE 203'); document.cookie = 'personalHere=PRIVATE203; path=/'; document.querySelector('textarea').value = 'personal draft 203'; true")
      let herePage = SereinPageChip.page(hereTab)
      let hereWeb = hereTab.web
      let hereStore = hereWeb.configuration.websiteDataStore
      let hereRecordCount = records().filter { $0["here_bound_tabs"] != nil }.count
      let firstGate = folder.appendingPathComponent("here-binding-first-release")
      let followGate = folder.appendingPathComponent("here-binding-follow-release")
      for gate in [firstGate, followGate] { try? FileManager.default.removeItem(at: gate) }
      var hereID = ""
      defer {
        if let run = agent.hub.run(for: hereID) { agent.hub.stop(run) }
        for gate in [firstGate, followGate] { try? Data().write(to: gate) }
      }
      func ownedHereCopy(_ run: AgentRun?) async throws -> [String] {
        guard let run, let tabs = browser.tasks[run.taskID]?.tabs, tabs.count == 1, let copy = tabs.first else {
          throw SereinError.invalid("FAIL: Work here did not create exactly one task tab")
        }
        await copy.settle(limit: 10)
        let separate = copy.owner == run.taskID && copy.id != hereTab.id && copy.id != otherTab.id
          && copy.address == hereURL.absoluteString && copy.web.configuration.websiteDataStore !== hereStore
          && copy.web.configuration.websiteDataStore !== WKWebsiteDataStore.default()
          && !copy.web.configuration.websiteDataStore.proxyConfigurations.isEmpty && hereStore.proxyConfigurations.isEmpty
        // A task's store starts empty: none of the person's sign-ins, storage or typing comes along.
        let clean = try await copy.script("document.title === 'Work here fixture' && document.body.textContent.includes('OWNED HERE 203') && !sessionStorage.getItem('personalHere') && !document.cookie.includes('personalHere=') && document.querySelector('textarea').value === ''") as? Bool == true
        guard separate && clean else {
          let store = copy.web.configuration.websiteDataStore
          let facts = "separate=\(separate) clean=\(clean) owner=\(copy.owner == run.taskID) address=\(copy.address == hereURL.absoluteString) "
            + "ownStore=\(store !== hereStore && store !== WKWebsiteDataStore.default()) proxied=\(!store.proxyConfigurations.isEmpty) personalDirect=\(hereStore.proxyConfigurations.isEmpty)"
          let page = try await copy.script("JSON.stringify({title: document.title, body: document.body.textContent.slice(0, 120), session: sessionStorage.getItem('personalHere') !== null, cookie: document.cookie.includes('personalHere='), note: document.querySelector('textarea')?.value, url: location.href})") as? String ?? "?"
          throw SereinError.invalid("FAIL: Work here copied the wrong page or personal state: " + facts + " page=" + page)
        }
        return tabs.map(\.id)
      }
      browser.selected = otherTab.id
      relay.turnPage = herePage
      let liveHereCard = CurrentPageContext.workHereCard(title: "Work here fixture", site: CurrentPageContext.host(hereTab.address))
      let hereStarted = try await hereApprovals.perform(expecting: [
        .init(title: liveHereCard.title, detail: liveHereCard.detail, thread: relay.threadID,
              button: liveHereCard.button, more: "CHILD HERE BINDING first", moreName: "the task"),
      ]) {
        try await relay.tools.call("agent_start", ["task": "CHILD HERE BINDING first", "destination": "here"], thread: relay.threadID)
      }
      hereID = hereStarted["run"] as? String ?? ""
      let firstHereRun = agent.hub.run(for: hereID)
      let firstHereTabs = try await ownedHereCopy(firstHereRun)
      try await waitFor(10) { records().filter { $0["here_bound_tabs"] != nil }.count > hereRecordCount }
      try Data().write(to: firstGate)
      try await waitFor(20) { agent.hub.run(for: hereID) == nil }
      relay.turnPage = herePage
      guard let hereThread = agent.conversations.first(where: { $0.id == hereID }) else {
        throw SereinError.invalid("FAIL: The work-here conversation was not saved")
      }
      // The site grant supplies access, not consent to new instructions. Even under Autopilot,
      // a new task on the approved site and a follow-up each wait for their own exact card.
      let runsBeforeInstructions = agent.hub.runs.count
      let tasksBeforeInstructions = Set(browser.tasks.keys)
      let bindingsBeforeInstructions = records().filter { $0["here_bound_tabs"] != nil }.count
      let newHereTask = String(repeating: "Review the entries. ", count: 18) + "Do not submit."
      let newHereCard = ApprovalCopy.startTask(provider: hereThread.provider.name, destination: "here",
                                              place: CurrentPageContext.host(hereTab.address), edits: false, task: newHereTask)
      let newHereDeclined = try await hereApprovals.perform(expecting: [
        .init(title: newHereCard.title, detail: newHereCard.detail, thread: relay.threadID,
              button: "Start", more: newHereTask, moreName: "the task", answer: .no),
      ]) {
        await refusal("agent_start", ["task": newHereTask, "destination": "here"])
      }
      let followHereText = "CHILD HERE BINDING follow-up"
      let followHereCard = ApprovalCopy.sendTask(provider: hereThread.provider.name, run: hereID,
                                                title: hereThread.title, text: followHereText)
      let followHereDeclined = try await hereApprovals.perform(expecting: [
        .init(title: followHereCard.title, detail: followHereCard.detail, thread: relay.threadID,
              button: "Send", more: followHereText, moreName: "the message", answer: .no),
      ]) {
        await refusal("agent_send", ["run": hereID, "text": followHereText])
      }
      let declinedInstructionsUnsent = newHereDeclined == "The user declined this delegated run."
        && followHereDeclined == "The user declined this delegated run."
        && agent.hub.runs.count == runsBeforeInstructions && Set(browser.tasks.keys) == tasksBeforeInstructions
        && records().filter { $0["here_bound_tabs"] != nil }.count == bindingsBeforeInstructions
      _ = try await hereApprovals.perform(expecting: [
        .init(title: followHereCard.title, detail: followHereCard.detail, thread: relay.threadID,
              button: "Send", more: followHereText, moreName: "the message"),
      ]) {
        try await relay.tools.call("agent_send", ["run": hereID, "text": followHereText], thread: relay.threadID)
      }
      let followHereRun = agent.hub.run(for: hereID)
      let followHereTabs = try await ownedHereCopy(followHereRun)
      try await waitFor(10) { records().filter { $0["here_bound_tabs"] != nil }.count > hereRecordCount + 1 }
      try Data().write(to: followGate)
      try await waitFor(20) { agent.hub.run(for: hereID) == nil }
      relay.turnPage = SereinPageChip.page(otherTab)
      let retargetRefused = try await hereApprovals.perform(expecting: []) {
        await refusal("agent_send", ["run": hereID, "text": "CHILD wrong tab"])
      }
      browser.selected = selectedBeforeHere
      hereApprovals.close()
      let hereRecords = records().compactMap { $0["here_bound_tabs"] as? [String: Any] }
      let recordedBindings = hereRecords.compactMap { ($0["tabs"] as? [[String: Any]])?.first?["tab"] as? String }
      let personalUnchanged = hereTab.owner == nil && hereTab.address == hereURL.absoluteString && hereTab.web === hereWeb
        && hereTab.web.configuration.websiteDataStore === hereStore && hereStore.proxyConfigurations.isEmpty && otherTab.owner == nil
      let personalStateKept = try await hereTab.script("sessionStorage.getItem('personalHere') === 'PRIVATE HERE 203' && document.cookie.includes('personalHere=PRIVATE203') && document.querySelector('textarea').value === 'personal draft 203'") as? Bool == true
      try check(!hereID.isEmpty && firstHereTabs != followHereTabs && personalUnchanged && personalStateKept && declinedInstructionsUnsent
                && Array(recordedBindings.suffix(2)) == firstHereTabs + followHereTabs
                && recordedBindings.count >= hereRecordCount + 2 && retargetRefused?.contains("original tab and site") == true,
                "Work here and agent_send copy the approved URL into owned tabs, preserve personal state, ask before new instructions, send nothing on decline, and refuse retargeting without a card")
      let ownStoreGuide = WebTaskPrompt.text(isolated: false, actions: true)
      let isolatedGuide = WebTaskPrompt.text(isolated: true, actions: true)
      try check(ownStoreGuide.contains("start signed out")
                && !ownStoreGuide.contains("own sign-ins") && !ownStoreGuide.contains("Your tabs are isolated")
                && isolatedGuide.contains("Your tabs are isolated") && !isolatedGuide.contains("start signed out"),
                "The web task guide tells a task with its own store that it starts signed out, as the page above proved")
      let signInChip = TaskPermissions.chip(.signIns, on: true)
      try check(signInChip.label == "Signing in" && signInChip.detail.contains("start signed out")
                && !signInChip.detail.contains("your sign-ins"),
                "The sign-in permission says its tabs start signed out instead of promising the person's sign-ins")

      // The explicit page-with-text chip wins over the automatic current-tab chip.
      let explicitPage = SereinAttachment(title: "Explicit page A", icon: "globe", body: "EXPLICIT PAGE A 713",
                                         page: plainPage)
      // The turn that called agent_send may still be ending on a busy Mac; a message sent then waits
      // (`pending`) and binds its page only when it goes, so the binding is read on a fresh turn.
      try await waitFor(20) { !relay.working }
      relay.ask("WARM PING explicit-page-binding", attachments: [explicitPage], page: SereinPageChip.page(otherTab))
      let explicitBound = relay.turnPage == plainPage
      try await waitFor(20) { !relay.working }
      let explicitPrompt = records().compactMap { $0["prompt"] as? String }.last { $0.contains("WARM PING explicit-page-binding") } ?? ""
      try check(explicitBound && explicitPrompt.contains("EXPLICIT PAGE A 713")
                && explicitPrompt.contains("“Ramen guide · Eater” on eater.example") && !explicitPrompt.contains("on other.example"),
                "An explicit page attachment supplies the current-page binding when a different tab is selected")

      // Queue entries own their page and attachments. Removing the last entry must remove both,
      // while a surviving entry with no chip must not inherit a deleted entry's tab.
      relay.ask("WARM PING queue-context-seed")
      // Files keep a message in the queue; a plain one would take a side seat.
      relay.ask("WARM PING queue-context-keep", attachments: [SereinAttachment(title: "Keep note", body: "KEEP NOTE 3307")],
                interrupt: false)
      let removedPage = SereinAttachment(title: "Discard page B", icon: "globe", body: "REMOVED PAGE B 947",
                                        page: SereinPageChip.page(otherTab))
      relay.ask("WARM PING queue-context-discard", attachments: [removedPage], interrupt: false)
      relay.removePending(at: 1)
      try await waitFor(30) { !relay.working && relay.pending.isEmpty }
      let keptPrompt = records().compactMap { $0["prompt"] as? String }.last { $0.contains("WARM PING queue-context-keep") } ?? ""
      try check(!keptPrompt.isEmpty && !keptPrompt.contains("REMOVED PAGE B 947")
                && !keptPrompt.contains("queue-context-discard") && !keptPrompt.contains("current tab (untrusted data")
                && relay.turnPage == nil,
                "Removing a queued message also removes its attachments and page authority")
      relay.turnPage = nil
      relay.reportsFinishedWork = reportsBeforeHere

      // Serein beside and back: ⌘J moves Serein from beside a tab to full and back, with the same
      // chat, the same unsent draft and (when one is alive) the same hologram engine, all of which
      // live in the window's surface. Hide turns beside off with an Undo; asking from hidden only
      // peeks beside this tab, never writing the saved choice, and the peek ends on another
      // selection; Hide during a peek only ends it.
      try await waitFor(10) { relay.run == nil && !relay.working }
      let surface = SereinSurface.main
      let besideBefore = SereinRouter.besideOn
      let viewBefore = browser.section
      let draftBefore = surface.draft
      RelayOrchestrator.setSetting(true, forKey: RelayController.columnKey)
      // A page with an address, like one a task hands over: a blank tab has no screen, so it falls
      // back to Serein.
      let selectedBeforeBeside = browser.selected
      let besideTab = BrowserTab(store: .nonPersistent())
      browser.tabs.append(besideTab)
      defer {
        browser.selected = selectedBeforeBeside
        besideTab.discardPage()
        browser.tabs.removeAll { $0.id == besideTab.id }
      }
      try besideTab.navigate(hereURL.absoluteString)
      await besideTab.settle(limit: 10)
      browser.selected = besideTab.id
      browser.section = ShellSection.browser
      try await waitFor(5) { surface.place == .beside && RelayController.columnShown }
      let besideFirst = surface.place == .beside && RelayController.columnShown && SereinRouter.switchState.title == "Show Serein Full"
      surface.draft = "WARM PING draft kept"
      let chatBefore = relay.threadID
      let engineBefore = surface.madeEngine
      SereinRouter.toggleFullBeside()
      try await waitFor(5) { surface.place == .full && RelayController.columnShown }
      let wentFull = browser.section == ShellSection.serein && surface.place == .full && RelayController.columnShown
        && surface.draft == "WARM PING draft kept" && relay.threadID == chatBefore
        && SereinRouter.switchState.title == "Show Serein Beside" && SereinRouter.switchState.enabled
      SereinRouter.toggleFullBeside()
      try await waitFor(5) { surface.place == .beside && RelayController.columnShown }
      let cameBack = [ShellSection.browser, ShellSection.start].contains(browser.section) && surface.place == .beside
        && surface.draft == "WARM PING draft kept" && relay.threadID == chatBefore && SereinRouter.besideOn
        && (engineBefore == nil || surface.madeEngine === engineBefore)
      let backFacts = "section=\(browser.section) place=\(surface.place) fits=\(surface.fits) besideOn=\(SereinRouter.besideOn) draft=\(surface.draft == "WARM PING draft kept") chat=\(relay.threadID == chatBefore) engine=\(engineBefore == nil || surface.madeEngine === engineBefore)"
      let pageView = browser.section
      SereinRouter.hide()
      try await waitFor(5) { surface.place == .hidden }
      let hid = !SereinRouter.besideOn && surface.place == .hidden
        && ToastCenter.shared.queue.items.contains { $0.id == "serein-hidden" && $0.actionTitle == "Undo" }
      ToastCenter.shared.perform("serein-hidden")
      try await waitFor(5) { surface.place == .beside }
      let undone = SereinRouter.besideOn && surface.place == .beside
      SereinRouter.hide()
      try await waitFor(5) { surface.place == .hidden }
      SereinRouter.show()
      try await waitFor(5) { surface.place == .beside }
      let peeked = surface.peek && !SereinRouter.besideOn && surface.place == .beside && browser.section == pageView
      // History is a legacy deep link to Serein full. Changing the selected browser tab ends a peek.
      browser.selected = otherTab.id
      try await waitFor(5) { surface.place == .hidden }
      let peekEnded = !surface.peek && !SereinRouter.besideOn && surface.place == .hidden
      browser.selected = besideTab.id
      browser.section = pageView
      SereinRouter.show()
      try await waitFor(5) { surface.place == .beside }
      SereinRouter.hide()
      try await waitFor(5) { surface.place == .hidden }
      let hidPeek = !surface.peek && !SereinRouter.besideOn && surface.place == .hidden
      // The task panel on the right (the interim rule until tasks move into Serein), beside off:
      // asking shows Serein full and leaves the panel open, and one ⌘J from the tab takes the right
      // side back from the panel on the first press, with Serein beside.
      // A task Serein started opens in the surface where Serein is: with Serein hidden, a peek
      // beside the page, which stays; ⌘J takes the task view along to Serein full, and “‹ Serein”
      // goes back to the chat. AgentModel's current chat is never touched.
      let userThreadBefore = agent.conversationID
      SereinRouter.openTask(childID)
      try await waitFor(5) { surface.place == .beside }
      let askedFull = surface.peek && surface.view == .task(childID) && browser.section == pageView && !surface.chatShowing
        && agent.conversationID == userThreadBefore
      SereinRouter.toggleFullBeside()
      try await waitFor(5) { surface.place == .full }
      let panelGaveWay = browser.section == ShellSection.serein && surface.view == .task(childID)
        && agent.conversationID == userThreadBefore
      SereinRouter.backToChat()
      ToastCenter.shared.dismiss("serein-hidden")
      RelayOrchestrator.setSetting(besideBefore, forKey: RelayController.columnKey)
      surface.draft = draftBefore
      browser.section = viewBefore
      try check(besideFirst && wentFull && cameBack && hid && undone && peeked && peekEnded && hidPeek && askedFull && panelGaveWay,
                "Serein moves beside and back with its chat and draft [beside: \(besideFirst), full: \(wentFull), back: \(cameBack), hide: \(hid), undo: \(undone), peek: \(peeked), peek ends: \(peekEnded), hide peek: \(hidPeek), task peek: \(askedFull), task full: \(panelGaveWay), after back: \(backFacts)]")

      // Delete Chat… on a task: its card leaves Serein's chat, its chip the strip, and its view and
      // record are gone, even while its stopped run is still in the hub.
      func listed() -> Bool {
        SereinTray.items(hub: agent.hub, agent: agent, relay: relay, ledger: SereinTray.shared.ledger, now: Date())
          .contains { $0.id == childID }
      }
      let hadTask = relay.isChild(childID) && listed() && SereinTray.shared.exists(childID, agent: agent)
      agent.flow.deleteThreads([childID])
      SereinRouter.openTask(childID)
      let gone = !relay.isChild(childID) && !relay.state.children.contains { $0.threadID == childID }
        && !agent.conversations.contains { $0.id == childID } && !listed() && SereinTray.shared.record(childID) == nil
        && !SereinTray.shared.exists(childID, agent: agent) && surface.view != .task(childID)
      try check(hadTask && gone, "Deleting a task’s chat removes its card and chip [before: \(hadTask), after: \(gone)]")

      results += try await relayS9Navigation(browser: browser, agent: agent, relay: relay, folder: folder, record: record)

      // chats_search: the main assistant finds what was said in another assistant's chat, and a
      // match from a chat that took in personal data marks the chat that searched.
      let searcher = relay.addProfile("Searcher") ? relay.team.profiles.last?.id : nil
      try check(searcher != nil, "A second assistant for chats_search")
      let theirs = relay.mainThread(of: searcher ?? "")
      var trip = Conversation(id: theirs, title: "Trip", messages: [
        AgentMessage(role: "you", text: "Book the Lisbon ferry for Saturday."),
        AgentMessage(role: "assistant", text: "Booked the 9:40 ferry to Lisbon."),
      ], provider: .claude, mode: .anywhere, projectID: nil, remoteID: nil, scope: "", updatedAt: Date())
      trip.serein = true
      agent.conversations.append(trip)
      let here = relay.turnThread
      let found = try relay.searchChats("lisbon ferry saturday", limit: nil, frame: relay.clickFrame)
      let rows = found["messages"] as? [[String: Any]] ?? []
      try check(rows.count == 2 && rows.first?["assistant"] as? String == "Searcher" && rows.first?["from"] as? String == "person"
                && (rows.first?["text_untrusted"] as? String)?.contains("Lisbon ferry") == true && !agent.readsPersonal(thread: here),
                "chats_search finds what was said in another assistant's chat, best match first [\(rows)]")
      let ownMatch = try relay.searchChats("Relay finished delegated", limit: nil, frame: relay.clickFrame)["total"] as? Int
      try check(ownMatch == 0, "chats_search leaves out the chat it is asked in")
      if let i = agent.conversations.firstIndex(where: { $0.id == theirs }) { agent.conversations[i].readPersonal = true }
      // A chat that cannot take the mark (here, one not saved yet) gets no personal match.
      let hadHere = agent.conversations.contains { $0.id == here }
      if hadHere { agent.conversations.removeAll { $0.id == here } }
      let unmarkable = try relay.searchChats("ferry", limit: 1, frame: relay.clickFrame)
      try check((unmarkable["messages"] as? [Any])?.isEmpty == true && unmarkable["withheld"] != nil,
                "A personal chat's match is withheld when the chat that searched cannot be marked")
      agent.conversations.append(Conversation(id: here, title: "Serein", messages: [], provider: .claude, mode: .anywhere,
                                              projectID: nil, remoteID: nil, scope: "", updatedAt: Date()))
      let marked = try relay.searchChats("ferry", limit: 1, frame: relay.clickFrame)
      try check((marked["messages"] as? [Any])?.count == 1 && agent.readsPersonal(thread: here),
                "A match from a chat that read personal data marks the chat that searched")
      agent.conversations.removeAll { $0.id == here }
      agent.conversations.removeAll { $0.id == theirs }
      if let searcher { _ = relay.removeProfile(searcher) }
      relay.autopilotOverride = nil
    }
    try await pageChipAndSurfaces()

    return results
  }

  /// Real accepted dispatches through the fake CLI, before the first human send in this check.
  /// No diagnostic event is injected: the evidence comes from each runtime entry point.
  /// Messages sent in a row show as the messages the person wrote, and go as one turn; tags in the
  /// answer become which message each bubble answers.
  @MainActor private static func relayBurst(relay: RelayOrchestrator) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    let network = relay.networkOnline
    let quiet = RelayOrchestrator.quietForChecks
    relay.networkOnline = { true }
    RelayOrchestrator.quietForChecks = true
    defer {
      relay.networkOnline = network
      RelayOrchestrator.quietForChecks = quiet
      if relay.working { relay.stopReply() }
    }
    // Files keep the burst in the queue; plain messages would each take a side seat.
    relay.ask("Burst one", interrupt: false)
    relay.ask("Burst two", attachments: [SereinAttachment(title: "Burst note 2", body: "BURST NOTE 2")], interrupt: false)
    relay.ask("Burst three", attachments: [SereinAttachment(title: "Burst note 3", body: "BURST NOTE 3")], interrupt: false)
    try check(relay.pending == ["Burst two", "Burst three"], "Messages sent during a reply wait together, in order")
    let deadline = Date().addingTimeInterval(20)
    while (relay.working || !relay.pending.isEmpty) && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    try check(!relay.working && relay.pending.isEmpty, "The burst's turn ended")
    let people: [String] = relay.transcript.filter { $0.role == "you" }.map(\.text)
    try check(Array(people.suffix(3)) == ["Burst one", "Burst two", "Burst three"], "Each message of a burst is its own bubble")
    try check(!people.contains { $0.contains("sent these messages") || $0.contains("[reply") }, "The prompt never shows as the person's words")

    let numbered = relay.transcript.filter { $0.role == "you" }.suffix(2).map(\.burstIndex)
    try check(numbered == [1, 2], "A burst's messages keep the numbers the model read")
    var messages = [
      AgentMessage(id: "one", role: "you", text: "One", burstIndex: 1), AgentMessage(id: "two", role: "you", text: "Two", burstIndex: 2),
      AgentMessage(role: "assistant", text: "[reply 2] For two\n\n[reply 1] For one\n\n[reply 9] Past the end"),
    ]
    RelayOrchestrator.land(nil, plan: nil, in: &messages)
    try check(messages[2].text == "Past the end\n\nFor one\n\nFor two", "Tagged replies land in send order with the newest answer last")
    try check(messages[2].replies == ["1": "one", "2": "two"], "A saved reply keeps which message each bubble answers")
    var lone = [AgentMessage(id: "one", role: "you", text: "One"), AgentMessage(role: "assistant", text: "[reply 1] Hi")]
    RelayOrchestrator.land(nil, plan: nil, in: &lone)
    try check(lone[1].text == "Hi" && lone[1].replies == nil, "After one message the answer needs no quote")
    // An interrupted message left unanswered above the burst: [1] is still the burst's first.
    var interrupted = [
      AgentMessage(id: "before", role: "you", text: "Before"),
      AgentMessage(id: "b", role: "you", text: "B", burstIndex: 1), AgentMessage(id: "c", role: "you", text: "C", burstIndex: 2),
      AgentMessage(role: "assistant", text: "[reply 1] For B"),
    ]
    RelayOrchestrator.land(nil, plan: nil, in: &interrupted)
    try check(interrupted[3].replies == ["0": "b"], "A tag names the burst's message, not one above it")
    try check(AgentMessage.burst(before: 1, in: interrupted).isEmpty, "A message sent alone has no burst")
    try check(RelaySteering.prompt(["x", "y"]).contains("[2] y"), "The numbers match the messages shown")
    return results
  }

  @MainActor private static func relayS10Origins(
    browser: BrowserModel, relay: RelayOrchestrator, record: (String) -> [String: Any]?
  ) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func idle() async throws {
      let deadline = Date().addingTimeInterval(15)
      while relay.working && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
      guard !relay.working else { throw SereinError.invalid("FAIL: S10 origin fixture did not finish") }
    }
    let guide = GuideCenter.shared
    let hints = HintCenter.shared
    let network = relay.networkOnline
    let learns = relay.learnsOverride
    let reminders = relay.reminders
    let quiet = RelayOrchestrator.quietForChecks
    relay.networkOnline = { true }
    relay.learnsOverride = false
    RelayOrchestrator.quietForChecks = true
    defer {
      relay.networkOnline = network
      relay.learnsOverride = learns
      relay.updateReminders { $0 = reminders }
      RelayOrchestrator.quietForChecks = quiet
      for item in relay.held where item.message.text.contains("S10 origin") { relay.discardHeld(item.id) }
      if relay.working { relay.stopReply() }
    }
    // The fresh nonpersistent center must not inherit personal message days.
    guard !RelayOrchestrator.persists, hints.messageEvidenceForChecks.days.isEmpty,
      hints.messageEvidenceForChecks.inWindow == 0, !guide.state.done.contains(.ask)
    else { throw SereinError.invalid("FAIL: S10 teaching fixtures inherited personal progress") }

    let access = OutsideAgents(root: browser.library.root, browser: browser)
    guard access.makeOffer(name: "S10 origin app", sites: "", actions: false, localHosts: "", days: 1, relay: true) == nil,
      let code = access.offer?.code else { throw SereinError.invalid("FAIL: S10 origin pairing offer") }
    _ = await access.respond(["op": "pair", "code": code])
    guard let token = access.grants.first(where: { $0.name == "S10 origin app" })?.token else {
      throw SereinError.invalid("FAIL: S10 origin app did not pair")
    }
    _ = await access.respond(["op": "relay_ask", "token": token, "text": "WARM PING S10 origin paired app", "wait": 10])
    try await idle()
    let pairedDelivered = (record("prompt")?["prompt"] as? String)?.contains("S10 origin paired app") == true
    // All three calls happen before dispatch can suspend: the latter two are queued. Removing
    // the human message must also remove its teaching evidence while the app's request remains.
    relay.ask("WARM PING S10 origin external seed", inWindow: false, userMessage: false)
    relay.ask("WARM PING S10 origin queued human removed", attachments: [SereinAttachment(title: "S10 note", body: "S10 NOTE 6620")],
              interrupt: false)
    relay.ask("WARM PING S10 origin queued app kept", interrupt: false, inWindow: false, userMessage: false)
    relay.removePending(at: 0)
    try await idle()
    let queuedPrompt = record("prompt")?["prompt"] as? String ?? ""
    try check(pairedDelivered && queuedPrompt.contains("S10 origin queued app kept")
      && !queuedPrompt.contains("queued human removed") && !guide.state.done.contains(.ask)
      && hints.messageEvidenceForChecks.inWindow == 0 && hints.messageEvidenceForChecks.days.isEmpty,
      "Paired apps and retained external queues do not teach that a person sent a message")

    let scheduled = RelayReminder(text: "WARM PING S10 origin scheduled", due: Date().addingTimeInterval(-1), action: true)
    relay.updateReminders { $0 = [scheduled] }
    relay.tick()
    // The run is written to the work ledger first, then it starts.
    let written = Date().addingTimeInterval(10)
    while (record("prompt")?["prompt"] as? String)?.contains("S10 origin scheduled") != true, Date() < written {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try await idle()
    try check((record("prompt")?["prompt"] as? String)?.contains("S10 origin scheduled") == true
      && !guide.state.done.contains(.ask) && hints.messageEvidenceForChecks.inWindow == 0
      && hints.messageEvidenceForChecks.days.isEmpty,
      "Accepted scheduled turns do not advance the guide or message-day teaching")

    relay.networkOnline = { false }
    relay.ask("WARM PING S10 origin held app first", inWindow: false, userMessage: false)
    relay.ask("WARM PING S10 origin held human removed")
    relay.ask("WARM PING S10 origin held app last", inWindow: false, userMessage: false)
    guard let removed = relay.held.first(where: { $0.message.text.contains("held human removed") }) else {
      throw SereinError.invalid("FAIL: S10 held human fixture missing")
    }
    relay.discardHeld(removed.id)
    relay.networkOnline = { true }
    relay.releaseHeld()
    try await idle()
    let heldPrompt = record("prompt")?["prompt"] as? String ?? ""
    try check(heldPrompt.contains("S10 origin held app last") && !heldPrompt.contains("held human removed")
      && relay.held.isEmpty && !guide.state.done.contains(.ask)
      && hints.messageEvidenceForChecks.inWindow == 0 && hints.messageEvidenceForChecks.days.isEmpty,
      "Held messages retain their own origin through discard, release and queued delivery")

    guard let controller = RelayController.shared, !controller.inWindow else {
      throw SereinError.invalid("FAIL: S10 expected the global bar send entry point")
    }
    controller.sendFromBar("WARM PING S10 origin real bar send")
    try await idle()
    let barDay = hints.messageEvidenceForChecks.days
    let barAccepted = guide.state.done.contains(.ask) && guide.state.done.contains(.anywhere)
      && barDay.count == 1 && hints.messageEvidenceForChecks.inWindow == 0
    relay.networkOnline = { false }
    relay.ask("WARM PING S10 origin held window send")
    let waitingDidNotCount = hints.messageEvidenceForChecks.inWindow == 0
    relay.networkOnline = { true }
    relay.releaseHeld()
    try await idle()
    try check(barAccepted && waitingDidNotCount && hints.messageEvidenceForChecks.inWindow == 1
      && hints.messageEvidenceForChecks.days == barDay && relay.held.isEmpty,
      "A real bar send records a message day; an in-window held send counts only on accepted release")

    results += try await conversationalWelcome(browser: browser, relay: relay, record: record)
    return results
  }

  /// S9 navigation through the real public entry points and fake CLI. File gates hold a routed
  /// request and a reply at observable points, so the checks do not depend on a timing race.
  @MainActor private static func relayS9Navigation(
    browser: BrowserModel, agent: AgentModel, relay: RelayOrchestrator, folder: URL,
    record: (String) -> [String: Any]?
  ) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ label: String) throws {
      if !condition { throw SereinError.invalid("FAIL: " + label + "\n" + results.joined(separator: "\n")) }
      results.append("PASS: " + label)
    }
    func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    /// The fake CLI's whole log (`record` finds only the last of a key), for a failure's detail.
    func records() -> [[String: Any]] {
      ((try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    }
    let projectFolder = folder.appendingPathComponent("s9-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
    let project = Project(name: "S9 navigation fixture", path: projectFolder.path)
    let routeGate = folder.appendingPathComponent("s9-route-release")
    let replyGate = folder.appendingPathComponent("s9-reply-release")
    try? FileManager.default.removeItem(at: routeGate)
    try? FileManager.default.removeItem(at: replyGate)
    let originalSelection = agent.openThreadItem(agent.conversationID)
    let originalDraft = agent.draft
    let originalSection = browser.section
    let originalView = SereinSurface.main.view
    let originalSurfaceDraft = SereinSurface.main.draft
    let originalProjects = browser.projects
    let quietBefore = RelayOrchestrator.quietForChecks
    let argumentDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    let optionsBefore = ComposerContext.shared.taskOptionsThreadID
    var fixtureThreads: [String] = []
    RelayOrchestrator.quietForChecks = true
    // Feature switches live in GateSettings, which a check keeps in memory; put back after.
    let routingBefore = GateSettings.shared.object(forKey: FeaturePolicy.key(.routing))
    GateSettings.shared.set(true, forKey: FeaturePolicy.key(.routing))
    browser.projects.append(project)
    defer {
      // A failed assertion releases/stops only these fixtures, never another run.
      try? Data().write(to: routeGate)
      try? Data().write(to: replyGate)
      for id in fixtureThreads { if let run = agent.hub.run(for: id) { agent.hub.stop(run) } }
      browser.projects = originalProjects
      if let originalSelection { SereinRouter.direct { agent.openConversation(originalSelection) } }
      else { agent.clear(); agent.draft = originalDraft }
      SereinSurface.main.view = originalView
      SereinSurface.main.draft = originalSurfaceDraft
      browser.section = originalSection
      ComposerContext.shared.taskOptionsThreadID = optionsBefore
      RelayOrchestrator.quietForChecks = quietBefore
      UserDefaults.standard.setVolatileDomain(argumentDefaults, forName: UserDefaults.argumentDomain)
      GateSettings.shared.set(routingBefore, forKey: FeaturePolicy.key(.routing))
    }

    // An established direct run stays alive with its browser capability when New Task Here
    // changes the selected thread. Its unsent follow-up remains with the thread being left.
    let workingID = try await agent.dispatch("SLOW S9 direct run", into: nil,
      as: AgentModel.DispatchTarget(mode: .answer, provider: .claude))
    fixtureThreads.append(workingID)
    guard let working = agent.hub.run(for: workingID) else { throw SereinError.invalid("FAIL: S9 direct run did not start") }
    SereinRouter.open(threadID: workingID)
    agent.draft = "S9 follow-up stays with the working task"
    let workingTranscript = working.transcript
    DestinationPicker.startTask(in: project, agent: agent, browser: browser)
    let newTaskID = agent.conversationID
    fixtureThreads.append(newTaskID)
    let newTaskOpened = newTaskID != workingID && agent.mode == .project && agent.projectID == project.id
      && agent.draft.isEmpty && agent.messages.isEmpty && agent.openThreads.contains(newTaskID)
      && browser.section == ShellSection.thread && ComposerContext.shared.taskOptionsThreadID == newTaskID
    let workingPreserved = working.isActive && agent.hub.run(for: workingID) === working
      && working.transcript == workingTranscript && browser.tasks[working.taskID] != nil
      && agent.openThreadItem(workingID)?.draft == "S9 follow-up stays with the working task"
    agent.hub.stop(working)
    try await waitFor(5) { !working.isActive }
    try check(newTaskOpened && workingPreserved,
      "New Task Here opens an empty direct task and preserves the established run, capability and old draft")

    // A real no-tool routing request reaches the helper and waits there. Both New Task entry
    // points reject the switch; releasing the helper proves the original request still sends.
    agent.provider = .claude
    agent.mode = .auto
    agent.draft = "S9 ROUTE GUARD original request"
    let routedThread = agent.conversationID
    let tabsBeforeRouting = agent.openThreads
    agent.send()
    try await waitFor(10) { record("s9_route_received") != nil }
    let acceptedRoute = record("s9_route_received") != nil && agent.choosingDestination
    DestinationPicker.show(browser: browser, agent: agent, newTask: true)
    DestinationPicker.close()
    DestinationPicker.startTask(in: project, agent: agent, browser: browser)
    let routingKept = agent.choosingDestination && agent.conversationID == routedThread
      && agent.mode == .auto && agent.draft == "S9 ROUTE GUARD original request" && agent.openThreads == tabsBeforeRouting
    let beforeGate = records().count
    let gateOpened = Date()
    try Data().write(to: routeGate)
    try await waitFor(15) {
      agent.hub.latest(for: routedThread)?.record.outcome == .done && !agent.choosingDestination
    }
    let afterGate = records().dropFirst(beforeGate).map { $0.keys.sorted().joined(separator: "+") }.joined(separator: ",")
    let routedMessages = agent.hub.latest(for: routedThread)?.transcript ?? []
    let originalSent = routedMessages.contains { $0.role == "you" && $0.text == "S9 ROUTE GUARD original request" }
      && routedMessages.last?.text == "child says hi"
    try check(acceptedRoute && routingKept && originalSent,
      "New Task rejects an accepted routing request without cancelling it; the original request still completes"
        + (acceptedRoute && routingKept && originalSent ? "" : " (accepted \(acceptedRoute), kept \(routingKept), "
          + "sent \(originalSent), outcome \(agent.hub.latest(for: routedThread).map { "\($0.record.outcome)" } ?? "none"), "
          + "phase \(agent.hub.latest(for: routedThread)?.phase ?? "none"), choosing \(agent.choosingDestination), "
          + "waited \(Int(Date().timeIntervalSince(gateOpened)))s, after gate [\(afterGate)], "
          + "fake CLI \(agent.hub.latest(for: routedThread)?.spec.executable == folder.appendingPathComponent("claude").path), "
          + "exec \(agent.hub.latest(for: routedThread)?.spec.executable ?? "none"), pinned \(agent.available[.claude] ?? "none"), "
          + "runs \(agent.hub.runs.filter { $0.spec.threadID == routedThread }.map { "\($0.record.outcome)/\($0.phase)/\($0.transcript.count)" }), "
          + "log pids \(records().dropFirst(beforeGate).compactMap { ($0["cli_boot"] ?? $0["cli_start"] ?? $0["s9_route_child_done"]).map { "\($0)" } }), "
          + "last \(routedMessages.last.map { "\($0.role): \($0.text.prefix(80))" } ?? "none"))"))

    // Make a real saved Serein chat, then hold a reply in a new one. History opens the old chat
    // read-only; neither the live thread identity nor either transcript is moved or rewritten.
    relay.ask("WARM PING S9 saved chat")
    try await waitFor(10) { !relay.working }
    let pastID = relay.threadID
    let pastMessages = relay.transcript
    relay.newChat()
    let liveID = relay.threadID
    fixtureThreads.append(liveID)
    relay.ask("S9 LIVE REPLY")
    try await waitFor(10) { record("s9_reply_received") != nil }
    guard let live = relay.run else { throw SereinError.invalid("FAIL: S9 live reply did not start") }
    let liveMessages = relay.transcript
    let selectedDuringReply = agent.conversationID
    SereinSurface.main.draft = "S9 draft stays in the current chat"
    SereinRouter.open(threadID: pastID)
    let readParts = [
      SereinSurface.main.view == .pastChat(pastID), relay.threadID == liveID, relay.run === live,
      relay.transcript == liveMessages, agent.openThreadItem(pastID)?.messages == pastMessages,
      agent.conversationID == selectedDuringReply, SereinSurface.main.draft == "S9 draft stays in the current chat",
    ]
    let readOnly = readParts.allSatisfy { $0 }
    let liveCounts = "\(liveMessages.count)→\(relay.transcript.count)"
    SereinRouter.backToChat()
    let returnedToLive = SereinSurface.main.view == .chat && relay.run === live && relay.threadID == liveID
    SereinRouter.open(threadID: pastID)
    try Data().write(to: replyGate)
    try await waitFor(10) { !relay.working }
    let stayParts = [
      relay.threadID == liveID, relay.transcript.last?.text == "S9 live reply finished",
      agent.openThreadItem(pastID)?.messages == pastMessages,
    ]
    let replyStayed = stayParts.allSatisfy { $0 }
    let lastAfterReply = relay.transcript.last.map { "\($0.role): \($0.text.prefix(60))" } ?? "none"
    SereinRouter.open(threadID: pastID)
    // One conversation: after the reply too, the earlier chat only opens to read.
    let resumeParts = [
      SereinSurface.main.view == .pastChat(pastID), relay.threadID == liveID,
      agent.openThreadItem(pastID)?.messages == pastMessages,
    ]
    let resumedAfter = resumeParts.allSatisfy { $0 }
    func bits(_ parts: [Bool]) -> String { parts.map { $0 ? "1" : "0" }.joined() }
    let passed = !pastMessages.isEmpty && readOnly && returnedToLive && replyStayed && resumedAfter
    try check(passed,
      "Opening a past Serein chat during a live reply is read-only; the reply stays put, and afterwards it still only opens to read"
        + (passed ? "" : " (past \(pastMessages.count), read \(bits(readParts)) live \(liveCounts), returned \(returnedToLive), "
          + "stayed \(bits(stayParts)) last \(lastAfterReply), resumed \(bits(resumeParts)) view \(SereinSurface.main.view), "
          + "working \(relay.working))"))
    for id in fixtureThreads { agent.deleteThread(id) }
    return results
  }
}

/// A Claude Code stand-in on Engines' stream-json wire (ClaudeDriver): answers the start-up request,
/// replays each user message, speaks MCP to the helper named in --mcp-config. In Relay's run (its system prompt says "You are Serein, the user's personal assistant", or "You are Relay" before the rename) it calls Relay's tools; in a
/// delegated run it lists its tools, tries one of Relay's, and answers.
private let fakeRelayClaude = #"""
#!/usr/bin/python3 -I
import json, os, subprocess, sys, time, datetime
here = os.path.dirname(os.path.abspath(sys.argv[0]))
args = sys.argv[1:]
if args == ["--version"]:
    print("2.1.325 (Claude Code)"); sys.exit(0)
if args[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty"})); sys.exit(0)
log = open(os.path.join(here, "log.jsonl"), "a")
def record(obj):
    log.write(json.dumps(obj) + "\n"); log.flush()
record({"cli_boot": os.getpid()})
def arg(name):
    return args[args.index(name) + 1] if name in args else ""
session = "fake-%d" % os.getpid()
def next_prompt():
    # One stdin line per message on a stdin that stays open; the start-up request comes first.
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        message = json.loads(line)
        if message.get("type") == "control_request":
            print(json.dumps({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"],
                "response": {"current_permission_mode": "dontAsk"}}}), flush=True)
            continue
        if message.get("type") != "user":
            continue
        print(json.dumps({"type": "system", "subtype": "init", "session_id": session, "permissionMode": "dontAsk"}), flush=True)
        # --replay-user-messages: says when a model call took the line in.
        print(json.dumps({"type": "user", "message": message["message"], "uuid": message.get("uuid"), "isReplay": True}), flush=True)
        content = message["message"]["content"]
        return "".join(b.get("text", "") for b in content if b.get("type") == "text") if isinstance(content, list) else content
def system_prompt():
    path = arg("--append-system-prompt-file")
    return open(path).read() if path else arg("--append-system-prompt")
# "You are Serein, a browser assistant" is every other run's prompt, so the persona line is matched whole.
relay = any(name in system_prompt() for name in ("You are the user's personal assistant in Serein", "You are Serein, the user's personal assistant", "You are Relay"))
def answer(text):
    print(json.dumps({"type": "assistant", "parent_tool_use_id": None, "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}), flush=True)
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "stop_reason": "end_turn", "session_id": session,
        "usage": {"input_tokens": 10, "output_tokens": 5}, "queued_turn_count": 0}), flush=True)
def wait_gate(name, timeout=15):
    deadline = time.monotonic() + timeout
    while not os.path.exists(os.path.join(here, name)) and time.monotonic() < deadline:
        time.sleep(0.05)
    if not os.path.exists(os.path.join(here, name)):
        raise RuntimeError("S9 fixture gate timed out: " + name)
servers = json.loads(arg("--mcp-config"))["mcpServers"]
if not servers:
    # A helper request (StructuredAgent), with no MCP tools. The host releases only this routing request.
    prompt = next_prompt() or ""
    if "S9 ROUTE GUARD" not in prompt:
        sys.exit(1)
    record({"s9_route_received": prompt})
    wait_gate("s9-route-release")
    answer(json.dumps({"mode": "answer", "project_id": None, "candidates": [], "confidence": 1.0,
                       "reason": "Synthetic routing fixture", "title": "S9 routed request"}))
    sys.exit(0)
server = servers["serein_browser"]
mcp = subprocess.Popen([server["command"]] + server["args"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
n = [0]
def rpc(method, params):
    n[0] += 1
    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params}) + "\n"); mcp.stdin.flush()
    return json.loads(mcp.stdout.readline())
def call(name, arguments):
    # A tool kept out of the list (ToolGroups) runs through tool_run, as a model would call it.
    if name not in names and "tool_run" in names:
        arguments, name = {"name": name, "arguments": arguments}, "tool_run"
    r = rpc("tools/call", {"name": name, "arguments": arguments})["result"]
    text = r["content"][0]["text"]
    if r.get("isError"): return {"error": text}
    return json.loads(text)
record({"cli_start": os.getpid()})
rpc("initialize", {})
names = [t["name"] for t in rpc("tools/list", {})["result"]["tools"]]
record({"cli_tools": os.getpid()})
turns = 0
while True:
    prompt = next_prompt()
    if prompt is None:
        break
    turns += 1
    if relay:
        import stat
        st = os.fstat(1)
        record({"prompt": prompt, "system_prompt": system_prompt(), "model": arg("--model"), "pid": os.getpid(), "turn": turns,
                "fd1": ("pipe" if stat.S_ISFIFO(st.st_mode) else ("char" if stat.S_ISCHR(st.st_mode) else "other")),
                "fd1_dev": st.st_dev, "fd1_ino": st.st_ino})
    if relay and "\u27e6Relay\u27e7 Morning brief" in prompt:
        if "look_set" in prompt:
            record({"brief_look": call("look_set", {"preset": "Ember", "reason": "A warm morning"})})
        record({"brief": prompt})
        answer("Good morning. Your day is clear.")
    elif relay and "\u27e6Relay\u27e7 Check-in" in prompt:
        record({"checkin_look": call("look_set", {"preset": "Mono"})})
        record({"checkin_look2": call("look_set", {"preset": "Reactor"})})
        record({"checkin": prompt})
        answer("NOTHING")
    elif relay and "\u27e6Relay\u27e7 Something in Serein needs attention" in prompt:
        record({"attention": prompt})
        answer("Your Claude Code run failed; I can retry it.")
    elif relay and "A run you delegated finished" in prompt:
        record({"report": prompt})
        answer("Your run finished.")
    elif relay and "S9 LIVE REPLY" in prompt:
        record({"s9_reply_received": prompt})
        wait_gate("s9-reply-release")
        answer("S9 live reply finished")
    elif relay and "Request from Script, an app you paired with Serein:\nsay hello" in prompt:
        # This checks the paired request/reply transport, not another tool workflow.
        answer("Hello from the paired-app check.")
    elif relay and "CHIP ALONE 5519" in prompt:
        # The attachment-only check needs a reply, not another delegation or memory write.
        answer("Attachment received.")
    elif relay and "SETUP OFFER HUMAN" in prompt:
        record({"setup_offer": call("setup_offer", {"topic": "anywhere"})})
        answer("You can choose the shortcut on the card.")
    elif relay and "SETUP OFFER AUTOMATIC" in prompt:
        record({"setup_denied": call("setup_offer", {"topic": "check_ins"})})
        answer("No setup change was made.")
    elif relay and "WARM PING" in prompt:
        # The warm-thread check: a second turn on the same process answers from the same pid.
        answer("warm pong from %d" % os.getpid())
    elif relay and ("Please delegate a check task." in prompt or "SLOW" in prompt):
        if "Please delegate a check task." in prompt:
            record({"first_delegation_ready": prompt})
            wait_gate("first-delegation-release")
        record({"relay_tools": names, "prompt_relay": True})
        if "SLOW" in prompt:
            started = call("agent_start", {"task": "SLOW child", "destination": "answer"})
            record({"slow_child": started})
            if "SLOW HOLD" in prompt:
                time.sleep(60)
            else:
                # Like Claude Code, which reads its open stdin between steps: words sent meanwhile end the wait.
                import select
                select.select([sys.stdin], [], [], 60)
            answer("slow done")
        else:
            record({"overview": call("agent_status", {})})
            started = call("agent_start", {"task": "CHILD please say hi", "destination": "answer", "agent": "claude"})
            record({"started": started})
            waited = {}
            for _ in range(4):
                waited = call("agent_wait", {"runs": [started.get("run", "")], "seconds": 10})
                if not waited.get("still_working"): break
            record({"waited": waited})
            record({"remembered": call("remember", {"text": "Prefers Codex for Swift work", "quote": "use codex for swift"})})
            record({"recalled": call("recall", {"query": "which agent for swift"})})
            at = (datetime.datetime.now().astimezone() + datetime.timedelta(hours=1)).isoformat(timespec="seconds")
            record({"reminded": call("reminder_create", {"text": "Stretch", "at": at, "repeat": "daily"})})
            record({"look_got": call("look_get", {})})
            record({"look_set": call("look_set", {"look": {"name": "Check Look", "palette": {"primary": "#2fd27a"}, "states": {"thinking": {"formation": "helix", "core": "heart"}}}, "reason": "A check"})})
            record({"look_bad": call("look_set", {"look": {"rings": {"count": 99}, "states": {"idle": {"formation": "blob"}}}})})
            record({"look_show": call("look_show", {"state": "tour", "seconds": 4})})
            record({"look_undo": call("look_undo", {})})
            record({"look_preset": call("look_set", {"preset": "Aurora", "reason": "Back to a preset"})})
            answer("Relay finished: delegated, waited, remembered and scheduled.")
    elif relay:
        raise RuntimeError("Unexpected Relay fixture prompt: " + prompt)
    elif "FAIL this run" in prompt:
        print(json.dumps({"type": "result", "subtype": "error_during_execution", "result": "Credit balance is too low", "is_error": True, "session_id": session}), flush=True)
    else:
        if "HERE BINDING" in prompt:
            record({"here_bound_tabs": call("tabs" if "tabs" in names else "list_tabs", {})})
            wait_gate("here-binding-follow-release" if "follow-up" in prompt else "here-binding-first-release", timeout=30)
        if "S9 ROUTE GUARD" in prompt:
            record({"s9_route_child": os.getpid()})
        record({"child_tools": names})
        record({"child_refused": call("agent_status", {}).get("error", "")})
        if "SLOW" in prompt:
            time.sleep(60)
        answer("child says hi")
        if "S9 ROUTE GUARD" in prompt:
            record({"s9_route_child_done": os.getpid()})
"""#
#endif
