import AppKit
import Combine
import SereinCore

/// Host-owned questions bootstrap the conversation before any AI app has been chosen: what to
/// call the person, then which account to think with, then what help they want. Only an explicit
/// answer connects an app or applies a route, and a connected app keeps its own default model
/// unless that cannot be used. The last answer is kept as the person's note, in their words.
/// Every question and answer lives in the transcript; no provider runs before the person starts
/// talking. Setup ends by offering check-ins (a morning brief, word when work needs you), which
/// only the person's click turns on.
@MainActor final class SereinChatSetup: ObservableObject {
  static let shared = SereinChatSetup()
  @Published private(set) var state = SereinChatSetupState()
  @Published private(set) var busy = false
  @Published private(set) var error: String?
  /// What to do next, after a message that didn't answer the question. Not a failure.
  @Published private(set) var guidance: String?
  private var libraryPath: String?
  private var operation = UUID()
  private var payment: (thread: String, title: String)?
  private let path = "relay/chat-setup.json"
  private var checking = false
  private var computerWatcher: AnyCancellable?
  private weak var computerOwner: RelayOrchestrator?
  private var probeWatcher: AnyCancellable?
  private var probeAnswered = false
  #if DEBUG
  private var checkRestore: (SereinChatSetupState, String?, Data?)?
  func beginForChecks(_ relay: RelayOrchestrator) {
    guard RunMode.automated, checkRestore == nil else { return }
    checkRestore = (state, libraryPath, try? Data(contentsOf: relay.browser.library.root.appendingPathComponent(path)))
    checking = true
    state = SereinChatSetupState()
    libraryPath = relay.browser.library.root.path
    busy = false
    error = nil
  }
  func endChecks(_ relay: RelayOrchestrator) {
    guard RunMode.automated, let saved = checkRestore else { return }
    checking = false
    operation = UUID()
    busy = false
    state = saved.0
    libraryPath = saved.1
    let url = relay.browser.library.root.appendingPathComponent(path)
    if let data = saved.2 { try? data.write(to: url, options: .atomic) }
    else { try? FileManager.default.removeItem(at: url) }
    checkRestore = nil
  }
  #endif
  static let nameQuestion = "Hello, I’m Serein. What should I call you?"
  static let harnessQuestion = "Which AI account should I use?"
  /// Said when the answer to “What should I call you?” was a question or a request.
  static let requestHeldLine = "I’ll answer that as soon as I’m connected."
  static let modelQuestion = "Which model would you like me to use?"
  static let aboutQuestion = "What would you like my help with? Tell me a little about your work and what’s on your plate. I’ll keep it as a note you can change any time."
  static let computerQuestion = "First, I’m preparing my own Mac. I’ll handle its setup here before we connect your AI account."
  static var preview: Bool { RunMode.previewing && CommandLine.arguments.contains("--ui-chat-setup") }

  var question: String? {
    switch state.phase {
    case .computer: return Self.computerQuestion
    case .name: return Self.nameQuestion
    case .harness:
      guard !state.accountChosenBefore, let name = state.personName else { return Self.harnessQuestion }
      return "Nice to meet you, \(name). \(Self.harnessQuestion)"
    case .connecting:
      return "Let’s connect \(state.selectedHarness?.displayName ?? "your AI app"). Finish signing in, then come back here. I’ll pick up when you’re connected."
    case .model:
      return "\(state.selectedHarness?.displayName ?? "Your AI app") is connected. \(Self.modelQuestion)"
    case .about:
      return "\(state.selectedHarness.flatMap { SereinConnect.account($0) } ?? state.selectedHarness?.displayName ?? "Your AI app") is ready. \(Self.aboutQuestion)"
    case .complete, .skipped: return nil
    }
  }
  private func presentQuestion(_ relay: RelayOrchestrator) {
    guard isActive(in: relay), let question else { return }
    // A connected app thinks with its own default model; the question is asked only when that
    // default cannot be used. The composer's model menu changes it later.
    if state.phase == .model, !Self.preview {
      // A choice already underway answers it; nothing is asked meanwhile.
      if busy { return }
      if let route = models(relay).first(where: { $0.model.isEmpty && $0.selectable }) {
        chooseModel(route, relay: relay, automatic: true)
        return
      }
    }
    _ = relay.recordSetupQuestion(question)
  }

