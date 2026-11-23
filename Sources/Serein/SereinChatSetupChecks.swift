#if DEBUG
import Foundation
import SereinCore

extension SmokeTest {
  /// The native bootstrap is exercised before the UI mounts, using the Relay suite's fake
  /// executable and isolated library. Choices stay local; only the final explicit user message
  /// starts a model turn, using the selected engine, the assistant's name and the person's.
  @MainActor static func conversationalChatSetup(
    browser: BrowserModel, relay: RelayOrchestrator, record: (String) -> [String: Any]?
  ) async throws -> [String] {
    var results: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw SereinError.invalid("FAIL: " + message) }
      results.append("PASS: " + message)
    }
    // The last question: the model choice leads to it, Skip cannot leave setup from it, its answer
    // completes setup, and a saved state at it reloads as it was.
    var machine = SereinChatSetupState()
    machine.begin(in: "setup-machine")
    machine.selectPersonName("Ziwen", in: "setup-machine")
    machine.selectHarness(.claude, in: "setup-machine", needsConnection: false)
    let toAbout = machine.complete(model: "", in: "setup-machine") && machine.phase == .about
    let noSkip = !machine.skip(in: "setup-machine") && machine.phase == .about && machine.selectedHarness == .claude
    let reloaded = (try? JSONDecoder().decode(SereinChatSetupState.self, from: JSONEncoder().encode(machine))) == machine
    let foreign = !machine.answerAbout(in: "another-chat") && machine.phase == .about
    let answered = machine.answerAbout(in: "setup-machine") && machine.phase == .complete && machine.selectedModel == ""
    try check(toAbout && noSkip && reloaded && foreign && answered,
      "The model choice leads to the help question, which only its own chat answers and which completes setup")
    let long = String(repeating: "w", count: RelayMemory.maxLength + 40)
    try check(SereinChatSetup.aboutNote(long).count == RelayMemory.maxLength
      && SereinChatSetup.aboutNote("Email and planning") == "About me and the help I want: Email and planning",
      "The help answer is kept as one note within a note's length")

    // Open at login is offered only once schedules exist, in a copy macOS can open at login,
    // while it is off and not declined; the AI may offer it too, as any other card.
    let offers = SereinSetup.offersLogin(scheduled: true, opensAtLogin: false, packaged: true, declined: false)
    let quiet = [
      SereinSetup.offersLogin(scheduled: false, opensAtLogin: false, packaged: true, declined: false),
      SereinSetup.offersLogin(scheduled: true, opensAtLogin: true, packaged: true, declined: false),
      SereinSetup.offersLogin(scheduled: true, opensAtLogin: false, packaged: false, declined: false),
      SereinSetup.offersLogin(scheduled: true, opensAtLogin: false, packaged: true, declined: true),
    ].allSatisfy { !$0 }
    try check(offers && quiet && (try? SereinSetup.topic(["topic": "login"])) == .login,
      "Open at login is offered once schedules exist, never when it is on, unavailable or declined")
    // A build run from its folder cannot open at login: a new timed request offers nothing.
    let offersBefore = relay.setupOffersHere
    let timedID = "chat-setup-timed-fixture"
    relay.updateReminders { $0.append(RelayReminder(id: timedID, text: "Synthetic timed request", due: Date().addingTimeInterval(3600),
                                                    repeats: .daily, action: true)) }
    let unpackagedQuiet = LoginLaunch.packaged || relay.setupOffersHere == offersBefore
    relay.updateReminders { $0.removeAll { $0.id == timedID } }
    try check(unpackagedQuiet, "A copy that cannot open at login never offers it when a schedule is added")

    let setup = SereinChatSetup.shared
    let agent = relay.agent
    let registry = HarnessRegistry.shared
    let savedState = relay.state
    let savedChats = agent.conversations
    let savedMessages = agent.messages
    let selected = agent.conversationID
    let draft = agent.draft
    let savedAvailable = agent.available
    let savedAuth = agent.auth
    let savedSettings = registry.settings
    let savedSnapshots = registry.snapshots
    let savedProbes = registry.probesEnabled
    let savedOnChange = registry.onChange
    guard let main = relay.team.mainProfileID else {
      throw SereinError.invalid("FAIL: Chat setup needs a main assistant profile")
    }
    let savedRoute = relay.team.profiles.first { $0.id == main }?.route
    let savedName = relay.profileName(main)
    let savedPersona = relay.persona
    let originalHeld = Set(relay.held.map(\.id))
    let surfaceDraft = SereinSurface.main.draft
    let lastPrompt = record("prompt")?["prompt"] as? String
    guard let fake = agent.available[.claude], !relay.working,
      relay.team.activeID == main, relay.activeTeam == nil else {
      throw SereinError.invalid("FAIL: Chat setup needs the idle fake-Claude main chat")
    }
    setup.beginForChecks(relay)
    registry.onChange = nil
    SereinSurface.main.draft = ""
    // Keep the only runnable executable on the test's fake CLI even if another fixture left
    // a detected harness behind. No dispatch should occur before the explicit model choice.
    agent.available = [.claude: fake]
    defer {
      if relay.working { relay.stopReply() }
      for held in relay.held where !originalHeld.contains(held.id) { relay.discardHeld(held.id) }
      if SereinConnect.shared.inline { SereinConnect.shared.dismiss() }
      setup.endChecks(relay)
      _ = relay.setProfileRoute(main, savedRoute)
      _ = relay.renameProfile(main, to: savedName)
      relay.updatePersona(savedPersona)
      registry.installPreview(savedSnapshots, settings: savedSettings)
      registry.probesEnabled = savedProbes
      registry.onChange = savedOnChange
      agent.available = savedAvailable
      agent.auth = savedAuth
      relay.restoreWelcomeCheckState(savedState)
      agent.conversations = savedChats
      agent.messages = savedMessages
      SereinSurface.main.draft = surfaceDraft
      try? browser.library.save(savedChats, to: "sessions/threads.json")
    }
    func clearNewHolds() {
      for held in relay.held where !originalHeld.contains(held.id) { relay.discardHeld(held.id) }
    }
    func notDispatched() -> Bool {
      !relay.working && relay.run == nil && (record("prompt")?["prompt"] as? String) == lastPrompt
    }

    relay.newChat()
    let early = "Summarize this page"
    // Do not call beginIfNeeded: an early composer send must establish the chooser itself.
    relay.ask(early)
    relay.releaseHeld()
    try await Task.sleep(for: .milliseconds(120))
    try check(setup.isActive(in: relay) && setup.state.phase == .name
      && relay.held.contains { $0.message.text == early && $0.message.reason == .noAI }
      && notDispatched(),
      "A request before setup mounts is held without calling an automatically detected AI app")
    clearNewHolds()

    relay.newChat()
    let page = SereinPage(tabID: "chat-setup-fixture-page", title: "Synthetic setup source",
      url: "https://setup.preview.invalid/source")
    let attachment = SereinAttachment(title: "Synthetic setup attachment", body: "ATTACHED_SETUP_FIXTURE", page: page)
    relay.ask("", attachments: [attachment])
    relay.releaseHeld()
    try await Task.sleep(for: .milliseconds(120))
    let heldAttachment = relay.held.first { $0.attachments.contains(attachment) }
    try check(heldAttachment?.message.text == SereinAttachment.noWords
      && heldAttachment?.attachments == [attachment] && heldAttachment?.page == page
      && heldAttachment?.inWindow == true && heldAttachment?.userMessage == true
      && setup.isActive(in: relay) && notDispatched(),
      "An attached first request keeps its attachment and page binding while AI selection waits")
    clearNewHolds()

    setup.skip(relay)
    try check(setup.state.phase == .skipped && setup.blocksWelcome(relay),
      "Set up later does not authorize a greeting from the detected default AI app")
    let afterSkip = "Help me with my next task"
    relay.ask(afterSkip)
    relay.releaseHeld()
    try await Task.sleep(for: .milliseconds(120))
    try check(setup.isActive(in: relay) && setup.state.phase == .name
      && relay.held.contains { $0.message.text == afterSkip } && notDispatched(),
      "A message after Set up later reopens AI selection and remains unsent")
    clearNewHolds()

    var fixtureSettings = savedSettings
    for index in fixtureSettings.instances.indices where [.claude, .codex].contains(fixtureSettings.instances[index].driver) {
      fixtureSettings.instances[index].enabled = true
      fixtureSettings.instances[index].userChose = true
    }
    var snapshots = savedSnapshots
    for driver: HarnessDriver in [.claude, .codex] {
      var snapshot = HarnessSnapshot(instance: fixtureSettings.instance(driver))
      snapshot.installed = true
      snapshot.path = fake
      snapshot.version = driver.minimumCLIVersion ?? "999.0.0"
      snapshot.signedIn = false
      snapshot.checkedAt = Date()
      snapshots[driver] = snapshot
    }
    registry.installPreview(snapshots, settings: fixtureSettings)
    agent.available[.codex] = fake
    try check(!setup.harnessReady(.claude, relay: relay) && !setup.harnessReady(.codex, relay: relay),
      "Installed but signed-out Claude Code and Codex cannot skip the connection question")

    relay.newChat()
    setup.restart(relay)
    guard let nameQuestion = setup.question else {
      throw SereinError.invalid("FAIL: Missing name question")
    }
    setup.beginIfNeeded(relay)
    setup.beginIfNeeded(relay)
    let firstStored = browser.library.load([Conversation].self, from: "sessions/threads.json")?
      .first { $0.id == relay.threadID }
    try check(setup.state.phase == .name && relay.transcript.count == 1
      && relay.transcript.first?.role == "assistant" && relay.transcript.first?.text == nameQuestion
      && firstStored?.messages == relay.transcript && notDispatched(),
      "Setup opens with one saved assistant greeting before any answer, without a provider call")

    let namesAndRequests: [(String, SetupNameAnswer)] = [
      ("Sam", .name("Sam")), ("  Mary Jane  ", .name("Mary Jane")), ("my name is Sam", .name("Sam")),
      ("Hi, I'm Sam", .name("Sam")), ("Will Smith", .name("Will Smith")), ("Can", .name("Can")), ("我叫子文", .name("子文")),
      ("hey what model are you using?", .request), ("what model are you using", .request), ("help me plan my day", .request),
      ("Will you help me", .request), ("你用的什么模型？", .request), ("hello", .request), ("the weather today", .request),
    ]
    let misread = namesAndRequests.filter { SetupNameAnswer($0.0) != $0.1 }.map(\.0)
    try check(misread.isEmpty, "Names read as names, and questions and requests never become a name"
      + (misread.isEmpty ? "" : " (misread \(misread))"))

    relay.ask(String(repeating: "n", count: 41))
    try check(setup.state.phase == .name && relay.heldHere.isEmpty && relay.transcript.count == 1
      && setup.error != nil && notDispatched(),
      "A rejected name stays at its question and never becomes a request to send after setup")

    relay.ask("Ziwen")
    guard let harnessQuestion = setup.question else {
      throw SereinError.invalid("FAIL: Missing account question after the person's name")
    }
    let savedSetup = browser.library.load(SereinChatSetupState.self, from: "relay/chat-setup.json")
    try check(setup.state.phase == .harness && setup.state.personName == "Ziwen" && setup.state.assistantName == nil
      && savedSetup?.personName == "Ziwen" && relay.profileName(main) == savedName && relay.persona == savedPersona
      && harnessQuestion.hasPrefix("Nice to meet you, Ziwen.")
      && relay.transcript.map(\.role) == ["assistant", "you", "assistant"]
      && relay.transcript.map(\.text) == [nameQuestion, "Ziwen", harnessQuestion]
      && notDispatched(),
      "Typing a name saves what to call the person, keeps the assistant's own name, then asks which account to use")

    setup.chooseHarness(.claude, relay: relay)
    let stored = browser.library.load([Conversation].self, from: "sessions/threads.json")?
      .first { $0.id == relay.threadID }
    let exchange = relay.transcript
    try check(setup.state.phase == .connecting && setup.state.selectedHarness == .claude
      && exchange.contains { $0.role == "assistant" && $0.text == harnessQuestion }
      && exchange.filter { $0.role == "you" }.map(\.text) == ["Ziwen", SereinConnect.account(.claude) ?? ""]
      && stored?.messages == relay.transcript && stored?.serein == true
      && agent.conversationID == selected && agent.draft == draft && agent.messages == savedMessages
      && SereinConnect.shared.flow == nil && notDispatched(),
      "An account answer becomes saved assistant/user conversation without changing the selected task or starting a test installer")
    setup.back(relay)
    try check(setup.state.phase == .harness && setup.state.selectedHarness == nil
      && setup.state.personName == "Ziwen" && relay.transcript.last?.text == SereinChatSetup.harnessQuestion
      && relay.transcript.filter { $0.text.hasPrefix("Nice to meet you") }.count == 1,
      "Changing the account returns to its question, greeted once, without accepting a stale connection")

    setup.chooseHarness(.claude, relay: relay)
    try check(setup.state.phase == .connecting, "The chosen signed-out app waits for its own sign-in")

    // A synthetic catalog entry stands for a real account's models without a live catalog or
    // provider request; setup keeps the app's default rather than asking for one of them.
    let chosenModel = HarnessModel(id: "synthetic-opus-5-5", name: "Claude Opus 5.5")
    snapshots[.claude]?.models = [chosenModel]
    snapshots[.claude]?.signedIn = true
    registry.installPreview(snapshots, settings: fixtureSettings)
    agent.available = [.claude: fake]
    try check(setup.harnessReady(.claude, relay: relay), "A usable signed-in fixture can finish setup")
    // Fixed snapshots disable probes. Starting this already-ready connection runs no CLI,
    // installer or login; it simulates the native job completing while the chat was hidden.
    guard !registry.probesEnabled else { throw SereinError.invalid("FAIL: Connection fixture must not probe real accounts") }
    let setupThread = relay.threadID
    SereinConnect.shared.start(.claude, inline: true)
    let connectionDeadline = Date().addingTimeInterval(2)
    while SereinConnect.shared.flow?.phase != .connected && Date() < connectionDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    // A chat on screen reconciles the finished login at once (the panel's connection change);
    // a hidden one waits for the person to come back. Either way setup goes on from it.
    let waiting = SereinConnect.shared.flow?.phase == .connected && setup.state.phase == .connecting
    let reconciled = SereinConnect.shared.flow == nil && setup.state.phase != .connecting
    try check(waiting || reconciled,
      "A fixture login finishes whether or not its setup conversation is on screen"
        + (waiting || reconciled ? ""
          : " (flow \(String(describing: SereinConnect.shared.flow?.phase)), setup \(setup.state.phase))"))

    // Returning to the chat applies the app's default model: no model question, no approval and
    // no provider request. The last question, what help the person wants, waits in the same chat.
    setup.beginIfNeeded(relay)
    var deadline = Date().addingTimeInterval(10)
    while (setup.busy || setup.state.phase != .about) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let aboutQuestion = "Claude is ready. \(SereinChatSetup.aboutQuestion)"
    let asked = setup.state.phase == .about && relay.threadID == setupThread && relay.transcript.last?.text == aboutQuestion
    try check(asked && setup.state.selectedModel == "" && setup.requiresChoice(relay)
      && SereinConnect.shared.flow == nil && relay.approvals.isEmpty && relay.questionForms.isEmpty
      && !relay.transcript.contains { $0.text.contains(SereinChatSetup.modelQuestion) } && notDispatched(),
      "A completed login keeps the app's default model and asks what help is wanted in the same chat, without a model question or provider request"
        + (asked ? "" : " (setup \(setup.state.phase), model \(String(describing: setup.state.selectedModel)), error \(setup.error ?? "none"), "
          + "last \(relay.transcript.last.map { $0.role + ": " + $0.text.prefix(90) } ?? "none"), same chat \(relay.threadID == setupThread))"))

    // The answer becomes the person's note in their words; setup ends with one line in the same
    // chat and asks nothing more (reading and check-ins are on by default; the first read starts
    // only outside checks). Still no provider request.
    for topic in relay.setupOffersHere { relay.dismissSetupOffer(topic, declined: false) }
    RelayOrchestrator.setSetting(false, forKey: ScreenTrailWatch.declinedKey)
    let trailOff = !ScreenTrailWatch.enabled
    let help = "I run a small game studio and want help with email and planning"
    relay.ask(help)
    let allSet = "Got it, I’ll keep that in mind. All set, Ziwen. I’ll use Claude. What should we start with?"
    let note = SereinChatSetup.aboutNote(help)
    let done = setup.state.phase == .complete && relay.transcript.last?.text == allSet
    try check(done && !setup.requiresChoice(relay) && relay.notes.contains { $0.text == note }
      && relay.transcript.contains { $0.role == "you" && $0.text == help }
      && trailOff && relay.setupOffersHere == [.follow]
      && relay.heldHere.isEmpty && notDispatched(),
      "The help the person wants becomes their note, setup ends in the same chat with one card to answer or ignore (following along), and no provider request"
        + (done ? "" : " (setup \(setup.state.phase), error \(setup.error ?? "none"), last \(relay.transcript.last?.text.prefix(90) ?? "none"))")
        + " [trail off: \(trailOff), cards: \(relay.setupOffersHere.map(\.rawValue))]")
    relay.updateNotes { $0.removeAll { $0.text == note } }
    for topic in [SereinSetup.Topic.checkIns, .firstRead, .follow] where relay.setupOffersHere.contains(topic) {
      relay.dismissSetupOffer(topic, declined: false)
    }

    // Pinning an unchanged implicit default must succeed idempotently, without a bill-changing
    // approval or a model call. The actual selected-task route must not be affected.
    _ = relay.setProfileRoute(main, nil)
    let implicit = relay.assistantEngine(relay.team.profiles.first { $0.id == main })
    guard let current = agent.routes(implicit.provider, models: [implicit.model]).first else {
      throw SereinError.invalid("FAIL: Missing synthetic current route")
    }
    let first = await relay.switchRoute(current, for: main)
    let second = await relay.switchRoute(current, for: main)
    let explicit = AssistantRoute(provider: current.provider, model: current.model)
    try check(first && second && relay.team.profiles.first { $0.id == main }?.route == explicit
      && relay.approvals.isEmpty && agent.conversationID == selected && notDispatched(),
      "Confirming the implicit default twice pins one explicit route without an approval or model request")
    let before = relay.team.profiles.first { $0.id == main }?.route
    var stale = current
    stale.model = "stale-fixture-model"
    let changed = await relay.switchRoute(stale, for: main, isCurrent: { false })
    try check(!changed && relay.team.profiles.first { $0.id == main }?.route == before
      && relay.approvals.isEmpty && notDispatched(),
      "A stale model answer cannot change the route or open an approval")

    // Only the person's next message reaches the fake CLI. Its instructions keep the assistant's
    // own name and say what to call the person.
    let firstMessage = "WARM PING named setup is ready"
    relay.ask(firstMessage)
    deadline = Date().addingTimeInterval(10)
    while relay.working && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let dispatched = record("prompt")
    let systemPrompt = dispatched?["system_prompt"] as? String ?? ""
    try check(!relay.working && relay.transcript.last?.text.contains("warm pong") == true
      && agent.hub.latest(for: relay.threadID)?.spec.provider == .claude
      && (dispatched?["prompt"] as? String)?.contains(firstMessage) == true
      && systemPrompt.contains("Your name is \(String(reflecting: savedName))")
      && systemPrompt.contains("The person likes to be called \"Ziwen\"")
      && relay.questionForms.isEmpty,
      "The next real message uses the chosen AI app, keeps the assistant's name and says what to call the person")

    // After setup, “change model” is words for the AI app: it never erases what was chosen.
    try check(!setup.handleText("change model", relay: relay) && setup.state.phase == .complete
      && setup.state.personName == "Ziwen",
      "Typing a setup phrase once setup is done leaves setup as it is")

    // A question at “What should I call you?” isn't a name: setup moves on and the question waits.
    relay.newChat()
    setup.restart(relay)
    setup.beginIfNeeded(relay)
    let request = "hey what model are you using?"
    relay.ask(request)
    let moved = setup.state.phase == .harness && setup.state.personName == nil
      && relay.heldHere.map(\.message.text) == [request]
      && relay.transcript.filter { $0.role == "you" }.map(\.text) == [request]
      && relay.transcript.contains { $0.text == SereinChatSetup.requestHeldLine }
      && relay.transcript.last?.text == SereinChatSetup.harnessQuestion
    try check(moved, "A question at the name question is kept for later, never taken as a name"
      + (moved ? "" : " (setup \(setup.state.phase), name \(setup.state.personName ?? "none"), held \(relay.heldHere.count), last \(relay.transcript.last?.text.prefix(90) ?? "none"))"))
    setup.skip(relay)
    try check(relay.heldHere.map(\.message.text) == [request]
      && !relay.transcript.contains { $0.role == "you" && $0.text == request }
      && !relay.transcript.contains { $0.text == SereinChatSetup.requestHeldLine },
      "Leaving setup shows the waiting question once, as a held message")
    for item in relay.heldHere { relay.discardHeld(item.id) }

    // Choosing an account finishes setup and the waiting question goes by itself, shown once.
    relay.newChat()
    setup.restart(relay)
    setup.beginIfNeeded(relay)
    let waitingQuestion = "WARM PING what model are you using?"
    relay.ask(waitingQuestion)
    setup.chooseHarness(.claude, relay: relay)
    deadline = Date().addingTimeInterval(15)
    while (setup.state.phase != .complete || setup.busy || relay.sending || relay.working
      || relay.transcript.last?.text.contains("warm pong") != true) && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let sentWords = relay.transcript.filter { $0.role == "you" }.map(\.text)
    let heldAnswered = setup.state.phase == .complete && relay.heldHere.isEmpty
      && relay.transcript.last?.text.contains("warm pong") == true
      && sentWords.filter { $0 == waitingQuestion }.count == 1
      && (record("prompt")?["prompt"] as? String)?.contains(waitingQuestion) == true
      && !relay.transcript.contains { $0.text == SereinChatSetup.requestHeldLine }
      && !relay.transcript.contains { $0.text.contains("What should we start with?") }
    try check(heldAnswered, "A question held at the name question is answered once setup is done, and shows once"
      + (heldAnswered ? "" : " (setup \(setup.state.phase), held \(relay.heldHere.count), you \(sentWords), last \(relay.transcript.last?.text.prefix(90) ?? "none"))"))
    return results
  }
}
#endif