  /// The two accounts most people already have, offered first; the rest stay one click away.
  static let accounts: [HarnessDriver] = [.claude, .codex]
  /// An account's button: the plan people know (“Continue with ChatGPT”), not the app's name.
  func accountTitle(_ driver: HarnessDriver) -> String {
    Self.accounts.contains(driver) ? "Continue with \(SereinConnect.account(driver) ?? driver.displayName)"
      : driver.displayName
  }
  /// What Serein calls the person: setup's answer in this library, when they gave one.
  func personName(_ relay: RelayOrchestrator) -> String? {
    load(relay)
    return state.personName
  }

  var harnesses: [HarnessDriver] {
    HarnessDriver.allCases.sorted { left, right in
      let a = HarnessRegistry.shared.snapshots[left]?.installed == true
      let b = HarnessRegistry.shared.snapshots[right]?.installed == true
      if a != b { return a }
      return (HarnessDriver.allCases.firstIndex(of: left) ?? 0) < (HarnessDriver.allCases.firstIndex(of: right) ?? 0)
    }
  }
  /// Only what the row's title can't say: why choosing this app won't simply work. Not installed
  /// or not signed in needs no words, because choosing the row connects it.
  func harnessDetail(_ driver: HarnessDriver) -> String? {
    let snapshot = HarnessRegistry.shared.snapshots[driver]
    guard snapshot?.installed == true, snapshot?.signedIn != false else { return nil }
    if snapshot?.tooOld == true { return "Update needed." }
    if !HarnessRegistry.shared.instance(driver).enabled { return "Currently off." }
    return RelayOrchestrator.assistantRouteRefusal(Provider(driver))
  }
  func harnessReady(_ driver: HarnessDriver, relay: RelayOrchestrator) -> Bool {
    let snapshot = HarnessRegistry.shared.snapshots[driver]
    return snapshot?.checkedAt != nil && snapshot?.installed == true && snapshot?.signedIn != false
      && snapshot?.tooOld != true && HarnessRegistry.shared.instance(driver).enabled
      && relay.agent.canThink(Provider(driver)) && RelayOrchestrator.assistantRouteRefusal(Provider(driver)) == nil
  }
  func models(_ relay: RelayOrchestrator) -> [ModelRoute] {
    guard let driver = state.selectedHarness else { return [] }
    let provider = Provider(driver)
    if Self.preview {
      return ["", "preview-balanced", "preview-capable"].map {
        ModelRoute(provider: provider.rawValue, model: $0, costClass: .yourPlan, caps: [.tools], installed: true, reason: nil)
      }
    }
    let ids = HarnessRegistry.shared.models(provider).map(\.id)
    var seen = Set<String>()
    let unique = ([""] + ids).filter { seen.insert($0).inserted }
    return relay.agent.routes(provider, models: unique).map { route in
      var route = route
      if let refusal = RelayOrchestrator.assistantRouteRefusal(provider) { route.reason = refusal }
      return route
    }
  }
  func isActive(in relay: RelayOrchestrator) -> Bool {
    state.threadID == relay.threadID && relay.team.activeID == relay.team.mainProfileID
      && relay.activeTeam == nil && [.computer, .name, .harness, .connecting, .model, .about].contains(state.phase)
      && (!RunMode.automated || Self.preview || checking)
  }
  func blocksWelcome(_ relay: RelayOrchestrator) -> Bool {
    load(relay)
    // Skipping means browse for now; it is not permission to call a detected default provider.
    return state.phase != .complete
  }
  func needsInitialSetup(_ relay: RelayOrchestrator) -> Bool {
    load(relay)
    // The provider is already selected at .about. Resume its last question in chat.
    return state.phase != .complete && state.phase != .skipped && state.phase != .about
  }
  /// Check-ins and briefs wait for setup (`SereinChatSetupState.holdsCheckIns`). Checks that don't
  /// run setup keep theirs.
  func holdsCheckIns(_ relay: RelayOrchestrator) -> Bool {
    guard !RunMode.automated || checking else { return false }
    load(relay)
    return state.holdsCheckIns(firstRunFinished: !SetupProgress.needsFirstRun())
  }
  func beginIfNeeded(_ relay: RelayOrchestrator) {
    guard !RunMode.stress, (!RunMode.automated || Self.preview || checking),
      relay.team.activeID == relay.team.mainProfileID, relay.activeTeam == nil,
      !relay.working, !relay.sending, !relay.state.paused,
      relay.approvals.isEmpty, relay.questionForms.isEmpty,
      SereinSurface.main.draft.isEmpty, SereinSurface.main.attachments.isEmpty else { return }
    load(relay)
    guard state.phase != .complete, state.phase != .skipped else { return }
    relay.cancelWelcome()
    // Looks round this Mac while the person answers, for the closing line (LocalScan).
    LocalScan.start()
    var next = state
    if let owner = next.threadID, owner != relay.threadID {
      invalidate(relay)
      if SereinConnect.shared.inline { SereinConnect.shared.dismiss() }
      next.restart(in: relay.threadID, needsComputer: needsComputer)
    } else { next.begin(in: relay.threadID, needsComputer: needsComputer) }
    if next != state { guard save(next, relay: relay) else { return } }
    if state.phase == .computer {
      presentQuestion(relay)
      computerChanged(relay)
      return
    }
    // The person's name comes from their Mac account when it holds one, so setup does not ask.
    // A check or preview keeps the question, which it tests.
    if next.phase == .name, next.personName == nil, !RunMode.automated,
      let name = SereinChatSetupState.likelyName(fullName: NSFullUserName()) {
      next.selectPersonName(name, in: relay.threadID)
    }
    if next != state { _ = save(next, relay: relay) }
    if awaitsProbe(relay) { return }
    if quickStart(relay) { return }
    if Self.preview, state.phase == .connecting, SereinConnect.shared.flow == nil {
      SereinConnect.shared.previewInline(state.selectedHarness ?? .claude)
    }
    // Sign-in can finish while its browser window or another tab hides this chat. Reconcile
    // the current job on return, even when this view missed the connection's change event.
    if state.phase == .connecting { connectionChanged(relay) }
    presentQuestion(relay)
  }
  func restart(_ relay: RelayOrchestrator) {
    guard !relay.working, !relay.sending, relay.team.activeID == relay.team.mainProfileID,
      relay.activeTeam == nil else {
      error = "Finish this reply, then open setup in Serein’s main chat."
      return
    }
    load(relay)
    invalidate(relay)
    if SereinConnect.shared.inline { SereinConnect.shared.dismiss() }
    relay.cancelWelcome()
    var next = state
    next.restart(in: relay.threadID, needsComputer: needsComputer)
    if save(next, relay: relay) {
      presentQuestion(relay)
      if state.phase == .computer { computerChanged(relay) }
    }
  }
  private var needsComputer: Bool { ComputerHost.shared.initialMacSetupComputer() != nil }

  /// A host state change, never a model's claim that installation finished.
  private func computerChanged(_ relay: RelayOrchestrator) {
    guard !Self.preview, isActive(in: relay), state.phase == .computer else { return }
    if let computer = ComputerHost.shared.initialMacSetupComputer() {
      if computerWatcher == nil || computerOwner !== relay {
        computerOwner = relay
        let settings = NotificationCenter.default.publisher(for: GateSettings.changed).map { _ in true }.prepend(true)
        computerWatcher = Publishers.CombineLatest3(computer.$macSetup, computer.$state, settings)
          .sink { [weak self, weak relay] _ in
            Task { @MainActor in if let relay { self?.computerChanged(relay) } }
          }
      }
      return
    }
    computerWatcher?.cancel(); computerWatcher = nil; computerOwner = nil
    var next = state
    guard next.computerReady(in: relay.threadID), save(next, relay: relay) else { return }
    beginIfNeeded(relay)
  }
  func showComputerSetup(_ relay: RelayOrchestrator) {
    guard isActive(in: relay), state.phase == .computer, !RunMode.previewing,
      let computer = ComputerHost.shared.initialMacSetupComputer() else { return }
    ComputerWindow.show(computer, initialSetup: true)
    if computer.state != .running, computer.starting == nil {
      Task { await ComputerHost.shared.resumeInitialSetup(computer) }
    }
  }
  func requiresChoice(_ relay: RelayOrchestrator) -> Bool {
    guard (!RunMode.automated || checking), !RunMode.stress, relay.team.activeID == relay.team.mainProfileID,
      relay.activeTeam == nil else { return false }
    load(relay)
    // An AI app already chosen for Serein (its route) answers a setup put off or begun in another
    // chat (`adopt`); one waiting in this chat keeps its question, so a typed answer is not lost.
    if state.phase == .skipped || state.threadID != relay.threadID, let route = relay.team.main?.route {
      adopt(route, relay: relay)
    }
    return state.phase != .complete
  }
  @discardableResult func prepareForMessage(_ relay: RelayOrchestrator) -> Bool {
    guard requiresChoice(relay) else { return false }
    let wasAsked = isActive(in: relay) && relay.transcript.last?.role == "assistant"
      && relay.transcript.last?.text == question
    if state.phase == .skipped || state.threadID != relay.threadID { restart(relay) }
    else { presentQuestion(relay) }
    return wasAsked
  }
  func cancelPending(_ relay: RelayOrchestrator) {
    guard isActive(in: relay) else { return }
    invalidate(relay)
    if SereinConnect.shared.inline { SereinConnect.shared.dismiss() }
    var next = state
    if next.back(in: relay.threadID), save(next, relay: relay) { presentQuestion(relay) }
  }
  private func invalidate(_ relay: RelayOrchestrator) {
    computerWatcher?.cancel(); computerWatcher = nil; computerOwner = nil
    operation = UUID()
    busy = false
    if let payment {
      for approval in relay.approvals where approval.threadID == payment.thread && approval.title == payment.title
        && approval.effect == .pay { approval.answer(.no) }
    }
    payment = nil
  }
  /// The person's own name (nil: they would rather not say). The assistant keeps its name, which
  /// Settings › Serein can change.
  @discardableResult func choosePersonName(_ name: String?, relay: RelayOrchestrator) -> Bool {
    guard isActive(in: relay), state.phase == .name, !busy, let question else { return false }
    var next = state
    guard next.selectPersonName(name, in: relay.threadID) else {
      error = "What should I call you? Keep it to 40 characters, or type skip."
      return false
    }
    guard relay.recordSetupExchange(question: question, answer: next.personName ?? "I’d rather not say."),
      save(next, relay: relay) else { return false }
    presentQuestion(relay)
    return true
  }
  /// The answer to “What should I call you?” was a question or a request, not a name. It stays in
  /// the chat where they wrote it and setup moves on without a name; `RelayOrchestrator.ask` holds
  /// the request, which goes by itself when setup is done (`finish`).
  private func moveOnFromRequest(_ text: String, relay: RelayOrchestrator) {
    guard isActive(in: relay), state.phase == .name, !busy, let question else { return }
    var next = state
    guard next.selectPersonName(nil, in: relay.threadID),
      relay.recordSetupExchange(question: question, answer: text),
      relay.recordSetupQuestion(Self.requestHeldLine),
      save(next, relay: relay) else { return }
    presentQuestion(relay)
  }
  /// What an answer button says in the chat: the account's name (“ChatGPT”), not the app's.
  private func harnessAnswer(_ driver: HarnessDriver) -> String {
    SereinConnect.account(driver) ?? driver.displayName
  }
  func chooseHarness(_ driver: HarnessDriver, relay: RelayOrchestrator, answer: String? = nil) {
    guard isActive(in: relay), state.phase == .harness, !busy, harnesses.contains(driver),
      !RunMode.automated || Self.preview || checking, let question else { return }
    let ready = !Self.preview && harnessReady(driver, relay: relay)
    var next = state
    guard next.selectHarness(driver, in: relay.threadID, needsConnection: !ready && !Self.preview),
      relay.recordSetupExchange(question: question, answer: answer ?? harnessAnswer(driver)),
      save(next, relay: relay) else { return }
    presentQuestion(relay)
    if next.phase == .connecting && !checking {
      SereinConnect.shared.start(driver, inline: true)
    }
  }
  func connectionChanged(_ relay: RelayOrchestrator) {
    guard isActive(in: relay), state.phase == .connecting,
      let selected = state.selectedHarness else { return }
    let connect = SereinConnect.shared
    guard let flow = connect.flow else {
      var next = state
      next.connectionInterrupted(in: relay.threadID)
      if save(next, relay: relay) { presentQuestion(relay) }
      return
    }
    guard connect.inline, flow.driver == selected, flow.phase == .connected else { return }
    relay.agent.syncHarnesses()
    guard RelayOrchestrator.assistantRouteRefusal(Provider(selected)) == nil else {
      error = RelayOrchestrator.assistantRouteRefusal(Provider(selected))
      return
    }
    var next = state
    guard next.connected(selected, in: relay.threadID), save(next, relay: relay) else { return }
    connect.dismiss()
    presentQuestion(relay)
  }
  /// `automatic`: setup took the app's default itself, so no question or answer is recorded.
  func chooseModel(_ route: ModelRoute, relay: RelayOrchestrator, answer: String? = nil, automatic: Bool = false) {
    guard isActive(in: relay), state.phase == .model, !busy,
      let offered = models(relay).first(where: { $0.id == route.id }), offered == route, offered.selectable else { return }
    if Self.preview { return } // A synthetic capture never applies a real setting or starts a CLI.
    let thread = relay.threadID
    guard let profile = relay.team.mainProfileID else { return }
    let token = UUID()
    operation = token
    busy = true
    error = nil
    payment = (thread, "Switch \(relay.profileName(profile)) to \(ModelBackups.name(route)) (\(route.costClass.label))?")
    Task { [weak self, weak relay] in
      guard let self, let relay else { return }
      defer { if self.operation == token { self.busy = false; self.payment = nil } }
      let current = { [weak self, weak relay] in
        guard let self, let relay else { return false }
        return self.operation == token && self.isActive(in: relay) && relay.threadID == thread
          && relay.team.activeID == profile && self.state.phase == .model
          && self.models(relay).contains(route) && route.selectable
      }
      guard await relay.switchRoute(route, for: profile, isCurrent: current), current() else {
        if current() { self.error = "The model wasn’t changed. You can choose again when you’re ready." }
        return
      }
      let model = HarnessRegistry.shared.models(Provider(rawValue: route.provider)).first { $0.id == route.model }?.name
        ?? (route.model.isEmpty ? "the app’s default model" : route.model)
      let choice = "\(Provider(rawValue: route.provider).name) · \(model)"
      var next = self.state
      guard let question = self.question, next.complete(model: route.model, in: thread),
        automatic || relay.recordSetupExchange(question: question, answer: answer ?? choice) else { return }
      // A request already waiting for the app goes first: no more questions before it.
      if !relay.heldHere.isEmpty { next.answerAbout(in: thread) }
      guard self.save(next, relay: relay) else { return }
      if next.phase == .complete { self.finish(relay, told: false) } else { self.presentQuestion(relay) }
    }
  }
  /// What help the person wants, in their words (nil: they passed). The words become their note
  /// (Settings › Serein lists, edits and undoes notes); the state keeps none of them.
  @discardableResult func chooseAbout(_ text: String?, relay: RelayOrchestrator) -> Bool {
    guard isActive(in: relay), state.phase == .about, !busy, let question else { return false }
    let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    let told = words.map { !$0.isEmpty } ?? false
    var next = state
    guard next.answerAbout(in: relay.threadID),
      relay.recordSetupExchange(question: question, answer: told ? words! : "I’ll tell you as we go.") else { return false }
    var noteFailure: String?
    if told, let words {
      do { try relay.updateNotes { _ = try RelayMemory.remember(Self.aboutNote(words), quote: nil, in: &$0) } }
      catch { noteFailure = "I couldn’t keep that as a note: \(error.localizedDescription)" }
    }
    guard save(next, relay: relay) else { return false }
    // “I’ll keep that in mind” only when it was kept; `save` clears errors, so this one comes after.
    finish(relay, told: told && noteFailure == nil)
    if let noteFailure { error = noteFailure }
    return true
  }
  /// The note setup keeps: the person's words under one plain heading, within a note's length.
  static func aboutNote(_ words: String) -> String {
    let lead = "About me and the help I want: "
    return lead + String(words.prefix(RelayMemory.maxLength - lead.count))
  }
  /// Setup is complete: one closing line, then any request held for the app, while Serein reads the
  /// person's AI chats in the background to get to know them (`GetToKnow`), unless they turned that
  /// off.
  private func finish(_ relay: RelayOrchestrator, told: Bool) {
    let who = state.personName.map { ", \($0)" } ?? ""
    let driver = state.selectedHarness
    let account = driver.flatMap { SereinConnect.account($0) } ?? driver?.displayName ?? "your AI app"
    let model = state.selectedModel ?? ""
    let name = driver.flatMap { d in HarnessRegistry.shared.models(Provider(d)).first { $0.id == model }?.name } ?? model
    let using = model.isEmpty ? "" : ", using \(name)"
    let lead = told ? "Got it, I’ll keep that in mind. " : ""
    let waiting = !relay.heldHere.isEmpty
    // The conversation goes on here: the person's next message is the first real request. One
    // already waiting is answered next, so there is nothing to ask.
    let ask = waiting ? "" : " What should we start with?"
    relay.dropSetupRequestCopies()
    let found = LocalScan.finds?.sentence.map { " " + $0 } ?? ""
    _ = relay.recordSetupQuestion("\(lead)All set\(who). I’ll use \(account)\(using).\(found)\(ask)")
    relay.releaseHeld()
    // Serein gets to know the person in the background now, with nothing in the chat (GetToKnow).
    GetToKnow.runIfDue(relay, now: true)
    relay.offerFollowIfUseful()
  }
  /// An AI app and model the person picked for Serein in a model picker: as explicit as an
  /// answer here, so a setup put off or never finished ends with that choice and the messages
  /// that waited for an AI app go. At the last question (`.about`) only the chosen app and model
  /// follow the pick: the question stays, and the answer being typed goes to `chooseAbout`.
  func adopt(_ route: AssistantRoute, relay: RelayOrchestrator) {
    load(relay)
    guard state.phase != .complete, state.phase != .computer, !busy,
      let driver = HarnessDriver.allCases.first(where: { Provider($0).rawValue == route.provider }),
      harnessReady(driver, relay: relay) else { return }
    let about: Bool = state.phase == .about
    let thread: String = about ? (state.threadID ?? relay.threadID) : relay.threadID
    var next = SereinChatSetupState()
    guard next.restart(in: thread), next.selectPersonName(state.personName, in: thread),
      next.selectHarness(driver, in: thread, needsConnection: false),
      next.complete(model: route.model, in: thread), about || next.answerAbout(in: thread) else { return }
    if about {
      save(next, relay: relay)
      return
    }
    invalidate(relay)
    if SereinConnect.shared.inline { SereinConnect.shared.dismiss() }
    guard save(next, relay: relay) else { return }
    finish(relay, told: false)
  }
  /// At launch nothing knows yet whether the app Serein thinks with is signed in. The account
  /// question waits for that answer (10 seconds at most), so a signed-in app is never asked about.
  private func awaitsProbe(_ relay: RelayOrchestrator) -> Bool {
    guard !Self.preview, !checking, !probeAnswered, [.name, .harness].contains(state.phase),
      let driver = relay.assistantEngine(relay.team.main).provider.driver,
      HarnessRegistry.shared.snapshots[driver]?.checkedAt == nil else { return false }
    guard probeWatcher == nil else { return true }
    HarnessRegistry.shared.probeDeferred([driver])
    probeWatcher = HarnessRegistry.shared.$snapshots.filter { $0[driver]?.checkedAt != nil }.first()
      .timeout(.seconds(10), scheduler: DispatchQueue.main)
      .sink(receiveCompletion: { [weak self, weak relay] _ in
        Task { @MainActor in
          self?.probeAnswered = true
          self?.probeWatcher = nil
          if let relay { self?.beginIfNeeded(relay) }
        }
      }, receiveValue: { _ in })
    return true
  }
  /// The app Serein thinks with is already signed in: nothing to ask, so setup ends here and the
  /// chat opens on that app's own greeting (SereinWelcome).
  private func quickStart(_ relay: RelayOrchestrator) -> Bool {
    guard !Self.preview, !checking, [.name, .harness].contains(state.phase), !busy,
      let driver = relay.assistantEngine(relay.team.main).provider.driver, harnessReady(driver, relay: relay) else { return false }
    let thread = relay.threadID
    var next = SereinChatSetupState()
    guard next.restart(in: thread), next.selectPersonName(state.personName, in: thread),
      next.selectHarness(driver, in: thread, needsConnection: false),
      next.complete(model: "", in: thread), next.answerAbout(in: thread), save(next, relay: relay) else { return false }
    relay.releaseHeld()
    GetToKnow.runIfDue(relay, now: true)
    return true
  }
  /// Browsing before choosing a provider must never start a welcome or a scheduled check-in.
  func deferFirstRun(_ relay: RelayOrchestrator) -> Bool {
    load(relay)
    guard !busy, relay.approvals.isEmpty, !SereinConnect.shared.inline else { return false }
    var next = state
    let thread = next.threadID ?? relay.threadID
    guard next.begin(in: thread), next.skip(in: thread) else { return false }
    return save(next, relay: relay)
  }

  func skip(_ relay: RelayOrchestrator) {
    guard isActive(in: relay), !busy else { return }
    operation = UUID()
    if SereinConnect.shared.inline { SereinConnect.shared.dismiss() }
    var next = state
    guard next.skip(in: relay.threadID),
      relay.recordSetupExchange(question: question ?? Self.nameQuestion, answer: "I’ll set up later."),
      save(next, relay: relay) else { return }
    relay.dropSetupRequestCopies()
    _ = relay.recordSetupQuestion("Of course. What you write here waits until an AI account is connected, and we can finish whenever you’re ready.")
  }
  func back(_ relay: RelayOrchestrator) {
    guard isActive(in: relay), !busy else { return }
    operation = UUID()
    if SereinConnect.shared.inline { SereinConnect.shared.dismiss() }
    var next = state
    guard next.back(in: relay.threadID) else { return }
    if save(next, relay: relay) { presentQuestion(relay) }
  }
  /// Typed choices are matched against the options shown, never sent to an unchosen provider.
  func handleText(_ text: String, relay: RelayOrchestrator, answeringQuestion: Bool = true) -> Bool {
    guard (!RunMode.automated || checking), !relay.working, relay.team.activeID == relay.team.mainProfileID,
      relay.activeTeam == nil else { return false }
    load(relay)
    let answer = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Only while setup is unfinished: once it's done these are ordinary words to the AI app, and
    // restarting would erase the choices already made. Settings › AI apps changes them.
    if state.phase != .complete,
      ["set up serein", "help me set up serein", "choose an ai app", "change ai app", "change harness", "choose a model", "change model"].contains(answer) {
      restart(relay)
      return true
    }
    guard isActive(in: relay) else { return false }
    // At the name question “skip” passes over the name only; “not now” leaves setup for later.
    if state.phase == .name, answeringQuestion, ["skip", "pass"].contains(answer) {
      _ = choosePersonName(nil, relay: relay)
      return true
    }
    // The last question: anything typed answers it (“skip”, “not now” pass over it). A message
    // sent before it showed is a request, held until setup is done.
    if state.phase == .about {
      guard answeringQuestion else { return false }
      _ = chooseAbout(["skip", "pass", "not now", "later", "no"].contains(answer) ? nil : text, relay: relay)
      return true
    }
    if ["skip", "later", "not now", "set up later"].contains(answer) { skip(relay); return true }
    if ["back", "choose another", "change ai app"].contains(answer) { back(relay); return true }
    guard !busy else { error = "Finish the model confirmation below first."; return true }
    switch state.phase {
    case .computer:
      guidance = "My Mac is still being prepared in setup. Any agreement choice belongs in that window."
      return false
    case .name:
      // A short request sent before the greeting appeared is still a request, not a name.
      guard answeringQuestion else { return false }
      switch SetupNameAnswer(text) {
      case .name(let name):
        _ = choosePersonName(name, relay: relay)
        // A rejected answer stays at this question, never queued as a task to send after setup.
        return true
      case .request:
        moveOnFromRequest(text, relay: relay)
        return false
      }
    case .harness:
      let name = answer.hasPrefix("use ") ? String(answer.dropFirst(4)) : answer
      // The account's own name works too: “ChatGPT” is Codex, “Claude” is Claude Code.
      if let driver = harnesses.first(where: {
        [ $0.rawValue.lowercased(), $0.displayName.lowercased(), Provider($0).shortName.lowercased(),
          SereinConnect.account($0)?.lowercased() ].contains(name)
      }) { chooseHarness(driver, relay: relay, answer: text) }
      else { guidance = "I’ll keep your message here until an AI account is connected."; return false }
    case .model:
      let candidates = models(relay)
      let catalog = state.selectedHarness.map { HarnessRegistry.shared.models(Provider($0)) } ?? []
      // Match only names offered by this account. A short name such as “Opus 5.5” may
      // omit the harness brand, but it must still identify exactly one catalog entry.
      func modelKey(_ value: String) -> String {
        var words = value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "use" { words.removeFirst() }
        if state.selectedHarness == .claude && words.first == "claude" { words.removeFirst() }
        return words.joined(separator: " ")
      }
      let named = candidates.filter { route in
        route.model.isEmpty ? ["default", "app default", "use default"].contains(answer)
          : modelKey(route.model) == modelKey(answer)
            || catalog.first(where: { $0.id == route.model }).map { modelKey($0.name) == modelKey(answer) } == true
      }
      if named.count == 1, let route = named.first { chooseModel(route, relay: relay, answer: text) }
      else { guidance = "Choose a model below, or say ‘default’ to use the app’s default model."; return false }
    case .connecting: guidance = "Finish connecting the app below, or choose a different AI app."; return false
    case .about, .complete, .skipped: return false
    }
    return true
  }
  private func load(_ relay: RelayOrchestrator) {
    let root = relay.browser.library.root.path
    guard libraryPath != root else { return }
    libraryPath = root
    state = SereinChatSetupState()
    if !RunMode.previewing {
      if let saved = relay.browser.library.load(SereinChatSetupState.self, from: path) { state = saved }
      // A setup at the account question goes on from there, with or without the person's name
      // (Skip leaves none). A relaunch never replays installation or sign-in. It offers the
      // question again.
      if state.phase == .connecting, let thread = state.threadID {
        state.connectionInterrupted(in: thread)
        _ = save(state, relay: relay)
      }
    } else if Self.preview {
      let args = CommandLine.arguments
      let kind = args.drop(while: { $0 != "--ui-chat-setup" }).dropFirst().first
      state.begin(in: relay.threadID, needsComputer: kind == "computer")
      if kind != "name" && kind != "computer" {
        _ = relay.recordSetupExchange(question: Self.nameQuestion, answer: "Ziwen")
        state.selectPersonName("Ziwen", in: relay.threadID)
      }
      if kind == "model" || kind == "connecting" || kind == "about" {
        _ = relay.recordSetupExchange(question: question ?? Self.harnessQuestion, answer: "Continue with Claude")
        state.selectHarness(.claude, in: relay.threadID, needsConnection: kind == "connecting")
      }
      // `--ui-chat-setup about`: the app connected with its default model; the last question shows.
      if kind == "about" { state.complete(model: "", in: relay.threadID) }
    }
  }
  @discardableResult private func save(_ next: SereinChatSetupState, relay: RelayOrchestrator) -> Bool {
    do {
      if !RunMode.previewing {
        try FileManager.default.createDirectory(at: relay.browser.library.root.appendingPathComponent("relay"),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try relay.browser.library.save(next, to: path)
        if next.phase == .complete || next.phase == .skipped {
          // Retire only the old tour's presentation. This does not claim imports/permissions
          // were configured, and never starts SetupRun's automatic work.
          if !RunMode.automated {
            var legacy = SetupProgress.load()
            legacy.finished = true
            legacy.save()
            // The setup chat was the greeting: the first launch's welcome does not greet again.
            RelayOrchestrator.setSetting(true, forKey: WelcomeFlowView.welcomedKey)
          }
        }
      }
      state = next
      error = nil
      guidance = nil
      return true
    } catch {
      self.error = "I couldn’t save that setup choice: \(error.localizedDescription)"
      return false
    }
  }
}

extension RelayOrchestrator {
  /// Local setup choices become actual chat history without selecting or altering a task chat.
  @discardableResult func recordSetupExchange(question: String, answer: String) -> Bool {
    guard recordSetupQuestion(question) else { return false }
    return appendSetupMessages([AgentMessage(role: "you", text: answer)])
  }
  /// Present each question before its answer, once, through the same rendering and history as
  /// any other assistant reply. Reopening a chat never duplicates its unanswered question.
  @discardableResult func recordSetupQuestion(_ question: String) -> Bool {
    guard !working, team.activeID == team.mainProfileID, activeTeam == nil else { return false }
    // Asked already and not answered since: a status text or note that came after it does not
    // make it a new question.
    if transcript.last(where: { $0.role == "you" || ($0.role == "assistant" && $0.text == question) })?.text == question {
      return true
    }
    return appendSetupMessages([AgentMessage(role: "assistant", text: question, notice: true)])
  }
  /// A held request that setup also shows in the chat (`moveOnFromRequest`).
  func isSetupRequestCopy(_ item: Held) -> Bool {
    transcript.contains { $0.role == "you" && $0.text == item.message.text }
  }
  /// Setup is over: a held request leaves its place in the chat, with the line that promised an
  /// answer, because from here it shows where it is answered (or as a held message).
  func dropSetupRequestCopies() {
    guard !working, !heldHere.isEmpty else { return }
    let waiting = Set(heldHere.map(\.message.text))
    let kept = transcript.filter { message in
      !(message.role == "you" && waiting.contains(message.text))
        && !(message.role == "assistant" && message.text == SereinChatSetup.requestHeldLine)
    }
    guard kept.count != transcript.count else { return }
    replaceSetupMessages(kept)
  }
  private func appendSetupMessages(_ additions: [AgentMessage]) -> Bool {
    replaceSetupMessages(transcript + additions)
  }
  @discardableResult private func replaceSetupMessages(_ messages: [AgentMessage]) -> Bool {
    guard !working, team.activeID == team.mainProfileID, activeTeam == nil else { return false }
    var chats = agent.conversations
    let now = Date()
    if let index = chats.firstIndex(where: { $0.id == threadID }) {
      chats[index].messages = messages
      chats[index].serein = true
      chats[index].updatedAt = now
      chats[index].lastMessageAt = now
    } else {
      var chat = Conversation(id: threadID, title: "Setting up Serein", messages: messages, provider: assistantEngine(team.active).provider,
        mode: .anywhere, projectID: nil, remoteID: nil, scope: "", updatedAt: now)
      chat.serein = true
      chat.lastMessageAt = now
      chats.insert(chat, at: 0)
    }
    do {
      if !RunMode.previewing {
        try FileManager.default.createDirectory(at: browser.library.root.appendingPathComponent(dir),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try browser.library.save(state, to: dir + "/state.json")
        try browser.library.save(chats, to: "sessions/threads.json")
      }
      agent.conversations = chats
      if agent.conversationID == threadID { agent.messages = messages }
      agent.hub.latest(for: threadID)?.transcript = messages
      objectWillChange.send()
      return true
    } catch {
      lastError = "I couldn’t save that setup answer: \(error.localizedDescription)"
      return false
    }
  }
}
